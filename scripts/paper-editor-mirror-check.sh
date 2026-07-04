#!/usr/bin/env bash
# paper-editor-mirror-check — guard the paper-editor style mirrors + the
# generated paper-surface token layer.
#
# TWO invariants, one script:
#
#   Part 1/2 — .bp-canvas-* lockstep. The Studio paper editor's node-view chrome
#   (.bp-canvas-*) is styled in TWO places that must stay in lockstep:
#     1. api/lib/barkpark_web/layouts/root.html.heex   (Studio inline <style>)
#     2. api/assets/paper-editor/src/styles.css        (the de-scoped bundle)
#   When a rule lands in one mirror but not the other, edit-mode-at-rest silently
#   diverges from view mode (hyphens/callout/list-marker drift, cycles 57-58).
#   This tripwire fails when a .bp-canvas-* class exists in one mirror but not the
#   other, unless the asymmetry is in the documented allowlist.
#   NOTE: paper-surface.css is deliberately NOT unioned into the heex side —
#   per its own header, .bp-canvas-* node-view chrome is Studio-shell and stays
#   in root.html.heex (a canvas rule landing in the portable source is itself
#   drift this check should surface).
#   (The old "part 2" single-owner --bp-* sentinel moved to
#   test/barkpark/portable_doc/render/stylesheet_test.exs, which pins the same
#   invariant compile-coupled; it is not duplicated here.)
#
#   Part 3 — generated paper-surface token layer. The `--paper-*` theme tokens +
#   `--bp-*` typography tokens in the embedder bundle (styles.css) are GENERATED
#   from the ONE canonical source (api/assets/paper-surface/paper-surface.css)
#   via a deterministic de-scoping transform, and live between exact BEGIN/END
#   GENERATED markers. Default mode regenerates in memory and byte-compares
#   against the marked section (fails with a --write hint on drift). `--write`
#   rewrites the marked section in place. This makes the bundle track the source:
#   a token added/changed in paper-surface.css (e.g. wave-2 --bp-tone-* light+dark
#   values) can't be silently forgotten in the standalone bundle.
#
# Usage:
#   scripts/paper-editor-mirror-check.sh            # check (CI + the merge gate)
#   scripts/paper-editor-mirror-check.sh --write    # regenerate the token layer
set -euo pipefail

MODE="check"
if [[ "${1:-}" == "--write" ]]; then
  MODE="write"
elif [[ -n "${1:-}" ]]; then
  echo "paper-editor-mirror-check: unknown argument '$1' (expected --write or none)" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEEX="$ROOT/api/lib/barkpark_web/layouts/root.html.heex"
BUNDLE="$ROOT/api/assets/paper-editor/src/styles.css"
SURFACE="$ROOT/api/assets/paper-surface/paper-surface.css"

# ── Part 3: generated paper-surface token layer (source → bundle) ────────────
# Runs first so `--write` regenerates before the lockstep check verifies.
python3 - "$SURFACE" "$BUNDLE" "$MODE" <<'PY'
import os, re, sys, difflib

surface_path, bundle_path, mode = sys.argv[1:4]

if not os.path.isfile(surface_path):
    print(f"paper-editor-mirror-check part 3: FAILED — canonical source missing: "
          f"{surface_path}\n  (paper-surface.css is the ONE source the bundle's "
          f"token layer is generated from — it must never be deleted/moved without "
          f"updating this script.)", file=sys.stderr)
    sys.exit(1)

# Literal font stacks for any host-app-only `var(--font*)` values the source
# might carry (Studio resolves those through host vars that DO NOT exist in a
# bare host). The source is literal-fonts today, so this is a passthrough guard;
# it keeps the transform correct if a `var(--font…)` ever lands in the source.
FONT_LITERALS = {
    "--paper-font-serif": '"Iowan Old Style", "Palatino Linotype", Palatino, Charter, Georgia, \'Source Serif 4\', serif',
    "--paper-font-sans": '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif',
    "--paper-font-mono": 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace',
}

def strip_comments(s):
    return re.sub(r"/\*.*?\*/", " ", s, flags=re.S)

def parse_decls(sel, body):
    """Ordered (name, value) custom-property declarations from a token-scope
    rule body. A token scope must be PURE custom properties: a non-custom
    declaration there is a hard error, never a silent skip — a silently
    skipped block would mean its tokens NEVER reach the generated bundle
    section while the check stays green (the exact drift this gate exists to
    prevent). Element/chrome rules belong under element selectors
    (`.bp-paper-surface h1`, `.bp-callout`, …), not the bare token scopes."""
    out = []
    for decl in strip_comments(body).split(";"):
        decl = decl.strip()
        if not decl:
            continue
        name, _, value = decl.partition(":")
        name, value = name.strip(), value.strip()
        if not name.startswith("--"):
            print("paper-editor-mirror-check part 3: FAILED — paper-surface.css "
                  f"token scope `{sel.strip()}` carries a non-custom-property "
                  f"declaration (`{decl}`).\n"
                  "  Token scopes (.bp-paper-surface/.bp-paper-body, themed or "
                  "not) must hold ONLY `--*` custom properties — move element/"
                  "chrome declarations to an element selector, or the generated "
                  "bundle section cannot represent this block.", file=sys.stderr)
            sys.exit(1)
        m = re.fullmatch(r"var\((--font[\w-]*)\)", value)
        if m:
            value = FONT_LITERALS.get(m.group(1), value)
        out.append((name, value))
    return out

def is_token_selector(sel):
    """True for the paper-surface TOKEN scopes only (not element/class rules):
    every comma-part resolves to `.bp-paper-surface` / `.bp-paper-body`,
    optionally under an `html[data-theme=…]` ancestor. Element rules
    (`.bp-paper-surface h1`) and unrelated selectors return False."""
    sel = strip_comments(sel).strip()
    if not sel:
        return False
    for part in sel.split(","):
        part = re.sub(r'^html\[data-theme="(?:light|dark)"\]\s+', "", part.strip())
        if part not in (".bp-paper-surface", ".bp-paper-body"):
            return False
    return True

# Strip comments up front: a source comment may legitimately contain literal
# braces (e.g. the `ul,ol { margin:0 0 24px }` example) that would otherwise
# fool the flat brace matcher below.
surface = strip_comments(open(surface_path, encoding="utf-8").read())

light, dark = {}, {}          # name -> value (last write wins)
light_order, dark_order = [], []

for m in re.finditer(r"([^{}]*)\{([^{}]*)\}", surface):
    sel, body = m.group(1), m.group(2)
    if not is_token_selector(sel):
        continue
    decls = parse_decls(sel, body)
    dark_scope = 'data-theme="dark"' in sel
    bucket, order = (dark, dark_order) if dark_scope else (light, light_order)
    for name, value in decls:
        if name not in bucket:
            order.append(name)
        bucket[name] = value

def emit(selector, order, bucket):
    lines = [f"  {name}: {bucket[name]};" for name in order]
    return selector + " {\n" + "\n".join(lines) + "\n}"

generated = emit(":root, :host", light_order, light) + "\n\n" + emit(
    ':root[data-theme="dark"], :host([data-theme="dark"])', dark_order, dark
)

bundle = open(bundle_path, encoding="utf-8").read()
marker = re.search(
    r"(/\* BEGIN GENERATED: paper-surface[^\n]*\*/\n)(.*?)(\n/\* END GENERATED: paper-surface \*/)",
    bundle,
    re.S,
)
if not marker:
    print("paper-editor-mirror-check part 3: FAILED — BEGIN/END GENERATED: "
          "paper-surface markers not found in styles.css.", file=sys.stderr)
    sys.exit(1)

if bundle.count("BEGIN GENERATED: paper-surface") > 1:
    print("paper-editor-mirror-check part 3: FAILED — multiple 'BEGIN GENERATED: "
          "paper-surface' markers in styles.css; the generated section must be "
          "exactly one marked region.", file=sys.stderr)
    sys.exit(1)

current = marker.group(2)

if mode == "write":
    new_bundle = bundle[: marker.start()] + marker.group(1) + generated + marker.group(3) + bundle[marker.end():]
    if new_bundle != bundle:
        open(bundle_path, "w", encoding="utf-8").write(new_bundle)
        print("paper-editor-mirror-check part 3: WROTE — regenerated the "
              "paper-surface token layer in styles.css from paper-surface.css.")
    else:
        print("paper-editor-mirror-check part 3: up to date — nothing to write.")
    sys.exit(0)

if current == generated:
    n = generated.count("--")
    print(f"paper-editor-mirror-check part 3: PASS — {n} generated paper-surface "
          f"tokens in styles.css match paper-surface.css.")
    sys.exit(0)

print("paper-editor-mirror-check part 3: FAILED — the generated paper-surface "
      "token layer in styles.css is STALE vs paper-surface.css.\n", file=sys.stderr)
for line in difflib.unified_diff(
    current.strip("\n").splitlines(), generated.splitlines(),
    "styles.css (marked)", "regenerated from paper-surface.css", lineterm=""):
    print("  " + line, file=sys.stderr)
print("\n  Fix: run  scripts/paper-editor-mirror-check.sh --write  and commit the "
      "result (the token layer is GENERATED — never hand-edit between the markers).",
      file=sys.stderr)
sys.exit(1)
PY

# ── Part 1/2: .bp-canvas-* lockstep (root.html.heex ↔ styles.css bundle) ─────
# Intentional one-sided selectors (documented). Keep this list SMALL and justified.
#   bp-canvas-source — the source-mode <textarea> (canvas/index.js); Studio-only,
#                      absent from the standalone embedder bundle by design.
HEEX_ONLY_ALLOW="bp-canvas-source"
BUNDLE_ONLY_ALLOW=""

python3 - "$HEEX" "$BUNDLE" "$HEEX_ONLY_ALLOW" "$BUNDLE_ONLY_ALLOW" <<'PY'
import re, sys

heex_path, bundle_path, heex_allow, bundle_allow = sys.argv[1:5]

def canvas_classes(path):
    s = open(path, encoding="utf-8").read()
    s = re.sub(r"/\*.*?\*/", " ", s, flags=re.S)   # CSS comments
    s = re.sub(r"<!--.*?-->", " ", s, flags=re.S)  # HTML comments
    return set(re.findall(r"\.(bp-canvas-[a-z0-9-]+)", s))

heex = canvas_classes(heex_path)
bundle = canvas_classes(bundle_path)
heex_allow = set(filter(None, heex_allow.split()))
bundle_allow = set(filter(None, bundle_allow.split()))

heex_only = heex - bundle - heex_allow
bundle_only = bundle - heex - bundle_allow

if not heex_only and not bundle_only:
    n = len(heex & bundle)
    print(f"paper-editor-mirror-check: PASS — {n} .bp-canvas-* classes in lockstep "
          f"(+{len(heex_allow)} allowlisted heex-only).")
    sys.exit(0)

print("paper-editor-mirror-check: FAILED — the two paper-editor style mirrors have drifted.\n")
if heex_only:
    print("  In root.html.heex but NOT in styles.css bundle:")
    for c in sorted(heex_only):
        print(f"    .{c}")
if bundle_only:
    print("  In styles.css bundle but NOT in root.html.heex (Studio would not pick this up!):")
    for c in sorted(bundle_only):
        print(f"    .{c}")
print("\n  Fix: add the missing rule to the other mirror (keep values identical), or — if the")
print("  asymmetry is intentional — add the class to HEEX_ONLY_ALLOW / BUNDLE_ONLY_ALLOW in")
print("  scripts/paper-editor-mirror-check.sh with a one-line justification.")
sys.exit(1)
PY
