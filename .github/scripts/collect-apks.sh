#!/usr/bin/env bash
# Asset names: release komorebi-<label>-<abi>.apk, debug komorebi-<label>-<abi>-debug.apk
set -euo pipefail
shopt -s nullglob

variant=$1
apk_dir=$2
out_dir=$3
label=$4
abis=(arm64-v8a armeabi-v7a universal)

fail() { echo "::error::$*" >&2; exit 1; }

case "$variant" in
  release|debug) ;;
  *) fail "unknown variant '$variant'" ;;
esac

apks=("$apk_dir"/*.apk)
[ "${#apks[@]}" -gt 0 ] || fail "no $variant APKs in $apk_dir"
mkdir -p "$out_dir"

if [ "$variant" = release ]; then
  bt=$(find "$ANDROID_HOME/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n1)
  [ -n "$bt" ] || fail "no Android build-tools under $ANDROID_HOME"
  echo "Using build-tools $(basename "$bt")"
  tmp=$(mktemp -d "${RUNNER_TEMP:-/tmp}/sign.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT
  ks="$tmp/release.keystore"
  printf '%s' "$KEYSTORE_BASE64" | base64 -d > "$ks"
fi

for apk in "${apks[@]}"; do
  # Gradle names: app-<abi>-release-unsigned.apk / app-<abi>-debug.apk
  abi=$(basename "$apk" .apk)
  abi=${abi#app-}
  abi=${abi%-unsigned}
  abi=${abi%-"$variant"}
  if [ "$variant" = release ]; then
    out="$out_dir/komorebi-$label-$abi.apk"
    aligned="$tmp/$abi-aligned.apk"
    "$bt/zipalign" -f -p 4 "$apk" "$aligned"
    "$bt/zipalign" -c -p 4 "$aligned"
    "$bt/apksigner" sign --ks "$ks" \
      --ks-pass env:KEYSTORE_PASSWORD \
      --ks-key-alias "$KEY_ALIAS" \
      --key-pass env:KEY_PASSWORD \
      --out "$out" "$aligned"
    "$bt/apksigner" verify "$out"
    rm -f "$aligned"
  else
    out="$out_dir/komorebi-$label-$abi-debug.apk"
    cp "$apk" "$out"
  fi
done

for abi in "${abis[@]}"; do
  ls "$out_dir"/komorebi-"$label"-"$abi"*.apk >/dev/null 2>&1 || fail "no $abi APK was built"
done
ls -l "$out_dir"
