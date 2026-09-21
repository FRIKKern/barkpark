#!/usr/bin/env bash
# Repo-wide PREDICATE over every maintenance-handler emission. TWO arms:
#   1. no file may EMIT a handle_errors block with no status list;
#   2. no file may EMIT a maintenance `respond 503` block with no Content-Type.
#
# WHY THIS IS A PREDICATE AND NOT A LIST. deploy/site-deploy.sh's regression pin
# (search it for "A MISS ON A SPAWNED STATIC SITE IS A 404") asserts the
# status-scoped form in exactly two files: deploy/instance-deploy.sh and
# deploy/caddy/barkpark-maintenance.caddy. There are FIVE places in this repo
# that emit the maintenance handler. A pin that guards two of five reads as
# present and is blind — which is how the incident it pins survived in three
# other renderers for the whole life of the fix. This check scans EVERY TRACKED
# FILE (`git ls-files`) so a renderer nobody remembered to add to a list is
# still covered on the day it is written.
#
# THE INCIDENT (deploy/caddy/barkpark-maintenance.caddy:6-15 is the reference):
# a bare `handle_errors {` catches every error the SITE raises, including the
# 404 a `file_server` raises inside an armed `handle_path /sites/<slug>/*`. Every
# miss on every spawned static site answered the branded 503 instead of 404. The
# status list `502 503 504` is the fix and it is load-bearing.
#
# Usage:  bash deploy/caddy-handle-errors-scope-check.sh
# Exit 0 = no un-stood-down violations. Exit 1 = a violation, or a broken scan.
set -euo pipefail

ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$ROOT" ]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "$ROOT"

# ---------------------------------------------------------------------------
# DATED STAND-DOWN — NOW EMPTY. It carried four sites that were bare when this
# check landed (deploy.sh, internal/cli/setup/assets/deploy.sh,
# internal/caddyfile/caddyfile.go, docs/ops/adding-a-domain.md) because their
# fix lived in a lane that change was fenced out of. All four were FIXED by
# task-859a0dbc8ab0583e — they emit the status-scoped form now, so the list is
# empty rather than re-stood-down, and every one of them reds IMMEDIATELY if it
# ever regresses. The machinery stays for the next such hand-off; a path added
# here must carry a row id and a date, and nothing may sit on it past its
# expiry.
# ---------------------------------------------------------------------------
STANDDOWN_EXPIRES="2026-09-24"
STANDDOWN_ROW="task-d06e8a2a42f1ed2f"
standdown_paths=()

is_stood_down() {
  local p="$1" s
  # bash 3.2 (the macOS default) expands "${arr[@]}" of an EMPTY array as an
  # unbound variable under `set -u`. Answer "not stood down" before touching it.
  if [ "${#standdown_paths[@]}" -eq 0 ]; then
    return 1
  fi
  for s in "${standdown_paths[@]}"; do
    [ "$p" = "$s" ] && return 0
  done
  return 1
}

# A line is EMISSION unless it is prose. Rules, not a file list:
#   * a file whose name marks it a test (*_test.*, */testdata/*) pins whatever
#     the renderer currently does and is updated with the renderer;
#   * a line whose first non-blank characters are `#` or `//` is a comment
#     ABOUT the bare form — this check's own header would otherwise red it;
#   * in a MARKDOWN file, a match wrapped in backticks is prose NAMING the shape
#     ("still carries the bare `handle_errors {`"), while an unbacktick'd match
#     is a block an operator is being told to paste. deploy/README.md's
#     withdrawal of the old "baked into the renderers" claim has to be able to
#     say the words; docs/ops/adding-a-domain.md:41 hands out the bare block in
#     an indented code sample and must stay visible. The two specimens differ on
#     exactly this, so the rule is the difference, not a filename;
#   * a line carrying the inline marker `handle-errors-scope-check:
#     deliberate-bare` is a NEGATIVE ARM rendering the pre-fix shape on purpose
#     (deploy/caddy-handle-errors-behaviour_* boots one to measure it). It is
#     PRINTED on every run as DELIBERATE — not skipped silently — so a marker
#     used to launder a real renderer is visible in the same output as the
#     violations it is pretending not to be.
is_scanned_file() {
  case "$1" in
    *_test.*|*/testdata/*|*/__tests__/*) return 1 ;;
    *) return 0 ;;
  esac
}

BARE_RE='handle_errors[[:space:]]*\{'
MD_PROSE_RE='`handle_errors[[:space:]]*\{'
DELIBERATE_RE='handle-errors-scope-check: deliberate-bare'
SCOPED_RE='handle_errors[[:space:]]+502[[:space:]]+503[[:space:]]+504[[:space:]]*\{'
COMMENT_RE='^[[:space:]]*(#|//)'

bare_hits=()
scoped_files=()
deliberate_hits=()
scanned=0
skipped=0
# THE WORK SIDES of this arm's two count identities (task-fb55d468c7dea75b):
# tracked files REACHED, and — accumulated across every outer iteration — grep
# hit lines REACHED against grep hit lines ENUMERATED.
seen=0
hit_lines_seen=0
hit_lines_enumerated=0

# MATERIALISED, not consumed straight out of `< <(git ls-files)`: an identity
# needs an enumeration side that a short read cannot move, and a process
# substitution gives it nothing to compare against. `git ls-files` quotes any
# path containing a newline, so one tracked file is one line here.
FILE_LIST="$(git ls-files)"
file_enumerated="$(printf '%s' "$FILE_LIST" | grep -c . || true)"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  # MUT-SPLICE: scan-count-identity
  # Tallied above every `continue` in this body, so it counts tracked files
  # REACHED. `$scanned` and `$skipped` are the CLASSIFICATION, not the coverage:
  # a file the loop never reached lands in neither.
  seen=$((seen + 1))
  [ -f "$f" ] || continue
  if ! is_scanned_file "$f"; then skipped=$((skipped + 1)); continue; fi
  scanned=$((scanned + 1))
  # `grep || true` — a no-match exit 1 must not trip `set -e`.
  hits="$(grep -nE "$BARE_RE|$SCOPED_RE" -- "$f" 2>/dev/null || true)"
  [ -n "$hits" ] || continue
  hit_lines_enumerated=$((hit_lines_enumerated + $(printf '%s' "$hits" | grep -c . || true)))
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # MUT-SPLICE: hitline-count-identity
    hit_lines_seen=$((hit_lines_seen + 1))
    # `grep -n` over a SINGLE file emits `LINENO:text` — strip exactly ONE
    # field. Stripping two ate past a colon inside the text itself, which hid
    # the leading `#` of a comment line and mis-sorted a status-scoped hit into
    # the violation pile. Caught by deploy/site-deploy.sh --self-test, not by
    # reading this loop.
    body="${line#*:}"
    case "$body" in
      *[!\ ]*) : ;;
      *) continue ;;
    esac
    if printf '%s\n' "$body" | grep -qE "$COMMENT_RE"; then continue; fi
    case "$f" in
      *.md)
        # Prose naming the shape, in backticks. An unbacktick'd match in the same
        # file is still a violation — this is a per-LINE rule, not a file skip.
        if printf '%s\n' "$body" | grep -qE "$MD_PROSE_RE"; then continue; fi
        ;;
    esac
    if printf '%s\n' "$body" | grep -qF -- "$DELIBERATE_RE"; then
      deliberate_hits+=("$f:$line")
      continue
    fi
    if printf '%s\n' "$body" | grep -qE "$SCOPED_RE"; then
      scoped_files+=("$f:${line%%:*}")
    elif printf '%s\n' "$body" | grep -qE "$BARE_RE"; then
      bare_hits+=("$f:$line")
    else
      # Neither pattern survives into the extracted body: the line matched the
      # file-level grep but this loop cannot see why. That is a parse fault in
      # THIS script, not a finding about the repo — say so rather than
      # manufacturing a violation out of it.
      echo "[handle_errors-scope] FAIL (parse fault) — $f:${line%%:*} matched the file scan but"
      echo "  neither pattern matches the extracted body: <<$body>>"
      exit 1
    fi
  done <<< "$hits"
done <<< "$FILE_LIST"

# ── THE COUNT IDENTITIES (task-fb55d468c7dea75b) ─────────────────────────────
# BOTH loops above read on fd 0 — the outer from `<<< "$FILE_LIST"`, the inner
# from `<<< "$hits"`. Any body child that reads stdin (a future `git` with a
# pager, an `ssh`, a `read`, a `gh` without `</dev/null`) swallows the remaining
# rows and the loop ENDS EARLY with no error and no non-zero status. Nothing
# below could see it: `bare_hits`, `scoped_files` and `scanned` are ALL read off
# those loops, so they agree with each other on a short read, and the verdict
#     [handle_errors-scope] OK — no status-less handle_errors block is emitted anywhere.
# is exactly what a scan that reached 1 of 15884 tracked files prints. "Anywhere"
# is the assertion, and a file never reached is a Caddyfile never scanned.
#
# The positive control below is NOT this guard: it asserts that SOME scoped
# emission was seen, and deploy/instance-deploy.sh sorts early enough that a
# truncated `git ls-files` walk can satisfy it while missing everything after it.
# A control says nothing about the coverage of the population it was drawn from.
# MUT-ANCHOR: scan-count-identity
if [ "$seen" -ne "$file_enumerated" ]; then
  echo "[handle_errors-scope] FAIL (short scan) — reached $seen of $file_enumerated tracked file(s)"
  echo "  enumerated by \`git ls-files\`. The scan loop ended before the list did (a loop-body"
  echo "  child that reads stdin consumes the remaining paths silently). A partial scan must"
  echo "  never print a clean verdict in the same words as a complete one. This is a fault in"
  echo "  THIS check, not a finding about the repo."
  exit 1
fi
if [ "$hit_lines_seen" -ne "$hit_lines_enumerated" ]; then
  echo "[handle_errors-scope] FAIL (short scan) — classified $hit_lines_seen of $hit_lines_enumerated"
  echo "  grep hit line(s) across the scanned files. The per-line loop ended before its hit list"
  echo "  did; a hit line never reached is a bare emission never reported."
  exit 1
fi
# MUT-END: scan-count-identity

echo "[handle_errors-scope] scanned $scanned tracked files ($skipped skipped as tests/fixtures)"

# ---------------------------------------------------------------------------
# POSITIVE CONTROL. An absence is never caught by inspection: a scan that found
# NOTHING and a scan that is BROKEN print the same clean nothing. Before any
# empty result is believed, assert the scan reached a site we know is present.
# ---------------------------------------------------------------------------
if [ "${#scoped_files[@]}" -eq 0 ]; then
  echo "[handle_errors-scope] FAIL (broken scan) — the positive control found ZERO status-scoped"
  echo "  handle_errors emissions anywhere in the tree. deploy/instance-deploy.sh is known to"
  echo "  carry one. A clean 'no violations' from this run would be a lie about the scan, not"
  echo "  a fact about the repo."
  exit 1
fi
echo "[handle_errors-scope] control OK — ${#scoped_files[@]} status-scoped emission(s) found, the scan reaches real sites:"
for s in "${scoped_files[@]}"; do echo "    SCOPED  $s"; done

if [ "${#deliberate_hits[@]}" -gt 0 ]; then
  echo "[handle_errors-scope] ${#deliberate_hits[@]} marked-deliberate bare emission(s) (negative arms, NOT skipped silently):"
  for h in "${deliberate_hits[@]}"; do echo "    DELIBERATE  $h"; done
fi


# ---------------------------------------------------------------------------
# SECOND PREDICATE — THE Content-Type ARM (task-2ca3b45a2137aab4).
#
# The reference form calls it out in its own words (barkpark-maintenance.caddy
# :19-20): "The Content-Type header is load-bearing and NOT decoration. respond
# with a body and no Content-Type defaults the response to text/plain;
# charset=utf-8". MEASURED on caddy 2.11.4 by ARM NO-CT in
# deploy/caddy-handle-errors-behaviour-proof.sh — the browser then paints the
# raw <!doctype html> source instead of rendering the branded page.
#
# It is the SAME SHAPE as the status-list incident and it went the same way: the
# repair lived only in deploy/instance-deploy.sh, so a box provisioned by
# `bp setup` or root deploy.sh and never touched by instance-deploy.sh served
# the maintenance page as plain text indefinitely. So it gets a PREDICATE over
# every tracked file, not a list of renderers anyone must remember.
#
# THE RULE: a non-prose line emitting `respond 503` must have a
# `header Content-Type "text/html...` line within CT_LOOKBACK lines ABOVE it —
# i.e. in the same handler block, and OUTSIDE the respond block (a header
# directive nested inside `respond {` sets nothing on the response, which is why
# this looks BACKWARD rather than for presence anywhere in the file).
# ---------------------------------------------------------------------------
RESPOND_RE='respond[[:space:]]+503'
# `[^[:space:]]*` between the directive and the value, NOT `.?`: a Go renderer
# writes the line as a quoted string literal, so the source bytes are
# `header Content-Type \"text/html; charset=utf-8\"` — backslash AND quote.
# `.?` matched the Caddyfile/shell form (one bare `"`) and MISSED the Go one,
# which reported internal/caddyfile/caddyfile.go as a violation on a tree that
# had just been fixed. Caught by running the quiet arm, not by reading this line.
CT_RE='header[[:space:]]+Content-Type[[:space:]]+[^[:space:]]*text/html'
# A backticked match is PROSE naming the shape, in any file — not just markdown.
# This check's own failure messages say the words ("N maintenance `respond 503`
# emission(s) with NO Content-Type"), and a predicate that reds on its own error
# text is a predicate nobody can write a message for. The emission lines in every
# real renderer (Caddyfile, shell heredoc, Go string literal) never carry a
# backtick before the directive, so the rule separates the two populations
# without naming a single file.
PROSE_RESPOND_RE='`respond'
DELIBERATE_CT_RE='handle-errors-scope-check: deliberate-no-content-type'
CT_LOOKBACK=12

content_type_arm() {
  local f line n rest body ctx hits from
  local ct_bad=() ct_ok=() ct_deliberate=()
  # THE TWO SIDES of this arm's count identity (task-fb55d468c7dea75b).
  local ct_seen=0 ct_enumerated=0

  # ONE `git grep` over the whole index, not a grep per tracked file: the
  # status-list loop above already pays 12k process spawns and a second such
  # walk doubled this script's wall time. Same corpus (tracked files), same
  # per-line rules below. Output is `path:lineno:body`.
  hits="$(git grep -nE "$RESPOND_RE" -- . 2>/dev/null || true)"
  ct_enumerated="$(printf '%s' "$hits" | grep -c . || true)"
  if [ -n "$hits" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      # MUT-SPLICE: ct-count-identity
      # Tallied above every `continue`, so it counts hit lines REACHED. The three
      # arrays below are the CLASSIFICATION; a line never reached joins none.
      ct_seen=$((ct_seen + 1))
      f="${line%%:*}"
      rest="${line#*:}"
      n="${rest%%:*}"
      body="${rest#*:}"
      [ -f "$f" ] || continue
      is_scanned_file "$f" || continue
      # Here-strings, not `printf | grep -q`: grep -q closes the pipe at the
      # first match, the writer takes SIGPIPE (141), and `set -o pipefail` hands
      # that 141 back as the test's status — a match reported as a NON-match
      # under load. scripts/pipefail-sigpipe-scan.sh ratchets on that shape.
      if grep -qE "$COMMENT_RE" <<< "$body"; then continue; fi
      if grep -qF -- "$PROSE_RESPOND_RE" <<< "$body"; then continue; fi

      from=$(( n > CT_LOOKBACK ? n - CT_LOOKBACK : 1 ))
      # The marker may sit on the emission line itself OR on a comment line just
      # above it (a Caddyfile heredoc cannot always carry a trailing comment), so
      # it is looked for in the whole window, comments included.
      ctx="$(sed -n "${from},${n}p" "$f")"
      if grep -qF -- "$DELIBERATE_CT_RE" <<< "$ctx"; then
        ct_deliberate+=("$f:$n")
        continue
      fi
      # Comments stripped for the POSITIVE test only: a commented-out example of
      # the fixed form must not satisfy the arm for a renderer below it.
      ctx="$(sed -n "${from},${n}p" "$f" | grep -vE "$COMMENT_RE" || true)"
      if [ -n "$ctx" ] && grep -qE "$CT_RE" <<< "$ctx"; then
        ct_ok+=("$f:$n")
      else
        ct_bad+=("$f:$n")
      fi
    done <<< "$hits"
  fi

  # ── THE COUNT IDENTITY (task-fb55d468c7dea75b) ─────────────────────────────
  # `done <<< "$hits"` is fd 0. The three `grep`s and the `sed` in that body all
  # take a file or a here-string operand today; the next one added that does not
  # eats the rest of the hit list and the loop ends early, silently. `ct_ok`,
  # `ct_bad` and `ct_deliberate` are ALL read off that loop, so they agree with
  # each other on a short read — and the positive control immediately below,
  # which reds only at ZERO compliant emissions, is satisfied by the FIRST
  # compliant hit. A truncated list shrinks the control's population without
  # tripping it, and the arm then prints "every emitted respond-503 maintenance
  # block sets Content-Type" over a list it stopped reading.
  # MUT-ANCHOR: ct-count-identity
  if [ "$ct_seen" -ne "$ct_enumerated" ]; then
    echo "[handle_errors-scope] FAIL (short scan) — the Content-Type arm classified $ct_seen of"
    echo "  $ct_enumerated \`respond 503\` hit line(s) enumerated by its own git grep. The loop ended"
    echo "  before the hit list did (a loop-body child that reads stdin consumes the rest silently)."
    echo "  The positive control below cannot see this: it reds at zero compliant emissions, and a"
    echo "  truncated list still contains the first one. This is a fault in THIS check."
    exit 1
  fi
  # MUT-END: ct-count-identity

  # POSITIVE CONTROL, same reasoning as the one above: a scan that found nothing
  # and a scan that is BROKEN print the same clean nothing.
  if [ "${#ct_ok[@]}" -eq 0 ]; then
    echo "[handle_errors-scope] FAIL (broken scan) — the Content-Type arm's positive control"
    echo "  found ZERO compliant \`respond 503\` emissions anywhere. deploy/instance-deploy.sh and"
    echo "  deploy/caddy/barkpark-maintenance.caddy are both known to carry one. A clean pass here"
    echo "  would be a lie about the scan, not a fact about the repo."
    exit 1
  fi
  echo "[handle_errors-scope] content-type control OK — ${#ct_ok[@]} compliant respond-503 emission(s):"
  for s in "${ct_ok[@]}"; do echo "    CT-OK   $s"; done

  if [ "${#ct_deliberate[@]}" -gt 0 ]; then
    echo "[handle_errors-scope] ${#ct_deliberate[@]} marked-deliberate Content-Type-less emission(s) (negative arms, NOT skipped silently):"
    for s in "${ct_deliberate[@]}"; do echo "    CT-DELIBERATE  $s"; done
  fi

  if [ "${#ct_bad[@]}" -gt 0 ]; then
    echo "[handle_errors-scope] FAIL — ${#ct_bad[@]} maintenance \`respond 503\` emission(s) with NO Content-Type:"
    for s in "${ct_bad[@]}"; do echo "    NO-CONTENT-TYPE *** VIOLATION ***  $s"; done
    echo "  Caddy's \`respond\` with a body and no Content-Type answers text/plain; charset=utf-8,"
    echo "  so the branded maintenance page arrives as raw markup the browser paints verbatim."
    echo "  Emit \`header Content-Type \"text/html; charset=utf-8\"\` beside the Retry-After header,"
    echo "  OUTSIDE the respond block. Reference: deploy/caddy/barkpark-maintenance.caddy"
    exit 1
  fi
  echo "[handle_errors-scope] content-type arm OK — every emitted respond-503 maintenance block sets Content-Type."
}

if [ "${#bare_hits[@]}" -eq 0 ]; then
  echo "[handle_errors-scope] OK — no status-less handle_errors block is emitted anywhere."
  content_type_arm
  exit 0
fi

today="$(date -u +%Y-%m-%d)"
hard=0
echo "[handle_errors-scope] ${#bare_hits[@]} BARE emission(s):"
for h in "${bare_hits[@]}"; do
  p="${h%%:*}"
  if is_stood_down "$p" && [ "$today" \< "$STANDDOWN_EXPIRES" ]; then
    echo "    BARE (stood down until $STANDDOWN_EXPIRES, $STANDDOWN_ROW)  $h"
  else
    echo "    BARE *** VIOLATION ***  $h"
    hard=$((hard + 1))
  fi
done

# ---------------------------------------------------------------------------
# DOC TRUTH ARM. The stand-down is a promise that these sites are KNOWN-bare, and
# a promise nobody can read is not one. deploy/README.md carried "Baked into the
# renderers ... so every provisioned instance gets it" for the whole life of the
# fix while three of the renderers it named emitted the bare form — the prose was
# the reason nobody looked. So: every path on the stand-down above must be NAMED
# in deploy/README.md. Derived from the array, never a second hand-list, so a
# renderer added to the stand-down tomorrow reds this arm until the page says so,
# and a renderer FIXED out of the stand-down stops being required.
#
# Substring match is deliberate: naming `internal/cli/setup/assets/deploy.sh`
# also satisfies the bare `deploy.sh` entry, because that IS the twin the page is
# describing. This arm asserts the page TALKS ABOUT each site, not its wording.
# ---------------------------------------------------------------------------
DOC="deploy/README.md"
if [ ! -f "$DOC" ]; then
  echo "[handle_errors-scope] FAIL (broken scan) — $DOC is missing; the doc truth arm"
  echo "  cannot be satisfied or refuted, and a silent pass here is the exact failure"
  echo "  this arm exists to prevent."
  exit 1
fi
# An EMPTY stand-down has nothing to document, and bash 3.2 (the macOS default)
# expands "${arr[@]}" of an empty array as an unbound variable under `set -u` —
# which killed this arm mid-run instead of letting the violation report below
# print. Found by the revert arm of task-859a0dbc8ab0583e: the clean path exits
# earlier and never reaches here, so only a REAL violation ever hit it.
undocumented=()
if [ "${#standdown_paths[@]}" -gt 0 ]; then
  for s in "${standdown_paths[@]}"; do
    grep -qF -- "$s" "$DOC" || undocumented+=("$s")
  done
fi
if [ "${#undocumented[@]}" -gt 0 ]; then
  echo "[handle_errors-scope] FAIL — $DOC does not name ${#undocumented[@]} stood-down site(s):"
  for s in "${undocumented[@]}"; do echo "    UNDOCUMENTED  $s"; done
  echo "  A stand-down the operator docs do not mention is how 'Baked into the renderers'"
  echo "  survived. Name each site in $DOC's maintenance-page section, or take it off the"
  echo "  stand-down by fixing it."
  exit 1
fi
if [ "${#standdown_paths[@]}" -eq 0 ]; then
  echo "[handle_errors-scope] doc truth arm OK — the stand-down is EMPTY, so there is nothing $DOC must name."
else
  echo "[handle_errors-scope] doc truth arm OK — $DOC names all ${#standdown_paths[@]} stood-down site(s)."
fi

if [ "$hard" -gt 0 ]; then
  echo "[handle_errors-scope] FAIL — $hard un-stood-down bare handle_errors emission(s)."
  echo "  A bare handle_errors catches EVERY error the site raises, including the 404 a"
  echo "  file_server raises inside an armed handle_path /sites/<slug>/*. Emit"
  echo "  the status-scoped form (502 503 504) instead. Reference: deploy/caddy/barkpark-maintenance.caddy"
  exit 1
fi

content_type_arm
echo "[handle_errors-scope] OK — every bare emission is on the dated stand-down (expires"
echo "  $STANDDOWN_EXPIRES, closed by $STANDDOWN_ROW). It is NOT quiet: the sites are named above."
exit 0
