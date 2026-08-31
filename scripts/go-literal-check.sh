#!/usr/bin/env bash
# go-literal-check.sh — the Go (CLI/TUI) literal-color gate (unified-aesthetic W4.10).
#
# The CLI/TUI's SEMANTIC status/lifecycle/priority colours must resolve through
# internal/semrole off the generated token artifact (design/tokens.json →
# tokens_gen.go) — never an inline `lipgloss.AdaptiveColor{Light:"#…"}` or
# `lipgloss.Color("#…")` at a call site. After the W4.10 sweep every semantic
# colour literal in the scanned files was repointed onto a role (semrole.RoleColor
# / statusTone / the roleColor helpers); this gate keeps it that way: it FAILS when
# a NEW inline `#hex` colour literal appears in a scanned production file.
#
# It is the Go-scoped twin of scripts/studio-literal-check.sh / web-literal-check.sh.
# Go source has NO "displayed hex content" (no styleguide markup), so ANY inline
# colour literal outside the allowlist just fails — simpler than the CSS/markup case.
# Every lipgloss colour literal carries a `#hex` string, so keying on `#hex` catches
# both `AdaptiveColor{Light:"#…"}` and `Color("#…")`; a `lipgloss.Color(var)` (a
# variable) or a zero `AdaptiveColor{}` carries no hex and passes by construction.
#
# SCOPE (production call sites only — test files carry hex as DATA fixtures, e.g.
# a color-field default, and are out of scope by construction):
#   • cmd/barkpark/**            (the bp TUI + CLI render surface)
#   • internal/cli/**            (the WHOLE CLI: setup wizard, style_cmd, table,
#                                 seed, every command surface — au-w4-cli-ratchet)
#   • internal/taskboard/theme.go (the portrait board palette)
#   • internal/pdrender/theme.go  (the WASM-reader chrome palette — ts-w2b threaded
#                                  its 11 pd*/tone* vars onto tokens_gen.go twins;
#                                  only pdBtnFg, pure-white on-primary, stays a lit-allow)
#
# AUDIT (au-w4-cli-ratchet, 2026-07-08): when the walk was broadened from the
# narrow internal/cli/setup subtree to the whole internal/cli tree, the tree was
# audited to ZERO semantic colour literals — nothing to thread onto a role, no
# resisters, EXCEPT one color-field DATA default (seed_cmd.go's `color` fake
# value, a field value not chrome — lit-allow'd, same class as tui_render.go's
# color-picker default). Recorded here as honest evidence: the extension is a
# genuine "audited → clean" broaden, NOT a silent blanket dir exemption.
# (The `bp style` design-token sheet, internal/cli/style_cmd.go — W4.11 — is now
# scanned as part of the whole internal/cli tree, no longer a standalone entry.)
#
# ALLOWLIST — the lead-approved chrome resisters (styles.go highlight/dim/borders/
# ink/title/selection/toolbar/breadcrumb/publishBtn primary-CTA; the wizard chrome
# wzTitle/wzDim/wzSel/wzLabel/wzBorder; paper.go code fg/bg + ingress; the
# tui_render color-picker DATA default; the taskboard neutral/dim/title chrome) each
# carry a `lit-allow:` annotation pointing at the au-w4-cli-chrome-tokens follow-up.
# These are the honest-floor residual — colours with no generated Go twin (yet).
#
# It strips Go comments string-safely (a `#` in a `//` or `/* */` comment, e.g. a
# palette note or a PR ref, never trips it; a `#hex` inside a string is still
# detected).
#
# THE CORPUS FLOOR (MIN_GO_FILES, wbt-jwt-go-literal-corpus-floor): a gate that
# scans nothing PASSES, so this one refuses to. ROOTS (cmd/barkpark,
# internal/cli) are walked with os.walk, which yields zero files — and raises
# nothing — for a missing/renamed directory; FILES (the two fixed theme.go
# paths) are independent of ROOTS and still exist regardless. So a renamed or
# missing internal/cli silently fell back to scanning only those 2 fixed FILES
# and printed "PASS — 2 Go file(s) scanned", exit 0, over a scan of the whole
# CLI tree that never happened. MIN_GO_FILES closes it — see the floor's own
# failure text below. Usage: scripts/go-literal-check.sh   (check; CI + merge gate)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --selftest — the DURABLE tripwire (au-w4-cli-ratchet, AC5). Proves the gate
# actually REDs on a planted literal, repeatably, planting NOTHING in the real
# tree (a temp dir, cleaned on exit — so the self-test can never trip the real
# gate). It drives the REAL scanner via GO_LIT_SELFTEST so a future edit that
# weakens strip_comments/LITERAL/ALLOW_LINE is caught here, not just in prose.
# CI wires this right after the main check (doc-gates.yml) so it can't rot.
#
# Refuse an argument this gate does not understand first. A swallowed flag — a
# `--selftest` typo, a future rename — would silently run the ordinary check
# and report green, fabricating the tripwire's own proof.
if [ -n "${1:-}" ] && [ "$1" != "--selftest" ]; then
    echo "go-literal-check: unknown argument '$1' (expected nothing or --selftest)" >&2
    exit 2
fi

if [ "${1:-}" = "--selftest" ]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    # 1) A file with a planted #hex literal in a lipgloss call site MUST fail.
    cat >"$tmp/planted_cmd.go" <<'GO'
package demo

import "github.com/charmbracelet/lipgloss"

var planted = lipgloss.NewStyle().Foreground(lipgloss.Color("#ff0000"))
GO
    if out="$(GO_LIT_SELFTEST="$tmp/planted_cmd.go" bash "$0" 2>&1)"; then
        echo "go-literal-check --selftest: FAIL — planted #ff0000 was NOT caught (gate is blind)."
        echo "$out"
        exit 1
    fi
    if ! printf '%s' "$out" | grep -q 'planted_cmd.go:5'; then
        echo "go-literal-check --selftest: FAIL — RED did not name the planted file:line."
        echo "$out"
        exit 1
    fi
    # 2) A clean file (a variable colour, no hex) MUST pass.
    cat >"$tmp/clean_cmd.go" <<'GO'
package demo

import "github.com/charmbracelet/lipgloss"

func style(c string) lipgloss.Style { return lipgloss.NewStyle().Foreground(lipgloss.Color(c)) }
GO
    if ! GO_LIT_SELFTEST="$tmp/clean_cmd.go" bash "$0" >/dev/null 2>&1; then
        echo "go-literal-check --selftest: FAIL — a clean file was wrongly flagged (gate over-triggers)."
        exit 1
    fi
    # 3) A hex inside a comment (not a call site) MUST pass — the lexer must strip it.
    cat >"$tmp/comment_cmd.go" <<'GO'
package demo

// palette note: brand accent is #ff0000 — documented, not applied.
var x = 1
GO
    if ! GO_LIT_SELFTEST="$tmp/comment_cmd.go" bash "$0" >/dev/null 2>&1; then
        echo "go-literal-check --selftest: FAIL — a #hex in a COMMENT was flagged (comment lexer broke)."
        exit 1
    fi
    # 4) A NARROWED ROOTS directory (standing in for a renamed/missing
    #    cmd/barkpark or internal/cli) MUST NOT pass vacuously. Reproduced
    #    before MIN_GO_FILES existed: os.walk over a missing/renamed dir
    #    yields zero files and raises nothing, so only the two fixed FILES
    #    (theme.go x2) got counted and the gate printed "PASS — 2 Go file(s)
    #    scanned", exit 0, over a scan that never happened. This case is the
    #    only thing that keeps the MIN_GO_FILES floor honest.
    empty_root="$tmp/empty_root"
    mkdir -p "$empty_root"
    if out="$(GO_LIT_SELFTEST_EMPTY_ROOTS="$empty_root" bash "$0" 2>&1)"; then
        echo "go-literal-check --selftest: FAIL — narrowed ROOTS scanning only the 2 fixed FILES PASSED (vacuous green)."
        echo "$out"
        exit 1
    fi
    if ! printf '%s' "$out" | grep -q 'file(s) were scanned'; then
        echo "go-literal-check --selftest: FAIL — the narrowed-ROOTS run failed for the wrong reason."
        echo "$out"
        exit 1
    fi
    echo "go-literal-check --selftest: PASS — gate REDs on a planted literal, names file:line, passes clean + commented hex, and REFUSES to pass vacuously from narrowed ROOTS."
    exit 0
fi

python3 - "$ROOT" <<'PY'
import os, re, sys

root = sys.argv[1]
# Directory subtrees walked wholesale (recursive), plus individual files.
# GO_LIT_SELFTEST override: when set, scan ONLY that one file (the --selftest
# tripwire points the REAL scanner at a throwaway temp file — same lexer, same
# LITERAL, same allow logic — so the tripwire proves the actual gate, not a fork).
# GO_LIT_SELFTEST_EMPTY_ROOTS: the corpus-floor tripwire (wbt-jwt-go-literal-
# corpus-floor). Narrows ROOTS to one empty directory while leaving FILES at
# their normal, real, existing paths — reproducing a renamed/missing
# cmd/barkpark or internal/cli WITHOUT relocating the script itself (unlike
# GO_LIT_SELFTEST above, which replaces the whole corpus with one fixture).
_selftest = os.environ.get("GO_LIT_SELFTEST")
_selftest_empty_roots = os.environ.get("GO_LIT_SELFTEST_EMPTY_ROOTS")
if _selftest:
    ROOTS = []
    FILES = [_selftest]
else:
    ROOTS = ([_selftest_empty_roots] if _selftest_empty_roots else
              [os.path.join(root, "cmd", "barkpark"),
               os.path.join(root, "internal", "cli")])  # au-w4: whole CLI tree (subsumes setup/ + style_cmd.go)
    FILES = [os.path.join(root, "internal", "taskboard", "theme.go"),
             os.path.join(root, "internal", "pdrender", "theme.go")]  # ts-w2b: pdrender chrome threaded onto tokens_gen.go; only pdBtnFg stays a lit-allow

# A 3/6/8-digit #hex colour literal. Go has no hsl().
LITERAL = re.compile(r"#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b")

# A flagged line is allowed only if it carries an explicit per-line resister
# annotation earmarking the au-w4-cli-chrome-tokens follow-up.
ALLOW_LINE = re.compile(r"lit-allow")


def blank(m):
    return re.sub(r"[^\n]", " ", m.group(0))


def strip_comments(src):
    # A length-preserving STRING-SAFE lexer for Go: it blanks //-line and /*…*/-
    # block comments to spaces (keeping newlines) while leaving string CONTENTS
    # intact, so a `#849` inside a comment is neutralised but a `#ff0000` inside a
    # string is still visible to LITERAL. Go string delimiters ", ', and ` (raw)
    # are honoured; backslash escapes are skipped inside "…"/'…' (a raw `…`
    # backtick string has no escapes, so a stray backslash there is inert here —
    # applied colour literals never live in a raw string anyway).
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
            elif c == "/" and nxt == "/":
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
            if quote != "`" and c == "\\":
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
    s = strip_comments(raw)
    lines = s.split("\n")
    hits = []
    for i, stripped in enumerate(lines, 1):
        if not LITERAL.search(stripped):
            continue
        if ALLOW_LINE.search(raw_lines[i - 1]):
            continue
        hits.append((i, raw_lines[i - 1].strip()))
    return hits


def go_files():
    for base in ROOTS:
        for dirpath, _dirs, files in os.walk(base):
            for fn in sorted(files):
                if fn.endswith(".go") and not fn.endswith("_test.go"):
                    yield os.path.join(dirpath, fn)
    for f in FILES:
        yield f


# A gate that scans nothing PASSES. Reproduced: os.walk over a missing/renamed
# ROOTS directory yields zero files and raises nothing, so a renamed
# internal/cli fell back to scanning only the 2 fixed FILES and printed
# "PASS — 2 Go file(s) scanned", exit 0, over a scan that never happened. So
# the real run asserts a NON-ZERO, PLAUSIBLE corpus before it is allowed to
# pass. 164 Go files scanned today; the floor is set far below that so
# ordinary deletions never trip it, and far above the degenerate 2 (the fixed
# FILES alone) so that vacuous-pass path can't either.
MIN_GO_FILES = 140

failures = []
scanned = 0
for path in go_files():
    rel = os.path.relpath(path, root)
    scanned += 1
    for ln, text in scan(path):
        failures.append((rel, ln, text))

if not _selftest and scanned < MIN_GO_FILES:
    print(f"go-literal-check: FAILED — only {scanned} Go file(s) were scanned, "
          f"below the {MIN_GO_FILES}-file floor.\n")
    print(f"  Scanned roots: {', '.join(ROOTS) if ROOTS else '(none)'}")
    print("  A gate that scans nothing PASSES, so this refuses to. Either cmd/barkpark")
    print("  or internal/cli was renamed/moved, or GO_LIT_SELFTEST_EMPTY_ROOTS leaked")
    print("  into the real gate step, or the CLI tree genuinely shrank — in which case")
    print("  lower MIN_GO_FILES deliberately, in the same commit.")
    sys.exit(1)

if not failures:
    print(f"go-literal-check: PASS — {scanned} Go file(s) scanned, "
          f"no inline color literals at call sites.")
    sys.exit(0)

print("go-literal-check: FAILED — inline color literal(s) in CLI/TUI Go source.\n")
for rel, ln, text in sorted(failures):
    print(f"  {rel}:{ln}:  {text}")
print("\n  Resolve semantic colours through internal/semrole off the generated")
print("  artifact instead of an inline hex: semrole.RoleColor(role) (or the local")
print("  roleColor/statusTone helper) for a status role, semrole.LifecycleColor(state)")
print("  for a lifecycle hue — the tones are emitted into tokens_gen.go from")
print("  design/tokens.json (regenerate: node design/emit.mjs --write).")
print("  Genuinely chrome with no generated twin? Add a `lit-allow: <reason>`")
print("  comment on the line, earmarking the au-w4-cli-chrome-tokens follow-up.")
sys.exit(1)
PY
