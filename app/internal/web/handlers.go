package web

import (
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/sawibowo/l2lab/internal/bus"
	"github.com/sawibowo/l2lab/internal/cache"
	"github.com/sawibowo/l2lab/internal/obs"
	"github.com/sawibowo/l2lab/internal/store"
)

const timelineCacheTTL = 30 * time.Second
const timelineLimit = 50

// --- Probes -----------------------------------------------------------------

// healthz is the LIVENESS probe: "is this process wedged?"
// It deliberately checks NOTHING external. If it checked Postgres, then a
// database blip would make Kubernetes restart every API pod - turning a
// recoverable dependency outage into a full crash-loop outage. This distinction
// is one of the most commonly-botched things in real clusters.
func (s *Server) healthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// readyz is the READINESS probe: "should traffic be sent here right now?"
// This one DOES check dependencies. A failure pulls the pod out of the ALB
// target group without restarting it, so it can recover on its own.
func (s *Server) readyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := contextWithTimeout(r, 2*time.Second)
	defer cancel()

	checks := map[string]string{}
	ready := true

	if err := s.Store.Ping(ctx); err != nil {
		checks["postgres"] = err.Error()
		ready = false
	} else {
		checks["postgres"] = "ok"
	}

	if err := s.Cache.Ping(ctx); err != nil {
		checks["redis"] = err.Error()
		ready = false
	} else {
		checks["redis"] = "ok"
	}

	// NATS is NOT gating: the app can serve reads and writes without it, the
	// worker just falls behind. Marking ourselves unready would be an
	// over-reaction that takes the site down for a degraded background job.
	if s.Bus.Healthy() {
		checks["nats"] = "ok"
	} else {
		checks["nats"] = "disconnected (non-fatal)"
	}

	code := http.StatusOK
	if !ready {
		code = http.StatusServiceUnavailable
	}
	writeJSON(w, code, map[string]any{"ready": ready, "checks": checks})
}

// --- Auth -------------------------------------------------------------------

type credentials struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

func (s *Server) signup(w http.ResponseWriter, r *http.Request) {
	var in credentials
	if err := decode(r, &in); err != nil {
		obs.SignupsTotal.WithLabelValues("bad_request").Inc()
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}

	in.Username = strings.ToLower(strings.TrimSpace(in.Username))
	if len(in.Username) < 3 || len(in.Username) > 32 {
		obs.SignupsTotal.WithLabelValues("bad_request").Inc()
		writeErr(w, http.StatusBadRequest, "username must be 3-32 characters")
		return
	}
	if len(in.Password) < 8 {
		obs.SignupsTotal.WithLabelValues("bad_request").Inc()
		writeErr(w, http.StatusBadRequest, "password must be at least 8 characters")
		return
	}

	hash, err := hashPassword(in.Password)
	if err != nil {
		obs.SignupsTotal.WithLabelValues("error").Inc()
		writeErr(w, http.StatusInternalServerError, "could not hash password")
		return
	}

	u, err := s.Store.CreateUser(r.Context(), in.Username, hash)
	switch {
	case errors.Is(err, store.ErrDuplicate):
		obs.SignupsTotal.WithLabelValues("duplicate").Inc()
		writeErr(w, http.StatusConflict, "username already taken")
		return
	case err != nil:
		obs.SignupsTotal.WithLabelValues("error").Inc()
		s.Log.ErrorContext(r.Context(), "signup failed", slog.Any("error", err))
		writeErr(w, http.StatusInternalServerError, "could not create user")
		return
	}

	obs.SignupsTotal.WithLabelValues("ok").Inc()
	s.Log.InfoContext(r.Context(), "user_created",
		slog.String("username", u.Username), slog.Int64("user_id", u.ID))

	s.startSession(w, r, u)
	writeJSON(w, http.StatusCreated, u)
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	var in credentials
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}

	u, err := s.Store.UserByName(r.Context(), strings.ToLower(strings.TrimSpace(in.Username)))
	// Same response for "no such user" and "wrong password", so the endpoint
	// cannot be used to enumerate valid usernames.
	if err != nil || !checkPassword(u.PasswordHash, in.Password) {
		s.Log.InfoContext(r.Context(), "login_failed", slog.String("username", in.Username))
		writeErr(w, http.StatusUnauthorized, "invalid credentials")
		return
	}

	s.startSession(w, r, u)
	s.Log.InfoContext(r.Context(), "login_ok", slog.Int64("user_id", u.ID))
	writeJSON(w, http.StatusOK, u)
}

func (s *Server) startSession(w http.ResponseWriter, r *http.Request, u *store.User) {
	sid := newSessionID()
	if err := s.Cache.PutSession(r.Context(), sid, u.ID); err != nil {
		s.Log.ErrorContext(r.Context(), "session write failed", slog.Any("error", err))
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Value:    sid,
		Path:     "/",
		HttpOnly: true,                 // not readable from JavaScript
		Secure:   true,                 // HTTPS only - the ALB terminates TLS
		SameSite: http.SameSiteLaxMode, // basic CSRF mitigation
		MaxAge:   int((24 * time.Hour).Seconds()),
	})
}

func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie(sessionCookie); err == nil {
		_ = s.Cache.DropSession(r.Context(), c.Value)
	}
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Value: "", Path: "/", MaxAge: -1})
	writeJSON(w, http.StatusOK, map[string]string{"status": "logged out"})
}

// me returns the logged-in user WITH their follower/following/post counts,
// so the UI can render a profile card without a second round trip.
func (s *Server) me(w http.ResponseWriter, r *http.Request) {
	u, err := s.Store.Me(r.Context(), currentUser(r).ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not load profile")
		return
	}
	writeJSON(w, http.StatusOK, u)
}

// --- Posts ------------------------------------------------------------------

func (s *Server) createPost(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Body string `json:"body"`
		// Present when this post is a reply, which is what makes threads work.
		ParentID *int64 `json:"parent_id"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}

	in.Body = strings.TrimSpace(in.Body)
	if in.Body == "" || len(in.Body) > 280 {
		writeErr(w, http.StatusBadRequest, "body must be 1-280 characters")
		return
	}

	// Reject a reply to a post that does not exist, rather than letting the
	// foreign key raise an opaque 500 later.
	if in.ParentID != nil {
		if _, err := s.Store.PostByID(r.Context(), currentUser(r).ID, *in.ParentID); err != nil {
			writeErr(w, http.StatusNotFound, "the post you are replying to does not exist")
			return
		}
	}

	u := currentUser(r)
	p, err := s.Store.CreatePost(r.Context(), u.ID, in.Body, in.ParentID)
	if err != nil {
		s.Log.ErrorContext(r.Context(), "create post failed", slog.Any("error", err))
		writeErr(w, http.StatusInternalServerError, "could not save post")
		return
	}
	p.Author = u.Username
	p.DisplayName = u.DisplayName
	obs.PostsCreated.Inc()

	// Fan-out happens asynchronously. If NATS is down we log and carry on:
	// the post is already durably written, and stale timelines expire in 30s
	// anyway. Failing the request here would let a background-job outage take
	// down the primary user journey.
	if err := s.Bus.Publish(r.Context(), bus.SubjectPostCreated, &bus.PostCreated{
		PostID:   p.ID,
		AuthorID: u.ID,
		Author:   u.Username,
		PostedAt: p.Created,
	}); err != nil {
		s.Log.WarnContext(r.Context(), "fan-out publish failed",
			slog.Any("error", err), slog.Int64("post_id", p.ID))
	}

	// The author's own timeline must be correct immediately - they expect to
	// see their own post. Everyone else's is invalidated by the worker.
	_ = s.Cache.InvalidateTimelines(r.Context(), []int64{u.ID})

	s.Log.InfoContext(r.Context(), "post_created",
		slog.Int64("post_id", p.ID), slog.Int64("user_id", u.ID))
	writeJSON(w, http.StatusCreated, p)
}

// timeline is the read-through cache path: Redis first, Postgres on a miss.
func (s *Server) timeline(w http.ResponseWriter, r *http.Request) {
	u := currentUser(r)

	var posts []store.Post
	if err := s.Cache.GetTimeline(r.Context(), u.ID, &posts); err == nil {
		writeJSON(w, http.StatusOK, map[string]any{"source": "cache", "posts": posts})
		return
	} else if !errors.Is(err, cache.ErrMiss) {
		// Redis is erroring rather than simply empty. Degrade to Postgres
		// rather than failing - the cache is an optimisation, not a dependency.
		s.Log.WarnContext(r.Context(), "cache read failed", slog.Any("error", err))
	}

	posts, err := s.Store.Timeline(r.Context(), u.ID, timelineLimit)
	if err != nil {
		s.Log.ErrorContext(r.Context(), "timeline query failed", slog.Any("error", err))
		writeErr(w, http.StatusInternalServerError, "could not load timeline")
		return
	}
	if posts == nil {
		posts = []store.Post{}
	}

	if err := s.Cache.PutTimeline(r.Context(), u.ID, posts, timelineCacheTTL); err != nil {
		s.Log.WarnContext(r.Context(), "cache write failed", slog.Any("error", err))
	}
	writeJSON(w, http.StatusOK, map[string]any{"source": "database", "posts": posts})
}

// --- Follows ----------------------------------------------------------------

func (s *Server) follow(w http.ResponseWriter, r *http.Request) {
	target := strings.ToLower(strings.TrimSpace(r.PathValue("username")))
	u := currentUser(r)

	if target == u.Username {
		writeErr(w, http.StatusBadRequest, "you cannot follow yourself")
		return
	}

	other, err := s.Store.UserByName(r.Context(), target)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "no such user")
		return
	} else if err != nil {
		writeErr(w, http.StatusInternalServerError, "lookup failed")
		return
	}

	if err := s.Store.Follow(r.Context(), u.ID, other.ID); err != nil {
		s.Log.ErrorContext(r.Context(), "follow failed", slog.Any("error", err))
		writeErr(w, http.StatusInternalServerError, "could not follow")
		return
	}

	// The follower's timeline just changed shape, so drop their cache.
	_ = s.Cache.InvalidateTimelines(r.Context(), []int64{u.ID})

	s.Log.InfoContext(r.Context(), "follow_created",
		slog.Int64("follower_id", u.ID), slog.Int64("followee_id", other.ID))
	writeJSON(w, http.StatusOK, map[string]string{"following": other.Username})
}
