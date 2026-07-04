#!/usr/bin/env bash
# paper-editor-mirror-check — guard the paper-editor style mirrors + the ONE
# canonical paper-surface source.
#
# (1) The Studio paper editor's node-view chrome (.bp-canvas-*) is styled in TWO
#     places that must stay in lockstep:
#       a. api/lib/barkpark_web/layouts/root.html.heex   (Studio inline <style>)
#          — PLUS the extracted api/assets/paper-surface/paper-surface.css it
#            embeds (a rule may now legitimately live in either; we union them).
#       b. api/assets/paper-editor/src/styles.css        (the de-scoped standalone
#          bundle for embedders)
#     When a rule lands in one mirror but not the other, edit-mode-at-rest
#     silently diverges from view mode (this bit us: hyphens/callout/list-marker
#     drift, cycles 57-58). This tripwire fails CI when a .bp-canvas-* class
#     exists in one mirror but not the other, unless the asymmetry is allowlisted.
#
# (2) Paper editor parity Stage 2 extracted the portable paper-surface layer
#     (--paper-*/--bp-* tokens + .bp-paper-surface element rules) into a SINGLE
#     source, api/assets/paper-surface/paper-surface.css, embedded by root +
#     bulldocs layouts + the sheet export. We assert that source exists AND that
#     the --bp-* token block was truly MOVED (lives ONLY in the source, never
#     duplicated back into root.html.heex).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEEX="$ROOT/api/lib/barkpark_web/layouts/root.html.heex"
SURFACE="$ROOT/api/assets/paper-surface/paper-surface.css"
BUNDLE="$ROOT/api/assets/paper-editor/src/styles.css"

# Intentional one-sided selectors (documented). Keep this list SMALL and justified.
#   bp-canvas-source — the source-mode <textarea> (canvas/index.js); Studio-only,
#                      absent from the standalone embedder bundle by design.
HEEX_ONLY_ALLOW="bp-canvas-source"
BUNDLE_ONLY_ALLOW=""

# ── (1) .bp-canvas-* two-mirror lockstep ────────────────────────────────────
# The heex side is the UNION of root.html.heex and the extracted paper-surface
# source (a canvas rule may live in either after the Stage-2 split).
python3 - "$HEEX" "$SURFACE" "$BUNDLE" "$HEEX_ONLY_ALLOW" "$BUNDLE_ONLY_ALLOW" <<'PY'
import re, sys

heex_path, surface_path, bundle_path, heex_allow, bundle_allow = sys.argv[1:6]

def canvas_classes(*paths):
    out = set()
    for path in paths:
        s = open(path, encoding="utf-8").read()
        s = re.sub(r"/\*.*?\*/", " ", s, flags=re.S)   # CSS comments
        s = re.sub(r"<!--.*?-->", " ", s, flags=re.S)  # HTML comments
        out |= set(re.findall(r"\.(bp-canvas-[a-z0-9-]+)", s))
    return out

heex = canvas_classes(heex_path, surface_path)
bundle = canvas_classes(bundle_path)
heex_allow = set(filter(None, heex_allow.split()))
bundle_allow = set(filter(None, bundle_allow.split()))

heex_only = heex - bundle - heex_allow
bundle_only = bundle - heex - bundle_allow

if not heex_only and not bundle_only:
    n = len(heex & bundle)
    print(f"paper-editor-mirror-check: PASS (1/2) — {n} .bp-canvas-* classes in lockstep "
          f"(+{len(heex_allow)} allowlisted heex-only).")
else:
    print("paper-editor-mirror-check: FAILED (1/2) — the paper-editor style mirrors have drifted.\n")
    if heex_only:
        print("  In root.html.heex / paper-surface.css but NOT in styles.css bundle:")
        for c in sorted(heex_only):
            print(f"    .{c}")
    if bundle_only:
        print("  In styles.css bundle but NOT in root.html.heex / paper-surface.css (Studio would not pick this up!):")
        for c in sorted(bundle_only):
            print(f"    .{c}")
    print("\n  Fix: add the missing rule to the other mirror (keep values identical), or — if the")
    print("  asymmetry is intentional — add the class to HEEX_ONLY_ALLOW / BUNDLE_ONLY_ALLOW in")
    print("  scripts/paper-editor-mirror-check.sh with a one-line justification.")
    sys.exit(1)
PY

# ── (2) canonical paper-surface source: exists + single-owner --bp-* tokens ──
# Sentinel: the --bp-* typography token DEFINITION block (`--bp-h1-size:`) must
# live ONLY in paper-surface.css. A `var(--bp-h1-size)` REFERENCE (no colon) in
# root.html.heex is fine — only a duplicate DEFINITION (`--bp-h1-size:`) fails.
python3 - "$HEEX" "$SURFACE" <<'PY'
import os, sys

heex_path, surface_path = sys.argv[1:3]
SENTINEL = "--bp-h1-size:"
errors = []

if not os.path.isfile(surface_path):
    errors.append(f"canonical source missing: {surface_path}")
else:
    surface = open(surface_path, encoding="utf-8").read()
    if SENTINEL not in surface:
        errors.append(f"canonical source {os.path.basename(surface_path)} "
                      f"does not define the --bp-* tokens (missing '{SENTINEL}').")

heex = open(heex_path, encoding="utf-8").read()
dup = heex.count(SENTINEL)
if dup:
    errors.append(f"root.html.heex still DEFINES the --bp-* tokens "
                  f"('{SENTINEL}' x{dup}) — they must live ONLY in paper-surface.css "
                  f"(references `var(--bp-h1-size)` are fine; a definition is not).")

if errors:
    print("\npaper-editor-mirror-check: FAILED (2/2) — canonical paper-surface source:\n")
    for e in errors:
        print(f"    - {e}")
    print("\n  Fix: keep the --paper-*/--bp-* token blocks + .bp-paper-surface element rules")
    print("  in api/assets/paper-surface/paper-surface.css ONLY; root.html.heex embeds them")
    print("  via <%= raw(Barkpark.PortableDoc.Render.Stylesheet.css()) %>.")
    sys.exit(1)

print("paper-editor-mirror-check: PASS (2/2) — paper-surface.css is the single --bp-* owner.")
PY
