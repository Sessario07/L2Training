// Package cache is the Redis layer: sessions plus a timeline read-through cache.
package cache

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"

	"github.com/sawibowo/l2lab/internal/obs"
)

var ErrMiss = errors.New("cache miss")

type Cache struct{ rdb *redis.Client }

func New(addr, password string) *Cache {
	return &Cache{rdb: redis.NewClient(&redis.Options{
		Addr:     addr,
		Password: password,

		// A small pool with a short timeout fails fast and loudly rather than
		// letting requests pile up invisibly behind Redis.
		PoolSize:     10,
		DialTimeout:  2 * time.Second,
		ReadTimeout:  1 * time.Second,
		WriteTimeout: 1 * time.Second,
	})}
}

func (c *Cache) Close() error { return c.rdb.Close() }

func (c *Cache) Ping(ctx context.Context) error { return c.rdb.Ping(ctx).Err() }

func (c *Cache) trace(ctx context.Context, op string, fn func(context.Context) error) error {
	ctx, span := obs.Tracer().Start(ctx, "redis."+op)
	defer span.End()
	span.SetAttributes(
		attribute.String("db.system", "redis"),
		attribute.String("db.operation", op),
	)

	start := time.Now()
	err := fn(ctx)

	result := "ok"
	if err != nil && !errors.Is(err, ErrMiss) {
		result = "error"
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
	}
	obs.DepDuration.WithLabelValues("redis", op, result).Observe(time.Since(start).Seconds())
	return err
}

// --- Sessions ---------------------------------------------------------------
//
// Sessions live in Redis rather than in-process memory. That is what lets the
// API scale to multiple replicas behind the ALB - any pod can serve any user.
// It also means Redis is now on the critical path for every authenticated
// request, which is a tradeoff worth being conscious of.

const sessionTTL = 24 * time.Hour

func (c *Cache) PutSession(ctx context.Context, sid string, userID int64) error {
	return c.trace(ctx, "put_session", func(ctx context.Context) error {
		return c.rdb.Set(ctx, "session:"+sid, userID, sessionTTL).Err()
	})
}

func (c *Cache) Session(ctx context.Context, sid string) (int64, error) {
	var userID int64
	err := c.trace(ctx, "get_session", func(ctx context.Context) error {
		v, err := c.rdb.Get(ctx, "session:"+sid).Int64()
		if errors.Is(err, redis.Nil) {
			return ErrMiss
		}
		userID = v
		return err
	})
	return userID, err
}

func (c *Cache) DropSession(ctx context.Context, sid string) error {
	return c.trace(ctx, "drop_session", func(ctx context.Context) error {
		return c.rdb.Del(ctx, "session:"+sid).Err()
	})
}

// --- Timeline cache ---------------------------------------------------------

func timelineKey(userID int64) string {
	return "timeline:" + itoa(userID)
}

// GetTimeline returns ErrMiss when nothing is cached, so callers fall through
// to Postgres. Every call records a hit/miss so the cache hit ratio is
// graphable - a sudden drop in hit ratio is a classic precursor to a database
// overload incident.
func (c *Cache) GetTimeline(ctx context.Context, userID int64, out any) error {
	err := c.trace(ctx, "get_timeline", func(ctx context.Context) error {
		b, err := c.rdb.Get(ctx, timelineKey(userID)).Bytes()
		if errors.Is(err, redis.Nil) {
			return ErrMiss
		}
		if err != nil {
			return err
		}
		return json.Unmarshal(b, out)
	})

	switch {
	case err == nil:
		obs.CacheEvents.WithLabelValues("timeline", "hit").Inc()
	case errors.Is(err, ErrMiss):
		obs.CacheEvents.WithLabelValues("timeline", "miss").Inc()
	default:
		obs.CacheEvents.WithLabelValues("timeline", "error").Inc()
	}
	return err
}

func (c *Cache) PutTimeline(ctx context.Context, userID int64, v any, ttl time.Duration) error {
	return c.trace(ctx, "put_timeline", func(ctx context.Context) error {
		b, err := json.Marshal(v)
		if err != nil {
			return err
		}
		return c.rdb.Set(ctx, timelineKey(userID), b, ttl).Err()
	})
}

// InvalidateTimelines is called by the worker after a new post, for every
// follower of the author. This is the "fan-out on write" pattern.
func (c *Cache) InvalidateTimelines(ctx context.Context, userIDs []int64) error {
	if len(userIDs) == 0 {
		return nil
	}
	return c.trace(ctx, "invalidate_timelines", func(ctx context.Context) error {
		keys := make([]string, len(userIDs))
		for i, id := range userIDs {
			keys[i] = timelineKey(id)
		}
		return c.rdb.Del(ctx, keys...).Err()
	})
}

// Info exposes Redis INFO fields (used by /readyz and for debugging evictions).
func (c *Cache) Info(ctx context.Context, section string) (string, error) {
	return c.rdb.Info(ctx, section).Result()
}

func itoa(i int64) string {
	if i == 0 {
		return "0"
	}
	var b [20]byte
	pos := len(b)
	neg := i < 0
	if neg {
		i = -i
	}
	for i > 0 {
		pos--
		b[pos] = byte('0' + i%10)
		i /= 10
	}
	if neg {
		pos--
		b[pos] = '-'
	}
	return string(b[pos:])
}
