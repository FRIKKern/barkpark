#!/usr/bin/env bash
#
# cli-dns-step-vocabulary-check.sh — the DNS-step VOCABULARY pin between the Go
# readers that EMIT a dns step error and the control plane's classifier that
# READS it.
#
# WHY THIS EXISTS (dr-w22-bl-internal-cli-trips-zero-required-gates)
# -----------------------------------------------------------------
# `BarkparkCloud.FailureCopy` turns a raw provisioning capture into the sentence
# the console shows. Its DNS clause is one regex, `@dns_step`
# (cloud/lib/barkpark_cloud/failure_copy.ex), anchored on the STEP VERB:
#
#     hetzner dns <upsert|change-ttl|delete|resolve|list>
#     hcloud zone rrset <set-records|change-ttl|delete|list>
#
# Every one of those verbs is a transcription of a Go `fmt.Errorf` prefix — the
# rendered bytes of the CLI-side DNS readers, `internal/cli/cloud/dns.go`,
# `internal/cli/cloud/dns_cloud.go` and `internal/hetzner/dns.go`. Rename a verb
# on the Go side and the classifier silently stops matching: the capture falls
# through to the capacity clause and the console tells a user that a DOMAIN
# failure was a SERVER-CAPACITY failure. Nothing in the tree reds.
#
# `failure_copy_test.exs` cannot catch it. Its corpus is HAND-TRANSCRIBED — the
# emitter strings are typed into the test with a `# internal/cli/cloud/dns.go:NNN`
# comment beside each — so it proves the clause matches its own fixtures and
# nothing about what the producers emit. That test's own comment records the
# same lesson one step back: three strings it used to pin were SYNTHETIC, "no
# producer anywhere emits them". A hand-authored corpus is how a rail guard ends
# up green by construction; this is the derivation that can lose.
#
# THIS IS THE READER-COVERAGE HALF OF THAT ROW. `internal/cli/cloud/**` reaches
# the required `Cloud gate` today only through the whole-tree `internal/**` entry
# the caller corpus needs (dr-w26-s4) — a DISPATCH claim, with no assertion
# behind it that reads a CLI reader's rendered bytes. This check is that
# assertion, and it runs in cloud.yml's UNFILTERED `path-escape` job, already in
# `Cloud gate`'s `needs:`, so a drift reds a context that can refuse a merge.
#
# WHAT IT REFUSES (the rule, in words)
# ------------------------------------
# Derive, from Go SOURCE, the set of `<family> <verb>` pairs any non-test .go
# file under internal/ emits as a `fmt.Errorf` PREFIX. Derive, from the
# `@dns_step` regex's own bytes, the set of pairs the classifier recognises.
# Assert the two sets are EQUAL, both directions:
#
#   (a) GO-ONLY — a verb a Go reader emits that the classifier does not know.
#       The capture misclassifies. This is the live one.
#   (b) REGEX-ONLY — a verb the classifier knows that no producer emits. A dead
#       alternation: it can only ever match a string this tree cannot make, and
#       it reads exactly like coverage.
#
# THE PREFIX ANCHOR IS LOAD-BEARING, and was measured, not assumed. Matching the
# family anywhere on a `fmt.Errorf` line — rather than immediately after the
# `("` — picks up `hetzner dns record` from internal/cli/hetzner_dns_cmd.go:598,
# where the phrase sits inside a backticked `run this` hint and is not a step
# prefix at all. That one false pair would have made this check red on a clean
# tree, i.e. an instrument nobody could satisfy.
#
# COUNT FLOORS, ON BOTH SIDES. Zero is a pass in every set comparison: two empty
# sets are equal. A `find` that stopped matching, or a regex extractor that
# stopped parsing, would report "0 differences" and exit 0 — clean-looking and
# completely blind. So each side must resolve at least VOCAB_MIN pairs or the
# check REFUSES (exit 2) rather than answer. Measured population on main at the
# time of writing: 9 pairs on each side (5 `hetzner dns`, 4 `hcloud zone rrset`).
# The floor is set BELOW that at 6, deliberately: a legitimate future deletion of
# one verb from both sides must not turn into a refusal, while a neutered scanner
# (which lands at 0, or at one family's worth) still cannot pass.
#
# POSITIVE CONTROL. The check prints every pair it resolved WITH the `file:line`
# that emits it, so a green names what it read. A verdict with no citations under
# it is the empty scan, and the floor above is what makes that fatal.
#
# EXIT CODES: 0 clean · 1 a measured drift · 2 cannot measure (a refusal, which
# makes NO claim in either direction).
#
# USAGE
#   cli-dns-step-vocabulary-check.sh            # the check (CI + the gate)
#   cli-dns-step-vocabulary-check.sh --selftest # run the harness
#   cli-dns-step-vocabulary-check.sh --list     # print both resolved sets
#
# bash 3.2 compatible (macOS runs it too). POSIX awk / grep -E only.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Retargeting hooks. The harness is their ONLY caller, and neither can weaken a
# real run: they change WHAT is compared, never how strictly — the floors, the
# both-directions equality and the exit vocabulary are constants below. The
# selftest asserts that pointing them at the real tree reproduces the real
# verdict byte for byte.
GO_ROOT="${CLI_DNS_VOCAB_GO_ROOT:-$REPO_ROOT/internal}"
EX_FILE="${CLI_DNS_VOCAB_EX_FILE:-$REPO_ROOT/cloud/lib/barkpark_cloud/failure_copy.ex}"

# The two step families. Kept as one ERE alternation so the producer scan and the
# classifier scan can never disagree about what a "family" is.
FAMILIES_ERE='hetzner dns|hcloud zone rrset'

# See the COUNT FLOORS note above. A CONSTANT on purpose: an env override would
# be a one-line CI bypass of the only thing that tells "clean" from "blind".
VOCAB_MIN=6

MODE="check"
case "${1:-}" in
  "") ;;
  --selftest) MODE="selftest" ;;
  --list) MODE="list" ;;
  *) echo "usage: $0 [--selftest|--list]" >&2; exit 2 ;;
esac

# ── producer side ───────────────────────────────────────────────────────────
# One `<family>\t<verb>\t<file>:<line>` record per emit site. The anchor is
# `fmt.Errorf("` immediately followed by the family: a PREFIX, not a mention.
scan_producers() {
  local root="$1"
  [ -d "$root" ] || return 2
  find "$root" -type f -name '*.go' ! -name '*_test.go' -print0 2>/dev/null \
    | LC_ALL=C xargs -0 grep -noE "fmt\.Errorf\(\"(${FAMILIES_ERE}) [a-z][a-z0-9-]*" /dev/null 2>/dev/null \
    | awk -F: -v root="$REPO_ROOT" '
        {
          # $1 = file, $2 = line, rest = the match (which itself holds no colon)
          file = $1; lineno = $2
          m = $0
          sub(/^[^:]*:[0-9]+:/, "", m)
          sub(/^fmt\.Errorf\("/, "", m)
          # split the trailing verb off the family
          n = split(m, a, / /)
          verb = a[n]
          fam = a[1]
          for (i = 2; i < n; i++) fam = fam " " a[i]
          # Citations are REPO-RELATIVE, or a GitHub annotation is dropped in
          # silence. Relative to the scan ROOT they would read `cli/cloud/dns.go`
          # for a file the reader has to find at `internal/cli/cloud/dns.go`.
          sub("^" root "/", "", file)
          printf "%s\t%s\t%s:%s\n", fam, verb, file, lineno
        }'
}

# ── classifier side ─────────────────────────────────────────────────────────
# One `<family>\t<verb>\t<file>:<line>` record per alternation branch, read out
# of the `@dns_step` regex's own bytes. Two spellings are understood: a
# `(?:a|b|c)` group, and a bare single verb.
scan_classifier() {
  local exfile="$1"
  [ -f "$exfile" ] || return 2
  grep -nE '@dns_step[[:space:]]*~r/' "$exfile" 2>/dev/null \
    | awk -F: -v exfile="$exfile" '
        {
          lineno = $1
          body = $0
          sub(/^[0-9]+:/, "", body)
          rest = body
          while (match(rest, /(hetzner dns|hcloud zone rrset) (\(\?:[a-z0-9|-]+\)|[a-z][a-z0-9-]*)/)) {
            hit = substr(rest, RSTART, RLENGTH)
            rest = substr(rest, RSTART + RLENGTH)
            # family = the hit minus its last space-separated token
            n = split(hit, a, / /)
            tail = a[n]
            fam = a[1]
            for (i = 2; i < n; i++) fam = fam " " a[i]
            if (tail ~ /^\(\?:/) {
              sub(/^\(\?:/, "", tail); sub(/\)$/, "", tail)
              k = split(tail, v, /\|/)
              for (i = 1; i <= k; i++)
                if (v[i] != "") printf "%s\t%s\t%s:%s\n", fam, v[i], exfile, lineno
            } else {
              printf "%s\t%s\t%s:%s\n", fam, tail, exfile, lineno
            }
          }
        }' | sed "s#\t${REPO_ROOT}/#\t#"
}

# ── the check ───────────────────────────────────────────────────────────────
run_check() {
  local list_only="${1:-no}"
  local tmp go_raw ex_raw go_set ex_set
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/clidnsvocab.XXXXXX")" || return 2
  go_raw="$tmp/go.raw"; ex_raw="$tmp/ex.raw"; go_set="$tmp/go.set"; ex_set="$tmp/ex.set"

  echo "── DNS step vocabulary: Go emitters vs FailureCopy.@dns_step ──"
  echo "go source root : ${GO_ROOT}"
  echo "classifier file: ${EX_FILE}"
  echo

  if ! scan_producers "$GO_ROOT" >"$go_raw" 2>/dev/null; then
    echo "REFUSED: the Go source root does not exist: ${GO_ROOT}"
    rm -rf "$tmp"; return 2
  fi
  if ! scan_classifier "$EX_FILE" >"$ex_raw" 2>/dev/null; then
    echo "REFUSED: the classifier file does not exist: ${EX_FILE}"
    rm -rf "$tmp"; return 2
  fi

  LC_ALL=C sort -u -t"$(printf '\t')" -k1,2 "$go_raw" | awk -F'\t' '{print $1"\t"$2}' | LC_ALL=C sort -u >"$go_set"
  awk -F'\t' '{print $1"\t"$2}' "$ex_raw" | LC_ALL=C sort -u >"$ex_set"

  local go_n ex_n
  go_n=$(wc -l <"$go_set" | tr -d ' ')
  ex_n=$(wc -l <"$ex_set" | tr -d ' ')

  echo "POSITIVE CONTROL — the Go emit sites this scan actually READ:"
  if [ "$go_n" -eq 0 ]; then
    echo "  (none)"
  else
    LC_ALL=C sort "$go_raw" | awk -F'\t' '{ printf "  go  %-32s %s\n", $1" "$2, $3 }'
  fi
  echo
  echo "POSITIVE CONTROL — the classifier branches this scan actually READ:"
  if [ "$ex_n" -eq 0 ]; then
    echo "  (none)"
  else
    LC_ALL=C sort "$ex_raw" | awk -F'\t' '{ printf "  ex  %-32s %s\n", $1" "$2, $3 }'
  fi
  echo
  echo "distinct pairs — go emitters: ${go_n}   classifier branches: ${ex_n}   floor: ${VOCAB_MIN}"
  echo

  if [ "$list_only" = "list" ]; then rm -rf "$tmp"; return 0; fi

  if [ "$go_n" -lt "$VOCAB_MIN" ] || [ "$ex_n" -lt "$VOCAB_MIN" ]; then
    echo "REFUSED: a side resolved fewer than ${VOCAB_MIN} pairs (go=${go_n}, classifier=${ex_n})."
    echo "  Two empty sets are EQUAL, so a scanner that stopped matching would report zero"
    echo "  differences and exit 0. This check makes NO claim about vocabulary drift here."
    rm -rf "$tmp"; return 2
  fi

  local only_go only_ex n_go n_ex
  only_go="$(LC_ALL=C comm -23 "$go_set" "$ex_set")"
  only_ex="$(LC_ALL=C comm -13 "$go_set" "$ex_set")"
  n_go=0; n_ex=0
  [ -n "$only_go" ] && n_go=$(printf '%s\n' "$only_go" | wc -l | tr -d ' ')
  [ -n "$only_ex" ] && n_ex=$(printf '%s\n' "$only_ex" | wc -l | tr -d ' ')

  if [ "$n_go" -eq 0 ] && [ "$n_ex" -eq 0 ]; then
    rm -rf "$tmp"
    echo "OK: every DNS step verb a Go reader emits is classified, and every classifier branch has a live producer (${go_n} pairs)."
    return 0
  fi

  if [ "$n_go" -gt 0 ]; then
    printf '%s\n' "$only_go" | while IFS="$(printf '\t')" read -r fam verb; do
      local where
      where="$(awk -F'\t' -v f="$fam" -v v="$verb" '$1==f && $2==v {print $3; exit}' "$go_raw")"
      echo "::error file=cloud/lib/barkpark_cloud/failure_copy.ex::dns-step vocabulary (a) GO-ONLY: a Go reader emits \"${fam} ${verb}\" (${where}) and FailureCopy.@dns_step does not classify it — that capture falls through to the capacity clause and the console calls a DOMAIN failure a SERVER-CAPACITY one."
      echo "  RED (a) GO-ONLY   ${fam} ${verb}   emitted at ${where}, absent from @dns_step"
    done
  fi
  if [ "$n_ex" -gt 0 ]; then
    printf '%s\n' "$only_ex" | while IFS="$(printf '\t')" read -r fam verb; do
      echo "::error file=cloud/lib/barkpark_cloud/failure_copy.ex::dns-step vocabulary (b) CLASSIFIER-ONLY: @dns_step recognises \"${fam} ${verb}\" and no Go reader under ${GO_ROOT} emits it as a fmt.Errorf prefix — a dead alternation that can only match a string this tree cannot produce, and it reads exactly like coverage."
      echo "  RED (b) CLASSIFIER-ONLY   ${fam} ${verb}   in @dns_step, no live producer"
    done
  fi
  echo
  echo "FAILED: ${n_go} go-only and ${n_ex} classifier-only DNS step verb(s)."
  rm -rf "$tmp"
  return 1
}

# ── selftest ────────────────────────────────────────────────────────────────
# Fixture note: every fixture that must reach the COMPARISON carries at least
# VOCAB_MIN pairs on both sides, so a red fixture reds on the drift it encodes
# and never on the floor.
selftest() {
  local pass=0 fail=0 d out rc
  ok()  { pass=$((pass + 1)); echo "ok   - $*"; }
  bad() { fail=$((fail + 1)); echo "FAIL - $*"; }
  # SUBSTRING TESTS ARE A BUILTIN `case`, NEVER `printf | grep -q`. Under
  # `set -o pipefail` a `grep -q` that matches EXITS FIRST, printf takes SIGPIPE,
  # and the pipeline returns 141 — falsy. It only bites once the payload exceeds
  # the pipe buffer, so the pipe form passes on a short fixture and inverts every
  # assertion on a real one: measured here, two true reds read as harness
  # failures ("should red (a), got exit 1") while the check had behaved exactly
  # right. No pipe, no SIGPIPE, no load-dependent verdict.
  has() { case "$out" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

  d="$(mktemp -d "${TMPDIR:-/tmp}/clidnsvocab-st.XXXXXX")"
  trap 'rm -rf "$d"' RETURN

  mkdir -p "$d/go/cli/cloud" "$d/go/hetzner"
  cat >"$d/go/hetzner/dns.go" <<'GO'
package hetzner

func a() error { return fmt.Errorf("hetzner dns upsert %q: %w", f, err) }
func b() error { return fmt.Errorf("hetzner dns change-ttl %q: %w", f, err) }
func c() error { return fmt.Errorf("hetzner dns delete %q: %w", f, err) }
func e() error { return fmt.Errorf("hetzner dns resolve %q: %w", f, err) }
GO
  cat >"$d/go/cli/cloud/dns.go" <<'GO'
package cloud

func f() error { return fmt.Errorf("hetzner dns list: %w", err) }
func g() error { return fmt.Errorf("hcloud zone rrset list %q: %w: %s", z, err, out) }
func h() error { return fmt.Errorf("hcloud zone rrset set-records %q: %w: %s", z, err, out) }
func i() error { return fmt.Errorf("hcloud zone rrset change-ttl %q: %w: %s", z, err, out) }
func j() error { return fmt.Errorf("hcloud zone rrset delete %q: %w: %s", z, err, out) }
GO
  # The PREFIX-ANCHOR fixture: a mention of the family inside a hint string, on a
  # fmt.Errorf line, that is NOT a step prefix. It must contribute NOTHING.
  cat >"$d/go/cli/cloud/hint.go" <<'GO'
package cloud

func k() error {
	return fmt.Errorf("record %s not found (see `bp cloud hetzner dns record list --zone %s`)", n, z)
}
GO
  # A _test.go emitter must be invisible: tests are not producers.
  cat >"$d/go/cli/cloud/dns_test.go" <<'GO'
package cloud

func l() error { return fmt.Errorf("hetzner dns bogusverb %q: %w", f, err) }
GO

  mk_ex() { printf '  @dns_step ~r/\\b(?:hetzner dns (?:%s)|hcloud zone rrset (?:%s))\\b/\n' "$1" "$2" >"$3"; }

  mk_ex 'upsert|change-ttl|delete|resolve|list' 'set-records|change-ttl|delete|list' "$d/match.ex"
  mk_ex 'upsert|change-ttl|delete|resolve' 'set-records|change-ttl|delete|list' "$d/drop_list.ex"
  mk_ex 'upsert|change-ttl|delete|resolve|list|ghostverb' 'set-records|change-ttl|delete|list' "$d/ghost.ex"
  : >"$d/empty.ex"

  out="$(GO_ROOT="$d/go" EX_FILE="$d/match.ex" run_check 2>&1)"; rc=$?
  if [ $rc -eq 0 ]; then ok "an in-sync vocabulary is GREEN"
  else bad "in-sync vocabulary should be green, got exit $rc"; printf '%s\n' "$out" | sed 's/^/       /'; fi
  if has "go emitters: 9" && has "classifier branches: 9"; then
    ok "positive control resolved 9 pairs on each side"
  else bad "expected 9 pairs per side"; printf '%s\n' "$out" | sed 's/^/       /'; fi
  if has "hetzner dns record"; then
    bad "the PREFIX anchor leaked: a backticked hint was read as a step prefix"
  else ok "a family MENTION inside a hint string is not read as a step prefix"; fi
  if has "bogusverb"; then
    bad "a _test.go emitter was counted as a producer"
  else ok "_test.go emitters are excluded from the producer census"; fi

  out="$(GO_ROOT="$d/go" EX_FILE="$d/drop_list.ex" run_check 2>&1)"; rc=$?
  if [ $rc -eq 1 ] && has "(a) GO-ONLY" && has "hetzner dns list"; then
    ok "(a) a Go verb the classifier lost is RED and names it"
  else bad "dropping 'list' from the classifier should red (a), got exit $rc"; printf '%s\n' "$out" | sed 's/^/       /'; fi

  out="$(GO_ROOT="$d/go" EX_FILE="$d/ghost.ex" run_check 2>&1)"; rc=$?
  if [ $rc -eq 1 ] && has "(b) CLASSIFIER-ONLY" && has "ghostverb"; then
    ok "(b) a classifier branch with no live producer is RED and names it"
  else bad "a producer-less alternation should red (b), got exit $rc"; printf '%s\n' "$out" | sed 's/^/       /'; fi

  out="$(GO_ROOT="$d/go" EX_FILE="$d/empty.ex" run_check 2>&1)"; rc=$?
  if [ $rc -eq 2 ] && has "REFUSED"; then
    ok "a classifier file with no @dns_step REFUSES (exit 2) instead of greening on two empty sets"
  else bad "an unparseable classifier should refuse with exit 2, got exit $rc"; printf '%s\n' "$out" | sed 's/^/       /'; fi

  out="$(GO_ROOT="$d/nosuchdir" EX_FILE="$d/match.ex" run_check 2>&1)"; rc=$?
  if [ $rc -eq 2 ] && has "REFUSED"; then
    ok "a missing Go source root REFUSES (exit 2), it does not report a clean tree"
  else bad "a missing go root should refuse with exit 2, got exit $rc"; printf '%s\n' "$out" | sed 's/^/       /'; fi

  # THE FLOOR IS LOAD-BEARING, proved rather than asserted: one family alone is
  # 4 pairs, under the floor of 6, and must refuse rather than compare.
  mkdir -p "$d/thin"
  cat >"$d/thin/thin.go" <<'GO'
package thin

func a() error { return fmt.Errorf("hcloud zone rrset list %q: %w", z, err) }
func b() error { return fmt.Errorf("hcloud zone rrset delete %q: %w", z, err) }
GO
  printf '  @dns_step ~r/\\b(?:hcloud zone rrset (?:list|delete))\\b/\n' >"$d/thin.ex"
  out="$(GO_ROOT="$d/thin" EX_FILE="$d/thin.ex" run_check 2>&1)"; rc=$?
  if [ $rc -eq 2 ] && has "fewer than ${VOCAB_MIN}"; then
    ok "a scan that resolves under the floor REFUSES — an EQUAL pair of near-empty sets is not a pass"
  else bad "the ${VOCAB_MIN}-pair floor should refuse a 2-pair tree, got exit $rc"; printf '%s\n' "$out" | sed 's/^/       /'; fi

  # RETARGETING CANNOT WEAKEN A REAL RUN: the defaults and an explicit retarget
  # at the same paths must produce the identical verdict.
  local rc_default rc_explicit
  run_check >/dev/null 2>&1; rc_default=$?
  out="$(GO_ROOT="$REPO_ROOT/internal" EX_FILE="$REPO_ROOT/cloud/lib/barkpark_cloud/failure_copy.ex" run_check 2>&1)"; rc_explicit=$?
  if [ "$rc_default" -eq "$rc_explicit" ]; then
    ok "retargeting at the real tree reproduces the default verdict (exit ${rc_default})"
  else bad "retarget changed the verdict: default ${rc_default} vs explicit ${rc_explicit}"; fi

  echo
  echo "selftest: $pass passed, $fail failed"
  [ "$fail" -eq 0 ] || return 1
  return 0
}

case "$MODE" in
  selftest) selftest; exit $? ;;
  list) run_check list; exit $? ;;
  *) run_check; exit $? ;;
esac
