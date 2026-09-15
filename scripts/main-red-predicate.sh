#!/usr/bin/env bash
# main-red-predicate.sh — WHAT IS RED ON MAIN, BY PREDICATE, NOT BY MEMORY.
#
# WHY THIS EXISTS. Main's previous ledger re-ran THE SCRIPTS IT ALREADY KNEW
# ABOUT and called the result "main's red ledger". That instrument can only
# confirm or clear a KNOWN red; it is structurally incapable of finding a new
# one. gates found `gate-map.test.mjs` failing on pristine main — invisible to
# all four instruments main was running, because its workflow is paths-filtered
# and HAS NO COMPLETED RUN ON MAIN AT ALL. A red that cannot be observed on the
# branch it is red on.
#
# THE PREDICATE: enumerate every workflow carrying a `push:` arm, then ask GitHub
# for its most recent COMPLETED run on main. Three buckets, and the third is the
# point:
#     RED         a completed main run concluded failure
#     GREEN       a completed main run concluded success
#     CANNOT READ no completed main run exists  <-- NOT green. Debt accrues here.
#
# FAILS CLOSED. An unreadable workflow list, or an unreadable run feed, refuses
# rather than reporting an empty red set. A zero-red verdict from a broken query
# is the exact failure this file exists to stop.
#
# CONTROL, run every invocation: the run feed must return MORE THAN ONE distinct
# workflow name. A feed that sees one thing cannot discriminate, and its silence
# about the other 40 is not evidence.
set -uo pipefail
# --------------------------------------------------------- SMOKE SELFTEST (no network) -------
# ADDED WHEN THIS FILE WAS VENDORED (2026-09-16). Everything below the selftest is the r19
# scratchpad tool verbatim. A vendored file that nothing executes rots silently, so
# `main-red-predicate.sh --selftest` proves WITHOUT ONE NETWORK CALL that the file is not
# truncated, that its FOUR interpreters exist (bash, gh, jq AND python3 — the tags-only
# partition is a python3 heredoc, and a missing python3 would silently mis-bucket every
# workflow), and that the two verdicts that matter still discriminate:
#   * a feed that sees ONE workflow name must REFUSE (exit 4), never report an empty red set —
#     this is the fail-closed control the file's own header promises;
#   * the same run with a healthy feed must CLASSIFY (red vs green vs tags-only N/A).
# The green arm is not decoration: a tool that answered RED to everything would pass the red
# arm while measuring nothing. Both arms run against this repo's REAL .github/workflows, so the
# tags-only partition (cli-release.yml, release.yml) is exercised for real.
_MRP_SELF="${BASH_SOURCE[0]}"; case "$_MRP_SELF" in */*) _MRP_DIR="${_MRP_SELF%/*}";; *) _MRP_DIR=".";; esac
_MRP_DIR=$(cd "$_MRP_DIR" 2>/dev/null && pwd) || _MRP_DIR="."
_MRP_SELF="$_MRP_DIR/${_MRP_SELF##*/}"

_mrp_selftest() {
  local d fails=0 pass=0 out rc
  _ok(){ printf 'PASS %-26s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
  _no(){ printf 'FAIL %-26s %s\n' "$1" "${2:-}"; fails=$((fails+1)); }

  if bash -n "$_MRP_SELF" 2>/dev/null; then _ok "parses" "bash -n clean"
  else _no "parses" "bash -n FAILED — file truncated or malformed"; fi
  if grep -qF 'CANNOT READ: run feed shows' "$_MRP_SELF" \
  && grep -qF 'branch-driven push workflows' "$_MRP_SELF"; then _ok "not truncated" "control text + summary line both present"
  else _no "not truncated" "a load-bearing line is missing — file truncated"; fi
  for t in gh jq python3 git; do
    if command -v "$t" >/dev/null 2>&1; then _ok "dep $t" "$(command -v "$t")"
    else _no "dep $t" "NOT ON PATH — this tool cannot run correctly"; fi
  done

  d=$(mktemp -d) || { echo "SELFTEST: CANNOT READ — no tmpdir"; return 1; }
  mkdir -p "$d/bin"
  cat > "$d/bin/gh" <<'STUB'
#!/usr/bin/env bash
# MRP_FEED drives the discrimination CONTROL, MRP_CONC the per-workflow verdict.
# Nothing here reaches the network.
case " $* " in
  *"--json name"*)
    case "${MRP_FEED:-many}" in
      dead) exit 1;;
      one)  echo '[{"name":"only-one"}]'; exit 0;;
      *)    echo '[{"name":"a"},{"name":"b"},{"name":"c"}]'; exit 0;;
    esac;;
  *"--json conclusion,headSha,createdAt,status"*)
    printf '[{"conclusion":"%s","headSha":"abcdef1234567890","createdAt":"2026-01-01T00:00:00Z","status":"completed"}]\n' "${MRP_CONC:-failure}"
    exit 0;;
esac
exit 1
STUB
  chmod +x "$d/bin/gh"

  _arm(){ # label FEED CONC want-exit needle [forbidden]
    local lbl="$1" feed="$2" conc="$3" wrc="$4" need="$5" bad="${6:-}"
    out=$(PATH="$d/bin:$PATH" MRP_FEED="$feed" MRP_CONC="$conc" bash "$_MRP_SELF" acme/widget 2>&1); rc=$?
    if [ "$rc" != "$wrc" ]; then _no "$lbl" "exit=$rc (want $wrc) | $(printf '%s\n' "$out" | tail -1)"; return; fi
    case "$out" in *"$need"*) : ;; *) _no "$lbl" "output lacks [$need]"; return;; esac
    if [ -n "$bad" ]; then case "$out" in *"$bad"*) _no "$lbl" "output CONTAINS the forbidden [$bad]"; return;; esac; fi
    _ok "$lbl" "$(printf '%s\n' "$out" | grep -m1 'branch-driven push workflows' || printf '%s\n' "$out" | tail -1)"
  }
  # FAIL CLOSED. A feed that cannot discriminate must refuse, never report "no reds".
  _arm "one-name feed refuses" one    failure 4 "cannot discriminate" "RED ON MAIN"
  _arm "dead feed refuses"     dead   failure 4 "CANNOT READ"         "RED ON MAIN"
  # CLASSIFIES. Red and green must reach DIFFERENT verdicts, or neither measured anything.
  _arm "reds are reported"     many   failure 1 "RED ON MAIN"
  _arm "greens are not reds"   many   success 0 "red 0"               "failure"
  # The tags-only partition must fire against this repo's real workflows, or a tags-only
  # workflow gets booked as debt it can never discharge.
  out=$(PATH="$d/bin:$PATH" MRP_FEED=many MRP_CONC=success bash "$_MRP_SELF" acme/widget 2>&1)
  case "$out" in
    *"tags-only push arm"*) _ok "tags-only partition" "$(printf '%s\n' "$out" | grep -m1 'branch-driven push workflows')" ;;
    *) _no "tags-only partition" "no tags-only workflow was partitioned — the python3 arm is not firing" ;;
  esac
  rm -rf "$d"
  local total=$((pass+fails))
  if [ "$total" -lt 8 ]; then echo "SELFTEST: CANNOT READ — only $total arm(s) ran; this tally measures nothing"; return 1; fi
  [ "$fails" = 0 ] && { echo "SELFTEST: $pass/$total arms pass"; return 0; }
  echo "SELFTEST: $fails of $total arm(s) FAILED"; return 1
}
[ "${1:-}" = "--selftest" ] && { _mrp_selftest; exit $?; }

REPO="${1:-FRIKKern/barkpark}"
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 4

WF_DIR=.github/workflows
[ -d "$WF_DIR" ] || { echo "CANNOT READ: no $WF_DIR"; exit 4; }

# --- CONTROL 1: the run feed sees more than one workflow -----------------------
# NOTE, MEASURED 2026-09-15: a 200-row completed-main feed reaches back only
# ~49 MINUTES on this repo. An earlier version of this script bucketed "absent
# from that feed" as "no completed main run" — WHICH IS FALSE. `bp-graph-drift`
# was absent from the window and has a SUCCESS from 2026-09-13. That is the
# enumeration-read-as-a-predicate fault, committed inside the tool written to
# cure it. The feed is now used ONLY as a discrimination control; every verdict
# comes from a PER-WORKFLOW query, which is not windowed.
FEED=$(gh run list --repo "$REPO" --branch main --status completed --limit 200 --json name 2>&1)
if [ -z "$FEED" ] || ! printf '%s' "$FEED" | jq -e 'type=="array"' >/dev/null 2>&1; then
  echo "CANNOT READ: main run feed unreadable — refusing to report a red set"; exit 4
fi
DISTINCT=$(printf '%s' "$FEED" | jq -r '[.[].name]|unique|length')
if [ "${DISTINCT:-0}" -lt 2 ]; then
  echo "CANNOT READ: run feed shows $DISTINCT distinct workflow name(s) — cannot discriminate"; exit 4
fi
echo "control: run feed sees $DISTINCT distinct workflow names on main"

# --- enumerate workflows carrying a push: arm ----------------------------------
red=0; green=0; unseen=0; total=0; na=0
RED_LIST=$(mktemp); UNSEEN_LIST=$(mktemp); NA_LIST=$(mktemp)
for f in "$WF_DIR"/*.yml "$WF_DIR"/*.yaml; do
  [ -f "$f" ] || continue
  grep -qE '^[[:space:]]*push:' "$f" || continue
  # TAGS-ONLY PUSH ARMS ARE NOT BRANCH-DRIVEN (cli, 2026-09-15). A `push:` arm whose
  # only key is `tags:` MATCHES this grep while being STRUCTURALLY INCAPABLE of a main
  # run — so an earlier version reported them as "no completed main run", i.e. as debt.
  # Measured: 53 workflows carry `branches:`, exactly 2 are tags-only
  # (cli-release.yml, release.yml), 0 are bare. CONTROL: the branches count is non-zero,
  # so the partition discriminates. Report these as N/A, never as unread.
  if python3 - "$f" <<'PYEOF'
import sys,re
lines=open(sys.argv[1]).read().split("\n")
pi=next((i for i,l in enumerate(lines) if re.match(r"^\s*push:\s*(#.*)?$", l)), None)
if pi is None: sys.exit(1)
ind=len(lines[pi])-len(lines[pi].lstrip()); keys=set()
for l in lines[pi+1:]:
    if not l.strip() or l.lstrip().startswith("#"): continue
    if len(l)-len(l.lstrip())<=ind: break
    if ":" in l: keys.add(l.strip().split(":")[0])
sys.exit(0 if ("tags" in keys and not {"branches","branches-ignore"} & keys) else 1)
PYEOF
  then
    na=$((na+1)); printf '%s\ttags-only push arm — NOT branch-driven, a main run is impossible\n' "$(basename "$f")" >> "$NA_LIST"
    continue
  fi
  total=$((total+1))
  BASE=$(basename "$f")
  # PER-WORKFLOW, NOT WINDOWED. Take the most recent run with a real conclusion:
  # an in-progress run has conclusion null and must never be read as a verdict.
  ROW=$(gh run list --repo "$REPO" --workflow="$BASE" --branch main --limit 20 \
          --json conclusion,headSha,createdAt,status 2>/dev/null \
        | jq -r '[.[]|select(.status=="completed" and .conclusion!=null and .conclusion!="")]
                 | sort_by(.createdAt) | reverse | .[0] // empty')
  if [ -z "$ROW" ]; then
    unseen=$((unseen+1)); printf '%s\tno completed main run EVER\n' "$BASE" >> "$UNSEEN_LIST"; continue
  fi
  # (the unread annotation below uses cli's discriminator — see the *: arm)
  CONC=$(printf '%s' "$ROW" | jq -r '.conclusion'); SHA=$(printf '%s' "$ROW" | jq -r '.headSha[0:9]')
  WHEN=$(printf '%s' "$ROW" | jq -r '.createdAt')
  case "$CONC" in
    failure|timed_out|startup_failure)
      red=$((red+1)); printf '%s\t%s\t%s\t%s\n' "$CONC" "$SHA" "$WHEN" "$BASE" >> "$RED_LIST";;
    success) green=$((green+1));;
    *) unseen=$((unseen+1))
       # A CANCEL DESTROYS A VERDICT; IT DOES NOT DESTROY THE RUN RECORD (cli, 2026-09-15).
       # A cancelled run still EXISTS in the runs list with conclusion=cancelled, so
       # total_count settles in ONE call whether an absence is STRUCTURAL (no run was ever
       # created) or merely UNMEASURED (runs exist, verdicts were destroyed). Main's own
       # sweep destroyed verdicts tonight; this is how main bounds its own damage instead
       # of guessing. CONTROLS: cli-release.yml (tags-only) reads 0; elixir.yml reads 7450.
       TC=$(gh api "repos/$REPO/actions/workflows/$BASE/runs?branch=main&per_page=1" --jq '.total_count' 2>/dev/null)
       CN=$(gh api "repos/$REPO/actions/workflows/$BASE/runs?branch=main&per_page=100" --jq '[.workflow_runs[]|select(.conclusion=="cancelled")]|length' 2>/dev/null)
       if [ "${TC:-0}" = "0" ]; then
         printf '%s\tlast completed = %s — and total_count=0: NO MAIN RUN WAS EVER CREATED (structural)\n' "$BASE" "$CONC" >> "$UNSEEN_LIST"
       else
         printf '%s\tlast completed = %s (%s) — runs EXIST (total %s on main, %s cancelled in last 100): a VERDICT was destroyed, not a run\n' \
           "$BASE" "$CONC" "$WHEN" "${TC:-?}" "${CN:-?}" >> "$UNSEEN_LIST"
       fi;;
  esac
done

echo
echo "RED ON MAIN ($red):"
[ -s "$RED_LIST" ] && sort "$RED_LIST" | sed 's/^/  /' || echo "  (none)"
echo
echo "NO SUCCESS/FAILURE VERDICT ON MAIN — CANNOT READ, NOT GREEN ($unseen):"
[ -s "$UNSEEN_LIST" ] && sort "$UNSEEN_LIST" | sed 's/^/  /' || echo "  (none)"
echo
echo
echo "N/A — TAGS-ONLY push arm, a main run is structurally impossible ($na):"
[ -s "$NA_LIST" ] && sort "$NA_LIST" | sed 's/^/  /' || echo "  (none)"
echo
echo "branch-driven push workflows = $total · red $red · green $green · unread $unseen · n/a $na"
if [ "$total" -lt 5 ]; then
  echo "CANNOT READ: only $total workflow(s) carried a push: arm — this measures nothing"; exit 4
fi
rm -f "$RED_LIST" "$UNSEEN_LIST"
[ "$red" -gt 0 ] && exit 1
[ "$unseen" -gt 0 ] && exit 2
exit 0
