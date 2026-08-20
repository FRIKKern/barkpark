#!/usr/bin/env bash
# github-webhook-subscription-parity.sh — every GitHub event the webhook
# controller CONSUMES must be an event the App manifest SUBSCRIBES to.
#
# THE FAILURE THIS EXISTS FOR, exactly. PR #5742 (2026-07-22) added a
# `"pull_request" -> handle_pull_request(...)` branch to
# `BarkparkWeb.GithubWebhookController.receive/2`, plus a handler, plus five
# green unit tests. It did NOT add `pull_request` to
# `scripts/github-app-bootstrap.py`'s `default_events`, which stayed `["issues"]`.
# GitHub therefore never sent the event. The handler was never invoked once in
# 29 days; 9 merge-gated tasks in a single 40-day window went unstamped by hand
# while CI was green throughout. Nothing in the repo could notice, because the
# only thing that knew the handler existed was a test that called it directly.
#
# This closes that specific hole and only that hole: a consumer added without a
# subscription REDS on the PR that adds it. It is cheap (pure text, no network)
# and it runs on every PR that touches either side.
#
# WHAT THIS IS NOT. It compares CODE against the MANIFEST. It cannot see the
# GitHub App that actually exists — a manifest edit does not retro-apply to an
# already-created App, so this check can be green while the live App is still
# subscribed to nothing. Proving the real delivery path is alive is
# `scripts/merge-gate-autostamp-liveness.sh`'s job, and it reads the ledger to
# do it. Do not let a green here stand in for that.
#
#   scripts/github-webhook-subscription-parity.sh [--root <repo root>]
#
# Exit 0 = parity. Exit 1 = a consumed event is unsubscribed, or the runbook
# disagrees with the manifest. Exit 3 = an input file is missing/unparseable.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2;;
    -h|--help) sed -n '2,28p' "$0"; exit 0;;
    *) echo "unknown arg $1" >&2; exit 3;;
  esac
done

CONTROLLER="$ROOT/api/lib/barkpark_web/controllers/github_webhook_controller.ex"
MANIFEST="$ROOT/scripts/github-app-bootstrap.py"
RUNBOOK="$ROOT/docs/ops/github-sync.md"

for f in "$CONTROLLER" "$MANIFEST" "$RUNBOOK"; do
  [ -f "$f" ] || { echo "UNAVAILABLE: missing $f" >&2; exit 3; }
done

CONTROLLER="$CONTROLLER" MANIFEST="$MANIFEST" RUNBOOK="$RUNBOOK" python3 <<'PY'
import os, re, sys

# ── consumed: the string literals `receive/2` dispatches on ──────────────────
# `ping` is excluded on purpose: GitHub sends the install handshake regardless
# of the subscription list, so it is not a subscription claim. `_other` is the
# catch-all 202. Everything else is a handler that CANNOT run unsubscribed.
HANDSHAKE = {"ping"}

src = open(os.environ["CONTROLLER"]).read()
m = re.search(r"def receive\(conn, params\) do(.*?)\n  end\n", src, re.S)
if not m:
    print("UNAVAILABLE: could not locate receive/2 in the controller", file=sys.stderr)
    sys.exit(3)
consumed = [e for e in re.findall(r'"([a-z_]+)"\s*->', m.group(1)) if e not in HANDSHAKE]
consumed = sorted(set(consumed))

# ── subscribed: default_events in the App manifest ───────────────────────────
mf = open(os.environ["MANIFEST"]).read()
m = re.search(r'"default_events"\s*:\s*\[([^\]]*)\]', mf)
if not m:
    print("UNAVAILABLE: could not locate default_events in the manifest", file=sys.stderr)
    sys.exit(3)
subscribed = sorted(set(re.findall(r'"([a-z_]+)"', m.group(1))))

# ── declared: the runbook's Subscribe-to-events line ─────────────────────────
# The runbook is what a human follows when provisioning by hand, so it must not
# drift from the manifest the script uses. Bold names map back to event ids.
rb = open(os.environ["RUNBOOK"]).read()
m = re.search(r"\*\*Subscribe to events\*\*:(.*)", rb)
line = m.group(1) if m else ""
ALIASES = {"issues": "issues", "pull requests": "pull_request", "pull request": "pull_request"}
declared = sorted({ALIASES[b.strip().lower()]
                   for b in re.findall(r"\*\*([^*]+)\*\*", line)
                   if b.strip().lower() in ALIASES})

print("controller consumes ..... %s" % (consumed or ["(none)"]))
print("manifest subscribes ..... %s" % (subscribed or ["(none)"]))
print("runbook declares ........ %s" % (declared or ["(none)"]))
print()

fail = False
missing = [e for e in consumed if e not in subscribed]
if missing:
    fail = True
    print("BROKEN — the controller handles %s but the App manifest does not subscribe to it."
          % ", ".join("`%s`" % e for e in missing))
    print("GitHub will never send that event, so the handler is dead code and every test")
    print("that calls it directly is a green that cannot go red. Add it to")
    print("`default_events` in scripts/github-app-bootstrap.py (and grant any permission")
    print("the event requires), then update the runbook line.")
    print()

if declared != subscribed:
    fail = True
    print("BROKEN — docs/ops/github-sync.md's `Subscribe to events` line says %s but the"
          % (declared or ["(none)"]))
    print("manifest says %s. A human provisioning by hand follows the runbook; a drift here")
    print("silently produces a differently-wired App than the script does.")
    print()

if fail:
    sys.exit(1)

print("PARITY — every consumed event is subscribed, and the runbook agrees.")
print("(This proves code/manifest agreement ONLY. It says nothing about the App that")
print(" actually exists — use scripts/merge-gate-autostamp-liveness.sh for that.)")
PY
exit $?
