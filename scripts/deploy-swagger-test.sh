#!/usr/bin/env bash
# deploy.sh 生成 Swagger 那一步的离线测试：把 gen_swagger_docs 从 deploy.sh 里抠出来单跑，
# make / go 全换成桩，不碰服务器、不真跑 swag，CI 和本地都能跑。由 scripts/check.sh scripts 调用。
#
# 守的是「部署生成的 docs 和 make swagger / CI 一样」：deploy.sh 以前写死一条 swag 命令，
# 下游改过 swagger 目标的（比如加 --tags 把后台和开放接口分成两份文档）部署一次工作区 server/docs 就脏了，
# 之后按 git describe --dirty 编的二进制版本号都带 -dirty。现在有 make 就走 make swagger。
#
# 用法: bash scripts/deploy-swagger-test.sh [deploy.sh 路径]
# 注意：写法要兼容 bash 3.2（macOS 自带）。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${1:-$ROOT/deploy.sh}"
fail=0

check() { # 描述 命令...
  local desc="$1"
  shift
  if "$@"; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc"
    fail=1
  fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FN="$TMP_ROOT/fn.sh"
sed -n '/^gen_swagger_docs() {$/,/^}$/p' "$SCRIPT" >"$FN"
check "deploy.sh 里有 gen_swagger_docs" test -s "$FN"
check "deploy_server 调 gen_swagger_docs 生成文档" \
  grep -Eq '^[[:space:]]+gen_swagger_docs$' "$SCRIPT"
# 写死的 swag 命令只许留在没有 make 时的退路里，别处再抄一条就又和 make swagger 分叉了
check "swag 命令只在退路里出现一次" \
  test "$(grep -c 'swaggo/swag/cmd/swag@' "$SCRIPT")" = 1

# stub <目录> <名字> <退出码>：写一个记下自己怎么被调的桩（参数、GOWORK、当前目录）
stub() {
  mkdir -p "$1"
  cat >"$1/$2" <<EOF
#!/bin/sh
echo "$2 GOWORK=\${GOWORK:-} PWD=\$(pwd) ARGS=\$*" >>"$TMP_ROOT/calls"
echo "Generating docs.Foo"
echo "warning: route declared multiple times"
exit $3
EOF
  chmod +x "$1/$2"
}

# run_case <PATH>：在子 shell 里 source 抠出来的函数并调一次，输出写 out.txt
run_case() {
  rm -f "$TMP_ROOT/calls"
  mkdir -p "$TMP_ROOT/server"
  (
    set -e # 和 deploy.sh 一样
    ROOT_DIR="$TMP_ROOT/repo"
    SERVER_DIR="$TMP_ROOT/server"
    RED="" YELLOW="" NC=""
    # shellcheck source=/dev/null
    source "$FN"
    PATH="$1"
    gen_swagger_docs
  ) >"$TMP_ROOT/out.txt" 2>&1
}

# 一、有 make：走 make swagger（下游对 swagger 目标的定制都在里面），GOWORK=off
stub "$TMP_ROOT/bin-make" make 0
run_case "$TMP_ROOT/bin-make:$PATH"
check "有 make 时调 make swagger" \
  grep -q "^make .*ARGS=-C $TMP_ROOT/repo --no-print-directory swagger$" "$TMP_ROOT/calls"
check "make swagger 带 GOWORK=off" grep -q '^make GOWORK=off ' "$TMP_ROOT/calls"
check "不再直接调 go run swag" test "$(grep -c '^go ' "$TMP_ROOT/calls")" = 0
check "流水账滤掉了" sh -c "! grep -q 'Generating ' '$TMP_ROOT/out.txt'"
check "警告留着" grep -q 'route declared multiple times' "$TMP_ROOT/out.txt"

# 二、没有 make（Windows 的 Git Bash）：退回直接调钉死版本的 swag，在 server/ 里跑
NOMAKE="$TMP_ROOT/bin-nomake"
stub "$NOMAKE" go 0
for tool in mktemp grep sed tail rm; do
  ln -s "$(command -v "$tool")" "$NOMAKE/$tool"
done
run_case "$NOMAKE"
check "没有 make 时直接调 swag@v1.16.6" \
  grep -q "^go GOWORK=off PWD=$TMP_ROOT/server ARGS=run github.com/swaggo/swag/cmd/swag@v1.16.6 init -g main.go " \
  "$TMP_ROOT/calls"
check "没有 make 时提示了" grep -q '未找到 make' "$TMP_ROOT/out.txt"

# 三、生成失败不中断部署（deploy.sh 是 set -e），把报错尾巴打出来
stub "$TMP_ROOT/bin-fail" make 2
run_case "$TMP_ROOT/bin-fail:$PATH"
status=$?
check "生成失败函数照样返回 0" test "$status" = 0
check "生成失败打出报错" grep -q 'Swagger 生成失败' "$TMP_ROOT/out.txt"

if [ "$fail" != 0 ]; then
  echo "--- 最后一次的输出 ---"
  cat "$TMP_ROOT/out.txt"
  exit 1
fi
echo "deploy.sh Swagger 生成测试全部通过"
