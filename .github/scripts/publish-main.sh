#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

dist=$1
tag=nightly
marker="komorebi-build: upstream=$UPSTREAM_SHA builder=$BUILDER_SHA"
marker_re='komorebi-build: upstream=[0-9a-f]{40} builder=[0-9a-f]{40}'

fail() { echo "::error::$*" >&2; exit 1; }

[[ $UPSTREAM_SHA =~ ^[0-9a-f]{40}$ ]] || fail "UPSTREAM_SHA '$UPSTREAM_SHA' is not a commit SHA"
[[ $BUILDER_SHA =~ ^[0-9a-f]{40}$ ]] || fail "BUILDER_SHA '$BUILDER_SHA' is not a commit SHA"
apks=("$dist"/*.apk)
[ "${#apks[@]}" -gt 0 ] || fail "no APKs in $dist"

get_or_404() {
  local out err
  err=$(mktemp)
  if out=$(gh api "$1" 2>"$err"); then
    rm -f "$err"; printf '%s' "$out"; return 0
  fi
  if grep -q 'HTTP 404' "$err"; then
    rm -f "$err"; return 1
  fi
  cat "$err" >&2; rm -f "$err"; fail "GitHub API request $1 failed"
}

# Listing (not releases/tags/nightly) also finds a draft left by an interrupted tag fallback, so it is reused.
mapfile -t ids < <(gh api --paginate "repos/$GH_REPO/releases?per_page=100" \
  --jq ".[] | select(.tag_name == \"$tag\") | .id")
if [ "${#ids[@]}" -gt 1 ]; then
  echo "::warning::${#ids[@]} releases use tag '$tag' (${ids[*]}); updating ${ids[0]} only"
fi
if [ "${#ids[@]}" -gt 0 ]; then
  id=${ids[0]}
  release=$(gh api "repos/$GH_REPO/releases/$id")
  current=$(jq -r '.body // ""' <<<"$release" | grep -oE "$marker_re" | sed -n 1p || true)
  napk=$(jq '[.assets[] | select(.name | endswith(".apk"))] | length' <<<"$release")
  draft=$(jq -r .draft <<<"$release")
  echo "Current '$tag' release: id $id, draft=$draft, ${current:-no build-info line}, $napk APK(s)"
  if [ "$current" = "$marker" ] && [ "$napk" -gt 0 ] && [ "$draft" = false ]; then
    echo "::notice::The '$tag' release was already built from upstream ${UPSTREAM_SHA:0:7} + builder ${BUILDER_SHA:0:7}; not publishing."
    exit 0
  fi
else
  # creating the release also creates the tag at BUILDER_SHA
  echo "No '$tag' release yet; creating it"
  id=$(gh api -X POST "repos/$GH_REPO/releases" \
    -f tag_name="$tag" -f target_commitish="$BUILDER_SHA" -f name="$LABEL (publishing)" \
    -f body="Publishing in progress." -F prerelease=true -F draft=false -f make_latest=false \
    --jq .id)
fi

# Upload first so the release is never without APKs for long.
gh release upload "$tag" "${apks[@]}" --clobber

declare -A keep=()
for apk in "${apks[@]}"; do keep[$(basename "$apk")]=1; done
while IFS=$'\t' read -r asset_id asset_name; do
  [ -n "$asset_id" ] || continue
  if [ -z "${keep[$asset_name]:-}" ]; then
    echo "Deleting old asset $asset_name"
    gh api -X DELETE "repos/$GH_REPO/releases/assets/$asset_id"
  fi
done < <(gh api --paginate "repos/$GH_REPO/releases/$id/assets" --jq '.[] | [.id, .name] | @tsv')

if get_or_404 "repos/$GH_REPO/git/ref/tags/$tag" >/dev/null; then
  if ! gh api -X PATCH "repos/$GH_REPO/git/refs/tags/$tag" -f sha="$BUILDER_SHA" -F force=true >/dev/null; then
    # Fallback: deleting the tag turns the release into a draft for a moment; the release update below re-creates it.
    echo "::warning::Could not move tag '$tag' in place; re-creating it through the release"
    gh api -X DELETE "repos/$GH_REPO/git/refs/tags/$tag"
  fi
else
  echo "Tag '$tag' is missing; the release update below re-creates it"
fi

# The build-info line is written last, so an interrupted run is never mistaken for a completed one.
body=$(cat <<EOF
Rolling build of upstream [\`main\`](https://github.com/$UPSTREAM_REPO/tree/$UPSTREAM_SHA) (\`${UPSTREAM_SHA:0:7}\`) with this repository's patches at \`${BUILDER_SHA:0:7}\`.
Replaced automatically whenever upstream \`main\` or this repository changes. Not a stable release.
${RUN_URL:+
Build: $RUN_URL}

$marker
EOF
)
gh api -X PATCH "repos/$GH_REPO/releases/$id" \
  -f tag_name="$tag" -f target_commitish="$BUILDER_SHA" \
  -f name="$LABEL (upstream ${UPSTREAM_SHA:0:7})" -f body="$body" \
  -F prerelease=true -F draft=false -f make_latest=false >/dev/null

got=$(gh api "repos/$GH_REPO/git/ref/tags/$tag" --jq .object.sha)
[ "$got" = "$BUILDER_SHA" ] || fail "tag '$tag' points at $got, expected $BUILDER_SHA"
echo "Published $LABEL to the '$tag' release"
