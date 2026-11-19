package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
	"golang.org/x/term"
	"taoscreen.local/server/internal/config"
	"taoscreen.local/server/internal/database"
	"taoscreen.local/server/internal/httpapi"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	if e := run(); e != nil {
		slog.Error("服务退出", "error", e)
		os.Exit(1)
	}
}
func run() error {
	command := "serve"
	if len(os.Args) > 1 {
		command = os.Args[1]
	}
	if command == "healthcheck" {
		client := http.Client{Timeout: 4 * time.Second}
		addr := os.Getenv("HEALTHCHECK_URL")
		if addr == "" {
			addr = "http://127.0.0.1:8080/health/ready"
		}
		resp, e := client.Get(addr)
		if e != nil {
			return e
		}
		defer resp.Body.Close()
		if resp.StatusCode != 200 {
			return fmt.Errorf("服务未就绪: %d", resp.StatusCode)
		}
		return nil
	}
	if command == "migrate" {
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()
		url := os.Getenv("MIGRATION_DATABASE_URL")
		if url == "" {
			return errors.New("缺少 MIGRATION_DATABASE_URL")
		}
		db, e := database.Open(ctx, url)
		if e != nil {
			return errors.New("迁移数据库连接失败")
		}
		defer db.Close()
		if e = database.Migrate(ctx, db); e != nil {
			return e
		}
		slog.Info("数据库迁移完成")
		return nil
	}
	switch command {
	case "serve":
	case "create-user", "create-admin", "reset-admin":
		if len(os.Args) != 3 {
			return fmt.Errorf("用法: server %s <邮箱>", command)
		}
	default:
		return errors.New("可用命令: serve、migrate、create-user、create-admin、reset-admin、healthcheck")
	}
	cfg, e := config.Load()
	if e != nil {
		return e
	}
	if command == "create-user" && !cfg.Auth.PasswordLogin {
		return errors.New("请先启用邮箱密码登录")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	db, e := database.Open(ctx, cfg.DatabaseURL)
	if e != nil {
		return errors.New("应用数据库连接失败")
	}
	defer db.Close()
	if e = database.Check(ctx, db); e != nil {
		return e
	}
	opts, e := redis.ParseURL(cfg.RedisURL)
	if e != nil {
		return errors.New("Redis URL 无效")
	}
	rc := redis.NewClient(opts)
	defer rc.Close()
	api := httpapi.New(cfg, db, rc)
	if command == "create-admin" || command == "reset-admin" {
		return provisionAdmin(api, os.Args[2], command == "reset-admin")
	}
	if command == "create-user" {
		var password string
		if term.IsTerminal(int(os.Stdin.Fd())) {
			password, e = readTerminalPassword("输入本地账号密码（至少 12 个字符）：")
		} else {
			var input []byte
			input, e = io.ReadAll(io.LimitReader(os.Stdin, 259))
			password = strings.TrimSuffix(strings.TrimSuffix(string(input), "\n"), "\r")
		}
		if e != nil {
			return e
		}
		createCtx, createCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer createCancel()
		id, e := api.CreateUser(createCtx, os.Args[2], password)
		if e != nil {
			return e
		}
		fmt.Println(id)
		return nil
	}
	if e = rc.Ping(ctx).Err(); e != nil {
		return errors.New("Redis 连接失败")
	}
	srv := &http.Server{Addr: cfg.Addr, Handler: api.Handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 5 * time.Minute, WriteTimeout: 5 * time.Minute, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 * 1024}
	stop, stopCancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stopCancel()
	result := make(chan error, 1)
	go func() {
		slog.Info("API 已启动", "addr", cfg.Addr, "environment", cfg.Env)
		result <- srv.ListenAndServe()
	}()
	select {
	case e = <-result:
		if !errors.Is(e, http.ErrServerClosed) {
			return e
		}
	case <-stop.Done():
		shutdown, c := context.WithTimeout(context.Background(), 30*time.Second)
		defer c()
		if e = srv.Shutdown(shutdown); e != nil {
			return e
		}
	}
	return nil
}
