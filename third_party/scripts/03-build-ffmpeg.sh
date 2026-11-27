#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/00-setup-env.sh
source "$SCRIPT_DIR/00-setup-env.sh"

src="$SOURCE_DIR/jellyfin-ffmpeg"
build="$BUILD_DIR/ffmpeg"
[[ -d "$src" ]] || { printf 'Run 01-fetch.sh first.\n' >&2; exit 1; }
rm -rf "$build"
mkdir -p "$build"

ffmpeg_arch_flags=(--arch="$FFMPEG_ARCH" --cpu="$FFMPEG_CPU")
if [[ "$FFMPEG_ENABLE_NEON" == 1 ]]; then
    ffmpeg_arch_flags+=(--enable-neon)
fi
if [[ "$FFMPEG_ENABLE_THUMB" == 1 ]]; then
    ffmpeg_arch_flags+=(--enable-thumb)
fi

(
    cd "$build"
    "$src/configure" \
        --prefix="$INSTALL_PREFIX" \
        --target-os=android "${ffmpeg_arch_flags[@]}" \
        --enable-cross-compile --cross-prefix="$TOOLCHAIN_BIN/${TARGET_TRIPLE}-" \
        --cc="$CC" --cxx="$CXX" --ar="$AR" --ranlib="$RANLIB" --strip="$STRIP" --nm="$NM" \
        --sysroot="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot" \
        --extra-cflags="-I$INSTALL_PREFIX/include -DCL_TARGET_OPENCL_VERSION=120" \
        --extra-ldflags="-L$INSTALL_PREFIX/lib -ldl -llog -Wl,-z,max-page-size=16384" \
        --pkg-config=pkg-config \
        --pkg-config-flags="--static" \
        --enable-pic --enable-shared --disable-static \
        --disable-programs --disable-doc --disable-debug --disable-network --disable-autodetect --disable-everything \
        --enable-avutil --enable-avcodec --enable-avfilter --enable-swscale \
        --disable-avformat --disable-swresample --disable-avdevice \
        --enable-jni --enable-mediacodec --enable-opencl \
        --enable-decoder=mpeg2video --enable-decoder=mpeg2_mediacodec \
        --enable-parser=mpegvideo \
        --enable-filter=format --enable-filter=scale \
        --enable-filter=hwupload --enable-filter=hwmap \
        --enable-filter=ivtc_opencl --enable-filter=bwdif_opencl --enable-filter=bwdif \
        --enable-filter=yadif --enable-filter=fieldmatch --enable-filter=decimate
    make -j"$(nproc)"
    make install
)

# --disable-programs omits ffmpeg/ffprobe, so check the generated configuration
# instead and stop before installation on any missing feature.
for header in config.h config_components.h; do
    [[ -f "$build/$header" ]] || { printf 'Missing %s after FFmpeg configure\n' "$build/$header" >&2; exit 1; }
done
for component in \
    CONFIG_JNI \
    CONFIG_MEDIACODEC \
    CONFIG_OPENCL \
    CONFIG_AVCODEC \
    CONFIG_AVFILTER \
    CONFIG_SWSCALE \
    CONFIG_MPEG2VIDEO_DECODER \
    CONFIG_MPEG2_MEDIACODEC_DECODER \
    CONFIG_MPEGVIDEO_PARSER \
    CONFIG_HWUPLOAD_FILTER \
    CONFIG_HWMAP_FILTER \
    CONFIG_IVTC_OPENCL_FILTER \
    CONFIG_BWDIF_OPENCL_FILTER \
    CONFIG_BWDIF_FILTER \
    CONFIG_YADIF_FILTER \
    CONFIG_FIELDMATCH_FILTER \
    CONFIG_DECIMATE_FILTER \
    CONFIG_SCALE_FILTER; do
    if ! grep -Eqh "^#define ${component} 1$" "$build/config.h" "$build/config_components.h"; then
        printf 'Required FFmpeg component is disabled or missing: %s\n' "$component" >&2
        exit 1
    fi
done
for component in CONFIG_GPL CONFIG_NONFREE CONFIG_AVFORMAT CONFIG_SWRESAMPLE; do
    if ! grep -Eq "^#define ${component} 0$" "$build/config.h"; then
        printf 'FFmpeg component must be disabled: %s\n' "$component" >&2
        exit 1
    fi
done
printf 'Required FFmpeg components are enabled.\n'
