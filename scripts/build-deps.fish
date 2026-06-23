#!/usr/bin/env fish
# build-deps.fish — 全平台 stream + FFmpeg libs 编译与打包
# Usage: fish scripts/build-deps.fish [--upload]
#   --upload  构建完成后上传到 build-deps release tag
#
# 流程:
#   [1] SSH Gentoo → 编译 linux musl FFmpeg + pslinkb-stream (x86_64, aarch64)
#   [2] 触发 build-deps.yml GitHub Action → 编译 macOS + Windows
#   [3] 等待 Action 完成 → 下载 artifacts
#   [4] 整理产物 → 打包 pslinkb-build-deps.tar.zst
#   [5] --upload: 上传到 GitHub Release (tag: build-deps)

set -g GENTOO "root@192.168.1.11"
set -g GENTOO_PROJ "/root/PSLinkB-Dev"
set -g OUT "/tmp/pslinkb-deps"
set -g REPO "urlynn/PSLinkB-Test"
set -g WF "build-deps.yml"
set -g TAG "build-deps"

set -g DO_UPLOAD false
for arg in $argv
    test "$arg" = "--upload" && set DO_UPLOAD true
end

echo "══════════════════════════════════════════"
echo " PSLinkB Build Deps — 全平台 deps 打包"
echo "══════════════════════════════════════════"

rm -rf $OUT
mkdir -p $OUT/stream $OUT/ffbuild

# ── [1/5] Gentoo musl (linux stream + ffmpeg) ──
echo ""
echo "[1/5] Gentoo musl 编译..."
fish scripts/build-ffmpeg.fish x86_64
fish scripts/build-ffmpeg.fish aarch64

for arch in x86_64 aarch64
    set src "$GENTOO:$GENTOO_PROJ/ffbuild/linux-$arch"
    mkdir -p $OUT/stream/$arch-linux-musl
    scp "$src/bin/pslinkb-stream" $OUT/stream/$arch-linux-musl/
    echo "  $arch-linux-musl ✓"
end

# ── [2/5] 触发 Action (macOS + Windows) ──
echo ""
echo "[2/5] 触发 build-deps.yml..."
if not gh auth status >/dev/null 2>&1
    echo "  ERROR: gh not authenticated. Run: gh auth login"
    exit 1
end
gh workflow run $WF --repo $REPO
echo "  → dispatched"

# ── [3/5] 等待 + 下载 artifacts ──
echo ""
echo "[3/5] 等待 Action 完成..."

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
    echo "  WARN: 未检测到 CI run，跳过 artifact 下载"
else
    set conclusion (gh run view $run_id --repo $REPO --json conclusion --jq '.conclusion' 2>/dev/null)
    echo "  run $run_id: $conclusion"
    if test "$conclusion" != "success"
        echo "  WARN: Action 未成功，检查: https://github.com/$REPO/actions/runs/$run_id"
    end

    for job in macos-aarch64 macos-x86_64 windows-x86_64
        gh run download $run_id --repo $REPO -n $job -D /tmp/artifacts/$job 2>/dev/null; or true
    end

    # macOS FFmpeg libs
    if test -d /tmp/artifacts/macos-aarch64/lib
        mkdir -p $OUT/ffbuild/aarch64-macos/lib $OUT/ffbuild/aarch64-macos/include
        cp -r /tmp/artifacts/macos-aarch64/lib/* $OUT/ffbuild/aarch64-macos/lib/ 2>/dev/null || true
        cp -r /tmp/artifacts/macos-aarch64/include/* $OUT/ffbuild/aarch64-macos/include/ 2>/dev/null || true
        echo "  macos-aarch64 ffbuild ✓"
    end
    if test -d /tmp/artifacts/macos-x86_64/lib
        mkdir -p $OUT/ffbuild/x86_64-macos/lib $OUT/ffbuild/x86_64-macos/include
        cp -r /tmp/artifacts/macos-x86_64/lib/* $OUT/ffbuild/x86_64-macos/lib/ 2>/dev/null || true
        cp -r /tmp/artifacts/macos-x86_64/include/* $OUT/ffbuild/x86_64-macos/include/ 2>/dev/null || true
        echo "  macos-x86_64 ffbuild ✓"
    end

    # Windows stream
    if test -f /tmp/artifacts/windows-x86_64/pslinkb-stream.exe
        mkdir -p $OUT/stream/x86_64-windows
        cp /tmp/artifacts/windows-x86_64/pslinkb-stream.exe $OUT/stream/x86_64-windows/
        echo "  windows-x86_64 stream ✓"
    end

    rm -rf /tmp/artifacts
end

# ── [4/5] 检查 + 打包 ──
echo ""
echo "[4/5] 打包..."

for bin in (find $OUT/stream -type f -name 'pslinkb-stream*')
    set info (file -b "$bin")
    echo "  stream: $bin → $info"
    test -s "$bin" || { echo "  ERROR: empty binary"; exit 1; }
end

set pkg_gz  "/tmp/pslinkb-build-deps.tar.gz"
cd $OUT
tar czf $pkg_gz stream/ ffbuild/
echo "  → $pkg_gz"
ls -lh $pkg_gz

# ── [5/5] 上传 ──
if $DO_UPLOAD
    echo ""
    echo "[5/5] 上传到 release..."
    gh release delete "$TAG" --repo "$REPO" -y 2>&1 || true
    gh release create "$TAG" $pkg_gz \
        --repo "$REPO" \
        --title "Build Dependencies" \
        --notes "pslinkb-stream + FFmpeg static libs for all platforms"
    echo "  v$TAG ✓"
end

echo ""
echo "══════════════════════════════════════════"
echo " Done"
echo "══════════════════════════════════════════"
