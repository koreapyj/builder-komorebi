#!/usr/bin/env bash
# Usage: install-app.sh <app module dir> [abi...]   (default: every ABI in versions.env)
# Copies prebuilt/<abi> into <app>/src/main/jniLibs/<abi>/ and
# <app>/src/main/cpp/third_party/ffmpeg/<abi>/include/, touching nothing that is already current.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/versions.env
source "$SCRIPT_DIR/versions.env"

[[ $# -ge 1 && -d "$1" ]] || { printf 'Usage: %s <app module dir> [abi...]\n' "$0" >&2; exit 1; }
app=$1
shift
abis=("$@")
if [[ ${#abis[@]} -eq 0 ]]; then
    read -ra abis <<< "$FFMPEG_ABIS"
fi
read -ra libs <<< "$FFMPEG_LIBS"

for abi in "${abis[@]}"; do
    prebuilt="$THIRD_PARTY_DIR/prebuilt/$abi"
    [[ -f "$prebuilt/.build-id" ]] || { printf 'No complete FFmpeg build for %s; run build.sh first\n' "$abi" >&2; exit 1; }

    jni="$app/src/main/jniLibs/$abi"
    mkdir -p "$jni"
    for library in "${libs[@]}"; do
        cmp -s "$prebuilt/lib/$library" "$jni/$library" || install -m 0644 "$prebuilt/lib/$library" "$jni/$library"
    done

    include="$app/src/main/cpp/third_party/ffmpeg/$abi/include"
    if ! diff -r -q "$prebuilt/include" "$include" >/dev/null 2>&1; then
        rm -rf "$include"
        mkdir -p "$(dirname "$include")"
        cp -R "$prebuilt/include" "$include"
    fi
    printf 'FFmpeg %s installed in %s\n' "$abi" "$app"
done
