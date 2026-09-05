-- Schema for the mini social app.
-- Applied by the api process on startup (idempotent).

CREATE TABLE IF NOT EXISTS users (
    id            BIGSERIAL PRIMARY KEY,
    username      TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS posts (
    id         BIGSERIAL PRIMARY KEY,
    user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    body       TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 280),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Timeline queries read posts by author, newest first.
CREATE INDEX IF NOT EXISTS posts_user_created_idx ON posts (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS posts_created_idx      ON posts (created_at DESC);

CREATE TABLE IF NOT EXISTS follows (
    follower_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    followee_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (follower_id, followee_id),
    CHECK (follower_id <> followee_id)
);

-- The worker needs "who follows this author" to invalidate their caches.
CREATE INDEX IF NOT EXISTS follows_followee_idx ON follows (followee_id);
