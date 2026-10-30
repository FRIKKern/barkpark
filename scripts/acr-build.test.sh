#!/usr/bin/env bash
# check() evals its condition later, so single quotes are intended.
# shellcheck disable=SC2016,SC2034
# Runs deploy/azure/acr-build.sh against this clone with a fake `az`:
#   - the upload holds api/Dockerfile and the paths its COPY lines name, with
#     no .gitignore file and none of web/, js/ or docs/;
#   - the build is queued with --no-wait, and show-run is polled until it ends;
#   - the last stdout line is the image ref, and a failed run exits 1.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
check() { if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1"; fails=$((fails + 1)); fi; }

SHA="$(git -C "$ROOT" rev-parse HEAD)"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/az" <<'AZ'
#!/usr/bin/env bash
echo "az $*" >> "$CALLS"
case "$1 $2" in
  "acr build")
    find . -type f | sed 's#^\./##' | sort > "$CTX_LIST"
    # With --no-wait the real az prints only stderr lines, the run id among them.
    echo "WARNING: Packing source code into tar to upload..." >&2
    echo "WARNING: Queued a build with ID: run-7" >&2 ;;
  "acr task")
    n=$(( $(cat "$POLLS" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$POLLS"
    # FAKE_STATUSES: one status per poll; the last one repeats.
    set -- $FAKE_STATUSES
    shift $(( n > $# ? $# - 1 : n - 1 )); echo "$1" ;;
  "acr show") echo "crtest.azurecr.io" ;;
esac
AZ
chmod +x "$TMP/bin/az"

run() {
  rm -f "$TMP/calls" "$TMP/polls" "$TMP/ctx"
  env PATH="$TMP/bin:$PATH" CALLS="$TMP/calls" POLLS="$TMP/polls" CTX_LIST="$TMP/ctx" ACR_BUILD_POLL=0 "$@" \
    bash "$ROOT/deploy/azure/acr-build.sh" crtest "$SHA" "$ROOT" 2>"$TMP/err"
}

echo "== a run that succeeds =="
out="$(run FAKE_STATUSES="Queued Running Running Succeeded")"; rc=$?
check "it exits 0" '[ "$rc" -eq 0 ]'
check "the last stdout line is the image ref" '[ "$(tail -1 <<<"$out")" = "crtest.azurecr.io/barkpark:sha-${SHA:0:12}" ]'
check "the build is queued with --no-wait" 'grep -q "^az acr build .*--no-wait" "$TMP/calls"'
check "az stderr still reaches the caller" 'grep -q "Packing source code" "$TMP/err"'
check "it polls show-run until the run ends" '[ "$(grep -c "^az acr task show-run -r crtest --run-id run-7" "$TMP/calls")" -eq 4 ]'
check "it prints each poll on stderr" 'grep -q "run run-7 Running" "$TMP/err" && grep -q "run run-7 Succeeded" "$TMP/err"'
check "the upload has the Dockerfile, its .dockerignore and the copied paths" 'grep -qx api/Dockerfile "$TMP/ctx" && grep -qx .dockerignore "$TMP/ctx" && grep -qx VERSION "$TMP/ctx" && grep -qx api/mix.exs "$TMP/ctx" && grep -q "^api/lib/" "$TMP/ctx" && grep -q "^design/" "$TMP/ctx" && grep -qx cloud/priv/secret-scrub.exs "$TMP/ctx" && grep -q "^tooling/pds/" "$TMP/ctx"'
check "the upload has no .gitignore file" '! grep -q "\(^\|/\)\.gitignore$" "$TMP/ctx"'
check "the upload has nothing outside the COPY paths" '! grep -q "^\(web\|js\|docs\|internal\|scripts\|deploy\)/" "$TMP/ctx" && ! grep -q "^cloud/lib/" "$TMP/ctx"'

echo "== a run that fails =="
out="$(run FAKE_STATUSES="Running Failed")"; rc=$?
check "it exits 1 and prints no image ref" '[ "$rc" -eq 1 ] && ! grep -q azurecr.io <<<"$out"'
check "it names the command that shows the log" 'grep -q "az acr task logs -r crtest --run-id run-7" "$TMP/err"'

if [ "$fails" -ne 0 ]; then echo "acr-build: $fails failed"; exit 1; fi
echo "acr-build: all checks passed"
