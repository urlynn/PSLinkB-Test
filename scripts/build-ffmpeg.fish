#!/usr/bin/env fish
# build-ffmpeg.fish — musl-linux FFmpeg + stream compiler (Gentoo 远程)
# Usage: fish scripts/build-ffmpeg.fish <arch>
#   arch: x86_64 | aarch64

set -g ARCH $argv[1]
if not contains $ARCH x86_64 aarch64
    echo "Usage: fish build-ffmpeg.fish <x86_64|aarch64>"
    exit 1
end

set -g GENTOO "root@192.168.1.11"
set -g PROJECT "/root/PSLinkB-Dev"
set -g FFBUILD "$PROJECT/ffbuild/linux-$ARCH"

# ── LLVM 自动检测 ──
echo "[LLVM] 检测 Gentoo LLVM 路径..."
set LLVM_BIN (ssh $GENTOO "ls -d /usr/lib/llvm/*/bin 2>/dev/null | sort -V | tail -1 | tr -d '\n'" 2>/dev/null)
if test -z "$LLVM_BIN"
    set LLVM_BIN "/usr/lib/llvm/22/bin"  # fallback
end
echo "  → $LLVM_BIN"

# ── 架构参数 ──
switch $ARCH
    case x86_64
        set CC        "$LLVM_BIN/x86_64-unknown-linux-musl-clang"
        set CXX       "$LLVM_BIN/x86_64-unknown-linux-musl-clang-cpp"
        set AR        "$LLVM_BIN/llvm-ar"
        set NM        "$LLVM_BIN/llvm-nm"
        set RANLIB    "$LLVM_BIN/llvm-ranlib"
        set STRIP     "$LLVM_BIN/llvm-strip"
        set CFLAGS    "-Oz -static -ffunction-sections -fdata-sections -march=x86-64-v3"
        set LDFLAGS   "-static"
        set STREAM_MARCH "-march=x86-64-v3"
    case aarch64
        set CC        "$LLVM_BIN/aarch64-unknown-linux-musl-clang"
        set CXX       "$LLVM_BIN/aarch64-unknown-linux-musl-clang-cpp"
        set AR        "$LLVM_BIN/llvm-ar"
        set NM        "$LLVM_BIN/llvm-nm"
        set RANLIB    "$LLVM_BIN/llvm-ranlib"
        set STRIP     "$LLVM_BIN/llvm-strip"
        set CFLAGS    "-Oz -static -ffunction-sections -fdata-sections"
        set LDFLAGS   "-static -L/root/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/lib/rustlib/aarch64-unknown-linux-musl/lib/self-contained"
        set STREAM_MARCH ""
        set SYSROOT   "/usr/aarch64-unknown-linux-musl"
end

set STREAM_VER "0.1.1"
set -l cross_flag ""
test -n "$SYSROOT" && set cross_flag "--sysroot=$SYSROOT"

# ── 拼接命令字符串 ──
set -l remote_cmd "
set -e
cd $PROJECT

# FFmpeg configure + make
cd ffmpeg
git fetch origin refs/tags/n8.0:refs/tags/n8.0 --depth 1 2>/dev/null || true
git checkout tags/n8.0 2>/dev/null || true
make distclean 2>/dev/null || true

./configure \
  --prefix=$FFBUILD \
  --cc=$CC --cxx=$CXX --ar=$AR --ranlib=$RANLIB --strip=$STRIP --nm=$NM \
  --target-os=linux --arch=$ARCH \
  --extra-cflags=\"$CFLAGS\" --extra-ldflags=\"$LDFLAGS\" \
  $cross_flag \
  --enable-cross-compile \
  --enable-static --disable-shared \
  --disable-everything --enable-small \
  --enable-ffmpeg \
  --enable-protocol=tcp,rtmp --enable-demuxer=flv --enable-muxer=flv --enable-parser=h264 --enable-network \
  --disable-filters --disable-swscale --disable-bsfs --disable-doc --disable-debug --disable-ffplay --disable-ffprobe \
  --disable-iconv --disable-lzma --disable-bzlib --disable-zlib --disable-runtime-cpudetect

make -j\$(nproc) && make install

# stream_copy.c
mkdir -p $FFBUILD/bin
$CC -O2 -flto $STREAM_MARCH \
  -DSTREAM_VERSION='\"$STREAM_VER\"' \
  -I$FFBUILD/include -L$FFBUILD/lib \
  $PROJECT/src/ffmpeg/stream_copy.c \
  -lavformat -lavcodec -lavutil \
  $LDFLAGS -Wl,--gc-sections \
  -o $FFBUILD/bin/pslinkb-stream

# 验证
for lib in avcodec avformat avutil; do
  test -f $FFBUILD/lib/lib\${lib}.a || { echo \"MISSING: lib\${lib}.a\"; exit 1; }
done
test -f $FFBUILD/bin/pslinkb-stream || { echo \"MISSING: pslinkb-stream\"; exit 1; }

echo \"BUILD OK: linux-$ARCH\"
wc -c < $FFBUILD/bin/pslinkb-stream
"

# ── 远程执行 ──
echo ""
echo "[编译] linux-$ARCH → Gentoo..."
ssh $GENTOO "$remote_cmd"

echo "  linux-$ARCH ✓"
