#!/usr/bin/env bash
# Builds the FFmpeg and ffprobe that ship inside FileFoundry.app, so Convert & Compress needs nothing installed.
# Static arm64 binaries from pinned upstream sources (checked by SHA-256). They link only macOS system libraries.
# Output: vendor/ffmpeg/bin/{ffmpeg,ffprobe}, vendor/ffmpeg/sources/ (exact sources, kept for the GPL) and SOURCES.txt.
# Needs: Xcode command line tools, cmake, pkg-config. Usage: scripts/build_ffmpeg.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT_DIR/vendor/ffmpeg"
WORK="$ROOT_DIR/.build-ffmpeg"
PREFIX="$WORK/prefix"
SRC="$OUT/sources"
JOBS="$(sysctl -n hw.ncpu)"

# name|version|url|sha256|file
PACKAGES=(
  "x265|4.3|https://github.com/Multicorewareinc/x265/releases/download/4.3/x265_4.3.tar.gz|83c53e4c8bbb8f1e33ed59e10a7d621d1d7801ca853910c3eb41f038b8ffb121|x265_4.3.tar.gz"
  "libvpx|1.17.0|https://github.com/webmproject/libvpx/archive/refs/tags/v1.17.0.tar.gz|1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a|libvpx-1.17.0.tar.gz"
  "libwebp|1.6.0|https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz|e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564|libwebp-1.6.0.tar.gz"
  "lame|4.0|https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz|3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb|lame-4.0.tar.gz"
  "opus|1.6.1|https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.6.1.tar.gz|6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1|opus-1.6.1.tar.gz"
  "ffmpeg|9.0.2|https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz|8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e|ffmpeg-9.0.2.tar.xz"
)

export MACOSX_DEPLOYMENT_TARGET=14.0
export CC=clang CXX=clang++
export CFLAGS="-arch arm64 -mmacosx-version-min=14.0 -O2"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-arch arm64 -mmacosx-version-min=14.0"
# Only our own static libraries are visible to configure scripts, never Homebrew's.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH CPATH LIBRARY_PATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH

# RESUME=1 keeps libraries finished by an earlier run (development only; CI always starts clean).
if [[ "${RESUME:-0}" != 1 ]]; then rm -rf "$WORK" "$OUT"; fi
mkdir -p "$WORK" "$PREFIX" "$SRC" "$OUT/bin"
done_() { [[ -f "$PREFIX/.done-$1" ]]; }
mark() { touch "$PREFIX/.done-$1"; }

fetch() { # name -> extracted dir in $WORK
  local line name version url sha file
  for line in "${PACKAGES[@]}"; do
    IFS='|' read -r name version url sha file <<<"$line"
    [[ "$name" == "$1" ]] || continue
    curl -fsSL --retry 3 -o "$SRC/$file" "$url"
    echo "$sha  $SRC/$file" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch for $file" >&2; exit 1; }
    mkdir -p "$WORK/$name"
    tar -xf "$SRC/$file" -C "$WORK/$name" --strip-components 1
    echo "$name $version $url sha256:$sha" >>"$OUT/SOURCES.txt"
    return
  done
  echo "Unknown package $1" >&2; exit 1
}

if ! done_ x264; then
# x264 has no release tarballs and GitLab regenerates its archives, so it is pinned by git commit instead.
X264_COMMIT=b35605ace3ddf7c1a5d67a2eb553f034aef41d55
git -c init.defaultBranch=main init -q "$WORK/x264"
git -C "$WORK/x264" fetch -q --depth 1 https://code.videolan.org/videolan/x264.git "$X264_COMMIT"
git -C "$WORK/x264" checkout -q FETCH_HEAD
[[ "$(git -C "$WORK/x264" rev-parse HEAD)" == "$X264_COMMIT" ]] || { echo "x264 commit mismatch" >&2; exit 1; }
git -C "$WORK/x264" archive --format=tar.gz --prefix=x264-r3222/ -o "$SRC/x264-r3222.tar.gz" HEAD
echo "x264 r3222 https://code.videolan.org/videolan/x264.git commit:$X264_COMMIT" >>"$OUT/SOURCES.txt"
(cd "$WORK/x264" && ./configure --prefix="$PREFIX" --enable-static --enable-pic --disable-cli --disable-opencl \
  && make -j"$JOBS" && make install-lib-static)
mark x264
fi

if ! done_ x265; then
fetch x265
(mkdir -p "$WORK/x265/out" && cd "$WORK/x265/out" && cmake ../source -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null && make -j"$JOBS" && make install)
mark x265
fi

if ! done_ libvpx; then
fetch libvpx
# Newest macOS target libvpx knows ("arm64-darwin-gcc" without a number is iOS). `--help` exits 1 by design.
VPX_TARGET="$(cd "$WORK/libvpx" && { ./configure --help || true; } | grep -o 'arm64-darwin[0-9][0-9]*-gcc' | sort -V | tail -1)"
[[ -n "$VPX_TARGET" ]] || { echo "No macOS arm64 target in libvpx" >&2; exit 1; }
(cd "$WORK/libvpx" && ./configure --prefix="$PREFIX" --target="$VPX_TARGET" --enable-static --disable-shared --enable-pic \
  --disable-examples --disable-tools --disable-docs --disable-unit-tests --enable-vp9-highbitdepth \
  && make -j"$JOBS" && make install)
mark libvpx
fi

if ! done_ libwebp; then
fetch libwebp
(cd "$WORK/libwebp" && ./configure --prefix="$PREFIX" --enable-static --disable-shared --with-pic \
  --enable-libwebpmux --enable-libwebpdemux --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-gl \
  --disable-sdl --disable-wic && make -j"$JOBS" && make install)
mark libwebp
fi

if ! done_ lame; then
fetch lame
(cd "$WORK/lame" && ./configure --prefix="$PREFIX" --enable-static --disable-shared --with-pic --disable-frontend --disable-decoder \
  && make -j"$JOBS" && make install)
mark lame
fi

if ! done_ opus; then
fetch opus
(cd "$WORK/opus" && ./configure --prefix="$PREFIX" --enable-static --disable-shared --with-pic --disable-doc \
  --disable-extra-programs && make -j"$JOBS" && make install)
mark opus
fi

if ! done_ ffmpeg; then
fetch ffmpeg
(cd "$WORK/ffmpeg" && ./configure --prefix="$PREFIX" --arch=arm64 --cc=clang --cxx=clang++ \
  --enable-gpl --disable-autodetect --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib \
  --enable-libx264 --enable-libx265 --enable-libvpx --enable-libwebp --enable-libmp3lame --enable-libopus \
  --enable-static --disable-shared --disable-ffplay --disable-doc --disable-network --disable-debug \
  --pkg-config-flags=--static --extra-cflags="-I$PREFIX/include $CFLAGS" \
  --extra-ldflags="-L$PREFIX/lib $LDFLAGS" --extra-libs="-lc++" \
  && make -j"$JOBS")
mark ffmpeg
fi

for tool in ffmpeg ffprobe; do
  cp "$WORK/ffmpeg/$tool" "$OUT/bin/$tool"
  strip -x "$OUT/bin/$tool"
  # Refuse anything that would need a library outside macOS itself (for example from Homebrew).
  if otool -L "$OUT/bin/$tool" | tail -n +2 | grep -vE '^\s+(/usr/lib/|/System/Library/)'; then
    echo "$tool links a non-system library" >&2; exit 1
  fi
  [[ "$(lipo -archs "$OUT/bin/$tool")" == "arm64" ]] || { echo "$tool is not arm64 only" >&2; exit 1; }
done

for encoder in libx264 libx265 libvpx-vp9 libwebp libmp3lame libopus aac flac gif mjpeg png h264_videotoolbox; do
  "$OUT/bin/ffmpeg" -hide_banner -encoders | grep -q " $encoder " || { echo "Missing encoder $encoder" >&2; exit 1; }
done

rm -rf "$WORK"
echo "Built $OUT/bin/ffmpeg and ffprobe ($(du -sh "$OUT/bin" | cut -f1))"
