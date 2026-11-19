ALTER TABLE local_admins
 ALTER COLUMN totp_ciphertext DROP NOT NULL,
 ALTER COLUMN last_totp_step DROP NOT NULL,
 ADD CONSTRAINT local_admin_totp_pair CHECK ((totp_ciphertext IS NULL) = (last_totp_step IS NULL));

-- 旧版本签发的会话均已验证动态码或恢复码。
ALTER TABLE local_admin_sessions ADD COLUMN second_factor_verified boolean NOT NULL DEFAULT true;
ALTER TABLE local_admin_sessions ALTER COLUMN second_factor_verified SET DEFAULT false;
