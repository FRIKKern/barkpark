#!/usr/bin/env bash
# Build the Barkpark image from source in an Azure Container Registry, with
# `az acr build`, so no image comes from ghcr.io. Deploy acr.bicep first.
# Guide: docs/setup/SELF-HOST.md#build-the-image-from-source.
#
#   deploy/azure/acr-build.sh <registry> <git ref> [<git URL or local clone>]
#
# The source defaults to https://github.com/FRIKKern/barkpark.git. The script
# exports the ref with `git archive`, so uncommitted files never go in, and
# puts api/Dockerfile.dockerignore in place as .dockerignore. The root
# .dockerignore leaves out api/ for the web image, and `az acr build` uses only
# the root file, both to pick the upload and in its builder.
#
# It prints the image reference on stdout as the last line, for example
# crbarkpark1234.azurecr.io/barkpark:v0.2.31. Pass it to main.bicep as image,
# with acrName=<registry>.
set -euo pipefail

ACR="${1:-}" REF="${2:-}" SRC="${3:-https://github.com/FRIKKern/barkpark.git}"
if [ -z "$ACR" ] || [ -z "$REF" ]; then
  echo "usage: $0 <registry> <git ref> [<git URL or local clone>]" >&2
  exit 2
fi
for tool in az git tar; do
  command -v "$tool" >/dev/null || { echo "$tool is not installed" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ -d "$SRC" ]; then
  repo="$SRC"
else
  echo "Fetching $REF from $SRC" >&2
  git init -q "$work/repo"
  git -C "$work/repo" fetch -q --depth 1 "$SRC" "$REF"
  repo="$work/repo"
  REV=FETCH_HEAD
fi
REV="${REV:-$REF}"
SHA=$(git -C "$repo" rev-parse --verify "$REV^{commit}")

mkdir "$work/ctx"
git -C "$repo" archive "$SHA" | tar -x -C "$work/ctx"
cp "$work/ctx/api/Dockerfile.dockerignore" "$work/ctx/.dockerignore"

# A ref of letters, digits, dots, dashes and underscores, such as v0.2.31,
# becomes the image tag. Any other ref, and a full commit id, becomes
# sha-<12 characters>. The image reports VERSION and the full commit.
case "$REF" in
  *[!A-Za-z0-9._-]*) TAG="sha-${SHA:0:12}" ;;
  *) TAG="$REF" ;;
esac
[ "$TAG" = "$SHA" ] && TAG="sha-${SHA:0:12}"

echo "Building $ACR.azurecr.io/barkpark:$TAG from commit $SHA" >&2
VERSION=$(tr -d '[:space:]' <"$work/ctx/VERSION")
az acr build -r "$ACR" -t "barkpark:$TAG" -f api/Dockerfile --timeout 3600 \
  --build-arg "BARKPARK_BUILD_VERSION=$VERSION" --build-arg "BARKPARK_BUILD_COMMIT=$SHA" \
  "$work/ctx" >&2

LOGIN=$(az acr show -n "$ACR" --query loginServer -o tsv)
echo "$LOGIN/barkpark:$TAG"
