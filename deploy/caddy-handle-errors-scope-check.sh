#!/usr/bin/env bash
# Repo-wide PREDICATE: no file may EMIT a handle_errors block with no status list.
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

while IFS= read -r f; do
  [ -f "$f" ] || continue
  if ! is_scanned_file "$f"; then skipped=$((skipped + 1)); continue; fi
  scanned=$((scanned + 1))
  # `grep || true` — a no-match exit 1 must not trip `set -e`.
  hits="$(grep -nE "$BARE_RE|$SCOPED_RE" -- "$f" 2>/dev/null || true)"
  [ -n "$hits" ] || continue
  while IFS= read -r line; do
    [ -n "$line" ] || continue
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
done < <(git ls-files)

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

if [ "${#bare_hits[@]}" -eq 0 ]; then
  echo "[handle_errors-scope] OK — no status-less handle_errors block is emitted anywhere."
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
undocumented=()
for s in "${standdown_paths[@]}"; do
  grep -qF -- "$s" "$DOC" || undocumented+=("$s")
done
if [ "${#undocumented[@]}" -gt 0 ]; then
  echo "[handle_errors-scope] FAIL — $DOC does not name ${#undocumented[@]} stood-down site(s):"
  for s in "${undocumented[@]}"; do echo "    UNDOCUMENTED  $s"; done
  echo "  A stand-down the operator docs do not mention is how 'Baked into the renderers'"
  echo "  survived. Name each site in $DOC's maintenance-page section, or take it off the"
  echo "  stand-down by fixing it."
  exit 1
fi
echo "[handle_errors-scope] doc truth arm OK — $DOC names all ${#standdown_paths[@]} stood-down site(s)."

if [ "$hard" -gt 0 ]; then
  echo "[handle_errors-scope] FAIL — $hard un-stood-down bare handle_errors emission(s)."
  echo "  A bare handle_errors catches EVERY error the site raises, including the 404 a"
  echo "  file_server raises inside an armed handle_path /sites/<slug>/*. Emit"
  echo "  the status-scoped form (502 503 504) instead. Reference: deploy/caddy/barkpark-maintenance.caddy"
  exit 1
fi

echo "[handle_errors-scope] OK — every bare emission is on the dated stand-down (expires"
echo "  $STANDDOWN_EXPIRES, closed by $STANDDOWN_ROW). It is NOT quiet: the sites are named above."
exit 0
