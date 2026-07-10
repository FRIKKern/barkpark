#!/usr/bin/env bash
# studio-literal-check.sh — the Studio literal-color gate (unified-aesthetic W2.6).
#
# Studio chrome — api/lib/barkpark_web/ AND the plugin-owned Studio surfaces
# under api/lib/barkpark/plugins/ (heex + ex; au-r3 closed that blind spot:
# plugin LiveViews like the tickets inbox and the /admin/projects board are
# LIVE chrome too) — must consume the emitted design tokens via var(--…),
# never a copied hex / hsl() channel literal. After the W2.6 sweep every
# chrome color literal was repointed onto a role/status token; this gate
# keeps it that way: it FAILS when a NEW inline `hsl(<digit> …)` or `#hex`
# color literal appears in a scanned file.
#
# It is deliberately narrow — colour literals only. It strips comments (so PR-refs
# like "#849" and hex inside a /* … */ note never trip it) and honours these
# LEAD-APPROVED allowlists (see the au-w2-studio-sweep charter, Q1–Q3):
#
#   • the BEGIN/END GENERATED: tokens block (design/emit.mjs owns those literals)
#   • rgb()/rgba() function VALUES are not scanned literals (the gate detects only
#     hsl()/#hex) — elevation shadows / overlays pass inherently. A hex/hsl that
#     shares a line with an rgba() is NOT masked by it: it needs its own lit-allow.
#   • --paper-* / .bp-paper-* / .bp-canvas-* — the paper surface + paper editor
#     (a separate surface, explicitly out of this task's scope)
#   • --sheet-* / .sheet-* — the Sheets grid categorical CF palette (Q3)
#   • --st-* — the paper-surface status manifest, redefined in the doc sidebar
#   • a line carrying a `lit-allow:` annotation — a documented per-line resister
#     (on-color white foregrounds, bespoke shadcn zinc ladder shades with no exact
#     token — each earmarked for a follow-up token). In .ex code, `mix format`
#     relocates trailing comments, so a `lit-allow-next-line:` comment on the
#     line DIRECTLY ABOVE allows exactly the one line below it (au-r3 — used for
#     hex-looking STRING data like "#rrggbb" error examples and "PR #123" help
#     text, which are not colors at all)
#   • a `studio-literal-check: skip-begin … skip-end` region — a large contiguous
#     out-of-scope block (the paper surface/editor + Sheets grid CSS in
#     root.html.heex live under their own token systems and follow-ups)
#
# EXEMPT FILES (self-contained pages whose root tokens don't cascade, categorical
# palettes, color-picker DATA defaults, and the out-of-scope paper surface) are
# listed in EXEMPT below, each with a reason.
#
# Usage: scripts/studio-literal-check.sh   (check; CI + merge gate)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/api/lib"

python3 - "$LIB" <<'PY'
import os, re, sys

lib = sys.argv[1]

# The scanned chrome roots, relative to api/lib. barkpark/plugins joined in
# au-r3 (plugin-owned Studio LiveViews are live chrome no other gate scanned).
SCAN_ROOTS = ["barkpark_web", "barkpark/plugins"]

# Files skipped entirely (api/lib-relative), each with the lead-approved reason.
EXEMPT = {
    # NOTE: the four self-contained pages (session_html.ex login, error_html.ex,
    # status_controller.ex, sheets.html.heex reader) were REMOVED from this list
    # in au-w2-login-layout-tokens — each now de-literalizes onto design/tokens.json
    # via its OWN page-scoped BEGIN/END GENERATED block (color.authButton /
    # errorPage / statusChrome / readerInfo), and the status health-severity DATA
    # tones moved to BarkparkWeb.Studio.TokensGen.status_health/0. They are SCANNED.
    #
    # The GENERATED categorical token artifact itself — design/emit.mjs owns
    # these hex value lists (the single source presence_state.ex + sheet_grid.ex
    # now consume). Analogous to the BEGIN/END GENERATED CSS block exemption.
    "barkpark_web/studio/tokens_gen.ex",
    "barkpark_web/components/studio_components/modals.ex",  # color-picker swatch palette
    # color-picker DATA — a <input type=color> default value, not chrome theming.
    "barkpark_web/components/field_inputs.ex",
    # Out of scope — the paper surface / paper editor (its own token system).
    "barkpark_web/layouts/bulldocs.html.heex",
    "barkpark_web/controllers/paper_tasks.ex",
    "barkpark_web/controllers/paper_backlinks.ex",
    "barkpark_web/live/studio/studio_live/shared/paper.ex",
    "barkpark_web/live/studio/studio_live/paper_canvas.ex",
    "barkpark_web/live/studio/studio_live/components/paper_editor.ex",
    "barkpark_web/live/studio/studio_live/blocks.ex",  # field-color block default value
    # Terminal emulator — a terminal background is literally black.
    "barkpark_web/live/studio/tmux_live.ex",
    # Sheets conditional-format bg sanitizer — user color DATA (sanitize_bg/
    # valid_bg?) whose doctest examples are hex strings by definition, not
    # chrome theming. Analogous to the field_inputs.ex color-picker DATA.
    "barkpark/plugins/sheets/cond_format.ex",
    # The standalone sheet HTML EXPORT — a self-contained downloaded artifact:
    # the root layout's token vars never cascade into it, and its body colors
    # are the paper-surface reader family (its own token system, out of this
    # gate's scope). Analogous to the bulldocs.html.heex paper-surface entry.
    "barkpark/plugins/sheets/html.ex",
}

LITERAL = re.compile(r"hsl\(\s*[0-9]|#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b")
GEN_BLOCK = re.compile(
    r"BEGIN GENERATED: tokens.*?END GENERATED: tokens", re.S)

def blank(m):
    # Replace a matched span with spaces, preserving newlines so line numbers
    # (used in the failure report) stay accurate.
    return re.sub(r"[^\n]", " ", m.group(0))

# A flagged line is allowed if it references an allowlisted token family, or
# carries an explicit per-line resister annotation. Note: rgba() is NOT an allow
# term — a hex/hsl sharing an rgba() line is still caught unless it carries its
# own lit-allow (rgba function values themselves never match LITERAL).
ALLOW_LINE = re.compile(
    r"lit-allow|--paper|\.bp-paper|\.bp-canvas|--sheet|\.sheet-|--st-")

# `mix format` moves a trailing comment onto its own line, so .ex code can't
# carry a same-line `lit-allow:`. A `lit-allow-next-line:` marker allows
# exactly the ONE line directly below it (never a region — that's skip-begin/
# skip-end's job).
ALLOW_NEXT = "lit-allow-next-line"

SKIP_BEGIN = "studio-literal-check: skip-begin"
SKIP_END = "studio-literal-check: skip-end"

def scan(path, rel):
    raw = open(path, encoding="utf-8").read()
    raw_lines = raw.split("\n")
    # neutralise the emitted GENERATED block (design/emit.mjs owns it) + strip
    # block comments (CSS, HTML, HEEx) — line-count preserving so line numbers
    # (report) + the raw_lines index stay aligned. Literals are DETECTED on the
    # stripped copy (so hex in a /* … */ note never trips); the allow-annotation
    # and the region markers live in comments, so they're read from raw_lines.
    s = GEN_BLOCK.sub(blank, raw)
    # Neutralise the CSS block-comment delimiters (/* … */) INSIDE single-line
    # double-quoted string literals BEFORE the block-comment pass. Otherwise a
    # `/*` living in an ordinary string — e.g. `embed_templates "session_html/*"`
    # — is misread as a real comment OPENER and the DOTALL strip below blanks
    # everything down to the next `*/`, silently exempting the intervening lines
    # from the scan. We only rewrite the two-char delimiters (length-preserving),
    # so a real inline literal like `style="color:#ff0000"` (no /* inside) is
    # untouched and still detected, and a genuine CSS `/* … */` comment — which
    # lives in bare heredoc/template text, not inside a "…" string — is left for
    # the block-comment pass to strip normally.
    def _neuter_str_delims(m):
        return m.group(0).replace("/*", "/ ").replace("*/", " /")
    s = re.sub(r'"[^"\n]*"', _neuter_str_delims, s)
    s = re.sub(r"/\*.*?\*/", blank, s, flags=re.S)
    s = re.sub(r"<!--.*?-->", blank, s, flags=re.S)
    s = re.sub(r"<%!--.*?--%>", blank, s, flags=re.S)
    s = re.sub(r"<%#.*?%>", blank, s, flags=re.S)
    lines = s.split("\n")
    is_ex = rel.endswith(".ex")
    hits = []
    skipping = False
    for i, stripped in enumerate(lines, 1):
        rawline = raw_lines[i - 1]
        if SKIP_BEGIN in rawline:
            skipping = True
        if SKIP_END in rawline:
            skipping = False
            continue
        if skipping:
            continue
        # Elixir full-line comments ("# text") — strips PR-ref comments without
        # touching a CSS "#fff {" line (which starts with a hex char, not "# ").
        if is_ex and re.match(r"^\s*#(\s|$)", stripped):
            continue
        if not LITERAL.search(stripped):
            continue
        if ALLOW_LINE.search(rawline):
            continue
        if i >= 2 and ALLOW_NEXT in raw_lines[i - 2]:
            continue
        hits.append((i, rawline.strip()))
    return hits

failures = []
scanned = 0
for scan_root in SCAN_ROOTS:
    for dirpath, _dirs, files in os.walk(os.path.join(lib, scan_root)):
        for fn in sorted(files):
            if not (fn.endswith(".ex") or fn.endswith(".heex")):
                continue
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, lib)
            if rel in EXEMPT:
                continue
            scanned += 1
            for ln, text in scan(path, rel):
                failures.append((rel, ln, text))

if not failures:
    print(f"studio-literal-check: PASS — {scanned} Studio chrome file(s) scanned, "
          f"no inline color literals ({len(EXEMPT)} files allowlisted).")
    sys.exit(0)

print("studio-literal-check: FAILED — inline color literal(s) in Studio chrome.\n")
for rel, ln, text in failures:
    print(f"  {rel}:{ln}:  {text}")
print("\n  Consume an emitted token instead: var(--primary|--primary-soft|--ok-soft|")
print("  --warn|--danger-soft|--info|--bg|--text|--border|--muted-surface|…), or")
print("  hsl(var(--<role>-hsl) / <alpha>) for a custom-alpha tint. See design/tokens.json.")
print("  Genuinely un-tokenizable? Add a `lit-allow: <reason>` comment on the line")
print("  (`lit-allow-next-line: <reason>` on the line above, in formatted .ex code), or")
print("  add the file to EXEMPT in scripts/studio-literal-check.sh with a justification.")
sys.exit(1)
PY
