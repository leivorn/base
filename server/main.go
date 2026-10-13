package main

import (
	"fmt"

	"base/docs"
	"base/internal/router"
	"base/internal/store"

	basekit "github.com/leivorn/base-kit"
	"github.com/leivorn/base-kit/config"

	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/swagger"
)

// @title Admin 后台管理系统 API
// @version 1.0
// @description 基于 Go Fiber + GORM + JWT 的后台管理系统 API 文档
// @termsOfService http://swagger.io/terms/

// @contact.name API Support
// @contact.email admin@example.com

// @host localhost:8080
// @BasePath /
// @schemes http https

// @securityDefinitions.apikey BearerAuth
// @in header
// @name Authorization
// @description 输入 Bearer {token} 格式的 JWT 令牌

// 框架层（配置、鉴权、权限码、数据层、系统管理模块）在 github.com/leivorn/base-kit，
// 用 go get ...@latest 升级，不再随模板 merge。本文件只负责把项目自己的东西挂上去：
// 模型和种子数据在 internal/store/project.go，业务路由在 internal/router/project.go。
func main() {
	basekit.Run(basekit.Options{
		Models:  store.ProjectModels(),
		Seed:    store.ProjectSeed,
		Routes:  router.Setup,
		Swagger: mountSwagger,
	})
}

// mountSwagger 只在配置 enable_swagger 为 true 时被调用。
// Swagger 生成物属于本项目（docs/ 随仓库提交，main.go import 了它），kit 不依赖 swag。
func mountSwagger(app *fiber.App) {
	docs.SwaggerInfo.Host = fmt.Sprintf("localhost:%d", config.C.Server.Port)
	if config.C.Server.SwaggerTitle != "" {
		docs.SwaggerInfo.Title = config.C.Server.SwaggerTitle
	}
	if config.C.Server.SwaggerDesc != "" {
		docs.SwaggerInfo.Description = config.C.Server.SwaggerDesc
	}
	app.Get("/swagger/*", swagger.HandlerDefault)
}
