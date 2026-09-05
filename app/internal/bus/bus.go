// Package bus is the NATS layer - the asynchronous seam between the API and
// the worker.
//
// Why a message bus at all in an app this small? Because it creates a realistic
// failure surface: the API can succeed while the worker falls behind, so the
// system is "up" but stale. Distinguishing "broken" from "lagging" is a core
// L2 skill, and you cannot practise it without an async component.
package bus

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/nats-io/nats.go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"

	"github.com/sawibowo/l2lab/internal/obs"
)

const SubjectPostCreated = "app.post.created"

type PostCreated struct {
	PostID   int64     `json:"post_id"`
	AuthorID int64     `json:"author_id"`
	Author   string    `json:"author"`
	PostedAt time.Time `json:"posted_at"`

	// W3C traceparent, carried by hand so the worker's spans join the same
	// trace as the HTTP request that produced the message. Without this the
	// trace stops dead at the publish call.
	Traceparent string `json:"traceparent,omitempty"`
}

type Bus struct{ nc *nats.Conn }

func Connect(url string) (*Bus, error) {
	nc, err := nats.Connect(url,
		nats.Name("l2lab"),
		// Reconnect forever: a NATS restart should degrade the app, not kill it.
		nats.MaxReconnects(-1),
		nats.ReconnectWait(time.Second),
		nats.Timeout(5*time.Second),
	)
	if err != nil {
		return nil, err
	}
	return &Bus{nc: nc}, nil
}

func (b *Bus) Close() {
	if b != nil && b.nc != nil {
		b.nc.Close()
	}
}

// Healthy is nil-safe on purpose. The API starts even when NATS is unreachable
// (fan-out is optional), which leaves a nil *Bus - and a nil receiver here
// would panic inside the readiness probe, turning a degraded dependency into a
// crash loop.
func (b *Bus) Healthy() bool {
	return b != nil && b.nc != nil && b.nc.IsConnected()
}

func (b *Bus) Publish(ctx context.Context, subject string, msg *PostCreated) error {
	if !b.Healthy() {
		obs.DepDuration.WithLabelValues("nats", "publish", "unavailable").Observe(0)
		return errors.New("nats unavailable")
	}

	ctx, span := obs.Tracer().Start(ctx, "nats.publish "+subject,
		trace.WithSpanKind(trace.SpanKindProducer))
	defer span.End()
	span.SetAttributes(
		attribute.String("messaging.system", "nats"),
		attribute.String("messaging.destination.name", subject),
	)

	// Inject the current trace context into the message payload.
	carrier := propagation.MapCarrier{}
	otel.GetTextMapPropagator().Inject(ctx, carrier)
	msg.Traceparent = carrier.Get("traceparent")

	start := time.Now()
	payload, err := json.Marshal(msg)
	if err == nil {
		err = b.nc.Publish(subject, payload)
	}

	result := "ok"
	if err != nil {
		result = "error"
		span.RecordError(err)
	}
	obs.DepDuration.WithLabelValues("nats", "publish", result).
		Observe(time.Since(start).Seconds())
	return err
}

// Subscribe uses a queue group, so multiple worker replicas share the load
// instead of every replica handling every message.
func (b *Bus) Subscribe(subject, queue string, handle func(context.Context, *PostCreated) error) error {
	_, err := b.nc.QueueSubscribe(subject, queue, func(m *nats.Msg) {
		var msg PostCreated
		if err := json.Unmarshal(m.Data, &msg); err != nil {
			obs.WorkerProcessed.WithLabelValues(subject, "malformed").Inc()
			return
		}

		// Re-attach the producer's trace context so this work shows up as a
		// child span of the original HTTP request.
		ctx := otel.GetTextMapPropagator().Extract(
			context.Background(),
			propagation.MapCarrier{"traceparent": msg.Traceparent},
		)
		ctx, span := obs.Tracer().Start(ctx, "nats.receive "+subject,
			trace.WithSpanKind(trace.SpanKindConsumer))
		defer span.End()

		// How long the message sat before we picked it up. This is the number
		// that tells you the worker is falling behind.
		obs.WorkerLag.Observe(time.Since(msg.PostedAt).Seconds())

		result := "ok"
		if err := handle(ctx, &msg); err != nil {
			result = "error"
			span.RecordError(err)
		}
		obs.WorkerProcessed.WithLabelValues(subject, result).Inc()
	})
	return err
}
