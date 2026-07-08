#!/usr/bin/env bash
# status-manifest-check.sh — the drift gate for the task status vocabulary.
#
# design/status-manifest.json is the ONE source of the white ladder (statuses,
# roles, glyphs, semantic tones). This gate keeps every OTHER surface honest to
# it:
#
#   Part 1 — the `--st-*` tone tokens in paper-surface.css are GENERATED from the
#     manifest's `tones` (light + dark, media-query + data-theme), live between
#     BEGIN/END GENERATED markers. Default mode regenerates in memory and
#     byte-compares; `--write` rewrites the block from the manifest.
#   Part 2 — glyph-class coverage: paper-surface.css must define a `.bp-g--<role>`
#     rule for EXACTLY the manifest's roles — no orphan glyph class for a role
#     that isn't in the manifest, no missing rule for one that is. This is the
#     tripwire for "a surface added/dropped a glyph by hand."
#   Part 3 — Go pdrender: internal/pdrender/gridblocks.go inlines the SAME
#     vocabulary (it may not import the Elixir StatusVocab or internal/semrole,
#     per the go-list-deps invariant). Its `roleGlyph` map and `roleForStatus`
#     status→role aliases are byte-checked against the manifest here — the ONE
#     documented exception is the `progress` role, which the manifest marks
#     spinner:true (empty/animated glyph) and Go pins to a steady Braille frame
#     (⠋) a static terminal render can show. That steady value is asserted
#     explicitly so an ACCIDENTAL change to it still trips the gate.
#
# The Elixir emitters need no check here: Render.StatusVocab reads THIS manifest
# at compile time, so they cannot diverge by construction.
#
# Usage: scripts/status-manifest-check.sh [--write]
set -euo pipefail
cd "$(dirname "$0")/.."

MANIFEST="design/status-manifest.json"
CSS="api/assets/paper-surface/paper-surface.css"
GO="internal/pdrender/gridblocks.go"
MODE="${1:-check}"

python3 - "$MANIFEST" "$CSS" "$MODE" "$GO" <<'PY'
import json, re, sys

manifest_path, css_path, mode, go_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
m = json.load(open(manifest_path))
css = open(css_path).read()

# ── Part 1: generate the --st-* tone block from the manifest ────────────────
tones = m["tones"]
def toks(theme):
    return " ".join(f"--st-{name}: {tones[name][theme]};" for name in tones)

light, dark = toks("light"), toks("dark")
generated = "\n".join([
    f'.bp-paper-surface, .bp-paper-body {{ {light} }}',
    '@media (prefers-color-scheme: dark) {',
    f'  .bp-paper-surface, .bp-paper-body {{ {dark} }}',
    '}',
    f'html[data-theme="light"] .bp-paper-surface, html[data-theme="light"] .bp-paper-body {{ {light} }}',
    f'html[data-theme="dark"] .bp-paper-surface, html[data-theme="dark"] .bp-paper-body {{ {dark} }}',
])

marker = re.search(
    r"(/\* BEGIN GENERATED: status-tones[^\n]*\*/\n)(.*?)(\n/\* END GENERATED: status-tones \*/)",
    css, re.DOTALL)
if not marker:
    print("status-manifest-check part 1: FAILED — BEGIN/END GENERATED: status-tones "
          "markers not found in paper-surface.css.", file=sys.stderr)
    sys.exit(1)

current = marker.group(2)
if mode == "--write":
    if current != generated:
        css = css[:marker.start(2)] + generated + css[marker.end(2):]
        open(css_path, "w").write(css)
        print("status-manifest-check part 1: WROTE — regenerated the --st-* tone block from the manifest.")
    else:
        print("status-manifest-check part 1: PASS — tone block already in sync.")
elif current != generated:
    print("status-manifest-check part 1: FAILED — the --st-* tone block in paper-surface.css is "
          "STALE vs design/status-manifest.json.\n", file=sys.stderr)
    print("  --- paper-surface.css (marked)\n  +++ regenerated from the manifest", file=sys.stderr)
    for a, b in zip(current.split("\n"), generated.split("\n")):
        if a != b:
            print(f"  - {a}\n  + {b}", file=sys.stderr)
    print("\n  Fix: scripts/status-manifest-check.sh --write", file=sys.stderr)
    sys.exit(1)
else:
    print("status-manifest-check part 1: PASS — --st-* tone block matches the manifest.")

# ── Part 2: glyph-class coverage (roles ↔ .bp-g--<role>) ────────────────────
roles = {r["role"] for r in m["roles"]}
in_css = set(re.findall(r"\.bp-g--([a-z]+)\b", css))
missing = roles - in_css
orphan = in_css - roles
if missing or orphan:
    if missing:
        print(f"status-manifest-check part 2: FAILED — manifest roles with no .bp-g--<role> "
              f"rule in paper-surface.css: {sorted(missing)}", file=sys.stderr)
    if orphan:
        print(f"status-manifest-check part 2: FAILED — .bp-g--<role> classes with no matching "
              f"manifest role (hand-added glyph?): {sorted(orphan)}", file=sys.stderr)
    sys.exit(1)
print(f"status-manifest-check part 2: PASS — {len(roles)} glyph roles in lockstep "
      f"({', '.join(sorted(roles))}).")

# ── Part 3: Go pdrender (internal/pdrender/gridblocks.go) ────────────────────
# The Go copy can't be generated at compile time (it's a separate binary that
# must not import the Elixir vocab), so it is inlined and gated here instead.
go = open(go_path).read()

# The manifest marks `progress` as spinner (empty/animated glyph); a static
# terminal render can't animate, so Go pins one steady Braille frame. Hard-code
# the agreed steady value so this legitimate divergence is documented AND an
# accidental change to the Go glyph still trips the gate.
STEADY_PROGRESS = "⠋"  # ⠋ — see roleGlyph comment in gridblocks.go

# Expected role→glyph per the manifest, applying the progress exception.
expected_glyph = {}
for r in m["roles"]:
    expected_glyph[r["role"]] = STEADY_PROGRESS if r.get("spinner") else r["glyph"]

# Parse the inlined `var roleGlyph = map[string]string{ ... }` block.
gm = re.search(r"var roleGlyph = map\[string\]string\{(.*?)\n\}", go, re.DOTALL)
if not gm:
    print("status-manifest-check part 3: FAILED — `var roleGlyph = map[string]string{...}` "
          "not found in gridblocks.go.", file=sys.stderr)
    sys.exit(1)
go_glyph = dict(re.findall(r'"([a-z_]+)":\s*"([^"]*)"', gm.group(1)))

fails = []
for role in sorted(expected_glyph):
    want, got = expected_glyph[role], go_glyph.get(role)
    note = " (steady-frame exception for manifest spinner)" if role == "progress" else ""
    if got is None:
        fails.append(f"  role {role!r}: MISSING from Go roleGlyph (manifest glyph {want!r}){note}")
    elif got != want:
        fails.append(f"  role {role!r}: Go {got!r} != manifest {want!r}{note}")
    else:
        print(f"status-manifest-check part 3: PASS — glyph[{role}] = {want!r}{note}")
orphan_g = set(go_glyph) - set(expected_glyph)
if orphan_g:
    fails.append(f"  Go roleGlyph has extra role(s) not in the manifest: {sorted(orphan_g)}")

# Parse `func roleForStatus(status string) string { switch ... }` into status→role.
fn = re.search(r"func roleForStatus\(status string\) string \{(.*?)\n\}", go, re.DOTALL)
if not fn:
    print("status-manifest-check part 3: FAILED — func roleForStatus not found in gridblocks.go.",
          file=sys.stderr)
    sys.exit(1)
body = fn.group(1)
go_status = {}
for cm in re.finditer(r'case ((?:"[a-z_]+"(?:,\s*)?)+):\s*\n\s*return "([a-z_]+)"', body):
    for s in re.findall(r'"([a-z_]+)"', cm.group(1)):
        go_status[s] = cm.group(2)
dm = re.search(r'default:\s*\n\s*return "([a-z_]+)"', body)
go_default = dm.group(1) if dm else None

man_status = m["statuses"]
man_default = m["default_role"]
for status in sorted(man_status):
    want, got = man_status[status], go_status.get(status)
    if got is None:
        fails.append(f"  status {status!r}: MISSING from roleForStatus (manifest role {want!r})")
    elif got != want:
        fails.append(f"  status {status!r}: Go role {got!r} != manifest {want!r}")
    else:
        print(f"status-manifest-check part 3: PASS — roleForStatus[{status}] = {want!r}")
orphan_s = set(go_status) - set(man_status)
if orphan_s:
    fails.append(f"  roleForStatus has extra status alias(es) not in the manifest: {sorted(orphan_s)}")
if go_default != man_default:
    fails.append(f"  roleForStatus default {go_default!r} != manifest default_role {man_default!r}")
else:
    print(f"status-manifest-check part 3: PASS — roleForStatus default = {man_default!r}")

if fails:
    print("status-manifest-check part 3: FAILED — Go pdrender vocab is STALE vs "
          "design/status-manifest.json:", file=sys.stderr)
    for f in fails:
        print(f, file=sys.stderr)
    print("\n  Fix: edit internal/pdrender/gridblocks.go (roleGlyph / roleForStatus) to "
          "match design/status-manifest.json.", file=sys.stderr)
    sys.exit(1)
print(f"status-manifest-check part 3: PASS — Go pdrender vocab in lockstep "
      f"({len(expected_glyph)} glyphs, {len(man_status)} status aliases).")
PY
