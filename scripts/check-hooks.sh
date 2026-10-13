#!/usr/bin/env bash
# 基底挂载点冻结校验。
#
# AGENTS.md 承诺「下游挂载点，基底承诺永不修改」——下游把自己的路由/模型/脚本/
# CI job 写在这些文件里，基底一旦改动，所有下游 make sync-base 时都会撞冲突。这个
# 脚本把承诺变成可执行的检查：两个 Go 挂载点按 blob id 冻结，其余挂载点必须不存在
# （它们由下游按需新增：dev/deploy 扩展、Makefile 自有目标、CI 自有 job）。
#
# 只在基底仓库本体生效（origin 指向 leivorn/base）；下游可以随意修改挂载点，
# 继承到这个脚本时自动跳过。
#
# 基底确需改动挂载点时（应极少）：改完用 git hash-object 取新 id 更新下面的常量，
# 并在 CHANGELOG.md 里说明这次改动，让下游知道会有一处冲突。
#
# 注意：写法要兼容 bash 3.2（macOS 自带），不能用 declare -A / mapfile。
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if ! git remote get-url origin 2>/dev/null | grep -Eq 'leivorn/base(\.git)?/?$'; then
    echo "check-hooks: 非基底仓库本体，跳过（下游可自由修改挂载点）"
    exit 0
fi

# 与 FROZEN_FILES 同序
FROZEN_FILES="server/internal/router/project.go server/internal/store/project.go"
FROZEN_BLOBS="d1e2419f95412b781b7b04c04cc9de191d260a65 c4ff7a92fa16fce68eede1eeae81643c22d05be5"
ABSENT_FILES="dev.project.sh deploy.project.sh Makefile.project .github/workflows/project.yml"

fail=0
i=1
for f in $FROZEN_FILES; do
    want=$(echo "$FROZEN_BLOBS" | cut -d' ' -f"$i")
    if [ ! -f "$f" ]; then
        echo "挂载点缺失: $f"
        fail=1
    else
        got=$(git hash-object "$f")
        if [ "$got" != "$want" ]; then
            echo "挂载点被修改: $f"
            echo "  期望 blob $want，实际 $got"
            echo "  基底不应改动挂载点；确需改动时更新 scripts/check-hooks.sh 的 FROZEN_BLOBS 并写进 CHANGELOG"
            fail=1
        fi
    fi
    i=$((i + 1))
done

for f in $ABSENT_FILES; do
    if [ -e "$f" ]; then
        echo "基底不应包含下游文件: $f（这是下游按需新增的脚本挂载点）"
        fail=1
    fi
done

if [ "$fail" = "0" ]; then
    echo "check-hooks: 挂载点完好"
fi
exit "$fail"
