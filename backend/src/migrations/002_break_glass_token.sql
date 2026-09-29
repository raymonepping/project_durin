-- migrations/002_break_glass_token.sql
-- Adds access_token_hash column to break_glass_requests so that the
-- one-time-use break-glass token can be validated without storing the
-- raw token in the database.  The plaintext token is only returned once
-- (in the approve response) and is never persisted.

ALTER TABLE break_glass_requests
  ADD COLUMN IF NOT EXISTS access_token_hash VARCHAR(64);

-- Index for fast token lookup (constant-time is handled in application code)
CREATE INDEX IF NOT EXISTS bg_token_hash_idx
  ON break_glass_requests(access_token_hash)
  WHERE access_token_hash IS NOT NULL;
