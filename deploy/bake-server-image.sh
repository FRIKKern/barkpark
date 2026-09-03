#!/usr/bin/env bash
# bake-server-image.sh — the nightly warm-image bake (snapshot-management).
#
# THE structural fix for "every deploy has to update Barkpark first": the baked
# snapshot used to be a hand-managed, ever-staler pin, so claim-time freshen
# paid a 4-6 minute on-box rebuild for the accumulated drift. This pipeline
# keeps the snapshot tracking main automatically:
#
#   1. Resolve the newest `role=warm-image` snapshot and the commit label the
#      last bake stamped on it.
#   2. Compare against origin/main via the GitHub API. Already current → exit.
#      Drift confined to box-irrelevant paths (docs/, cloud/, web/, js/,
#      .github/, .claude/, tooling/, *.md — mirroring EnsureFresh's
#      boxIrrelevantPrefixes in internal/cli/cloud/freshen.go) → exit.
#   3. Boot a bake box FROM the newest snapshot, fast-forward it to
#      origin/main, run the full deploy-rebuild, pre-run migrations (throwaway
#      keys, stripped before the snapshot — no secrets ever ship in an image),
#      reset the inherited demo seed (delete-only TRUNCATE after the key
#      restore, counts reported, schema_migrations kept — PDF-D103; a reset
#      failure warns loudly but never kills the bake), clean build residue,
#      verify HEAD, power off.
#   4. Snapshot it with labels role=warm-image + commit=<sha>. The provisioner
#      resolves the newest labeled snapshot DYNAMICALLY (cloud.ResolveWarmImage),
#      so the fresh bake goes live with no env edit and no worker restart, and
#      the pool reconciler recycles standing warm boxes onto it one per pass.
#   5. Prune old bakes (keep the newest 2 — one rollback), delete the bake box.
#
# Runs on the control host under the barkpark-image-bake.timer (systemd,
# nightly); env comes from /etc/barkpark-provisioner.env (HCLOUD_TOKEN,
# BARKPARK_SSH_KEY, BARKPARK_SSH_KEY_FILE, BARKPARK_SERVER_IMAGE fallback).
# Manual run: systemctl start barkpark-image-bake.service (or invoke directly).
# Any failure exits non-zero with the bake box torn down; the next night retries.
set -euo pipefail

REPO="${BAKE_GITHUB_REPO:-FRIKKern/barkpark}"
SERVER_TYPE="${BARKPARK_SERVER_TYPE:-cx23}"
LOCATION="${BARKPARK_SERVER_LOCATION:-nbg1}"
SSH_KEY_NAME="${BARKPARK_SSH_KEY:-}"
SSH_KEY_FILE="${BARKPARK_SSH_KEY_FILE:-/root/.ssh/barkpark_indx}"
KEEP_IMAGES="${BAKE_KEEP_IMAGES:-2}"
BOX_NAME="bp-imagebake-$(date -u +%Y%m%d%H%M)"

log() { echo "[image-bake] $*"; }
py() { python3 -c "$1"; }

# One bake at a time — a slow snapshot must not overlap the next timer firing.
exec 9>/var/lock/barkpark-image-bake.lock
flock -n 9 || { log "another bake is running; exiting"; exit 0; }

command -v hcloud >/dev/null || { log "FATAL: hcloud CLI not found"; exit 1; }
[ -f "$SSH_KEY_FILE" ] || { log "FATAL: ssh key file $SSH_KEY_FILE not found"; exit 1; }

BOX_CREATED=0
cleanup() {
  if [ "$BOX_CREATED" = 1 ]; then
    log "cleanup: deleting bake box $BOX_NAME"
    hcloud server delete "$BOX_NAME" >/dev/null 2>&1 || log "WARNING: bake box $BOX_NAME delete failed — delete it manually"
  fi
}
trap cleanup EXIT

# ── 1. The newest labeled bake + its commit ──────────────────────────────────
IMAGES_JSON="$(hcloud image list --type snapshot --selector role=warm-image -o json)"
read -r BASE_IMAGE BAKED_COMMIT <<EOF2
$(printf '%s' "$IMAGES_JSON" | py '
import json, sys
imgs = [i for i in json.load(sys.stdin) if i.get("status") == "available"]
imgs.sort(key=lambda i: i.get("created", ""), reverse=True)
if imgs:
    top = imgs[0]
    print(top["id"], top.get("labels", {}).get("commit", "-"))
else:
    print("-", "-")
')
EOF2
if [ "$BASE_IMAGE" = "-" ]; then
  BASE_IMAGE="${BARKPARK_SERVER_IMAGE:-}"
  BAKED_COMMIT="-"
  [ -n "$BASE_IMAGE" ] || { log "FATAL: no labeled bake and no BARKPARK_SERVER_IMAGE fallback"; exit 1; }
  log "no labeled bake yet — bootstrapping from env image $BASE_IMAGE"
fi
log "base image: $BASE_IMAGE (baked commit: $BAKED_COMMIT)"

# ── 2. Drift check against origin/main (public repo, unauthenticated API) ────
MAIN_SHA="$(curl -fsS "https://api.github.com/repos/$REPO/commits/main" | py 'import json,sys; print(json.load(sys.stdin)["sha"])')"
log "origin/main: $MAIN_SHA"

if [ "$BAKED_COMMIT" = "$MAIN_SHA" ]; then
  log "bake is current — nothing to do"
  exit 0
fi

if [ "$BAKED_COMMIT" != "-" ]; then
  # Box-relevant drift filter (mirror of freshen.go boxIrrelevantPrefixes): if
  # every changed file is inert for the box, a bake buys nothing.
  RELEVANT="$(curl -fsS "https://api.github.com/repos/$REPO/compare/$BAKED_COMMIT...$MAIN_SHA" | py '
import json, sys
data = json.load(sys.stdin)
files = [f.get("filename", "") for f in data.get("files", [])]
inert_prefixes = ("docs/", "cloud/", "web/", "js/", ".github/", ".claude/", "tooling/")
def inert(p):
    return p.endswith(".md") or any(p.startswith(pre) for pre in inert_prefixes)
relevant = [p for p in files if p and not inert(p)]
# An empty/oversized compare (files capped at 300, or an unknown base after a
# force-push) reports "relevant" so we bake rather than silently skip.
print("yes" if (relevant or not files) else "no")
' || echo yes)"
  if [ "$RELEVANT" = "no" ]; then
    log "drift since $BAKED_COMMIT is box-irrelevant — skipping bake"
    exit 0
  fi
fi

# ── 3. Boot the bake box from the newest snapshot ────────────────────────────
log "creating bake box $BOX_NAME ($SERVER_TYPE/$LOCATION from $BASE_IMAGE)"
SSH_ARGS=()
[ -n "$SSH_KEY_NAME" ] && SSH_ARGS=(--ssh-key "$SSH_KEY_NAME")
hcloud server create --name "$BOX_NAME" --type "$SERVER_TYPE" --location "$LOCATION" \
  --image "$BASE_IMAGE" "${SSH_ARGS[@]}" --label role=imagebake >/dev/null
BOX_CREATED=1
BOX_IP="$(hcloud server ip "$BOX_NAME")"
log "bake box up at $BOX_IP — waiting for ssh"

SSH=(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "root@$BOX_IP")
for i in $(seq 1 60); do
  "${SSH[@]}" true 2>/dev/null && break
  [ "$i" = 60 ] && { log "FATAL: ssh never came up on $BOX_IP"; exit 1; }
  sleep 5
done

# ── On-box: fast-forward + rebuild + pre-run migrations + strip + clean ──────
log "freshening the box to origin/main (full rebuild — this is the slow part)"
"${SSH[@]}" bash -s <<'BAKE'
set -euo pipefail
cd /opt/barkpark
# No tty on this ssh heredoc: without GIT_TERMINAL_PROMPT=0 a git that wants a
# username blocks until the 120s timeout and reports only "timed out". The
# failure arm names the git version because "could not read Username" is the
# symptom BOTH of a credential problem and of the protocol-v2 refusal seen on
# git 2.34.x boxes (deploy/cp-deploy.sh, PR #15634).
export GIT_TERMINAL_PROMPT=0
timeout 120 git fetch origin --tags --prune || {
  echo "FATAL: git fetch origin --tags --prune failed on the bake box" >&2
  echo "  git version      : $(git --version 2>&1)" >&2
  echo "  protocol.version : $(git config --get protocol.version 2>/dev/null || echo 'unset/default')" >&2
  echo "  A 'could not read Username' here can be the WIRE protocol, not credentials." >&2
  echo "  Retry with: git -c protocol.version=0 fetch origin --tags --prune" >&2
  exit 11
}
git -c core.hooksPath=/dev/null merge --ff-only origin/main
timeout 2400 bash scripts/deploy-rebuild.sh

# Pre-run migrations with THROWAWAY keys so a provisioned box's migrate is a
# no-op; the keys are stripped below — an image never ships secrets (the
# go-live's secrets-install writes the real per-instance set).
export PATH="$HOME/.asdf/shims:$PATH"; . "$HOME/.asdf/asdf.sh" 2>/dev/null || true
cp /opt/barkpark/.env /tmp/env.pre-bake 2>/dev/null || touch /tmp/env.pre-bake
grep -v -e '^SECRET_KEY_BASE=' -e '^BARKPARK_KEK=' -e '^BARKPARK_CLOAK_KEY=' -e '^PREVIEW_JWT_SECRET=' -e '^BARKPARK_RELEASE_CAPTURE_HMAC_SECRET=' /tmp/env.pre-bake > /tmp/env.bake || true
{
  cat /tmp/env.bake
  echo "SECRET_KEY_BASE=$(head -c 48 /dev/urandom | base64)"
  echo "BARKPARK_KEK=$(head -c 32 /dev/urandom | base64)"
  echo "BARKPARK_CLOAK_KEY=$(head -c 32 /dev/urandom | base64)"
  echo "PREVIEW_JWT_SECRET=$(head -c 32 /dev/urandom | base64)"
  echo "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET=$(head -c 32 /dev/urandom | base64)"
} > /opt/barkpark/.env
cd /opt/barkpark/api
(set -a; . /opt/barkpark/.env; set +a; MIX_ENV=prod timeout 600 mix ecto.migrate) \
  || echo "[image-bake] WARNING: migrate skipped (provision-time migrate still covers it)"
cp /tmp/env.pre-bake /opt/barkpark/.env
rm -f /tmp/env.bake /tmp/env.pre-bake

# ── Seed reset (delete-only, OUTSIDE the throwaway-key bracket) ──────────────
# The whole-disk snapshot loop makes generation N+1's Postgres byte-for-byte
# generation N's, so the demo seed the lineage's ancestor received is
# transitively immortal unless the bake removes it (PDF-D103). This reset is
# DELETE-ONLY — TRUNCATE writes no rows, encrypted or otherwise — and it runs
# AFTER the /tmp/env.pre-bake restore above, so even a hypothetical write could
# not mint rows under the throwaway keys. CASCADE is deliberate: documents has
# ON DELETE RESTRICT referencers (epic_assignment_tasks, …) and SET NULL ones
# (revisions) that a bare DELETE would trip or orphan; TRUNCATE CASCADE empties
# them all and psql NOTICEs name every cascaded table in the journal.
# schema_migrations is untouched (nothing references it, it is not in the
# list): the pre-run migrate above exists precisely so a provisioned box's
# migrate stays a no-op, and the assertion below proves the rows survived.
# A reset failure must NOT kill the bake — this heredoc is set -euo pipefail
# and the outer EXIT trap would tear the box down snapshot-less, leaving the
# provisioner silently resolving the older image — so every command is guarded:
# on any failure the bake WARNS loudly and continues carrying the seed one more
# night, with the provision-time SupportResetDefaultWorkspaceStep as backstop.
SEED_RESET_OK=0
DB_URL="$(grep -m1 '^DATABASE_URL=' /opt/barkpark/.env | cut -d= -f2- || true)"
DB_URL="${DB_URL%\"}"; DB_URL="${DB_URL#\"}"
if [ -z "$DB_URL" ] || ! command -v psql >/dev/null 2>&1; then
  echo "[image-bake][seed-reset] WARNING: skipped (no DATABASE_URL in /opt/barkpark/.env or no psql) — this generation still carries the demo seed"
elif DOCS="$(psql "$DB_URL" -tAc 'SELECT count(*) FROM documents')" \
  && MEDIA="$(psql "$DB_URL" -tAc 'SELECT count(*) FROM media_files')" \
  && TOKENS="$(psql "$DB_URL" -tAc 'SELECT count(*) FROM api_tokens')"; then
  echo "[image-bake][seed-reset] deleting the baked seed: $DOCS document(s), $MEDIA media file(s), $TOKENS api token(s) (measured, not folklore)"
  if TRUNC_OUT="$(psql "$DB_URL" -v ON_ERROR_STOP=1 -c "SET lock_timeout='60s'" -c 'TRUNCATE TABLE documents, media_files, api_tokens CASCADE' 2>&1)"; then
    printf '%s\n' "$TRUNC_OUT" | sed 's/^/[image-bake][seed-reset] /'
    MIGS="$(psql "$DB_URL" -tAc 'SELECT count(*) FROM schema_migrations' || echo 0)"
    if [ "${MIGS:-0}" -gt 0 ] 2>/dev/null; then
      echo "[image-bake][seed-reset] done — schema_migrations intact ($MIGS rows), a provisioned box's migrate stays a no-op"
      SEED_RESET_OK=1
    else
      echo "[image-bake][seed-reset] WARNING: schema_migrations read EMPTY after the reset — every provision from this image would re-run the full migration set"
    fi
  else
    printf '%s\n' "$TRUNC_OUT" | sed 's/^/[image-bake][seed-reset] /'
    echo "[image-bake][seed-reset] WARNING: TRUNCATE failed — baking anyway; this generation STILL CARRIES the demo seed (the provision-time reset step remains the backstop)"
  fi
else
  echo "[image-bake][seed-reset] WARNING: could not count documents/media_files/api_tokens — baking anyway; this generation STILL CARRIES the demo seed"
fi
[ "$SEED_RESET_OK" = 1 ] || echo "[image-bake][seed-reset] NOTE: bake continues WITHOUT a clean seed reset — see the WARNING above"

rm -rf /opt/barkpark/api/_build_next
apt-get clean 2>/dev/null || true
journalctl --vacuum-size=10M >/dev/null 2>&1 || true

echo "BAKE_HEAD=$(git -C /opt/barkpark rev-parse HEAD)"
echo "BAKE_REMOTE=$(git -C /opt/barkpark rev-parse origin/main)"
BAKE

HEAD_SHA="$("${SSH[@]}" 'git -C /opt/barkpark rev-parse HEAD')"
REMOTE_SHA="$("${SSH[@]}" 'git -C /opt/barkpark rev-parse origin/main')"
if [ "$HEAD_SHA" != "$REMOTE_SHA" ]; then
  log "FATAL: box HEAD $HEAD_SHA != origin/main $REMOTE_SHA after freshen"
  exit 1
fi
log "box is at $HEAD_SHA — snapshotting"

# ── 4. Snapshot with the labels the resolver + the NEXT bake key off ─────────
hcloud server shutdown "$BOX_NAME" >/dev/null
for i in $(seq 1 36); do
  [ "$(hcloud server describe "$BOX_NAME" -o 'format={{.Status}}')" = "off" ] && break
  sleep 5
done

# `hcloud server create-image` supports NO -o flag (unlike list/describe) — it
# prints "Image <id> created from server <name>"; parse the id from stdout, with
# a list-by-selector fallback (the just-created snapshot is the newest labeled
# one in any status) so a wording change can't strand a finished bake.
CREATE_OUT="$(hcloud server create-image "$BOX_NAME" --type snapshot \
  --description "barkpark-server-$(date -u +%Y-%m-%d)-${HEAD_SHA:0:8}" \
  --label role=warm-image --label "commit=$HEAD_SHA")"
IMAGE_ID="$(printf '%s' "$CREATE_OUT" | grep -oiE 'image [0-9]+' | grep -oE '[0-9]+' | head -1)"
if [ -z "$IMAGE_ID" ]; then
  IMAGE_ID="$(hcloud image list --type snapshot --selector role=warm-image -o json | py '
import json, sys
imgs = json.load(sys.stdin)
imgs.sort(key=lambda i: i.get("created", ""), reverse=True)
print(imgs[0]["id"] if imgs else "")
')"
fi
[ -n "$IMAGE_ID" ] || { log "FATAL: could not determine the created snapshot id (output: $CREATE_OUT)"; exit 1; }
log "snapshot $IMAGE_ID creating — waiting for available"
for i in $(seq 1 120); do
  # Poll via `image list -o json` (proven flag surface) rather than describe.
  STATUS="$(hcloud image list --type snapshot --selector role=warm-image -o json | py "
import json, sys
print(next((i.get('status','') for i in json.load(sys.stdin) if str(i.get('id')) == '$IMAGE_ID'), ''))
")"
  [ "$STATUS" = "available" ] && break
  [ "$i" = 120 ] && { log "FATAL: snapshot $IMAGE_ID never became available (last status: $STATUS)"; exit 1; }
  sleep 15
done
log "snapshot $IMAGE_ID available (commit $HEAD_SHA) — the provisioner picks it up within a minute"

# ── 5. Prune old bakes (keep the newest $KEEP_IMAGES as rollback) ────────────
hcloud image list --type snapshot --selector role=warm-image -o json | py "
import json, sys
imgs = [i for i in json.load(sys.stdin) if i.get('status') == 'available']
imgs.sort(key=lambda i: i.get('created', ''), reverse=True)
for old in imgs[$KEEP_IMAGES:]:
    print(old['id'])
" | while read -r OLD_ID; do
  [ -n "$OLD_ID" ] || continue
  log "pruning old bake $OLD_ID"
  hcloud image delete "$OLD_ID" || log "WARNING: prune of $OLD_ID failed"
done

log "DONE — warm image is now $IMAGE_ID @ ${HEAD_SHA:0:8}"
