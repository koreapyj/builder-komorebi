#!/usr/bin/env bash
set -euo pipefail

app="${1:?usage: patch-libaribcaption.sh <app-dir>}"
src="$app/src/main/cpp/third_party/libaribcaption"
patches="$(cd "$(dirname "${BASH_SOURCE[0]}")/../libaribcaption/patches" && pwd)"
[[ -d "$src/src" ]] || { printf 'Missing libaribcaption checkout: %s\n' "$src" >&2; exit 1; }

for patch in "$patches"/*.patch; do
    if git -C "$src" apply --check "$patch" 2>/dev/null; then
        git -C "$src" apply "$patch"
        printf 'Applied %s\n' "$(basename "$patch")"
    elif ! git -C "$src" apply -R --check "$patch" 2>/dev/null; then
        printf 'libaribcaption patch %s is neither applicable nor already applied.\n' "$(basename "$patch")" >&2
        exit 1
    fi
done
