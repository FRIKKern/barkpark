#!/usr/bin/env bash
# Charter-corpus marker hygiene. Enforces docs/decisions/0008-charter-corpus-marker-hygiene.md.
#
# The ruling is scrub-forward + one redaction, NOT a blanket rewrite. This guard
# is therefore TWO arms with different shapes, because the two halves of the
# ruling have different baselines:
#
#   ARM A — zero baseline, WHOLE TRACKED TREE.
#     The gyldendal.no address was redacted out of all 4 files that held it, so
#     the repo baseline for that marker is ZERO. A zero baseline needs no
#     exclusion list: any occurrence anywhere is new, and reds. This is the
#     redact-worst half, and it is the only marker that can be enforced this way.
#
#   ARM B — scrub-forward on NEW charters only.
#     The other five markers exist in ~342 tracked files today; banning them
#     outright would red on the corpus the ruling deliberately declined to
#     rewrite. So ARM B bans them in charter files that DID NOT EXIST at the
#     baseline commit. The grandfathered set is computed at runtime from
#     `git ls-tree $BASELINE` — a PREDICATE over a path set, never a
#     hand-maintained file list, so it cannot drift behind the corpus.
#
#     KNOWN, DELIBERATE EDGE: the predicate is PATH identity, not content
#     lineage, so RENAMING a grandfathered charter reds it — the new path was
#     not in the baseline tree. Rename detection via `git log --follow` is
#     heuristic and would let a rename+edit launder a marker in, so the noisier
#     direction is the safe one. The red names the file and says what to do.
#
# DELIBERATE EXCLUSIONS, stated here rather than left silent (ruling §"The cost"):
#   tooling/grip/ledger/**      append-only evidence commons; a dated row must
#                               quote what it observed. Rewriting one falsifies a
#                               past measurement. (Same tree docs-anchors-check.sh
#                               prunes structurally, for the same stated reason.)
#   scripts/measurements/**     captured runs — evidence, same class as above.
#   .omx/**, .tmp-bp89/**       nested-checkout scratch, not authored content.
#   pre-baseline .claude/workflows/*.md   the existing charters: append-only
#                               ruling logs whose D-/GR- rows quote measurements
#                               taken ON the named box.
# ARM A overrides every one of these: a zero-baseline marker is banned in the
# evidence trees too, because nothing there carries it any more.
#
# Markers are written as PATTERNS, not as the literals they catch — the email
# arms match any local-part on the two domains (so a new address on the same
# domain also reds), and the host arms match the /24 each box sits in (so a
# sibling host reds too). That is both broader coverage and the reason this file
# does not itself re-publish an address or a host.

# INTERPRETER GUARD — this file uses process substitution, which a POSIX-mode
# bash cannot parse. `sh scripts/charter-corpus-hygiene-check.sh` would run everything above that line and
# then die with the status of the LAST COMPLETED command — a vacuous green from a
# gate that compared NOTHING. Refuse instead, before any check runs. The guard must
# stay POSIX-parseable and must stay FIRST: anything it sits below is code a
# POSIX-mode shell has already run. Enforced by scripts/posix-vacuous-green-census.sh.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "charter-corpus-hygiene-check.sh: needs bash (this gate uses process substitution); run: bash scripts/charter-corpus-hygiene-check.sh${1:+ $1}" >&2
  exit 2
fi
case ":${SHELLOPTS:-}:" in
  *:posix:*)
    echo "charter-corpus-hygiene-check.sh: bash is in POSIX mode (invoked as \`sh\`?), which cannot parse this gate's process substitution; run: bash scripts/charter-corpus-hygiene-check.sh${1:+ $1}" >&2
    exit 2
    ;;
esac

set -uo pipefail

SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# --- --selftest ---------------------------------------------------------------
# Distrust vacuous green. Both arms print `ok:` when they find nothing, and a
# scanner that has gone BLIND prints the same `ok:`. Each case below builds a
# throwaway 2-commit repo, plants exactly ONE violation, and re-invokes THIS
# script against it via CHARTER_HYGIENE_ROOT/_BASELINE — so the assertions drive
# the shipping gate, not a copy of it. It plants nothing in this repo.
if [ "${1:-}" = "--selftest" ]; then
  st_fail=0
  # Fixture addresses use a NON-REAL final octet in each real /24: the arms are
  # /24 predicates, so these exercise the same branch without this guard
  # itself republishing a host address the ruling is about.
  st_case() { # $1 expected rc, $2 label, $3 shell body run inside the fixture
    local want="$1" label="$2" body="$3" dir rc out
    dir=$(mktemp -d)
    (
      cd "$dir" || exit 2
      git init -q . && git config user.email t@t.invalid && git config user.name t
      mkdir -p .claude/workflows tooling/grip/ledger
      # a GRANDFATHERED charter that legitimately carries a forward marker
      printf 'ssh root@89.167.28.7 -i ~/.ssh/barkpark_indx\n' > .claude/workflows/old-charter.md
      printf 'measured on 157.180.90.7\n' > tooling/grip/ledger/row.md
      git add -A && git commit -qm baseline
      eval "$body"
    ) >/dev/null 2>&1
    base=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
    out=$(CHARTER_HYGIENE_ROOT="$dir" CHARTER_HYGIENE_BASELINE="$base" bash "$SELF_PATH" 2>&1); rc=$?
    if [ "$rc" -eq "$want" ]; then
      echo "ok:   selftest: $label (rc=$rc)"
    else
      echo "FAIL: selftest: $label expected rc=$want got rc=$rc"
      printf '%s\n' "$out" | sed 's/^/        /'
      st_fail=1
    fi
    rm -rf "$dir"
  }

  # POSITIVE CONTROL: the untouched fixture must PASS. Without this every case
  # below could be passing for the wrong reason (a scanner that always reds).
  st_case 0 "clean fixture passes"                    ':'
  st_case 1 "arm B reds on a NEW charter with a host marker" \
    'printf "ssh root@89.167.28.7\n" > .claude/workflows/new-charter.md; git add -A'
  st_case 1 "arm B reds on a NEW charter with an ssh key path" \
    'printf "ssh -i ~/.ssh/barkpark_indx box\n" > .claude/workflows/new.md; git add -A'
  st_case 1 "arm B reds on a NEW charter with an operator address" \
    'printf "owner: me@guerrilla.no\n" > .claude/workflows/new.md; git add -A'
  # DISCRIMINATION: the SAME payload in a grandfathered charter must stay quiet.
  # If this case reds, arm B is banning the marker, not the new-file predicate.
  st_case 0 "arm B stays quiet when a grandfathered charter grows the same marker" \
    'printf "ssh root@89.167.28.7\n" >> .claude/workflows/old-charter.md'
  st_case 0 "arm B stays quiet on a NEW charter with no marker" \
    'printf "a clean new charter\n" > .claude/workflows/new.md; git add -A'
  # ARM A overrides every exclusion — including the evidence tree.
  st_case 1 "arm A reds on a zero-baseline address in the evidence tree" \
    'printf "tenant a@gyldendal.no\n" >> tooling/grip/ledger/row.md'
  st_case 0 "arm A ignores a forward marker in the evidence tree" \
    'printf "measured on 178.105.92.7 via ~/.ssh/barkpark_indx\n" >> tooling/grip/ledger/row.md'
  # A guard that cannot establish its baseline must REFUSE, not pass silently.
  d=$(mktemp -d); (cd "$d" && git init -q . && git commit -q --allow-empty -m x) >/dev/null 2>&1
  if CHARTER_HYGIENE_ROOT="$d" CHARTER_HYGIENE_BASELINE=0000000000000000000000000000000000000000 \
       bash "$SELF_PATH" >/dev/null 2>&1; then
    echo "FAIL: selftest: an unresolvable baseline PASSED — the guard can go blind"; st_fail=1
  else
    echo "ok:   selftest: an unresolvable baseline refuses instead of passing"
  fi
  rm -rf "$d"

  echo ""
  [ "$st_fail" -eq 0 ] && { echo "charter-corpus-hygiene --selftest: PASS"; exit 0; }
  echo "charter-corpus-hygiene --selftest: FAILED"; exit 1
fi

BASELINE="${CHARTER_HYGIENE_BASELINE:-a5c5486163a16b16956ab20a7c5932650f5fd05c}"
ROOT="${CHARTER_HYGIENE_ROOT:-}"
if [ -n "$ROOT" ]; then cd "$ROOT" || exit 2; else
  cd "$(git rev-parse --show-toplevel)" || exit 2
fi

FAIL=0

# --- marker patterns ----------------------------------------------------------
ZERO_BASELINE_PAT='[A-Za-z0-9._%+-]+@gyldendal\.no'
FORWARD_PAT='[A-Za-z0-9._%+-]+@guerrilla\.no|\b89\.167\.28\.[0-9]{1,3}\b|\b157\.180\.90\.[0-9]{1,3}\b|\b178\.105\.92\.[0-9]{1,3}\b|barkpark_indx'

SELF='scripts/charter-corpus-hygiene-check.sh'

# --- ARM A: zero baseline, whole tracked tree ---------------------------------
# `git grep` walks TRACKED files only — the row is about the tracked corpus, and
# this keeps node_modules/_build/deps out without a prune list.
A_HITS=$(git grep -nIE "$ZERO_BASELINE_PAT" -- . 2>/dev/null | grep -v "^$SELF:" || true)
if [ -n "$A_HITS" ]; then
  echo "FAIL: [arm A] a gyldendal.no address is back in the tracked corpus."
  echo "      Its baseline is ZERO (docs/decisions/0008). Redact it; do not allowlist it."
  printf '%s\n' "$A_HITS" | sed 's/^/      /'
  FAIL=1
else
  echo "ok:   [arm A] zero-baseline marker absent from the whole tracked tree"
fi

# --- ARM B: the five remaining markers, on NEW charters only ------------------
if ! git cat-file -e "${BASELINE}^{commit}" 2>/dev/null; then
  echo "FAIL: [arm B] baseline commit $BASELINE is not in this checkout."
  echo "      This guard cannot establish what is grandfathered, so it refuses to"
  echo "      pass silently. Use actions/checkout with fetch-depth: 0."
  exit 1
fi

GRANDFATHERED=$(git ls-tree -r --name-only "$BASELINE" -- .claude/workflows/ 2>/dev/null || true)
CURRENT=$(git ls-files -- '.claude/workflows/*.md' 2>/dev/null || true)

NEW_CHARTERS=$(comm -13 <(printf '%s\n' "$GRANDFATHERED" | sort) <(printf '%s\n' "$CURRENT" | sort))
NEW_COUNT=$(printf '%s\n' "$NEW_CHARTERS" | grep -c . || true)

B_HITS=''
if [ "$NEW_COUNT" -gt 0 ]; then
  # -- separator stops a pathspec that looks like a flag; xargs-free to survive spaces
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    h=$(grep -nIE "$FORWARD_PAT" -- "$f" 2>/dev/null || true)
    [ -n "$h" ] && B_HITS="${B_HITS}${f}:${h}"$'\n'
  done <<< "$NEW_CHARTERS"
fi

if [ -n "$B_HITS" ]; then
  echo "FAIL: [arm B] a NEW charter carries an infrastructure marker."
  echo "      Charters authored after the baseline must use placeholders"
  echo "      (<prod-ip>, <operator-email>, <ssh-key-path>). See docs/decisions/0008."
      echo "      If this is a RENAMED grandfathered charter and not a new one, that is"
      echo "      the known path-identity edge: move the baseline forward in this guard."
  printf '%s' "$B_HITS" | sed 's/^/      /'
  FAIL=1
else
  echo "ok:   [arm B] $NEW_COUNT charter(s) added since baseline, none carries a marker"
fi

if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "charter-corpus-hygiene: FAILED"
  exit 1
fi
echo ""
echo "charter-corpus-hygiene: PASS"
