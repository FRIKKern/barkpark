#!/usr/bin/env bash
# Wire the App creds into the Barkpark instance: PUT the six github.* settings via
# the admin plugin-settings API, then verify the plugin goes active.
#
# Inputs:
#   --creds   <file>   the JSON from github-app-bootstrap.py (app_id, private_key, webhook_secret)
#   --install <id>     the App Installation ID (from installing the App on the repo)
#   --repo    <o/r>    default FRIKKern/barkpark
#   --project <PVT_…>  optional Projects v2 board node id (from github-projects-setup.sh)
#   --base    <url>    instance base (default: the bp-configured server)
#   --token   <tok>    admin token (default: the bp-configured token)
#
# The stored plugin_settings row is keyed "github" with BARE keys (repo, app_id,
# installation_id, private_key, webhook_secret, project_id) — the shape
# Settings.get_credentials/0 reads.
set -euo pipefail

CREDS="" INSTALL="" REPO="FRIKKern/barkpark" PROJECT="" BASE="" TOKEN=""
while [ $# -gt 0 ]; do case "$1" in
  --creds) CREDS="$2"; shift 2;; --install) INSTALL="$2"; shift 2;;
  --repo) REPO="$2"; shift 2;; --project) PROJECT="$2"; shift 2;;
  --base) BASE="$2"; shift 2;; --token) TOKEN="$2"; shift 2;;
  *) echo "unknown arg $1" >&2; exit 1;; esac; done

[ -n "$CREDS" ] && [ -f "$CREDS" ] || { echo "--creds <file> required" >&2; exit 1; }
[ -n "$INSTALL" ] || { echo "--install <installation_id> required" >&2; exit 1; }

CFG="$HOME/.config/barkpark/config.json"
[ -n "$BASE" ]  || BASE="$(python3 -c "import json;print(json.load(open('$CFG'))['server'])")"
[ -n "$TOKEN" ] || TOKEN="$(python3 -c "import json;print(json.load(open('$CFG'))['token'])")"

# Build the settings map (bare keys) from the creds file + args.
BODY="$(CREDS="$CREDS" INSTALL="$INSTALL" REPO="$REPO" PROJECT="$PROJECT" python3 - <<'PY'
import json, os
c = json.load(open(os.environ["CREDS"]))
settings = {
    "repo": os.environ["REPO"],
    "app_id": str(c["app_id"]),
    "installation_id": str(os.environ["INSTALL"]),
    "private_key": c["private_key"],
    "webhook_secret": c["webhook_secret"],
}
if os.environ.get("PROJECT"):
    settings["project_id"] = os.environ["PROJECT"]
print(json.dumps({"settings": settings}))
PY
)"

echo ">> PUT ${BASE%/}/v1/plugins/settings/github ..."
code="$(curl -sS -o /tmp/gh-provision.out -w '%{http_code}' \
  -X PUT "${BASE%/}/v1/plugins/settings/github" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data "$BODY")"
if [ "$code" != "200" ]; then
  echo "!! settings PUT returned HTTP $code:" >&2; cat /tmp/gh-provision.out >&2; echo >&2; exit 1
fi
echo "   settings stored (HTTP 200)."

echo ">> Verifying with bp github status ..."
if command -v bp >/dev/null; then
  bp github status 2>&1 | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin); h=d.get("health",d)
    print("   active:", h.get("active"), "| repo:", h.get("repo"))
except Exception:
    print("   (could not parse bp github status output — check manually)")' || true
fi
echo
echo "If active:false, the plugin may not be whitelisted on this instance — add"
echo "'github' to BARKPARK_PLUGINS and restart (or it is already all-plugins-on)."
echo "Then re-run the round-trip verify in docs/ops/github-sync.md §5."
