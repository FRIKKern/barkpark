#!/usr/bin/env bash
# paper-editor-mirror-check — guard the two hand-synced paper-editor style mirrors.
#
# The Studio paper editor's node-view chrome (.bp-canvas-*) is styled in TWO places
# that must stay in lockstep:
#   1. api/lib/barkpark_web/layouts/root.html.heex   (Studio inline <style> — what Studio serves)
#   2. api/assets/paper-editor/src/styles.css        (the de-scoped standalone bundle for embedders)
# When a rule lands in one mirror but not the other, edit-mode-at-rest silently diverges
# from view mode (this bit us: hyphens/callout/list-marker drift, cycles 57-58). This tripwire
# fails CI when a .bp-canvas-* class exists in one mirror but not the other, unless the
# asymmetry is in the documented allowlist below.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEEX="$ROOT/api/lib/barkpark_web/layouts/root.html.heex"
BUNDLE="$ROOT/api/assets/paper-editor/src/styles.css"

# Intentional one-sided selectors (documented). Keep this list SMALL and justified.
#   bp-canvas-source — the source-mode <textarea> (canvas/index.js); Studio-only, absent from
#                      the standalone embedder bundle by design.
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
