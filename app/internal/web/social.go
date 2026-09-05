package web

import (
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"

	"github.com/sawibowo/l2lab/internal/store"
)

const (
	replyLimit    = 100
	userListLimit = 50
	profileLimit  = 50
)

// pathID parses a {id} path segment. Returns 0 and false if it is not a
// positive integer, so handlers can reject it before touching the database.
func pathID(r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		return 0, false
	}
	return id, true
}

// --- Threads ----------------------------------------------------------------

// thread returns one post plus its replies — the conversation view.
func (s *Server) thread(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "invalid post id")
		return
	}
	me := currentUser(r)

	post, err := s.Store.PostByID(r.Context(), me.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "no such post")
		return
	} else if err != nil {
		s.Log.ErrorContext(r.Context(), "thread lookup failed", slog.Any("error", err))
		writeErr(w, http.StatusInternalServerError, "could not load post")
		return
	}

	replies, err := s.Store.Replies(r.Context(), me.ID, id, replyLimit)
	if err != nil {
		s.Log.ErrorContext(r.Context(), "reply lookup failed", slog.Any("error", err))
		writeErr(w, http.StatusInternalServerError, "could not load replies")
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"post": post, "replies": replies})
}

func (s *Server) deletePost(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "invalid post id")
		return
	}
	me := currentUser(r)

	// The store scopes the DELETE by user_id, so someone else's post returns
	// ErrNotFound rather than deleting anything.
	if err := s.Store.DeletePost(r.Context(), me.ID, id); errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "no such post, or it is not yours")
		return
	} else if err != nil {
		s.Log.ErrorContext(r.Context(), "delete failed", slog.Any("error", err))
		writeErr(w, http.StatusInternalServerError, "could not delete post")
		return
	}

	// The author's own timeline changed; everyone else's expires via TTL.
	_ = s.Cache.InvalidateTimelines(r.Context(), []int64{me.ID})

	s.Log.InfoContext(r.Context(), "post_deleted",
		slog.Int64("post_id", id), slog.Int64("user_id", me.ID))
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}

// --- Likes ------------------------------------------------------------------

func (s *Server) like(w http.ResponseWriter, r *http.Request)   { s.setLike(w, r, true) }
func (s *Server) unlike(w http.ResponseWriter, r *http.Request) { s.setLike(w, r, false) }

// setLike handles both directions. Both are idempotent, which is what lets the
// UI fire them optimistically without tracking current state.
func (s *Server) setLike(w http.ResponseWriter, r *http.Request, on bool) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "invalid post id")
		return
	}
	me := currentUser(r)

	var err error
	if on {
		err = s.Store.Like(r.Context(), me.ID, id)
	} else {
		err = s.Store.Unlike(r.Context(), me.ID, id)
	}
	if err != nil {
		s.Log.ErrorContext(r.Context(), "like write failed", slog.Any("error", err))
		writeErr(w, http.StatusInternalServerError, "could not update like")
		return
	}

	// Return the post so the client can render the true count rather than
	// guessing by incrementing locally.
	post, err := s.Store.PostByID(r.Context(), me.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "no such post")
		return
	} else if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not reload post")
		return
	}

	// NOTE: cached timelines still hold the OLD like count for up to 30s.
	// Deliberate — invalidating every follower's cache on every like would be
	// a write amplification problem. It is also a nice, harmless example of
	// eventual consistency that you can actually observe in the UI.
	writeJSON(w, http.StatusOK, post)
}

// --- People -----------------------------------------------------------------

// listUsers powers "who to follow": everyone but you, most-followed first.
func (s *Server) listUsers(w http.ResponseWriter, r *http.Request) {
	users, err := s.Store.ListUsers(r.Context(), currentUser(r).ID, userListLimit)
	if err != nil {
		s.Log.ErrorContext(r.Context(), "user list failed", slog.Any("error", err))
		writeErr(w, http.StatusInternalServerError, "could not list users")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"users": users})
}

// profile returns a user plus their posts.
func (s *Server) profile(w http.ResponseWriter, r *http.Request) {
	name := strings.ToLower(strings.TrimSpace(r.PathValue("username")))
	me := currentUser(r)

	u, err := s.Store.Profile(r.Context(), me.ID, name)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "no such user")
		return
	} else if err != nil {
		s.Log.ErrorContext(r.Context(), "profile lookup failed", slog.Any("error", err))
		writeErr(w, http.StatusInternalServerError, "could not load profile")
		return
	}

	posts, err := s.Store.UserPosts(r.Context(), me.ID, u.ID, profileLimit)
	if err != nil {
		s.Log.ErrorContext(r.Context(), "profile posts failed", slog.Any("error", err))
		writeErr(w, http.StatusInternalServerError, "could not load posts")
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"user": u, "posts": posts})
}

func (s *Server) unfollow(w http.ResponseWriter, r *http.Request) {
	target := strings.ToLower(strings.TrimSpace(r.PathValue("username")))
	me := currentUser(r)

	other, err := s.Store.UserByName(r.Context(), target)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "no such user")
		return
	} else if err != nil {
		writeErr(w, http.StatusInternalServerError, "lookup failed")
		return
	}

	if err := s.Store.Unfollow(r.Context(), me.ID, other.ID); err != nil {
		s.Log.ErrorContext(r.Context(), "unfollow failed", slog.Any("error", err))
		writeErr(w, http.StatusInternalServerError, "could not unfollow")
		return
	}

	// Their timeline just lost a source, so drop the cached copy immediately.
	_ = s.Cache.InvalidateTimelines(r.Context(), []int64{me.ID})

	s.Log.InfoContext(r.Context(), "unfollow",
		slog.Int64("follower_id", me.ID), slog.Int64("followee_id", other.ID))
	writeJSON(w, http.StatusOK, map[string]string{"unfollowed": other.Username})
}

// updateProfile sets the optional display name and bio.
func (s *Server) updateProfile(w http.ResponseWriter, r *http.Request) {
	var in struct {
		DisplayName *string `json:"display_name"`
		Bio         *string `json:"bio"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}

	// Trim, and treat an emptied field as "unset" rather than as an empty string.
	norm := func(p *string, max int) (*string, bool) {
		if p == nil {
			return nil, true
		}
		v := strings.TrimSpace(*p)
		if len(v) > max {
			return nil, false
		}
		if v == "" {
			return nil, true
		}
		return &v, true
	}

	dn, ok := norm(in.DisplayName, 50)
	if !ok {
		writeErr(w, http.StatusBadRequest, "display name must be 50 characters or fewer")
		return
	}
	bio, ok := norm(in.Bio, 160)
	if !ok {
		writeErr(w, http.StatusBadRequest, "bio must be 160 characters or fewer")
		return
	}

	me := currentUser(r)
	if err := s.Store.UpdateProfile(r.Context(), me.ID, dn, bio); err != nil {
		s.Log.ErrorContext(r.Context(), "profile update failed", slog.Any("error", err))
		writeErr(w, http.StatusInternalServerError, "could not save profile")
		return
	}

	u, err := s.Store.Me(r.Context(), me.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not reload profile")
		return
	}
	writeJSON(w, http.StatusOK, u)
}
