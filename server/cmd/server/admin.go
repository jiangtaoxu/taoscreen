package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/boombuler/barcode/qr"
	"github.com/pquerna/otp"
	"golang.org/x/term"
	"taoscreen.local/server/internal/httpapi"
)

func provisionAdmin(api *httpapi.Server, email string, reset bool) error {
	if api.Config.Auth.AdminMode != "local" {
		return errors.New("请先启用本地管理员登录")
	}
	fd := int(os.Stdin.Fd())
	if !term.IsTerminal(fd) || !term.IsTerminal(int(os.Stdout.Fd())) {
		return errors.New("请在交互终端中创建或重置管理员")
	}
	var key *otp.Key
	var err error
	if !api.Config.Auth.AdminTOTPDisabled {
		key, err = httpapi.NewAdminAuthenticator(email)
		if err != nil {
			return err
		}
	}
	password, err := readTerminalPassword("输入管理员密码（至少 12 个字符）：")
	if err != nil {
		return err
	}
	confirmation, err := readTerminalPassword("再次输入密码：")
	if err != nil {
		return err
	}
	if confirmation != password {
		return errors.New("两次输入的密码不一致")
	}
	var code string
	if key != nil {
		fmt.Println("用验证器扫描下方二维码，也可以手工输入绑定密钥。")
		if err = printTerminalQR(key.URL()); err != nil {
			return err
		}
		fmt.Println("绑定密钥（请勿分享）", key.Secret())
		fmt.Fprint(os.Stderr, "输入验证器显示的六位动态码：")
		code, err = bufio.NewReader(os.Stdin).ReadString('\n')
		if err != nil {
			return err
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	codes, err := api.ProvisionAdmin(ctx, email, password, strings.TrimSpace(code), key, reset)
	if err != nil {
		return err
	}
	if len(codes) == 0 {
		fmt.Println("管理员密码已设置。")
		return nil
	}
	fmt.Println("绑定完成。请离线保存以下一次性恢复码。后台登录时请使用下一组动态码。")
	for _, recovery := range codes {
		fmt.Println(recovery)
	}
	return nil
}

func readTerminalPassword(prompt string) (string, error) {
	fmt.Fprint(os.Stderr, prompt)
	raw, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Fprintln(os.Stderr)
	return string(raw), err
}

func printTerminalQR(value string) error {
	img, err := qr.Encode(value, qr.M, qr.Auto)
	if err != nil {
		return err
	}
	var output strings.Builder
	bounds := img.Bounds().Inset(-4)
	colors := [2][2]string{
		{"\x1b[30;40m▀", "\x1b[30;47m▀"},
		{"\x1b[37;40m▀", "\x1b[37;47m▀"},
	}
	white := func(x, y int) int {
		point := img.Bounds()
		if x < point.Min.X || x >= point.Max.X || y < point.Min.Y || y >= point.Max.Y {
			return 1
		}
		r, _, _, _ := img.At(x, y).RGBA()
		if r == 0 {
			return 0
		}
		return 1
	}
	for y := bounds.Min.Y; y < bounds.Max.Y; y += 2 {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			output.WriteString(colors[white(x, y)][white(x, y+1)])
		}
		output.WriteString("\x1b[0m\n")
	}
	_, err = fmt.Print(output.String())
	return err
}
