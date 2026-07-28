#!/usr/bin/env bash
# templates-literal-check.sh — the STARTER-TEMPLATE contrast/focus literal gate
# (search-template epic, slice stw11-a11y-invariants).
#
# The sibling of scripts/studio-literal-check.sh, deliberately built on the same
# skeleton (SCAN_ROOTS + EXEMPT map + a per-line allow annotation + a named
# failure report). It is a SIBLING rather than a second SCAN_ROOTS entry on that
# script because the two scan different LANGUAGES of colour: studio chrome is
# .ex/.heex and its defect is a raw `hsl(…)`/`#hex` value; the starter templates
# are .tsx and their defect is a raw TAILWIND PALETTE UTILITY. Same idiom, a
# different detector. `design/check.mjs` contains ZERO occurrences of
# "templates" — nothing in the design pipeline has ever looked at this tree,
# which is how the literals below accumulated unseen.
#
# WHAT IT BANS, and why each ban is ARITHMETIC rather than taste. Ratios below
# were computed from templates/search-starter/app/globals.css's own --color-bg
# per theme identity (evergreen / charple / ember / fjord):
#
#   1. LIGHT-APPLYING `text-zinc-300` / `text-zinc-400` — i.e. the utility with
#      no `dark:` in its variant chain, so it paints on the LIGHT background,
#      which is the default first paint a stranger sees.
#        text-zinc-400 (#a1a1aa) on light: 2.56 / 2.42 / 2.51 / 2.50
#        text-zinc-300 (#d4d4d8) on light: 1.48 / 1.39 / 1.45 / 1.44
#      Both sit below the 4.5:1 WCAG 1.4.3 AA floor for body text AND below the
#      3:1 1.4.11 floor that even non-text has to clear. Charple is worst.
#      The replacement needs no judgment: `text-muted-text` (--color-muted-text)
#      measures 5.02 / 5.20 / 5.42 / 5.38 in light and 7.77 / 5.71 / 6.50 / 6.64
#      in dark, so ONE utility clears AA in both modes on all four identities.
#      `dark:text-zinc-400` is NOT banned — on the dark backgrounds it measures
#      7.77 / 6.29 / 7.16 / 7.29 and is fine.
#
#   2. A raw palette RING in a focus variant — `focus-visible:ring-violet-500`
#      and friends. This is a correctness ban, not a contrast one: the theme
#      declares --color-ring per identity (a green on evergreen, indigo on
#      charple, orange on ember, blue on fjord) and a hardcoded violet is
#      off-theme on all four. Use `ring-ring`. Non-focus state rings (the graph
#      accent, the selected-row ring) are NOT banned — they are semantic state
#      indicators, and re-hueing the palette is explicitly out of scope.
#
# WHAT IT DOES NOT BAN, stated so the gate does not overclaim: `text-zinc-500`
# fails AA in DARK (4.12 / 3.33 / 3.79 / 3.86) and `text-zinc-600` fails badly
# in DARK (2.57 / 2.09 / 2.37 / 2.42). Those are real and are NOT gated here —
# they are spread across template files outside stw11-a11y-invariants's file
# set, and each needs a judgment about whether the element is body text or a
# de-emphasised affordance. Filed as stw11-backlog-dark-mode-zinc-mirror.
#
# ESCAPE HATCHES, both explicit:
#   • a `templates-literal-allow: <reason>` comment on the flagged line
#   • the EXEMPT map below (whole file, each entry carrying its reason)
# Comments are stripped before detection, so prose that merely NAMES a banned
# utility (e.g. the note in app/not-found.tsx explaining the swap) never trips.
#
# CAVEAT, found by reading the built CSS rather than trusting the build's exit
# code: Tailwind's own source scanner does NOT strip comments. A comment that
# spells out `text-<palette>-<shade>` still emits that rule into the shipped
# bundle even though this gate (correctly) stays silent about it. So do not
# spell banned utilities out in template prose — describe them. This gate does
# not and cannot detect that case; it is called out here instead of pretended
# away.
#
# Usage:
#   scripts/templates-literal-check.sh             check the tree (CI + merge gate)
#   scripts/templates-literal-check.sh --selftest  prove the tripwire BITES
#
# --selftest plants nothing in the tree: it scans temp fixtures and asserts the
# exact hits, including that each allow mechanism suppresses and that the
# NOT-banned forms stay green. A gate that cannot be shown to fail is not a gate.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

MODE="check"
if [ "${1:-}" = "--selftest" ]; then
  MODE="selftest"
elif [ -n "${1:-}" ]; then
  echo "templates-literal-check: unknown argument '$1' (expected nothing or --selftest)" >&2
  exit 2
fi

python3 - "$ROOT" "$MODE" <<'PY'
import os, re, sys, tempfile

root, mode = sys.argv[1], sys.argv[2]
templates = os.path.join(root, "templates")

# The scanned template roots, relative to templates/. Mirrors
# studio-literal-check.sh's SCAN_ROOTS seam.
SCAN_ROOTS = ["search-starter", "astro-search-starter"]

# Files skipped entirely (templates/-relative), each with its reason.
EXEMPT = {
    # The Astro graph pane paints onto its OWN hardcoded dark canvas
    # (style={{ background: '#0b0d10' }}), not the theme --color-bg, so its
    # bare text-zinc-400 overlay measures 7.59:1 and is mode-independent. It is
    # not the light-mode default paint this gate is about. If that canvas ever
    # becomes theme-driven, drop this entry.
    "astro-search-starter/src/components/GraphPane.tsx",
}

# A Tailwind class token: any variant chain (`dark:`, `focus-visible:`, `md:`,
# `group-hover:`, `dark:hover:` …) followed by `<utility>-<palette>-<shade>`.
PALETTES = ("zinc|slate|gray|neutral|stone|red|orange|amber|yellow|lime|green|"
            "emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose")
TOKEN = re.compile(
    r"(?<![\w-])((?:[a-z][\w.\[\]/%.-]*:)*)(text|ring)-(" + PALETTES + r")-(\d{2,3})(?![\w-])"
)

# Shades whose LIGHT-mode contrast is arithmetically below the 3:1 floor on all
# four theme identities (see the header). Only these are banned for text.
LIGHT_FAIL_TEXT_SHADES = {"300", "400"}
FOCUS_VARIANTS = {"focus", "focus-visible", "focus-within"}

ALLOW_LINE = "templates-literal-allow"

# Only the theme-token SNAPSHOT block is neutralised wholesale (it declares raw
# hsl values by definition); .tsx files have no such block, but the constant is
# kept so the css sibling stays one edit away.
SNAPSHOT_BLOCK = re.compile(r"BEGIN SNAPSHOT: tokens.*?END SNAPSHOT: tokens", re.S)


def blank(m):
    # Replace a matched span with spaces, preserving newlines so the line
    # numbers in the failure report stay accurate.
    return re.sub(r"[^\n]", " ", m.group(0))


def strip_comments(src):
    """Blank JSX/JS comments, line-count preserving, so prose that merely NAMES
    a banned utility never trips the detector. Strings are left alone: a
    className IS a string, and that is exactly what we scan."""
    s = SNAPSHOT_BLOCK.sub(blank, src)
    s = re.sub(r"\{/\*.*?\*/\}", blank, s, flags=re.S)   # {/* JSX comment */}
    s = re.sub(r"/\*.*?\*/", blank, s, flags=re.S)       # /* block comment */
    s = re.sub(r"(?m)^([ \t]*)//.*$", lambda m: m.group(1) + " " * (len(m.group(0)) - len(m.group(1))), s)
    return s


def classify(variants, util, palette, shade):
    """Return a violation message, or None if this token is allowed.
    `variants` is the raw chain, e.g. 'dark:hover:' or ''."""
    chain = [v for v in variants.split(":") if v]
    if util == "text":
        if "dark" in chain:
            return None  # paints on the dark bg, where these shades measure 6.3-7.8
        if shade in LIGHT_FAIL_TEXT_SHADES:
            return (f"text-{palette}-{shade} paints on the LIGHT background "
                    f"(2.42-2.56:1 at shade 400, 1.39-1.48:1 at 300) — below the "
                    f"3:1 floor on all four theme identities. Use `text-muted-text`.")
        return None
    # util == "ring"
    if any(v in FOCUS_VARIANTS for v in chain):
        return (f"ring-{palette}-{shade} hardcodes a focus ring hue that is "
                f"off-theme on all four identities. Use `ring-ring` "
                f"(--color-ring).")
    return None


def scan_text(src):
    hits = []
    raw_lines = src.split("\n")
    stripped = strip_comments(src).split("\n")
    for i, line in enumerate(stripped, 1):
        rawline = raw_lines[i - 1]
        if ALLOW_LINE in rawline:
            continue
        for m in TOKEN.finditer(line):
            why = classify(m.group(1), m.group(2), m.group(3), m.group(4))
            if why:
                hits.append((i, m.group(0), why, rawline.strip()))
    return hits


def scan_file(path):
    with open(path, encoding="utf-8") as fh:
        return scan_text(fh.read())


def run_check():
    failures, scanned = [], 0
    for scan_root in SCAN_ROOTS:
        base = os.path.join(templates, scan_root)
        if not os.path.isdir(base):
            print(f"templates-literal-check: FAILED — scan root missing: "
                  f"templates/{scan_root}")
            return 1
        for dirpath, dirs, files in os.walk(base):
            dirs[:] = [d for d in dirs if d not in {"node_modules", ".next", "dist", ".astro"}]
            for fn in sorted(files):
                if not fn.endswith(".tsx"):
                    continue
                path = os.path.join(dirpath, fn)
                rel = os.path.relpath(path, templates)
                if rel in EXEMPT:
                    continue
                scanned += 1
                for ln, tok, why, text in scan_file(path):
                    failures.append((rel, ln, tok, why, text))

    if not failures:
        print(f"templates-literal-check: PASS — {scanned} starter-template .tsx "
              f"file(s) scanned, no light-mode palette text literals and no "
              f"hardcoded focus rings ({len(EXEMPT)} file(s) allowlisted).")
        return 0

    print("templates-literal-check: FAILED — raw palette literal(s) in the "
          "starter templates.\n")
    for rel, ln, tok, why, text in failures:
        print(f"  templates/{rel}:{ln}:  {tok}")
        print(f"      {why}")
        print(f"      | {text}")
    print("\n  The theme tokens are already declared in "
          "templates/search-starter/app/globals.css:")
    print("    --color-muted-text  ->  text-muted-text   (5.02-5.42 light, 5.71-7.77 dark)")
    print("    --color-ring        ->  ring-ring         (per-identity focus hue)")
    print("  Genuinely justified? Put a `templates-literal-allow: <reason>` comment on")
    print("  the line, or add the file to EXEMPT in scripts/templates-literal-check.sh")
    print("  with a reason. Both are read by a human at review time.")
    return 1


def run_selftest():
    """Prove the tripwire bites. Fixtures only — nothing is written into the
    repo tree."""
    cases = [
        # (name, source, expected hit count)
        ("bare text-zinc-400 is caught",
         '<p className="text-sm text-zinc-400">x</p>', 1),
        ("bare text-zinc-300 is caught",
         '<p className="text-zinc-300">x</p>', 1),
        ("a responsive variant does not smuggle it past",
         '<p className="md:text-zinc-400">x</p>', 1),
        ("dark:text-zinc-400 is ALLOWED (7.77-6.29:1 on the dark bg)",
         '<p className="text-muted-text dark:text-zinc-400">x</p>', 0),
        ("dark:hover:text-zinc-300 is ALLOWED",
         '<p className="dark:hover:text-zinc-300">x</p>', 0),
        ("focus-visible:ring-violet-500 is caught",
         '<a className="focus-visible:ring-2 focus-visible:ring-violet-500" />', 1),
        ("focus:ring-zinc-300 is caught",
         '<a className="focus:ring-zinc-300" />', 1),
        ("a non-focus STATE ring is allowed (semantic, out of scope)",
         '<a className="ring-1 ring-violet-300 dark:ring-violet-600/60" />', 0),
        ("ring-ring is the sanctioned replacement",
         '<a className="focus-visible:ring-2 focus-visible:ring-ring" />', 0),
        ("text-muted-text is the sanctioned replacement",
         '<p className="text-muted-text">x</p>', 0),
        ("a JSX comment NAMING the literal does not trip it",
         '{/* text-zinc-400 used to be here */}\n<p className="text-muted-text">x</p>', 0),
        ("a line comment NAMING the literal does not trip it",
         '// was text-zinc-400\n<p className="text-muted-text">x</p>', 0),
        ("an explicit per-line allow suppresses it",
         '<p className="text-zinc-400"> {/* templates-literal-allow: on a fixed dark canvas */}', 0),
        ("two violations on one line are BOTH reported",
         '<a className="text-zinc-400 focus-visible:ring-violet-500" />', 2),
    ]
    bad = 0
    for name, src, expected in cases:
        got = len(scan_text(src))
        ok = got == expected
        bad += 0 if ok else 1
        print(f"  [{'ok' if ok else 'FAIL'}] {name}  (expected {expected}, got {got})")

    # End-to-end mutation proof: the real tree is green, and a planted literal
    # in a COPY of a real scanned file reds. This is the "make the check able to
    # fail" proof — asserting a state, not an exit code.
    real = os.path.join(templates, "search-starter", "components", "finder.tsx")
    with open(real, encoding="utf-8") as fh:
        original = fh.read()
    clean_hits = len(scan_text(original))
    mutated = original.replace('text-muted-text', 'text-zinc-400', 1)
    mutated_hits = len(scan_text(mutated))
    print(f"  [{'ok' if clean_hits == 0 else 'FAIL'}] the real finder.tsx is clean "
          f"(0 hits, got {clean_hits})")
    print(f"  [{'ok' if mutated_hits == 1 else 'FAIL'}] re-adding ONE text-zinc-400 to it "
          f"reds (1 hit, got {mutated_hits})")
    bad += (clean_hits != 0) + (mutated_hits != 1)

    # And the same for a focus ring, in a temp file on disk so the file walk
    # itself — not just the matcher — is exercised.
    with tempfile.TemporaryDirectory() as td:
        p = os.path.join(td, "planted.tsx")
        with open(p, "w", encoding="utf-8") as fh:
            fh.write('<a className="focus-visible:ring-violet-500" />\n')
        disk_hits = len(scan_file(p))
    print(f"  [{'ok' if disk_hits == 1 else 'FAIL'}] a planted focus ring is caught "
          f"through the file reader (1 hit, got {disk_hits})")
    bad += disk_hits != 1

    if bad:
        print(f"\ntemplates-literal-check --selftest: FAILED — {bad} case(s) wrong. "
              f"The gate does not do what its header claims.")
        return 1
    print(f"\ntemplates-literal-check --selftest: PASS — {len(cases) + 3} cases, "
          f"including a mutation that reds and every allow mechanism that suppresses.")
    return 0


sys.exit(run_selftest() if mode == "selftest" else run_check())
PY
