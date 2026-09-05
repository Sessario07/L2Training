// Command api serves the HTTP API and the web UI.
package main

import (
	"context"
	"errors"
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
	"github.com/sawibowo/l2lab/internal/web"
)

func main() {
	log := obs.NewLogger("l2lab-api")

	// Root context cancelled on SIGTERM. Kubernetes sends SIGTERM and then
	// waits terminationGracePeriodSeconds before SIGKILL, so everything below
	// must finish inside that window or connections get cut mid-request.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	shutdownTracing, err := obs.InitTracing(ctx, "l2lab-api")
	if err != nil {
		log.Error("tracing init failed", slog.Any("error", err))
		os.Exit(1)
	}

	// --- Dependencies -------------------------------------------------------

	db, err := store.New(ctx, mustEnv("DATABASE_URL"))
	if err != nil {
		log.Error("postgres connect failed", slog.Any("error", err))
		os.Exit(1)
	}
	defer db.Close()

	if dir := envOr("MIGRATIONS_DIR", "/migrations"); dir != "" {
		if err := db.Migrate(ctx, dir); err != nil {
			log.Error("migrations failed", slog.Any("error", err))
			os.Exit(1)
		}
		log.Info("migrations applied", slog.String("dir", dir))
	}
	obs.Registry.MustRegister(db.PoolCollector())

	rdb := cache.New(mustEnv("REDIS_ADDR"), obs.Env("REDIS_PASSWORD"))
	defer rdb.Close()

	nc, err := bus.Connect(mustEnv("NATS_URL"))
	if err != nil {
		// Non-fatal by design: NATS only drives background fan-out. Exiting
		// here would mean a message-bus outage takes the whole site down.
		log.Warn("nats connect failed; fan-out disabled", slog.Any("error", err))
	}
	if nc != nil {
		defer nc.Close()
	}

	// --- HTTP server --------------------------------------------------------

	srv := &http.Server{
		Addr:    envOr("LISTEN_ADDR", ":8080"),
		Handler: (&web.Server{Store: db, Cache: rdb, Bus: nc, Log: log}).Routes(),

		// Timeouts are not optional. Without them a slow or malicious client
		// holds a goroutine and a connection open indefinitely, and the pod
		// eventually exhausts memory or file descriptors.
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		log.Info("api listening", slog.String("addr", srv.Addr))
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("listen failed", slog.Any("error", err))
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	log.Info("shutdown signal received")

	// Graceful shutdown, in order:
	//   1. Sleep briefly so the ALB notices we are going away and stops sending
	//      new requests. Skipping this causes 502s during every deploy, because
	//      target group deregistration is not instantaneous.
	//   2. Drain in-flight HTTP requests.
	//   3. Flush buffered spans - otherwise the traces for the requests that
	//      were in flight during the incident are lost.
	time.Sleep(preStopDelay())

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown failed", slog.Any("error", err))
	}
	if err := shutdownTracing(shutdownCtx); err != nil {
		log.Warn("trace flush failed", slog.Any("error", err))
	}
	log.Info("shutdown complete")
}

func preStopDelay() time.Duration {
	if d, err := time.ParseDuration(envOr("PRESTOP_DELAY", "5s")); err == nil {
		return d
	}
	return 5 * time.Second
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
