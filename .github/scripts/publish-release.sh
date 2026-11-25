#!/usr/bin/env bash
# Draft first, APKs attached, then published (which creates the tag), so clients never see a release without APKs.
set -euo pipefail
shopt -s nullglob

dist=$1

fail() { echo "::error::$*" >&2; exit 1; }

case "$CHANNEL" in
  stable) prerelease=false; latest=true ;;
  beta) prerelease=true; latest=false ;;
  *) fail "CHANNEL must be stable or beta, not '$CHANNEL'" ;;
esac
[[ $RELEASE_TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+.*-[0-9]+$ ]] || fail "unexpected release tag '$RELEASE_TAG'"
[[ $UPSTREAM_SHA =~ ^[0-9a-f]{40}$ ]] || fail "UPSTREAM_SHA '$UPSTREAM_SHA' is not a commit SHA"
[[ $BUILDER_SHA =~ ^[0-9a-f]{40}$ ]] || fail "BUILDER_SHA '$BUILDER_SHA' is not a commit SHA"
apks=("$dist"/*.apk)
[ "${#apks[@]}" -gt 0 ] || fail "no APKs in $dist"

body=$(cat <<EOF
Upstream [\`$UPSTREAM_TAG\`](https://github.com/$UPSTREAM_REPO/releases/tag/$UPSTREAM_TAG) (\`${UPSTREAM_SHA:0:7}\`) with this repository's patches at \`${BUILDER_SHA:0:7}\`.
${RUN_URL:+
Build: $RUN_URL}

komorebi-build: upstream=$UPSTREAM_SHA builder=$BUILDER_SHA
EOF
)

mapfile -t ids < <(gh api --paginate "repos/$GH_REPO/releases?per_page=100" \
  --jq ".[] | select(.tag_name == \"$RELEASE_TAG\") | .id")
if [ "${#ids[@]}" -gt 0 ]; then
  id=${ids[0]}
  echo "Reusing existing release $RELEASE_TAG (id $id)"
else
  id=$(gh api -X POST "repos/$GH_REPO/releases" \
    -f tag_name="$RELEASE_TAG" -f target_commitish="$BUILDER_SHA" -f name="$RELEASE_TAG" \
    -f body="$body" -F draft=true -F prerelease="$prerelease" --jq .id)
  echo "Created draft release $RELEASE_TAG (id $id)"
fi

gh release upload "$RELEASE_TAG" "${apks[@]}" --clobber

gh api -X PATCH "repos/$GH_REPO/releases/$id" \
  -f name="$RELEASE_TAG" -f body="$body" -f target_commitish="$BUILDER_SHA" \
  -F draft=false -F prerelease="$prerelease" -f make_latest="$latest" >/dev/null

got=$(gh api "repos/$GH_REPO/git/ref/tags/$RELEASE_TAG" --jq .object.sha)
[ "$got" = "$BUILDER_SHA" ] || fail "tag $RELEASE_TAG points at $got, expected $BUILDER_SHA"
echo "Published $CHANNEL release $RELEASE_TAG: $(gh api "repos/$GH_REPO/releases/$id" --jq .html_url)"
