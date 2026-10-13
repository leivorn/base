package main

import (
	"encoding/json"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"base/internal/router"
	"base/internal/store"

	basekit "github.com/leivorn/base-kit"
	"github.com/leivorn/base-kit/config"
	kitstore "github.com/leivorn/base-kit/store"

	"github.com/gofiber/fiber/v2"
)

// TestBootAndLogin 冒烟测试：用临时 sqlite 完整启动一次，跑通登录 → 取用户信息 → 菜单 → Swagger。
//
// 模板本身几乎没有代码了（框架层在 base-kit），这个测试守的是「装配」这件事：
// kit 的版本升级后接口还对得上、种子数据还建得出来、docs 还是本项目的。
func TestBootAndLogin(t *testing.T) {
	dir := t.TempDir()
	cfg := config.Config{}
	cfg.Server.Port = 0
	cfg.Server.Mode = "development"
	cfg.Server.EnableSwagger = true
	cfg.Server.CorsOrigins = "*"
	cfg.Database.Driver = "sqlite"
	cfg.Database.DSN = filepath.Join(dir, "smoke.db")
	cfg.JWT.Secret = "smoke-test-secret-0123456789abcdefghij"
	cfg.JWT.Expire = time.Hour
	cfg.JWT.RefreshExpire = time.Hour

	app, err := basekit.NewApp(basekit.Options{
		Config:  &cfg,
		Models:  store.ProjectModels(),
		Seed:    store.ProjectSeed,
		Routes:  router.Setup,
		Swagger: mountSwagger,
	})
	if err != nil {
		t.Fatalf("启动: %v", err)
	}
	// Windows 上句柄不放开，t.TempDir() 的清理会失败（dev.sh 支持 Git Bash）
	t.Cleanup(func() {
		if sqlDB, err := kitstore.DB.DB(); err == nil {
			sqlDB.Close()
		}
	})

	// 登录：种子数据里的内置超管
	token := login(t, app, "super", "123456")

	// 带 token 取用户信息
	var info struct {
		Data struct {
			Username string   `json:"username"`
			Roles    []string `json:"roles"`
			HomePath string   `json:"homePath"`
		} `json:"data"`
	}
	decode(t, do(t, app, http.MethodGet, "/admin/user/info", token), &info)
	if info.Data.Username != "super" {
		t.Errorf("用户名 = %q", info.Data.Username)
	}
	if len(info.Data.Roles) == 0 {
		t.Error("super 应有角色")
	}

	// 菜单树：种子数据建好了才有内容
	var menus struct {
		Data []struct {
			Name string `json:"name"`
		} `json:"data"`
	}
	decode(t, do(t, app, http.MethodGet, "/admin/menu/all", token), &menus)
	if len(menus.Data) == 0 {
		t.Fatal("菜单树为空，种子数据没跑起来")
	}

	// 无 token 必须 401，权限中间件挂上了
	if resp := do(t, app, http.MethodGet, "/admin/user/info", ""); resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("无 token 访问 = %d，期望 401", resp.StatusCode)
	}

	// Swagger 挂载的是本项目 docs/，且包含 kit 的路由
	resp := do(t, app, http.MethodGet, "/swagger/doc.json", "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("swagger doc.json = %d", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), "/admin/system/user/list") {
		t.Error("swagger 文档里没有 kit 的路由，检查 make swagger 的 --parseDependencyLevel/--packagePrefix 参数")
	}
}

func login(t *testing.T, app *fiber.App, username, password string) string {
	t.Helper()
	body := strings.NewReader(`{"username":"` + username + `","password":"` + password + `"}`)
	req, _ := http.NewRequest(http.MethodPost, "/admin/auth/login", body)
	req.Header.Set("Content-Type", "application/json")
	resp, err := app.Test(req, 10_000)
	if err != nil {
		t.Fatalf("登录请求: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(resp.Body)
		t.Fatalf("登录 = %d: %s", resp.StatusCode, raw)
	}
	var parsed struct {
		Data struct {
			AccessToken string `json:"accessToken"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		t.Fatalf("解析登录响应: %v", err)
	}
	if parsed.Data.AccessToken == "" {
		t.Fatal("登录未返回 accessToken")
	}
	return parsed.Data.AccessToken
}

func do(t *testing.T, app *fiber.App, method, path, token string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(method, path, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := app.Test(req, 10_000)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	return resp
}

func decode(t *testing.T, resp *http.Response, dst any) {
	t.Helper()
	if resp.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(resp.Body)
		t.Fatalf("状态码 %d: %s", resp.StatusCode, raw)
	}
	if err := json.NewDecoder(resp.Body).Decode(dst); err != nil {
		t.Fatalf("解析响应: %v", err)
	}
}
