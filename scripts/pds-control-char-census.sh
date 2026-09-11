#!/usr/bin/env bash
#
# pds-control-char-census.sh — the RERUN COMMAND for criterion 1 of
# pds-w33-bl-census-primitives-fail-silently: does published task content carry
# raw U+0000–U+001F control characters, and can jq read the live envelopes?
#
# READ ONLY. No write verb, no publish, no patch, no mutate, no discard. The
# selftest greps this file's own source for write verbs so a later edit that
# "just fixes the two rows while it is in there" reds before it runs.
#
# WHY THIS EXISTS
# ---------------
# The row recorded, from wave 33: "jq CANNOT PARSE several live task envelopes —
# 'Invalid string: control characters from U+0000 through U+001F must be
# escaped' on 6 of the 22 draft twins. A jq-keyed census silently DROPS those
# rows and exits 0." That is the worst class of instrument fault, so the
# question deserved a standing measurement rather than a remembered anecdote.
#
# WHAT THE MEASUREMENT ACTUALLY FOUND (2026-09-11, guerrilla.barkpark.cloud)
# -------------------------------------------------------------------------
# The premise does not reproduce, and the reason matters more than the verdict.
#
#   corpus: bp doc ls task --perspective drafts --all -o json
#           87,858,221 bytes · 9,079 rows
#
#   AXIS A — raw control BYTES in the transport stream:           0
#            jq parses the whole 87 MB. `jq '.documents|length'` exits 0.
#   AXIS B — DECODED U+0000–U+001F inside string VALUES:          2, in 2 rows
#            spd-w19-desk-row-census-run
#            spd-w19-desk-chips-and-names
#            both at brief.blocks[1].content[0].value — the ENTIRE paragraph
#            text is a lone U+0001.
#
# THE TWO AXES ARE NOT THE SAME QUESTION, and conflating them is what produced
# the original report. A control character INSIDE a JSON string value is legal
# and the server escapes it correctly on the wire (as a \u0001 escape); jq reads it without
# complaint. jq's "must be escaped" error fires only on a RAW control byte in
# the serialized text — axis A — and axis A is empty. `bp task get <id> -o json |
# jq` exits 0 on both affected rows; verified individually.
#
# So there is no serialization defect to fix. What is left is an AUTHORING
# artifact upstream of the API: a brief generator wrote U+0001 as the text of
# what should have been an empty spacer paragraph, twice, in one wave's rows.
# That is out of this row's fence (internal/cli + scripts/pds-*) and is not
# worth a migration for two paragraphs — it is worth a standing detector, which
# is this file. If axis A ever becomes non-empty, that IS a server defect and
# this script's exit code says so.
#
# RERUN
#   bash scripts/pds-control-char-census.sh              # census the live ledger
#   bash scripts/pds-control-char-census.sh --selftest   # prove the detector fires
#   bash scripts/pds-control-char-census.sh --type paper # any document type
#
# EXIT CODES
#   0  clean on axis A (no raw control bytes) — axis B findings are REPORTED,
#      not failed, because a U+0001 in a string value is legal JSON
#   1  axis A non-empty: the server emitted an unparseable envelope, or the
#      selftest's planted control byte was NOT detected
#   2  the corpus could not be read at all (UNKNOWN, never "clean")
#
set -uo pipefail

TYPE="task"
PERSPECTIVE="drafts"
SELFTEST=0
CORPUS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --selftest)    SELFTEST=1; shift ;;
    --type)        TYPE="$2"; shift 2 ;;
    --perspective) PERSPECTIVE="$2"; shift 2 ;;
    --corpus)      CORPUS="$2"; shift 2 ;;
    -h|--help)     sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# The analyser. It is python3, not jq, ON PURPOSE: jq is the instrument under
# test here, and an instrument cannot be its own control. python3's json module
# with strict=False decodes raw control bytes that jq refuses, which is exactly
# the asymmetry that lets axis A be measured at all.
# ---------------------------------------------------------------------------
cat > "$WORK/analyse.py" <<'PYEOF'
import collections, json, re, sys

path = sys.argv[1]
raw = open(path, "rb").read()

# AXIS A — raw control BYTES in the serialized text. TAB/LF/CR are legal
# whitespace between tokens; every other byte below 0x20 is what jq refuses.
axis_a = collections.Counter(
    b for b in raw if b < 0x20 and b not in (0x09, 0x0a, 0x0d)
)

# AXIS B — DECODED control characters inside string VALUES. strict=False is the
# whole point: it parses a corpus jq would drop, so a broken corpus still gets
# counted instead of silently shortening the census.
try:
    doc = json.loads(raw, strict=False)
except Exception as exc:                       # pragma: no cover - corpus fault
    print("UNREADABLE %s" % exc)
    sys.exit(2)

rows = doc.get("documents", doc) if isinstance(doc, dict) else doc
if not isinstance(rows, list):
    rows = [rows]

pat = re.compile(r"[\x00-\x08\x0b-\x1f]")
hits = []

def walk(node, path):
    if isinstance(node, str):
        for m in pat.finditer(node):
            hits.append((path, "U+%04X" % ord(m.group())))
    elif isinstance(node, dict):
        for k, v in node.items():
            walk(v, path + "." + k)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, "%s[%d]" % (path, i))

for row in rows:
    rid = row.get("_id", "?") if isinstance(row, dict) else "?"
    walk(row, rid)

print("BYTES %d" % len(raw))
print("ROWS %d" % len(rows))
print("AXIS_A %d" % sum(axis_a.values()))
for b, n in sorted(axis_a.items()):
    print("AXIS_A_BYTE 0x%02x %d" % (b, n))
print("AXIS_B %d" % len(hits))
seen = set()
for p, cp in hits:
    seen.add(p.split(".")[0])
    print("AXIS_B_HIT %s %s" % (cp, p))
print("AXIS_B_ROWS %d" % len(seen))
PYEOF

# ---------------------------------------------------------------------------
# SELFTEST — a planted control byte, and a CONTROL that must stay clean.
#
# Two arms, because one proves nothing. A detector that always says DIRTY and a
# detector that always says CLEAN each pass a single-arm selftest. The planted
# corpus is a RAW 0x01 byte written inside a JSON string (the thing jq refuses)
# plus the escaped form (the thing jq accepts) — so the run also demonstrates,
# on the same file, that the two axes are genuinely different questions.
# ---------------------------------------------------------------------------
if [ "$SELFTEST" = "1" ]; then
  rc=0

  printf '{"documents":[{"_id":"clean-row","brief":"nothing to see"}]}' > "$WORK/clean.json"
  CLEAN_OUT="$("$(command -v python3)" "$WORK/analyse.py" "$WORK/clean.json")"
  CLEAN_A="$(printf '%s\n' "$CLEAN_OUT" | awk '$1=="AXIS_A"{print $2}')"
  CLEAN_B="$(printf '%s\n' "$CLEAN_OUT" | awk '$1=="AXIS_B"{print $2}')"
  if [ "$CLEAN_A" = "0" ] && [ "$CLEAN_B" = "0" ]; then
    echo "selftest CONTROL  ok   — a clean corpus reads 0 on both axes"
  else
    echo "selftest CONTROL  FAIL — clean corpus read axis_a=$CLEAN_A axis_b=$CLEAN_B, want 0/0"
    rc=1
  fi

  # printf '\001' writes the RAW byte. This file is deliberately NOT valid
  # strict JSON — it is the shape jq refuses and the shape axis A exists to see.
  printf '{"documents":[{"_id":"planted-raw","brief":"before\001after","escaped":"before\\u0001after"}]}' > "$WORK/dirty.json"
  DIRTY_OUT="$("$(command -v python3)" "$WORK/analyse.py" "$WORK/dirty.json")"
  DIRTY_A="$(printf '%s\n' "$DIRTY_OUT" | awk '$1=="AXIS_A"{print $2}')"
  DIRTY_B="$(printf '%s\n' "$DIRTY_OUT" | awk '$1=="AXIS_B"{print $2}')"
  if [ "${DIRTY_A:-0}" -ge 1 ]; then
    echo "selftest PLANTED  ok   — a raw 0x01 byte is seen on axis A (axis_a=$DIRTY_A)"
  else
    echo "selftest PLANTED  FAIL — a raw 0x01 byte was NOT seen (axis_a=${DIRTY_A:-unset})"
    rc=1
  fi
  if [ "${DIRTY_B:-0}" -ge 2 ]; then
    echo "selftest DECODED  ok   — both the raw and the \\u0001 form are seen on axis B (axis_b=$DIRTY_B)"
  else
    echo "selftest DECODED  FAIL — axis B saw ${DIRTY_B:-unset}, want >= 2"
    rc=1
  fi

  # THE ASYMMETRY, demonstrated rather than asserted: jq must REFUSE the planted
  # corpus and ACCEPT the clean one. This is the claim the whole script rests on.
  if command -v jq >/dev/null 2>&1; then
    if jq -e . "$WORK/dirty.json" >/dev/null 2>&1; then
      echo "selftest JQ       FAIL — jq accepted a raw control byte; the premise of axis A is wrong on this jq"
      rc=1
    else
      echo "selftest JQ       ok   — jq refuses the planted raw byte"
    fi
    if jq -e . "$WORK/clean.json" >/dev/null 2>&1; then
      echo "selftest JQ-CTRL  ok   — jq accepts the clean corpus"
    else
      echo "selftest JQ-CTRL  FAIL — jq refused a clean corpus; this jq is not the instrument described"
      rc=1
    fi
  else
    echo "selftest JQ       SKIP — jq is not installed, the asymmetry arm was not run"
  fi

  # READ-ONLY ARM. The header promises this file contains no write verb; an
  # unverified promise is the exact species of claim this row exists about. The
  # grep excludes its own pattern line and the comment lines that name the verbs,
  # so only a real invocation matches. The CONTROL is that the same grep DOES
  # find the read verb `bp doc ls` — without it, an empty result would prove the
  # grep is broken rather than the file clean.
  WRITE_VERBS='bp (doc )?(publish|patch|mutate|discard-draft|delete|create)|bp task (close|stamp|claim|create|pulse)'
  if grep -nE "$WRITE_VERBS" "$0" | grep -v '^ *[0-9]*: *#' | grep -v 'WRITE_VERBS=' | grep -q .; then
    echo "selftest READONLY FAIL — a write verb appears in this file:"
    grep -nE "$WRITE_VERBS" "$0" | grep -v '^ *[0-9]*: *#' | grep -v 'WRITE_VERBS='
    rc=1
  else
    echo "selftest READONLY ok   — no write verb in this file"
  fi
  if grep -q 'bp doc ls' "$0"; then
    echo "selftest RO-CTRL  ok   — the grep control found the read verb it must see"
  else
    echo "selftest RO-CTRL  FAIL — the control read verb was not found; the READONLY arm measured nothing"
    rc=1
  fi

  echo "selftest rc=$rc"
  exit "$rc"
fi

# ---------------------------------------------------------------------------
# THE CENSUS
# ---------------------------------------------------------------------------
if [ -n "$CORPUS" ]; then
  cp "$CORPUS" "$WORK/corpus.json" || { echo "UNKNOWN: --corpus unreadable" >&2; exit 2; }
else
  if ! command -v bp >/dev/null 2>&1; then
    echo "UNKNOWN: bp is not on PATH — the corpus was never read (this is not 'clean')" >&2
    exit 2
  fi
  echo "reading: bp doc ls $TYPE --perspective $PERSPECTIVE --all -o json"
  if ! env -u BARKPARK_TOKEN bp doc ls "$TYPE" --perspective "$PERSPECTIVE" --all -o json > "$WORK/corpus.json" 2>"$WORK/corpus.err"; then
    echo "UNKNOWN: the corpus read failed — $(head -c 400 "$WORK/corpus.err")" >&2
    exit 2
  fi
fi

OUT="$(python3 "$WORK/analyse.py" "$WORK/corpus.json")" || { echo "UNKNOWN: the corpus could not be analysed" >&2; exit 2; }

BYTES="$(printf '%s\n' "$OUT" | awk '$1=="BYTES"{print $2}')"
ROWS="$(printf '%s\n' "$OUT" | awk '$1=="ROWS"{print $2}')"
A="$(printf '%s\n' "$OUT" | awk '$1=="AXIS_A"{print $2}')"
B="$(printf '%s\n' "$OUT" | awk '$1=="AXIS_B"{print $2}')"
BROWS="$(printf '%s\n' "$OUT" | awk '$1=="AXIS_B_ROWS"{print $2}')"

echo
echo "corpus: type=$TYPE perspective=$PERSPECTIVE  ${BYTES} bytes  ${ROWS} rows"
echo
echo "AXIS A — raw control bytes in the transport (what jq refuses): $A"
printf '%s\n' "$OUT" | awk '$1=="AXIS_A_BYTE"{printf "         %s x%s\n", $2, $3}'
echo "AXIS B — decoded U+0000-U+001F inside string values:           $B  (in ${BROWS:-0} rows)"
printf '%s\n' "$OUT" | awk '$1=="AXIS_B_HIT"{printf "         %s at %s\n", $2, $3}'
echo

# The jq CONTROL, run against the real corpus rather than asserted about it: if
# jq reads this file, no jq-keyed census over it was ever silently shortened.
if command -v jq >/dev/null 2>&1; then
  if jq -e 'if type=="object" then (.documents // .) else . end | length' "$WORK/corpus.json" >/dev/null 2>&1; then
    echo "jq control: jq PARSES this corpus — a jq-keyed census over it drops nothing"
  else
    echo "jq control: jq REFUSES this corpus — any jq-keyed census over it is short"
  fi
fi

if [ "${A:-0}" -gt 0 ]; then
  echo
  echo "VERDICT: axis A is NON-EMPTY. The server emitted raw control bytes; a jq-keyed"
  echo "         census over this corpus silently drops rows. This is a server defect."
  exit 1
fi

echo
echo "VERDICT: axis A clean — no raw control byte reached the wire, jq reads the corpus."
if [ "${B:-0}" -gt 0 ]; then
  echo "         Axis B is non-zero but NOT a failure: a control character inside a JSON"
  echo "         string value is legal and correctly escaped on the wire. The rows above"
  echo "         are an AUTHORING artifact (a generator wrote a control char as text)."
fi
exit 0
