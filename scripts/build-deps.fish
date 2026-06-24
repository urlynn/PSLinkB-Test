#!/usr/bin/env fish
# build-deps.fish — CI 全平台 stream 编译与发布
# Usage: fish scripts/build-deps.fish
#
# 流程:
#   [1] 触发 build-deps.yml GitHub Action
#   [2] 等待所有 job 完成
#   [3] 下载 artifacts
#   [4] 整理产物 → 按架构打包
#   [5] 上传到 GitHub Release (tag: build-deps)

set -g OUT "/tmp/pslinkb-deps"
set -g REPO "urlynn/PSLinkB-Test"
set -g WF "build-deps.yml"
set -g TAG "build-deps"

echo "══════════════════════════════════════════"
echo " PSLinkB Build Deps — CI 全平台打包"
echo "══════════════════════════════════════════"

rm -rf $OUT /tmp/artifacts
mkdir -p $OUT

# ── [1/5] 触发 Action ──
echo ""
echo "[1/5] 触发 build-deps.yml..."
if not gh auth status >/dev/null 2>&1
    echo "  ERROR: gh not authenticated. Run: gh auth login"
    exit 1
end
gh workflow run $WF --repo $REPO
echo "  → dispatched"

# ── [2/5] 等待完成 ──
echo ""
echo "[2/5] 等待 CI 完成..."

set run_id ""
for i in (seq 1 90)
    set run_id (gh run list --repo $REPO --workflow $WF --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)
    set s (gh run view $run_id --repo $REPO --json status --jq '.status' 2>/dev/null)
    if test "$s" = "completed"
        break
    end
    echo -n "."
    sleep 20
end
echo ""

if test -z "$run_id"
    echo "  ERROR: 未检测到 CI run"; exit 1
end

set conclusion (gh run view $run_id --repo $REPO --json conclusion --jq '.conclusion' 2>/dev/null)
echo "  run $run_id: $conclusion"
if test "$conclusion" != "success"
    echo "  ERROR: CI 失败 https://github.com/$REPO/actions/runs/$run_id"
    exit 1
end

# ── [3/5] 下载 artifacts ──
echo ""
echo "[3/5] 下载 artifacts..."

set -l jobs linux-x86_64 linux-aarch64 macos-aarch64 macos-x86_64 windows-x86_64 windows-aarch64
for job in $jobs
    gh run download $run_id --repo $REPO -n $job -D /tmp/artifacts/$job 2>/dev/null; or true
end

# ── [4/5] 整理 + 按架构打包 ──
echo ""
echo "[4/5] 整理 + 打包..."

for arch_desc in "x86_64-linux-musl:linux-x86_64" \
                 "aarch64-linux-musl:linux-aarch64" \
                 "x86_64-windows:windows-x86_64" \
                 "aarch64-windows:windows-aarch64"
    set dir (echo $arch_desc | cut -d: -f1)
    set job (echo $arch_desc | cut -d: -f2)
    set stream_file (find /tmp/artifacts/$job -name 'pslinkb-stream*' -type f 2>/dev/null | head -1)
    if test -n "$stream_file"
        set info (file -b "$stream_file")
        echo "  stream $dir: $info"
        test -s "$stream_file" || { echo "  ERROR: empty"; exit 1; }
        mkdir -p $OUT/stream/$dir
        cp "$stream_file" $OUT/stream/$dir/
    else
        echo "  WARN: no stream for $dir"
    end
end

for arch_desc in "aarch64-macos:macos-aarch64" "x86_64-macos:macos-x86_64"
    set dir (echo $arch_desc | cut -d: -f1)
    set job (echo $arch_desc | cut -d: -f2)
    if test -d /tmp/artifacts/$job/lib
        mkdir -p $OUT/ffbuild/$dir/lib $OUT/ffbuild/$dir/include
        cp -r /tmp/artifacts/$job/lib/* $OUT/ffbuild/$dir/lib/ 2>/dev/null || true
        cp -r /tmp/artifacts/$job/include/* $OUT/ffbuild/$dir/include/ 2>/dev/null || true
        echo "  ffbuild $dir ✓"
    end
end

echo ""

set pkg_gz "/tmp/pslinkb-build-deps.tar.gz"
cd $OUT
tar czf $pkg_gz stream/ ffbuild/
echo "  → $pkg_gz"
ls -lh $pkg_gz

rm -rf /tmp/artifacts

# ── [5/5] 上传 ──
echo ""
echo "[5/5] 上传到 release ($TAG)..."
gh release delete "$TAG" --repo "$REPO" -y 2>&1 || true
gh release create "$TAG" $pkg_gz \
    --repo "$REPO" \
    --title "Build Dependencies" \
    --notes "pslinkb-stream + FFmpeg static libs for all platforms (CI built)"
echo "  $TAG ✓"

echo ""
echo "══════════════════════════════════════════"
echo " Done"
echo "══════════════════════════════════════════"
