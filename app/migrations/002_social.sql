-- Adds what makes this a social app rather than a guestbook: threaded replies
-- and likes. Idempotent, like 001, so re-running against an existing database
-- is safe.

-- A reply is just a post with a parent. Self-referencing FK with CASCADE, so
-- deleting a post takes its whole reply thread with it.
ALTER TABLE posts
  ADD COLUMN IF NOT EXISTS parent_id BIGINT REFERENCES posts(id) ON DELETE CASCADE;

-- Thread view: every reply to one post, oldest first.
CREATE INDEX IF NOT EXISTS posts_parent_idx ON posts (parent_id, created_at);

-- The main feed shows only top-level posts. A PARTIAL index stores only rows
-- matching the WHERE clause, so it stays small no matter how many replies
-- accumulate.
CREATE INDEX IF NOT EXISTS posts_toplevel_idx
  ON posts (created_at DESC) WHERE parent_id IS NULL;

CREATE TABLE IF NOT EXISTS likes (
    user_id    BIGINT NOT NULL REFERENCES users(id)  ON DELETE CASCADE,
    post_id    BIGINT NOT NULL REFERENCES posts(id)  ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Composite PK: a user can like a post at most once, enforced by the
    -- database rather than by hopeful application code.
    PRIMARY KEY (user_id, post_id)
);

-- The PK above is ordered (user_id, post_id), so it cannot serve a
-- "count likes for this post" query. Hence a second index on post_id.
CREATE INDEX IF NOT EXISTS likes_post_idx ON likes (post_id);

-- Optional profile fields, nullable so existing rows stay valid.
ALTER TABLE users ADD COLUMN IF NOT EXISTS display_name TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS bio          TEXT;
