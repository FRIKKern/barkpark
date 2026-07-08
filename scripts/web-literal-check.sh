#!/usr/bin/env bash
# web-literal-check.sh — the web literal-color gate (unified-aesthetic W3.9).
#
# The `web/` demo (web/app/** + web/components/** — .tsx/.ts/.css) must consume
# the emitted design tokens via var(--color-…) / Tailwind token utilities —
# never a copied hex or hsl() channel literal. After the W3.9 sweep every web
# chrome color literal was repointed onto a role/status token; this gate keeps
# it that way: it FAILS when a NEW inline `hsl(<digit> …)` / `hsla(<digit> …)`
# or `#hex` color literal appears in a scanned file. It is the web-scoped twin
# of scripts/studio-literal-check.sh.
#
# It is deliberately narrow — colour literals only. It strips comments with a
# STRING-SAFE lexer (so a React-error ref like "#418" in a `//` comment, or a
# hex inside a `/* … */` / `{/* … */}` note, never trips it — while a hex living
# INSIDE a string, e.g. style={{background:"#ff0000"}}, is still detected) and
# honours these lead-approved allowlists (mirroring the Studio gate, W2.6):
#
#   • the web/app/globals.css BEGIN/END GENERATED: tokens block (design/emit.mjs
#     owns those hsl() literals — the single source is design/tokens.json).
#   • rgb()/rgba() function VALUES are NOT scanned literals (the gate detects
#     only hsl()/hsla()/#hex). The web/app/globals.css --scrollbar-thumb rgba()
#     tints are overlay values with no elevation/overlay role token yet — the
#     web analog of the Studio elevation/shadow exemption. Follow-up: an
#     --overlay/--scrollbar token. A hex/hsl sharing a line with an rgba() is
#     NOT masked by it — it needs its own lit-allow.
#   • a line carrying a `lit-allow:` annotation — a documented per-line resister
#     (the always-dark Obsidian graph canvas; the finder match-quality spectrum
#     legend — each earmarked for a follow-up token). A hex shown as displayed
#     CONTENT (documenting a token value in the styleguide) is allowed the same
#     way: annotate it `lit-allow`; an applied-style hex is not.
#
# SCOPE: only web/app/** + web/components/** are walked. web/lib/tokens.gen.ts
# (generated token data, mirrors the Studio tokens_gen.ex exemption) and every
# other web/ subtree are out of scope by construction.
#
# Usage: scripts/web-literal-check.sh   (check; CI + merge gate)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import os, re, sys

root = sys.argv[1]
ROOTS = [os.path.join(root, "web", "app"),
         os.path.join(root, "web", "components")]

# hsl()/hsla() with a numeric first channel, or a 3/6/8-digit #hex. rgb()/rgba()
# are intentionally NOT matched (overlay/scrollbar tints — see header).
LITERAL = re.compile(
    r"hsla?\(\s*[0-9]|#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b")
GEN_BLOCK = re.compile(
    r"BEGIN GENERATED: tokens.*?END GENERATED: tokens", re.S)

# A flagged line is allowed only if it carries an explicit per-line resister
# annotation. (Web has no --paper/--sheet token families; lit-allow is the sole
# per-line escape hatch.)
ALLOW_LINE = re.compile(r"lit-allow")


def blank(m):
    # Replace a matched span with spaces, preserving newlines so line numbers
    # (used in the failure report) stay accurate.
    return re.sub(r"[^\n]", " ", m.group(0))


def strip_comments(src, allow_line_comments):
    # A length-preserving STRING-SAFE lexer: it blanks //-line and /*…*/-block
    # comments to spaces (keeping newlines) while leaving string CONTENTS intact,
    # so a `#418` inside a comment is neutralised but a `#ff0000` inside a string
    # is still visible to LITERAL. String delimiters ", ', ` are honoured with
    # backslash escapes; template-literal ${…} interpolation is treated as opaque
    # string body (a pragmatic simplification — applied color literals never live
    # in an interpolation). CSS files have no // line comments, so `//` inside an
    # unquoted url(https://…) is not mistaken for a comment (allow_line_comments
    # is False for .css).
    out = list(src)
    i, n = 0, len(src)
    NORMAL, STR, LINE, BLOCK = 0, 1, 2, 3
    state = NORMAL
    quote = ""
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if state == NORMAL:
            if c in "\"'`":
                state, quote = STR, c
            elif c == "/" and nxt == "/" and allow_line_comments:
                state = LINE
                out[i] = " "
                if i + 1 < n:
                    out[i + 1] = " "
                i += 2
                continue
            elif c == "/" and nxt == "*":
                state = BLOCK
                out[i] = " "
                if i + 1 < n:
                    out[i + 1] = " "
                i += 2
                continue
        elif state == STR:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                state = NORMAL
        elif state == LINE:
            if c == "\n":
                state = NORMAL
            else:
                out[i] = " "
        elif state == BLOCK:
            if c == "*" and nxt == "/":
                out[i] = " "
                if i + 1 < n:
                    out[i + 1] = " "
                state = NORMAL
                i += 2
                continue
            elif c != "\n":
                out[i] = " "
        i += 1
    return "".join(out)


def scan(path):
    raw = open(path, encoding="utf-8").read()
    raw_lines = raw.split("\n")
    is_css = path.endswith(".css")
    # neutralise the emitted GENERATED block (design/emit.mjs owns it), then strip
    # comments string-safely — both length-preserving so the report line numbers
    # and the raw_lines index stay aligned. Literals are DETECTED on the stripped
    # copy; the lit-allow annotation lives in a comment, so it's read from raw.
    s = GEN_BLOCK.sub(blank, raw)
    s = strip_comments(s, allow_line_comments=not is_css)
    lines = s.split("\n")
    hits = []
    for i, stripped in enumerate(lines, 1):
        if not LITERAL.search(stripped):
            continue
        if ALLOW_LINE.search(raw_lines[i - 1]):
            continue
        hits.append((i, raw_lines[i - 1].strip()))
    return hits


failures = []
scanned = 0
for base in ROOTS:
    for dirpath, _dirs, files in os.walk(base):
        for fn in sorted(files):
            if not (fn.endswith(".tsx") or fn.endswith(".ts")
                    or fn.endswith(".css")):
                continue
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, root)
            scanned += 1
            for ln, text in scan(path):
                failures.append((rel, ln, text))

if not failures:
    print(f"web-literal-check: PASS — {scanned} web file(s) scanned, "
          f"no inline color literals.")
    sys.exit(0)

print("web-literal-check: FAILED — inline color literal(s) in web/.\n")
for rel, ln, text in sorted(failures):
    print(f"  {rel}:{ln}:  {text}")
print("\n  Consume an emitted token instead: a Tailwind token utility")
print("  (bg-primary / text-muted-text / border-border …) or var(--color-<role>)")
print("  in an inline style / arbitrary value (bg-[var(--color-surface)]). The web")
print("  roles are emitted into web/app/globals.css from design/tokens.json")
print("  (regenerate: node design/emit.mjs --write).")
print("  Genuinely un-tokenizable (an always-dark canvas, a decorative data-viz")
print("  spectrum, a displayed hex value in the styleguide)? Add a")
print("  `lit-allow: <reason>` comment on the line, earmarking a follow-up token.")
sys.exit(1)
PY
