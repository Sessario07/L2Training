package store

import (
	"context"

	"github.com/jackc/pgx/v5"
)

// --- Single post and threads -------------------------------------------------

// PostByID fetches one post as seen by `viewerID` (which determines liked_by_me).
func (s *Store) PostByID(ctx context.Context, viewerID, postID int64) (*Post, error) {
	var p Post
	err := s.trace(ctx, "post_by_id", func(ctx context.Context) error {
		rows, err := s.pool.Query(ctx, postColumns+` WHERE p.id = $2`, viewerID, postID)
		if err != nil {
			return err
		}
		defer rows.Close()

		posts, err := scanPosts(rows)
		if err != nil {
			return err
		}
		if len(posts) == 0 {
			return ErrNotFound
		}
		p = posts[0]
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &p, nil
}

// Replies returns the direct replies to a post, oldest first - the order a
// conversation reads in.
func (s *Store) Replies(ctx context.Context, viewerID, postID int64, limit int) ([]Post, error) {
	var out []Post
	err := s.trace(ctx, "replies", func(ctx context.Context) error {
		rows, err := s.pool.Query(ctx, postColumns+`
			WHERE p.parent_id = $2
			ORDER BY p.created_at ASC
			LIMIT $3`, viewerID, postID, limit)
		if err != nil {
			return err
		}
		defer rows.Close()
		out, err = scanPosts(rows)
		return err
	})
	return out, err
}

// UserPosts returns one user's own posts, replies included, for their profile.
func (s *Store) UserPosts(ctx context.Context, viewerID, authorID int64, limit int) ([]Post, error) {
	var out []Post
	err := s.trace(ctx, "user_posts", func(ctx context.Context) error {
		rows, err := s.pool.Query(ctx, postColumns+`
			WHERE p.user_id = $2
			ORDER BY p.created_at DESC
			LIMIT $3`, viewerID, authorID, limit)
		if err != nil {
			return err
		}
		defer rows.Close()
		out, err = scanPosts(rows)
		return err
	})
	return out, err
}

// DeletePost removes a post, but only if the caller wrote it. Authorisation is
// expressed in the WHERE clause rather than as a separate SELECT-then-DELETE,
// which would be racy.
func (s *Store) DeletePost(ctx context.Context, userID, postID int64) error {
	return s.trace(ctx, "delete_post", func(ctx context.Context) error {
		tag, err := s.pool.Exec(ctx,
			`DELETE FROM posts WHERE id = $1 AND user_id = $2`, postID, userID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			// Either it does not exist, or it is not theirs. Returning the same
			// error for both means this cannot be used to probe for post IDs.
			return ErrNotFound
		}
		return nil
	})
}

// --- Likes -------------------------------------------------------------------

// Like is idempotent: liking twice is not an error, it is a no-op.
func (s *Store) Like(ctx context.Context, userID, postID int64) error {
	return s.trace(ctx, "like", func(ctx context.Context) error {
		_, err := s.pool.Exec(ctx,
			`INSERT INTO likes (user_id, post_id) VALUES ($1, $2)
			 ON CONFLICT DO NOTHING`, userID, postID)
		return err
	})
}

func (s *Store) Unlike(ctx context.Context, userID, postID int64) error {
	return s.trace(ctx, "unlike", func(ctx context.Context) error {
		_, err := s.pool.Exec(ctx,
			`DELETE FROM likes WHERE user_id = $1 AND post_id = $2`, userID, postID)
		return err
	})
}

// --- Follows -----------------------------------------------------------------

func (s *Store) Unfollow(ctx context.Context, followerID, followeeID int64) error {
	return s.trace(ctx, "unfollow", func(ctx context.Context) error {
		_, err := s.pool.Exec(ctx,
			`DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2`,
			followerID, followeeID)
		return err
	})
}

// --- Profiles and discovery --------------------------------------------------

// userColumns computes the counts a profile card needs. $1 is the viewer.
const userColumns = `
	SELECT u.id, u.username, u.created_at, u.display_name, u.bio,
	       (SELECT count(*) FROM follows WHERE followee_id = u.id) AS followers,
	       (SELECT count(*) FROM follows WHERE follower_id = u.id) AS following,
	       (SELECT count(*) FROM posts   WHERE user_id     = u.id) AS posts,
	       EXISTS (SELECT 1 FROM follows f
	               WHERE f.follower_id = $1 AND f.followee_id = u.id) AS is_following
	FROM users u
`

func scanUsers(rows pgx.Rows, viewerID int64) ([]User, error) {
	out := []User{}
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.Username, &u.CreatedAt, &u.DisplayName, &u.Bio,
			&u.Followers, &u.Following, &u.PostCount, &u.IsFollowing); err != nil {
			return nil, err
		}
		u.IsSelf = u.ID == viewerID
		out = append(out, u)
	}
	return out, rows.Err()
}

// Profile returns one user with their counts, as seen by the viewer.
func (s *Store) Profile(ctx context.Context, viewerID int64, username string) (*User, error) {
	var u User
	err := s.trace(ctx, "profile", func(ctx context.Context) error {
		rows, err := s.pool.Query(ctx, userColumns+` WHERE u.username = $2`, viewerID, username)
		if err != nil {
			return err
		}
		defer rows.Close()

		users, err := scanUsers(rows, viewerID)
		if err != nil {
			return err
		}
		if len(users) == 0 {
			return ErrNotFound
		}
		u = users[0]
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &u, nil
}

// ListUsers powers the "who to follow" view: everyone except the viewer,
// most-followed first.
func (s *Store) ListUsers(ctx context.Context, viewerID int64, limit int) ([]User, error) {
	var out []User
	err := s.trace(ctx, "list_users", func(ctx context.Context) error {
		rows, err := s.pool.Query(ctx, userColumns+`
			WHERE u.id <> $1
			ORDER BY followers DESC, u.created_at DESC
			LIMIT $2`, viewerID, limit)
		if err != nil {
			return err
		}
		defer rows.Close()
		out, err = scanUsers(rows, viewerID)
		return err
	})
	return out, err
}

// Me is Profile for the logged-in user, so the UI gets counts for itself too.
func (s *Store) Me(ctx context.Context, userID int64) (*User, error) {
	var u User
	err := s.trace(ctx, "me", func(ctx context.Context) error {
		rows, err := s.pool.Query(ctx, userColumns+` WHERE u.id = $2`, userID, userID)
		if err != nil {
			return err
		}
		defer rows.Close()

		users, err := scanUsers(rows, userID)
		if err != nil {
			return err
		}
		if len(users) == 0 {
			return ErrNotFound
		}
		u = users[0]
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &u, nil
}

// UpdateProfile sets the optional display name and bio.
func (s *Store) UpdateProfile(ctx context.Context, userID int64, displayName, bio *string) error {
	return s.trace(ctx, "update_profile", func(ctx context.Context) error {
		_, err := s.pool.Exec(ctx,
			`UPDATE users SET display_name = $2, bio = $3 WHERE id = $1`,
			userID, displayName, bio)
		return err
	})
}
