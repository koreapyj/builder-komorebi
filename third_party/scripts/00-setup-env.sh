#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2317
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/versions.env
source "$SCRIPT_DIR/versions.env"

PINNED_NDK_DIR="$BUILD_ROOT/ndk-$NDK_VERSION"

find_installed_ndk() {
    local sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}} ndk
    [[ -n "$sdk" && -d "$sdk/ndk" ]] || return 1
    ndk=$(find "$sdk/ndk" -mindepth 1 -maxdepth 1 -type d -exec test -f '{}/source.properties' ';' -print | sort -V | tail -n 1)
    [[ -n "$ndk" ]] && printf '%s\n' "$ndk"
}

if [[ -n "${FFMPEG_NDK:-}" ]]; then
    ANDROID_NDK_HOME=$FFMPEG_NDK
elif ndk=$(find_installed_ndk); then
    ANDROID_NDK_HOME=$ndk
else
    ANDROID_NDK_HOME=$PINNED_NDK_DIR
fi
export ANDROID_NDK_HOME

TOOLCHAIN_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
NDK_REVISION=
if [[ -d "$ANDROID_NDK_HOME" ]]; then
    [[ -x "$TOOLCHAIN_BIN/${TARGET_TRIPLE}${ANDROID_API}-clang" ]] || {
        printf 'NDK toolchain for %s API %s is missing at %s\n' "$TARGET_TRIPLE" "$ANDROID_API" "$TOOLCHAIN_BIN" >&2
        return 1 2>/dev/null || exit 1
    }
    NDK_REVISION=$(sed -n 's/^Pkg.Revision *= *//p' "$ANDROID_NDK_HOME/source.properties")
    export PATH="$TOOLCHAIN_BIN:$PATH"
    export CC="$TOOLCHAIN_BIN/${TARGET_TRIPLE}${ANDROID_API}-clang"
    export CXX="$TOOLCHAIN_BIN/${TARGET_TRIPLE}${ANDROID_API}-clang++"
    export AR="$TOOLCHAIN_BIN/llvm-ar"
    export RANLIB="$TOOLCHAIN_BIN/llvm-ranlib"
    export STRIP="$TOOLCHAIN_BIN/llvm-strip"
    export NM="$TOOLCHAIN_BIN/llvm-nm"
fi

export PKG_CONFIG_LIBDIR="$INSTALL_PREFIX/lib/pkgconfig"
unset PKG_CONFIG_SYSROOT_DIR
