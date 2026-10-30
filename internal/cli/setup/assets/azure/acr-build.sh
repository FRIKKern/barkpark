#!/usr/bin/env bash
# Build the Barkpark image from source in an Azure Container Registry, with
# `az acr build`, so no image comes from ghcr.io. Deploy acr.bicep first.
# Guide: docs/setup/SELF-HOST.md#build-the-image-from-source.
#
#   deploy/azure/acr-build.sh <registry> <git ref> [<git URL or local clone>]
#
# The source defaults to https://github.com/FRIKKern/barkpark.git. The script
# exports the ref with `git archive`, so uncommitted files never go in. It
# exports only api/Dockerfile and the paths its COPY lines name, about 17 MiB
# packed instead of 71 MiB for the whole repo, and drops .gitignore files,
# which `az acr build` would list one by one. It puts
# api/Dockerfile.dockerignore in place as .dockerignore, because the root
# .dockerignore leaves out api/ for the web image.
#
# It queues the run with --no-wait and polls `az acr task show-run` every
# 20 seconds, printing the status, until the run ends. Streaming the logs went
# on for 10 minutes after a 6 minute run on 2026-10-30. A failed run prints
# the command that shows its log.
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

# The image needs no Git LFS file, and the screenshots in LFS are 100 MB.
export GIT_LFS_SKIP_SMUDGE=1
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

# The context is api/Dockerfile and each source of its COPY lines that has no
# --from. Every COPY in it is one line with plain paths; refuse any other form
# rather than upload too little.
DOCKERFILE=$(git -C "$repo" show "$SHA:api/Dockerfile")
if printf '%s\n' "$DOCKERFILE" | grep -Eq '^COPY .*(\\$|\[)'; then
  echo "api/Dockerfile has a COPY this script cannot read; use one line and plain paths" >&2
  exit 1
fi
paths=$(printf '%s\n' "$DOCKERFILE" | awk '$1 == "COPY" && $0 !~ /--from=/ {
  for (i = 2; i < NF; i++) if ($i !~ /^--/) print $i }' | sort -u)
[ -n "$paths" ] || { echo "api/Dockerfile has no COPY of the build context" >&2; exit 1; }
mkdir "$work/ctx"
# shellcheck disable=SC2086 # one path per word, none has a space
git -C "$repo" archive "$SHA" api/Dockerfile $paths | tar -x -C "$work/ctx"
find "$work/ctx" -name .gitignore -type f -delete
git -C "$repo" show "$SHA:api/Dockerfile.dockerignore" >"$work/ctx/.dockerignore"
echo "Build context: $(du -sk "$work/ctx" | cut -f1) KiB from $(printf '%s\n' "$paths" | wc -l | tr -d ' ') paths" >&2

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
# az reads the -f path from the current directory, so build from the context.
# With --no-wait az prints nothing on stdout, so the run id comes from its
# "Queued a build with ID" line on stderr, which still reaches the caller.
queued=$(cd "$work/ctx" && az acr build -r "$ACR" -t "barkpark:$TAG" -f api/Dockerfile --timeout 3600 \
  --build-arg "BARKPARK_BUILD_VERSION=$VERSION" --build-arg "BARKPARK_BUILD_COMMIT=$SHA" \
  --no-wait . 2>&1 >/dev/null | tee /dev/stderr)
RUN_ID=$(printf '%s\n' "$queued" | sed -n 's/.*Queued a build with ID: *\([A-Za-z0-9-]*\).*/\1/p' | tail -n 1)
[ -n "$RUN_ID" ] || { echo "az acr build queued no run" >&2; exit 1; }
echo "Queued run $RUN_ID; polling every ${ACR_BUILD_POLL:-20}s" >&2

start=$(date +%s) status=""
while :; do
  status=$(az acr task show-run -r "$ACR" --run-id "$RUN_ID" --query status -o tsv) || status=""
  echo "  $(( $(date +%s) - start ))s: run $RUN_ID ${status:-not readable}" >&2
  case "$status" in
    Succeeded) break ;;
    Failed | Canceled | Error | Timeout)
      echo "Run $RUN_ID ended $status. Its log: az acr task logs -r $ACR --run-id $RUN_ID" >&2
      exit 1 ;;
  esac
  if [ $(( $(date +%s) - start )) -gt 3900 ]; then
    echo "Run $RUN_ID is still $status after 65 minutes. Its log: az acr task logs -r $ACR --run-id $RUN_ID" >&2
    exit 1
  fi
  sleep "${ACR_BUILD_POLL:-20}"
done

LOGIN=$(az acr show -n "$ACR" --query loginServer -o tsv)
echo "$LOGIN/barkpark:$TAG"
