package database

import (
	"context"
	"crypto/sha256"
	"embed"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed migrations/*.sql
var migrations embed.FS

func Open(ctx context.Context, url string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		return nil, err
	}
	cfg.MaxConns = 12
	cfg.MinConns = 1
	cfg.MaxConnLifetime = time.Hour
	cfg.ConnConfig.ConnectTimeout = 5 * time.Second
	// 避免配置错误或崩溃客户端长期占用锁。
	cfg.ConnConfig.RuntimeParams["statement_timeout"] = "15000"
	cfg.ConnConfig.RuntimeParams["idle_in_transaction_session_timeout"] = "360000"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	if err = pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	return pool, nil
}

// migration 是 migrations 目录下的一个文件，文件名以三位版本号开头，例如 002_device_links.sql。
type migration struct {
	version  int
	sql      []byte
	checksum string
}

func loadMigrations() ([]migration, error) {
	entries, e := migrations.ReadDir("migrations")
	if e != nil {
		return nil, e
	}
	var out []migration
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasSuffix(name, ".sql") {
			continue
		}
		version, e := strconv.Atoi(strings.SplitN(name, "_", 2)[0])
		if e != nil || version <= 0 {
			return nil, fmt.Errorf("迁移文件名无效：%s", name)
		}
		sql, e := migrations.ReadFile("migrations/" + name)
		if e != nil {
			return nil, e
		}
		out = append(out, migration{version, sql, fmt.Sprintf("%x", sha256.Sum256(sql))})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].version < out[j].version })
	for i, m := range out {
		if m.version != i+1 {
			return nil, fmt.Errorf("迁移版本必须从 1 连续编号，缺少版本 %d", i+1)
		}
	}
	return out, nil
}

// Migrate 按版本顺序执行尚未执行的迁移。已执行的迁移校验和必须一致，绝不改写已有 schema。
func Migrate(ctx context.Context, p *pgxpool.Pool) error {
	all, e := loadMigrations()
	if e != nil {
		return e
	}
	tx, e := p.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	if _, e = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(928614307)"); e != nil {
		return e
	}
	if _, e = tx.Exec(ctx, "CREATE TABLE IF NOT EXISTS schema_migrations (version integer PRIMARY KEY, checksum text NOT NULL)"); e != nil {
		return e
	}
	applied, e := appliedMigrations(ctx, tx)
	if e != nil {
		return e
	}
	if e = verifyApplied(applied, all); e != nil {
		return e
	}
	for _, m := range all[len(applied):] {
		if _, e = tx.Exec(ctx, string(m.sql)); e != nil {
			return fmt.Errorf("执行迁移 %d 失败：%w", m.version, e)
		}
		if _, e = tx.Exec(ctx, "INSERT INTO schema_migrations VALUES($1,$2)", m.version, m.checksum); e != nil {
			return e
		}
	}
	return tx.Commit(ctx)
}

type queryer interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

func appliedMigrations(ctx context.Context, q queryer) (map[int]string, error) {
	rows, e := q.Query(ctx, "SELECT version,checksum FROM schema_migrations")
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	applied := map[int]string{}
	for rows.Next() {
		var v int
		var checksum string
		if e = rows.Scan(&v, &checksum); e != nil {
			return nil, e
		}
		applied[v] = checksum
	}
	return applied, rows.Err()
}

// 已执行的迁移必须是代码里迁移的前缀，且内容未被改动。
func verifyApplied(applied map[int]string, all []migration) error {
	if len(applied) > len(all) {
		return fmt.Errorf("数据库迁移版本高于当前程序，拒绝运行")
	}
	for i := 0; i < len(applied); i++ {
		if applied[all[i].version] != all[i].checksum {
			return fmt.Errorf("迁移版本或校验和不匹配，拒绝改写已有 schema")
		}
	}
	return nil
}

func Check(ctx context.Context, p *pgxpool.Pool) error {
	all, e := loadMigrations()
	if e != nil {
		return e
	}
	applied, e := appliedMigrations(ctx, p)
	if e != nil {
		return e
	}
	if len(applied) != len(all) || verifyApplied(applied, all) != nil {
		return fmt.Errorf("数据库迁移不匹配")
	}
	return nil
}
