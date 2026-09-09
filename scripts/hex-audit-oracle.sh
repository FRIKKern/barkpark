#!/usr/bin/env bash
#
# hex-audit-oracle.sh — the SECOND CVE oracle, and the honest reporter for both.
#
# WHY THIS EXISTS (cch-w12-bl-cve-gate-is-oracle-blind).
#
#   Two oracles, the same lockfiles, the same commit, opposite answers:
#
#     mix deps.audit  (mix_audit 2.1.5, mirego's advisory DB — the oracle the CI
#                      job has always used)  -> "No vulnerabilities found."
#     mix hex.audit   (Hex's own OSV-backed feed, over the SAME api/mix.lock)
#                      -> 17 advisories, 4 HIGH   (measured 2026-09-09, local)
#
#   Worse for the second lock: the CVE job is declared `working-directory: api`,
#   so cloud/mix.lock was never audited by ANY oracle. `mix hex.audit` over it
#   reports 14 advisories, 5 HIGH (measured 2026-09-09, local). mix_audit gives
#   no answer there at all — mix_audit is an api-only dep, so in cloud/ the task
#   does not exist. This script reports that as ORACLE-UNAVAILABLE, which is a
#   DIFFERENT WORD from clean, on purpose (charter: a failed read must never be
#   byte-identical to a zero).
#
# WHAT IT DOES NOT DO. It does not make anything blocking. Which oracle should
#   gate a merge is criterion 1 of that row and is HELD FOR THE OWNER
#   (owner-queue item 47). This script is wired into the ALREADY non-blocking
#   `Dependency CVE audit (… non-blocking)` job as extra STEPS — no new job
#   name, so no .github/required-checks.json row is needed and the required
#   census cannot drift.
#
# EXIT CODES — three outcomes, never collapsed:
#     0  every audited lock is readable and carries NO HIGH/CRITICAL advisory
#        (LOW/MEDIUM advisories are still PRINTED and counted; they do not red)
#     1  at least one HIGH or CRITICAL advisory — the visible red
#     3  CANNOT READ: a lock is missing, or `mix hex.audit` failed without
#        producing an advisory report (hex down, no network, no project).
#        NEVER 0. A refused feed is not a clean feed.
#
# USAGE
#     scripts/hex-audit-oracle.sh                      # audits api/ and cloud/
#     scripts/hex-audit-oracle.sh --dir api            # one lock
#     scripts/hex-audit-oracle.sh --ignore EEF-CVE-…   # repeatable; matches the
#                                                      # advisory id OR any aka
#     scripts/hex-audit-oracle.sh --from-file F --label L   # parse a captured
#                                                      # report instead of running
#     scripts/hex-audit-oracle.sh --selftest           # prove the parser can fail
#
# NOT PIPED, EVER. Read to EOF. `… | grep -q` under pipefail returns 141 on
# SIGPIPE and launders this script's verdict into a lie (charter D37).

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"

DIRS=()
IGNORES=()
FROM_FILE=""
FROM_LABEL=""
BASELINE=""
SELFTEST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)       DIRS+=("$2"); shift 2 ;;
    --ignore)    IGNORES+=("$2"); shift 2 ;;
    --from-file) FROM_FILE="$2"; shift 2 ;;
    --label)     FROM_LABEL="$2"; shift 2 ;;
    --baseline)  BASELINE="$2"; shift 2 ;;
    --selftest)  SELFTEST=1; shift ;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "hex-audit-oracle: unknown argument '$1'" >&2; exit 64 ;;
  esac
done

# ── the parser ─────────────────────────────────────────────────────────────
# A FILE, not an inline heredoc, so --selftest drives the very same code over
# deliberately-broken fixtures. A detector never pointed at a broken input has
# not been shown to detect anything.
PARSER="$(mktemp "${TMPDIR:-/tmp}/hex-audit-parse.XXXXXX.py")"
trap 'rm -f "$PARSER"' EXIT
cat >"$PARSER" <<'PY'
import re, sys

# argv: <report-file> <label> [ignored-id …]
path, label = sys.argv[1], sys.argv[2]
ignores = {i.strip() for i in sys.argv[3:] if i.strip()}

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
raw = open(path, "r", errors="replace").read()
text = ANSI.sub("", raw)

# An entry: "  bandit 1.12.0 - EEF-CVE-2026-65623 (HIGH)" then an optional
# "    aka: CVE-…, GHSA-…" line. Severity is captured as written; an entry with
# no parenthesised severity is UNKNOWN and is treated as HIGH-equivalent
# (an unlabelled advisory must not be silently downgraded to noise).
HEAD = re.compile(r"^ {2}(\S+) (\S+) - (\S+)(?: \((\w+)\))?\s*$")
AKA = re.compile(r"^\s*aka: (.+?)\s*$")

readable = ("Advisories:" in text) or ("Retired:" in text)

entries, cur = [], None
in_adv = False
for line in text.splitlines():
    if line.strip() == "Advisories:":
        in_adv = True
        continue
    if line.strip() == "Retired:":
        in_adv = False
        continue
    if not in_adv:
        continue
    m = HEAD.match(line)
    if m:
        cur = {"pkg": m.group(1), "ver": m.group(2), "id": m.group(3),
               "sev": (m.group(4) or "UNKNOWN").upper(), "aka": []}
        entries.append(cur)
        continue
    m = AKA.match(line)
    if m and cur is not None:
        cur["aka"] = [a.strip() for a in m.group(1).split(",") if a.strip()]

kept, skipped = [], []
for e in entries:
    names = {e["id"], *e["aka"]}
    (skipped if (names & ignores) else kept).append(e)

order = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"]
counts = {s: sum(1 for e in kept if e["sev"] == s) for s in order}
high = counts["CRITICAL"] + counts["HIGH"] + counts["UNKNOWN"]

print(f"[{label}] readable={'yes' if readable else 'NO'} "
      f"advisories={len(kept)} "
      + " ".join(f"{s}={counts[s]}" for s in order)
      + (f" ignored={len(skipped)}" if skipped else ""))
for e in kept:
    print(f"[{label}]   {e['sev']:<8} {e['id']:<22} {e['pkg']} {e['ver']}")
for e in skipped:
    print(f"[{label}]   ignored  {e['id']:<22} {e['pkg']} {e['ver']}")

# machine lines, consumed by the shell caller
for e in kept:
    print(f"##ENTRY {e['sev']} {e['id']} {e['pkg']} {e['ver']}")
print(f"##RESULT {label} readable={int(readable)} total={len(kept)} high={high}")
PY

# summarise <report-file> <label> ; echoes the human report, returns via globals
R_READABLE=0; R_TOTAL=0; R_HIGH=0; R_IDS=""
summarise() {
  local file="$1" label="$2" out
  out="$(python3 "$PARSER" "$file" "$label" "${IGNORES[@]+"${IGNORES[@]}"}")"
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "CANNOT READ [$label]: the hex.audit report parser exited $rc."
    R_READABLE=0; R_TOTAL=0; R_HIGH=0; R_IDS=""
    return 0
  fi
  R_IDS="$(echo "$out" | sed -n 's|^##ENTRY [A-Z]* \([^ ]*\) .*|\1|p')"
  # print everything except the machine lines
  echo "$out" | grep -v '^##RESULT ' | grep -v '^##ENTRY '
  local m
  m="$(echo "$out" | sed -n 's|^##RESULT .* readable=\([01]\) total=\([0-9]*\) high=\([0-9]*\)$|\1 \2 \3|p')"
  if [ -z "$m" ]; then
    echo "CANNOT READ [$label]: the parser emitted no ##RESULT line."
    R_READABLE=0; R_TOTAL=0; R_HIGH=0; R_IDS=""
    return 0
  fi
  read -r R_READABLE R_TOTAL R_HIGH <<<"$m"
}

# ── the baseline ratchet ───────────────────────────────────────────────────
# WHY A RATCHET AND NOT AN ABSOLUTE FLOOR. Measured 2026-09-09 on origin/main:
# api/mix.lock ALREADY carries 17 advisories, 4 of them HIGH, with no upstream
# fix available for several. An absolute "any HIGH reds" rule therefore reds on
# the CLEAN lock, every run, from day one — a gate that is red before anyone
# touches it teaches people to ignore it, and it can never demonstrate the one
# thing criterion 2 asks for (clean green, reverted-lock red).
#
# So the CI wiring compares against a RECORDED BASELINE of advisory ids:
#   an id NOT in the baseline  -> NEW, exit 1 (the red that means something)
#   a baseline id NOT reported -> CLEARED, printed as a notice, exit 0
# A ratchet has two failure directions; this one refuses to red when the world
# got BETTER, and says so out loud instead of silently carrying a stale record.
#
# baseline_ids <file> -> echoes one id per line (field 1, '#' comments stripped)
baseline_ids() {
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' "$1" | awk 'NF {print $1}' | sort -u
}

# baseline_verdict <baseline-file> <seen-ids-file>; sets B_NEW / B_CLEARED counts
B_NEW=0; B_CLEARED=0
baseline_verdict() {
  local bfile="$1" sfile="$2" known new cleared
  known="$(baseline_ids "$bfile")"
  new="$(comm -13 <(echo "$known") <(sort -u "$sfile"))"
  cleared="$(comm -23 <(echo "$known") <(sort -u "$sfile"))"
  B_NEW=$(echo "$new" | awk 'NF' | wc -l | tr -d ' ')
  B_CLEARED=$(echo "$cleared" | awk 'NF' | wc -l | tr -d ' ')
  if [ "$B_NEW" -gt 0 ]; then
    echo "NEW ADVISORIES — not in $bfile ($B_NEW):"
    echo "$new" | awk 'NF {print "  + " $0}'
  else
    echo "NEW ADVISORIES: none. Every reported id is in $bfile."
  fi
  if [ "$B_CLEARED" -gt 0 ]; then
    echo "CLEARED — in the baseline, no longer reported ($B_CLEARED). The world got"
    echo "BETTER; that is a NOTICE, never a red. Trim these from the baseline:"
    echo "$cleared" | awk 'NF {print "  - " $0}'
  fi
}

# ── selftest ───────────────────────────────────────────────────────────────
if [ "$SELFTEST" = "1" ]; then
  T="$(mktemp -d "${TMPDIR:-/tmp}/hex-audit-selftest.XXXXXX")"
  pass=0; fail=0
  ok() { pass=$((pass+1)); echo "  ok   — $1"; }
  no() { fail=$((fail+1)); echo "  FAIL — $1" >&2; }

  cat >"$T/high.txt" <<'FIX'
Advisories:
  bandit 1.12.0 - EEF-CVE-2026-65623 (HIGH)
    aka: CVE-2026-65623, GHSA-vg8x-66vg-5pxh
    Quadratic CPU blow-up reassembling fragmented WebSocket messages in Bandit
    https://osv.dev/vulnerability/EEF-CVE-2026-65623

  swoosh 1.26.2 - EEF-CVE-2026-54893 (LOW)
    aka: CVE-2026-54893
    Something minor
FIX
  # THE MUTANT PAIR. Same file minus the HIGH entry: if the verdict does not
  # move, the parser is not reading severity at all.
  cat >"$T/lowonly.txt" <<'FIX'
Advisories:
  swoosh 1.26.2 - EEF-CVE-2026-54893 (LOW)
    aka: CVE-2026-54893
    Something minor
FIX
  cat >"$T/clean.txt" <<'FIX'
Advisories:
FIX
  cat >"$T/unreadable.txt" <<'FIX'
** (Mix) The task "hex.audit" could not be found
FIX
  cat >"$T/unknownsev.txt" <<'FIX'
Advisories:
  mystery 1.0.0 - EEF-CVE-2026-00000
    aka: CVE-2026-00000
FIX

  echo "hex-audit-oracle --selftest"
  IGNORES=()
  summarise "$T/high.txt" fix; [ "$R_HIGH" = 1 ] && ok "a HIGH entry is counted HIGH (high=$R_HIGH)" || no "high=$R_HIGH, wanted 1"
  [ "$R_TOTAL" = 2 ] && ok "both entries parsed (total=$R_TOTAL)" || no "total=$R_TOTAL, wanted 2"
  summarise "$T/lowonly.txt" fix; [ "$R_HIGH" = 0 ] && [ "$R_TOTAL" = 1 ] && ok "MUTANT: drop the HIGH -> high=0 total=1 (severity really is read)" || no "lowonly gave high=$R_HIGH total=$R_TOTAL"
  summarise "$T/clean.txt" fix; [ "$R_READABLE" = 1 ] && [ "$R_TOTAL" = 0 ] && ok "an empty Advisories block is READABLE and clean" || no "clean gave readable=$R_READABLE total=$R_TOTAL"
  summarise "$T/unreadable.txt" fix; [ "$R_READABLE" = 0 ] && ok "a mix error is UNREADABLE, not clean" || no "unreadable gave readable=$R_READABLE"
  summarise "$T/unknownsev.txt" fix; [ "$R_HIGH" = 1 ] && ok "an advisory with NO severity counts toward the red (never downgraded)" || no "unknownsev gave high=$R_HIGH"
  IGNORES=("GHSA-vg8x-66vg-5pxh")
  summarise "$T/high.txt" fix; [ "$R_HIGH" = 0 ] && [ "$R_TOTAL" = 1 ] && ok "--ignore matches an AKA, not just the primary id" || no "aka-ignore gave high=$R_HIGH total=$R_TOTAL"
  IGNORES=("EEF-CVE-2026-65623")
  summarise "$T/high.txt" fix; [ "$R_HIGH" = 0 ] && ok "--ignore matches the primary id" || no "id-ignore gave high=$R_HIGH"
  IGNORES=("EEF-CVE-1999-99999")
  summarise "$T/high.txt" fix; [ "$R_HIGH" = 1 ] && ok "CONTROL: an --ignore that matches nothing changes nothing" || no "no-match ignore gave high=$R_HIGH"

  # ── the ratchet's own arms, driven over the same code CI runs ────────────
  printf 'EEF-CVE-2026-65623 bandit 1.12.0 HIGH\n# a comment\nEEF-CVE-2026-54893 swoosh\n' >"$T/base.txt"
  printf 'EEF-CVE-2026-65623\nEEF-CVE-2026-54893\n' >"$T/seen.same.txt"
  printf 'EEF-CVE-2026-65623\nEEF-CVE-2026-54893\nEEF-CVE-2026-99999\n' >"$T/seen.new.txt"
  printf 'EEF-CVE-2026-65623\n' >"$T/seen.fewer.txt"
  baseline_verdict "$T/base.txt" "$T/seen.same.txt" >/dev/null
  [ "$B_NEW" = 0 ] && [ "$B_CLEARED" = 0 ] && ok "RATCHET: the baseline's own id set is new=0 cleared=0 (comments stripped)" || no "same gave new=$B_NEW cleared=$B_CLEARED"
  baseline_verdict "$T/base.txt" "$T/seen.new.txt" >/dev/null
  [ "$B_NEW" = 1 ] && ok "RATCHET MUTANT: one unrecorded id -> new=1 (this is the red)" || no "new-id gave new=$B_NEW"
  baseline_verdict "$T/base.txt" "$T/seen.fewer.txt" >/dev/null
  [ "$B_NEW" = 0 ] && [ "$B_CLEARED" = 1 ] && ok "RATCHET OTHER DIRECTION: a cleared id is a notice (new=0 cleared=1), never a red" || no "fewer gave new=$B_NEW cleared=$B_CLEARED"
  if [ -f "$ROOT/.github/hex-audit-baseline.txt" ]; then
    n="$(baseline_ids "$ROOT/.github/hex-audit-baseline.txt" | wc -l | tr -d ' ')"
    [ "$n" -gt 0 ] && ok "the committed baseline parses to $n ids (a baseline that reads as EMPTY would make every id NEW)" || no "the committed baseline parsed to 0 ids"
  else
    no "the committed baseline .github/hex-audit-baseline.txt is missing"
  fi

  rm -rf "$T"
  echo
  echo "selftest: $pass ok, $fail FAIL"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

# ── --from-file: parse a captured report, no mix run ────────────────────────
if [ -n "$FROM_FILE" ]; then
  if [ ! -f "$FROM_FILE" ]; then
    echo "CANNOT READ: --from-file '$FROM_FILE' does not exist."
    exit 3
  fi
  summarise "$FROM_FILE" "${FROM_LABEL:-file}"
  [ "$R_READABLE" = 1 ] || { echo "CANNOT READ: '$FROM_FILE' is not a hex.audit report."; exit 3; }
  [ "$R_HIGH" -eq 0 ] || exit 1
  exit 0
fi

# ── the real run ───────────────────────────────────────────────────────────
if [ "${#DIRS[@]}" -eq 0 ]; then DIRS=(api cloud); fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hex-audit-oracle.XXXXXX")"
unreadable=0; any_high=0; grand_total=0
SEEN="$WORK/seen.txt"; : >"$SEEN"

for d in "${DIRS[@]}"; do
  dir="$ROOT/$d"
  echo "──────────────────────────────────────────────────────────────────────"
  echo "LOCK: $d/mix.lock"
  echo "──────────────────────────────────────────────────────────────────────"

  if [ ! -f "$dir/mix.lock" ]; then
    echo "CANNOT READ [$d]: $dir/mix.lock does not exist. Not reporting this as clean."
    unreadable=1
    continue
  fi

  # ORACLE 1 — mix_audit, the oracle this job has always used. In cloud/ the
  # task does not exist (mix_audit is an api-only dep): that is ORACLE
  # UNAVAILABLE, printed as such, and it is the topological half of the finding.
  o1="$WORK/$d.mix_audit.txt"
  ( cd "$dir" && mix deps.audit --ignore-advisory-ids GHSA-4g2h-vm7x-747c ) >"$o1" 2>&1
  o1rc=$?
  echo "ORACLE 1 — mix deps.audit (mix_audit, mirego DB) — exit $o1rc"
  if grep -q 'could not be found' "$o1"; then
    echo "  ORACLE UNAVAILABLE in $d/ — the mix_audit task is not a dependency here."
    echo "  This is NOT 'no vulnerabilities'. It is no answer at all."
  fi
  sed 's/^/  /' "$o1"
  echo

  # ORACLE 2 — mix hex.audit, Hex's own OSV-backed feed.
  o2="$WORK/$d.hex_audit.txt"
  ( cd "$dir" && mix hex.audit ) >"$o2" 2>&1
  o2rc=$?
  echo "ORACLE 2 — mix hex.audit (Hex/OSV feed) — exit $o2rc"
  sed 's/^/  /' "$o2"
  echo
  summarise "$o2" "$d"
  if [ "$R_READABLE" != "1" ]; then
    echo "CANNOT READ [$d]: mix hex.audit exited $o2rc without producing an advisory report."
    echo "  Causes: no network, hex.pm unreachable, or the project failed to load."
    echo "  Refusing to report this as clean."
    unreadable=1
    continue
  fi
  grand_total=$((grand_total + R_TOTAL))
  [ "$R_HIGH" -gt 0 ] && any_high=1
  # Seen ids are keyed BY LOCK (`api:EEF-...`), not bare. bandit's two HIGHs sit
  # in BOTH locks; a bare-id baseline would let an advisory recorded against api/
  # arrive in cloud/ and never read as NEW.
  echo "$R_IDS" | awk -v d="$d" 'NF {print d ":" $1}' >>"$SEEN"
  echo
done

echo "══════════════════════════════════════════════════════════════════════"
echo "VERDICT: locks=${#DIRS[@]} advisories(hex.audit)=$grand_total high_or_worse=$( [ $any_high = 1 ] && echo yes || echo no ) unreadable=$( [ $unreadable = 1 ] && echo yes || echo no )"
echo "This oracle is ADVISORY. 'Security gate' is not a required context and"
echo "this job is not on any merge path; a red here stops no merge. Which"
echo "oracle should BLOCK is owner-queue item 47 / criterion 1 of"
echo "cch-w12-bl-cve-gate-is-oracle-blind, deliberately not decided here."
echo "══════════════════════════════════════════════════════════════════════"

# UNREADABLE OUTRANKS EVERYTHING. A feed that refused to answer is not a clean
# feed and is not a baseline match either, so it exits 3 before any verdict
# below — a CANNOT READ must never be byte-identical to a zero.
if [ "$unreadable" = "1" ]; then
  rm -rf "$WORK"
  echo "CANNOT READ: at least one lock produced no advisory report. Exit 3."
  exit 3
fi

if [ -n "$BASELINE" ]; then
  if [ ! -f "$BASELINE" ]; then
    rm -rf "$WORK"
    echo "CANNOT READ: --baseline '$BASELINE' does not exist. A baseline read as"
    echo "empty would flip this ratchet's verdict wholesale; refusing to guess."
    exit 3
  fi
  echo
  echo "RATCHET against $BASELINE"
  baseline_verdict "$BASELINE" "$SEEN"
  rm -rf "$WORK"
  if [ "$B_NEW" -gt 0 ]; then
    echo "RATCHET VERDICT: $B_NEW advisory id(s) not in the recorded baseline. Exit 1."
    exit 1
  fi
  echo "RATCHET VERDICT: no unrecorded advisory. Exit 0."
  exit 0
fi

rm -rf "$WORK"
[ "$any_high" = "1" ] && exit 1
exit 0
