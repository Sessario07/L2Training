// Command worker consumes post-created events and invalidates the timeline
// caches of everyone who follows the author (fan-out on write).
//
// It exists to create a realistic asynchronous seam. When it falls behind,
// the site stays "up" but serves stale timelines - the difference between
// broken and degraded, which is exactly what L2 triage is about.
package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/sawibowo/l2lab/internal/bus"
	"github.com/sawibowo/l2lab/internal/cache"
	"github.com/sawibowo/l2lab/internal/obs"
	"github.com/sawibowo/l2lab/internal/store"
)

func main() {
	log := obs.NewLogger("l2lab-worker")

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	shutdownTracing, err := obs.InitTracing(ctx, "l2lab-worker")
	if err != nil {
		log.Error("tracing init failed", slog.Any("error", err))
		os.Exit(1)
	}

	db, err := store.New(ctx, mustEnv("DATABASE_URL"))
	if err != nil {
		log.Error("postgres connect failed", slog.Any("error", err))
		os.Exit(1)
	}
	defer db.Close()

	rdb := cache.New(mustEnv("REDIS_ADDR"), obs.Env("REDIS_PASSWORD"))
	defer rdb.Close()

	nc, err := bus.Connect(mustEnv("NATS_URL"))
	if err != nil {
		// Unlike the API, the worker has no purpose without NATS.
		log.Error("nats connect failed", slog.Any("error", err))
		os.Exit(1)
	}
	defer nc.Close()

	// Queue group "fanout": with several worker replicas, NATS delivers each
	// message to exactly one of them rather than to all.
	err = nc.Subscribe(bus.SubjectPostCreated, "fanout",
		func(ctx context.Context, msg *bus.PostCreated) error {
			// Artificial delay knob, used later for chaos work. Default 0.
			if d := workDelay(); d > 0 {
				time.Sleep(d)
			}

			followers, err := db.FollowerIDs(ctx, msg.AuthorID)
			if err != nil {
				log.ErrorContext(ctx, "follower lookup failed",
					slog.Any("error", err), slog.Int64("author_id", msg.AuthorID))
				return err
			}

			if err := rdb.InvalidateTimelines(ctx, followers); err != nil {
				log.ErrorContext(ctx, "cache invalidation failed", slog.Any("error", err))
				return err
			}

			log.InfoContext(ctx, "fanout_complete",
				slog.Int64("post_id", msg.PostID),
				slog.Int64("author_id", msg.AuthorID),
				slog.Int("followers_invalidated", len(followers)),
				slog.Duration("age", time.Since(msg.PostedAt)))
			return nil
		})
	if err != nil {
		log.Error("subscribe failed", slog.Any("error", err))
		os.Exit(1)
	}

	// The worker has no user-facing traffic, but it still exposes /metrics for
	// Prometheus and /healthz so Kubernetes can tell whether it is alive.
	mux := http.NewServeMux()
	mux.Handle("GET /metrics", obs.MetricsHandler())
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		if !nc.Healthy() {
			http.Error(w, "nats disconnected", http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})

	srv := &http.Server{
		Addr:              envOr("LISTEN_ADDR", ":8081"),
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() { _ = srv.ListenAndServe() }()

	log.Info("worker running", slog.String("subject", bus.SubjectPostCreated))

	<-ctx.Done()
	log.Info("shutdown signal received")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
	if err := shutdownTracing(shutdownCtx); err != nil {
		log.Warn("trace flush failed", slog.Any("error", err))
	}
	log.Info("shutdown complete")
}

// workDelay is a deliberate hook for later chaos exercises: set WORK_DELAY=2s
// and watch app_worker_lag_seconds climb while the site stays up.
func workDelay() time.Duration {
	d, err := time.ParseDuration(os.Getenv("WORK_DELAY"))
	if err != nil {
		return 0
	}
	return d
}

// mustEnv resolves via obs.Env, so every setting also accepts a "_FILE"
// variant pointing at a mounted secret.
func mustEnv(k string) string {
	v := obs.Env(k)
	if v == "" {
		slog.Error("required configuration is not set",
			slog.String("key", k),
			slog.String("hint", "set "+k+" or "+k+"_FILE"))
		os.Exit(1)
	}
	return v
}

func envOr(k, def string) string { return obs.EnvOr(k, def) }
