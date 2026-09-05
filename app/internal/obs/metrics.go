package obs

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"net/http"
)

// The RED method: Rate, Errors, Duration. If you only ever record three metrics
// about a service, record these.
var (
	HTTPRequests = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "app_http_requests_total",
			Help: "Total HTTP requests by route, method and status class.",
		},
		[]string{"route", "method", "status"},
	)

	HTTPDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name: "app_http_request_duration_seconds",
			Help: "HTTP request latency.",
			// Buckets chosen around expected latency. Get these wrong and your
			// p99 is a lie - everything lands in the +Inf bucket.
			Buckets: []float64{.005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5},
		},
		[]string{"route", "method"},
	)

	// Dependency latency, so you can answer "is it us or is it Postgres?"
	DepDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "app_dependency_duration_seconds",
			Help:    "Latency of calls to Postgres, Redis and NATS.",
			Buckets: []float64{.001, .005, .01, .025, .05, .1, .25, .5, 1, 2.5},
		},
		[]string{"dependency", "operation", "status"},
	)

	CacheEvents = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "app_cache_events_total",
			Help: "Redis cache hits and misses.",
		},
		[]string{"cache", "result"},
	)

	// Business metrics. Infra metrics tell you the pods are healthy; these tell
	// you the product actually works - which is not the same thing.
	PostsCreated = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "app_posts_created_total",
		Help: "Posts successfully written.",
	})

	SignupsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "app_signups_total",
			Help: "Signup attempts by outcome.",
		},
		[]string{"result"},
	)

	// Queue depth equivalent: how far behind the worker is.
	WorkerProcessed = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "app_worker_messages_total",
			Help: "NATS messages handled by the worker, by outcome.",
		},
		[]string{"subject", "result"},
	)

	WorkerLag = prometheus.NewHistogram(prometheus.HistogramOpts{
		Name:    "app_worker_lag_seconds",
		Help:    "Age of a message when the worker picked it up.",
		Buckets: []float64{.01, .05, .1, .5, 1, 5, 15, 60},
	})
)

// Registry is explicit rather than using the global default, so we control
// exactly what gets exposed.
var Registry = prometheus.NewRegistry()

func init() {
	Registry.MustRegister(
		HTTPRequests, HTTPDuration, DepDuration, CacheEvents,
		PostsCreated, SignupsTotal, WorkerProcessed, WorkerLag,
		// Go runtime internals: goroutines, GC pauses, heap. Invaluable for
		// diagnosing memory leaks and goroutine leaks.
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)
}

func MetricsHandler() http.Handler {
	return promhttp.HandlerFor(Registry, promhttp.HandlerOpts{
		// Lets Prometheus attach trace IDs to histogram buckets, which is what
		// makes the "click a latency spike -> open the trace" workflow possible.
		EnableOpenMetrics: true,
	})
}
