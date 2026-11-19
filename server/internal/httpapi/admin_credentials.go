package httpapi

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base32"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/pquerna/otp"
	"github.com/pquerna/otp/totp"
)

const adminTOTPStep = 30

func NewAdminAuthenticator(email string) (*otp.Key, error) {
	email, err := normalizeEmail(email)
	if err != nil {
		return nil, err
	}
	return totp.Generate(totp.GenerateOpts{
		Issuer: "TaoScreen Admin", AccountName: email, SecretSize: 20, Period: adminTOTPStep,
	})
}

// Check the current, previous and next step for clock skew. The accepting
// transaction records the matched step so concurrent requests cannot replay it.
func adminCodeStep(code, secret string, now time.Time) (int64, bool) {
	if len(code) != 6 {
		return 0, false
	}
	step := now.Unix() / adminTOTPStep
	for _, candidate := range []int64{step, step - 1, step + 1} {
		valid, _ := totp.ValidateCustom(code, secret, time.Unix(candidate*adminTOTPStep, 0),
			totp.ValidateOpts{Period: adminTOTPStep, Digits: otp.DigitsSix, Algorithm: otp.AlgorithmSHA1})
		if valid {
			return candidate, true
		}
	}
	return 0, false
}

func (s *Server) adminOTPEncryption() (cipher.AEAD, error) {
	block, err := aes.NewCipher(s.Config.Auth.AdminOTPKey)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCMWithRandomNonce(block)
}

// ProvisionAdmin is called by the server operator on an interactive terminal.
func (s *Server) ProvisionAdmin(ctx context.Context, email, password, code string, key *otp.Key, reset bool) ([]string, error) {
	if s.Config.Auth.AdminMode != "local" {
		return nil, errors.New("请先启用本地管理员登录")
	}
	email, err := normalizeEmail(email)
	if err != nil {
		return nil, err
	}
	step, valid := adminCodeStep(code, key.Secret(), time.Now())
	if !valid {
		return nil, errors.New("动态码无效，请检查验证器时间并重新执行命令")
	}
	passwordHash, err := HashPassword(password)
	if err != nil {
		return nil, err
	}
	aead, err := s.adminOTPEncryption()
	if err != nil {
		return nil, err
	}
	secret := aead.Seal(nil, nil, []byte(key.Secret()), []byte(email))
	codes := make([]string, 8)
	encoding := base32.StdEncoding.WithPadding(base32.NoPadding)
	for i := range codes {
		var random [16]byte
		if _, err = rand.Read(random[:]); err != nil {
			return nil, err
		}
		codes[i] = encoding.EncodeToString(random[:])
	}
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	admin := uuid.NewString()
	if reset {
		err = tx.QueryRow(ctx, `UPDATE local_admins SET password_hash=$2,totp_ciphertext=$3,last_totp_step=$4
			WHERE email=$1 RETURNING id::text`, email, passwordHash, secret, step).Scan(&admin)
		if err != nil {
			return nil, errors.New("重置管理员失败，请检查账号和数据库状态")
		}
		if _, err = tx.Exec(ctx, "DELETE FROM local_admin_sessions WHERE admin_id=$1", admin); err != nil {
			return nil, err
		}
		if _, err = tx.Exec(ctx, "DELETE FROM local_admin_recovery_codes WHERE admin_id=$1", admin); err != nil {
			return nil, err
		}
	} else {
		_, err = tx.Exec(ctx, "INSERT INTO local_admins(id,email,password_hash,totp_ciphertext,last_totp_step) VALUES($1,$2,$3,$4,$5)",
			admin, email, passwordHash, secret, step)
		if err != nil {
			var conflict *pgconn.PgError
			if errors.As(err, &conflict) && conflict.Code == "23505" {
				return nil, errors.New("该管理员已存在，可使用 reset-admin 重新绑定")
			}
			return nil, err
		}
	}
	for _, recovery := range codes {
		if _, err = tx.Exec(ctx, "INSERT INTO local_admin_recovery_codes(admin_id,hash) VALUES($1,$2)", admin, recoveryCodeHash(recovery)); err != nil {
			return nil, err
		}
	}
	if err = tx.Commit(ctx); err != nil {
		return nil, err
	}
	return codes, nil
}

func recoveryCodeHash(code string) string {
	return digest([]byte(strings.ToUpper(code)))
}
