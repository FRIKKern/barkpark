#!/usr/bin/env bash
# main-collapse-criterion-check.sh — A CRITERION MAY NOT NAME A RUN THAT WILL
# NEVER EXIST.
#
# THE DEFECT (task-9ee58a247b158826, measured 2026-09-13 and re-measured
# 2026-09-16). Five workflows declare themselves main-collapsible: every push to
# main shares ONE concurrency group, so each merge evicts the PENDING
# intermediate run. That is deliberate (task-e376642d6d69fa3f; it bought back a
# 31% queue regression) and this check does NOT argue with it.
#
# What it does argue with is a ledger criterion phrased
#
#     "merged to main; the next main compose-smoke run shows the census green"
#
# Under the collapse there may BE no run for that merge sha — it was evicted
# while pending. The criterion names a subject that does not exist, so it can
# never be honestly stamped or honestly missed. RE-MEASURED 2026-09-16 over the
# last 60 main shas older than 1h, counting only shas that actually TRIGGERED
# the workflow (a paths-filtered skip is not an eviction):
#
#     compose-smoke            44/60 shas got a verdict  — 27% evicted
#     go-format                10/16                     — 37% evicted
#     go-tests                 13/21                     — 38% evicted
#     search-template-gates    52/60                     — 13% evicted
#     Shell harnesses          23/29                     — 21% evicted
#     ------------------------------------------------------------------
#     all five                142/186 = 76% verdict       — 24% NO VERDICT
#     CONTROL, per-sha groups: elixir.yml 60/60, cloud.yml 60/60 — 0% evicted.
#
# The row that opened this said ~65%. That number counted paths-filtered
# NON-RUNS as evictions; at 2026-09-16 cadence the real per-sha loss is 24%.
# It is cadence-dependent and it is never zero, which is enough: a gate with a
# one-in-four chance of naming a nonexistent subject is not a gate.
#
# THE HONEST FORM is ancestry, not identity:
#     "the next COMPLETED main run of X whose head sha is the merge sha OR a
#      descendant of it"
# — a descendant run's verdict covers the merge, and one always arrives.
#
# THE POPULATION IS DERIVED, NEVER LISTED. It is
#     grep -l 'main-collapse: harness-ok' .github/workflows/*.yml
# read at check time. Mark a sixth workflow collapsible and this check judges
# criteria naming it with no edit here. A population of ZERO is a hard FAIL, not
# "no violations" — a check whose corpus vanished has measured nothing.
#
# EXIT CODES
#   0  no live criterion names a collapsible workflow in the identity form
#   1  FINDING — row id, criterion index and workflow are named
#   2  CANNOT MEASURE — empty population, no python3, no ledger. Never a
#      vacuous green.
#
# USAGE
#   bash scripts/main-collapse-criterion-check.sh              # live ledger via bp
#   bash scripts/main-collapse-criterion-check.sh --rows f.json # rows from a file
#   bash scripts/main-collapse-criterion-check.sh --selftest
# MCC_WORKFLOW_ROOT overrides the workflow directory (--selftest uses it).
set -uo pipefail
cd "$(dirname "$0")/.."

WF_ROOT="${MCC_WORKFLOW_ROOT:-.github/workflows}"
ROWS=""
case "${1:-}" in
  --selftest) ;;
  --rows) ROWS="${2:-}"; [ -n "$ROWS" ] || { echo "main-collapse-criterion-check: --rows needs a file" >&2; exit 2; };;
  "") ;;
  *) echo "main-collapse-criterion-check: unknown argument '$1'" >&2; exit 2;;
esac

command -v python3 >/dev/null 2>&1 || { echo "CANNOT MEASURE: no python3"; exit 2; }

# ---- the DERIVED population -------------------------------------------------
mcc_population() {
  grep -l 'main-collapse: harness-ok' "$WF_ROOT"/*.yml 2>/dev/null || true
}

mcc_scan() { # $1 = rows json file
  python3 - "$1" "$WF_ROOT" <<'PY'
import sys, json, re, glob, os

rows_path, wf_root = sys.argv[1], sys.argv[2]

# POPULATION, DERIVED AT RUN TIME.
pop = []
for f in sorted(glob.glob(os.path.join(wf_root, "*.yml"))):
    txt = open(f, encoding="utf-8", errors="replace").read()
    if "main-collapse: harness-ok" not in txt:
        continue
    base = os.path.basename(f)
    aliases = {base, base[:-4]}                      # compose-smoke.yml, compose-smoke
    m = re.search(r"^name:\s*(.+?)\s*$", txt, re.M)  # the DECLARED name: "Shell harnesses"
    if m:
        aliases.add(m.group(1).strip().strip('"\''))
    pop.append((base, aliases))

print("population (grep -l 'main-collapse: harness-ok' %s/*.yml): %d" % (wf_root, len(pop)))
for base, al in pop:
    print("  %-28s aliases: %s" % (base, ", ".join(sorted(al))))
if not pop:
    # A VANISHED CORPUS IS NOT A CLEAN BILL. Refuse.
    print("CANNOT MEASURE: population is ZERO — the marker grep matched nothing; refusing to report 'no violations'")
    sys.exit(2)

def norm(s):
    return re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()

# "the next [completed] main <X> run" / "the next main run of <X>" — the IDENTITY form.
NEXT_RUN = re.compile(r"\bnext\b[^.;]{0,120}?\brun\b", re.I)
MAIN     = re.compile(r"\bmain\b", re.I)
# The ANCESTRY qualifier that makes the subject exist. Any of these disarms the finding.
# A CRITERION THAT QUOTES THE BAD WORDING IN ORDER TO SPECIFY A DETECTOR IS NOT
# A GATE ON A RUN. Specimen, found the first time this check ran live: the row
# that commissioned it (task-9ee58a247b158826, criterion[1]) reads
#   "MUTATION ARM THAT REDS IT: file a draft row whose criterion reads
#    'merged to main; the next main compose-smoke run is green' and the check
#    must name that row, that criterion index, and compose-smoke."
# Flagging that is a self-reference, not a finding — nobody will ever wait on a
# compose-smoke run to satisfy it. The exemption takes TWO conditions together,
# so it is a rule and not a waiver for this one row: the run phrase must sit
# INSIDE quotes (a real gate does not quote its own subject) AND the sentence
# must carry an explicit detector-specification marker.
QUOTED   = re.compile(r"['\"‘’“”]")
SPECMARK = re.compile(r"MUTATION ARM|the check must|must be flagged|must NOT be flagged|"
                      r"must not be flagged|detector from criterion", re.I)
ANCESTRY = re.compile(
    r"descendant|descends from|\bancestor\b|head[ _]sha is the merge sha|"
    r"whose head sha|merge sha or a descendant|is-ancestor",
    re.I)

rows = json.load(open(rows_path))
if isinstance(rows, dict):
    rows = rows.get("docs") or rows.get("rows") or []
if not isinstance(rows, list):
    print("CANNOT MEASURE: rows file is not a list and carries no .docs[]")
    sys.exit(2)
print("ledger rows read: %d" % len(rows))

findings = []
for r in rows:
    doc = r.get("doc", r)
    rid = doc.get("doc_id") or r.get("doc_id") or "<no id>"
    life = (doc.get("lifecycle_status") or r.get("lifecycle_status") or "").lower()
    if life not in ("open", "in_progress"):
        continue
    crits = (doc.get("content") or {}).get("acceptance_criteria") or []
    for i, c in enumerate(crits):
        text = c.get("criterion", "") if isinstance(c, dict) else str(c)
        if not text:
            continue
        # sentence-scope so a qualifier three paragraphs away cannot disarm it
        for sent in re.split(r"(?<=[.;])\s+", text):
            if not (NEXT_RUN.search(sent) and MAIN.search(sent)):
                continue
            n = norm(sent)
            hit = None
            for base, al in pop:
                for a in al:
                    if norm(a) and norm(a) in n:
                        hit = base
                        break
                if hit:
                    break
            if not hit:
                continue
            if ANCESTRY.search(sent):
                continue
            if QUOTED.search(sent) and SPECMARK.search(sent):
                continue  # a detector SPECIFICATION quoting the bad form, not a gate
            findings.append((rid, i, hit, sent.strip()[:160]))
            break

if findings:
    print("")
    print("FINDING — %d criterion/criteria name a main-collapse workflow in the IDENTITY form:" % len(findings))
    for rid, i, wf, sent in findings:
        print("  %s  criterion[%d]  %s" % (rid, i, wf))
        print("      %s" % sent)
    print("")
    print("  REWORD to the ancestry form: \"the next COMPLETED main run of <X> whose")
    print("  head sha is the merge sha OR a descendant of it\". Under the collapse the")
    print("  run for THAT sha may have been evicted while pending and never exist.")
    sys.exit(1)
print("")
print("main-collapse-criterion gate OK — no live (open/in_progress) criterion names one of")
print("the %d collapsible workflow(s) in the identity form." % len(pop))
sys.exit(0)
PY
}

# ---- SELFTEST: planted workflows + planted rows, no network -------------------
if [ "${1:-}" = "--selftest" ]; then
  pass=0; fails=0
  _ok(){ printf 'PASS %-34s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
  _no(){ printf 'FAIL %-34s %s\n' "$1" "${2:-}"; fails=$((fails+1)); }
  D=$(mktemp -d) || { echo "SELFTEST: CANNOT MEASURE — no tmpdir"; exit 2; }
  mkdir -p "$D/wf"
  _plant(){ # $1 file  $2 declared name  $3 marked?
    { echo "name: $2"; echo "concurrency:";
      [ "$3" = yes ] && echo "  # main-collapse: harness-ok - planted (task-selftest)";
      echo "  group: x"; } > "$D/wf/$1"; }
  _plant compose-smoke.yml "compose-smoke"     yes
  _plant shell-harnesses.yml "Shell harnesses" yes
  _plant go-tests.yml "go-tests"               yes
  _plant search-template-gates.yml "search-template-gates" yes
  _plant go-format.yml "Go format"             yes
  _plant elixir.yml "elixir"                   no    # CONTROL: not collapsible

  _rows(){ cat > "$D/rows.json"; }
  _run(){ MCC_WORKFLOW_ROOT="$D/wf" bash "$0" --rows "$D/rows.json" 2>&1; }

  # ARM 1 — POPULATION IS DERIVED. Five planted markers must be read as five.
  _rows <<'J'
[]
J
  out=$(_run); rc=$?
  case "$out" in *"population (grep -l 'main-collapse: harness-ok'"*": 5"*) _ok "population derives 5" "rc=$rc";; *) _no "population derives 5" "$(printf '%s' "$out"|head -1)";; esac
  # ARM 2 — AND IT GROWS WITH THE TREE, with NO edit to this file.
  _plant sixth-harness.yml "sixth-harness" yes
  out=$(_run)
  case "$out" in *": 6"*) _ok "a sixth marker moves it to 6" "no edit to the check";; *) _no "a sixth marker moves it to 6" "$(printf '%s' "$out"|head -1)";; esac
  trash "$D/wf/sixth-harness.yml" 2>/dev/null || rm -f "$D/wf/sixth-harness.yml"
  # ARM 3 — A ZERO POPULATION REFUSES. It must never read as "no violations".
  mkdir -p "$D/empty"
  out=$(MCC_WORKFLOW_ROOT="$D/empty" bash "$0" --rows "$D/rows.json" 2>&1); rc=$?
  if [ "$rc" = 2 ] && case "$out" in *"population is ZERO"*) true;; *) false;; esac
  then _ok "zero population refuses" "rc=2"; else _no "zero population refuses" "rc=$rc | $out"; fi

  # ARM 4 — THE MUTATION THE ROW SPECIFIES. This exact wording must be flagged,
  # by row id, criterion index AND workflow.
  _rows <<'J'
[{"doc":{"doc_id":"task-selftest-bad","lifecycle_status":"open","content":{"acceptance_criteria":[
  {"criterion":"a harmless first criterion with no run in it"},
  {"criterion":"merged to main; the next main compose-smoke run is green"}]}}}]
J
  out=$(_run); rc=$?
  if [ "$rc" = 1 ] && case "$out" in *"task-selftest-bad  criterion[1]  compose-smoke.yml"*) true;; *) false;; esac
  then _ok "identity form is flagged" "row+index+workflow named"; else _no "identity form is flagged" "rc=$rc | $(printf '%s' "$out"|tail -3)"; fi

  # ARM 5 — THE QUIET ARM. The ancestry wording must NOT be flagged, or the
  # check is a blanket ban on the word "run" and tells nobody anything.
  _rows <<'J'
[{"doc":{"doc_id":"task-selftest-good","lifecycle_status":"open","content":{"acceptance_criteria":[
  {"criterion":"merged to main; the next completed main run of compose-smoke whose head sha is the merge sha or a descendant of it is green"}]}}}]
J
  out=$(_run); rc=$?
  if [ "$rc" = 0 ] && case "$out" in *"gate OK"*) true;; *) false;; esac
  then _ok "ancestry form stays quiet" "rc=0"; else _no "ancestry form stays quiet" "rc=$rc | $(printf '%s' "$out"|tail -3)"; fi

  # ARM 6 — DECLARED-NAME ALIAS. "Shell harnesses" is the workflow's `name:`,
  # not its basename, and every live offender on the ledger uses that spelling.
  _rows <<'J'
[{"doc":{"doc_id":"task-selftest-alias","lifecycle_status":"open","content":{"acceptance_criteria":[
  {"criterion":"merged; the next main Shell harnesses run shows the step green"}]}}}]
J
  out=$(_run); rc=$?
  if [ "$rc" = 1 ] && case "$out" in *"shell-harnesses.yml"*) true;; *) false;; esac
  then _ok "declared name matches too" "Shell harnesses -> shell-harnesses.yml"; else _no "declared name matches too" "rc=$rc"; fi

  # ARM 7 — NOISE CONTROL 1: a NON-collapsible workflow in the same wording is
  # NOT a finding. elixir.yml keeps a per-sha group; its next main run exists.
  _rows <<'J'
[{"doc":{"doc_id":"task-selftest-elixir","lifecycle_status":"open","content":{"acceptance_criteria":[
  {"criterion":"merged to main; the next main elixir run is green"}]}}}]
J
  out=$(_run); rc=$?
  if [ "$rc" = 0 ]; then _ok "per-sha workflow is not flagged" "elixir rc=0"; else _no "per-sha workflow is not flagged" "rc=$rc"; fi

  # ARM 8 — NOISE CONTROL 2: a CLOSED row is not live and is not the gate's
  # business. Same text as ARM 4, lifecycle done.
  _rows <<'J'
[{"doc":{"doc_id":"task-selftest-done","lifecycle_status":"done","content":{"acceptance_criteria":[
  {"criterion":"merged to main; the next main compose-smoke run is green"}]}}}]
J
  out=$(_run); rc=$?
  if [ "$rc" = 0 ]; then _ok "closed rows are out of scope" "rc=0"; else _no "closed rows are out of scope" "rc=$rc"; fi

  # ARM 9 — THE SELF-REFERENCE EXEMPTION. A criterion that QUOTES the bad wording
  # while specifying a detector is not a gate on a run. Verbatim from the row that
  # commissioned this check.
  _rows <<'J'
[{"doc":{"doc_id":"task-selftest-spec","lifecycle_status":"open","content":{"acceptance_criteria":[
  {"criterion":"MUTATION ARM THAT REDS IT: file a draft row whose criterion reads 'merged to main; the next main compose-smoke run is green' and the check must name that row, that criterion index, and compose-smoke."}]}}}]
J
  out=$(_run); rc=$?
  if [ "$rc" = 0 ]; then _ok "quoted spec is exempt" "rc=0"; else _no "quoted spec is exempt" "rc=$rc"; fi

  # ARM 10 — AND THE EXEMPTION IS NARROW. Quotes ALONE do not buy it: the same
  # wording in quotes with no detector-specification marker is STILL a finding.
  # Without this arm the exemption would be "any criterion with an apostrophe".
  _rows <<'J'
[{"doc":{"doc_id":"task-selftest-quoted-only","lifecycle_status":"open","content":{"acceptance_criteria":[
  {"criterion":"merged to main; the 'next main compose-smoke run' is green"}]}}}]
J
  out=$(_run); rc=$?
  if [ "$rc" = 1 ]; then _ok "quotes alone are not exempt" "rc=1"; else _no "quotes alone are not exempt" "rc=$rc"; fi

  trash "$D" 2>/dev/null || rm -rf "$D"
  total=$((pass+fails))
  [ "$total" -lt 10 ] && { echo "SELFTEST: CANNOT MEASURE — only $total arm(s) ran"; exit 2; }
  [ "$fails" = 0 ] && { echo "SELFTEST: $pass/$total arms pass"; exit 0; }
  echo "SELFTEST: $fails of $total arm(s) FAILED"; exit 1
fi

# ---- live run ----------------------------------------------------------------
POP=$(mcc_population)
if [ -z "$POP" ]; then
  echo "CANNOT MEASURE: population is ZERO — no workflow under $WF_ROOT carries 'main-collapse: harness-ok'"
  exit 2
fi

if [ -z "$ROWS" ]; then
  command -v bp >/dev/null 2>&1 || { echo "CANNOT MEASURE: no bp on PATH and no --rows file"; exit 2; }
  ROWS=$(mktemp)
  {
    env -u BARKPARK_TOKEN bp task ls --status open --all -o json 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);print(json.dumps(d.get("docs",[])))' 2>/dev/null
    env -u BARKPARK_TOKEN bp task ls --status in_progress --all -o json 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);print(json.dumps(d.get("docs",[])))' 2>/dev/null
  } | python3 -c 'import sys,json
out=[]
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    out.extend(json.loads(line))
print(json.dumps(out))' > "$ROWS"
  if [ ! -s "$ROWS" ] || [ "$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$ROWS" 2>/dev/null || echo 0)" = 0 ]; then
    echo "CANNOT MEASURE: the ledger read returned ZERO rows — that is unreadable, not clean"
    exit 2
  fi
fi

mcc_scan "$ROWS"
