package httpapi

import (
	"context"
	"errors"
	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5"
	"time"
)

const presenceTTL = 70 * time.Second
const closeSessionRevoked websocket.StatusCode = 4001

func (s *Server) sessionActive(ctx context.Context, session string) (bool, error) {
	var ok bool
	e := s.DB.QueryRow(ctx, "SELECT true FROM sessions WHERE id=$1 AND revoked_at IS NULL AND expires_at>now()", session).Scan(&ok)
	if errors.Is(e, pgx.ErrNoRows) {
		return false, nil
	}
	return ok, e
}
