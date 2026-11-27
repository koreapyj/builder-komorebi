#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/00-setup-env.sh
source "$SCRIPT_DIR/00-setup-env.sh"

rm -rf "$PREBUILT_DIR"
mkdir -p "$PREBUILT_DIR/lib" "$PREBUILT_DIR/include"

for library in $FFMPEG_LIBS; do
    source_path="$INSTALL_PREFIX/lib/$library"
    [[ -f "$source_path" ]] || { printf 'Missing built library: %s\n' "$source_path" >&2; exit 1; }
    install -m 0644 "$source_path" "$PREBUILT_DIR/lib/$library"
    "$STRIP" --strip-unneeded "$PREBUILT_DIR/lib/$library"
done

for header_dir in libavcodec libavfilter libavutil libswscale CL; do
    cp -R "$INSTALL_PREFIX/include/$header_dir" "$PREBUILT_DIR/include/"
done

printf 'Installed %s FFmpeg in %s (NDK %s, API %s):\n' "$ANDROID_ABI" "$PREBUILT_DIR" "$NDK_REVISION" "$ANDROID_API"
du -h "$PREBUILT_DIR"/lib/*.so
