// Package store 是数据层在本项目里的挂载点。
//
// 真正的数据层实现在 github.com/leivorn/base-kit/store：连接、迁移、基底种子数据都在那边。
// 本包只提供两样东西：
//   - 把 project.go 里登记的模型和种子数据交给 kit（ProjectModels / ProjectSeed）
//   - 转发 v2.0.0 之前本包对外的符号（DB、IsUniqueViolation）和 project.go 用到的
//     syncSeedMenu、refreshRoleMenus，让老代码一个字都不用改
//
// 正因为本包还在，basekit-migrate 不会改写 base/internal/store 的 import。
// kit 里 store 的其余能力（SyncSeedMenus、RemoveLegacySeedMenus 等）没有转发，
// 需要时直接 import kit：`kitstore "github.com/leivorn/base-kit/store"`。
package store

import (
	adminmodel "github.com/leivorn/base-kit/model/admin"
	kitstore "github.com/leivorn/base-kit/store"

	"gorm.io/gorm"
)

// DB 指向 kit 打开的同一个连接，在 ProjectSeed 执行前由 kit 赋值。
// 只在 projectSeed 及其之后的运行期可用（HTTP 请求进来时早已就绪）。
var DB *gorm.DB

// IsUniqueViolation 判断错误是否为唯一索引冲突，转调 kit 的实现。
// v2.0.0 之前它就在本包里，业务代码里到处是 store.IsUniqueViolation(err)。
func IsUniqueViolation(err error) bool {
	return kitstore.IsUniqueViolation(err)
}

// ProjectModels 返回 project.go 里登记的下游模型，交给 kit 一起 AutoMigrate。
func ProjectModels() []any {
	return projectModels
}

// ProjectSeed 由 kit 在基底种子数据之后调用。
func ProjectSeed(db *gorm.DB) {
	DB = db
	projectSeed()
}

// syncSeedMenu / refreshRoleMenus 是 project.go 文档里提到的助手，转调 kit 的实现。
// 保留这两个未导出的名字，是为了让下游已经写好的 projectSeed 函数体一个字都不用改。
func syncSeedMenu(menu adminmodel.Menu, parentName string) (adminmodel.Menu, bool) {
	return kitstore.SyncSeedMenu(menu, parentName)
}

func refreshRoleMenus() {
	kitstore.RefreshRoleMenus()
}
