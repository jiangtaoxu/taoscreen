ALTER TABLE users ALTER COLUMN password_hash DROP NOT NULL;
ALTER TABLE users ADD COLUMN display_name text NOT NULL DEFAULT '';
ALTER TABLE users ADD COLUMN email_verified boolean NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN registration_provider text NOT NULL DEFAULT 'password'
 CHECK (registration_provider IN ('password','google','github'));
ALTER TABLE users ADD COLUMN last_login_at timestamptz;

CREATE TABLE auth_identities (
 provider text NOT NULL CHECK (provider IN ('google','github')),
 subject text NOT NULL,
 user_id uuid NOT NULL REFERENCES users(id),
 email text NOT NULL,
 email_verified boolean NOT NULL,
 display_name text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 last_login_at timestamptz,
 PRIMARY KEY(provider,subject),
 UNIQUE(user_id,provider)
);

CREATE TABLE auth_logins (
 ticket_hash text PRIMARY KEY,
 provider text NOT NULL CHECK (provider IN ('google','github')),
 purpose text NOT NULL CHECK (purpose IN ('login','link')),
 target_user uuid REFERENCES users(id),
 target_session uuid REFERENCES sessions(id),
 device_id uuid NOT NULL,
 device_name text NOT NULL,
 client_state text NOT NULL,
 code_challenge text NOT NULL,
 provider_verifier text NOT NULL,
 nonce text NOT NULL,
 browser_hash text,
 callback_used boolean NOT NULL DEFAULT false,
 identity_data jsonb,
 code_hash text UNIQUE,
 expires_at timestamptz NOT NULL,
 CHECK (length(code_challenge)=43),
 CHECK ((purpose='login' AND target_user IS NULL AND target_session IS NULL)
     OR (purpose='link' AND target_user IS NOT NULL AND target_session IS NOT NULL))
);
CREATE INDEX auth_logins_expiry ON auth_logins(expires_at);
