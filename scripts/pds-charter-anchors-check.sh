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
# It WAS a ratchet over known debt: 11 cited paths were uncovered when this arm
# landed, all of them outside the deploy/PDS fence that owns this script
# (api/**, internal/**, docs/contracts/**, and `scripts/pds-*.py`, which the
# `scripts/pds-*.sh` glob misses on its extension). Hard-redding then would have
# put a permanent red on main that no PDS PR was allowed to fix, so the ceiling
# bounded the damage and named every uncovered path — which is exactly the
# worklist the .github/ repair (task-ceada0e53f6d2f1d) worked through.
#
# THAT DEBT IS NOW ZERO and the ceiling is locked at 0. The arm still reds only
# on an INCREASE, so it behaves identically; at ceiling 0 that means the first
# anchor pointed at a file that cannot trigger the check reds on the PR that
# writes it, which was the point of building the arm.
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
# them. Baselined at 11 from a run of this script on d2a4ecc02; CLOSED to 0 by
# task-ceada0e53f6d2f1d, which put all eleven into BOTH halves of
# .github/workflows/shell-harnesses.yml. Same ratchet rule as B/C/D: falling is
# progress, exceeding is the red — and at 0 the ratchet is no longer a budget
# for known debt but a hard rule: the NEXT anchor pointed at a file that cannot
# trigger this check reds on the PR that writes it.
TRIGGER_GAP_CEILING="${PDS_ANCHOR_TRIGGER_GAP_CEILING:-0}"
# The workflow whose trigger set arm E reads. Overridable so the self-test can
# point it at a fixture; never overridden in CI.
TRIGGER_WORKFLOW="${PDS_ANCHOR_WORKFLOW:-.github/workflows/shell-harnesses.yml}"

if [ ! -f "$CHARTER" ]; then
  printf 'pds-charter-anchors-check: charter not found: %s\n' "$CHARTER" >&2
  exit 2
fi

fails=0
checked=0
# THE WORK SIDE of arm A's count identity — one per anchor pair the resolution
# loop below actually REACHED, tallied before any per-anchor verdict. `checked`
# is NOT that number: it excludes the `<path>` placeholder on purpose.
seen=0

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
    # MUT-SPLICE: anchor-count-identity
    # Tallied HERE — above the placeholder skip and above every `continue` — so
    # it counts anchors REACHED, which is the only quantity a short read moves.
    seen=$((seen + 1))
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

  # ── THE COUNT IDENTITY (task-fb55d468c7dea75b) ─────────────────────────────
  # The loop above reads `$anchors` on fd 0 (`done <<< "$anchors"`). Any body
  # child that reads stdin — a future `grep` with no file operand, a `read`, an
  # `ssh`, a pager — swallows the remaining pairs and the loop ENDS EARLY with
  # no error and no non-zero status. Nothing downstream could see that: a
  # resolution loop that stopped after pair 1 of 40 raises no ROTTED and no
  # AMBIGUOUS, so `fails` stays 0 and the run prints
  #     RESULT: PASS — every charter content anchor resolves uniquely.
  # in the SAME WORDS it uses for 40 of 40. "Every" is the assertion, and an
  # anchor never reached never rots.
  #
  # `$pairs` is the enumeration side, already computed above as the non-blank
  # line count of `$anchors` (`grep -c .`); `perl` emits both fields non-empty
  # on every line it prints, so a non-blank line and a non-empty `$path` are the
  # same population. `$seen` is the work side. No body child reads fd 0 today;
  # the identity is for the one added next year, which is precisely the child no
  # fd-discipline review can name.
  # MUT-ANCHOR: anchor-count-identity
  if [ "$seen" -ne "$pairs" ]; then
    printf '\nSHORT ANCHOR SWEEP — resolved %s of %s anchor pair(s) parsed from the charter.\n' "$seen" "$pairs"
    printf '  The resolution loop ended before the parsed list did (a loop-body child that reads\n'
    printf '  stdin consumes the remaining pairs silently). A partial sweep must never print\n'
    printf '  RESULT: PASS in the same words as a complete one. This is a fault in THIS script,\n'
    printf '  not a finding about the charter.\n'
    exit 2
  fi
  # MUT-END: anchor-count-identity
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
trigger_sets=""
trigger_src=""

if [ ! -f "$TRIGGER_WORKFLOW" ]; then
  trigger_unchecked="workflow not found: $TRIGGER_WORKFLOW"
else
  trigger_out="$(printf '%s' "$anchors" \
    | perl -e '
      my $wf = shift @ARGV;
      open(my $fh, "<", $wf) or die "open: $!";
      my @lines = <$fh>; close $fh;
      my (@wfpaths, @roster, @searched, @srcinfo);
      # Roster rows are matched by SHAPE, never by filename: a line whose whole
      # content is `pds-harnesses <path>`, indented (the old in-YAML shape) or at
      # column 0 (the dispatcher-script shape #19505 moved them to).
      sub roster_rows {
        my ($txt) = @_; my @out;
        for my $l (split /\n/, $txt) { push @out, $1 if $l =~ /^\s*pds-harnesses (\S+)\s*$/ }
        return @out;
      }
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
        # The roster rows: the job-SELECTION half. Still read from the
        # workflow, because that is where they lived before #19505 and where
        # the self-test fixtures put them.
      }
      # PRECONDITION. An empty set here means the parse stopped matching, not
      # that the workflow stopped filtering — report it, never score it.
      if (!@wfpaths) { print "UNCHECKED\tthe workflow-level pull_request paths list parsed EMPTY\n"; exit }
      push @roster, roster_rows(join("", @lines));
      push @srcinfo, sprintf("%s:%d", $wf, scalar(@roster));

      # ── WHERE THE ROSTER LIVES IS DERIVED, NOT HARDCODED ────────────────
      # #19505 moved the roster rows out of the workflow into
      # scripts/shell-harness-dispatch.sh and arm E went blind for four days:
      # the regex matched nothing, the precondition fired, and the job reds
      # with no coverage verdict at all. Re-pointing this at one new filename
      # would only re-arm the same trap. So the sources are FOLLOWED from the
      # workflow: every `.sh` the workflow names (those are the scripts CI
      # actually runs — the dispatcher is one of them), then, one level
      # deeper, only files those scripts explicitly `source`/`.`. A roster
      # that moves into any script the workflow runs, or into anything such a
      # script sources, is still found. A roster that moves somewhere NONE of
      # them reaches reds as UNCHECKED naming every file that was read.
      # The tree of the WORKFLOW ITSELF is searched before the cwd: a self-test
      # that points this at a fixture workflow must resolve the scripts of that
      # fixture, never the live copies of the same names in the repo.
      # (No apostrophes below this line: the whole block is one shell-quoted
      # string, and one apostrophe ends it and spills perl into the shell.)
      my @bases = ();
      { my $d = $wf; $d =~ s{/[^/]*$}{}; $d = "." if $d eq $wf;
        push @bases, $d, "$d/..", "$d/../..", "$d/../../..", "."; }
      my %opened = ();
      my @queue = ({ txt => join("", @lines), depth => 0 });
      while (my $item = shift @queue) {
        last if scalar(@searched) >= 200;
        my @toks;
        if ($item->{depth} == 0) {
          @toks = ($item->{txt} =~ m{([A-Za-z0-9_][A-Za-z0-9_./-]*\.sh)}g);
        } elsif ($item->{depth} == 1) {
          for my $l (split /\n/, $item->{txt}) {
            push @toks, $1 if $l =~ /^\s*(?:source|\.)\s+"?([A-Za-z0-9_][A-Za-z0-9_.\/-]*\.sh)"?/;
          }
        }
        for my $tok (@toks) {
          my $p;
          for my $b (@bases) { my $c = "$b/$tok"; if (-f $c) { $p = $c; last } }
          next unless defined $p;
          my $key = $p; $key =~ s{/+}{/}g;
          next if $opened{$key}++;
          open(my $g, "<", $p) or next;
          my $body = do { local $/; <$g> }; close $g;
          push @searched, $tok;
          my @rows = roster_rows($body);
          if (@rows) { push @roster, @rows; push @srcinfo, sprintf("%s:%d", $tok, scalar(@rows)) }
          push @queue, { txt => $body, depth => $item->{depth} + 1 };
        }
      }

      # PRECONDITION, and the REGRESSION GUARD the move of #19505 earned: an
      # empty roster names every file that was read, so the next move is a
      # loud red with a worklist rather than a silent read of zero rows.
      if (!@roster) {
        my @shown = @searched > 12 ? (@searched[0..11], sprintf("(+%d more)", scalar(@searched) - 12)) : @searched;
        printf "UNCHECKED\tthe pds-harnesses roster rows parsed EMPTY — read %s and %d script(s) it names: %s\n",
          $wf, scalar(@searched), (@shown ? join(", ", @shown) : "none");
        exit;
      }
      printf "SETS\t%d\t%d\n", scalar(@wfpaths), scalar(@roster);
      printf "ROSTERSRC\t%s\n", join(" ", @srcinfo);
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

  # Here-strings, not `printf … | grep -q`: under this file's pipefail the
  # reader's early exit SIGPIPEs the producer and 141 comes back, so a MATCH
  # reads as a non-match. `$trigger_out` is arm E's whole transcript.
  if grep -q '^UNCHECKED' <<<"$trigger_out"; then
    trigger_unchecked="$(printf '%s' "$trigger_out" | sed -n 's/^UNCHECKED\t//p' | head -1)"
  elif ! grep -q '^SETS' <<<"$trigger_out"; then
    trigger_unchecked="the trigger parse produced no verdict line: $trigger_out"
  else
    trigger_gap_list="$(printf '%s' "$trigger_out" | grep '^GAP' | cut -f2- || true)"
    trigger_gap="$(printf '%s' "$trigger_gap_list" | grep -c . || true)"
    # The two set sizes and the per-file roster provenance, printed so a READER
    # of a green run can see WHICH file the roster came from. A verdict scored
    # off a roster nobody can locate is the failure this arm already had once.
    trigger_sets="$(printf '%s' "$trigger_out" | sed -n 's/^SETS\t/SETS /p' | tr '\t' ' ' | head -1)"
    trigger_src="$(printf '%s' "$trigger_out" | sed -n 's/^ROSTERSRC\t//p' | head -1)"
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
  printf '                      %s · roster from %s\n' "$trigger_sets" "$trigger_src"
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
