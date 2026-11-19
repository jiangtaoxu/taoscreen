CREATE TABLE users (
 id uuid PRIMARY KEY,
 email text NOT NULL UNIQUE,
 password_hash text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE devices (
 user_id uuid NOT NULL REFERENCES users(id),
 id uuid NOT NULL,
 name text NOT NULL,
 PRIMARY KEY(user_id,id)
);
CREATE TABLE sessions (
 id uuid PRIMARY KEY,
 user_id uuid NOT NULL,
 device_id uuid NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz NOT NULL,
 revoked_at timestamptz,
 FOREIGN KEY(user_id,device_id) REFERENCES devices(user_id,id)
);
CREATE INDEX sessions_user ON sessions(user_id,created_at);
CREATE TABLE session_tokens (
 hash text PRIMARY KEY,
 session_id uuid NOT NULL REFERENCES sessions(id),
 kind text NOT NULL CHECK(kind IN ('access','refresh')),
 expires_at timestamptz NOT NULL,
 used_at timestamptz
);
