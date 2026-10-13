#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$ROOT_DIR/server"
ADMIN_DIR="$ROOT_DIR/admin"
AIR_PID=""
ADMIN_PID=""
ADMIN_PORT="${ADMIN_PORT:-5666}"
FORCE_MODE=0

# --- Windows 适配（Git Bash / MSYS / Cygwin）---
# Windows 上请在 Git Bash 中运行本脚本；自动切换：
# air 用 .air.windows.toml（无 Unix 环境变量前缀 + .exe 产物）、端口探测用 netstat、杀进程用 taskkill。
IS_WINDOWS=0
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
esac
EXE=""
[ "$IS_WINDOWS" = "1" ] && EXE=".exe"

# --- 穿云内网穿透（可选）---
# 变量与 chuanyun_* 函数都在这个文件里；调用时机仍在本脚本下面的原位置。
# 必须早于 dev.project.sh 的 source：下游挂载点里要用 chuanyun_up / chuanyun_slug。
. "$ROOT_DIR/scripts/dev-chuanyun.sh"

usage() {
    echo -e "${CYAN}用法: ./dev.sh [--force|-f]${NC}"
    echo ""
    echo "  默认:        端口被占用时自动改用空闲端口启动 (不影响其他项目)"
    echo "  --force, -f  杀死占用后端/前端开发端口的进程，坚持使用配置端口"
    echo "  --no-chuanyun 本次不接入穿云内网穿透 (等价 CHUANYUN=0)"
    echo "  --help, -h   显示帮助"
    echo ""
    echo "  仓库根存在 dev.project.sh 时会一并启动下游扩展服务"
    echo ""
    echo "  Windows 用户请在 Git Bash 中运行（随 Git for Windows 附带），"
    echo "  脚本会自动改用 .air.windows.toml / netstat / taskkill"
    exit "${1:-0}"
}

for arg in "$@"; do
    case "$arg" in
        -f|--force) FORCE_MODE=1 ;;
        --no-chuanyun) CHUANYUN_ENABLED=0 ;;
        -h|--help|help) usage 0 ;;
        *)
            echo -e "${RED}未知参数: $arg${NC}"
            usage 1
            ;;
    esac
done

# 从 config.yaml 读取后端端口（唯一来源）
CONFIG_FILE="$SERVER_DIR/config.yaml"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}config.yaml 不存在，请从 config.yaml.example 复制一份${NC}"
    exit 1
fi
SERVER_PORT=$(grep -E '^\s*port:' "$CONFIG_FILE" | head -1 | awk '{print $2}')
SERVER_PORT=${SERVER_PORT:-8080}

get_port_pids() {
    local port="$1"

    if command -v lsof &>/dev/null; then
        lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true
        return 0
    fi

    # Windows(Git Bash) 没有 lsof，用系统 netstat 解析监听 PID
    # 行格式: TCP    0.0.0.0:8080    0.0.0.0:0    LISTENING    1234
    if [ "$IS_WINDOWS" = "1" ] && command -v netstat &>/dev/null; then
        netstat -ano -p tcp 2>/dev/null \
            | awk -v p=":$port" '$1 == "TCP" && $4 == "LISTENING" && substr($2, length($2) - length(p) + 1) == p {print $5}' \
            | sort -u || true
    fi
}

# 跨平台杀单个进程：Windows 用 taskkill（Git Bash 的 kill 杀不动原生 Windows 进程）
kill_pid() {
    local pid="$1" force="$2"

    if [ "$IS_WINDOWS" = "1" ]; then
        taskkill //PID "$pid" //F >/dev/null 2>&1 || true
    elif [ "$force" = "1" ]; then
        kill -9 "$pid" 2>/dev/null || true
    else
        kill "$pid" 2>/dev/null || true
    fi
}

collect_kill_pids_for_port() {
    local port="$1"
    local pid ppid parent_cmd

    for pid in $(get_port_pids "$port"); do
        echo "$pid"

        # Git Bash 的 ps 看不到原生 Windows 进程树，跳过父进程(air)探测
        [ "$IS_WINDOWS" = "1" ] && continue

        ppid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
        [ -z "$ppid" ] && continue
        [ "$ppid" = "1" ] && continue
        [ "$ppid" = "$$" ] && continue

        parent_cmd=$(ps -p "$ppid" -o command= 2>/dev/null || true)
        case "$parent_cmd" in
            *"/air"*|*" air"*|*"air "*) echo "$ppid" ;;
        esac
    done | sort -u
}

format_pids() {
    tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

print_processes() {
    local pids="$1"
    local pid cmd port_info

    for pid in $pids; do
        if command -v lsof &>/dev/null; then
            port_info=$(lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR == 2 {print $1 " " $2 " " $9}' || true)
            if [ -n "$port_info" ]; then
                echo -e "        $port_info"
                continue
            fi
        fi

        cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
        if [ -n "$cmd" ]; then
            echo -e "        PID $pid: $cmd"
        else
            echo -e "        PID $pid"
        fi
    done
}

kill_port_listeners() {
    local port="$1"
    local label="$2"
    local pids
    local remaining

    pids=$(collect_kill_pids_for_port "$port" | format_pids)
    [ -z "$pids" ] && return 0

    echo -e "${YELLOW}${label} 端口 ${port} 被占用，强制模式将停止以下进程:${NC}"
    print_processes "$pids"

    for pid in $pids; do
        kill_pid "$pid" 0
    done
    sleep 1

    remaining=$(collect_kill_pids_for_port "$port" | format_pids)
    if [ -n "$remaining" ]; then
        echo -e "${YELLOW}      进程仍未退出，强制结束: $remaining${NC}"
        for pid in $remaining; do
            kill_pid "$pid" 1
        done
        sleep 1
    fi

    remaining=$(get_port_pids "$port" | format_pids)
    if [ -n "$remaining" ]; then
        echo -e "${RED}无法释放 ${label} 端口 ${port}: $remaining${NC}"
        exit 1
    fi

    echo -e "${GREEN}      ${label} 端口 ${port} 已释放${NC}"
}

port_in_use() {
    local port="$1"
    [ -n "$(get_port_pids "$port")" ]
}

# 本次启动已分配出去的端口。多个服务(含 dev.project.sh 扩展服务)依次 resolve_port 时，
# 先解析的服务可能尚未真正 LISTEN，仅靠 lsof 探测会把同一端口分给两个服务
CLAIMED_PORTS=""

port_claimed() {
    case " $CLAIMED_PORTS " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

find_free_port() {
    local port="$1"
    local limit=$((port + 100))

    while [ "$port" -le "$limit" ]; do
        if ! port_claimed "$port" && ! port_in_use "$port"; then
            echo "$port"
            return 0
        fi
        port=$((port + 1))
    done
    return 1
}

# 解析最终使用的端口，结果写入 RESOLVED_PORT：
#   默认模式  端口被占用 -> 自动挑选空闲端口
#   强制模式  端口被占用 -> 杀死占用进程，坚持使用配置端口
RESOLVED_PORT=""
resolve_port() {
    local port="$1"
    local label="$2"
    local pids free_port

    RESOLVED_PORT="$port"
    pids=$(get_port_pids "$port" | format_pids)

    if [ -z "$pids" ] && ! port_claimed "$port"; then
        CLAIMED_PORTS="$CLAIMED_PORTS $port"
        return 0
    fi

    if [ -n "$pids" ] && [ "$FORCE_MODE" = "1" ]; then
        kill_port_listeners "$port" "$label"
        CLAIMED_PORTS="$CLAIMED_PORTS $port"
        return 0
    fi

    if [ -n "$pids" ]; then
        echo -e "${YELLOW}${label} 端口 ${port} 已被占用:${NC}"
        print_processes "$pids"
    else
        echo -e "${YELLOW}${label} 端口 ${port} 与本次启动的其他服务冲突${NC}"
    fi

    if ! free_port=$(find_free_port $((port + 1))); then
        echo -e "${RED}未找到空闲的${label}端口 (从 ${port} 起已尝试 100 个)${NC}"
        echo -e "${YELLOW}可使用 ./dev.sh --force / make dev-force 强制释放配置端口${NC}"
        exit 1
    fi

    RESOLVED_PORT="$free_port"
    CLAIMED_PORTS="$CLAIMED_PORTS $free_port"
    echo -e "${GREEN}      自动改用空闲端口 ${free_port} (如需固定端口: ./dev.sh --force)${NC}"
}

# 杀掉整棵进程树：pnpm 是多层包装，vite/server 是孙进程，
# 只杀直接子进程会在非交互(kill)场景下留下孤儿监听进程。
# 必须先收集完整棵树再统一 kill——边杀边遍历时上层先退出，
# 下层会被过继给 PID 1，pgrep -P 就找不到了
collect_tree() {
    local p
    echo "$1"
    for p in $(pgrep -P "$1" 2>/dev/null); do
        collect_tree "$p"
    done
}

kill_tree() {
    local pids

    # Windows: Git Bash 的 pgrep/kill 既看不到也杀不动原生进程树，
    # 用 taskkill //T 让系统连同子进程(server.exe / node)一起结束
    if [ "$IS_WINDOWS" = "1" ]; then
        taskkill //PID "$1" //T //F >/dev/null 2>&1 || true
        return 0
    fi

    pids=$(collect_tree "$1" | tr '\n' ' ')
    [ -n "$pids" ] && kill $pids 2>/dev/null
    return 0
}


CLEANED=0
cleanup() {
    # Ctrl+C 和 EXIT 都会进来，只清理一次
    [ "$CLEANED" = "1" ] && return 0
    CLEANED=1
    echo ""
    echo -e "${YELLOW}正在关闭服务...${NC}"
    chuanyun_down
    [ -n "$AIR_PID" ] && kill_tree "$AIR_PID" && echo -e "${GREEN}后端已停止${NC}"
    [ -n "$ADMIN_PID" ] && kill_tree "$ADMIN_PID" && echo -e "${GREEN}前端已停止${NC}"
    type project_dev_stop &>/dev/null && project_dev_stop
    command -v pkill &>/dev/null && pkill -P $$ 2>/dev/null || true

    # Windows 下杀 bash 作业不一定连带结束原生子进程，按本次已分配的端口兜底清一遍
    # (CLAIMED_PORTS 覆盖后端/前端及 dev.project.sh 扩展服务)
    if [ "$IS_WINDOWS" = "1" ]; then
        local p pid
        for p in $CLAIMED_PORTS; do
            for pid in $(get_port_pids "$p"); do
                kill_pid "$pid" 1
            done
        done
    fi
    return 0
}

# EXIT 也要挂：脚本因 set -e 中途退出（比如后端起来后 pnpm install 失败）时同样收尾，
# 否则已启动的 air 和已登记的隧道会留成孤儿，下次启动只会看到端口被占自动漂移
trap 'cleanup; exit 0' SIGINT SIGTERM
trap cleanup EXIT

# --- 自动启用 pre-push 钩子 ---
# 这是已有下游拿到钩子的途径：它们不会再跑一次 create-base，也未必记得执行 make hooks。
# 只在没人设过 core.hooksPath 时才设（不覆盖别人已有的 husky/lefthook），
# 关掉用 git config base.prepush off，或 git config --unset core.hooksPath。
if [ -f "$ROOT_DIR/.githooks/pre-push" ] \
   && [ -z "$(git -C "$ROOT_DIR" config --get core.hooksPath 2>/dev/null)" ] \
   && [ "$(git -C "$ROOT_DIR" config --get base.prepush 2>/dev/null)" != "off" ]; then
    if git -C "$ROOT_DIR" config core.hooksPath .githooks 2>/dev/null; then
        echo -e "${GREEN}已启用 pre-push 检查${NC}（push 前按改动路径自动验证；关闭: git config base.prepush off）"
    fi
fi

# --- 下游挂载点: dev.project.sh (基底不包含此文件、永不创建，下游按需新增) ---
# 在仓库根新增 dev.project.sh 即可挂载额外开发服务，可实现三个函数:
#   project_dev_start  后端/前端启动完成后调用: 用 resolve_port 解析端口
#                      (自动处理占用/强制模式/与已分配端口去重)，后台启动服务并记下 PID
#   project_dev_stop   Ctrl+C 清理时调用: 用 kill_tree <PID> 停掉自己启动的服务
#   project_dev_info   启动汇总里追加打印服务地址行
#
# ⚠️ 启动时机：**要给后端进程注入环境变量的服务，别放 project_dev_start**——
# 本文件在此处 source，而 project_dev_start 是在后端 air 起来之后才调用的，
# 那时再 export 后端已经看不到了（export 只影响之后 fork 的子进程）。这类服务
# 直接写在 dev.project.sh 的顶层（源载即执行）：那时 resolve_port / kill_tree
# 等助手已就绪，唯独后端端口尚未解析（在本段之后），需要它的服务才留给
# project_dev_start。
if [ -f "$ROOT_DIR/dev.project.sh" ]; then
    source "$ROOT_DIR/dev.project.sh"
fi

echo -e "${CYAN}==============================${NC}"
echo -e "${CYAN}   Admin 后台管理系统 - DEV   ${NC}"
echo -e "${CYAN}==============================${NC}"
echo ""

# chuanyun.toml：先读出 project（隧道名前缀要用），再建 connects。
# connects 会占住本地端口，所以必须早于 resolve_port，后面才会自动避开
if [ "$CHUANYUN_ENABLED" = "1" ] && [ -f "$CHUANYUN_TOML" ]; then
    CHUANYUN_PROJECT=$(chuanyun_toml_records | awk -F"$(printf '\t')" '$1 == "project" { print $2; exit }')
    chuanyun_connects_up
fi

resolve_port "$SERVER_PORT" "后端"
SERVER_PORT="$RESOLVED_PORT"
resolve_port "$ADMIN_PORT" "前端"
ADMIN_PORT="$RESOLVED_PORT"

# 后端 config.Load 支持 SERVER_PORT 环境变量覆盖 config.yaml，
# air 启动的服务进程会继承该变量，自动换端口才能生效
export SERVER_PORT

# 穿云接入要在启动后端之前完成：CHUANYUN_PUBLIC_URL 得先 export 出去，
# air 之后 fork 的后端进程才拿得到（业务代码可用它拼微信/支付回调地址）
if [ "$CHUANYUN_ENABLED" = "1" ]; then
    CHUANYUN_WEB_TUNNEL="$(chuanyun_slug)-admin"
    # 这里不再先 DELETE 上次的前端隧道：DELETE 会把用户在客户端给它设的访问口令
    # 一起删掉。穿云 0.1.11 起插件的 POST 是幂等的，端口变了会自动挪过去、口令保留。
    chuanyun_track "$CHUANYUN_WEB_TUNNEL"           # 插件建的隧道也由 dev.sh 负责关掉
    chuanyun_up "$(chuanyun_slug)-api" "$SERVER_PORT"
    CHUANYUN_PUBLIC_URL="$CHUANYUN_LAST_URL"
    chuanyun_tunnels_up
    export CHUANYUN_NAME="$CHUANYUN_WEB_TUNNEL"     # 前端隧道名，vite 插件读它
else
    export CHUANYUN=0                                # 让 vite 插件一并跳过
fi
export CHUANYUN_PUBLIC_URL

# --- 检查 air ---
# go env GOPATH 在 Windows 返回反斜杠路径，统一成正斜杠供 bash 使用
GOPATH_DIR="$(go env GOPATH | tr '\\' '/')"
AIR_BIN="$GOPATH_DIR/bin/air$EXE"
if [ ! -f "$AIR_BIN" ]; then
    echo -e "${YELLOW}安装 air (Go 热更新工具)...${NC}"
    go install github.com/air-verse/air@latest
fi

# --- 后端 (air 热更新) ---
echo -e "${YELLOW}[1/2] 启动后端 - air 热更新 (http://localhost:${SERVER_PORT})${NC}"
cd "$SERVER_DIR"

if [ ! -f go.sum ]; then
    go mod tidy
fi

# generate swagger docs（docs 已随仓库提交，此步只为保持与代码同步；失败不影响启动）
# swag 每次要刷 600+ 行流水账（每个生成的类型一行 "Generating x"，每个它读不懂的
# 第三方类型一行 "TypeSpecDef is nil"），把「route ... declared multiple times」
# 这类真该处理的警告冲得看不见。这里只滤掉流水账——不用 swag 自己的 -q，那个把
# 警告和报错也一并吞了。
SWAG_NOISE='Generating |TypeSpecDef is nil|Generate swagger docs|Generate general API Info|create (docs\.go|swagger\.json|swagger\.yaml) at '
# 有 make 就走 make swagger，和 scripts/check.sh 同一个理由：下游可能改过 swagger 目标
# （多生成一份文档、加 --tags 把两份分开），这里写死 swag 命令会生成出和 CI 不一样的
# docs，每次 ./dev.sh 都把工作区改脏。Windows 的 Git Bash 不带 make，退回直接调 swag。
# swag 版本与 Makefile、CI 保持一致：不同版本的生成物有差异，CI 的 docs 时效检查会误报。
# --parseDependencyLevel 3 让 swag 解析 module cache 里 base-kit 的 handler 注解（框架层已搬到那边），
# --packagePrefix 限定只扫本模块和 kit，不扫 fiber/gorm，快 3 倍。
# 用 go run 而不是 go install，省掉"装没装、装的哪个版本"的分歧（首次编译后有缓存）。
# 注意：两条路都不加 GOWORK=off——make kit-dev 时开发者就是想看本地 kit 的接口文档。
# 但那份 docs 别提交：CI 用 go.mod 钉死的版本重新生成后比对，会直接拦下。
SWAG_CMD=(go run github.com/swaggo/swag/cmd/swag@v1.16.6)
if command -v make >/dev/null 2>&1; then
    SWAG_RUN=(make -C "$ROOT_DIR" --no-print-directory swagger)
else
    echo -e "${YELLOW}      未找到 make，直接调用 swag（若你定制过 swagger 目标，请装 make 或手动生成）${NC}"
    SWAG_RUN=("${SWAG_CMD[@]}" init -g main.go -o docs --parseDependencyLevel 3 --packagePrefix base,github.com/leivorn/base-kit)
fi
echo -e "${YELLOW}      生成 Swagger 文档...${NC}"
SWAG_LOG=$(mktemp)
if "${SWAG_RUN[@]}" >"$SWAG_LOG" 2>&1; then
    grep -vE "$SWAG_NOISE" "$SWAG_LOG" | sed 's/^/      /' || true
    echo -e "${GREEN}      Swagger 文档已生成${NC}"
else
    # 失败时不过滤：报错往往就藏在被滤掉的那类行的上下文里
    echo -e "${YELLOW}      Swagger 生成失败（不影响启动，继续用仓库内已有 docs）:${NC}"
    tail -20 "$SWAG_LOG" | sed 's/^/      /'
    # swag 中途失败可能把 docs/ 写坏（docs.go 缺失会让 go build 编译不过、air 起不来），从 git 恢复。
    # 下游 make swagger 可能生成好几份（docs/open/docs.go 同样被 import），所以看 docs/ 下有没有已提交的文件不见了
    if [ ! -f docs/docs.go ] || [ -n "$(git ls-files --deleted -- docs 2>/dev/null)" ]; then
        echo -e "${YELLOW}      docs/ 下有生成物缺失，从 git 恢复 docs/ ...${NC}"
        git checkout -- docs 2>/dev/null || true
    fi
fi
rm -f "$SWAG_LOG"

# Windows 用专用配置：.air.toml 的 build cmd 带 Unix 内联环境变量前缀(CGO_LDFLAGS=-w)，
# PowerShell/cmd 不支持该语法，且产物需要 .exe 后缀
if [ "$IS_WINDOWS" = "1" ]; then
    "$AIR_BIN" -c .air.windows.toml &
else
    "$AIR_BIN" &
fi
AIR_PID=$!
sleep 3

if ! kill -0 "$AIR_PID" 2>/dev/null; then
    echo -e "${RED}后端启动失败！${NC}"
    exit 1
fi
echo -e "${GREEN}      后端启动成功 (air PID: $AIR_PID)${NC}"

# --- 前端 ---
echo -e "${YELLOW}[2/2] 启动前端 (http://localhost:${ADMIN_PORT})${NC}"
cd "$ADMIN_DIR"

if [ ! -d node_modules ]; then
    echo -e "${YELLOW}      安装前端依赖...${NC}"
    pnpm install --no-frozen-lockfile
fi

# 端口通过 VITE_ADMIN_PORT 传递：pnpm 多层转发会把 `-- --port` 吞成位置参数，
# vite 收不到 --port，因此改用环境变量（见 apps/web-antd/vite.config.mts）
VITE_API_PORT=$SERVER_PORT VITE_ADMIN_PORT=$ADMIN_PORT pnpm dev:antd &
ADMIN_PID=$!
sleep 3

# --- 下游扩展服务 (dev.project.sh) ---
if type project_dev_start &>/dev/null; then
    project_dev_start
fi

echo ""
echo -e "${GREEN}==============================${NC}"
echo -e "${GREEN}   全部服务已启动！${NC}"
echo -e "${GREEN}==============================${NC}"
echo ""
echo -e "  前端:    ${CYAN}http://localhost:${ADMIN_PORT}${NC}"
echo -e "  后端:    ${CYAN}http://localhost:${SERVER_PORT}${NC}"
echo -e "  Swagger: ${CYAN}http://localhost:${SERVER_PORT}/swagger/index.html${NC}"
if [ -n "$CHUANYUN_PUBLIC_URL" ]; then
echo -e "  公网:    ${CYAN}${CHUANYUN_PUBLIC_URL}${NC} (穿云 -> 后端 ${SERVER_PORT})"
fi
if [ -n "$CHUANYUN_EXTRA_INFO" ]; then
printf "%b" "${CYAN}${CHUANYUN_EXTRA_INFO}${NC}"
fi
if type project_dev_info &>/dev/null; then
    project_dev_info
fi
echo ""
echo -e "  默认账号: ${YELLOW}super / 123456${NC}"
echo ""
echo -e "${YELLOW}后端文件修改后自动重新编译 (air 热更新)${NC}"
echo -e "${YELLOW}按 Ctrl+C 停止所有服务${NC}"

wait
