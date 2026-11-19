CREATE TABLE local_admins (
 id uuid PRIMARY KEY,
 email text NOT NULL UNIQUE,
 password_hash text NOT NULL,
 totp_ciphertext bytea NOT NULL,
 last_totp_step bigint NOT NULL
);

CREATE TABLE local_admin_recovery_codes (
 admin_id uuid NOT NULL REFERENCES local_admins(id) ON DELETE CASCADE,
 hash text NOT NULL,
 PRIMARY KEY (admin_id, hash)
);

CREATE TABLE local_admin_sessions (
 hash text PRIMARY KEY,
 admin_id uuid NOT NULL REFERENCES local_admins(id) ON DELETE CASCADE,
 expires_at timestamptz NOT NULL
);
CREATE INDEX local_admin_sessions_admin ON local_admin_sessions(admin_id, expires_at);
