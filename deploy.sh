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
# BUILD_DIR 在解析完项目名后按项目设置 (.build/<项目名>)

# -------------------------------------------------------
# 下游挂载点: deploy.project.sh (基底不包含此文件、永不创建，下游按需新增)
# 在仓库根新增 deploy.project.sh 即可挂载额外部署目标:
#   PROJECT_DEPLOY_TARGETS="agent worker"   声明额外目标名(空格分隔)
#   project_deploy_<目标名>() { ... }        每个目标对应的部署函数
#   project_deploy_info() { ... }            (可选) 部署信息头里追加打印
# 额外目标可单独部署 (./deploy.sh <目标名>)，all 模式在 server/admin 之后依次执行。
# 函数体内可用助手: ssh_run / scp_to / check_remote_owner / mark_remote_owner /
#   ensure_systemd_unit / remote_service_exists / remote_port_in_use /
#   restart_remote_service，以及 TARGET_OS / TARGET_ARCH / BUILD_DIR /
#   PROJECT_NAME / AUTO_RESTART 等变量。
# 注意: 本文件在解析参数前加载，此时 .deploy.env 尚未读入，
#       依赖配置变量的校验要放到 project_deploy_* 函数体内做。
# -------------------------------------------------------
PROJECT_DEPLOY_TARGETS=""
if [ -f "$ROOT_DIR/deploy.project.sh" ]; then
    source "$ROOT_DIR/deploy.project.sh"
fi

is_project_target() {
    local t
    for t in $PROJECT_DEPLOY_TARGETS; do
        [ "$t" = "$1" ] && return 0
    done
    return 1
}

# -------------------------------------------------------
# 使用说明
# -------------------------------------------------------
usage() {
    echo -e "${CYAN}用法: ./deploy.sh [server|admin|all] [项目名]${NC}"
    echo ""
    echo "  server  - 仅部署后端"
    echo "  admin   - 仅部署后台前端"
    echo "  all     - 全量部署 (默认，含下游扩展目标)"
    if [ -n "$PROJECT_DEPLOY_TARGETS" ]; then
        local t
        for t in $PROJECT_DEPLOY_TARGETS; do
            printf '  %-7s - 下游扩展目标 (deploy.project.sh)\n' "$t"
        done
    fi
    echo ""
    echo "  项目名  - 可选。指定后读取 .deploy.<项目名>.env，"
    echo "            用于同一台服务器发布多个项目；不指定读取 .deploy.env"
    echo ""
    echo "  -p, --project <项目名>  同上，显式指定项目"
    echo "  -l, --list              列出已有的部署配置"
    echo ""
    echo "示例:"
    echo "  ./deploy.sh                    # 默认配置全量部署"
    echo "  ./deploy.sh server             # 默认配置仅部署后端"
    echo "  ./deploy.sh all shop           # 使用 .deploy.shop.env 全量部署"
    echo "  ./deploy.sh admin -p blog      # 使用 .deploy.blog.env 部署前端"
    exit 0
}

list_projects() {
    echo -e "${CYAN}可用部署配置:${NC}"
    local found=0 f name
    if [ -f "$ROOT_DIR/.deploy.env" ]; then
        echo "  (默认)        .deploy.env"
        found=1
    fi
    for f in "$ROOT_DIR"/.deploy.*.env; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        name=${name#.deploy.}
        name=${name%.env}
        printf '  %-12s  %s\n' "$name" "$(basename "$f")"
        found=1
    done
    if [ "$found" = "0" ]; then
        echo -e "  ${YELLOW}(暂无，复制 .deploy.env.example 创建)${NC}"
    fi
}

DEPLOY_MODE=""
PROJECT=""
while [ $# -gt 0 ]; do
    case "$1" in
        server|admin|all) DEPLOY_MODE="$1" ;;
        web) DEPLOY_MODE="admin" ;;
        -p|--project)
            shift
            [ -z "${1:-}" ] && { echo -e "${RED}-p/--project 需要指定项目名${NC}"; exit 1; }
            PROJECT="$1"
            ;;
        -l|--list|list) list_projects; exit 0 ;;
        -h|--help|help) usage ;;
        -*) echo -e "${RED}未知参数: $1${NC}"; usage ;;
        *)
            # 下游扩展目标名优先于项目名; 项目名与目标同名时用 -p 指定项目
            if is_project_target "$1"; then
                DEPLOY_MODE="$1"
            elif [ -z "$PROJECT" ]; then
                PROJECT="$1"
            else
                echo -e "${RED}多余参数: $1${NC}"; usage
            fi
            ;;
    esac
    shift
done
DEPLOY_MODE="${DEPLOY_MODE:-all}"

# -------------------------------------------------------
# 加载配置（支持多项目: .deploy.<项目名>.env）
# -------------------------------------------------------
if [ -n "$PROJECT" ]; then
    ENV_FILE="$ROOT_DIR/.deploy.${PROJECT}.env"
    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${RED}缺少项目部署配置文件 .deploy.${PROJECT}.env${NC}"
        echo -e "${YELLOW}请复制 .deploy.env.example 为 .deploy.${PROJECT}.env 并填写实际配置${NC}"
        echo ""
        echo "  cp .deploy.env.example .deploy.${PROJECT}.env"
        echo ""
        list_projects
        exit 1
    fi
else
    ENV_FILE="$ROOT_DIR/.deploy.env"
    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${RED}缺少部署配置文件 .deploy.env${NC}"
        echo -e "${YELLOW}请复制 .deploy.env.example 为 .deploy.env 并填写实际配置${NC}"
        echo ""
        echo "  cp .deploy.env.example .deploy.env"
        exit 1
    fi
fi

source "$ENV_FILE"

# 项目名解析: .deploy.env 的 PROJECT_NAME > 命令行项目名 > 由 SERVICE_NAME 推导。
# 服务名、远程临时文件、本地构建目录都按项目隔离，同一台服务器可发布多个项目。
# 三者都缺时拒绝部署：base 的每份项目拷贝如果都落到同一个默认服务名，
# 后部署的项目会顶掉先部署项目的 systemd 服务
PROJECT_NAME="${PROJECT_NAME:-$PROJECT}"
if [ -z "$PROJECT_NAME" ] && [ -n "${SERVICE_NAME:-}" ]; then
    PROJECT_NAME="${SERVICE_NAME%-server}"
fi
if [ -z "$PROJECT_NAME" ]; then
    echo -e "${RED}缺少项目标识：多个项目发布到同一台服务器时必须能区分项目${NC}"
    echo -e "${YELLOW}请在 $(basename "$ENV_FILE") 中添加一行（改成你的项目名）:${NC}"
    echo ""
    echo "  PROJECT_NAME=shop"
    echo ""
    echo -e "${YELLOW}或设置 SERVICE_NAME；也可用 ./deploy.sh all <项目名> 走 .deploy.<项目名>.env${NC}"
    exit 1
fi

REMOTE_ADMIN_DIR="${REMOTE_ADMIN_DIR:-${REMOTE_WEB_DIR:-}}"
ADMIN_BUILD_CMD="${ADMIN_BUILD_CMD:-${WEB_BUILD_CMD:-pnpm build:antd}}"

for var in SSH_HOST SSH_USER REMOTE_SERVER_DIR REMOTE_ADMIN_DIR; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}配置项 $var 未设置，请检查 .deploy.env${NC}"
        exit 1
    fi
done

# 认证方式二选一：SSH_KEY（私钥文件）优先，否则用 SSH_PASS 口令；都没有就试 ssh-agent
if [ -n "${SSH_KEY:-}" ] && [ ! -f "$SSH_KEY" ]; then
    echo -e "${RED}SSH_KEY 指向的文件不存在: $SSH_KEY${NC}"
    exit 1
fi
if [ -z "${SSH_KEY:-}" ] && [ -z "${SSH_PASS:-}" ]; then
    echo -e "${YELLOW}未设置 SSH_KEY 或 SSH_PASS，将依赖 ssh-agent 中已加载的密钥${NC}"
fi

SSH_PORT="${SSH_PORT:-22}"
AUTO_RESTART="${AUTO_RESTART:-no}"
SERVICE_NAME="${SERVICE_NAME:-${PROJECT_NAME}-server}"
SERVER_BIN_NAME="${SERVER_BIN_NAME:-server}"

# 本地构建目录和远程临时包按项目区分，避免多项目互相覆盖
BUILD_DIR="$ROOT_DIR/.build/${PROJECT_NAME}"
REMOTE_TMP_TAR="/tmp/${PROJECT_NAME}-admin.tar.gz"

# 只有用口令认证时才需要 sshpass
if [ -z "${SSH_KEY:-}" ] && [ -n "${SSH_PASS:-}" ] && ! command -v sshpass &>/dev/null; then
    echo -e "${YELLOW}安装 sshpass...${NC}"
    if [[ "$(uname)" == "Darwin" ]]; then
        brew install hudochenkov/sshpass/sshpass
    else
        sudo apt-get install -y sshpass 2>/dev/null || sudo yum install -y sshpass 2>/dev/null
    fi
fi

# 端口参数不能放进公共 SSH_OPTS：ssh 用 -p，而 scp 的 -p 是"保留时间戳"(不带参数)，
# 端口号会被 scp 当成待上传的本地文件 (scp: stat local "22": No such file)
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# SSH_WRAP 决定怎么认证。口令走 sshpass -e 读环境变量，不用 -p：
# -p 的口令会出现在 ps 的命令行里，同机其他用户看得到。
# 密钥路径用数组单独传，不能拼进 SSH_OPTS：后者是不带引号展开的，
# 含空格的路径（如 ~/My Keys/id_ed25519）会被拆开，ssh 把后半段当成主机名。
SSH_WRAP=()
SSH_KEY_OPTS=()
if [ -n "${SSH_KEY:-}" ]; then
    SSH_KEY_OPTS=(-o BatchMode=yes -i "$SSH_KEY")
elif [ -n "${SSH_PASS:-}" ]; then
    export SSHPASS="$SSH_PASS"
    SSH_WRAP=(sshpass -e)
fi
ssh_run() { ${SSH_WRAP[@]+"${SSH_WRAP[@]}"} ssh $SSH_OPTS ${SSH_KEY_OPTS[@]+"${SSH_KEY_OPTS[@]}"} -p "${SSH_PORT}" "${SSH_USER}@${SSH_HOST}" "$@"; }
scp_to() { ${SSH_WRAP[@]+"${SSH_WRAP[@]}"} scp $SSH_OPTS ${SSH_KEY_OPTS[@]+"${SSH_KEY_OPTS[@]}"} -P "${SSH_PORT}" "$1" "${SSH_USER}@${SSH_HOST}:$2"; }

# -------------------------------------------------------
# 远程目录归属校验：目录内 .deploy-project 记录属主项目，
# 防止两个项目的配置误指向同一个远程目录而互相覆盖
# -------------------------------------------------------
check_remote_owner() {
    local dir="$1" label="$2" owner
    owner=$(ssh_run "cat ${dir}/.deploy-project 2>/dev/null" | tr -d '[:space:]' || true)
    if [ -n "$owner" ] && [ "$owner" != "$PROJECT_NAME" ]; then
        echo -e "${RED}[${label}] 远程目录 ${dir} 属于项目 '${owner}'，当前项目为 '${PROJECT_NAME}'${NC}"
        echo -e "${YELLOW}多项目共用服务器时请为每个项目配置独立的远程目录；${NC}"
        echo -e "${YELLOW}确认目录确实归本项目使用，可删除该目录下的 .deploy-project 后重试${NC}"
        exit 1
    fi
}

mark_remote_owner() {
    ssh_run "echo '${PROJECT_NAME}' > $1/.deploy-project"
}

# -------------------------------------------------------
# 生产配置预检
# 位置刻意排在下面的 SSH 探测之前：config.prod.yaml 缺失时，原先要等到连上服务器、
# 交叉编译完、生成完 Swagger 之后才在 cp 那一步报 "No such file or directory"，
# 首次部署的人完全不知道该建什么文件。本函数不依赖任何远程变量，可以最先跑。
# -------------------------------------------------------
preflight_server_config() {
    local cfg="$SERVER_DIR/config.prod.yaml"
    if [ ! -f "$cfg" ]; then
        echo -e "${RED}缺少生产配置 server/config.prod.yaml${NC}"
        echo -e "${YELLOW}从模板创建并按实际环境填写（该文件已 gitignore，不会入库）:${NC}"
        echo ""
        echo "  cp server/config.prod.yaml.example server/config.prod.yaml"
        echo ""
        exit 1
    fi

    # 非生产模式会种下 admin / jack 两个 123456 的演示账号（kit 只在非生产模式建它们）
    # 行尾允许带注释：模板里这一行本来就跟着说明文字
    if ! grep -Eq '^[[:space:]]*mode:[[:space:]]*"?production"?[[:space:]]*(#.*)?$' "$cfg"; then
        local cur
        cur=$(grep -E '^[[:space:]]*mode:' "$cfg" | head -1 | awk '{print $2}')
        echo -e "${RED}config.prod.yaml 的 mode 是 ${cur:-(未设置)}，不是 production${NC}"
        echo -e "${YELLOW}非生产模式会在线上种下演示账号 admin / jack（密码 123456），并回显内部错误详情。${NC}"
        echo -e "${YELLOW}确认要这样发布，用 DEPLOY_ALLOW_DEV_MODE=1 ./deploy.sh ...${NC}"
        [ "${DEPLOY_ALLOW_DEV_MODE:-}" = "1" ] || exit 1
        echo -e "${YELLOW}        已按 DEPLOY_ALLOW_DEV_MODE=1 继续${NC}"
    fi

    # 后端在生产模式下会拒绝用占位密钥启动，这里提前说清楚，省得等部署完才发现服务起不来
    if grep -q 'change-this-to-a-strong-secret' "$cfg"; then
        echo -e "${RED}config.prod.yaml 的 jwt.secret 还是占位值${NC}"
        echo -e "${YELLOW}生产模式会拒绝启动。换成随机值:${NC}"
        echo ""
        echo "  openssl rand -hex 32"
        echo ""
        exit 1
    fi

    if grep -Eq '^[[:space:]]*enable_swagger:[[:space:]]*true' "$cfg"; then
        echo -e "${YELLOW}提醒: config.prod.yaml 里 enable_swagger: true，接口文档会在公网可见${NC}"
    fi
}
case "$DEPLOY_MODE" in server|all) preflight_server_config ;; esac

# -------------------------------------------------------
# 自动检测远程系统和架构
# -------------------------------------------------------
echo -e "${YELLOW}检测远程服务器系统信息...${NC}"
REMOTE_INFO=$(ssh_run "echo \$(uname -s)_\$(uname -m)")
REMOTE_UNAME_S=$(echo "$REMOTE_INFO" | cut -d'_' -f1)
# -f2- 取第一个下划线之后的全部：x86_64 自带下划线，-f2 会截成 x86 被误判为不支持
REMOTE_UNAME_M=$(echo "$REMOTE_INFO" | cut -d'_' -f2-)

case "$REMOTE_UNAME_S" in
    Linux)   TARGET_OS="linux" ;;
    Darwin)  TARGET_OS="darwin" ;;
    MINGW*|MSYS*|CYGWIN*) TARGET_OS="windows" ;;
    *) echo -e "${RED}不支持的远程系统: $REMOTE_UNAME_S${NC}"; exit 1 ;;
esac

case "$REMOTE_UNAME_M" in
    x86_64|amd64)  TARGET_ARCH="amd64" ;;
    aarch64|arm64)  TARGET_ARCH="arm64" ;;
    armv7l)         TARGET_ARCH="arm" ;;
    *) echo -e "${RED}不支持的架构: $REMOTE_UNAME_M${NC}"; exit 1 ;;
esac

echo -e "${CYAN}==============================${NC}"
echo -e "${CYAN}   Admin 后台管理系统 - 部署   ${NC}"
echo -e "${CYAN}==============================${NC}"
echo ""
echo -e "  项目:       ${YELLOW}${PROJECT_NAME}${NC} (配置: $(basename "$ENV_FILE"))"
echo -e "  部署模式:   ${YELLOW}${DEPLOY_MODE}${NC}"
echo -e "  目标主机:   ${YELLOW}${SSH_USER}@${SSH_HOST}:${SSH_PORT}${NC}"
echo -e "  远程系统:   ${YELLOW}${TARGET_OS}/${TARGET_ARCH}${NC}"
case "$DEPLOY_MODE" in server|all)
echo -e "  后端目录:   ${YELLOW}${REMOTE_SERVER_DIR}${NC}" ;;
esac
case "$DEPLOY_MODE" in admin|all)
echo -e "  前端目录:   ${YELLOW}${REMOTE_ADMIN_DIR}${NC}" ;;
esac
if type project_deploy_info &>/dev/null; then
    project_deploy_info
fi
echo ""

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# -------------------------------------------------------
# 后端端口解析
#   首次部署(服务不存在): 配置端口被占用时从该端口向后找空闲端口启动，
#                         并把本地 config.prod.yaml 回写成实际使用的端口
#   服务已存在:           端口是既定事实(nginx/回调都依赖它)，被其他进程
#                         占用时只提醒、不自动更换，人工处理
# -------------------------------------------------------

remote_service_exists() {
    local svc="${1:-$SERVICE_NAME}"
    ssh_run "systemctl list-unit-files ${svc}.service 2>/dev/null | grep -q ${svc}"
}

remote_port_in_use() {
    ssh_run "ss -tln 2>/dev/null | awk '{print \$4}' | grep -q '[:.]${1}\$'"
}

update_prod_config_port() {
    local new_port="$1" cfg="$SERVER_DIR/config.prod.yaml"
    # 只匹配 "port: <数字>" 形式(server.port)，DSN 里的 port=xxx 不受影响
    sed -i.deploybak -E "s/^([[:space:]]*port:[[:space:]]*)[0-9]+/\1${new_port}/" "$cfg"
    rm -f "${cfg}.deploybak"
}

FINAL_SERVER_PORT=""

# 远程检查的结果分三种：0 是、1 否、255 SSH 本身没连上。连不上不能当「否」：
# 「服务不存在」会走首次部署的分支，「端口没占用 / 被占用」会换端口——下游真实事故：部署时 SSH 断了一下，
# 已部署的服务被当成首次部署、端口被自己占着于是换到下一个端口并回写 config.prod.yaml，nginx 还指着原端口，整站 502。
ssh_failed() {
    echo -e "${RED}SSH 连接失败（$1），为了不误判服务和端口，停止部署；稍后重试即可${NC}"
    exit 1
}

# remote_check <说明> <命令...>：回 0 / 1，SSH 连不上直接停止部署
remote_check() {
    local what="$1" rc=0
    shift
    "$@" || rc=$?
    [ "$rc" -eq 255 ] && ssh_failed "$what"
    return "$rc"
}

resolve_server_port() {
    local configured_port final_port i main_pid listener
    configured_port=$(grep -E '^[[:space:]]*port:' "$SERVER_DIR/config.prod.yaml" | head -1 | awk '{print $2}')
    configured_port=${configured_port:-8080}
    FINAL_SERVER_PORT="$configured_port"

    echo -e "${YELLOW}[后端] 检查远程端口 ${configured_port}...${NC}"

    if remote_check "检查服务是否已部署" remote_service_exists; then
        if remote_check "检查端口 ${configured_port}" remote_port_in_use "$configured_port"; then
            # 端口在监听——先判断是不是本服务自己占着(正常情况)
            main_pid=$(ssh_run "systemctl show -p MainPID --value ${SERVICE_NAME} 2>/dev/null" | tr -d '[:space:]' || true)
            listener=$(ssh_run "ss -tlnp 2>/dev/null | grep '[:.]${configured_port} ' | head -1" || true)
            if [ -n "$main_pid" ] && [ "$main_pid" != "0" ] && echo "$listener" | grep -q "pid=${main_pid},"; then
                echo -e "${GREEN}        端口 ${configured_port} 由本服务占用，重启后继续使用${NC}"
                return 0
            fi
            echo -e "${RED}服务 ${SERVICE_NAME} 已存在，但端口 ${configured_port} 被其他进程占用:${NC}"
            echo -e "        ${listener:-（无法获取占用进程信息）}"
            echo -e "${YELLOW}已部署过的服务端口不自动更换（nginx/回调地址都依赖它），请人工处理:${NC}"
            echo -e "        1) 释放该端口；或"
            echo -e "        2) 修改 server/config.prod.yaml 的 port 并同步更新 nginx 配置后重新部署"
            exit 1
        fi
        return 0
    fi

    # 首次部署：配置端口空闲则直接用
    if ! remote_check "检查端口 ${configured_port}" remote_port_in_use "$configured_port"; then
        return 0
    fi

    echo -e "${YELLOW}        端口 ${configured_port} 已被占用，向后寻找空闲端口...${NC}"
    final_port=$configured_port
    for i in $(seq 1 50); do
        final_port=$((final_port + 1))
        if ! remote_check "检查端口 ${final_port}" remote_port_in_use "$final_port"; then
            FINAL_SERVER_PORT="$final_port"
            update_prod_config_port "$final_port"
            echo -e "${GREEN}        改用空闲端口 ${final_port}，已同步回写 server/config.prod.yaml${NC}"
            echo -e "${YELLOW}        注意: nginx 站点配置请使用端口 ${final_port}${NC}"
            return 0
        fi
    done

    echo -e "${RED}从 ${configured_port} 起连续 50 个端口都被占用，请人工确认服务器状态${NC}"
    exit 1
}

# -------------------------------------------------------
# 编译后端
# -------------------------------------------------------

# 重新生成 server/docs。失败不中断部署，继续用仓库里已有的文档。
# 有 make 就走 make swagger，和 dev.sh / scripts/check.sh 同一个理由：下游可能改过 swagger 目标
# （多生成一份文档、加 --tags 把两份分开），这里写死 swag 命令就会生成出和 CI 不一样的 docs——
# 部署一次工作区就脏了，之后按 git describe --dirty 编的二进制版本号都带 -dirty。
# Windows 的 Git Bash 不带 make，退回直接调 swag（版本与 Makefile / dev.sh / CI 钉的同一个）。
# GOWORK=off 与 deploy_server 的 go build 一致：本地 make kit-dev 留下的 go.work 会让 swag
# 按本地 kit 源码生成注解，否则 docs 来自改过的 kit、二进制来自钉死版本，两边对不上。
# 与 dev.sh 同策略：滤掉 600+ 行流水账，只留警告/报错（不用 -q，它把警告也吞了）。
gen_swagger_docs() {
    local -a swag_run
    local swag_log
    if command -v make >/dev/null 2>&1; then
        swag_run=(make -C "$ROOT_DIR" --no-print-directory swagger)
    else
        echo -e "${YELLOW}        未找到 make，直接调用 swag（若你定制过 swagger 目标，请装 make 或手动生成）${NC}"
        swag_run=(go run github.com/swaggo/swag/cmd/swag@v1.16.6 init -g main.go -o docs --parseDependencyLevel 3 --packagePrefix base,github.com/leivorn/base-kit)
    fi
    swag_log=$(mktemp)
    if (cd "$SERVER_DIR" && GOWORK=off "${swag_run[@]}") >"$swag_log" 2>&1; then
        grep -vE 'Generating |TypeSpecDef is nil|Generate swagger docs|Generate general API Info|create (docs\.go|swagger\.json|swagger\.yaml) at ' "$swag_log" | sed 's/^/        /' || true
    else
        echo -e "${RED}        Swagger 生成失败（继续用上一次的文档）:${NC}"
        tail -20 "$swag_log" | sed 's/^/        /'
    fi
    rm -f "$swag_log"
}

deploy_server() {
    resolve_server_port

    echo -e "${YELLOW}[后端] 交叉编译 (${TARGET_OS}/${TARGET_ARCH})...${NC}"
    cd "$SERVER_DIR"

    echo -e "        生成 Swagger 文档..."
    gen_swagger_docs

    BIN_NAME="$SERVER_BIN_NAME"
    [ "$TARGET_OS" = "windows" ] && BIN_NAME="${BIN_NAME}.exe"

    # GOWORK=off: 本地可能有 go.work 把 base-kit 指向源码副本，发布必须按 go.mod 里钉死的版本编译
    CGO_ENABLED=0 GOWORK=off GOOS="$TARGET_OS" GOARCH="$TARGET_ARCH" go build -ldflags="-s -w" -o "$BUILD_DIR/$BIN_NAME" .
    cp config.prod.yaml "$BUILD_DIR/config.yaml"
    echo -e "${GREEN}        编译完成: $BIN_NAME (使用生产配置)${NC}"

    echo -e "${YELLOW}[后端] 上传到服务器...${NC}"
    check_remote_owner "$REMOTE_SERVER_DIR" "后端"
    ssh_run "mkdir -p ${REMOTE_SERVER_DIR}"
    # 先传临时名再 mv 替换: 直接覆盖运行中的二进制会报 Text file busy
    scp_to "$BUILD_DIR/$BIN_NAME" "${REMOTE_SERVER_DIR}/${BIN_NAME}.new"
    scp_to "$BUILD_DIR/config.yaml" "${REMOTE_SERVER_DIR}/config.yaml"
    ssh_run "chmod +x ${REMOTE_SERVER_DIR}/${BIN_NAME}.new && mv -f ${REMOTE_SERVER_DIR}/${BIN_NAME}.new ${REMOTE_SERVER_DIR}/${BIN_NAME}"
    mark_remote_owner "$REMOTE_SERVER_DIR"
    echo -e "${GREEN}        上传完成${NC}"

    if [ "$AUTO_RESTART" = "yes" ]; then
        ensure_systemd_unit "$SERVICE_NAME" "$REMOTE_SERVER_DIR" "${REMOTE_SERVER_DIR}/${SERVER_BIN_NAME}" "${PROJECT_NAME} Server (${SERVICE_NAME})"
        restart_remote_service "$SERVICE_NAME" "端口 ${FINAL_SERVER_PORT}"
    fi
}

# -------------------------------------------------------
# 自动创建 systemd 服务 (server 与下游扩展目标共用)
#   ensure_systemd_unit <服务名> <工作目录> <启动命令> [描述]
# -------------------------------------------------------
ensure_systemd_unit() {
    local svc="$1" workdir="$2" exec_start="$3" desc="${4:-${PROJECT_NAME} ${1}}"
    local service_exists=0 unit_dir
    # 用 grep -q 的退出码判断存在性，不解析输出。
    # 不能写 `$(... | grep -c ...) || echo 0`：服务不存在时远程 grep -c 已输出 "0"
    # 且退出码为 1，|| 再补一个 0 会拼成两行 "0\n0"——既不等于 "0" 也不为空，
    # 结果跳过创建、直接 restart 报 service not found
    if remote_service_exists "$svc"; then
        service_exists=1
    fi

    # 服务已存在时校验归属：WorkingDirectory 指向别的目录说明服务名被其他项目占用
    if [ "$service_exists" = "1" ]; then
        unit_dir=$(ssh_run "systemctl show -p WorkingDirectory ${svc} 2>/dev/null" | cut -d= -f2- | tr -d '[:space:]' || true)
        if [ -n "$unit_dir" ] && [ "$unit_dir" != "$workdir" ]; then
            echo -e "${RED}systemd 服务 ${svc} 已被其他项目使用 (WorkingDirectory=${unit_dir})${NC}"
            echo -e "${YELLOW}请在 $(basename "$ENV_FILE") 中为当前项目设置不同的 PROJECT_NAME 或服务名${NC}"
            exit 1
        fi
        return 0
    fi

    echo -e "${YELLOW}[systemd] 创建服务: ${svc}...${NC}"
    ssh_run "cat > /etc/systemd/system/${svc}.service << 'UNIT'
[Unit]
Description=${desc}
After=network.target

[Service]
Type=simple
WorkingDirectory=${workdir}
ExecStart=${exec_start}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT"
    ssh_run "systemctl daemon-reload && systemctl enable ${svc}"
    echo -e "${GREEN}        服务已创建并设为开机自启${NC}"
}

# -------------------------------------------------------
# 重启远程服务并确认存活: restart_remote_service <服务名> [附注]
# -------------------------------------------------------
restart_remote_service() {
    local svc="$1" note="${2:-}"
    echo -e "${YELLOW}[systemd] 重启服务 (${svc})...${NC}"
    ssh_run "systemctl restart ${svc}"
    sleep 2
    if ssh_run "systemctl is-active --quiet ${svc}"; then
        echo -e "${GREEN}        服务运行中${note:+ (}${note}${note:+)}${NC}"
    else
        echo -e "${RED}        服务启动失败，最近日志:${NC}"
        ssh_run "journalctl -u ${svc} -n 15 --no-pager" || true
        exit 1
    fi
}

# -------------------------------------------------------
# 打包前端
# -------------------------------------------------------
deploy_admin() {
    echo -e "${YELLOW}[前端] 打包构建...${NC}"
    cd "$ADMIN_DIR"

    if [ ! -d node_modules ]; then
        echo -e "        安装依赖..."
        pnpm install --no-frozen-lockfile
    fi

    eval "$ADMIN_BUILD_CMD"

    DIST_DIR="$ADMIN_DIR/apps/web-antd/dist"
    if [ ! -d "$DIST_DIR" ]; then
        echo -e "${RED}前端打包输出目录不存在: $DIST_DIR${NC}"
        exit 1
    fi

    cd "$DIST_DIR"
    tar -czf "$BUILD_DIR/admin.tar.gz" .
    echo -e "${GREEN}        打包完成${NC}"

    echo -e "${YELLOW}[前端] 上传到服务器...${NC}"
    check_remote_owner "$REMOTE_ADMIN_DIR" "前端"
    ssh_run "mkdir -p ${REMOTE_ADMIN_DIR}"
    scp_to "$BUILD_DIR/admin.tar.gz" "$REMOTE_TMP_TAR"
    ssh_run "rm -rf ${REMOTE_ADMIN_DIR}/* && tar -xzf ${REMOTE_TMP_TAR} -C ${REMOTE_ADMIN_DIR} && rm -f ${REMOTE_TMP_TAR}"
    mark_remote_owner "$REMOTE_ADMIN_DIR"
    echo -e "${GREEN}        上传完成${NC}"
}

# -------------------------------------------------------
# 按模式执行
# -------------------------------------------------------
case "$DEPLOY_MODE" in
    server) deploy_server ;;
    admin)  deploy_admin ;;
    all)
        deploy_server
        deploy_admin
        for t in $PROJECT_DEPLOY_TARGETS; do
            "project_deploy_${t}"
        done
        ;;
    *)
        # 走到这里必然是 is_project_target 校验过的下游扩展目标
        "project_deploy_${DEPLOY_MODE}"
        ;;
esac

rm -rf "$BUILD_DIR"
rmdir "$ROOT_DIR/.build" 2>/dev/null || true

echo ""
echo -e "${GREEN}==============================${NC}"
echo -e "${GREEN}   部署完成！(${PROJECT_NAME} / ${DEPLOY_MODE})${NC}"
echo -e "${GREEN}==============================${NC}"
echo ""
