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
#   • a line carrying a `lit-allow:` annotation — a documented per-line resister.
#     Currently ZERO remain: the finder match-quality spectrum legend was
#     resolved in au-w3-finder-spectrum (emitted color.matchQuality token) and
#     the always-dark Obsidian graph canvas in au-w3-graph-canvas-token (emitted
#     color.graphCanvas → bg-graph-canvas). A hex shown as displayed
#     CONTENT (documenting a token value in the styleguide) is allowed the same
#     way: annotate it `lit-allow`; an applied-style hex is not.
#
# SCOPE: only web/app/** + web/components/** are walked. web/lib/tokens.gen.ts
# (generated token data, mirrors the Studio tokens_gen.ex exemption) and every
# other web/ subtree are out of scope by construction.
#
# THE lit-allow MARKER IS COMMENT-POSITION ONLY (cgsi-s4). It is read from a
# comments-only projection of the file, never from the raw line, so a marker that
# is not a comment cannot waive anything: a JSX attribute string
# `<div data-x="lit-allow" style={{background:"#ff0000"}} />` and a CSS class
# `.lit-allow { color: #ff0000; }` both FAIL (both were green before — a waiver
# spoofable from a string is not a waiver). A `// lit-allow: …` or
# `/* lit-allow: … */` on the flagged line still waives, as documented above.
#
# THE CORPUS FLOOR (MIN_WEB_FILES, cgsi-s4): a gate that scans nothing PASSES,
# so this one refuses to — see the floor's own failure text below.
#
# Usage: scripts/web-literal-check.sh              (check; CI + merge gate)
#        scripts/web-literal-check.sh --selftest   (prove the gate can FAIL)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

MODE="check"
if [ "${1:-}" = "--selftest" ]; then
    MODE="selftest"
elif [ -n "${1:-}" ]; then
    echo "web-literal-check: unknown argument '$1' (expected nothing or --selftest)" >&2
    exit 2
fi

# --selftest — the DURABLE tripwire (cgsi-s4; the shape is go-literal-check.sh's,
# which has carried it since au-w4-cli-ratchet AC5). It proves the gate actually
# REDs on a planted literal, repeatably, planting NOTHING in the real tree (a
# temp dir, cleaned on exit — so the self-test can never trip the real gate). It
# drives the REAL scanner via WEB_LIT_SELFTEST, so a future edit that weakens
# LITERAL / strip_comments / the GEN_BLOCK span / the comment-position allow rule
# is caught HERE rather than in prose. The last case is the floor's own keeper:
# a RELOCATED copy scanning zero files must RED, not print a vacuous PASS.
# NOTE: `--selftest` is an EXPLICIT mode, never the default — a script whose
# default run is its own self-test fabricates its own proof — and any other
# argument exits 2 above, so a flag typo cannot silently become "check".
if [ "$MODE" = "selftest" ]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    fail() {
        echo "web-literal-check --selftest: FAIL — $1"
        shift
        if [ "$#" -gt 0 ]; then echo "$*"; fi
        exit 1
    }

    # 1) A planted #hex in an applied .tsx style MUST fail, naming file:line.
    cat >"$tmp/planted.tsx" <<'TSX'
export function Planted() {
  return <div style={{background:"#ff0000"}}>planted</div>;
}
TSX
    if out="$(WEB_LIT_SELFTEST="$tmp/planted.tsx" bash "$0" 2>&1)"; then
        fail "planted #ff0000 was NOT caught (gate is blind)." "$out"
    fi
    grep -q 'planted.tsx:2' <<<"$out" \
        || fail "RED did not name the planted file:line." "$out"

    # 2) A clean token-consuming file MUST pass.
    cat >"$tmp/clean.tsx" <<'TSX'
export function Clean() {
  return <div style={{background:"var(--color-surface)"}} className="bg-primary" />;
}
TSX
    WEB_LIT_SELFTEST="$tmp/clean.tsx" bash "$0" >/dev/null 2>&1 \
        || fail "a clean var(--color-…) file was wrongly flagged (gate over-triggers)."

    # 3) A hex inside a `//` and inside a `{/* … */}` comment MUST pass.
    cat >"$tmp/comment.tsx" <<'TSX'
// palette note: the brand accent used to be #ff0000 — documented, not applied.
export function Noted() {
  {/* legacy: #00ff00 was the old success green */}
  return <div className="bg-success" />;
}
TSX
    WEB_LIT_SELFTEST="$tmp/comment.tsx" bash "$0" >/dev/null 2>&1 \
        || fail "a #hex in a COMMENT was flagged (comment lexer broke)."

    # 4) .css: a block-comment hex passes, and a bare `url(https://…)` on a line
    #    is NOT a line comment (allow_line_comments=False for .css).
    cat >"$tmp/notes.css" <<'CSS'
/* palette note: #ff0000 was the old brand accent */
.hero { background: url(https://example.com/hero.png) center / cover; }
CSS
    WEB_LIT_SELFTEST="$tmp/notes.css" bash "$0" >/dev/null 2>&1 \
        || fail "a .css block-comment hex or a url(https://…) line was flagged."

    # 4b) …and because `//` is NOT a comment in .css, a hex AFTER a url() on the
    #     same line is still seen. (If .css ever gained line comments, the url's
    #     `//` would blank the rest of the line and hide this literal.)
    cat >"$tmp/url_then_hex.css" <<'CSS'
.hero { background: url(https://example.com/hero.png); color: #ff0000; }
CSS
    if out="$(WEB_LIT_SELFTEST="$tmp/url_then_hex.css" bash "$0" 2>&1)"; then
        fail "a #hex after url(https://…) on a .css line was NOT caught (// treated as a comment)." "$out"
    fi

    # 5) A hsl() INSIDE the BEGIN/END GENERATED span is design/emit.mjs's — passes.
    cat >"$tmp/generated_ok.css" <<'CSS'
:root {
  /* BEGIN GENERATED: tokens */
  --color-primary: hsl(210 90% 50%);
  /* END GENERATED: tokens */
}
CSS
    WEB_LIT_SELFTEST="$tmp/generated_ok.css" bash "$0" >/dev/null 2>&1 \
        || fail "an hsl() INSIDE the GENERATED tokens block was flagged."

    # 6) …and a hsl() just OUTSIDE that span MUST fail — the block exempts its own
    #    span only, never the rest of the file.
    cat >"$tmp/generated_edge.css" <<'CSS'
:root {
  /* BEGIN GENERATED: tokens */
  --color-primary: hsl(210 90% 50%);
  /* END GENERATED: tokens */
}
.hand-written { color: hsl(0 100% 50%); }
CSS
    if out="$(WEB_LIT_SELFTEST="$tmp/generated_edge.css" bash "$0" 2>&1)"; then
        fail "an hsl() just OUTSIDE the GENERATED block was NOT caught." "$out"
    fi
    grep -q 'generated_edge.css:6' <<<"$out" \
        || fail "RED did not name the line just outside the GENERATED block." "$out"

    # 7) A lit-allow spoofed from a JSX ATTRIBUTE STRING MUST fail (cgsi-s4).
    cat >"$tmp/spoof_attr.tsx" <<'TSX'
export function Spoof() {
  return <div data-x="lit-allow" style={{background:"#ff0000"}} />;
}
TSX
    if out="$(WEB_LIT_SELFTEST="$tmp/spoof_attr.tsx" bash "$0" 2>&1)"; then
        fail "a lit-allow in a JSX ATTRIBUTE STRING waived a live #ff0000 (waiver is spoofable)." "$out"
    fi

    # 8) A lit-allow spoofed from a CSS CLASS NAME MUST fail (cgsi-s4).
    cat >"$tmp/spoof_class.css" <<'CSS'
.lit-allow { color: #ff0000; }
CSS
    if out="$(WEB_LIT_SELFTEST="$tmp/spoof_class.css" bash "$0" 2>&1)"; then
        fail "a lit-allow CSS CLASS NAME waived a live #ff0000 (waiver is spoofable)." "$out"
    fi

    # 9) …while the GENUINE comment-position waivers still pass, both flavours.
    cat >"$tmp/allow_block.css" <<'CSS'
.canvas { background: #101014; /* lit-allow: always-dark graph canvas, token pending */ }
CSS
    WEB_LIT_SELFTEST="$tmp/allow_block.css" bash "$0" >/dev/null 2>&1 \
        || fail "a genuine /* lit-allow: … */ block-comment waiver stopped working (false red)."
    cat >"$tmp/allow_line.tsx" <<'TSX'
export function Allowed() {
  return <div style={{background:"#101014"}} />; // lit-allow: always-dark canvas, token pending
}
TSX
    WEB_LIT_SELFTEST="$tmp/allow_line.tsx" bash "$0" >/dev/null 2>&1 \
        || fail "a genuine // lit-allow: … line-comment waiver stopped working (false red)."

    # 10) A RELOCATED copy of this script MUST NOT pass vacuously. Reproduced on
    #     origin/main: ROOT comes from `dirname $0`, so a copy outside the repo
    #     finds no web/app, scanned 0 files and printed
    #     "PASS — 0 web file(s) scanned" with exit 0. MIN_WEB_FILES closes it,
    #     and this case is the only thing that keeps the floor honest.
    mkdir -p "$tmp/relocated/scripts"
    cp "$0" "$tmp/relocated/scripts/web-literal-check.sh"
    if out="$(bash "$tmp/relocated/scripts/web-literal-check.sh" 2>&1)"; then
        fail "a RELOCATED copy scanning no files PASSED (vacuous green)." "$out"
    fi
    grep -q 'file floor' <<<"$out" \
        || fail "the zero-file RED did not name the corpus floor." "$out"

    echo "web-literal-check --selftest: PASS — gate REDs on a planted literal (naming file:line), on"
    echo "  both lit-allow spoofs, on an hsl() outside the GENERATED block and on a zero-file corpus;"
    echo "  passes clean token usage, commented hexes, .css url()/comments and genuine lit-allow waivers."
    exit 0
fi

python3 - "$ROOT" <<'PY'
import os, re, sys

root = sys.argv[1]
# WEB_LIT_SELFTEST override: when set, scan ONLY that one file (the --selftest
# tripwire points the REAL scanner at a throwaway temp file — same lexer, same
# LITERAL, same GEN_BLOCK, same allow logic — so the tripwire proves the actual
# gate, not a fork). The corpus floor is skipped for that single-file mode, and
# only for it.
SELFTEST = os.environ.get("WEB_LIT_SELFTEST")
ROOTS = [os.path.join(root, "web", "app"),
         os.path.join(root, "web", "components")]

# hsl()/hsla() with a numeric first channel, or a 3/6/8-digit #hex. rgb()/rgba()
# are intentionally NOT matched (overlay/scrollbar tints — see header).
LITERAL = re.compile(
    r"hsla?\(\s*[0-9]|#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b")
GEN_BLOCK = re.compile(
    r"BEGIN GENERATED: tokens.*?END GENERATED: tokens", re.S)

# A flagged line is allowed only if it carries an explicit per-line resister
# annotation IN A COMMENT. (Web has no --paper/--sheet token families; lit-allow
# is the sole per-line escape hatch — and unlike the Studio gate's token families,
# which are code-position by design, this marker is documentation, so it has no
# business being read out of code.) See comments_only() for the position rule.
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


def comments_only(src, stripped):
    # The COMMENTS-ONLY projection of a file: every character the lexer blanked
    # (i.e. comment text) kept as-is, everything else replaced by a space, with
    # newlines preserved so the line index still lines up. strip_comments is
    # length-preserving, so this costs one zip.
    #
    # This is what the lit-allow waiver is searched in. Reading the waiver off the
    # RAW line (what this gate did before cgsi-s4) made it spoofable from any
    # code position — a JSX attribute `data-x="lit-allow"` or a CSS class
    # `.lit-allow` silently waived a live #ff0000 on its line. The lexer already
    # knows precisely which characters are commentary; the allow decision now uses
    # that knowledge instead of throwing it away.
    return "".join("\n" if a == "\n" else (a if a != b else " ")
                   for a, b in zip(src, stripped))


def scan(path):
    raw = open(path, encoding="utf-8").read()
    raw_lines = raw.split("\n")
    is_css = path.endswith(".css")
    # neutralise the emitted GENERATED block (design/emit.mjs owns it), then strip
    # comments string-safely — both length-preserving so the report line numbers
    # and the raw_lines index stay aligned. Literals are DETECTED on the stripped
    # copy; the lit-allow annotation must live in a COMMENT, so it is read from
    # the comments-only projection of the same (post-GENERATED-block) source.
    g = GEN_BLOCK.sub(blank, raw)
    s = strip_comments(g, allow_line_comments=not is_css)
    lines = s.split("\n")
    allow_lines = comments_only(g, s).split("\n")
    hits = []
    for i, stripped in enumerate(lines, 1):
        if not LITERAL.search(stripped):
            continue
        if ALLOW_LINE.search(allow_lines[i - 1]):
            continue
        hits.append((i, raw_lines[i - 1].strip()))
    return hits


def corpus():
    if SELFTEST:
        yield SELFTEST
        return
    for base in ROOTS:
        for dirpath, _dirs, files in os.walk(base):
            for fn in sorted(files):
                if (fn.endswith(".tsx") or fn.endswith(".ts")
                        or fn.endswith(".css")):
                    yield os.path.join(dirpath, fn)


# THE CORPUS FLOOR (cgsi-s4). A relocated copy (ROOT comes from `dirname $0`)
# finds no web/app and printed "PASS — 0 web file(s) scanned" with exit 0 —
# reproduced on origin/main. So the real run asserts a NON-ZERO, PLAUSIBLE corpus
# before it is allowed to pass. HONEST LIMIT: the floor is skipped in
# WEB_LIT_SELFTEST single-file mode (that mode scans exactly one fixture on
# purpose), so it does NOT catch that env var leaking into the real CI step —
# only the gate step keeping its environment clean does.
# 55 files scanned today (re-measured spd-w19r; the comment said 56 when the
# floor landed), and the corpus is flat — 55 two thousand commits ago as well.
# The floor sits far below that so ordinary deletions never trip it, and far
# above 0/1 so neither vacuous-green path can.
# The --selftest relocated-copy case is what keeps this floor honest.
MIN_WEB_FILES = 30

failures = []
scanned = 0
for path in corpus():
    rel = os.path.relpath(path, root)
    scanned += 1
    for ln, text in scan(path):
        failures.append((rel, ln, text))

if not SELFTEST and scanned < MIN_WEB_FILES:
    print(f"web-literal-check: FAILED — only {scanned} web file(s) were scanned, "
          f"below the {MIN_WEB_FILES}-file floor.\n")
    print(f"  Scanned roots: {', '.join(ROOTS)}")
    print("  A gate that scans nothing PASSES, so this refuses to. Either the script was")
    print("  run from a relocated copy (ROOT comes from `dirname $0`), or WEB_LIT_SELFTEST")
    print("  leaked into the real gate step, or the web chrome tree genuinely shrank — in")
    print("  which case lower MIN_WEB_FILES deliberately, in the same commit.")
    sys.exit(1)

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
