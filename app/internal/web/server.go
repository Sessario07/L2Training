// Package web holds the HTTP layer: routing, middleware and handlers.
package web

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/trace"
	"golang.org/x/crypto/bcrypt"

	"github.com/sawibowo/l2lab/internal/bus"
	"github.com/sawibowo/l2lab/internal/cache"
	"github.com/sawibowo/l2lab/internal/obs"
	"github.com/sawibowo/l2lab/internal/store"
)

const sessionCookie = "l2lab_session"

type Server struct {
	Store *store.Store
	Cache *cache.Cache
	Bus   *bus.Bus
	Log   *slog.Logger
}

type ctxKey string

const userKey ctxKey = "user"

// Routes builds the mux. Note every route is registered with an explicit
// pattern name for metrics: using the raw URL path as a label would create
// unbounded cardinality and eventually take Prometheus down.
func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()

	// --- Probes and telemetry (deliberately NOT traced or metered) ---------
	// Health checks fire every few seconds from kubelet. Tracing them would
	// bury real traffic in noise and cost real money in a paid backend.
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /readyz", s.readyz)
	mux.Handle("GET /metrics", obs.MetricsHandler())

	// --- API ---------------------------------------------------------------
	s.route(mux, "POST /api/signup", "signup", s.signup)
	s.route(mux, "POST /api/login", "login", s.login)
	s.route(mux, "POST /api/logout", "logout", s.logout)
	s.route(mux, "GET /api/me", "me", s.requireAuth(s.me))
	s.route(mux, "PATCH /api/me", "update_profile", s.requireAuth(s.updateProfile))

	// Posts and threads
	s.route(mux, "POST /api/posts", "create_post", s.requireAuth(s.createPost))
	s.route(mux, "GET /api/timeline", "timeline", s.requireAuth(s.timeline))
	s.route(mux, "GET /api/posts/{id}", "thread", s.requireAuth(s.thread))
	s.route(mux, "DELETE /api/posts/{id}", "delete_post", s.requireAuth(s.deletePost))

	// Likes
	s.route(mux, "PUT /api/posts/{id}/like", "like", s.requireAuth(s.like))
	s.route(mux, "DELETE /api/posts/{id}/like", "unlike", s.requireAuth(s.unlike))

	// People
	s.route(mux, "GET /api/users", "list_users", s.requireAuth(s.listUsers))
	s.route(mux, "GET /api/users/{username}", "profile", s.requireAuth(s.profile))
	s.route(mux, "POST /api/follow/{username}", "follow", s.requireAuth(s.follow))
	s.route(mux, "DELETE /api/follow/{username}", "unfollow", s.requireAuth(s.unfollow))

	// The UI is NOT served from here any more - it is a separate image and a
	// separate Deployment, routed by the ALB. This process is a pure JSON API.
	// See frontend/ and k8s/app/frontend.yaml.

	// otelhttp extracts inbound traceparent headers and starts the root span.
	return otelhttp.NewHandler(recoverer(s.Log)(mux), "http",
		otelhttp.WithFilter(func(r *http.Request) bool {
			// Same reasoning as above: keep probes out of the traces.
			return !strings.HasPrefix(r.URL.Path, "/healthz") &&
				!strings.HasPrefix(r.URL.Path, "/readyz") &&
				!strings.HasPrefix(r.URL.Path, "/metrics")
		}),
	)
}

// route registers a handler wrapped in per-route metrics and access logging.
func (s *Server) route(mux *http.ServeMux, pattern, name string, h http.HandlerFunc) {
	mux.Handle(pattern, s.instrument(name, h))
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (w *statusRecorder) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

func (s *Server) instrument(route string, next http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}

		next(rec, r)

		elapsed := time.Since(start)
		obs.HTTPDuration.WithLabelValues(route, r.Method).Observe(elapsed.Seconds())
		obs.HTTPRequests.WithLabelValues(route, r.Method, statusClass(rec.status)).Inc()

		// One structured access log line per request, carrying the trace ID.
		// This is the bridge from "I see a slow request in Loki" to "here is
		// the trace that explains it".
		lvl := slog.LevelInfo
		if rec.status >= 500 {
			lvl = slog.LevelError
		}
		s.Log.LogAttrs(r.Context(), lvl, "http_request",
			slog.String("route", route),
			slog.String("method", r.Method),
			slog.String("path", r.URL.Path),
			slog.Int("status", rec.status),
			slog.Duration("duration", elapsed),
			slog.String("user_agent", r.UserAgent()),
		)
	})
}

// recoverer turns a panic into a 500 plus a logged stack, instead of killing
// the whole process and taking every in-flight request with it.
func recoverer(log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				if rec := recover(); rec != nil {
					span := trace.SpanFromContext(r.Context())
					span.RecordError(errors.New("panic"))
					log.ErrorContext(r.Context(), "panic recovered",
						slog.Any("panic", rec),
						slog.String("path", r.URL.Path))
					http.Error(w, "internal server error", http.StatusInternalServerError)
				}
			}()
			next.ServeHTTP(w, r)
		})
	}
}

func statusClass(code int) string {
	switch {
	case code < 200:
		return "1xx"
	case code < 300:
		return "2xx"
	case code < 400:
		return "3xx"
	case code < 500:
		return "4xx"
	default:
		return "5xx"
	}
}

// --- Auth -------------------------------------------------------------------

func (s *Server) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		c, err := r.Cookie(sessionCookie)
		if err != nil {
			writeErr(w, http.StatusUnauthorized, "not logged in")
			return
		}

		userID, err := s.Cache.Session(r.Context(), c.Value)
		if err != nil {
			// A cache miss here means the session expired or Redis lost it.
			// Note this returns 401, which looks identical to "never logged
			// in" - if Redis is flushed, every user is silently logged out.
			writeErr(w, http.StatusUnauthorized, "session expired")
			return
		}

		u, err := s.Store.UserByID(r.Context(), userID)
		if err != nil {
			writeErr(w, http.StatusUnauthorized, "unknown user")
			return
		}

		ctx := context.WithValue(r.Context(), userKey, u)
		next(w, r.WithContext(ctx))
	}
}

func currentUser(r *http.Request) *store.User {
	u, _ := r.Context().Value(userKey).(*store.User)
	return u
}

func newSessionID() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// --- Helpers ----------------------------------------------------------------

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func hashPassword(p string) (string, error) {
	// bcrypt cost 10 is ~60ms of CPU per hash. That is intentional (it slows
	// down offline cracking) but it also means signup/login are CPU-heavy
	// endpoints - visible as CPU throttling under load if limits are tight.
	b, err := bcrypt.GenerateFromPassword([]byte(p), 10)
	return string(b), err
}

func checkPassword(hash, p string) bool {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(p)) == nil
}
