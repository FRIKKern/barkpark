#!/usr/bin/env bash
# never-cancel-main-check.sh — the ratchet for honest-gates D12: `cancelled` is a NON-PASS.
#
# THE DEFECT THIS FORBIDS. A workflow that runs on push-to-main and sets
# `cancel-in-progress: true` cancels its own main runs whenever pushes land
# faster than the suite completes. On 2026-06-10 that starved the Elixir suite
# dark: 19 consecutive main runs cancelled, zero completions all day. Commit
# a547ff75a fixed it with `cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}`
# — but at SAMPLE scope. Five workflows got the guard; cloud.yml and
# doc-gates.yml were missed and kept a bare `true` for 40 days. That regrowth is
# what this gate exists to make impossible.
#
# WHY IT IS NOT COSMETIC. A cancelled check is not a pass. Under branch
# protection a cancelled required check is an unexplainable merge block, so a
# regrown bare `true` turns an otherwise-honest-green check into a lying gate
# the moment it is promoted.
#
# THE PREDICATE — exactly one reason to red. FAIL iff a workflow BOTH
#   (a) triggers on `push:` with `main` among its branches, AND
#   (b) sets `concurrency.cancel-in-progress` to the literal boolean `true`.
# Both halves are load-bearing. A pull_request-only workflow can carry a bare
# `true` honestly: `github.ref` is never `refs/heads/main` there, so the guard
# expression would evaluate to `true` anyway — identical behaviour. Flagging
# those would red for a reason other than the thing measured (charter: a gate
# must red for exactly ONE reason). They are reported as NOTE, never as failure,
# so the latent shape stays visible without manufacturing a false red.
#
# `cancel-in-progress: false` is always fine — it is strictly never-cancel, the
# deliberate choice in deploy/release workflows.
#
# --selftest proves this gate is ABLE TO FAIL (charter D2: distrust vacuous
# green). It runs the predicate over synthetic fixtures in a temp dir and
# asserts red on the hazardous shape and green on each safe one. It plants
# nothing in the tree.
#
# Usage: scripts/never-cancel-main-check.sh [--selftest]
set -euo pipefail
cd "$(dirname "$0")/.."

# scan <dir> — prints "FAIL <file>" / "NOTE <file>" lines, one per finding.
# Exits 2 (never 0/1) if the YAML harness itself is unavailable, so a broken
# harness can never be read as a verdict on the workflows (charter D3: exit code
# alone cannot discriminate a dep error from a real verdict — the text does).
scan() {
  python3 - "$1" <<'PY'
import sys, glob, os, re, json, fnmatch

try:
    import yaml
except ImportError:
    print("HARNESS-UNAVAILABLE: PyYAML not importable; this is NOT a verdict on the workflows")
    sys.exit(2)


# ── THE COLLAPSE MARKER (task-e376642d6d69fa3f) ────────────────────────────
# A workflow may declare itself COLLAPSIBLE on main: one shared group for every
# main push, cancel-in-progress true, so a burst of merges leaves one run on the
# newest sha. That is a DELIBERATE loss of per-commit resolution, and it is only
# safe for a workflow that certifies nothing anybody merges on and does nothing
# anybody depends on having happened. The declaration is a comment line in the
# workflow, EXACTLY:
#
#     # main-collapse: harness-ok - <one-line ground> (<task id>)
#
# matched by MARKER_RE below. It is a CLAIM, not a permission: this function
# re-derives the two facts the claim asserts and REFUSES the marker when either
# is false, so planting the marker on elixir.yml or on deploy.yml reds rather
# than waives.
MARKER_RE = re.compile(r"^[ \t]*#[ \t]*main-collapse:[ \t]*harness-ok\b")


def has_marker(path):
    try:
        with open(path) as fh:
            for line in fh:
                if MARKER_RE.match(line):
                    return True
    except Exception:
        return False
    return False


def required_contexts():
    """The required set, READ from .github/required-checks.json - never typed.

    Returns None when the file cannot be read, which callers turn into
    HARNESS-UNAVAILABLE: an unreadable authority is not an empty required set.
    """
    try:
        with open(".github/required-checks.json") as fh:
            spec = json.load(fh)
        checks = spec["protection"]["required_status_checks"]["checks"]
        return set(str(c["context"]) for c in checks)
    except Exception:
        return None


# THE ACTION/WATCHER DENYLIST. Not a shrink-only ledger like GRANDFATHERED - the
# safe direction here is the OPPOSITE. A grandfather line waives a defect, so it
# must only ever be deleted; a denylist line REFUSES a waiver, so adding one is
# always safe and deleting one is the dangerous edit. What keeps it honest is a
# POSITIVE CONTROL in --selftest: every pattern must match at least one file in
# the live tree (a typo protects nothing), and every live workflow that deploys,
# releases, renews or watches must be matched by some pattern.
DENY_PATTERNS = [
    "deploy.yml",           # performs the production deploy
    "release.yml",          # publishes packages
    "release-artifact.yml", # builds and uploads a release artifact
    "cli-release.yml",      # publishes the CLI
    "landed-mark.yml",      # WRITES to the task ledger for the pushed sha
    "*-watch.yml",          # breakglass / main-gate / stale-verdict: a skipped watch is a blind window
    "task-lease-renew.yml", # a skipped renewal lets a claim lapse
    "cron-overdue-probe.yml",
    "crown-reconcile.yml",
    "scaffy-catalog-drift.yml",  # its own job name calls it a post-merge watcher
]


def denied(basename):
    for pat in DENY_PATTERNS:
        if fnmatch.fnmatch(basename, pat):
            return pat
    return None


def job_names(doc):
    jobs = doc.get("jobs")
    if not isinstance(jobs, dict):
        return []
    out = []
    for key, val in jobs.items():
        if isinstance(val, dict) and isinstance(val.get("name"), str):
            out.append(val["name"])
        else:
            out.append(str(key))
    return out


def marker_verdict(path, doc):
    """(ok, reason). Only called when the marker is PRESENT."""
    base = os.path.basename(path)
    pat = denied(base)
    if pat is not None:
        return (False, "it matches the action/watcher denylist pattern %r - a "
                       "collapsed run of a workflow that deploys, releases, "
                       "renews or watches is a skipped action or a blind "
                       "window, never a saved CI slot" % pat)
    req = required_contexts()
    if req is None:
        return (None, "REQUIRED-SET-UNREADABLE")
    published = [n for n in job_names(doc) if n in req]
    if published:
        return (False, "it publishes required context(s) %s - branch protection "
                       "merges on that name, so its main runs must stay per-sha "
                       "and bisectable" % sorted(published))
    return (True, "publishes no required context and is not on the action/watcher denylist")



def triggers_push_to_main(on):
    """True iff this `on:` block fires on a push to main.

    Deliberately over-approximating on the shapes GitHub treats as "every
    branch": a `push:` with NO `branches` filter runs on main, and so does one
    that only sets `branches-ignore` without naming main. Reading only a literal
    `branches: [main]` list — as the first cut of this gate did — classes both
    of those as PR-only and lets a bare `true` through as a NOTE, which is the
    gate under-detecting the exact hazard it exists to forbid.
    """
    if not isinstance(on, dict):
        # `on: push` / `on: [push, pull_request]` carry no branch filter at all,
        # so they fire on every branch, main included.
        if on == "push":
            return True
        return isinstance(on, list) and "push" in on

    if "push" not in on:
        return False
    push = on["push"]
    if not isinstance(push, dict):
        # `push:` with a null/scalar body = no filter = all branches.
        return True

    def as_list(v):
        if isinstance(v, str):
            return [v]
        return v if isinstance(v, list) else []

    branches = as_list(push.get("branches"))
    ignore = as_list(push.get("branches-ignore"))

    if branches:
        # Patterns are globs: `main`, `ma*n` and `*` all select main.
        return any(fnmatch.fnmatch("main", str(p)) for p in branches)
    if ignore:
        return not any(fnmatch.fnmatch("main", str(p)) for p in ignore)
    # No filter of either kind → every branch, including main.
    return True

root = sys.argv[1]
for path in sorted(glob.glob(os.path.join(root, "*.yml")) + glob.glob(os.path.join(root, "*.yaml"))):
    try:
        doc = yaml.safe_load(open(path))
    except Exception as exc:
        print(f"HARNESS-UNAVAILABLE: {path} did not parse as YAML: {exc}")
        sys.exit(2)
    if not isinstance(doc, dict):
        continue

    # YAML 1.1 resolves a bare `on:` key to boolean True, so accept both forms.
    on = doc.get("on", doc.get(True))
    conc = doc.get("concurrency")
    if not isinstance(conc, dict):
        continue

    # Only a LITERAL boolean true is the hazard. The guard expression parses as
    # the string "${{ ... }}", and `false` is strictly never-cancel.
    if conc.get("cancel-in-progress") is not True:
        continue

    on_main = triggers_push_to_main(on)

    name = os.path.basename(path)
    if not on_main:
        print(f"NOTE {name}: bare `cancel-in-progress: true`, but no push-to-main trigger (harmless today)")
        continue

    # THE ONE EXEMPTION, and it is DECLARED and RE-DERIVED, never inferred from
    # a name. A workflow carrying the main-collapse marker has said out loud
    # that its main runs may collapse to the newest sha; marker_verdict() then
    # re-checks the two facts that claim depends on - it publishes no context in
    # .github/required-checks.json, and it is not on the action/watcher denylist
    # - and REFUSES the marker otherwise. So the marker cannot waive D12 for
    # elixir.yml, deploy.yml or a watcher: those red here exactly as before.
    if has_marker(path):
        verdict, reason = marker_verdict(path, doc)
        if verdict is None:
            print("HARNESS-UNAVAILABLE: %s carries the main-collapse marker but "
                  ".github/required-checks.json could not be read, so the marker "
                  "cannot be re-derived; this is NOT a verdict" % name)
            sys.exit(2)
        if verdict:
            print(f"COLLAPSE {name}: `cancel-in-progress: true` on push-to-main is DECLARED by the main-collapse marker and re-derived OK - {reason}")
            continue
        print(f"FAIL {name}: the main-collapse marker is REFUSED - {reason}")
        continue

    print(f"FAIL {name}: runs on push-to-main with a bare `cancel-in-progress: true`")
PY
}

SELFTEST_TMP=""
cleanup_selftest() { [ -n "$SELFTEST_TMP" ] && rm -rf "$SELFTEST_TMP"; return 0; }
trap cleanup_selftest EXIT

selftest() {
  local tmp failed=0 e2e_rc=0
  SELFTEST_TMP="$(mktemp -d)"
  tmp="$SELFTEST_TMP"

  # HAZARDOUS — push-to-main + bare true. Must red.
  cat >"$tmp/hazard.yml" <<'EOF'
name: hazard
on:
  push:
    branches: [main]
concurrency:
  group: hazard-${{ github.ref }}
  cancel-in-progress: true
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF

  # SAFE — push-to-main + the ref guard.
  cat >"$tmp/guarded.yml" <<'EOF'
name: guarded
on:
  push:
    branches: [main]
concurrency:
  group: guarded-${{ github.ref }}
  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF

  # SAFE — pull_request only, bare true is behaviourally identical to the guard.
  cat >"$tmp/pronly.yml" <<'EOF'
name: pronly
on:
  pull_request:
    paths: ["**/*.ex"]
concurrency:
  group: pronly-${{ github.ref }}
  cancel-in-progress: true
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF

  # HAZARDOUS — `push:` with NO branches filter runs on every branch, main
  # included. The first cut of this gate read only a literal `branches: [main]`
  # list and classed this as PR-only, letting the hazard through as a NOTE.
  cat >"$tmp/nofilter.yml" <<'EOF'
name: nofilter
on:
  push:
concurrency:
  group: nofilter-${{ github.ref }}
  cancel-in-progress: true
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF

  # HAZARDOUS — a glob that selects main, and the scalar (non-list) branches
  # form. Both are valid GitHub syntax and both were invisible before.
  cat >"$tmp/globbed.yml" <<'EOF'
name: globbed
on:
  push:
    branches: ma*n
concurrency:
  group: globbed-${{ github.ref }}
  cancel-in-progress: true
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF

  # HAZARDOUS — branches-ignore that does not name main, so main still fires.
  cat >"$tmp/ignoreother.yml" <<'EOF'
name: ignoreother
on:
  push:
    branches-ignore: [dependabot/**]
concurrency:
  group: ignoreother-${{ github.ref }}
  cancel-in-progress: true
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF

  # SAFE — branches-ignore that DOES name main: push-to-main never fires.
  cat >"$tmp/ignoremain.yml" <<'EOF'
name: ignoremain
on:
  push:
    branches-ignore: [main]
concurrency:
  group: ignoremain-${{ github.ref }}
  cancel-in-progress: true
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF

  # SAFE — push-to-main + explicit never-cancel.
  cat >"$tmp/nevercancel.yml" <<'EOF'
name: nevercancel
on:
  push:
    branches: [main]
concurrency:
  group: nevercancel-${{ github.ref }}
  cancel-in-progress: false
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF

  # ── THE MAIN-COLLAPSE MARKER: CAN-LOSE ARMS (task-e376642d6d69fa3f) ──────
  # The marker exempts a workflow from D12. An exemption that cannot be REFUSED
  # is a waiver, so each arm below plants the marker on a fixture that must NOT
  # get it and asserts the gate reds anyway. The `clean` fixture is the positive
  # control: without it a gate hard-wired to refuse every marker would pass all
  # three refusal arms while making the feature useless.
  write_marked() {
    # write_marked <file> <marker:yes|no> <job-name>
    local file="$1" marker="$2" jobname="$3"
    {
      echo "name: $(basename "$file" .yml)"
      echo "on:"
      echo "  push:"
      echo "    branches: [main]"
      echo "concurrency:"
      [ "$marker" = yes ] && echo "  # main-collapse: harness-ok - fixture (task-e376642d6d69fa3f)"
      # shellcheck disable=SC2016
      echo '  group: fx-${{ github.ref == '"'"'refs/heads/main'"'"' && '"'"'main'"'"' || github.ref }}'
      echo "  cancel-in-progress: true"
      echo "jobs:"
      echo "  a:"
      echo "    name: $jobname"
      echo "    runs-on: ubuntu-latest"
      echo "    steps: [{ run: \"true\" }]"
    } > "$file"
  }

  local mdir="$tmp/marker"
  mkdir -p "$mdir"
  write_marked "$mdir/clean-harness.yml"  yes "Harness arm"
  write_marked "$mdir/reqctx.yml"         yes "Elixir gate"
  write_marked "$mdir/deploy.yml"         yes "Harness arm"
  write_marked "$mdir/pretend-watch.yml"  yes "Harness arm"
  write_marked "$mdir/unmarked.yml"       no  "Harness arm"

  local mout mstatus=0
  mout="$(scan "$mdir")" || mstatus=$?
  if [ "$mstatus" -ne 0 ] || grep -q '^HARNESS-UNAVAILABLE' <<<"$mout"; then
    echo "SELFTEST HARNESS FAILURE on the marker fixtures (exit $mstatus):" >&2
    echo "$mout" >&2
    exit 2
  fi

  if ! grep -q '^COLLAPSE clean-harness.yml' <<<"$mout"; then
    echo "SELFTEST FAILED: a MARKED, clean fixture must be accepted as COLLAPSE, not red" >&2
    failed=1
  fi
  if grep -q '^FAIL clean-harness.yml' <<<"$mout"; then
    echo "SELFTEST FAILED: a marked, clean fixture must not FAIL" >&2
    failed=1
  fi
  if ! grep -q '^FAIL reqctx.yml.*REFUSED' <<<"$mout"; then
    echo "SELFTEST FAILED (CAN-LOSE): the marker on a fixture publishing the required context 'Elixir gate' must be REFUSED" >&2
    failed=1
  fi
  if ! grep -q '^FAIL deploy.yml.*REFUSED' <<<"$mout"; then
    echo "SELFTEST FAILED (CAN-LOSE): the marker on a fixture named deploy.yml must be REFUSED by the denylist" >&2
    failed=1
  fi
  if ! grep -q '^FAIL pretend-watch.yml.*REFUSED' <<<"$mout"; then
    echo "SELFTEST FAILED (CAN-LOSE): the marker on a *-watch.yml fixture must be REFUSED by the denylist" >&2
    failed=1
  fi
  if ! grep -q "^FAIL unmarked.yml: runs on push-to-main with a bare" <<<"$mout"; then
    echo "SELFTEST FAILED: an UNMARKED push-to-main workflow with a bare true must still red exactly as before" >&2
    failed=1
  fi

  # E2E: a root of the marked-clean fixture alone must exit 0; a root carrying a
  # refused marker must exit 1 (the verdict wiring, not just scan() text).
  local cleandir="$tmp/marker-clean-only"
  mkdir -p "$cleandir"; cp "$mdir/clean-harness.yml" "$cleandir/"
  e2e_rc=0
  NCM_SCAN_ROOT="$cleandir" bash "$0" >/dev/null 2>&1 || e2e_rc=$?
  if [ "$e2e_rc" -ne 0 ]; then
    echo "SELFTEST FAILED (E2E): a root of only a marked, clean workflow must exit 0, got ${e2e_rc}." >&2
    failed=1
  fi
  local refuseddir="$tmp/marker-refused-only"
  mkdir -p "$refuseddir"; cp "$mdir/reqctx.yml" "$refuseddir/"
  e2e_rc=0
  NCM_SCAN_ROOT="$refuseddir" bash "$0" >/dev/null 2>&1 || e2e_rc=$?
  if [ "$e2e_rc" -ne 1 ]; then
    echo "SELFTEST FAILED (E2E): a root whose only workflow carries a REFUSED marker must exit 1, got ${e2e_rc}." >&2
    failed=1
  fi

  if [ "$failed" -ne 0 ]; then
    echo "--- marker fixture scan output ---" >&2
    echo "$mout" >&2
    exit 1
  fi

  local out scan_status=0
  # `|| scan_status=$?` so `set -e` cannot abort the assignment and discard the
  # captured text — see the same guard on the real scan below.
  out="$(scan "$tmp")" || scan_status=$?
  if [ "$scan_status" -ne 0 ] || grep -q '^HARNESS-UNAVAILABLE' <<<"$out"; then
    echo "SELFTEST HARNESS FAILURE (exit $scan_status) — this is NOT a verdict on the workflows:" >&2
    echo "$out" >&2
    exit 2
  fi

  if ! grep -q '^FAIL hazard.yml' <<<"$out"; then
    echo "SELFTEST FAILED: the gate did NOT red on push-to-main + bare true" >&2
    failed=1
  fi
  # The main-selecting shapes that carry no literal `branches: [main]` list.
  for hazard in nofilter.yml globbed.yml ignoreother.yml; do
    if ! grep -q "^FAIL $hazard" <<<"$out"; then
      echo "SELFTEST FAILED: the gate did NOT red on $hazard — it fires on main but names no literal 'main' branch" >&2
      failed=1
    fi
  done
  for safe in guarded.yml nevercancel.yml ignoremain.yml; do
    if grep -q "^FAIL $safe" <<<"$out"; then
      echo "SELFTEST FAILED: the gate red on the safe shape $safe" >&2
      failed=1
    fi
  done
  if grep -q '^FAIL pronly.yml' <<<"$out"; then
    echo "SELFTEST FAILED: the gate red on a pull_request-only bare true (behaviourally identical to the guard)" >&2
    failed=1
  fi
  if ! grep -q '^NOTE pronly.yml' <<<"$out"; then
    echo "SELFTEST FAILED: the gate did not NOTE a pull_request-only bare true" >&2
    failed=1
  fi

  if [ "$failed" -ne 0 ]; then
    echo "--- selftest scan output ---" >&2
    echo "$out" >&2
    exit 1
  fi
  # ── E2E ARMS: the VERDICT WIRING, not just scan() ────────────────────────
  #
  # Every arm above asserts on the TEXT scan() returned. None of them execute
  # the branch that turns that text into an exit code, so the whole tail of
  # this script — the `grep -q '^FAIL '` verdict and its `exit 1` — was outside
  # the harness's reach. MEASURED (task-5c4187dda277d445): rewriting that one
  # line to `if false; then` left this selftest fully green while the real gate
  # returned 0 on a planted push-to-main + `cancel-in-progress: true` workflow
  # and printed "never-cancel-main gate OK". doc-gates.yml runs --selftest
  # first as the durable tripwire; it certified nothing about that branch.
  #
  # So these arms re-exec THIS SCRIPT against fixture roots and assert on the
  # exit code of the whole program. A disarm of the verdict now reds here.

  # (a) a root carrying the hazard must exit 1.
  e2e_rc=0
  NCM_SCAN_ROOT="$tmp" bash "$0" >/dev/null 2>&1 || e2e_rc=$?
  if [ "$e2e_rc" -ne 1 ]; then
    echo "SELFTEST FAILED (E2E): a scan root carrying the hazard must exit 1, got ${e2e_rc}." >&2
    echo "  The verdict wiring — \`grep -q '^FAIL ' <<<\"\$RESULT\"\` then exit 1 — is disarmed or unreachable." >&2
    failed=1
  fi

  # (b) a root carrying ONLY safe shapes must exit 0. Without this arm a gate
  #     hard-wired to `exit 1` would pass arm (a) and fail every real PR.
  local safe_dir="$tmp/safe-only"
  mkdir -p "$safe_dir"
  cp "$tmp/guarded.yml" "$tmp/nevercancel.yml" "$safe_dir/"
  e2e_rc=0
  NCM_SCAN_ROOT="$safe_dir" bash "$0" >/dev/null 2>&1 || e2e_rc=$?
  if [ "$e2e_rc" -ne 0 ]; then
    echo "SELFTEST FAILED (E2E): a scan root of only safe shapes must exit 0, got ${e2e_rc}." >&2
    failed=1
  fi

  # (c) an EMPTY root must exit 2, never 0. `scan` over a glob that matches
  #     nothing prints nothing and exits 0, so without the non-empty floor the
  #     verdict reports "gate OK" over a corpus of zero files — a green that
  #     measured nothing, and the exact failure the override could otherwise
  #     introduce.
  local empty_dir="$tmp/empty-root"
  mkdir -p "$empty_dir"
  e2e_rc=0
  NCM_SCAN_ROOT="$empty_dir" bash "$0" >/dev/null 2>&1 || e2e_rc=$?
  if [ "$e2e_rc" -ne 2 ]; then
    echo "SELFTEST FAILED (E2E): an EMPTY scan root must exit 2 (could not RUN), got ${e2e_rc}." >&2
    echo "  The non-empty floor is missing: this gate would report green over zero files." >&2
    failed=1
  fi

  # (d) a MISSING root must exit 2 too — a typo'd override must never green.
  e2e_rc=0
  NCM_SCAN_ROOT="$tmp/does-not-exist" bash "$0" >/dev/null 2>&1 || e2e_rc=$?
  if [ "$e2e_rc" -ne 2 ]; then
    echo "SELFTEST FAILED (E2E): a MISSING scan root must exit 2 (could not RUN), got ${e2e_rc}." >&2
    failed=1
  fi

  if [ "$failed" -ne 0 ]; then
    echo "--- selftest scan output ---" >&2
    echo "$out" >&2
    exit 1
  fi

  echo "never-cancel-main selftest OK — reds on push-to-main + bare true, green on the guard, on never-cancel, and on pull_request-only; and E2E: the whole script exits 1 on a hazard root, 0 on a safe root, 2 on an empty or missing root."
}

# Refuse an argument this gate does not understand. A swallowed flag — a
# `--selftest` typo, a future rename — would silently run the ordinary check
# and report green, fabricating the tripwire's own proof.
if [ -n "${1:-}" ] && [ "$1" != "--selftest" ]; then
  echo "never-cancel-main-check: unknown argument '$1' (expected nothing or --selftest)" >&2
  exit 2
fi

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit 0
fi

# `|| SCAN_STATUS=$?` is load-bearing. `scan` exits 2 when the YAML harness is
# unavailable, and under `set -e` a bare `RESULT="$(scan …)"` assignment aborts
# the script THERE — exiting 2 with the HARNESS-UNAVAILABLE text still sitting
# in the discarded capture. The step then failed with an EMPTY log, and a reader
# had no way to tell a missing PyYAML from a real finding. That is charter D3
# defeated by the very script that cites it: the discriminating text must reach
# the log, so the failure is captured here and re-emitted below.
# The scan root is overridable ONLY so the selftest can drive this script
# end-to-end against a fixture tree (see the E2E arms in selftest()). CI and
# every human invocation leave it unset and get `.github/workflows`.
SCAN_ROOT="${NCM_SCAN_ROOT:-.github/workflows}"

# THE NON-EMPTY FLOOR, and it is the whole reason this override is safe to
# exist. `scan` walks a glob: pointed at a missing or empty directory it prints
# NOTHING and exits 0, and the verdict below then reports
# "never-cancel-main gate OK" over a corpus of zero files. That is a gate that
# certifies rather than measures — a typo'd override, a moved workflows dir, or
# a checkout that never materialised would all read as green. A root that
# cannot be measured is exit 2 (could not RUN), never exit 0.
if [ ! -d "$SCAN_ROOT" ]; then
  echo "never-cancel-main gate could not RUN: scan root '$SCAN_ROOT' is not a directory — this is NOT a verdict on the workflows." >&2
  exit 2
fi
SCAN_ROOT_COUNT="$(find "$SCAN_ROOT" -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) -type f | wc -l | tr -d ' ')"
if [ "$SCAN_ROOT_COUNT" -eq 0 ]; then
  echo "never-cancel-main gate could not RUN: scan root '$SCAN_ROOT' holds ZERO workflow files — refusing to report a green over an empty corpus." >&2
  exit 2
fi

SCAN_STATUS=0
RESULT="$(scan "$SCAN_ROOT")" || SCAN_STATUS=$?

if [ "$SCAN_STATUS" -ne 0 ] || grep -q '^HARNESS-UNAVAILABLE' <<<"$RESULT"; then
  echo "never-cancel-main gate could not RUN (harness exit ${SCAN_STATUS}) — this is NOT a verdict on the workflows." >&2
  echo "${RESULT:-(the harness produced no output)}" >&2
  exit 2
fi

grep -E '^(NOTE|COLLAPSE) ' <<<"$RESULT" || true

if grep -q '^FAIL ' <<<"$RESULT"; then
  echo "" >&2
  # shellcheck disable=SC2016  # the backticks are literal prose, not substitution
  echo 'never-cancel-main gate FAILED — `cancelled` is a NON-PASS (honest-gates D12).' >&2
  grep '^FAIL ' <<<"$RESULT" >&2
  echo "" >&2
  echo "Fix: in that workflow's concurrency block, replace" >&2
  echo "    cancel-in-progress: true" >&2
  echo "with the ref guard (mirroring .github/workflows/elixir.yml:37-40)" >&2
  echo "    # Cancel superseded PR runs, but NEVER cancel main: fast push cadence" >&2
  echo "    # otherwise starves the suite (2026-06-10: 19 consecutive main runs" >&2
  echo "    # cancelled, zero completions all day). Queued main runs collapse to one." >&2
  echo "    cancel-in-progress: \${{ github.ref != 'refs/heads/main' }}" >&2
  echo "" >&2
  echo "Deliberate never-cancel (deploy/release) may use \`cancel-in-progress: false\`." >&2
  exit 1
fi

echo "never-cancel-main gate OK — no push-to-main workflow cancels its own in-progress runs."
