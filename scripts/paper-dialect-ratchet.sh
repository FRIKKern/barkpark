#!/usr/bin/env bash
# paper-dialect-ratchet.sh — the shrink-only count ratchet over the PAPER BLOCK
# DIALECTS that publish 200 and render NOTHING (task pe-w2-bl-hollow-corpus-repair).
#
# THE DEFECT CLASS, precisely. PortableDoc's canonical inline text leaf is
# `{"type":"text","value":…}`; `render/inline.ex` reads ONLY `value` and has no
# `"text"` fallback. A leaf keyed `text` (the TipTap dialect) therefore renders
# as the empty string, and a paragraph whose only leaf carries it VANISHES —
# behind an HTTP 200. The sibling shape is a `notes`/`cards` item (or a
# `pipeline` node) that arrives as a BARE STRING: every reader addresses those
# item FIELDS through `get/2`, which is nil on a binary, so the row renders
# EMPTY — again behind a 200. Both are rescued at the ONE write chokepoint,
# `Barkpark.Content.Papers.BlockOps.normalize_render_shapes/1` (#11616), so any
# payload that reaches persistence THROUGH that chokepoint is already clean.
# What the chokepoint cannot reach is a payload committed to this repo as a
# fixture, a seed, or a golden file — which is exactly what this gate measures.
#
# WHY A COUNT AND NOT A BAN. Frozen pre-repair specimens are legitimate: the
# paper-excellence rig deliberately keeps `heggemsnes-act.json` as it stood
# BEFORE the 2026-09-10 repair, because a normalizer test needs a real dirty
# input. A ban would force that specimen to be laundered; a shrink-only count
# lets it stand while making any NEW dirty payload a visible, reviewable, second
# -file bump. Modelled on scripts/silencer-growth-ratchet.sh and
# scripts/go-format-drift-ceiling.sh, which run the same shape.
#
# THE NON-VACUITY FLOOR. Each source also pins `min_value_keyed`. A walker that
# stopped matching — a renamed key, a corpus moved out from under the glob, a
# parser that silently returns {} — would report `text_keyed 0` and pass. The
# floor makes that impossible: if the CANONICAL leaves fall below the pinned
# number, the gate REFUSES (2) instead of greening. A zero that is not
# accompanied by a large positive control is not a measurement.
#
# REFUSAL, NOT A GREEN. If this gate cannot MEASURE — a named source directory
# is gone, the baseline is missing, a baseline row is unparsable, the baseline
# and the source table disagree, a JSON file will not parse, python3 is absent —
# it exits 2 as HARNESS-UNAVAILABLE. A deleted corpus and a clean corpus are
# indistinguishable in a count of zero.
#
# THE LIVE CORPUS. The population this class was FILED against is the live
# guerrilla corpus, which CI cannot reach (it needs a token). Sweep it on demand:
#
#   env -u BARKPARK_TOKEN bp doc query paper --all --fields _id,blocks -o json \
#     | grep '^{' > /tmp/corpus.json
#   bash scripts/paper-dialect-ratchet.sh --source /tmp/corpus.json --expect-zero
#
# `--expect-zero` is the live contract: the chokepoint is live in prod, so the
# served corpus must hold ZERO of either shape, and any nonzero is a bypass.
# Measured 2026-09-10 over 1048 published papers: text_keyed 0, malformed_items
# 0, value_keyed 177542 (tooling/grip/ledger/pe-w2-hollow-corpus-repair-2026-09-10.md).
#
# BLAST RADIUS, said plainly. Wired as a step in .github/workflows/doc-gates.yml,
# whose job publishes the "Doc budgets + anchors" context. That context carries an
# explicit S4 exclusion row in .github/required-checks.json, so it is NOT in the
# required set: a RED here is VISIBLE on the pull request and CANNOT stop a merge.
#
# USAGE:
#   bash scripts/paper-dialect-ratchet.sh                       # enforce the ratchet
#   bash scripts/paper-dialect-ratchet.sh --source <file|dir> [--expect-zero]
#   bash scripts/paper-dialect-ratchet.sh --selftest            # prove it can fail
#
# EXIT CODES:  0 = no growth   1 = a count GREW   2 = cannot measure (refusal)
#
# Overrides (used only by --selftest to drive throwaway trees):
#   PDR_ROOT      tree to measure     (default: the git toplevel)
#   PDR_BASELINE  baseline path       (default: $ROOT/scripts/.paper-dialect-baseline)
#   PDR_SOURCES   newline table       (default: the built-in table below)
#
# bash 3.2 compatible (macOS ships 3.2): no mapfile, no associative arrays.

set -uo pipefail

# ── the source table: name|path ─────────────────────────────────────────────
# Every in-repo tree that holds PortableDoc block payloads as committed JSON.
DEFAULT_SOURCES='rig-fixtures|tooling/paper-excellence/rig/fixtures
twin|tooling/paper-excellence/twin
go-testdata|cmd/barkpark/testdata'

# ── the walker ───────────────────────────────────────────────────────────────
# Emits exactly three integers on one line: text_keyed malformed_items value_keyed.
# Any parse failure is fatal (exit 2 from python3) — never a silent 0.
measure() { # measure PATH -> "tk mi vk" on stdout, or reason on stderr + rc 2
  local target="$1"
  if [ ! -e "$target" ]; then
    echo "missing source: $target" >&2
    return 2
  fi
  python3 - "$target" <<'PYEOF'
import json, os, sys

target = sys.argv[1]

if os.path.isdir(target):
    files = sorted(
        os.path.join(target, n) for n in os.listdir(target) if n.endswith(".json")
    )
    if not files:
        sys.stderr.write("no *.json under %s\n" % target)
        sys.exit(2)
else:
    files = [target]

tk = mi = vk = 0


def walk(node):
    global tk, mi, vk
    if isinstance(node, dict):
        if node.get("type") == "text":
            # A leaf carrying BOTH keys is already canonical (the normalizer
            # leaves it byte-identical) — only a text-ONLY leaf is the defect.
            if "value" in node:
                vk += 1
            elif isinstance(node.get("text"), str):
                tk += 1
        if node.get("type") in ("notes", "cards") and isinstance(node.get("items"), list):
            mi += sum(1 for i in node["items"] if not isinstance(i, dict))
        if node.get("type") == "pipeline" and isinstance(node.get("nodes"), list):
            mi += sum(1 for i in node["nodes"] if not isinstance(i, dict))
        for v in node.values():
            walk(v)
    elif isinstance(node, list):
        for v in node:
            walk(v)


for f in files:
    try:
        with open(f, encoding="utf-8") as fh:
            walk(json.load(fh))
    except Exception as exc:  # a file we cannot read is a HOLE, not a zero
        sys.stderr.write("unreadable JSON %s: %s\n" % (f, exc))
        sys.exit(2)

print("%d %d %d" % (tk, mi, vk))
PYEOF
}

# ── the ratchet ──────────────────────────────────────────────────────────────
# run_ratchet ROOT BASELINE SOURCES -> 0 ok, 1 growth, 2 refusal
run_ratchet() {
  local root="$1" baseline="$2" sources="$3"

  if ! command -v python3 >/dev/null 2>&1; then
    echo "REFUSE: python3 not on PATH — this gate cannot measure. (exit 2 = harness unavailable, NOT a pass.)"
    return 2
  fi

  if [ ! -f "$baseline" ]; then
    echo "REFUSE: baseline not found at $baseline — a guard that cannot compare must not report clean."
    echo "        (exit 2 = harness unavailable, NOT a pass.)"
    return 2
  fi

  local rows
  rows="$(grep -vE '^[[:space:]]*(#|$)' "$baseline" | awk '{print $1" "$2" "$3" "$4}')"

  local rc=0 grew=0 shrank=0 checked=0
  local line name path want out err tk mi vk want_tk want_mi want_vk

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="${line%%|*}"
    path="${line#*|}"

    want="$(printf '%s\n' "$rows" | awk -v n="$name" '$1==n {print $2" "$3" "$4; found=1} END{ if(!found) print "" }')"
    if [ -z "$(printf '%s' "$want" | tr -d ' ')" ]; then
      echo "REFUSE: source '$name' has no row in the baseline ($baseline)."
      echo "        Add a line '$name <text_keyed> <malformed_items> <min_value_keyed>' —"
      echo "        an unpinned source is UNMEASURED, not clean."
      return 2
    fi
    want_tk="$(printf '%s' "$want" | awk '{print $1}')"
    want_mi="$(printf '%s' "$want" | awk '{print $2}')"
    want_vk="$(printf '%s' "$want" | awk '{print $3}')"
    case "$want_tk$want_mi$want_vk" in
      ''|*[!0-9]*)
        echo "REFUSE: baseline row for '$name' is not three non-negative integers: '$want'"
        return 2
        ;;
    esac

    err="$(measure "$root/$path" 2>&1 >/dev/null)"
    out="$(measure "$root/$path" 2>/dev/null)"
    if [ -n "$err" ] || [ -z "$out" ]; then
      echo "REFUSE: cannot measure source '$name' ($path) — ${err:-no counts produced}."
      echo "        A named corpus that is not there is a HOLE, not a zero. Exit 2."
      return 2
    fi
    tk="$(printf '%s' "$out" | awk '{print $1}')"
    mi="$(printf '%s' "$out" | awk '{print $2}')"
    vk="$(printf '%s' "$out" | awk '{print $3}')"

    checked=$(( checked + 1 ))

    # NON-VACUITY FIRST. A zero defect count only means something when the
    # canonical shape is still being found in quantity.
    if [ "$vk" -lt "$want_vk" ]; then
      echo "REFUSE: non-vacuity floor breached — $name: canonical value-keyed leaves"
      echo "        fell to $vk, below the pinned floor of $want_vk."
      echo "        Either the corpus shrank or the walker stopped matching. A zero"
      echo "        defect count under a broken walker is not a green. Exit 2."
      return 2
    fi

    if [ "$tk" -gt "$want_tk" ]; then
      echo "FAIL: text-keyed inline leaves GREW — $name: $want_tk -> $tk (+$(( tk - want_tk ))) [$path]"
      grew=1; rc=1
    elif [ "$tk" -lt "$want_tk" ]; then
      echo "note: text-keyed leaves shrank — $name: $want_tk -> $tk. Allowed; lower the baseline when convenient."
      shrank=1
    fi

    if [ "$mi" -gt "$want_mi" ]; then
      echo "FAIL: malformed widget items GREW — $name: $want_mi -> $mi (+$(( mi - want_mi ))) [$path]"
      grew=1; rc=1
    elif [ "$mi" -lt "$want_mi" ]; then
      echo "note: malformed items shrank — $name: $want_mi -> $mi. Allowed; lower the baseline when convenient."
      shrank=1
    fi
  done <<EOF
$sources
EOF

  if [ "$checked" -eq 0 ]; then
    echo "REFUSE: measured 0 sources — an empty table cannot produce a meaningful green."
    return 2
  fi

  # Baseline rows naming nothing in the table: a source was retired but its row
  # survives, so the row we THINK is guarding something guards air.
  local rname
  while IFS= read -r rname; do
    [ -n "$rname" ] || continue
    if ! printf '%s\n' "$sources" | grep -q "^${rname}|"; then
      echo "REFUSE: baseline names '$rname', which this gate does not measure — a stale row guards nothing."
      return 2
    fi
  done <<EOF
$(printf '%s\n' "$rows" | awk '{print $1}')
EOF

  if [ "$grew" -eq 1 ]; then
    echo ""
    echo "A committed paper payload gained a dialect that renders NOTHING behind a 200."
    echo "  1. Fix the payload: inline leaves are {\"type\":\"text\",\"value\":…}; notes/cards"
    echo "     items and pipeline nodes are MAPS, never bare strings."
    echo "  2. Only if the dirty payload is a DELIBERATE normalizer specimen, raise the"
    echo "     matching number in $baseline in the SAME commit and say why in the PR body."
    return 1
  fi

  if [ "$shrank" -eq 1 ]; then
    echo "OK: $checked source(s) measured; no dialect count grew (some shrank — see notes)."
  else
    echo "OK: $checked source(s) measured; no dialect count grew."
  fi
  return 0
}

# ── one-shot mode: --source <path> [--expect-zero] ───────────────────────────
run_source() {
  local target="$1" expect_zero="$2" out err tk mi vk
  if ! command -v python3 >/dev/null 2>&1; then
    echo "REFUSE: python3 not on PATH — this gate cannot measure."
    return 2
  fi
  err="$(measure "$target" 2>&1 >/dev/null)"
  out="$(measure "$target" 2>/dev/null)"
  if [ -n "$err" ] || [ -z "$out" ]; then
    echo "REFUSE: cannot measure $target — ${err:-no counts produced}."
    return 2
  fi
  tk="$(printf '%s' "$out" | awk '{print $1}')"
  mi="$(printf '%s' "$out" | awk '{print $2}')"
  vk="$(printf '%s' "$out" | awk '{print $3}')"
  echo "$target: text_keyed $tk | malformed_items $mi | value_keyed $vk"
  if [ "$vk" -eq 0 ]; then
    echo "REFUSE: zero canonical value-keyed leaves found — the walker matched nothing."
    echo "        A zero defect count with no positive control is not a measurement. Exit 2."
    return 2
  fi
  if [ "$expect_zero" = "1" ] && { [ "$tk" -gt 0 ] || [ "$mi" -gt 0 ]; }; then
    echo "FAIL: --expect-zero, but the corpus carries $tk text-keyed leaf/leaves and $mi malformed item(s)."
    echo "      The #11616 write chokepoint is live, so a nonzero here is a BYPASS of it."
    return 1
  fi
  echo "OK."
  return 0
}

# ── self-test (tripwire) ─────────────────────────────────────────────────────
# Every arm builds a throwaway tree and re-invokes the SHIPPING functions above.
# It plants nothing in the real tree.
selftest() {
  local tmp; tmp="$(mktemp -d)"
  local fails=0

  _mk() { # _mk DIR — a clean minimal corpus: 1 source dir, 4 canonical leaves
    local d="$1"
    mkdir -p "$d/corpus"
    cat > "$d/corpus/a.json" <<'JSON'
{"_id":"a","blocks":[
 {"id":"p1","type":"paragraph","content":[{"type":"text","value":"one"},{"type":"text","value":"two"}]},
 {"id":"n1","type":"notes","items":[{"text":"note one"},{"text":"note two"}]},
 {"id":"pl","type":"pipeline","nodes":[{"title":"stage"}]},
 {"id":"s1","type":"section","blocks":[{"id":"p2","type":"paragraph","content":[{"type":"text","value":"three"},{"type":"text","value":"four"}]}]}
]}
JSON
  }
  local T='c|corpus'
  _baseline() { printf '# name text_keyed malformed_items min_value_keyed\nc %s %s %s\n' "$1" "$2" "$3"; }

  _arm() { # _arm LABEL EXPECTED_RC ROOT BASELINE SOURCES [GREP]
    local label="$1" want_rc="$2" root="$3" bl="$4" src="$5" pat="${6:-}"
    local out rc
    out="$(run_ratchet "$root" "$bl" "$src" 2>&1)"; rc=$?
    if [ "$rc" -ne "$want_rc" ]; then
      echo "SELFTEST FAIL ($label): expected rc=$want_rc, got rc=$rc"
      printf '%s\n' "$out" | sed 's/^/      | /'
      fails=1; return
    fi
    if [ -n "$pat" ] && ! printf '%s' "$out" | grep -q -- "$pat"; then
      echo "SELFTEST FAIL ($label): rc=$rc correct but output did not mention '$pat'"
      printf '%s\n' "$out" | sed 's/^/      | /'
      fails=1; return
    fi
    echo "SELFTEST ok ($label)"
  }

  # A — a baseline that matches reality passes.
  local A="$tmp/A"; _mk "$A"; _baseline 0 0 4 > "$A/bl"
  _arm "A: clean corpus at baseline passes" 0 "$A" "$A/bl" "$T" "no dialect count grew"

  # B — THE MUTATION: plant ONE text-keyed leaf. This is the defect the gate
  # exists for, and it must red naming the source and the delta.
  local B="$tmp/B"; _mk "$B"; _baseline 0 0 4 > "$B/bl"
  python3 - "$B/corpus/a.json" <<'JSON'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["blocks"].append({"id":"px","type":"paragraph","content":[{"type":"text","text":"PLANTED"}]})
json.dump(d,open(p,"w"))
JSON
  _arm "B: planted text-keyed leaf REDS" 1 "$B" "$B/bl" "$T" "text-keyed inline leaves GREW — c: 0 -> 1"

  # B2 — REMOVE the planted leaf: the same tree goes green again. Without this
  # arm, B proves only that something reds, not that THIS leaf is what red it.
  python3 - "$B/corpus/a.json" <<'JSON'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["blocks"]=[b for b in d["blocks"] if b.get("id")!="px"]
json.dump(d,open(p,"w"))
JSON
  _arm "B2: removing the planted leaf goes GREEN again" 0 "$B" "$B/bl" "$T" "no dialect count grew"

  # C — the sibling shape: a BARE STRING notes item.
  local C="$tmp/C"; _mk "$C"; _baseline 0 0 4 > "$C/bl"
  python3 - "$C/corpus/a.json" <<'JSON'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
for b in d["blocks"]:
    if b.get("id")=="n1": b["items"].append("a bare string that renders EMPTY")
json.dump(d,open(p,"w"))
JSON
  _arm "C: planted bare-string notes item REDS" 1 "$C" "$C/bl" "$T" "malformed widget items GREW — c: 0 -> 1"

  # C2 — a bare-string PIPELINE node counts on the same metric (different key).
  local C2="$tmp/C2"; _mk "$C2"; _baseline 0 0 4 > "$C2/bl"
  python3 - "$C2/corpus/a.json" <<'JSON'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
for b in d["blocks"]:
    if b.get("id")=="pl": b["nodes"].append("bare stage")
json.dump(d,open(p,"w"))
JSON
  _arm "C2: planted bare-string pipeline node REDS" 1 "$C2" "$C2/bl" "$T" "malformed widget items GREW"

  # D — a NESTED text-keyed leaf (inside section.blocks) reds too. The 2026-08
  # survey's own miss was a two-key walk that never descended.
  local D="$tmp/D"; _mk "$D"; _baseline 0 0 4 > "$D/bl"
  python3 - "$D/corpus/a.json" <<'JSON'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
for b in d["blocks"]:
    if b.get("id")=="s1":
        b["blocks"][0]["content"].append({"type":"text","text":"NESTED PLANT"})
json.dump(d,open(p,"w"))
JSON
  _arm "D: NESTED planted leaf REDS (the walk descends)" 1 "$D" "$D/bl" "$T" "0 -> 1"

  # E — a leaf carrying BOTH keys is canonical, not a defect: it must NOT red.
  local E="$tmp/E"; _mk "$E"; _baseline 0 0 4 > "$E/bl"
  python3 - "$E/corpus/a.json" <<'JSON'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["blocks"].append({"id":"pb","type":"paragraph","content":[{"type":"text","value":"v","text":"v"}]})
json.dump(d,open(p,"w"))
JSON
  _arm "E: both-keys leaf is canonical, stays GREEN" 0 "$E" "$E/bl" "$T" "no dialect count grew"

  # F — a SHRINK must NOT red. Paying a specimen down has to stay free.
  local F="$tmp/F"; _mk "$F"; _baseline 3 2 4 > "$F/bl"
  _arm "F: shrink passes with a note" 0 "$F" "$F/bl" "$T" "shrank"

  # G — REFUSAL: the non-vacuity floor. Empty the corpus of canonical leaves and
  # the defect counts read 0 — which without the floor sails through as a shrink.
  local G="$tmp/G"; _mk "$G"; _baseline 0 0 4 > "$G/bl"
  printf '{"_id":"a","blocks":[]}\n' > "$G/corpus/a.json"
  _arm "G: vacuous corpus REFUSES (2), never greens" 2 "$G" "$G/bl" "$T" "non-vacuity floor breached"

  # H — REFUSAL: the source directory is GONE.
  local H="$tmp/H"; _mk "$H"; _baseline 0 0 4 > "$H/bl"; rm -rf "$H/corpus"
  _arm "H: missing source REFUSES (2)" 2 "$H" "$H/bl" "$T" "missing source"

  # I — REFUSAL: unparsable JSON is a hole, not a zero.
  local I="$tmp/I"; _mk "$I"; _baseline 0 0 4 > "$I/bl"; printf 'not json' > "$I/corpus/a.json"
  _arm "I: unparsable JSON REFUSES (2)" 2 "$I" "$I/bl" "$T" "unreadable JSON"

  # J — REFUSAL: no baseline at all.
  local J="$tmp/J"; _mk "$J"
  _arm "J: absent baseline REFUSES (2)" 2 "$J" "$J/bl" "$T" "baseline not found"

  # K — REFUSAL: a source in the table with no baseline row.
  local K="$tmp/K"; _mk "$K"; printf '# hdr\nother 0 0 1\n' > "$K/bl"
  _arm "K: unpinned source REFUSES (2)" 2 "$K" "$K/bl" "$T" "no row in the baseline"

  # L — REFUSAL: a baseline row naming nothing measured.
  local L="$tmp/L"; _mk "$L"; { _baseline 0 0 4; printf 'ghost 0 0 0\n'; } > "$L/bl"
  _arm "L: stale baseline row REFUSES (2)" 2 "$L" "$L/bl" "$T" "guards nothing"

  # M — REFUSAL: a non-integer baseline value.
  local M="$tmp/M"; _mk "$M"; printf 'c zero 0 4\n' > "$M/bl"
  _arm "M: non-integer baseline REFUSES (2)" 2 "$M" "$M/bl" "$T" "three non-negative integers"

  # N — REFUSAL: an empty source table is a vacuous green otherwise.
  local N="$tmp/N"; _mk "$N"; _baseline 0 0 4 > "$N/bl"
  _arm "N: empty table REFUSES (2)" 2 "$N" "$N/bl" "" "measured 0 sources"

  # O — NON-VACUITY of arm A: a floor ONE ABOVE reality refuses, proving A's
  # green is a comparison and not an empty loop.
  local O="$tmp/O"; _mk "$O"; _baseline 0 0 5 > "$O/bl"
  _arm "O: floor above reality REFUSES (arm A is non-vacuous)" 2 "$O" "$O/bl" "$T" "fell to 4"

  # P — one-shot --source --expect-zero: green on a clean corpus, red on a dirty
  # one. This is the arm that runs against the LIVE guerrilla dump.
  local P="$tmp/P"; _mk "$P"
  local out rc
  out="$(run_source "$P/corpus" 1 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'text_keyed 0'; then
    echo "SELFTEST ok (P: --expect-zero green on a clean corpus)"
  else
    echo "SELFTEST FAIL (P): rc=$rc"; printf '%s\n' "$out" | sed 's/^/      | /'; fails=1
  fi
  python3 - "$P/corpus/a.json" <<'JSON'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["blocks"].append({"id":"px","type":"paragraph","content":[{"type":"text","text":"PLANTED"}]})
json.dump(d,open(p,"w"))
JSON
  out="$(run_source "$P/corpus" 1 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'BYPASS'; then
    echo "SELFTEST ok (Q: --expect-zero reds on a dirty corpus)"
  else
    echo "SELFTEST FAIL (Q): rc=$rc"; printf '%s\n' "$out" | sed 's/^/      | /'; fails=1
  fi

  rm -rf "$tmp"
  if [ "$fails" -ne 0 ]; then echo "SELFTEST: FAILURES ABOVE"; return 1; fi
  echo "SELFTEST: 18 arms passed — the ratchet REDS on a planted text-keyed leaf"
  echo "          (top-level and nested) and on a planted bare-string notes item or"
  echo "          pipeline node, goes GREEN again when the plant is removed, stays"
  echo "          green on a shrink and on a both-keys leaf, and REFUSES (2) rather"
  echo "          than greening whenever it cannot measure."
  return 0
}

# ── entry ────────────────────────────────────────────────────────────────────
MODE=enforce
SRC=""
EXPECT_ZERO=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --selftest) MODE=selftest; shift ;;
    --source) SRC="${2:-}"; MODE=source; shift 2 ;;
    --expect-zero) EXPECT_ZERO=1; shift ;;
    *)
      # Refuse an argument this gate does not understand: a swallowed flag would
      # run the ordinary check and report green, fabricating its own proof.
      echo "paper-dialect-ratchet: unknown argument '$1'" >&2
      echo "  usage: paper-dialect-ratchet.sh [--selftest | --source <file|dir> [--expect-zero]]" >&2
      exit 2
      ;;
  esac
done

if [ "$MODE" = "selftest" ]; then
  selftest
  exit $?
fi

if [ "$MODE" = "source" ]; then
  if [ -z "$SRC" ]; then
    echo "paper-dialect-ratchet: --source needs a path" >&2
    exit 2
  fi
  run_source "$SRC" "$EXPECT_ZERO"
  exit $?
fi

ROOT="${PDR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
BASELINE="${PDR_BASELINE:-$ROOT/scripts/.paper-dialect-baseline}"
SOURCES="${PDR_SOURCES:-$DEFAULT_SOURCES}"
run_ratchet "$ROOT" "$BASELINE" "$SOURCES"
exit $?
