#!/usr/bin/env bash
# paper-editor-mirror-check — guard the paper-editor style mirrors + the
# generated paper-surface token layer.
#
# TWO invariants, one script:
#
#   Part 1/2 — .bp-canvas-* lockstep. The Studio paper editor's node-view chrome
#   (.bp-canvas-*) is styled in TWO places that must stay in lockstep:
#     1. api/priv/static/assets/bp-paper-editor-shell.css  (the Studio shell
#        stylesheet — inline in root.html.heex until edit-on-the-link lifted it
#        into a static asset BOTH root.html.heex and the public paper reader
#        layout link, so one copy paints the editor on both surfaces)
#     2. api/assets/paper-editor/src/styles.css        (the de-scoped bundle)
#   When a rule lands in one mirror but not the other, edit-mode-at-rest silently
#   diverges from view mode (hyphens/callout/list-marker drift, cycles 57-58).
#   This tripwire fails when a .bp-canvas-* class exists in one mirror but not the
#   other, unless the asymmetry is in the documented allowlist.
#   NOTE: paper-surface.css is deliberately NOT unioned into the heex side —
#   per its own header, .bp-canvas-* node-view chrome is Studio-shell and stays
#   in the Studio shell stylesheet (a canvas rule landing in the portable source is itself
#   drift this check should surface).
#   (The old "part 2" single-owner --bp-* sentinel moved to
#   test/barkpark/portable_doc/render/stylesheet_test.exs, which pins the same
#   invariant compile-coupled; it is not duplicated here.)
#
#   Part 3 — generated paper-surface token layer. The `--paper-*` theme tokens +
#   `--bp-*` typography tokens in the embedder bundle (styles.css) are GENERATED
#   from the ONE canonical source (api/assets/paper-surface/paper-surface.css)
#   via a deterministic de-scoping transform, and live between exact BEGIN/END
#   GENERATED markers. Default mode byte-compares against the marked section
#   (fails with a --write hint on drift); `--write` rewrites it in place. This
#   makes the bundle track the source: a token added/changed in paper-surface.css
#   (e.g. wave-2 --bp-tone-* light+dark values) can't be silently forgotten.
#
#   The transform NO LONGER lives here: it is owned by design/paper-editor-mirror.mjs
#   (zero-dep Node), which design/emit.mjs ALSO drives after it emits
#   paper-surface.css and design/check.mjs gates. So a single
#   `node design/emit.mjs --write` keeps paper-surface.css AND this mirror in
#   lockstep, and there is exactly ONE implementation — this script and the
#   emitter can never disagree. This part just delegates (CLI surface unchanged).
#
#   --write here is FENCED, exactly as `node design/emit.mjs --write` is: it refuses
#   to replace the marked region when its SHA-256 does not match
#   design/emit-manifest.json, names every line it would delete, and records the
#   write in that same manifest. The fence lives in the ONE Node owner; this script
#   only forwards the flags, so the two writers can never disagree.
#
# Usage:
#   scripts/paper-editor-mirror-check.sh                  # check (CI + the merge gate)
#   scripts/paper-editor-mirror-check.sh --write          # fenced regenerate
#   scripts/paper-editor-mirror-check.sh --write --force  # regenerate over the fence
#   scripts/paper-editor-mirror-check.sh --adopt          # bless the region on disk
set -euo pipefail

MODE="check"
MIRROR_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --write) MODE="write"; MIRROR_ARGS+=("$arg") ;;
    --adopt) MODE="adopt"; MIRROR_ARGS+=("$arg") ;;
    --force) MIRROR_ARGS+=("$arg") ;;
    *)
      echo "paper-editor-mirror-check: unknown argument '$arg' (expected --write, --force, --adopt or none)" >&2
      exit 2
      ;;
  esac
done
if [[ "$MODE" == "check" && ${#MIRROR_ARGS[@]} -gt 0 ]]; then
  echo "paper-editor-mirror-check: --force needs --write" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEEX="$ROOT/api/priv/static/assets/bp-paper-editor-shell.css"
BUNDLE="$ROOT/api/assets/paper-editor/src/styles.css"
SURFACE="$ROOT/api/assets/paper-surface/paper-surface.css"

# ── Part 3: generated paper-surface token layer (source → bundle) ────────────
# Delegates to the single Node owner (design/paper-editor-mirror.mjs). Runs first
# so `--write` regenerates before the lockstep check verifies. `--write` passes
# through; default is a byte-compare. The transform is the SAME code design/emit.mjs
# drives, so this script and the emitter can never disagree.
node "$ROOT/design/paper-editor-mirror.mjs" ${MIRROR_ARGS[@]+"${MIRROR_ARGS[@]}"}

# ── Part 1/2: .bp-canvas-* lockstep (shell stylesheet ↔ styles.css bundle) ───
# Intentional one-sided selectors (documented). Keep this list SMALL and justified.
#   bp-canvas-source — the source-mode <textarea> (canvas/index.js); Studio-only,
#                      absent from the standalone embedder bundle by design.
HEEX_ONLY_ALLOW="bp-canvas-source"
BUNDLE_ONLY_ALLOW=""

python3 - "$HEEX" "$BUNDLE" "$HEEX_ONLY_ALLOW" "$BUNDLE_ONLY_ALLOW" <<'PY'
import re, sys

heex_path, bundle_path, heex_allow, bundle_allow = sys.argv[1:5]

# Exit codes, kept distinct on purpose:
#   0 = lockstep, 1 = DRIFT FOUND, 2 = REFUSED TO MEASURE (empty corpus,
#   unreadable mirror, broken comparator). A refusal must never share the
#   drift code — a crash that reads as a finding sends someone hunting a
#   divergence that does not exist.

def canvas_classes(path, side):
    try:
        s = open(path, encoding="utf-8").read()
    except OSError as e:
        print(f"paper-editor-mirror-check: REFUSED TO MEASURE — cannot read the {side} mirror: {e}")
        sys.exit(2)
    s = re.sub(r"/\*.*?\*/", " ", s, flags=re.S)   # CSS comments
    s = re.sub(r"<!--.*?-->", " ", s, flags=re.S)  # HTML comments
    return set(re.findall(r"\.(bp-canvas-[a-z0-9-]+)", s))

def compare(heex, bundle, h_allow, b_allow):
    """0 lockstep, 1 drift (with the two one-sided sets), 2 empty corpus."""
    if not heex or not bundle:
        return 2, set(), set()
    heex_only = heex - bundle - h_allow
    bundle_only = bundle - heex - b_allow
    if not heex_only and not bundle_only:
        return 0, set(), set()
    return 1, heex_only, bundle_only

# ALWAYS-ON SELF-TEST (runs before every measurement): two empty sets satisfy
# `not heex_only and not bundle_only`, so a refactor that empties BOTH corpora
# (moving the Studio editor CSS out of its file, or renaming the
# .bp-canvas-* convention) used to print 'PASS — 0 classes in lockstep'
# forever. Prove the comparator can refuse AND can red before trusting it.
for want, h, b in (
    (2, set(), {"bp-canvas-x"}),                      # one empty side refuses
    (2, set(), set()),                                # a corpus of zero refuses
    (1, {"bp-canvas-x", "bp-canvas-y"}, {"bp-canvas-x"}),  # a planted one-sided class reds
    (0, {"bp-canvas-x"}, {"bp-canvas-x"}),            # lockstep passes
):
    got = compare(h, b, set(), set())[0]
    if got != want:
        print(f"paper-editor-mirror-check: SELF-TEST FAILED — comparator returned {got}, "
              f"expected {want} for heex={sorted(h)} bundle={sorted(b)}; "
              f"refusing to measure with a broken instrument")
        sys.exit(2)

heex = canvas_classes(heex_path, "bp-paper-editor-shell.css")
bundle = canvas_classes(bundle_path, "styles.css bundle")
heex_allow = set(filter(None, heex_allow.split()))
bundle_allow = set(filter(None, bundle_allow.split()))

code, heex_only, bundle_only = compare(heex, bundle, heex_allow, bundle_allow)

if code == 2:
    zero = []
    if not heex: zero.append("bp-paper-editor-shell.css")
    if not bundle: zero.append("styles.css bundle")
    print(f"paper-editor-mirror-check: REFUSED TO MEASURE — {' and '.join(zero)} yielded ZERO "
          f".bp-canvas-* classes (heex={len(heex)}, bundle={len(bundle)}). A lockstep of two "
          f"empty corpora is a green about nothing; if the convention moved or was renamed, "
          f"update this check in the same PR.")
    sys.exit(2)

if code == 0:
    n = len(heex & bundle)
    print(f"paper-editor-mirror-check: PASS — {n} .bp-canvas-* classes in lockstep "
          f"(heex corpus {len(heex)}, bundle corpus {len(bundle)}, "
          f"+{len(heex_allow)} allowlisted heex-only).")
    sys.exit(0)

print("paper-editor-mirror-check: FAILED — the two paper-editor style mirrors have drifted.\n")
if heex_only:
    print("  In bp-paper-editor-shell.css but NOT in styles.css bundle:")
    for c in sorted(heex_only):
        print(f"    .{c}")
if bundle_only:
    print("  In styles.css bundle but NOT in bp-paper-editor-shell.css (Studio would not pick this up!):")
    for c in sorted(bundle_only):
        print(f"    .{c}")
print("\n  Fix: add the missing rule to the other mirror (keep values identical), or — if the")
print("  asymmetry is intentional — add the class to HEEX_ONLY_ALLOW / BUNDLE_ONLY_ALLOW in")
print("  scripts/paper-editor-mirror-check.sh with a one-line justification.")
sys.exit(1)
PY
