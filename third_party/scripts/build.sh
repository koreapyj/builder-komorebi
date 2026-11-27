#!/usr/bin/env bash
# Usage: build.sh [abi...]   (default: every ABI in versions.env)
# Rebuilds an ABI only when its prebuilt/ output is missing or was built from
# different third_party/ inputs or a different NDK revision.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/versions.env
source "$SCRIPT_DIR/versions.env"

abis=("$@")
if [[ ${#abis[@]} -eq 0 ]]; then
    read -ra abis <<< "$FFMPEG_ABIS"
fi

inputs_id=$(cd "$THIRD_PARTY_DIR" \
    && find . -path ./prebuilt -prune -o -type f -print | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1)

build_id() {
    # shellcheck disable=SC2016
    printf '%s builder-ffmpeg=%s@%s ndk=%s\n' "$inputs_id" "$BUILDER_FFMPEG_URL" "$BUILDER_FFMPEG_COMMIT" \
        "$(FFMPEG_ABI=$1 bash -c 'source "$1/00-setup-env.sh" && printf "%s" "$NDK_REVISION"' _ "$SCRIPT_DIR")"
}

for abi in "${abis[@]}"; do
    stamp="$THIRD_PARTY_DIR/prebuilt/$abi/.build-id"
    if [[ -f "$stamp" && "$(cat "$stamp")" == "$(build_id "$abi")" ]]; then
        printf 'FFmpeg %s is up to date\n' "$abi"
        continue
    fi
    rm -f "$stamp"
    start=$SECONDS
    for step in 01-fetch.sh 02-build-opencl-loader.sh 03-build-ffmpeg.sh 04-install-prebuilt.sh; do
        FFMPEG_ABI=$abi "$SCRIPT_DIR/$step"
    done
    build_id "$abi" > "$stamp"
    printf 'FFmpeg %s built in %ss\n' "$abi" "$((SECONDS - start))"
done
