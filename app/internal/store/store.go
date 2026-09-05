// Package store is the PostgreSQL layer.
package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"

	"github.com/sawibowo/l2lab/internal/obs"
)

var ErrNotFound = errors.New("not found")
var ErrDuplicate = errors.New("already exists")

type Store struct{ pool *pgxpool.Pool }

type User struct {
	ID           int64     `json:"id"`
	Username     string    `json:"username"`
	PasswordHash string    `json:"-"` // never serialised to a client
	CreatedAt    time.Time `json:"created_at"`

	DisplayName *string `json:"display_name,omitempty"`
	Bio         *string `json:"bio,omitempty"`

	// Populated only by Profile and ListUsers, which compute them.
	Followers   int  `json:"followers"`
	Following   int  `json:"following"`
	PostCount   int  `json:"posts"`
	IsFollowing bool `json:"is_following"`
	IsSelf      bool `json:"is_self"`
}

type Post struct {
	ID       int64     `json:"id"`
	AuthorID int64     `json:"author_id"`
	Author   string    `json:"author"`
	Body     string    `json:"body"`
	Created  time.Time `json:"created_at"`

	// The author's display name, when they have set one. Denormalised onto
	// the post so the feed does not need a second query per row.
	DisplayName *string `json:"display_name,omitempty"`

	// nil for a top-level post; set when this post is a reply.
	ParentID *int64 `json:"parent_id,omitempty"`

	Likes     int  `json:"likes"`
	Replies   int  `json:"replies"`
	LikedByMe bool `json:"liked_by_me"`
}

// postColumns is shared by every query that returns posts, so the feed, a
// thread and a profile all produce identically-shaped rows.
//
// $1 is always the VIEWING user's id - that is what makes `liked_by_me`
// per-viewer. The two LEFT JOIN subqueries aggregate likes and replies.
// This is a deliberately realistic query: it is the kind that looks fine on
// 100 rows and becomes an incident on 10 million.
const postColumns = `
	SELECT p.id, p.user_id, u.username, u.display_name, p.body, p.created_at, p.parent_id,
	       COALESCE(l.cnt, 0) AS likes,
	       COALESCE(r.cnt, 0) AS replies,
	       EXISTS (SELECT 1 FROM likes lk WHERE lk.post_id = p.id AND lk.user_id = $1) AS liked_by_me
	FROM posts p
	JOIN users u ON u.id = p.user_id
	LEFT JOIN (SELECT post_id, count(*) AS cnt FROM likes GROUP BY post_id) l
	       ON l.post_id = p.id
	LEFT JOIN (SELECT parent_id, count(*) AS cnt FROM posts
	           WHERE parent_id IS NOT NULL GROUP BY parent_id) r
	       ON r.parent_id = p.id
`

func New(ctx context.Context, dsn string) (*Store, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}

	// Pool sizing is a classic incident cause. Too small and requests queue
	// behind connection acquisition (looks like "the database is slow" when it
	// is actually us). Too large and Postgres itself runs out of backends -
	// its default max_connections is 100, shared across every replica.
	cfg.MaxConns = 10
	cfg.MinConns = 2
	cfg.MaxConnLifetime = 30 * time.Minute
	cfg.MaxConnIdleTime = 5 * time.Minute
	cfg.ConnConfig.ConnectTimeout = 5 * time.Second

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	return &Store{pool: pool}, nil
}

func (s *Store) Close() { s.pool.Close() }

func (s *Store) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

// PoolStats feeds the connection-pool gauges. Watching these is how you catch
// pool exhaustion before it becomes a user-visible outage.
func (s *Store) PoolStats() (acquired, idle, total int32, waitCount int64) {
	st := s.pool.Stat()
	return st.AcquiredConns(), st.IdleConns(), st.TotalConns(), st.EmptyAcquireCount()
}

// trace wraps a database call with a span plus a latency histogram, so the same
// operation shows up in both Tempo and Prometheus under the same name.
func (s *Store) trace(ctx context.Context, op string, fn func(context.Context) error) error {
	ctx, span := obs.Tracer().Start(ctx, "postgres."+op)
	defer span.End()
	span.SetAttributes(
		attribute.String("db.system", "postgresql"),
		attribute.String("db.operation", op),
	)

	start := time.Now()
	err := fn(ctx)

	result := "ok"
	if err != nil && !errors.Is(err, ErrNotFound) {
		result = "error"
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
	}
	obs.DepDuration.WithLabelValues("postgres", op, result).
		Observe(time.Since(start).Seconds())
	return err
}

// Migrate applies every .sql file in dir, in filename order. Deliberately naive:
// the files are written to be idempotent (CREATE TABLE IF NOT EXISTS) so
// re-running is safe. Real production wants a proper migration tool with a
// version table and down-migrations.
func (s *Store) Migrate(ctx context.Context, dir string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return fmt.Errorf("read migrations dir: %w", err)
	}

	var files []string
	for _, e := range entries {
		if !e.IsDir() && filepath.Ext(e.Name()) == ".sql" {
			files = append(files, e.Name())
		}
	}
	sort.Strings(files)

	for _, f := range files {
		sqlBytes, err := os.ReadFile(filepath.Join(dir, f))
		if err != nil {
			return err
		}
		if _, err := s.pool.Exec(ctx, string(sqlBytes)); err != nil {
			return fmt.Errorf("migration %s: %w", f, err)
		}
	}
	return nil
}

// --- Users ------------------------------------------------------------------

func (s *Store) CreateUser(ctx context.Context, username, hash string) (*User, error) {
	var u User
	err := s.trace(ctx, "create_user", func(ctx context.Context) error {
		row := s.pool.QueryRow(ctx,
			`INSERT INTO users (username, password_hash) VALUES ($1, $2)
			 RETURNING id, username, created_at`,
			username, hash)
		if err := row.Scan(&u.ID, &u.Username, &u.CreatedAt); err != nil {
			// 23505 = unique_violation. Mapping it to a domain error keeps
			// Postgres-specific codes out of the HTTP layer.
			if isUniqueViolation(err) {
				return ErrDuplicate
			}
			return err
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &u, nil
}

func (s *Store) UserByName(ctx context.Context, username string) (*User, error) {
	var u User
	err := s.trace(ctx, "user_by_name", func(ctx context.Context) error {
		row := s.pool.QueryRow(ctx,
			`SELECT id, username, password_hash, created_at FROM users WHERE username = $1`,
			username)
		err := row.Scan(&u.ID, &u.Username, &u.PasswordHash, &u.CreatedAt)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	})
	if err != nil {
		return nil, err
	}
	return &u, nil
}

func (s *Store) UserByID(ctx context.Context, id int64) (*User, error) {
	var u User
	err := s.trace(ctx, "user_by_id", func(ctx context.Context) error {
		row := s.pool.QueryRow(ctx,
			`SELECT id, username, password_hash, created_at FROM users WHERE id = $1`, id)
		err := row.Scan(&u.ID, &u.Username, &u.PasswordHash, &u.CreatedAt)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	})
	if err != nil {
		return nil, err
	}
	return &u, nil
}

// --- Posts ------------------------------------------------------------------

// CreatePost writes a post. Pass a non-nil parentID to make it a reply.
func (s *Store) CreatePost(ctx context.Context, userID int64, body string, parentID *int64) (*Post, error) {
	var p Post
	p.AuthorID = userID
	p.ParentID = parentID
	err := s.trace(ctx, "create_post", func(ctx context.Context) error {
		return s.pool.QueryRow(ctx,
			`INSERT INTO posts (user_id, body, parent_id) VALUES ($1, $2, $3)
			 RETURNING id, body, created_at`,
			userID, body, parentID).Scan(&p.ID, &p.Body, &p.Created)
	})
	if err != nil {
		return nil, err
	}
	return &p, nil
}

// scanPosts consumes rows shaped by postColumns.
func scanPosts(rows pgx.Rows) ([]Post, error) {
	out := []Post{}
	for rows.Next() {
		var p Post
		if err := rows.Scan(&p.ID, &p.AuthorID, &p.Author, &p.DisplayName, &p.Body,
			&p.Created, &p.ParentID, &p.Likes, &p.Replies, &p.LikedByMe); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// Timeline returns the caller's own top-level posts plus those of everyone
// they follow. Replies are excluded, the same way they are on a real feed -
// you see a reply by opening the thread, not in the main timeline.
func (s *Store) Timeline(ctx context.Context, userID int64, limit int) ([]Post, error) {
	var out []Post
	err := s.trace(ctx, "timeline", func(ctx context.Context) error {
		rows, err := s.pool.Query(ctx, postColumns+`
			WHERE p.parent_id IS NULL
			  AND (p.user_id = $1
			       OR p.user_id IN (SELECT followee_id FROM follows WHERE follower_id = $1))
			ORDER BY p.created_at DESC
			LIMIT $2`, userID, limit)
		if err != nil {
			return err
		}
		defer rows.Close()
		out, err = scanPosts(rows)
		return err
	})
	return out, err
}

// --- Follows ----------------------------------------------------------------

func (s *Store) Follow(ctx context.Context, followerID, followeeID int64) error {
	return s.trace(ctx, "follow", func(ctx context.Context) error {
		_, err := s.pool.Exec(ctx,
			`INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2)
			 ON CONFLICT DO NOTHING`, followerID, followeeID)
		return err
	})
}

// FollowerIDs is what the worker uses to fan out cache invalidation after a post.
func (s *Store) FollowerIDs(ctx context.Context, userID int64) ([]int64, error) {
	var ids []int64
	err := s.trace(ctx, "follower_ids", func(ctx context.Context) error {
		rows, err := s.pool.Query(ctx,
			`SELECT follower_id FROM follows WHERE followee_id = $1`, userID)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var id int64
			if err := rows.Scan(&id); err != nil {
				return err
			}
			ids = append(ids, id)
		}
		return rows.Err()
	})
	return ids, err
}

func isUniqueViolation(err error) bool {
	var pgErr interface{ SQLState() string }
	return errors.As(err, &pgErr) && pgErr.SQLState() == "23505"
}

// PoolCollector exposes pgxpool internals to Prometheus.
func (s *Store) PoolCollector() prometheus.Collector {
	return prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "app_db_pool_acquired_connections",
		Help: "Connections currently checked out of the pgx pool.",
	}, func() float64 {
		return float64(s.pool.Stat().AcquiredConns())
	})
}
