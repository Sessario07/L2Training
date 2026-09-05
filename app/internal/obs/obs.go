// Package obs wires up the three telemetry signals and - crucially - ties them
// together with a single trace ID.
//
// The payoff: in Grafana you can see a latency spike on a metrics dashboard,
// click the exemplar to jump to the exact trace, then click a span to see the
// log lines emitted inside it. That "metric -> trace -> log" loop is the whole
// reason for running this stack, and it only works because every signal carries
// the same trace_id.
package obs

import (
	"context"
	"log/slog"
	"os"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
	"go.opentelemetry.io/otel/trace"
)

// traceHandler is a slog handler that copies the active trace and span IDs into
// every log record. Without this, logs and traces are two disconnected piles of
// data and correlation is manual guesswork.
type traceHandler struct{ slog.Handler }

func (h traceHandler) Handle(ctx context.Context, r slog.Record) error {
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		r.AddAttrs(
			slog.String("trace_id", sc.TraceID().String()),
			slog.String("span_id", sc.SpanID().String()),
		)
	}
	return h.Handler.Handle(ctx, r)
}

func (h traceHandler) WithAttrs(as []slog.Attr) slog.Handler {
	return traceHandler{h.Handler.WithAttrs(as)}
}

func (h traceHandler) WithGroup(name string) slog.Handler {
	return traceHandler{h.Handler.WithGroup(name)}
}

// NewLogger returns a JSON logger. JSON matters because Grafana Alloy ships
// stdout to Loki, and structured fields become queryable labels instead of
// text we would have to regex out later.
func NewLogger(service string) *slog.Logger {
	level := slog.LevelInfo
	if os.Getenv("LOG_LEVEL") == "debug" {
		level = slog.LevelDebug
	}

	base := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: level,
		ReplaceAttr: func(_ []string, a slog.Attr) slog.Attr {
			// Loki and most log tooling expect "timestamp"/"message".
			switch a.Key {
			case slog.TimeKey:
				a.Key = "timestamp"
			case slog.MessageKey:
				a.Key = "message"
			}
			return a
		},
	})

	logger := slog.New(traceHandler{base}).With(
		slog.String("service", service),
		slog.String("version", Version()),
	)
	slog.SetDefault(logger)
	return logger
}

func Version() string {
	if v := os.Getenv("APP_VERSION"); v != "" {
		return v
	}
	return "dev"
}

// InitTracing sets up the OTLP exporter pointed at Tempo (via Alloy).
// The returned func flushes buffered spans on shutdown - skip it and you lose
// the traces for whatever was in flight when the pod terminated, which is
// exactly the window you care about during an incident.
func InitTracing(ctx context.Context, service string) (func(context.Context) error, error) {
	endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if endpoint == "" {
		// No collector configured: run with a no-op tracer rather than failing.
		// Lets the app boot locally without the whole stack running.
		return func(context.Context) error { return nil }, nil
	}

	// Deliberately NO WithEndpointURL here. The SDK already reads
	// OTEL_EXPORTER_OTLP_ENDPOINT itself and appends the correct signal path
	// (/v1/traces), which is what the OpenTelemetry spec says that variable
	// means: a BASE url.
	//
	// WithEndpointURL(endpoint) treats its argument as a COMPLETE url, so it
	// POSTs to "/" and Tempo answers 404. That failure is quiet - the app
	// keeps serving traffic and only an INFO line in its own logs says
	// "traces export: failed to send ... 404". Use
	// OTEL_EXPORTER_OTLP_TRACES_ENDPOINT if you ever need to override the
	// full path explicitly.
	exp, err := otlptracehttp.New(ctx)
	if err != nil {
		return nil, err
	}

	// resource.Merge REFUSES to merge two resources with different schema URLs.
	// resource.Default() carries whatever schema the SDK ships with, so the
	// semconv import above must match the SDK version or this fails at
	// startup with "conflicting Schema URL".
	//
	// This only fires when tracing is actually configured - with
	// OTEL_EXPORTER_OTLP_ENDPOINT unset the function returns a no-op before
	// reaching here, which is exactly how it survived local testing.
	res, err := resource.Merge(resource.Default(), resource.NewWithAttributes(
		semconv.SchemaURL,
		semconv.ServiceName(service),
		semconv.ServiceVersion(Version()),
		attribute.String("deployment.environment", envOr("APP_ENV", "lab")),
		attribute.String("k8s.pod.name", os.Getenv("POD_NAME")),
		attribute.String("k8s.node.name", os.Getenv("NODE_NAME")),
	))
	if err != nil {
		return nil, err
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exp, sdktrace.WithBatchTimeout(2*time.Second)),
		sdktrace.WithResource(res),
		// Sample everything. Correct for a low-traffic lab; in real production
		// you would use ParentBased(TraceIDRatioBased(0.01)) or tail sampling.
		sdktrace.WithSampler(sdktrace.AlwaysSample()),
	)
	otel.SetTracerProvider(tp)

	// W3C traceparent, so a trace started in the API continues in the worker.
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	return tp.Shutdown, nil
}

func Tracer() trace.Tracer { return otel.Tracer("github.com/sawibowo/l2lab") }

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
