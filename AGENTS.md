# AGENTS.md

**本文件是 AI 协作约定的唯一来源**，作用范围为整个仓库。`CLAUDE.md` 只有一行 `@AGENTS.md`（Claude Code 的导入语法），Cursor / Codex 等直接读本文件——规则只写在这里，不再维护多份副本。

## 项目概览

这是一个后台管理系统：

- 后端：`server/`，Go Fiber v2 + GORM + JWT + Swagger/OpenAPI；权限为菜单权限码 RBAC。
- **后端框架层是外部依赖**：配置、鉴权、权限码、数据层与整套系统管理模块在 `github.com/leivorn/base-kit`（本地开发副本约定放在仓库同级目录 `../base-kit`）。`server/` 只剩 `main.go`（装配）、两个挂载点和业务代码。
- 前端：`admin/`，Vben Admin v5 + Vue 3 + TypeScript + Ant Design Vue + Vite + Pinia + Tailwind CSS。
- 前端应用主路径：`admin/apps/web-antd/src/`。
- 后端管理接口前缀：`/admin`。
- 前端开发代理：`/api` 会被 Vite 改写到后端 `/admin`，见 `admin/apps/web-antd/vite.config.mts`。
- 本仓库是统一基底（base）：下游项目以 git clone 派生并持续 merge 吸收基底更新，见「基底与下游项目」一节；多个项目可能发布到同一台服务器，改 `dev.sh`、`deploy.sh` 时必须保持多项目共存能力（端口自动切换、按 `PROJECT_NAME` 隔离部署）。

## 基底与下游项目

本仓库是统一基底，地址 `https://github.com/leivorn/base`。新项目从基底克隆派生，之后持续用 git merge 吸收基底的 bug 修复与新功能。

身份判断：`git remote -v` 中 origin 指向 `leivorn/base` 时是基底本体；存在名为 `base` 的 remote 时是下游项目。本文件其余规则两种身份通用，下游项目额外遵守「下游开发纪律」。

### 新项目初始化（下游 bootstrap）

用户新开项目并指定使用本基底时，**优先用脚手架**，它会完成克隆、配置生成、依赖安装和首个提交：

```bash
go run github.com/leivorn/base/tools/create-base@latest <项目名> --origin <新项目仓库地址>
```

脚手架不可用时手工创建（等价）。禁止「删 `.git` 重新 init」或纯文件拷贝——那会切断与基底的共同历史，之后无法正常 merge：

```bash
git clone --no-tags -o base https://github.com/leivorn/base.git <项目名>
cd <项目名>
git remote add origin <新项目自己的仓库地址>   # 用户未提供则先跳过
git branch --unset-upstream                    # 否则 git push 推向基底
git push -u origin main
```

`--no-tags` 不能省：基底的 `v*` 标签会和下游自己的版本号撞车（`make sync-base` 会把它们拉到 `base/v*` 命名空间）。

手工创建后按项目补本地配置（已 gitignore，不会与基底冲突）：复制 `server/config.yaml.example` 为 `server/config.yaml` 并把 `jwt.secret` 换成随机值（生产模式会拒绝占位值）；部署前创建 `.deploy.env`（`PROJECT_NAME` 必填）；前端 `admin/apps/web-antd/.env` 的 `VITE_APP_NAMESPACE` 要按项目改（同域名下多个后台共用 namespace 会互相覆盖登录态）。

### 下游开发纪律

按后续 `make sync-base` 的合并成本，把文件分为两类：

**后端框架层不在仓库里，改不了也不用改**：配置、鉴权、权限码、数据层、系统管理模块（用户/角色/菜单/部门/配置/操作日志）都在 `github.com/leivorn/base-kit`。修 bug 或加通用功能到 kit 仓库提，下游 `go get github.com/leivorn/base-kit@latest` 就拿到，不再产生 merge 冲突。

kit 提供的扩展点（够用就别 fork）：

- 加接口：`basekit.Options.Routes`（业务路由）；**覆盖 kit 的某个接口**用 `PreRoutes`，Fiber 先注册先匹配。`PreRoutes` 排在 kit 的 `/admin` 中间件前面，覆盖的接口要自己挂 `JWTAuth` / `PermissionAuth` / `OperationLog`，否则不用登录就能调。
- 加模型/种子：`Options.Models` / `Options.Seed`，也就是两个挂载点文件。
- 给基底表加列：扩展结构**只声明表名、主键和新列**，登记到 `Options.Models`。不要嵌入 `adminmodel.User`——嵌入会把 `Roles` many2many 带过来，往共享的 `user_roles` 加一列 `<结构名>_id`，通过嵌入结构写入时 `user_id` 为 NULL，kit 按 `user_id` 查角色会静默失效（kit 的 `store/embed_test.go` 锁定了这个约束）。
- 读自己的配置段：`config.LoadExtra(&myCfg)`。
- 起常驻后台任务（投递 worker、定时扫描）：在 `Routes` 里用 `basekit.Go(app, fn)`，**不要** `go fn(context.Background())`。`app.Shutdown()` 时 ctx 取消并等任务返回；Background 起的任务永远不停，`store.DB` 又是包级变量，测试里每次 `NewApp` 都叠一份并转去读写新库（下游真实案例：回调 worker 叠了 7 份，每条回调发两遍，CI 时好时坏）。只要 ctx 时用 `basekit.AppContext(app)`。

**仍需谨慎修改的核心文件：**

- `admin/` 的 vben 框架部分：`packages/`、`internal/` 等封装层。
- `server/main.go`：装配代码，基底会跟着 kit 的 API 演进而改。
- `server/go.mod`：仅限制 **module 名必须保持 `base`**（唯一硬性禁令）——改名会让全部 import 路径与基底 diverge，之后每次 merge 大面积冲突。**新增依赖不受限**，见下。

**其余文件下游可自由修改**（工程脚手架和文档本来就该项目化）：

- `AGENTS.md` / `README.md`——改成项目自己的说明（`CLAUDE.md` 只有一行 `@AGENTS.md`，不用动）。
- `dev.sh`、`deploy.sh`、`Makefile`、`.gitignore`、`.github/`、`scripts/`、各类 `*.example` 配置模板；直接改允许，但想完全避开同步冲突，优先用下面的脚本挂载点扩展。
- 前端业务区 `admin/apps/web-antd/src/`（views、api、`router/routes/modules/`、locales、adapter 微调）。
- 后端业务代码：在 `server/internal/` 下按 model/dto/service/handler/validator 分层新增文件，路由注册在 `router/project.go`。
- `server/go.mod` / `go.sum` 新增依赖：下游按业务需要 `go get` 即可（module 名不动就行）；sync-base 冲突时保留双方依赖行、跑一次 `go mod tidy`。前端 `package.json` 加依赖同理。

**六个下游挂载点，基底承诺永不修改**（Go 挂载点在基底中保持空实现；其余挂载点基底不包含、由下游按需新增），下游可任意编辑且同步永不冲突。这个承诺由 `make check-hooks`（`scripts/check-hooks.sh`，按 blob id 冻结）在基底 CI 中强制：

- `server/internal/router/project.go`：注册下游业务路由；`/admin` 下的路由**不要再挂** JWT/权限码/操作日志中间件（照做每个写操作记两条日志，见「公共层」）；需要权限码的路由用 `middleware.RegisterRoutePermissions` 登记（示例见 kit 的 `middleware/permission.go` 中该函数的注释与 README「权限说明」），只需登录的用 `RegisterAuthenticatedRoutes`。
- `server/internal/store/project.go`：登记下游模型（并入 AutoMigrate）与业务种子数据。
- `dev.project.sh`（仓库根，可选）：`./dev.sh` 自动加载，挂载额外本地开发服务。实现 `project_dev_start` / `project_dev_stop` / `project_dev_info` 三个函数，端口用脚本提供的 `resolve_port` 解析（自动处理占用与 `--force`）。
- `deploy.project.sh`（仓库根，可选）：`./deploy.sh` 自动加载，挂载额外部署目标。声明 `PROJECT_DEPLOY_TARGETS="xxx ..."` 并实现 `project_deploy_<目标>` 函数；扩展目标可单独部署（`./deploy.sh <目标>`），`all` 模式在 server/admin 之后一并执行，可复用 `ssh_run` / `scp_to` / `ensure_systemd_unit` / `restart_remote_service` 等助手。
- `Makefile.project`（仓库根，可选）：`Makefile` 用 `-include` 加载。下游自己的 make 目标写这里，**不要再往 Makefile 本体加**（两边都在文件末尾追加必冲突）。目标带 `## 说明` 注释会自动出现在 `make help`；把目标名写进 `PROJECT_CHECKS` 就会并入 `make check`：

  ```make
  PROJECT_CHECKS = check-agent
  check-agent:  ## 编译边缘 Agent
  	@cd agent && go build ./...
  ```

- `.github/workflows/project.yml`（可选）：下游自己的 CI job 写这里，**不要再改 `ci.yml`**——它现在只是一层薄调用，改了就会每次同步都冲突。自带工具链准备，不要从 ci.yml 引用：

  ```yaml
  name: project
  on: { push: { branches: [main] }, pull_request: }
  jobs:
    agent:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v7
        - uses: actions/setup-go@v7
          with: { go-version-file: server/go.mod, cache-dependency-path: server/go.sum }
        - run: make check-agent
  ```

### CI 怎么跑的

`ci.yml` 只做分发：下游调用基底发布的 `leivorn/base/.github/workflows/checks.yml@ci-v1`，基底本体调用本提交里的同一个文件。好处是**修 CI 不再需要下游先 `make sync-base`**——基底改完 `checks.yml` 并前移 `ci-v1`，所有下游下一次推送就用上了。

`checks.yml` 保持极薄：只装工具链，检查内容全在 `scripts/check.sh` 里，而 `check.sh` 是随 merge 走的，所以下游停在哪个基底版本，跑的就是那个版本的检查语义，移动标签不会把新语义强加给旧下游。

本地跑的就是 CI 跑的：`make check`（= 后端 + 前端 + 脚本），或 `make check-backend` / `make typecheck` 单跑。`make hooks` 启用 `.githooks/pre-push`，push 前按改动路径自动挑检查（`server/` 跑后端，`admin/` 只跑类型检查）；跳过用 `git push --no-verify`、`BASE_SKIP_HOOKS=1` 或 `git config base.prepush off`。

组织若限制了 "Allow select actions" 导致远程调用被拒，把 `ci.yml` 里那行 `uses:` 换成 `./.github/workflows/checks.yml`（该文件本来就随 merge 继承了）。

### 新增额外服务（如前台站点 `web/`）

下游要在 server/admin 之外再加一个服务（Nuxt 前台、任务进程、第三方回调网关等）时，**不要改 `dev.sh` / `deploy.sh` 本体**，用两个脚本挂载点，同步永不冲突：

1. **本地开发**：仓库根新增 `dev.project.sh`，实现三个函数。dev.sh 会 source 它并在合适时机调用，其中这些助手可以直接用：
   - `resolve_port <端口> <名称>`：解析端口，结果在 `RESOLVED_PORT`（自动处理占用、`--force`、与本次已分配端口去重）。**必须用它**，不要自己写死端口，否则同机多项目会互相抢。
   - `chuanyun_up <隧道名> <端口>`：建公网隧道，地址在 `CHUANYUN_LAST_URL`（穿云没开就是空字符串）。隧道名用 `$(chuanyun_slug)-xxx` 保证按项目区分；dev.sh 退出时统一关掉（不删，用户设的口令保留），无需自己清理。
   - `kill_tree <PID>`：在 `project_dev_stop` 里结束自己启动的进程树（pnpm/nuxt 都是多层包装，`kill` 单个 PID 杀不干净）。
   - 现成变量：`ROOT_DIR`、`SERVER_PORT`（已解析）、`RED/GREEN/YELLOW/CYAN/NC` 配色。
2. **部署**：仓库根新增 `deploy.project.sh`，声明 `PROJECT_DEPLOY_TARGETS="web"` 并实现 `project_deploy_web`，可复用 `ssh_run` / `scp_to` / `check_remote_owner` / `ensure_systemd_unit` / `restart_remote_service`。
3. **端口约定**：新服务端口自己定默认值（如 `WEB_PORT="${WEB_PORT:-3000}"`），一律经 `resolve_port` 解析后再用；需要把端口告诉子进程时用环境变量传（`-- --port` 会被 pnpm 吞掉）。
4. **框架拦 Host**：Vite 系（含 Nuxt 的 vite 层）会拒绝陌生 Host，经隧道访问报 `Blocked request`。前端 admin 由 `vite-plugin-chuanyun` 自动处理；自己加的服务需要把隧道域名加进该框架的 `allowedHosts`。

完整可抄的 `dev.project.sh` 示例见 README「新增额外服务」一节。

**穿云隧道的两种写法别混用**：端口由 dev.sh 动态解析的服务（后端、admin、`dev.project.sh` 里启动的），一律在脚本里用 `chuanyun_up` 现取现用；只有 dev.sh **不启动**的固定端口服务才写进 `chuanyun.toml` 的 `[[tunnels]]`（该文件里的 port 按原样使用，不做端口避让）。`[[connects]]` 用来把同事已开的隧道接到本机端口，`local_port` 同样按原样占用；对方隧道的口令写 `chuanyun.local.toml`（gitignore），不写进 `chuanyun.toml`；dev.sh 会在解析自身端口之前先建立 connect，因此后续端口分配会自动避开它。隧道名一律带 `project` 前缀——公网地址不含项目信息，不加前缀跨项目必撞名。

同步基底：`make sync-base` 默认合入基底最新版本标签；`make sync-base VERSION=v1.2.0` 指定版本，`VERSION=main` 合开发中的 main。基底标签在下游以 `base/v*` 命名空间存在，不与下游自己的标签冲突。`make base-version` 查看当前已合入版本（`.base-version`，由基底写入，下游不要手改）与远端最新版本；每个版本的升级步骤见基底 `CHANGELOG.md`。

解决冲突原则：下游没改过的基底文件取基底版本；下游改过的文件（脚本/文档/业务代码）人工合并——保留下游定制、吸收基底修复；拿不准某文件归属时用 `git log base/main -- <文件>` 查它是否来自基底。

### 基底发布（仅基底仓库本体）

- 版本号语义：MAJOR = 同步后需要人工迁移；MINOR = 新功能/可选配置，可能要求重新登录；PATCH = 修 bug/文档。
- 发布前必须在 `CHANGELOG.md` 写好 `## [X.Y.Z] - YYYY-MM-DD` 条目（含三级标题 `### 升级步骤`，无需操作也写一句——`make sync-base` 只打印这一级标题下的内容），否则 `make base-release` 拒绝执行。
- 发布：内容提交先推 main 等 CI 绿 → `make base-release VERSION=vX.Y.Z`（自动跑 `make base-check`：挂载点冻结、后端测试、交叉编译、脚本语法、Swagger 时效、脚手架测试，然后写 `.base-version`、打标签、原子推送）。
- `.base-version` 只由发布流程写入，任何人不要手改。
- **`ci-v1` 是给下游用的移动标签**：`checks.yml` 有变化时 `base-release` 会自动前移它，所有下游立刻用上新的 CI，不需要同步。因此改 `checks.yml` 等于改所有人的 CI——务必先在基底本体跑绿（`checks-base` job 用的就是本提交里的副本）再发布。出事回滚：

  ```bash
  git tag -f ci-v1 <上一个好的 sha> && git push -f origin refs/tags/ci-v1
  ```

- 改动挂载点会被 `make check-hooks` 拦下。确有必要时：改完用 `git hash-object` 更新 `scripts/check-hooks.sh` 里的冻结 id，并在 CHANGELOG 说明（下游会有一处冲突）。
- swag 版本在 Makefile / dev.sh / deploy.sh 三处钉死为 v1.16.6，改版本要三处一起改，否则 docs 时效检查会误报。（CI 不再单独钉：`scripts/check.sh` 走 `make swagger`，用的就是 Makefile 里那份。）

## 工作原则

- 先读现有实现，再改代码。优先复用项目已有的 handler/service/model、Vben adapter、页面结构和命名风格。
- 涉及完整功能时，后端、前端、路由、权限、i18n、Swagger 文档一起处理，不只改单层。
- 保持改动范围小。不要顺手重构无关模块，不要引入未使用依赖。
- 不要提交或依赖本地敏感配置：`.deploy.env`、`.deploy.*.env`、`server/config.yaml`、`server/config.prod.yaml`。
- `server/docs/` 是 Swagger 生成物，但**随仓库提交**：`main.go` import 了 `base/docs`，不提交会让 fresh clone（新下游项目/CI/未装 swag 的同事）直接编译失败（`package base/docs is not in std`）。API 变更后重新生成并与代码一起提交，其余时候不用动。

## 后端开发规则

### 框架层在哪

配置、JWT 鉴权、菜单权限码、数据层、系统管理模块都在 `github.com/leivorn/base-kit`：

| 需求 | 去哪 |
| --- | --- |
| 改框架层的 bug / 加通用能力 | kit 仓库（本地 `../base-kit`），发版后 `go get ...@latest` |
| 同时改 kit 和模板 | `make kit-dev` 生成 `server/go.work` 直接编译本地 kit 源码，改完 `make kit-undev` |
| 加业务接口 | `server/internal/` 新增文件 + `router/project.go` 注册 |
| 覆盖 kit 的某个接口 | `main.go` 里用 `basekit.Options.PreRoutes` 注册同路径，并自己挂 `JWTAuth` / `PermissionAuth` / `OperationLog` |
| 给 sys_users 等基底表加列 | 扩展结构只声明表名/主键/新列，登记到 `Options.Models`（**不要嵌入 kit 的模型**） |
| 起常驻后台任务（worker、定时扫描） | `Routes` 里 `basekit.Go(app, fn)`，随 `app.Shutdown()` 停止（**不要** `context.Background()`） |

`server/go.work` 已 gitignore，`deploy.sh` 用 `GOWORK=off` 编译，发布永远按 `go.mod` 钉死的 kit 版本。

### 分层路径

后台管理功能按下面顺序补齐（这些目录的基底实现已搬到 kit，下面说的是**下游新增业务**的落点）：

1. `server/internal/model/<业务名>/`：GORM 数据模型。
2. `server/internal/dto/<业务名>/`：请求/响应 DTO。
3. `server/internal/validator/<业务名>/`：请求校验。
4. `server/internal/service/<业务名>/`：业务逻辑。
5. `server/internal/handler/<业务名>/`：HTTP handler 和 Swagger 注解。
6. `server/internal/router/project.go`：注册路由，并用 `middleware.RegisterRoutePermissions` 登记权限码。
7. `server/docs/`：API 变更后重新生成 Swagger。

目录名和包名都别用 `admin`：那是 kit 的包名，同一文件里再 import kit 的 `adminmodel`/`admindto` 就得起两个别名；
更麻烦的是把自己的文件放进和 kit 同名的目录后，将来 kit 再接管点什么，同一个 import 路径下就有了两个来源
（下游真实案例：6 个基底目录里 48 个自己的文件，改写后引用方全部 undefined）。

公共层：

- 统一响应在 kit 的 `dto` 包：`dto.Success`、`dto.PageSuccess`、`dto.Fail`、`dto.ParsePage`。
- 中间件在 kit 的 `middleware` 包：JWT、权限码（`PermissionAuth`）、操作日志。kit 把这三个挂在 `/admin` **前缀**上，之后注册的 `/admin/*` 路由（含 `project.go` 里的）自动鉴权、校验权限码、记操作日志，**不要再挂一遍**——base-kit v1.0.3 及之前重复挂会让每个写操作记两条日志、鉴权跑两遍；`/api` 等其他前缀和 `PreRoutes` 里的路由不经过它们，需要时自己挂。`JWTAuth` 每个请求以数据库为准核对用户状态与启用角色（进程内缓存 1 分钟），改用户/角色/密码时必须调 `middleware.InvalidateUserAuthCache`；角色/菜单变更调 `InvalidatePermissionCache`。
- 数据层在 kit 的 `store` 包（`store.DB`、`store.IsUniqueViolation`、种子助手）；模板的 `internal/store` 只是把两个挂载点接给 kit 的垫片。

### API 和响应

- Handler 返回统一响应格式，不直接拼零散 JSON。
- 列表接口使用分页结构：`items` + `total`。
- 管理端业务接口放在 `/admin` 前缀下；公共前台 API 才放 `/api`。
- 新增、修改、删除管理端接口：`/admin` 下自动带 JWT、权限码校验和操作日志（记 POST/PUT/DELETE），不要再挂中间件；必须用 `middleware.RegisterRoutePermissions` 登记权限码（未登记的 `/admin` 路由对非 super 一律 403）。
- id=1 的用户是超级管理员：不受普通权限限制，不出现在普通用户列表，不允许被修改或删除。持有 `super` 角色的用户同样受保护：非 super 操作者不得修改/删除，也不能把 super 角色分配出去。

### Swagger

每个 handler 方法都要有完整 Swagger 注解，至少包括：

- `@Summary`
- `@Tags`
- `@Accept`
- `@Produce`
- `@Param`
- `@Success`
- `@Failure`
- `@Router`

Tags 命名保持业务可读：

- 后台：`认证`、`用户`、`系统管理 - 角色` 等。
- 前台：使用 `前台 - xxx`。

API 变更后在 `server/` 下执行：

```bash
swag init -g main.go -o docs --parseDependencyLevel 3 --packagePrefix base,github.com/leivorn/base-kit
```

### GORM 注意事项

- 文件名使用小写下划线，例如 `operation_log.go`。
- 包名使用小写单词，例如 `admin`、`handler`。
- Go 结构体和方法使用大驼峰。
- 含连续大写缩写的字段必须显式指定列名，例如：
  - `OID` 需要 `gorm:"column:oid"`。
  - `AIPDFPath` 需要 `gorm:"column:ai_pdf_path"`。
- `map[string]any` 做 `Updates` 时，key 必须是数据库列名，也就是 snake_case，不是 Go 字段名。
- 同一字段禁止同时写 `uniqueIndex` 和 `index`（如 `gorm:"uniqueIndex;index"`）：两个未命名标签会生成同名默认索引，同一列被并入一个索引两次，MySQL AutoMigrate 报 `1060 Duplicate column name`；本地 SQLite 不报错，这类问题只在 MySQL 上暴露。`uniqueIndex` 本身就是索引，不要再叠加 `index`。
- 涉及索引/建表的模型改动，上线前用 MySQL 完整启动验证一次，不要只依赖本地 SQLite。
- 角色、用户、配置是物理删除（`Unscoped`，删除时同步清理 `role_menus` / `user_roles`），因为它们的 name/code/username/config_key 带唯一索引，软删行会永久占住键值；菜单、部门保持软删除，删除必须递归处理下级并清理 `role_menus`。列表接口统一用 `dto.ParsePage` 解析分页（pageSize 上限 200），唯一冲突用 `store.IsUniqueViolation` 判断后返回 400。
- SQLite 的 `data.db-wal` / `data.db-shm` 伴生文件**绝不能提交**（`.gitignore` 已用 `server/data.db*` 覆盖）：主库被忽略而 WAL 入库时，fresh clone 只有陈旧 WAL 没有主库，启动直接报 `malformed database schema ... no such table`。下游若发现这两个文件已被跟踪，用 `git rm --cached server/data.db-shm server/data.db-wal` 移除。
- 改 model 字段后需要完整重启后端，让 AutoMigrate 重新执行；只看前端热更新不够。
- 复杂写操作使用事务，查询注意预加载和索引，避免 N+1。

## 前端开发规则

### Vben 文档查阅

- 本项目是 Vben Admin v5。遇到 table、form、drawer、modal、menu、permission、route 等通用后台组件，不要凭记忆手写，先查 Vben 文档。
- 用户指定的入口是 `https://doc.vvbin.cn/`。如果该站点提示当前页是旧版本并给出 V5 文档入口，继续查 V5 文档 `https://doc.vben.pro/`。
- 常用 V5 组件关键词：`useVbenVxeGrid`、`useVbenForm`、`useVbenDrawer`、`Vben Modal`、`Vben Vxe Table`。
- 查完文档后还要对照本项目 adapter：`#/adapter/vxe-table`、`#/adapter/form`，以仓库内封装为最终落地方式。

### 前端路径

主要目录在 `admin/apps/web-antd/src/`：

- `api/`：接口定义，统一使用 `requestClient`。
- `views/`：页面组件。
- `router/`：路由配置。
- `store/`：Pinia 状态。
- `adapter/`：Vben 表单、表格、组件适配器。
- `locales/langs/zh-CN/` 和 `locales/langs/en-US/`：国际化。

系统管理页面优先沿用现有模块结构：

- `list.vue`：列表页，使用 `Page` + `useVbenVxeGrid`。
- `data.ts`：列配置、搜索表单 schema、表单 schema。
- `modules/form.vue`：新增/编辑抽屉，使用 `useVbenDrawer` + `useVbenForm`。

### 组件使用

- 列表和表格优先使用 `useVbenVxeGrid`，从 `#/adapter/vxe-table` 导入。
- 表单优先使用 `useVbenForm`，从 `#/adapter/form` 导入。
- 新增/编辑侧滑层优先使用 `useVbenDrawer`，从 `@vben/common-ui` 导入。
- 页面容器优先使用 `Page`。
- 图标优先使用项目已有图标包，例如 `@vben/icons`。
- 不要直接手写一套 Ant Design Vue Table/Form/Drawer，除非 Vben 封装明确无法满足，并在代码中保持局部化。

### 表格和表单约定

- 表格请求放在 `gridOptions.proxyConfig.ajax.query` 中，分页参数映射为后端需要的 `page`、`pageSize`。
- 表格行主键设置 `rowConfig.keyField`。
- 工具栏使用 `toolbarConfig`，自定义按钮放到 `#toolbar-tools` 或文档约定插槽。
- 搜索表单配置放在 `formOptions.schema`，常用 schema 写在同模块 `data.ts`。
- `destroyOnClose: true` 的 Drawer 中，新增和编辑打开时都必须调用 `formApi.setValues()` 或等效初始化逻辑，否则 Select、Switch 等组件容易残留旧值。
- 下拉选项优先通过 `formApi.updateSchema()` 更新 `options`，不要随意绕过项目现有 adapter。
- Switch 映射后端整数时设置 `checkedValue: 1`、`unCheckedValue: 0`。

### API、路由和 i18n

- API 方法写在 `admin/apps/web-antd/src/api/`，按业务模块分文件并补 TypeScript namespace/types。
- `requestClient` 已经配置 `codeField: code`、`dataField: data`、`successCode: 0`，后端响应要与其匹配。
- 前端调用路径写逻辑路径，例如 `/system/user/list`；开发时 Vite 会把 `/api` 代理到后端 `/admin`。
- 所有页面可见文案都要走 `$t()`，并同步维护 `zh-CN` 和 `en-US` 翻译。
- 新页面需要同步路由、菜单和权限编码；动态菜单数据由后端 `/admin/menu/all` 提供。

## 验证命令

**首选 `make check`**——它和 CI 跑的是同一份逻辑（`scripts/check.sh`），本地绿了 CI 就绿：

```bash
make check            # 后端 + 前端 + 脚本语法，等同 CI
make check-backend    # 仅后端：vet / test / 交叉编译 / Swagger 生成
make typecheck        # 仅前端类型检查（约 20 秒，改 .vue/.ts 后先跑这个）
make check-frontend   # 前端类型检查 + 构建
make check-scripts    # 仅 shell 语法（改 dev.sh / deploy.sh / scripts/ 后）
```

`make hooks` 启用后，push 前会按改动路径自动挑上面的检查（`./dev.sh` 启动时也会自动启用）。

改检查内容请改 `scripts/check.sh`，不要在 Makefile 或 ci.yml 里另加命令——三处
共用一份逻辑正是它存在的意义。

单独跑某一步时（少用）：

```bash
cd server && go test ./...
make swagger          # 重新生成 server/docs
cd admin && pnpm dev:antd
```

如果只是文档或规则变更，至少检查 Markdown 内容和路径是否与当前仓库一致。

## 常用命令

```bash
# 新建项目（脚手架）
go run github.com/leivorn/base/tools/create-base@latest <项目名> --origin <仓库地址>

# 校验（与 CI 同一份逻辑）
make check                      # 后端 + 前端 + 脚本
make typecheck                  # 仅前端类型检查（最快）
make hooks                      # 启用 pre-push 钩子

# 基底版本
make sync-base                  # 下游合入基底最新版本（合并前会打印升级步骤）
make sync-base VERSION=main     # 合入开发中的 main
make sync-base YES=1            # 跨大版本时确认继续
make base-version               # 查看已合入版本与远端最新版本
make base-release VERSION=v1.1.0  # 仅基底本体：发布新版本

# 一键启动前后端（默认：端口被占用时自动改用空闲端口，可同机多项目并行）
./dev.sh          # 等价 make dev
./dev.sh --force  # 杀死占用进程、坚持用配置端口，等价 make dev-force
# Windows 在 Git Bash 中运行：脚本自动改用 server/.air.windows.toml / netstat / taskkill
# 装了穿云客户端时自动给前后端各建一条公网隧道（没装/没开则静默跳过）；
# 仓库根有 chuanyun.toml 时额外应用其 [[tunnels]]/[[connects]]（见 chuanyun.toml.example）；
# 关闭用 ./dev.sh --no-chuanyun。后端可读 CHUANYUN_PUBLIC_URL 拼回调地址

# 后端开发
cd server
go run main.go
air

# 前端开发
cd admin
pnpm install
pnpm dev:antd
pnpm build:antd

# 部署（读取 .deploy.env，PROJECT_NAME 必填；详见 README「多项目发布」）
./deploy.sh [server|admin|all|<扩展目标>]  # 等价 make release / release-server / release-admin / release-<目标>
./deploy.sh all <项目名>              # 同仓库多目标：读取 .deploy.<项目名>.env
./deploy.sh --list                    # 列出已有部署配置
```

## 默认账号

| 账号 | 密码 | 角色 | 权限 |
| --- | --- | --- | --- |
| super | 123456 | super | 所有权限 |
| admin | 123456 | admin | 系统管理 |
| jack | 123456 | user | 仅查看 |

仅开发模式。生产模式只有 `super`（随机初始密码，见首次启动日志），启动时删除 `admin` / `jack`，弱密码一律拒绝登录；
超管进不去时在服务目录执行 `./server reset-password`。后端新建/重置密码要满足 kit 的口令策略（≥8 位、字母+数字、
非常见弱口令、不含用户名），测试里别再用 `123456` 建用户。

## 端口

- 后端 API：`http://localhost:8080`
- 前端开发：`http://localhost:5666`
- Swagger UI：`http://localhost:8080/swagger/index.html`，仅开发环境使用
- 以上为配置默认值。`./dev.sh` 发现端口被占用会自动换用空闲端口，实际端口以启动输出为准；后端端口支持环境变量 `SERVER_PORT` 覆盖 `config.yaml`，前端端口由 dev.sh 通过 `VITE_ADMIN_PORT` 传入。
- 同机可能有其他项目（如 laitui）的 dev 正在 8080/5666/3000 上运行；杀端口进程前先用 `ps -p <pid> -o command=` 确认进程属于本项目。
