package obs

import (
	"context"
	"testing"
)

// Reproduces the startup path that crash-looped in the cluster: with an OTLP
// endpoint configured, InitTracing builds a resource by merging with
// resource.Default(), which fails if the semconv schema versions disagree.
func TestInitTracingWithEndpoint(t *testing.T) {
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:4318")
	t.Setenv("POD_NAME", "test-pod")
	t.Setenv("NODE_NAME", "test-node")

	shutdown, err := InitTracing(context.Background(), "l2lab-test")
	if err != nil {
		t.Fatalf("InitTracing failed: %v", err)
	}
	if shutdown == nil {
		t.Fatal("nil shutdown func")
	}
	t.Log("tracing initialised without a schema conflict")
}
