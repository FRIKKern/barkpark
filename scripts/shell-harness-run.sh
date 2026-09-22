#!/usr/bin/env bash
# shell-harness-run.sh — run one shell-harness LEG's arms, in order, and report.
#
# This is the uniform body the `harness` matrix job executes. Before the matrix
# collapse each leg was its own job whose `run:` steps carried
# `if: ${{ !cancelled() && steps.setup.outcome == 'success' }}` — i.e. EVERY arm
# runs even when an earlier arm failed, and the job reds if any of them did. A
# naive `set -e` over the same commands would stop at the first red and HIDE the
# rest, which is the one semantic this collapse must not lose. So: each arm runs
# under its own `bash -c`, the status is accumulated, and the exit is the OR.
#
# Each arm is printed inside a `::group::` so the fold structure of the old
# per-step log survives, and a failing arm is re-named in a `::error::` line and
# in the FAILED summary at the end — the old shape named the failing STEP, and a
# log you have to read linearly to find out which of eighteen arms broke is a
# regression in exactly the direction that gets a red ignored.
#
# EXIT CODES
#   0  every arm of the leg exited 0
#   1  at least one arm failed — each is named
#   2  CANNOT MEASURE: no slug, legs file missing/unparseable, unknown slug, or
#      a leg with ZERO arms. A leg with no arms is a REFUSAL, never a pass: it
#      is precisely the shape a bad regeneration of the legs file produces, and
#      it would otherwise report a green that measured nothing.
#
# USAGE
#   bash scripts/shell-harness-run.sh <slug>
#   SHELL_HARNESS_LEGS=<path> bash scripts/shell-harness-run.sh <slug>

set -uo pipefail

LEGS="${SHELL_HARNESS_LEGS:-.github/shell-harness-legs.json}"

unavailable() { echo "::error::shell-harness-run: $*" >&2; exit 2; }

SLUG="${1:-}"
[ -n "$SLUG" ] || unavailable "no leg slug given (usage: shell-harness-run.sh <slug>)"
[ -f "$LEGS" ] || unavailable "legs file not found: $LEGS"
command -v python3 >/dev/null 2>&1 || unavailable "python3 is required to read $LEGS"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/shr.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# One python pass writes, per arm, a NAME file, an ENV file (KEY=VALUE lines)
# and a SCRIPT file. Nothing about an arm reaches the shell as an argument, so
# a run body containing quotes, newlines or `$(` is carried verbatim.
if ! python3 - "$LEGS" "$SLUG" "$TMP" <<'PY'
import json, os, sys
legs_path, slug, out = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    legs = json.load(open(legs_path))
except Exception as exc:
    sys.stderr.write("unparseable %s: %s\n" % (legs_path, exc)); sys.exit(2)
hit = [l for l in legs if l.get("slug") == slug]
if len(hit) != 1:
    sys.stderr.write("expected exactly one leg with slug %r, found %d\n" % (slug, len(hit)))
    sys.exit(2)
arms = hit[0].get("arms") or []
if not arms:
    sys.stderr.write("leg %r carries ZERO arms — refusing to report a green over nothing\n" % slug)
    sys.exit(2)
for i, arm in enumerate(arms):
    base = os.path.join(out, "%03d" % i)
    open(base + ".name", "w").write(arm.get("name") or "arm %d" % i)
    open(base + ".sh", "w").write(arm["run"])
    with open(base + ".env", "w") as fh:
        for k, v in (arm.get("env") or {}).items():
            fh.write("%s=%s\n" % (k, v))
print(len(arms))
PY
then
  unavailable "could not extract leg '$SLUG' from $LEGS"
fi

N=$(python3 - "$LEGS" "$SLUG" <<'PY'
import json,sys
legs=json.load(open(sys.argv[1]))
print(len([l for l in legs if l["slug"]==sys.argv[2]][0]["arms"]))
PY
)

echo "── shell-harness leg '$SLUG': $N arm(s) ──"
FAILED=""
i=0
while [ "$i" -lt "$N" ]; do
  base="$TMP/$(printf '%03d' "$i")"
  name="$(cat "$base.name")"
  echo "::group::$name"
  # `env` applies the arm's own env file without leaking it into later arms.
  if [ -s "$base.env" ]; then
    # shellcheck disable=SC2046
    env $(tr '\n' ' ' <"$base.env") bash "$base.sh"
  else
    bash "$base.sh"
  fi
  rc=$?
  echo "::endgroup::"
  if [ "$rc" -ne 0 ]; then
    echo "::error::$SLUG arm failed (exit $rc): $name"
    FAILED="$FAILED
  - $name (exit $rc)"
  fi
  i=$((i + 1))
done

if [ -n "$FAILED" ]; then
  echo "FAILED arms in leg '$SLUG':$FAILED"
  exit 1
fi
echo "ok - all $N arm(s) of leg '$SLUG' passed"
