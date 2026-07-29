#!/usr/bin/env bash
#
# Ratchet: api/.sobelow-skips must never carry a finding that an inline
# `# sobelow_skip [...]` / `@sobelow_skip [...]` annotation already waives.
#
# WHY. A fingerprint baseline and an inline annotation are two different kinds
# of promise. The annotation says "this call site is reviewed and safe"; the
# baseline says "this exact finding existed when we drew the line". Sobelow
# binds an annotation to a function by AST ADJACENCY (sobelow.ex:418-434) —
# move the function, split the module, insert a `defp` between the comment and
# its `def`, and the binding silently breaks and the finding comes back. That
# is the moment the gate is supposed to speak. If the baseline ALSO carries the
# same finding, it swallows it and nobody ever hears. The overlap is not a
# duplicate; it is an unfalsifiable waiver.
#
# The overlap only appears when the baseline is generated WITHOUT `--skip` —
# see api/scripts/sobelow-baseline-reconcile.sh. This script is the tripwire
# that keeps that regression from being re-committed.
#
# EXIT CODES (shared by both ratchets in this file; 2 dominates 1 dominates 0)
#   0  nothing found, and every population scanned was non-empty
#   1  a real finding: an overlap, or an unbound annotation
#   2  fail-closed: usage error, or a population scanned ZERO rows. A checker
#      that finds nothing to compare has not passed — it has failed to run, and
#      saying "PASS" there is the vacuous pass this epic exists to remove.
#
# SCOPE / KNOWN LIMIT. An annotation counts here only if Sobelow itself would
# honour it: the comment form is matched with parse.ex:61's regex verbatim, so
# a near-miss like `# sobelow_skip["X"]` (no space before the bracket) is NOT
# an annotation and the baseline entry covering it stays load-bearing.
# Coverage is computed from source text, not from
# Sobelow's own AST: an annotation covers from its own line to the line before
# the next `def`/`defp` at or after it. Nested `def`s inside a covered function
# therefore END the span early, which makes this ratchet CONSERVATIVE — it can
# miss an overlap, it cannot invent one. Findings in `.heex`/`.eex` templates
# have no annotation form and are never reported.
#
# ---------------------------------------------------------------------------
# SECOND RATCHET IN THIS FILE: --binding (runs by DEFAULT).
#
# THE FAILURE MODE, REPRODUCED not argued. Displace one inline annotation by a
# single function and the overlap scan's total moves 17 -> 18 — a bare +1,
# indistinguishable from "someone added a File call" — while a REVIEWED waiver
# silently starts covering an UNREVIEWED function. Both ratchets in the repo are
# blind to that: the overlap check is span-based and baseline-driven (a waiver
# that slid onto the wrong function is still a waiver, and the baseline row it
# used to duplicate simply stops overlapping, which reads as PASS), and the
# staleness check never looks at annotations at all. A waiver that TRANSFERS is
# the same class of hole as a baseline that swallows a finding: the reviewed
# promise is attached to code nobody reviewed.
#
# So the binding check asserts, from source text alone, that every annotation is
# attached to what its author meant it to be attached to. Four predicates:
#
#   MISSPELL     a line that plainly ATTEMPTS the annotation (`sobelow_skip` or
#                `@sobelow_skip` followed by `[`) but does not match parse.ex:61
#                — at most ONE whitespace after `#`, EXACTLY one space before
#                the bracket. Sobelow silently ignores it, so the author
#                believes the site is waived and it is not.
#   DETACHED     the first non-blank / non-comment / non-`@` line after a valid
#                annotation is not a `def`/`defp`. Sobelow binds by AST
#                adjacency, so an annotation with no def under it waives
#                nothing. (`@spec` and `@doc` between annotation and def are
#                normal and are skipped — two of this repo's annotations sit
#                above an `@spec`.)
#   INDENT       the annotation's indent differs from its bound def's. That is
#                the fingerprint of a comment left behind by a move, and of a
#                comment that reads as documentation of the enclosing block
#                rather than of the def below it.
#   MULTI-CLAUSE inside a contiguous clause group (same name, same indent) that
#                carries an annotation, either (a) an UNANNOTATED clause calls
#                into a module an ANNOTATED clause also calls, or (b) the
#                ANNOTATED clause makes no remote call at all while a sibling
#                does. Sobelow binds to ONE def, so clause 1's waiver never
#                reaches clause 2 — and (b) is that same displacement seen from
#                the other side, the waiver parked on the clause with nothing to
#                waive. Deliberately NOT "every sibling needs an annotation":
#                that literal rule was built, measured at 8 rows on api/lib, and
#                every one was a trivial `, do: :ok` fallback. See the full
#                measurement at the predicate itself.
#
# KNOWN LIMITS, pinned rather than papered over — each has a --selftest case
# asserted GREEN on purpose, so the day it reds the limit has been closed and
# the case is what says so. (1) A displacement that lands a WELL-FORMED
# annotation squarely on another def at the same indent in a DIFFERENT function
# is not decidable from source text; only the waived TYPE says which def the
# waiver was for. (2) MULTI-CLAUSE keys on qualified `Module.function(` tokens,
# so an imported `send_resp/3` is invisible to it. Both close the same way, with
# the detector-to-token table sobelow-baseline-staleness-check.sh already
# DERIVES from api/deps/sobelow — tracked at
# felix-w24-bl-binding-transfer-needs-detector-map.
#
# HEREDOC STATE IS TRACKED because Sobelow's own rewrite is not comment-aware —
# parse.ex:61 is applied as a whole-file `String.replace`, so it would happily
# rewrite a `# sobelow_skip [...]` that lives inside a `@moduledoc """ … """`.
# Reading such a line as a real annotation would report a bogus DETACHED. Zero
# such lines exist today; the state machine is what keeps that true.
#
# The regex is DEFINED ONCE, in $SKIP_COMMENT_ERE below, and shared by both
# ratchets. A second transcription of parse.ex:61 in this file would be exactly
# the fork the @canonical convention exists to prevent — and it would fail in
# the UNSAFE direction, since the two copies disagreeing means one of them is
# honouring an annotation Sobelow ignores.

set -euo pipefail

usage() {
  cat <<'USAGE'
usage: sobelow-inline-overlap-check.sh [--baseline FILE] [--lib DIR]
                                       [--binding | --overlap] [--selftest]

  --baseline FILE  baseline to check (default: api/.sobelow-skips)
  --lib DIR        source tree to scan for inline annotations (default: api/lib)
  --binding        run ONLY the annotation-binding predicates (no baseline is
                   read). The default run does BOTH this and the overlap check.
  --overlap        run ONLY the baseline/inline overlap check. Exists so the
                   selftest can exercise each ratchet in isolation.
  --selftest       run the mutation fixtures that prove this checker can fail,
                   then exit; does not touch the tracked tree
USAGE
}

# parse.ex:61, transcribed ONCE for this whole file:
#   ~r/#\s?sobelow_skip (\[(\"[^"]+\"(,|, )?)+\])/
# That regex is what rewrites `# sobelow_skip [...]` into the `@sobelow_skip`
# attribute Sobelow actually reads. A LOOSER copy fails in the UNSAFE
# direction: it honours an annotation Sobelow silently ignores, calls the
# baseline entry covering that site a duplicate, and orders the deletion of a
# load-bearing waiver. Note `#\s?` really does allow `#sobelow_skip`, and the
# match is NOT anchored to the start of the line, so both are honoured here too.
# The doubled backslashes survive `awk -v`'s escape processing as single ones.
SKIP_COMMENT_ERE='#[[:space:]]?sobelow_skip \\[("[^"]+"(, ?)?)+\\]'

# A line that plainly MEANS to be an annotation, honoured or not: `sobelow_skip`
# (with or without a leading `@`, inside a comment) or a bare `@sobelow_skip`
# attribute, immediately followed by the opening bracket. Deliberately loose so
# that near-misses are CAUGHT rather than skipped — and deliberately requiring
# the bracket so that prose ABOUT annotations is not. api/lib carries 14 such
# prose lines (`# Sobelow reads \`@sobelow_skip\` from source…`,
# `Module.register_attribute(__MODULE__, :sobelow_skip, …)`, and ten
# `# @sobelow_skip — <rationale>` headers); none of them binds anything and none
# of them matches this, which is why the binding population is 59 and not 73.
SKIP_ATTEMPT_ERE='#[[:space:]]*@?[[:space:]]*sobelow_skip[[:space:]]*\\['
SKIP_ATTR_ERE='^[[:space:]]*@sobelow_skip[[:space:]]*\\['

API_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BASELINE="$API_DIR/.sobelow-skips"
LIB_DIR="$API_DIR/lib"
SELFTEST=0
BINDING_ONLY=0
OVERLAP_ONLY=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --baseline)
      [[ $# -ge 2 ]] || { echo "error: --baseline needs a value" >&2; exit 2; }
      BASELINE=$2
      shift 2
      ;;
    --lib)
      [[ $# -ge 2 ]] || { echo "error: --lib needs a value" >&2; exit 2; }
      LIB_DIR=$2
      shift 2
      ;;
    --binding)
      BINDING_ONLY=1
      shift
      ;;
    --overlap)
      OVERLAP_ONLY=1
      shift
      ;;
    --selftest)
      SELFTEST=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# Emit one row per (file, waived type, covered line span) for every inline
# annotation under $LIB_DIR. Paths are printed relative to the PARENT of
# $LIB_DIR so they match the baseline's `lib/...` keys.
scan_annotations() {
  local lib_dir=${1%/} prefix
  # Derive the baseline-shaped prefix from the directory NAME, never from an
  # absolute path: `cd .. && pwd` resolves symlinks (macOS /var -> /private/var)
  # and the strip then silently no-ops, leaving absolute keys that match no
  # baseline entry — a vacuous pass. Caught by the --selftest fixtures.
  prefix=$(basename -- "$lib_dir")
  find "$lib_dir" -type f \( -name '*.ex' -o -name '*.exs' \) -print0 |
    LC_ALL=C sort -z |
    while IFS= read -r -d '' file; do
      awk -v rel="$prefix/${file#"$lib_dir"/}" -v skip_comment="$SKIP_COMMENT_ERE" '
        { line[NR] = $0 }
        END {
          ndef = 0
          for (i = 1; i <= NR; i++)
            if (line[i] ~ /^[[:space:]]*defp?[[:space:](]/) defline[++ndef] = i

          # `skip_comment` is parse.ex:61, passed in from $SKIP_COMMENT_ERE so
          # this file holds exactly ONE transcription of it (see the header).
          for (i = 1; i <= NR; i++) {
            s = line[i]
            is_comment = (match(s, skip_comment) > 0)
            mstart = RSTART; mlen = RLENGTH
            if (!is_comment && s !~ /^[[:space:]]*@sobelow_skip[[:space:]]*\[/) continue

            # The annotation binds to the next def; its span ends where the
            # following def begins (or at end of file).
            span_end = 0
            for (k = 1; k <= ndef; k++) {
              if (defline[k] <= i) continue
              span_end = (k < ndef) ? defline[k + 1] - 1 : NR
              break
            }
            if (span_end == 0) continue   # dangling annotation, binds to nothing

            # Read the waived types out of the matched bracket only, so text
            # after a valid annotation cannot smuggle in extra types.
            rest = is_comment ? substr(s, mstart, mlen) : s
            while (match(rest, /"[^"]+"/)) {
              printf "%s\t%s\t%d\t%d\n", rel,
                     substr(rest, RSTART + 1, RLENGTH - 2), i, span_end
              rest = substr(rest, RSTART + RLENGTH)
            }
          }
        }
      ' "$file"
    done
}

# Emit one row per annotation-binding fact for every file under $LIB_DIR:
#
#   OK        <rel>  <line>  <inline|attribute>   a valid annotation, bound
#   MISSPELL  <rel>  <line>  <detail>             attempted, Sobelow ignores it
#   DETACHED  <rel>  <line>  <detail>             valid, but binds to no def
#   INDENT    <rel>  <line>  <detail>             valid, bound, wrong column
#   MULTICLAUSE <rel> <line> <detail>             sibling clause left unwaived
#
# The OK rows ARE the census — the caller counts them so a scan that reads zero
# annotations fails closed instead of printing a vacuous pass.
scan_binding() {
  local lib_dir=${1%/} prefix
  prefix=$(basename -- "$lib_dir")
  find "$lib_dir" -type f \( -name '*.ex' -o -name '*.exs' \) -print0 |
    LC_ALL=C sort -z |
    while IFS= read -r -d '' file; do
      # The two heredoc delimiters are passed IN rather than written inside the
      # awk program: the program is single-quoted, so a literal ''' would end it.
      awk -v rel="$prefix/${file#"$lib_dir"/}" \
          -v skip_comment="$SKIP_COMMENT_ERE" \
          -v skip_attempt="$SKIP_ATTEMPT_ERE" \
          -v skip_attr="$SKIP_ATTR_ERE" \
          -v hd_double='"""' \
          -v hd_single="'''" '
        function indent_of(s,   t) { t = s; sub(/[^ \t].*$/, "", t); return t }

        # `def foo(a, b) do` -> `foo`; `defp bar?(x) when …` -> `bar?`.
        function defname(s,   t) {
          t = s
          sub(/^[[:space:]]*defp?[[:space:]]*/, "", t)
          sub(/[^A-Za-z0-9_?!].*$/, "", t)
          return t
        }

        # The qualified remote calls a clause body makes, returned as a
        # space-delimited " Mod.fun Mod2.fun2 " set. Comments, module attributes
        # and heredoc bodies are excluded, so a rationale comment SAYING
        # `File.read` and a `@spec …(String.t())` are not read as calls.
        function remote_calls(from, to,   j, s, out, tok) {
          out = " "
          for (j = from; j <= to; j++) {
            if (inside[j]) continue
            s = line[j]
            if (s ~ /^[[:space:]]*#/) continue
            if (s ~ /^[[:space:]]*@/) continue
            sub(/[[:space:]]#[^"]*$/, "", s)
            while (match(s, /[A-Z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)*\.[a-z_][A-Za-z0-9_?!]*\(/)) {
              tok = substr(s, RSTART, RLENGTH - 1)
              if (index(out, " " tok " ") == 0) out = out tok " "
              s = substr(s, RSTART + RLENGTH)
            }
          }
          return out
        }

        # The module half of every call in such a set: " File.rm " -> " File ".
        function modules_of(calls,   n, parts, i, out, m) {
          out = " "
          n = split(calls, parts, " ")
          for (i = 1; i <= n; i++) {
            m = parts[i]
            sub(/\.[^.]*$/, "", m)
            if (m != "" && index(out, " " m " ") == 0) out = out m " "
          }
          return out
        }

        # Where a clause BODY stops: just before the next def, minus the trailing
        # run of blanks / comments / `@` attributes / heredoc lines, because that
        # run is the NEXT function`s doc block, not this clause`s body. Without
        # the trim, `@spec delete_session_attachments(String.t())` reads as a
        # `String.t` call inside the clause above it.
        function clause_end(k,   e) {
          e = (k < ndef) ? defline[k + 1] - 1 : NR
          while (e > defline[k] &&
                 (inside[e] || line[e] ~ /^[[:space:]]*$/ ||
                  line[e] ~ /^[[:space:]]*#/ || line[e] ~ /^[[:space:]]*@/)) e--
          return e
        }

        # Heredoc state, tracked as the file is read. Sobelow rewrites
        # parse.ex:61 over the WHOLE FILE with String.replace and never asks
        # whether it is inside a string, so a `# sobelow_skip [...]` living in a
        # `@moduledoc """ … """` would be rewritten by Sobelow AND read as a
        # real (DETACHED) annotation here. `inside[n]` marks the body lines and
        # the terminator; the opener line itself stays outside, because that is
        # where the `@doc` / sigil lives. Only the delimiter that OPENED the
        # heredoc can close it, so a quote of the other kind in the body is inert.
        {
          line[NR] = $0
          if (heredoc == "") {
            inside[NR] = 0
            if (index($0, hd_double) > 0) heredoc = hd_double
            else if (index($0, hd_single) > 0) heredoc = hd_single
          } else {
            inside[NR] = 1
            if (index($0, heredoc) > 0) heredoc = ""
          }
        }

        END {
          for (i = 1; i <= NR; i++)
            if (!inside[i] && line[i] ~ /^[[:space:]]*defp?[[:space:](]/) {
              isdef[i] = 1
              defline[++ndef] = i
            }

          # --- pass 1: classify every annotation ATTEMPT, and record which
          # --- defs a VALID annotation binds to (needed by MULTI-CLAUSE).
          nann = 0
          for (i = 1; i <= NR; i++) {
            if (inside[i]) continue
            s = line[i]

            is_attr = (s ~ skip_attr)
            is_attempt = (match(s, skip_attempt) > 0)
            if (!is_attr && !is_attempt) continue

            # An `@sobelow_skip [...]` attribute is read from the AST, so its
            # whitespace is free; only the COMMENT form must survive
            # parse.ex:61 to reach Sobelow at all.
            if (!is_attr && match(s, skip_comment) == 0) {
              printf "MISSPELL\t%s\t%d\t%s\n", rel, i,
                     "does not match parse.ex:61 — Sobelow ignores this line, so the site is NOT waived"
              continue
            }

            ann_line[++nann] = i
            ann_kind[nann] = is_attr ? "attribute" : "inline"

            # Bind to the first line under it that is not blank, not a comment,
            # not another module attribute (`@spec`/`@doc`/a stacked
            # `@sobelow_skip`) and not heredoc body.
            target = 0
            for (j = i + 1; j <= NR; j++) {
              if (inside[j]) continue
              u = line[j]
              if (u ~ /^[[:space:]]*$/) continue
              if (u ~ /^[[:space:]]*#/) continue
              if (u ~ /^[[:space:]]*@/) continue
              target = j
              break
            }
            ann_target[nann] = target
            if (target > 0 && isdef[target]) bound[target] = 1
          }

          # --- pass 2: the three predicates that need the binding map.
          for (n = 1; n <= nann; n++) {
            i = ann_line[n]
            target = ann_target[n]

            if (target == 0) {
              printf "DETACHED\t%s\t%d\t%s\n", rel, i,
                     "nothing but blanks/comments/attributes follows — this annotation binds to no def"
              continue
            }
            if (!isdef[target]) {
              printf "DETACHED\t%s\t%d\t%s\n", rel, i,
                     sprintf("binds to line %d (%s…), not a def/defp", target,
                             substr(line[target], 1, 40))
              continue
            }

            printf "OK\t%s\t%d\t%s\n", rel, i, ann_kind[n]

            if (indent_of(line[i]) != indent_of(line[target])) {
              printf "INDENT\t%s\t%d\t%s\n", rel, i,
                     sprintf("indented %d columns, but its def on line %d is at %d",
                             length(indent_of(line[i])), target,
                             length(indent_of(line[target])))
            }

          }

          # --- pass 3: MULTI-CLAUSE, over clause GROUPS rather than over
          # --- annotations, because the transfer this predicate exists to catch
          # --- can move the annotation onto EITHER side of the group.
          #
          # A clause group is a contiguous run of defs with the same name at the
          # same indent (defs at a DEEPER indent are nested — a `quote`, an
          # inner defmodule — and are skipped rather than ending the run).
          #
          # Two halves, because a waiver can slide EITHER way inside a group:
          #
          #  (4a) SHARED MODULE — an UNANNOTATED clause calls into a module that
          #       an ANNOTATED clause of the same group also calls. Two clauses
          #       both reaching `File.` with only one waived is either a clause
          #       added without its waiver, or a reorder that moved the waiver.
          #  (4b) EMPTY WAIVER — the ANNOTATED clause makes no remote call at all
          #       while a sibling does. A waiver on a clause that only
          #       pattern-matches and returns a literal waives nothing; the
          #       clause actually calling `File.rm/1` is the unwaived one. This
          #       is the displacement caught from the other side.
          #
          # It is deliberately NOT "every sibling clause needs an annotation".
          # Measured on api/lib, that literal rule reports 8 rows and all 8 are
          # trivial fallbacks — `defp unlink_env(_), do: :ok`,
          # `def read_attachment(_), do: {:error, :missing}`. Demanding a waiver
          # there would order 8 NEW blanket waivers onto code with nothing to
          # waive, which makes the posture worse, not better. Nor is it "any
          # remote call in an unannotated clause": `defp serve(conn, %ShareLink{
          # kind: "doc"})` calls `Content.get_document/4` beside a `kind:
          # "media"` clause waived for `Traversal.SendFile` — a dispatch group
          # where the clauses do genuinely different things, and the modules they
          # touch are disjoint. Both shapes were measured before being excluded.
          #
          # KNOWN LIMIT, stated rather than papered over: an IMPORTED call is not
          # a qualified token, so an `XSS.SendResp` waiver on a multi-clause
          # controller action is not clause-checked (`send_resp/3` arrives via
          # `import Plug.Conn`). Closing that needs the detector-to-function map
          # Sobelow itself holds, not source text. A hand-kept list of risky bare
          # names would be the key-list shape this epic exists to remove.
          for (k = 1; k <= ndef; k++) {
            d = defline[k]
            col = indent_of(line[d])
            prev = 0
            for (m = k - 1; m >= 1; m--) {
              if (length(indent_of(line[defline[m]])) > length(col)) continue
              prev = defline[m]
              break
            }
            if (prev && indent_of(line[prev]) == col &&
                defname(line[prev]) == defname(line[d]))
              gid[d] = gid[prev]
            else
              gid[d] = ++ngroup
            gsize[gid[d]]++
            if (bound[d]) gbound[gid[d]]++
          }

          # Per-clause call sets, and per-group the union over ANNOTATED clauses.
          for (k = 1; k <= ndef; k++) {
            d = defline[k]
            calls[d] = remote_calls(d, clause_end(k))
            g = gid[d]
            if (bound[d]) waived_mods[g] = waived_mods[g] modules_of(calls[d])
            else if (calls[d] != " ") gfree_call[g] = gfree_call[g] " " d
          }

          for (k = 1; k <= ndef; k++) {
            d = defline[k]
            g = gid[d]
            if (gsize[g] < 2 || gbound[g] == 0) continue

            if (!bound[d]) {
              # (4a) shared module with an annotated clause of the same group.
              nm = split(modules_of(calls[d]), mods, " ")
              for (mi = 1; mi <= nm; mi++) {
                if (index(waived_mods[g], " " mods[mi] " ") == 0) continue
                printf "MULTICLAUSE\t%s\t%d\t%s\n", rel, d,
                       sprintf("this clause of `%s` calls into `%s`, which an ANNOTATED clause of the same group also calls, but carries no annotation of its own — Sobelow binds to ONE def, so no waiver reaches it",
                               defname(line[d]), mods[mi])
                break
              }
              continue
            }

            # (4b) the annotated clause makes no remote call, but a sibling does.
            if (calls[d] != " " || gfree_call[g] == "") continue
            split(gfree_call[g], sib, " ")
            printf "MULTICLAUSE\t%s\t%d\t%s\n", rel, d,
                   sprintf("this ANNOTATED clause of `%s` makes no remote call — it waives nothing — while its sibling clause on line %s does. The waiver looks displaced onto the wrong clause",
                           defname(line[d]), sib[1])
          }
        }
      ' "$file"
    done
}

run_binding_check() {
  if [[ ! -d $LIB_DIR ]]; then
    echo "error: source tree not found: $LIB_DIR" >&2
    return 2
  fi

  local rows
  rows=$(mktemp "${TMPDIR:-/tmp}/sobelow-binding.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -f -- '$rows'" RETURN
  scan_binding "$LIB_DIR" > "$rows"

  local status=0
  awk -F'\t' '
    $1 == "OK" {
      ok++
      kind[$4]++
      next
    }
    {
      violations++
      printf "%s %s:%d — %s\n", $1, $2, $3, $4 > "/dev/stderr"
    }
    END {
      # Fail closed ONLY when nothing at all was examined. `ok == 0` alone is
      # the wrong test: a tree whose every annotation is malformed has ok == 0
      # and a real finding to report, and downgrading that to "the scan did not
      # run" would bury it. An empty population means no OK rows AND no
      # violations — and exit 0 is unreachable from there, so no vacuous pass
      # can hide behind this.
      if (ok == 0 && violations == 0) {
        print "error: scanned ZERO binding sobelow annotations — refusing to report a pass" > "/dev/stderr"
        exit 2
      }
      printf "scanned %d binding sobelow annotations (%d inline + %d attribute)\n",
             ok, kind["inline"], kind["attribute"]
      if (violations > 0) {
        printf "FAIL: %d annotation(s) are not bound to what their author meant.\n", violations > "/dev/stderr"
        print  "      MISSPELL: fix the line to match parse.ex:61 exactly — at most one" > "/dev/stderr"
        print  "      space after `#`, exactly one before `[`." > "/dev/stderr"
        print  "      DETACHED/INDENT: move the annotation back onto its def." > "/dev/stderr"
        print  "      MULTICLAUSE: give each clause its own annotation." > "/dev/stderr"
        exit 1
      }
      print "PASS: every sobelow annotation is bound to the def its author wrote it for"
    }
  ' "$rows" || status=$?
  return "$status"
}

run_check() {
  if [[ ! -f $BASELINE ]]; then
    echo "error: baseline not found: $BASELINE" >&2
    return 2
  fi
  if [[ ! -d $LIB_DIR ]]; then
    echo "error: source tree not found: $LIB_DIR" >&2
    return 2
  fi

  local annotations
  annotations=$(mktemp "${TMPDIR:-/tmp}/sobelow-annotations.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -f -- '$annotations'" RETURN
  scan_annotations "$LIB_DIR" > "$annotations"

  local status=0
  awk -F'\t' -v baseline="$BASELINE" '
    # Pass 1: the annotation index, keyed (file, type).
    {
      key = $1 SUBSEP $2
      n = ++count[key]
      lo[key, n] = $3
      hi[key, n] = $4
      annotations++
      next
    }
    END {
      entries = 0
      overlaps = 0
      while ((getline row < baseline) > 0) {
        if (row ~ /^[[:space:]]*$/) continue
        entries++

        # `TYPE: human description,relative/path.ex:LINE,FINGERPRINT`
        # The description may contain commas, so anchor on the tail.
        if (match(row, /,[^,]+:[0-9]+,[0-9A-Fa-f]+[[:space:]]*$/) == 0) continue
        tail = substr(row, RSTART + 1)
        sub(/,[0-9A-Fa-f]+[[:space:]]*$/, "", tail)
        split(tail, loc, ":")
        file = loc[1]
        lineno = loc[2] + 0

        colon = index(row, ":")
        if (colon == 0) continue
        type = substr(row, 1, colon - 1)

        key = file SUBSEP type
        for (n = 1; n <= count[key]; n++) {
          if (lineno < lo[key, n] || lineno > hi[key, n]) continue
          overlaps++
          printf "OVERLAP %s:%d %s — waived inline at %s:%d (annotation covers %d-%d)\n",
                 file, lineno, type, file, lo[key, n], lo[key, n], hi[key, n]
          break
        }
      }
      close(baseline)

      if (annotations == 0) {
        print "error: scanned ZERO inline sobelow annotations — refusing to report a pass" > "/dev/stderr"
        exit 2
      }
      if (entries == 0) {
        print "error: scanned ZERO baseline entries — refusing to report a pass" > "/dev/stderr"
        exit 2
      }

      printf "scanned %d baseline entries against %d inline annotation coverings\n",
             entries, annotations
      if (overlaps > 0) {
        printf "FAIL: %d baseline entries duplicate an inline waiver.\n", overlaps > "/dev/stderr"
        print  "      Regenerate with api/scripts/sobelow-baseline-reconcile.sh (which runs" > "/dev/stderr"
        print  "      `mix sobelow --skip --mark-skip-all`), or drop these lines by hand." > "/dev/stderr"
        exit 1
      }
      print "PASS: no baseline entry duplicates an inline sobelow waiver"
    }
  ' "$annotations" || status=$?
  return "$status"
}

# --- selftest: prove the checker can fail, in both directions ----------------

selftest_fixture() {
  local dir=$1
  mkdir -p "$dir/lib/barkpark"
  cat > "$dir/lib/barkpark/fixture.ex" <<'FIXTURE'
defmodule Barkpark.Fixture do
  def untouched(path) do
    File.read!(path)
  end

  # sobelow_skip ["Traversal.FileModule"]
  def waived(path) do
    File.read!(path)
  end
end
FIXTURE

  # A MALFORMED annotation: no space before the bracket. Sobelow's rewrite
  # regex (parse.ex:61) requires that space, so Sobelow ignores this line
  # entirely and the finding is NOT waived inline — which makes the baseline
  # entry covering it load-bearing. A checker that accepts this shape
  # manufactures an OVERLAP and orders that entry deleted.
  cat > "$dir/lib/barkpark/malformed.ex" <<'MALFORMED'
defmodule Barkpark.Malformed do
  # sobelow_skip["Traversal.FileModule"]
  def not_waived_at_all(path) do
    File.read!(path)
  end
end
MALFORMED
}

# One fixture module per case, each in its OWN lib tree — a tree carrying a
# violation would poison every green assertion made against it.
binding_fixture() {
  local root=$1 name=$2
  mkdir -p "$root/$name/lib/barkpark"
  cat > "$root/$name/lib/barkpark/$name.ex"
}

# Assert BOTH the exit code and that the output names the predicate we meant to
# provoke. Exit 1 alone proves nothing here: five predicates share that code, so
# a fixture can red for a reason that has nothing to do with what it tests.
expect_binding() {
  local label=$1 want=$2 needle=$3 lib=$4
  local got=0 out
  out=$("${BASH_SOURCE[0]}" --binding --lib "$lib" 2>&1) || got=$?
  if [[ $got -ne $want ]]; then
    printf 'SELFTEST FAIL: %s — expected exit %d, got %d\n%s\n' "$label" "$want" "$got" "$out" >&2
    return 1
  fi
  if [[ -n $needle ]]; then
    case $out in
      *"$needle"*) ;;
      *)
        printf 'SELFTEST FAIL: %s — exit %d was right but the output never says %s\n%s\n' \
          "$label" "$got" "$needle" "$out" >&2
        return 1
        ;;
    esac
  fi
  printf '  ok  %-40s exit %d\n' "$label" "$got"
}

expect_status() {
  local label=$1 want=$2
  shift 2
  local got=0 out
  out=$("$@" 2>&1) || got=$?
  if [[ $got -ne $want ]]; then
    printf 'SELFTEST FAIL: %s — expected exit %d, got %d\n%s\n' "$label" "$want" "$got" "$out" >&2
    return 1
  fi
  printf '  ok  %-34s exit %d\n' "$label" "$got"
}

run_selftest() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/sobelow-overlap-selftest.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf -- '$tmp'" RETURN
  selftest_fixture "$tmp"

  # The waived `File.read!` sits at line 8, inside the annotation's span.
  local overlapping="$tmp/overlapping" clean="$tmp/clean" empty="$tmp/empty"
  printf '%s\n' \
    'Traversal.FileModule: Directory Traversal in `File.read!`,lib/barkpark/fixture.ex:3,AAAAAA' \
    'Traversal.FileModule: Directory Traversal in `File.read!`,lib/barkpark/fixture.ex:8,BBBBBB' \
    > "$overlapping"
  printf '%s\n' \
    'Traversal.FileModule: Directory Traversal in `File.read!`,lib/barkpark/fixture.ex:3,AAAAAA' \
    > "$clean"
  : > "$empty"

  # The malformed annotation sits at malformed.ex:2 and its `File.read!` at
  # line 4. Sobelow ignores the annotation, so this entry is load-bearing and
  # must NOT be reported as an overlap. Under the pre-parse.ex:61 regex this
  # fixture exits 1 and orders a live waiver deleted.
  local malformed="$tmp/malformed"
  printf '%s\n' \
    'Traversal.FileModule: Directory Traversal in `File.read!`,lib/barkpark/malformed.ex:4,CCCCCC' \
    > "$malformed"

  echo "selftest: overlap mutation fixtures"
  local failures=0
  # `--overlap` so these exercise ONE ratchet. The shared fixture tree carries a
  # deliberately malformed annotation, which the binding ratchet reds on by
  # design — asserted below as its own case rather than smuggled in here.
  expect_status "baseline carries a waived finding" 1 \
    "${BASH_SOURCE[0]}" --overlap --baseline "$overlapping" --lib "$tmp/lib" || failures=1
  expect_status "same baseline minus that line" 0 \
    "${BASH_SOURCE[0]}" --overlap --baseline "$clean" --lib "$tmp/lib" || failures=1
  expect_status "malformed annotation is NOT an overlap" 0 \
    "${BASH_SOURCE[0]}" --overlap --baseline "$malformed" --lib "$tmp/lib" || failures=1
  expect_status "zero baseline entries fails closed" 2 \
    "${BASH_SOURCE[0]}" --overlap --baseline "$empty" --lib "$tmp/lib" || failures=1

  # Same baseline, annotation deleted: zero annotations must fail closed, NOT
  # pass — a checker whose second population is empty proves nothing.
  local bare="$tmp/bare"
  mkdir -p "$bare/lib/barkpark"
  grep -v 'sobelow_skip' "$tmp/lib/barkpark/fixture.ex" > "$bare/lib/barkpark/fixture.ex"
  expect_status "zero annotations fails closed" 2 \
    "${BASH_SOURCE[0]}" --overlap --baseline "$clean" --lib "$bare/lib" || failures=1

  # --- binding fixtures ------------------------------------------------------

  local b="$tmp/binding"

  binding_fixture "$b" bind_ok <<'BIND_OK'
defmodule Barkpark.BindOk do
  @moduledoc """
  Heredoc body carrying an annotation-shaped line:

      # sobelow_skip ["Traversal.FileModule"]

  Sobelow rewrites parse.ex:61 with a whole-file String.replace and is not
  comment-aware, so it would rewrite that line too — but it binds to nothing.
  Reading it as a real annotation here would report a bogus DETACHED. The
  heredoc state machine is the only thing keeping that from happening.
  """

  # sobelow_skip ["Traversal.FileModule"]
  def read_it(path) do
    File.read!(path)
  end

  # Attribute form, separated from its def by an @spec — the shape both of this
  # repo's real @sobelow_skip annotations use.
  @sobelow_skip ["Misc.BinToTerm"]
  @spec decode(binary()) :: term()
  def decode(bin) do
    :erlang.binary_to_term(bin, [:safe])
  end

  # The corpus multi-clause shape: the risky clause is waived, the trivial
  # fallback has nothing to waive and must NOT be asked for a waiver.
  # sobelow_skip ["Traversal.FileModule"]
  defp unlink(%{path: path}) when is_binary(path), do: File.rm(path)
  defp unlink(_), do: :ok
end
BIND_OK

  binding_fixture "$b" bind_misspell <<'BIND_MISSPELL'
defmodule Barkpark.BindMisspell do
  # sobelow_skip["Traversal.FileModule"]
  def read_it(path) do
    File.read!(path)
  end
end
BIND_MISSPELL

  binding_fixture "$b" bind_detached <<'BIND_DETACHED'
defmodule Barkpark.BindDetached do
  def read_it(path) do
    # sobelow_skip ["Traversal.FileModule"]
    File.read!(path)
  end
end
BIND_DETACHED

  binding_fixture "$b" bind_indent <<'BIND_INDENT'
defmodule Barkpark.BindIndent do
  defmodule Inner do
  # sobelow_skip ["Traversal.FileModule"]
    def read_it(path) do
      File.read!(path)
    end
  end
end
BIND_INDENT

  binding_fixture "$b" bind_multi_shared <<'BIND_MULTI_SHARED'
defmodule Barkpark.BindMultiShared do
  # sobelow_skip ["Traversal.FileModule"]
  defp wipe(%{a: path}) when is_binary(path), do: File.rm(path)
  defp wipe(%{b: path}) when is_binary(path), do: File.rm_rf(path)
  defp wipe(_), do: :ok
end
BIND_MULTI_SHARED

  binding_fixture "$b" bind_displaced <<'BIND_DISPLACED'
defmodule Barkpark.BindDisplaced do
  defp wipe(%{a: path}) when is_binary(path), do: File.rm(path)
  # sobelow_skip ["Traversal.FileModule"]
  defp wipe(_), do: :ok
end
BIND_DISPLACED

  # THE KNOWN BLIND SPOT, pinned so a later wave cannot claim it was covered.
  # The annotation was written for `alpha` and now sits on `beta`: well-formed,
  # correctly indented, squarely bound to a def, and in a DIFFERENT function so
  # no clause group relates them. Source text cannot tell this from a deliberate
  # waiver on `beta` — deciding it needs Sobelow's own finding set. Asserted
  # GREEN on purpose: the day this fixture reds, the limit has been closed and
  # this case is what says so.
  binding_fixture "$b" bind_transfer_blind_spot <<'BIND_BLIND'
defmodule Barkpark.BindTransferBlindSpot do
  def alpha(path) do
    File.read!(path)
  end

  # sobelow_skip ["Traversal.FileModule"]
  def beta(path) do
    File.read!(path)
  end
end
BIND_BLIND

  binding_fixture "$b" bind_none <<'BIND_NONE'
defmodule Barkpark.BindNone do
  def read_it(path) do
    File.read!(path)
  end
end
BIND_NONE

  echo "selftest: annotation-binding mutation fixtures"
  expect_binding "green control (heredoc + @spec + clauses)" 0 "PASS:" \
    "$b/bind_ok/lib" || failures=1
  expect_binding "MISSPELL — parse.ex:61 near-miss" 1 "MISSPELL" \
    "$b/bind_misspell/lib" || failures=1
  expect_binding "DETACHED — annotation on the call site" 1 "DETACHED" \
    "$b/bind_detached/lib" || failures=1
  expect_binding "INDENT — annotation left at the old column" 1 "INDENT" \
    "$b/bind_indent/lib" || failures=1
  expect_binding "MULTICLAUSE 4a — sibling shares the module" 1 "MULTICLAUSE" \
    "$b/bind_multi_shared/lib" || failures=1
  expect_binding "MULTICLAUSE 4b — waiver on the empty clause" 1 "MULTICLAUSE" \
    "$b/bind_displaced/lib" || failures=1
  expect_binding "KNOWN LIMIT: clean transfer is NOT caught" 0 "PASS:" \
    "$b/bind_transfer_blind_spot/lib" || failures=1
  expect_binding "zero annotations fails closed" 2 "ZERO binding" \
    "$b/bind_none/lib" || failures=1

  # The deployment claim, asserted rather than asserted-about: the DEFAULT
  # invocation — the exact command security.yml:160 runs — carries the binding
  # predicates. The shared fixture tree has a clean baseline for the overlap
  # ratchet and a MISSPELL for the binding one, so a default run that reds here
  # can only have reded on the binding check.
  local default_out default_rc=0
  default_out=$("${BASH_SOURCE[0]}" --baseline "$malformed" --lib "$tmp/lib" 2>&1) || default_rc=$?
  if [[ $default_rc -ne 1 ]]; then
    printf 'SELFTEST FAIL: default run must carry the binding check — expected exit 1, got %d\n%s\n' \
      "$default_rc" "$default_out" >&2
    failures=1
  else
    case $default_out in
      *MISSPELL*"no baseline entry duplicates"*|*"no baseline entry duplicates"*MISSPELL*)
        printf '  ok  %-40s exit %d\n' "default run carries BOTH ratchets" "$default_rc" ;;
      *)
        printf 'SELFTEST FAIL: default run did not show both ratchets\n%s\n' "$default_out" >&2
        failures=1 ;;
    esac
  fi

  if [[ $failures -ne 0 ]]; then
    echo "SELFTEST FAILED" >&2
    return 1
  fi
  echo "SELFTEST PASS: the overlap ratchet reds on overlap and fails closed on either empty population; each binding predicate reds on its own fixture, the green control stays green, and the default run carries both"
}

if [[ $SELFTEST -eq 1 ]]; then
  run_selftest
  exit $?
fi

# BOTH ratchets run on the DEFAULT invocation. That is deliberate and it is the
# whole deployment story for the binding check: security.yml's blocking step is
# `bash api/scripts/sobelow-inline-overlap-check.sh` with no arguments, so the
# binding predicates go blocking on arrival with ZERO edits to that workflow
# file (which another slice of this wave owns). Both are run even when the first
# one reds, because a MISSPELL and an overlap are different repairs and a
# reviewer should see both in one CI page. Exit 2 (fail-closed) dominates exit 1
# (a real finding), which dominates 0.
overall=0
note_status() {
  local s=$1
  if [[ $s -eq 2 || $overall -eq 2 ]]; then
    overall=2
  elif [[ $s -ne 0 || $overall -ne 0 ]]; then
    overall=1
  fi
}

if [[ $BINDING_ONLY -eq 0 && $OVERLAP_ONLY -eq 0 ]]; then
  status=0
  run_check || status=$?
  note_status "$status"
  status=0
  run_binding_check || status=$?
  note_status "$status"
elif [[ $BINDING_ONLY -eq 1 ]]; then
  status=0
  run_binding_check || status=$?
  note_status "$status"
else
  status=0
  run_check || status=$?
  note_status "$status"
fi

exit "$overall"
