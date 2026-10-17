#!/usr/bin/env bash
# 校验契约：本地、pre-push 钩子、CI 跑的是同一份逻辑。
#
# 为什么是脚本而不是 Makefile 目标：
#   1. Git for Windows 不带 make，pre-push 钩子在 Windows 上调不了 make；
#   2. Makefile 是下游的冲突文件（phonehz 在里面加了 81 行），冲突解错就把目标丢了；
#   3. 这是个新文件，下游没人改过，sync-base 时必然原样到达——CI 里那份瘦 ci.yml
#      和它要调用的东西保证在同一次 merge 里到齐。
# Makefile 里的 check* 目标只是一行转发，给人用。
#
# 用法: bash scripts/check.sh <子命令> [选项]
#   backend [--no-swagger]  后端: vet / test / 交叉编译 / Swagger 生成
#   frontend [--fast]       前端: typecheck (--fast 时跳过 build)
#   scripts                 所有 shell 脚本的语法检查 + 脚本的离线行为测试
#   base                    仅基底本体: 挂载点冻结 + 脚手架测试
#   all                     backend + frontend + scripts
#   pre-push                按改动路径挑选上面的子集（供 .githooks/pre-push 调用）
#
# 注意：写法要兼容 bash 3.2（macOS 自带）与 Git Bash，不能用 declare -A / mapfile。
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# GOWORK=off 全程：本地 make kit-dev 留下的 go.work 会让检查按本地 kit 源码跑，
# 而发布（deploy.sh）永远按 go.mod 钉死的版本，两者必须一致才有意义。
export GOWORK=off

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

step() { echo "${YELLOW}==> $*${NC}"; }
ok()   { echo "${GREEN}$*${NC}"; }
die()  { echo "${RED}$*${NC}" >&2; exit 1; }

# 是否基底仓库本体。CI 里用 GITHUB_REPOSITORY，本地看 origin（与 check-hooks.sh 同一判断）。
is_base() {
    if [ -n "${GITHUB_REPOSITORY:-}" ]; then
        [ "$GITHUB_REPOSITORY" = "leivorn/base" ]
        return
    fi
    git remote get-url origin 2>/dev/null | grep -Eq 'leivorn/base(\.git)?/?$'
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# 后端
# ---------------------------------------------------------------------------
check_backend() {
    local want_swagger=1
    [ "${1:-}" = "--no-swagger" ] && want_swagger=0

    have go || die "未找到 go"

    step "后端 vet"
    (cd server && go vet ./...)

    step "后端 test"
    (cd server && go test ./...)

    # deploy.sh 用 CGO_ENABLED=0 交叉编译，这里保证纯 Go 依赖没被破坏
    step "后端交叉编译"
    (cd server && CGO_ENABLED=0 go build -o /dev/null .)

    if [ "$want_swagger" = 1 ]; then
        step "Swagger 生成"
        gen_swagger

        # 生成物时效只在基底本体校验。下游的 dev.sh / deploy.sh 每次都会重新生成，
        # 入库那份对它们没有意义，校验时效只会制造与自己代码无关的红灯。
        if is_base; then
            step "Swagger 文档时效"
            git diff --exit-code -- server/docs || \
                die "server/docs 已过期：make swagger 后提交生成物再发布"
        fi
    fi

    ok "后端检查通过"
}

# 重新生成 server/docs。
gen_swagger() {
    if have make; then
        # 优先走 make：下游（phonehz）把 swagger 目标改成了生成两个实例，
        # 走 make 才能让它们的定制自动生效。
        make --no-print-directory swagger
    else
        # Windows 的 Git Bash 不带 make——这正是本脚本不写成 Makefile 目标的首要理由，
        # 所以这里也不能因为缺 make 就失败。降级为直接调同一个钉死版本的 swag；
        # 下游若定制过 swagger 目标，这条降级路径覆盖不到，故给出提示。
        echo "${YELLOW}    未找到 make，直接调用 swag（若你定制过 swagger 目标，请装 make 或手动生成）${NC}"
        (cd server && go run github.com/swaggo/swag/cmd/swag@v1.16.6 init \
            -g main.go -o docs --parseDependencyLevel 3 \
            --packagePrefix base,github.com/leivorn/base-kit)
    fi
}

# 基底本体专用：push 前确认 server/docs 没过期。
# CI 上「Swagger 文档时效」是基底唯一会因 docs 变红的检查，钩子不覆盖它就漏掉了
# 最常见的那类红灯。只在工作区里 docs 干净时做——否则说明开发者手上有尚未提交的
# 生成物，重新生成再还原会毁掉它。
check_swagger_fresh() {
    is_base || return 0
    if ! git diff --quiet -- server/docs; then
        echo "${YELLOW}pre-push: server/docs 有未提交改动，跳过时效检查（记得把生成物一起提交）${NC}"
        return 0
    fi
    step "Swagger 文档时效"
    gen_swagger >/dev/null 2>&1 || {
        echo "${YELLOW}pre-push: Swagger 生成失败，跳过时效检查${NC}"
        return 0
    }
    if ! git diff --quiet -- server/docs; then
        git checkout -- server/docs      # 还原，不把生成物留在工作区
        die "server/docs 已过期：先跑 make swagger 并把生成物一起提交"
    fi
}

# ---------------------------------------------------------------------------
# 前端
# ---------------------------------------------------------------------------
check_frontend() {
    local fast=0
    [ "${1:-}" = "--fast" ] && fast=1

    have pnpm || die "未找到 pnpm"
    # 否则 vue-tsc 会以 "spawn ENOENT" 失败，看不出是没装依赖
    [ -d admin/node_modules ] || die "admin/node_modules 不存在，先执行: cd admin && pnpm install"

    step "前端类型检查"
    (cd admin && pnpm -F @vben/web-antd typecheck)

    if [ "$fast" = 0 ]; then
        step "前端构建"
        (cd admin && pnpm build:antd)
    fi

    ok "前端检查通过"
}

# ---------------------------------------------------------------------------
# 脚本语法 + 离线行为测试
# ---------------------------------------------------------------------------
check_scripts() {
    step "脚本语法"
    # bash -n 一次只检查第一个文件，必须逐个来。
    # 循环体用 if 而不是 [ -f x ] && bash -n x：后者在 set -e 下，最后一次判断为假会让整个脚本退出。
    local f
    for f in dev.sh deploy.sh dev.project.sh deploy.project.sh scripts/*.sh .githooks/*; do
        if [ -f "$f" ]; then
            bash -n "$f" || die "语法错误: $f"
        fi
    done
    ok "脚本语法通过"

    # 测试把 make / go 换成桩、PATH 只留桩目录，这套做法没在 Git Bash 上验证过，
    # 钩子又绝不能因为环境问题挡住 push，所以 Windows 上跳过；CI 和 macOS / Linux 都跑。
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*)
            echo "${YELLOW}    Windows 上跳过脚本离线测试${NC}"
            return 0 ;;
    esac
    step "脚本离线测试"
    bash scripts/deploy-swagger-test.sh || die "deploy.sh 生成 Swagger 的离线测试失败"
    ok "脚本离线测试通过"
}

# ---------------------------------------------------------------------------
# 基底本体专属
# ---------------------------------------------------------------------------
check_base() {
    is_base || die "base 子命令仅在基底仓库本体有意义（下游无需运行）"

    step "挂载点冻结校验"
    bash scripts/check-hooks.sh

    # create-base 的 scaffold_test.go 会把当前仓库自己的文件拷成一份假基底再跑一遍
    # 脚手架，其中一步要把 VITE_APP_TITLE=Admin 替换成新项目名。下游按约定必须改掉
    # 那个值，于是替换匹配到 0 处——这一步在任何下游都是必然失败，且与下游代码无关。
    step "脚手架 vet / test"
    (cd tools/create-base && go vet ./... && go test ./...)

    ok "基底检查通过"
}

# ---------------------------------------------------------------------------
# pre-push：按本次推送的改动路径挑检查
# ---------------------------------------------------------------------------
# 注意：检查的是当前工作区，不是将要 push 的那些提交。两者在「改完没提交就 push」
# 时会有出入，属于可接受的取舍——钩子的目的是快速拦住明显的红灯，不是复现 CI。
pre_push() {
    local remote="${1:-origin}"
    local pref
    pref=$(git config --get base.prepush || echo "")
    if [ "$pref" = off ] || [ -n "${BASE_SKIP_HOOKS:-}" ]; then
        echo "pre-push: 已按配置跳过"
        return 0
    fi

    local zero='^0\{40,\}$'
    local ranges="" lref lsha rref rsha base
    while read -r lref lsha rref rsha; do
        [ -n "${lsha:-}" ] || continue
        # 本地侧全 0 = 删除远端分支，没有内容要检查
        echo "$lsha" | grep -q "$zero" && continue
        if echo "${rsha:-}" | grep -q "$zero" || [ -z "${rsha:-}" ]; then
            # 远端还没有这个分支：与远端主干的 merge-base 起算
            base=$(git merge-base "$lsha" "refs/remotes/$remote/main" 2>/dev/null || echo "")
        else
            base="$rsha"
        fi
        # 远端 sha 未必存在于本地（对方 force push 过、或本地没 fetch）。
        # 不校验的话 git diff 会以 fatal: bad object 失败，set -e 直接把 push 拦下——
        # 而钩子绝不能因为环境问题挡住 push（见下面的工具缺失处理）。
        if [ -n "$base" ] && git rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1; then
            ranges="$ranges $base..$lsha"
        else
            ranges="ALL"
            break
        fi
    done

    local files
    if [ "$ranges" = "ALL" ]; then
        # 算不出比较基准（force push 之后等），保守起见全跑
        files="ALL"
    elif [ -z "${ranges// /}" ]; then
        # 没有可检查的 ref：删除远端分支，或根本没有输入
        echo "pre-push: 无需检查（删除分支或无提交）"
        return 0
    else
        files=$(for r in $ranges; do git diff --name-only "$r"; done | sort -u)
        [ -n "$files" ] || { echo "pre-push: 无文件改动"; return 0; }
    fi

    local do_backend=0 do_frontend=0 do_scripts=0
    if [ "$files" = "ALL" ]; then
        do_backend=1; do_frontend=1; do_scripts=1
    else
        echo "$files" | grep -q '^server/'                        && do_backend=1
        echo "$files" | grep -q '^admin/'                         && do_frontend=1
        echo "$files" | grep -Eq '\.sh$|^\.githooks/|^Makefile'   && do_scripts=1
        # 根目录的构建/CI 文件影响两边
        if echo "$files" | grep -Eq '^(Makefile|\.github/|scripts/)'; then
            do_backend=1; do_frontend=1
        fi
    fi

    # 工具缺失（GUI 客户端的 PATH 常常不全）只警告不拦：钩子绝不能因为环境问题挡住 push。
    if [ "$do_backend" = 1 ] && ! have go; then
        echo "${YELLOW}pre-push: 未找到 go，跳过后端检查${NC}"; do_backend=0
    fi
    if [ "$do_frontend" = 1 ] && ! have pnpm; then
        echo "${YELLOW}pre-push: 未找到 pnpm，跳过前端检查${NC}"; do_frontend=0
    fi

    if [ "$do_backend$do_frontend$do_scripts" = "000" ]; then
        echo "pre-push: 本次改动无需检查"
        return 0
    fi

    echo "${YELLOW}pre-push 检查中（跳过: git push --no-verify / BASE_SKIP_HOOKS=1 / git config base.prepush off）${NC}"
    # --no-swagger：生成会弄脏工作区。基底本体改由 check_swagger_fresh 单独核对并还原。
    [ "$do_scripts" = 1 ]  && check_scripts
    if [ "$do_backend" = 1 ]; then
        check_backend --no-swagger
        check_swagger_fresh
    fi
    if [ "$do_frontend" = 1 ]; then
        if [ "$pref" = full ]; then check_frontend; else check_frontend --fast; fi
    fi
    ok "pre-push 检查通过"
}

# ---------------------------------------------------------------------------
case "${1:-}" in
    backend)  shift; check_backend "$@" ;;
    frontend) shift; check_frontend "$@" ;;
    scripts)  check_scripts ;;
    base)     check_base ;;
    all)      check_scripts; check_backend; check_frontend ;;
    pre-push) shift; pre_push "$@" ;;
    *)
        echo "用法: bash scripts/check.sh {backend|frontend|scripts|base|all|pre-push}" >&2
        exit 1 ;;
esac
