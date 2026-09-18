#!/usr/bin/env bash
# pds-charter-anchors-check.sh — PDS-D299 made runnable.
#
# PDS-D299 is law: "ADJUDICATE BY CONTENT; CITED LINE NUMBERS ARE UNTRUSTWORTHY."
# A bare `file.sh:<line>` citation is a SNAPSHOT — it silently stops resolving the next
# time the file grows a line above it, and nothing reds. A CONTENT anchor is a
# PREDICATE: it names bytes that either are in the file or are not, so it can be
# checked by machine on every commit, forever, with no baseline to maintain.
#
# THE ANCHOR FORM, as carried by the charter:
#
#     `<path>`@`<literal>`
#
# e.g.  `scripts/pds-pull-proof.sh`@`spent_now=$((spent + 1))`
#
# RULE (arm A, hard): every anchor must match its file EXACTLY ONCE. Zero hits =
# the citation rotted. Two or more = the citation is ambiguous and a reader
# cannot tell which site the decision means; that is a rotted citation too, just
# one that has not bitten yet.
#
# RULE (arm B, ratchet): the count of surviving LEGACY bare-line citations
# (`pds-pull-proof.sh:NNN`) must not EXCEED the ceiling below. Fewer is progress,
# never a red — a ratchet that fires when the world improves trains people to
# ignore it — but it prints a LOWER-THE-CEILING line so the number cannot drift
# quietly upward behind a stale floor.
#
# RULE (arm C, ratchet): the same, for the FILE-LESS citation form `` `:NNN` ``
# (and `` `:NNN-MMM` ``) that PDS-D101 and PDS-D116 used. Arm B cannot see these
# — its pattern requires the filename — and that is the worse form, not the
# milder one: a bare `:2240` names no file at all, so a reader cannot even ask
# which blob it was true against, and no machine can resolve it. It is ratcheted
# separately rather than folded into arm B so a gain in one form can never be
# hidden by a loss in the other.
#
# RULE (arm D, ratchet): no PDS-D identifier may be DEFINED twice. A duplicated
# number makes every future citation of it ambiguous by construction, which is
# the same defect arm A refuses for content anchors, one level up. Three
# numbers, not one, because the LENS is where this check goes wrong:
#
#   * duplicates .......... ceiling below. Definitions are counted with the
#     em-dash discriminator `PDS-D<n> — `, because `**PDS-D454 stands — no
#     Elixir gate this wave**` is a bold CITATION at line start and is not a
#     definition; a looser boundary counts it and manufactures a duplicate.
#   * unclassified ........ lines that LOOK like a definition (`**PDS-D<n>` or
#     `### PDS-D<n>` at line start) but do not carry the discriminator. Ratcheted so the lens
#     cannot go blind quietly: a definition written with a different separator
#     would otherwise vanish from the duplicate count with nothing reporting it.
#   * definitions floor ... a PRECONDITION, and it is scoped to the CANONICAL
#     charter only. The production charter is append-only, so the
#     definition count can only grow. If it FALLS, the pattern stopped matching
#     and every verdict above it is vacuous — that reds, loudly, rather than
#     printing a reassuring `duplicates 0`. A fixture charter is legitimately
#     two lines long, so the floor is SKIPPED (and says so) for any other path;
#     the duplicate and unclassified arms still run on it, and the self-test
#     exercises both there.
#
# RULE (arm E, ratchet): every path an anchor CITES must be able to DISPATCH the
# job that checks the anchor. This is the defect that produced three separate
# rots of one citation in a single day (2026-09-17), none of them caught on the
# PR that caused it. `api/lib/barkpark/tasks/board.ex` is cited by this charter,
# but it appears in NEITHER the workflow-level `pull_request: paths:` list NOR
# the `pds-harnesses` roster rows of .github/workflows/shell-harnesses.yml — so
# the refactor that rotted the anchor ran no pds-harnesses job at all. The red
# then surfaced on the NEXT unrelated PDS PR, which could neither have caused it
# nor fixed it from its own fence; #18949's rollup was reddened exactly this way.
#
# shell-harnesses.yml states this lesson twice in its own comments — "a guard
# whose corpus cannot trigger it is a guard that watches the wrong PRs" and "a
# guard that does not watch the file it guards is not a guard" — and both times
# the fix was an enumeration of the files known to be missing THAT DAY. An
# enumeration is a snapshot; this arm is the predicate, so the next anchor
# pointed at an untriggerable file is caught when it is WRITTEN.
#
# BOTH halves must match, because GitHub needs both: the workflow-level `paths:`
# decides whether the workflow DISPATCHES, and the `pds-harnesses` roster rows
# decide whether the job is SELECTED once it has. A path in one and not the
# other starts a run in which the job is skipped — the exact disagreement
# shell-harnesses.yml records against `scripts/pds-secret-scan.sh`.
#
# It is a RATCHET, not a hard red, and deliberately so: 11 cited paths are
# uncovered today, all of them outside the deploy/PDS fence that owns this
# script (api/**, internal/**, docs/contracts/**, and `scripts/pds-*.py`, which
# the `scripts/pds-*.sh` glob misses on its extension). Hard-redding here would
# put a permanent red on main that no PDS PR is allowed to fix. The ceiling
# bounds the damage and names every uncovered path, so the .github/ repair has a
# worklist; the arm reds the moment a NEW anchor is pointed at a file that
# cannot trigger the check.
#
# PRECONDITION, loud: if the workflow is missing or either extracted set comes
# back EMPTY, arm E reds as UNCHECKED instead of printing `0 uncovered`. An
# absence is never caught by inspection — a parse that silently stops matching
# would otherwise report perfect coverage.
#
# THE LENS IS THE WHOLE FINDING HERE, TWICE. A census scoped to the LIST-ITEM
# form `^- **PDS-D<n>` sees 590 of 808 definitions and reports FIVE duplicates.
# Widening to the un-bulleted `**PDS-D<n>` form finds thirteen more (18).
# Widening again to the indented and `### PDS-D<n>` heading forms — the lens
# pds-record-parity.sh already used — finds two more (20). A guard baselined on
# any of the narrow lenses would have gone green on the wrong number and locked
# it in. Baseline every ceiling from a run of THIS script, never from a figure
# quoted in prose, and cross-check the lens against an INDEPENDENT instrument.
#
# Usage: bash scripts/pds-charter-anchors-check.sh [charter-path]
# Exit 0 = every anchor resolves and no new bare citation appeared. Exit 1 = a
# citation no longer resolves; the output names each one.

# shellcheck disable=SC2016  # backticks inside single quotes are literal citation syntax, not expansions
set -uo pipefail

CHARTER="${1:-.claude/workflows/bp-pds-charter.md}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

# Legacy bare `pds-pull-proof.sh:NNN` citations still in the charter. Lower this
# as decisions are converted to anchors; raising it is the thing arm B refuses.
LEGACY_BARE_CEILING="${PDS_ANCHOR_LEGACY_CEILING:-15}"

# File-less `` `:NNN` `` citations still in the charter (arm C). Same ratchet
# rule: lower it as decisions are converted; raising it is what arm C refuses.
FILELESS_CEILING="${PDS_ANCHOR_FILELESS_CEILING:-641}"

# Duplicated PDS-D identifiers still in the charter (arm D). Same ratchet rule.
DUPE_CEILING="${PDS_ANCHOR_DUPE_CEILING:-20}"
# Definition-shaped lines that carry no em-dash discriminator (arm D's blind
# spot, made visible). Both known ones are bold prose citations, not definitions.
UNCLASSIFIED_CEILING="${PDS_ANCHOR_UNCLASSIFIED_CEILING:-8}"
# The charter is append-only: this count may grow, never shrink. A fall means
# the pattern broke, not that decisions were deleted.
DEF_FLOOR="${PDS_ANCHOR_DEF_FLOOR:-809}"

# Arm E — anchor target paths that cannot DISPATCH the job that adjudicates
# them. Baselined at 11 from a run of this script on d2a4ecc02. Same ratchet
# rule as B/C/D: falling is progress, exceeding is the red.
TRIGGER_GAP_CEILING="${PDS_ANCHOR_TRIGGER_GAP_CEILING:-11}"
# The workflow whose trigger set arm E reads. Overridable so the self-test can
# point it at a fixture; never overridden in CI.
TRIGGER_WORKFLOW="${PDS_ANCHOR_WORKFLOW:-.github/workflows/shell-harnesses.yml}"

if [ ! -f "$CHARTER" ]; then
  printf 'pds-charter-anchors-check: charter not found: %s\n' "$CHARTER" >&2
  exit 2
fi

fails=0
checked=0

# Extract `path`@`literal` pairs. A line may carry more than one; perl walks
# every match on every line rather than the first, and prints them NUL-free on
# one tab-separated line each.
# Parse `path`@`literal` pairs. BOTH halves must sit on ONE line: a line-wrapped
# anchor would otherwise vanish from the parse and be silently unchecked, which
# is the exact failure this script exists to make impossible. So we also count
# the raw joints (a backtick, an @, a backtick) and require that every joint
# produced a parsed pair — an absence is never caught by inspection.
# The literal path `<path>` is the documented placeholder used when the charter
# SHOWS the form; it is parsed, then skipped.
anchors="$(perl -ne 'while (/`([^`\n]+)`\@`([^`\n]+)`/g) { print "$1\t$2\n" }' "$CHARTER")"
joints="$(grep -o '`@`' "$CHARTER" | wc -l | tr -d ' ')"
pairs="$(printf '%s' "$anchors" | grep -c . || true)"

if [ "$joints" -ne "$pairs" ]; then
  printf 'MALFORMED  %s joint(s) of the form `@` but only %s parsed on a single line.\n' "$joints" "$pairs"
  printf '           An anchor was line-wrapped. Keep `<path>`@`<literal>` on ONE line,\n'
  printf '           or it is never checked.\n'
  fails=$((fails + 1))
fi

if [ -n "$anchors" ]; then
  while IFS=$'\t' read -r path literal; do
    [ -n "$path" ] || continue
    [ "$path" = "<path>" ] && continue   # the documented placeholder, not an anchor
    checked=$((checked + 1))
    if [ ! -f "$path" ]; then
      printf 'ROTTED  %s\n        file does not exist; literal: %s\n' "$path" "$literal"
      fails=$((fails + 1))
      continue
    fi
    # -F: the literal is bytes, never a pattern. grep -c counts LINES, which is
    # what we want: an anchor naming a line that appears twice is ambiguous.
    hits="$(grep -cF -- "$literal" "$path")"
    if [ "$hits" -eq 1 ]; then
      continue
    elif [ "$hits" -eq 0 ]; then
      printf 'ROTTED  %s\n        literal no longer present: %s\n' "$path" "$literal"
      fails=$((fails + 1))
    else
      printf 'AMBIGUOUS  %s\n        literal matches %s lines, must match exactly 1: %s\n' "$path" "$hits" "$literal"
      fails=$((fails + 1))
    fi
  done <<< "$anchors"
fi

# Arm B — the legacy bare-citation ratchet.
bare="$(grep -oE 'pds-pull-proof\.sh`?:[0-9]' "$CHARTER" | wc -l | tr -d ' ')"

# Arm C — the FILE-LESS bare-citation ratchet. grep -o prints one match per
# occurrence (grep -c would count LINES, and a charter line can carry three).
fileless="$(grep -oE '`:[0-9]+(-[0-9]+)?`' "$CHARTER" | wc -l | tr -d ' ')"

# Arm D — the duplicate-identifier ratchet. A definition is `**PDS-D<n> — `
# at line start, optionally as a markdown list item. The em dash immediately
# after the number is the discriminator that separates a DEFINITION from a bold
# CITATION; see the header.
# The lens is deliberately the SAME one scripts/pds-record-parity.sh uses for
# `--axis d` (indented or bulleted `**PDS-D<n>`, plus the `### PDS-D<n>` heading
# form), so the two instruments cannot disagree about what a definition IS. A
# narrower lens here was caught by exactly that comparison: it missed the
# heading form and two more duplicates with it.
DEF_RE='^[[:space:]]*([-*][[:space:]]+)?\*\*PDS-D[0-9]+[a-z]? — |^#+[[:space:]]+PDS-D[0-9]+[a-z]? — '
LOOSE_RE='^[[:space:]]*([-*][[:space:]]+)?\*\*PDS-D[0-9]+|^#+[[:space:]]+PDS-D[0-9]+'

# The floor is a property of the CANONICAL append-only charter. A fixture is
# legitimately tiny, so scope it rather than letting it red every self-test arm.
CANONICAL_CHARTER="$REPO_ROOT/.claude/workflows/bp-pds-charter.md"
charter_abs="$(cd "$(dirname "$CHARTER")" && pwd)/$(basename "$CHARTER")"
if [ "$charter_abs" = "$CANONICAL_CHARTER" ]; then is_canonical=1; else is_canonical=0; fi

defs="$(grep -cE "$DEF_RE" "$CHARTER" || true)"
unclassified="$(grep -cE "$LOOSE_RE" "$CHARTER" || true)"
unclassified=$((unclassified - defs))
dupe_list="$(grep -oE "$DEF_RE" "$CHARTER" \
  | grep -oE 'PDS-D[0-9]+[a-z]?' \
  | sort | uniq -c | awk '$1 > 1 { print $2 }')"
dupes="$(printf '%s' "$dupe_list" | grep -c . || true)"

# ── Arm E — the TRIGGER-COVERAGE ratchet. ────────────────────────────────────
# Reuses the SAME `$anchors` parse arm A used, so the two arms can never
# disagree about what an anchor IS. Distinct paths only: a file cited by six
# anchors is one trigger-coverage fact, not six.
#
# perl, not a bash `case` loop: `case` patterns are not pathname expansion, so
# `*` there matches `/` too and `scripts/pds-*.sh` would silently "cover"
# scripts/pds-x/y.sh. Over-matching UNDER-counts the gap, which is the unsafe
# direction for a ratchet, so the globs are translated with GitHub's semantics
# (`**` spans separators, `*` and `?` do not).
trigger_gap=0
trigger_gap_list=""
trigger_unchecked=""

if [ ! -f "$TRIGGER_WORKFLOW" ]; then
  trigger_unchecked="workflow not found: $TRIGGER_WORKFLOW"
else
  trigger_out="$(printf '%s' "$anchors" \
    | perl -e '
      my $wf = shift @ARGV;
      open(my $fh, "<", $wf) or die "open: $!";
      my @lines = <$fh>; close $fh;
      my (@wfpaths, @roster);
      my ($in_pr, $in_paths) = (0, 0);
      for my $l (@lines) {
        # The workflow-level pull_request paths list: the dispatch half.
        if ($l =~ /^  pull_request:/)          { $in_pr = 1; next }
        if ($l =~ /^  [a-z_]+:/ && $l !~ /^  pull_request:/) { $in_pr = 0; $in_paths = 0 }
        if ($in_pr && $l =~ /^    paths:/)     { $in_paths = 1; next }
        if ($in_paths) {
          if ($l =~ /^      - "(.+)"\s*$/)     { push @wfpaths, $1; next }
          next if $l =~ /^\s*#/ || $l !~ /\S/;
          $in_paths = 0; $in_pr = 0;
        }
        # The roster rows: the job-SELECTION half.
        push @roster, $1 if $l =~ /^\s+pds-harnesses (\S+)\s*$/;
      }
      # PRECONDITION. An empty set here means the parse stopped matching, not
      # that the workflow stopped filtering — report it, never score it.
      if (!@wfpaths) { print "UNCHECKED\tthe workflow-level pull_request paths list parsed EMPTY\n"; exit }
      if (!@roster)  { print "UNCHECKED\tthe pds-harnesses roster rows parsed EMPTY\n"; exit }
      printf "SETS\t%d\t%d\n", scalar(@wfpaths), scalar(@roster);
      sub to_re {
        my ($g) = @_; my $o = ""; my $i = 0;
        while ($i < length $g) {
          my $c = substr($g, $i, 1);
          if    (substr($g, $i, 2) eq "**") { $o .= ".*";     $i += 2 }
          elsif ($c eq "*")                 { $o .= "[^/]*";  $i += 1 }
          elsif ($c eq "?")                 { $o .= "[^/]";   $i += 1 }
          else                              { $o .= quotemeta $c; $i += 1 }
        }
        return qr/^$o$/;
      }
      my @wfre = map { to_re($_) } @wfpaths;
      my @rore = map { to_re($_) } @roster;
      my %seen;
      while (my $line = <STDIN>) {
        chomp $line;
        my ($path) = split /\t/, $line;
        next unless defined $path && length $path;
        next if $path eq "<path>";
        next if $seen{$path}++;
        my $in_wf = grep { $path =~ $_ } @wfre;
        my $in_ro = grep { $path =~ $_ } @rore;
        next if $in_wf && $in_ro;
        printf "GAP\t%s\t%s\t%s\n", $path, $in_wf ? "yes" : "no", $in_ro ? "yes" : "no";
      }
    ' "$TRIGGER_WORKFLOW" 2>&1)"

  if printf '%s' "$trigger_out" | grep -q '^UNCHECKED'; then
    trigger_unchecked="$(printf '%s' "$trigger_out" | sed -n 's/^UNCHECKED\t//p' | head -1)"
  elif ! printf '%s' "$trigger_out" | grep -q '^SETS'; then
    trigger_unchecked="the trigger parse produced no verdict line: $trigger_out"
  else
    trigger_gap_list="$(printf '%s' "$trigger_out" | grep '^GAP' | cut -f2- || true)"
    trigger_gap="$(printf '%s' "$trigger_gap_list" | grep -c . || true)"
  fi
fi

printf '\n'
printf 'anchors checked ..... %s (arm A: each must resolve to exactly 1 line)\n' "$checked"
printf 'anchors rotted ...... %s\n' "$fails"
printf 'legacy bare cites ... %s (ceiling %s)\n' "$bare" "$LEGACY_BARE_CEILING"
printf 'file-less cites ..... %s (ceiling %s)\n' "$fileless" "$FILELESS_CEILING"
if [ "$is_canonical" -eq 1 ]; then
  printf 'D-definitions ....... %s (floor %s — append-only, may only grow)\n' "$defs" "$DEF_FLOOR"
else
  printf 'D-definitions ....... %s (floor SKIPPED — not the canonical charter)\n' "$defs"
fi
printf 'duplicate D-numbers . %s (ceiling %s)\n' "$dupes" "$DUPE_CEILING"
printf 'unclassified lines .. %s (ceiling %s — definition-shaped, no discriminator)\n' "$unclassified" "$UNCLASSIFIED_CEILING"
if [ -n "$trigger_unchecked" ]; then
  printf 'untriggerable cites . UNCHECKED (arm E could not look)\n'
else
  printf 'untriggerable cites . %s (ceiling %s — cited paths that cannot dispatch this check)\n' "$trigger_gap" "$TRIGGER_GAP_CEILING"
fi

if [ "$bare" -gt "$LEGACY_BARE_CEILING" ]; then
  printf '\nFAIL: a NEW bare `pds-pull-proof.sh:NNN` citation was added (%s > ceiling %s).\n' "$bare" "$LEGACY_BARE_CEILING"
  printf '      PDS-D299 forbids adjudicating by line number. Cite content instead:\n'
  printf '      `scripts/pds-pull-proof.sh`@`<a unique literal from the line you mean>`\n'
  fails=$((fails + 1))
elif [ "$bare" -lt "$LEGACY_BARE_CEILING" ]; then
  printf '\nPROGRESS: legacy bare citations are down to %s. LOWER THE CEILING to %s in this script\n' "$bare" "$bare"
  printf '          so the gain is locked in. This is NOT a failure.\n'
fi

if [ "$fileless" -gt "$FILELESS_CEILING" ]; then
  printf '\nFAIL: a NEW file-less `:NNN` citation was added (%s > ceiling %s).\n' "$fileless" "$FILELESS_CEILING"
  printf '      A citation that names no file cannot be resolved by any reader or any machine.\n'
  printf '      Cite content instead: `<path>`@`<a unique literal from the line you mean>`\n'
  fails=$((fails + 1))
elif [ "$fileless" -lt "$FILELESS_CEILING" ]; then
  printf '\nPROGRESS: file-less citations are down to %s. LOWER THE CEILING to %s in this script\n' "$fileless" "$fileless"
  printf '          so the gain is locked in. This is NOT a failure.\n'
fi

# Arm D's PRECONDITION first: if the lens stopped seeing definitions, every
# duplicate verdict below it is vacuous and must not be printed as a pass.
if [ "$is_canonical" -eq 1 ] && [ "$defs" -lt "$DEF_FLOOR" ]; then
  printf '\nFAIL: only %s PDS-D definitions matched, below the floor of %s.\n' "$defs" "$DEF_FLOOR"
  printf '      The charter is append-only, so this is the PATTERN breaking, not decisions\n'
  printf '      being deleted. Arm D measured nothing; fix the pattern before trusting it.\n'
  fails=$((fails + 1))
elif [ "$is_canonical" -eq 1 ] && [ "$defs" -gt "$DEF_FLOOR" ]; then
  printf '\nPROGRESS: %s definitions now (floor %s). RAISE THE FLOOR to %s so a future\n' "$defs" "$DEF_FLOOR" "$defs"
  printf '          pattern break cannot hide behind a stale floor. This is NOT a failure.\n'
fi

if [ "$unclassified" -gt "$UNCLASSIFIED_CEILING" ]; then
  printf '\nFAIL: %s definition-shaped lines carry no `— ` discriminator (ceiling %s).\n' "$unclassified" "$UNCLASSIFIED_CEILING"
  printf '      Arm D cannot see these, so a duplicate hiding in one would read as 0.\n'
  printf '      Write the definition as `**PDS-D<n> — TITLE.**`, or arm D is blind to it.\n'
  fails=$((fails + 1))
fi

if [ "$dupes" -gt "$DUPE_CEILING" ]; then
  printf '\nFAIL: %s PDS-D identifiers are defined twice (ceiling %s):\n' "$dupes" "$DUPE_CEILING"
  printf '%s\n' "$dupe_list" | sed 's/^/      /'
  printf '      A number defined twice makes every citation of it ambiguous by construction.\n'
  printf '      Mint the next free number from tooling/pds/d-number-reservations.tsv instead.\n'
  fails=$((fails + 1))
elif [ "$dupes" -lt "$DUPE_CEILING" ]; then
  printf '\nPROGRESS: duplicate D-numbers are down to %s. LOWER THE CEILING to %s.\n' "$dupes" "$dupes"
  printf '          This is NOT a failure.\n'
fi

# ── Arm E's verdict. The PRECONDITION is scored FIRST: if arm E could not look,
# every coverage number below it would be vacuous, so it reds rather than
# printing a reassuring zero.
if [ -n "$trigger_unchecked" ]; then
  printf '\nFAIL: arm E is UNCHECKED — %s\n' "$trigger_unchecked"
  printf '      Arm E measured NOTHING. This is not a pass with no gaps; it is a blind\n'
  printf '      instrument. Fix the parse (or the path to %s) before\n' "$TRIGGER_WORKFLOW"
  printf '      trusting any trigger-coverage verdict.\n'
  fails=$((fails + 1))
elif [ "$trigger_gap" -gt "$TRIGGER_GAP_CEILING" ]; then
  printf '\nFAIL: %s cited path(s) cannot DISPATCH this check (ceiling %s):\n' "$trigger_gap" "$TRIGGER_GAP_CEILING"
  printf '%s\n' "$trigger_gap_list" | awk -F'\t' '{ printf "      %-44s in workflow paths: %-3s  in pds-harnesses roster: %s\n", $1, $2, $3 }'
  printf '      An anchor on a file that cannot trigger the job checking it rots in\n'
  printf '      SILENCE on the PR that rots it, then reds on the next unrelated PDS PR,\n'
  printf '      which can neither have caused it nor fix it from its own fence.\n'
  printf '      Add the path to BOTH halves of .github/workflows/shell-harnesses.yml —\n'
  printf '      the workflow-level pull_request/push `paths:` lists AND a\n'
  printf '      `pds-harnesses <path>` roster row — or cite a file that is already in both.\n'
  fails=$((fails + 1))
elif [ "$trigger_gap" -lt "$TRIGGER_GAP_CEILING" ]; then
  printf '\nPROGRESS: untriggerable citations are down to %s. LOWER THE CEILING to %s in this\n' "$trigger_gap" "$trigger_gap"
  printf '          script so the gain is locked in. This is NOT a failure.\n'
fi

if [ "$fails" -ne 0 ]; then
  printf '\nRESULT: FAIL — %s citation(s) do not resolve.\n' "$fails"
  exit 1
fi

printf '\nRESULT: PASS — every charter content anchor resolves uniquely.\n'
exit 0
