#!/usr/bin/env bash
# Prints key=value lines for $GITHUB_OUTPUT: upstream_version_code, upstream_version_name,
# version_code (upstream * 100000 + build number), version_check (ok|mismatch|n/a).
set -euo pipefail

gradle_file=$1
build_number=$2
tag=${3:-}

fail() { echo "::error::$*" >&2; exit 1; }

[ -f "$gradle_file" ] || fail "$gradle_file not found in the upstream checkout"
[[ $build_number =~ ^[0-9]+$ ]] || fail "build number '$build_number' is not an integer"

# `versionCode = 19 // comment` -> 19 (only literal integers; assignments from properties are skipped)
mapfile -t codes < <(sed -nE 's/^[[:space:]]*versionCode[[:space:]]*=[[:space:]]*([0-9]+)([^0-9.].*)?$/\1/p' "$gradle_file")
if [ "${#codes[@]}" -ne 1 ]; then
  fail "expected exactly one 'versionCode = <integer>' line in $gradle_file, found ${#codes[@]}: ${codes[*]:-none}"
fi
upstream_code=$((10#${codes[0]}))
version_code=$((upstream_code * 100000 + 10#$build_number))
# Android's maximum versionCode.
[ "$version_code" -le 2100000000 ] || fail "versionCode $version_code exceeds 2100000000"

name=$(sed -nE 's/^[[:space:]]*versionName[[:space:]]*=[[:space:]]*"([^"]*)".*$/\1/p' "$gradle_file" | head -n1)

check=n/a
if [ -n "$tag" ]; then
  [[ $tag =~ ^([0-9]+\.[0-9]+\.[0-9]+) ]] || fail "upstream tag '$tag' does not start with X.Y.Z"
  xyz=${BASH_REMATCH[1]}
  if [[ $name =~ ^${xyz//./\\.}($|[^0-9.]) ]]; then
    check=ok
  else
    check=mismatch
  fi
fi

echo "upstream_version_code=$upstream_code"
echo "upstream_version_name=$name"
echo "version_code=$version_code"
echo "version_check=$check"
