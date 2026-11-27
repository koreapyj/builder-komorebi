#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/00-setup-env.sh
source "$SCRIPT_DIR/00-setup-env.sh"

mkdir -p "$BUILD_ROOT/downloads" "$SOURCE_DIR"
fetch() {
    local url=$1 output=$2 checksum=$3 algorithm=$4
    if [[ ! -f "$output" ]]; then
        curl --fail --location --retry 3 --output "$output.part" "$url"
        mv "$output.part" "$output"
    fi
    printf '%s  %s\n' "$checksum" "$output" | "$algorithm" -c -
}

if [[ ! -d "$ANDROID_NDK_HOME" ]]; then
    [[ "$ANDROID_NDK_HOME" == "$PINNED_NDK_DIR" ]] || {
        printf 'FFMPEG_NDK does not exist: %s\n' "$ANDROID_NDK_HOME" >&2
        exit 1
    }
    archive="$BUILD_ROOT/downloads/android-ndk-${NDK_VERSION}-linux.zip"
    fetch "$NDK_URL" "$archive" "$NDK_SHA1" sha1sum
    rm -rf "$BUILD_ROOT/android-ndk-${NDK_VERSION}"
    unzip -q "$archive" -d "$BUILD_ROOT"
    mv "$BUILD_ROOT/android-ndk-${NDK_VERSION}" "$PINNED_NDK_DIR"
fi

clone_tag() {
    local url=$1 tag=$2 commit=$3 destination=$4
    if [[ ! -d "$destination/.git" ]]; then
        git clone --quiet --depth 1 --branch "$tag" "$url" "$destination"
    fi
    [[ "$(git -C "$destination" rev-parse HEAD)" == "$commit" ]] || {
        printf 'Unexpected commit in %s; remove it and rerun 01-fetch.sh.\n' "$destination" >&2
        exit 1
    }
}
ffmpeg="$SOURCE_DIR/jellyfin-ffmpeg"
if [[ -d "$ffmpeg/.git" && "$(git -C "$ffmpeg" rev-parse HEAD)" != "$JELLYFIN_FFMPEG_COMMIT" ]]; then
    printf 'Pinned jellyfin-ffmpeg changed; re-cloning %s\n' "$ffmpeg"
    rm -rf "$ffmpeg"
fi
clone_tag "$JELLYFIN_FFMPEG_URL" "$JELLYFIN_FFMPEG_VERSION" "$JELLYFIN_FFMPEG_COMMIT" "$ffmpeg"

builder="$SOURCE_DIR/builder-ffmpeg"
[[ -d "$builder/.git" ]] || git init -q "$builder"
if [[ "$(git -C "$builder" rev-parse -q --verify HEAD || true)" != "$BUILDER_FFMPEG_COMMIT" ]]; then
    git -C "$builder" fetch -q --depth 1 "$BUILDER_FFMPEG_URL" "$BUILDER_FFMPEG_COMMIT"
    git -C "$builder" checkout -q --detach FETCH_HEAD
fi
[[ "$(git -C "$builder" rev-parse HEAD)" == "$BUILDER_FFMPEG_COMMIT" ]] || {
    printf 'Unexpected commit in %s; remove it and rerun 01-fetch.sh.\n' "$builder" >&2
    exit 1
}

# Same layering as builder-ffmpeg: its source-patches are appended to Jellyfin's
# quilt series, followed by our own FFmpeg patches. The stamp records the set.
series="$ffmpeg/debian/patches/series"
local_dir="$THIRD_PARTY_DIR/ffmpeg/patches"
source_patches=()
for patch in "$builder"/source-patches/*.patch; do
    source_patches+=("$(basename "$patch")")
done
local_patches=()
for patch in "$local_dir"/*.patch; do
    local_patches+=("$(basename "$patch")")
done
wanted="$(cd "$builder/source-patches" && sha256sum "${source_patches[@]}")
$(cd "$local_dir" && sha256sum "${local_patches[@]}" | sed 's|  |  komorebi/|')"
stamp="$ffmpeg/.komorebi-patches-applied"
if [[ ! -f "$stamp" || "$(cat "$stamp")" != "$wanted" ]]; then
    rm -f "$stamp"
    [[ -f "$series.orig" ]] || cp "$series" "$series.orig"
    if (cd "$ffmpeg" && QUILT_PATCHES=debian/patches quilt top >/dev/null 2>&1); then
        (cd "$ffmpeg" && QUILT_PATCHES=debian/patches quilt pop -a -q)
    fi
    cp "$series.orig" "$series"
    for patch in "${source_patches[@]}"; do
        cp "$builder/source-patches/$patch" "$ffmpeg/debian/patches/"
        printf '%s\n' "$patch" >> "$series"
    done
    rm -rf "$ffmpeg/debian/patches/komorebi"
    mkdir "$ffmpeg/debian/patches/komorebi"
    for patch in "${local_patches[@]}"; do
        cp "$local_dir/$patch" "$ffmpeg/debian/patches/komorebi/"
        printf 'komorebi/%s\n' "$patch" >> "$series"
    done
    (cd "$ffmpeg" && QUILT_PATCHES=debian/patches quilt push -a -q --fuzz=0)
    printf '%s\n' "$wanted" > "$stamp"
fi
