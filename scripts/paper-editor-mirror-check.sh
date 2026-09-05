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
#   scripts/paper-editor-mirror-check.sh --selftest       # prove part 1/2 can still lose
set -euo pipefail

SELF="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"

MODE="check"
MIRROR_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --write) MODE="write"; MIRROR_ARGS+=("$arg") ;;
    --adopt) MODE="adopt"; MIRROR_ARGS+=("$arg") ;;
    --selftest) MODE="selftest" ;;
    --force) MIRROR_ARGS+=("$arg") ;;
    *)
      echo "paper-editor-mirror-check: REFUSED TO MEASURE — unknown argument '$arg' (expected --write, --force, --adopt, --selftest or none)" >&2
      exit 2
      ;;
  esac
done
if [[ "$MODE" == "check" && ${#MIRROR_ARGS[@]} -gt 0 ]]; then
  echo "paper-editor-mirror-check: --force needs --write" >&2
  exit 2
fi

# ── selftest: prove part 1/2 BITES, and prove it stays SILENT when it should ──
#
# Every arm writes two throwaway mirror files and re-invokes THIS script against
# them via PAPER_EDITOR_MIRROR_HEEX/_BUNDLE, so the assertions drive the shipping
# comparator — not a second copy of it that could agree while both are wrong.
# Nothing is planted in this repo. Part 3 is skipped inside a probe (see the
# block above the delegate for why).
selftest() {
  local tmp bad=0 rc
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  say() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; bad=$((bad + 1)); fi; }

  # $1 = heex classes (space separated), $2 = bundle classes, $3 = heex allow
  probe() {
    local c
    : > "$tmp/h.css"; : > "$tmp/b.css"
    for c in $1; do printf '.%s { color: red }\n' "$c" >> "$tmp/h.css"; done
    for c in $2; do printf '.%s { color: red }\n' "$c" >> "$tmp/b.css"; done
    PAPER_EDITOR_MIRROR_HEEX="$tmp/h.css" \
    PAPER_EDITOR_MIRROR_BUNDLE="$tmp/b.css" \
    PAPER_EDITOR_MIRROR_HEEX_ALLOW="${3-}" \
      bash "$SELF" > "$tmp/out" 2>&1
    echo $?
  }

  echo "paper-editor-mirror-check --selftest (throwaway mirrors)"

  # 1. SILENT ARM — a real lockstep corpus passes and PRINTS its populations.
  rc="$(probe "bp-canvas-a bp-canvas-b" "bp-canvas-a bp-canvas-b" "")"
  { [ "$rc" -eq 0 ] && grep -q "2 .bp-canvas-\* classes in lockstep" "$tmp/out"; } \
    && say "lockstep corpus -> PASS, counts printed" 0 \
    || { say "lockstep corpus -> PASS, counts printed (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 2. REFUSE ARM — BOTH mirrors emptied. The device-oracle shape: two empty sets
  #    satisfy "no one-sided classes", so this used to be a green about nothing.
  rc="$(probe "" "" "")"
  { [ "$rc" -eq 2 ] && grep -q "REFUSED TO MEASURE" "$tmp/out"; } \
    && say "BOTH mirrors emptied -> REFUSED TO MEASURE (2), never a PASS" 0 \
    || { say "BOTH mirrors emptied -> REFUSED TO MEASURE (2) (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 3. REFUSE ARM — one side emptied is a refusal too, not a 28-class drift list.
  rc="$(probe "bp-canvas-a" "" "")"
  { [ "$rc" -eq 2 ] && grep -q "REFUSED TO MEASURE" "$tmp/out"; } \
    && say "one mirror emptied -> REFUSED TO MEASURE (2)" 0 \
    || { say "one mirror emptied -> REFUSED TO MEASURE (2) (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 4. BITE ARM — a one-sided class reds and is NAMED.
  rc="$(probe "bp-canvas-a bp-canvas-only" "bp-canvas-a" "")"
  { [ "$rc" -eq 1 ] && grep -q "bp-canvas-only" "$tmp/out"; } \
    && say "heex-only class -> FAILED, class named" 0 \
    || { say "heex-only class -> FAILED, class named (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 5. BITE ARM — the bundle side is policed too (Studio would not pick it up).
  rc="$(probe "bp-canvas-a" "bp-canvas-a bp-canvas-ghost" "")"
  { [ "$rc" -eq 1 ] && grep -q "bp-canvas-ghost" "$tmp/out"; } \
    && say "bundle-only class -> FAILED, class named" 0 \
    || { say "bundle-only class -> FAILED, class named (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 6. BITE ARM — two non-empty mirrors with NOTHING in common. The count is
  #    non-zero on both sides, so only the intersection catches this.
  rc="$(probe "bp-canvas-a" "bp-canvas-z" "")"
  { [ "$rc" -eq 1 ]; } \
    && say "disjoint mirrors (empty intersection) -> FAILED" 0 \
    || { say "disjoint mirrors (empty intersection) -> FAILED (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 7. SILENT ARM — an allowlisted one-sided class is allowed, and VERIFIED.
  rc="$(probe "bp-canvas-a bp-canvas-source" "bp-canvas-a" "bp-canvas-source")"
  { [ "$rc" -eq 0 ] && grep -q "1 verified allowlisted heex-only" "$tmp/out"; } \
    && say "allowlisted heex-only class PRESENT -> PASS, reported as verified" 0 \
    || { say "allowlisted heex-only class PRESENT -> PASS (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 8. BITE ARM — the allowlist entry is GONE from the corpus. Measured
  #    2026-09-05 on 9fdca8cb8: deleting .bp-canvas-source from the shell
  #    stylesheet still printed "+1 allowlisted heex-only" at exit 0. An
  #    allowlist that is COUNTED and never VERIFIED grows stale silently and
  #    each dead entry widens the hole for the next real drift.
  rc="$(probe "bp-canvas-a" "bp-canvas-a" "bp-canvas-source")"
  { [ "$rc" -eq 1 ] && grep -q "bp-canvas-source" "$tmp/out" && grep -q "STALE" "$tmp/out"; } \
    && say "allowlist entry ABSENT from the corpus -> FAILED, entry named STALE" 0 \
    || { say "allowlist entry ABSENT from the corpus -> FAILED (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 9. BITE ARM — an allowlist entry present on the WRONG side is stale too.
  rc="$(probe "bp-canvas-a" "bp-canvas-a bp-canvas-source" "bp-canvas-source")"
  { [ "$rc" -eq 1 ]; } \
    && say "heex allowlist entry present only in the BUNDLE -> FAILED" 0 \
    || { say "heex allowlist entry present only in the BUNDLE -> FAILED (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 10. ARG DISPATCH — an unknown flag is a refusal (2), not a silent gate run.
  rc=0; bash "$SELF" --no-such-flag > "$tmp/out" 2>&1 || rc=$?
  { [ "$rc" -eq 2 ] && grep -q -- "--no-such-flag" "$tmp/out"; } \
    && say "unknown argument -> exit 2, names the argument" 0 \
    || { say "unknown argument -> exit 2, names the argument (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  echo ""
  if [ "$bad" -eq 0 ]; then echo "paper-editor-mirror-check --selftest: PASS (10/10)"; return 0; fi
  echo "paper-editor-mirror-check --selftest: FAILED ($bad case(s))"; return 1
}

if [[ "$MODE" == "selftest" ]]; then selftest; exit $?; fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEEX="${PAPER_EDITOR_MIRROR_HEEX:-$ROOT/api/priv/static/assets/bp-paper-editor-shell.css}"
BUNDLE="${PAPER_EDITOR_MIRROR_BUNDLE:-$ROOT/api/assets/paper-editor/src/styles.css}"
SURFACE="$ROOT/api/assets/paper-surface/paper-surface.css"

# ── Part 3: generated paper-surface token layer (source → bundle) ────────────
# Delegates to the single Node owner (design/paper-editor-mirror.mjs). Runs first
# so `--write` regenerates before the lockstep check verifies. `--write` passes
# through; default is a byte-compare. The transform is the SAME code design/emit.mjs
# drives, so this script and the emitter can never disagree.
# The corpus plumb (PAPER_EDITOR_MIRROR_HEEX/_BUNDLE) is SCOPED to part 1/2,
# exactly as PREVIEW_PARITY_SCAN_ROOT is scoped to preview-parity's part 3:
# part 3 is a byte-compare between two files this repo owns, there is nothing
# to plant for it, and pointing the Node owner at a throwaway tree would only
# test that the tree lacks a design/ directory. --selftest sets the plumb, so
# every --selftest probe runs the REAL part 1/2 against a planted corpus.
if [ -n "${PAPER_EDITOR_MIRROR_HEEX:-}${PAPER_EDITOR_MIRROR_BUNDLE:-}" ]; then
  echo "paper-editor-mirror: part 3 SKIPPED — the lockstep corpus is plumbed (selftest probe)."
else
  node "$ROOT/design/paper-editor-mirror.mjs" ${MIRROR_ARGS[@]+"${MIRROR_ARGS[@]}"}
fi

# ── Part 1/2: .bp-canvas-* lockstep (shell stylesheet ↔ styles.css bundle) ───
# Intentional one-sided selectors (documented). Keep this list SMALL and justified.
#   bp-canvas-source — the source-mode <textarea> (canvas/index.js); Studio-only,
#                      absent from the standalone embedder bundle by design.
HEEX_ONLY_ALLOW="${PAPER_EDITOR_MIRROR_HEEX_ALLOW-bp-canvas-source}"
BUNDLE_ONLY_ALLOW="${PAPER_EDITOR_MIRROR_BUNDLE_ALLOW-}"

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

# ALLOWLIST ENTRIES ARE VERIFIED PRESENT, NOT COUNTED. Measured 2026-09-05 on
# 9fdca8cb8: deleting .bp-canvas-source from the shell stylesheet left the gate
# at exit 0 still printing "+1 allowlisted heex-only". A counted allowlist can
# only grow stale, and every dead entry is a class name this check has promised
# never to look at again — the widest hole a drift guard can carry.
stale = [("HEEX_ONLY_ALLOW", c, "bp-paper-editor-shell.css")
         for c in sorted(heex_allow - heex)]
stale += [("BUNDLE_ONLY_ALLOW", c, "styles.css bundle")
          for c in sorted(bundle_allow - bundle)]
if stale and code != 2:
    print("paper-editor-mirror-check: FAILED — STALE allowlist entry: a documented "
          "asymmetry names a class that is no longer in its own mirror.\n")
    for which, c, side in stale:
        print(f"    .{c}  ({which}) is absent from {side}")
    print("\n  An allowlist entry is a standing promise not to police that class. When the "
          "class\n  itself is gone the promise covers nothing and the entry only widens the "
          "next hole.\n  Fix: delete the entry from scripts/paper-editor-mirror-check.sh, or "
          "restore the rule.")
    sys.exit(1)

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
    sample = ", ".join("." + c for c in sorted(heex & bundle)[:3])
    print(f"paper-editor-mirror-check: PASS — {n} .bp-canvas-* classes in lockstep "
          f"(heex corpus {len(heex)}, bundle corpus {len(bundle)}, "
          f"+{len(heex_allow)} verified allowlisted heex-only"
          + (f", +{len(bundle_allow)} verified allowlisted bundle-only" if bundle_allow else "")
          + f"; sample: {sample}).")
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
