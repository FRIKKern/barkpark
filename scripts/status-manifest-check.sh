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
#   Part 4 — Go pdrender LABEL + MEANING: gridblocks.go also inlines `roleLabel`
#     (the canonical lowercase display noun the legend prints / the board
#     sentence-cases) and `roleMeaning` (the one-line gloss). Both are byte-checked
#     against the manifest's `roles[].label` / `roles[].meaning` (no exception —
#     these are prose, not spinner glyphs), so a Go label/meaning drift trips here.
#   Part 5 — JS/TS twins: two hand-maintained copies mirror the manifest by hand
#     (the generator is deferred, tlv-bl-js-vocab-generator) — the react legend
#     vocabulary `STATUS_ROLES` in js/packages/react/src/inline.tsx and the web
#     board ladder `STATUS_LADDER` in web/lib/component-projections.ts. Each TS
#     array literal is byte-checked against the manifest: the manifest roles must
#     appear in manifest ORDER with byte-equal glyph + label, none missing. The
#     ONE documented exception is the JS-only fail-open `unknown` sentinel (D11) —
#     it is NEVER a real lifecycle state, so it is the only sanctioned non-manifest
#     role; ANY other extra/missing/reorder/glyph/label desync reds the gate.
#     Byte-check only — this gate does NOT generate the TS (that is the deferred
#     generator); it keeps the hand-copies honest until then.
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
REACT_TSX="js/packages/react/src/inline.tsx"
WEB_TS="web/lib/component-projections.ts"
# apps/mobile is the THIRD hand-maintained JS/TS copy and was absent from this
# gate entirely until mob-bl-status-manifest-mobile-gate. Its shape differs from
# the other two — four Records/arrays instead of one array-of-objects — so Part 5
# parses it with its own reader; see the block there.
MOBILE_TSX="apps/mobile/src/papers/portabledoc/blocks/taskboard.tsx"
# `MODE="${1:-check}"` used to pass ANY argument straight through to the Python,
# which treats everything that is not `--write` as check mode — so a typo, or a
# `--selftest` this gate does not have, ran the ordinary check and exited 0.
# Refuse what we do not understand instead.
MODE="check"
if [ "${1:-}" = "--write" ]; then
  MODE="--write"
elif [ -n "${1:-}" ]; then
  echo "status-manifest-check: unknown argument '$1' (expected --write or none)" >&2
  exit 2
fi

python3 - "$MANIFEST" "$CSS" "$MODE" "$GO" "$REACT_TSX" "$WEB_TS" "$MOBILE_TSX" <<'PY'
import json, re, sys

manifest_path, css_path, mode, go_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
react_path, web_path, mobile_path = sys.argv[5], sys.argv[6], sys.argv[7]
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

# ── Part 4: Go pdrender role LABEL + MEANING (roleLabel / roleMeaning) ────────
# The label/meaning prose is folded into ONE manifest source (au-w5-status-prose-
# parity): the legend prints roleLabel, the board sentence-cases it, and the
# gloss is roleMeaning. Both are inlined in gridblocks.go (the go-list-deps
# invariant forbids importing the Elixir vocab) so they're byte-checked here,
# mirroring Part 3 — missing role / orphan / mismatch fails.
def parse_go_map(name):
    mm = re.search(r"var %s = map\[string\]string\{(.*?)\n\}" % name, go, re.DOTALL)
    if not mm:
        print(f"status-manifest-check part 4: FAILED — `var {name} = map[string]string{{...}}` "
              "not found in gridblocks.go.", file=sys.stderr)
        sys.exit(1)
    return dict(re.findall(r'"([a-z_]+)":\s*"([^"]*)"', mm.group(1)))

go_label = parse_go_map("roleLabel")
go_meaning = parse_go_map("roleMeaning")

man_label = {r["role"]: r["label"] for r in m["roles"]}
man_meaning = {r["role"]: r["meaning"] for r in m["roles"]}

p4_fails = []
for field, go_map, man_map in (("label", go_label, man_label), ("meaning", go_meaning, man_meaning)):
    for role in sorted(man_map):
        want, got = man_map[role], go_map.get(role)
        if got is None:
            p4_fails.append(f"  {field}[{role!r}]: MISSING from Go role{field.capitalize()} (manifest {want!r})")
        elif got != want:
            p4_fails.append(f"  {field}[{role!r}]: Go {got!r} != manifest {want!r}")
    orphan = set(go_map) - set(man_map)
    if orphan:
        p4_fails.append(f"  Go role{field.capitalize()} has extra role(s) not in the manifest: {sorted(orphan)}")

if p4_fails:
    print("status-manifest-check part 4: FAILED — Go pdrender label/meaning is STALE vs "
          "design/status-manifest.json:", file=sys.stderr)
    for f in p4_fails:
        print(f, file=sys.stderr)
    print("\n  Fix: edit internal/pdrender/gridblocks.go (roleLabel / roleMeaning) to "
          "match design/status-manifest.json.", file=sys.stderr)
    sys.exit(1)
print(f"status-manifest-check part 4: PASS — Go pdrender label+meaning in lockstep "
      f"({len(man_label)} labels, {len(man_meaning)} meanings).")

# ── Part 5: JS/TS status-vocabulary twins ────────────────────────────────────
# Two hand-maintained TS copies mirror the manifest (the generator is deferred,
# tlv-bl-js-vocab-generator): STATUS_ROLES in the react package (the legend
# vocabulary) and STATUS_LADDER in the web app (the board ladder). Byte-check
# each array literal against the manifest — role set, manifest ORDER, glyph and
# label. The JS-only fail-open `unknown` sentinel (D11) is NEVER a lifecycle
# state, so it is the ONE sanctioned non-manifest role; any other extra, any
# missing role, any reorder, any glyph/label mismatch reds this gate.
SANCTIONED_EXTRA = {"unknown"}
# The apps/mobile surface key, as it appears in the manifest's platform_overrides.
mobile_surface = "apps/mobile"
# `cancel` resolves and renders on mobile but is NOT a board lane: the web folds
# cancelled rows into a tally rather than giving them a column, and mobile mirrors
# that. Recorded here so the lane assertion stays a check against manifest ORDER
# rather than a second hand-kept list.
MOBILE_NON_LANE_ROLES = {"cancel"}
man_roles_order = [r["role"] for r in m["roles"]]
p5_glyph = {r["role"]: r["glyph"] for r in m["roles"]}
p5_label = {r["role"]: r["label"] for r in m["roles"]}

def parse_ts_ladder(path, var):
    """Extract the ordered [(role, glyph, label), ...] from a `const <var> = [...]`
    TS array literal, tolerating single OR double quotes and multi-line objects.
    The objects hold no nested [] or {}, so a flat scan is exact."""
    txt = open(path).read()
    am = re.search(re.escape(var) + r"[^=]*=\s*\[(.*?)\n\]", txt, re.DOTALL)
    if not am:
        print(f"status-manifest-check part 5: FAILED — `{var} = [...]` array literal "
              f"not found in {path}.", file=sys.stderr)
        sys.exit(1)
    rows = []
    for obj in re.finditer(r"\{([^{}]*)\}", am.group(1), re.DOTALL):
        body = obj.group(1)
        # (?<![A-Za-z_]) so `glyph_role:` does NOT match `role:`/`glyph:`.
        rm = re.search(r"(?<![A-Za-z_])role:\s*['\"]([^'\"]*)['\"]", body)
        gm = re.search(r"(?<![A-Za-z_])glyph:\s*['\"]([^'\"]*)['\"]", body)
        lm = re.search(r"(?<![A-Za-z_])label:\s*['\"]([^'\"]*)['\"]", body)
        if not (rm and gm and lm):
            continue
        rows.append((rm.group(1), gm.group(1), lm.group(1)))
    return rows

p5_fails = []
p5_counts = []
for path, var in ((react_path, "STATUS_ROLES"), (web_path, "STATUS_LADDER")):
    rows = parse_ts_ladder(path, var)
    if not rows:
        p5_fails.append(f"  {var} ({path}): parsed ZERO role objects — the literal shape changed.")
        continue
    ts_order = [r[0] for r in rows]
    ts_by_role = {}
    for role, glyph, label in rows:
        if role in ts_by_role:
            p5_fails.append(f"  {var} ({path}): duplicate role {role!r} in the array")
        ts_by_role[role] = (glyph, label)
    # Non-manifest roles: only the sanctioned `unknown` sentinel is allowed.
    for r in ts_order:
        if r not in p5_glyph and r not in SANCTIONED_EXTRA:
            p5_fails.append(f"  {var} ({path}): non-manifest role {r!r} not in the "
                            f"sanctioned set {sorted(SANCTIONED_EXTRA)} (hand-added?)")
    # Every manifest role must be present.
    for r in man_roles_order:
        if r not in ts_by_role:
            p5_fails.append(f"  {var} ({path}): MISSING manifest role {r!r} "
                            f"(glyph {p5_glyph[r]!r}, label {p5_label[r]!r})")
    # The manifest roles, in the order they appear in the TS, must equal manifest order.
    ts_manifest_seq = [r for r in ts_order if r in p5_glyph]
    if ts_manifest_seq != man_roles_order:
        p5_fails.append(f"  {var} ({path}): manifest roles OUT OF ORDER — "
                        f"got {ts_manifest_seq}, want {man_roles_order}")
    # Glyph + label byte-equality per manifest role.
    for r in man_roles_order:
        if r in ts_by_role:
            g, l = ts_by_role[r]
            if g != p5_glyph[r]:
                p5_fails.append(f"  {var} ({path}): glyph[{r!r}] = {g!r} != manifest {p5_glyph[r]!r}")
            if l != p5_label[r]:
                p5_fails.append(f"  {var} ({path}): label[{r!r}] = {l!r} != manifest {p5_label[r]!r}")
    p5_counts.append(f"{var}={len(rows)} roles")

if p5_fails:
    print("status-manifest-check part 5: FAILED — a JS/TS status-vocabulary twin is STALE vs "
          "design/status-manifest.json:", file=sys.stderr)
    for f in p5_fails:
        print(f, file=sys.stderr)
    print("\n  Fix: edit the TS array to match design/status-manifest.json — "
          "js/packages/react/src/inline.tsx (STATUS_ROLES) / "
          "web/lib/component-projections.ts (STATUS_LADDER). Byte-equal role order, "
          "glyph and label; the JS-only `unknown` sentinel is the ONLY sanctioned "
          "non-manifest role. (The generator that would remove this hand-copy is "
          "deferred: tlv-bl-js-vocab-generator.)", file=sys.stderr)
    sys.exit(1)
print(f"status-manifest-check part 5: PASS — JS/TS vocab twins in lockstep "
      f"({len(man_roles_order)} manifest roles, order+glyph+label byte-equal; {', '.join(p5_counts)}).")

# ── Part 5b: apps/mobile — the THIRD hand-maintained twin ────────────────────
# It was absent from this gate entirely until mob-bl-status-manifest-mobile-gate,
# so mobile's copy of the whole vocabulary had no drift check at all; the file's
# own header said the guard was a comment.
#
# WHY ITS OWN READER. react and web each hold ONE array-of-objects that
# parse_ts_ladder can walk. Mobile holds FOUR separate literals — STATUS_TO_ROLE
# and ROLE_GLYPH and ROLE_LABEL as `Record<string, string>` maps, plus a
# BOARD_ROLES string array — because a React Native block renderer resolves a
# status to a role and then looks up glyph/label/hue separately. Forcing that
# into the array reader would mean reshaping the shipped source to suit the gate.
#
# THE TWO SANCTIONED DIFFERENCES, both mechanical and both CHECKED, not skipped:
#   1. GLYPH: `progress` diverges, and the divergence is ADJUDICATED IN THE
#      MANIFEST (platform_overrides) rather than hardcoded here — the manifest
#      gives it an empty glyph with spinner:true because the web CSS-animates
#      Braille frames, and a pure D50 renderer would paint a blank cell. The
#      override is held honest below: it must name a real role, must ACTUALLY
#      differ, and the set of roles that diverge must EQUAL the set declared —
#      so a second drift can never hide behind the sanctioned one.
#   2. LABEL: mobile renders labels as column headings and sentence-cases the
#      first character ("in progress" -> "In progress"). That is a mechanical
#      relation, not a licence to diverge: asserting it still catches
#      "In Progress", a renamed label, or a dropped role.
# The JS-only `unknown` sentinel (D11) is the one sanctioned non-manifest role,
# exactly as for the other two twins.

def parse_ts_record(txt, var, path):
    """Extract the ordered [(key, value), ...] from a `const <var>: T = { ... }`
    TS object literal of string->string. Values hold no nested braces, so a flat
    scan to the first line that is exactly `}` is exact."""
    am = re.search(r"(?:export\s+)?const\s+" + re.escape(var) + r"\b[^=]*=\s*\{(.*?)\n\}", txt, re.DOTALL)
    if am is None:
        print(f"status-manifest-check part 5: FAILED — `{var} = {{...}}` object literal "
              f"not found in {path}. The vocabulary moved or was renamed; this gate "
              f"reads THAT literal and cannot check what it cannot find.", file=sys.stderr)
        sys.exit(1)
    rows = []
    for line in am.group(1).split("\n"):
        line = line.strip()
        if line.startswith("//") or line.startswith("*") or line.startswith("/*"):
            continue
        # `key: 'value',` — key may be bare or quoted; value is single/double quoted.
        km = re.match(r"^['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?\s*:\s*['\"](.*)['\"]\s*,?\s*$", line)
        if km:
            rows.append((km.group(1), km.group(2)))
    return rows


def parse_ts_string_array(txt, var, path):
    """Extract the ordered [value, ...] from a `const <var>: T = [ ... ]` TS array
    literal of plain strings."""
    am = re.search(r"(?:export\s+)?const\s+" + re.escape(var) + r"\b[^=]*=\s*\[(.*?)\n\]", txt, re.DOTALL)
    if am is None:
        print(f"status-manifest-check part 5: FAILED — `{var} = [...]` array literal "
              f"not found in {path}.", file=sys.stderr)
        sys.exit(1)
    return re.findall(r"['\"]([^'\"]+)['\"]", am.group(1))


mobile_txt = open(mobile_path).read()
mob_status_to_role = parse_ts_record(mobile_txt, "STATUS_TO_ROLE", mobile_path)
mob_glyph = parse_ts_record(mobile_txt, "ROLE_GLYPH", mobile_path)
mob_label = parse_ts_record(mobile_txt, "ROLE_LABEL", mobile_path)
mob_board = parse_ts_string_array(mobile_txt, "BOARD_ROLES", mobile_path)

overrides = (m.get("platform_overrides") or {}).get(mobile_surface, {})
overrides = {k: v for k, v in overrides.items() if not k.startswith("$")}

p5b = []
if not mob_glyph or not mob_label or not mob_status_to_role:
    p5b.append(f"  {mobile_path}: parsed ZERO entries from one of STATUS_TO_ROLE / "
               f"ROLE_GLYPH / ROLE_LABEL — the literal shape changed.")

mob_glyph_by = dict(mob_glyph)
mob_label_by = dict(mob_label)
mob_s2r = dict(mob_status_to_role)

# STATUS -> ROLE: exactly the manifest's statuses map, aliases and terminals included.
for status, role in m["statuses"].items():
    if status not in mob_s2r:
        p5b.append(f"  STATUS_TO_ROLE: MISSING manifest status {status!r} (-> {role!r})")
    elif mob_s2r[status] != role:
        p5b.append(f"  STATUS_TO_ROLE[{status!r}] = {mob_s2r[status]!r} != manifest {role!r}")
for status in mob_s2r:
    if status not in m["statuses"]:
        p5b.append(f"  STATUS_TO_ROLE: non-manifest status {status!r} (hand-added?)")

# ROLE SET, in both tables: the manifest roles plus the ONE sanctioned sentinel.
for var, table in (("ROLE_GLYPH", mob_glyph_by), ("ROLE_LABEL", mob_label_by)):
    for r in man_roles_order:
        if r not in table:
            p5b.append(f"  {var}: MISSING manifest role {r!r}")
    for r in table:
        if r not in p5_glyph and r not in SANCTIONED_EXTRA:
            p5b.append(f"  {var}: non-manifest role {r!r} not in the sanctioned set "
                       f"{sorted(SANCTIONED_EXTRA)} (hand-added?)")
    # ORDER: the manifest roles, in the order they appear, must equal manifest order.
    seq = [k for k, _ in (mob_glyph if var == "ROLE_GLYPH" else mob_label) if k in p5_glyph]
    if seq != man_roles_order:
        p5b.append(f"  {var}: manifest roles OUT OF ORDER — got {seq}, want {man_roles_order}")

# GLYPH: byte-equal to the manifest, or to the manifest's own recorded override.
for r in man_roles_order:
    if r not in mob_glyph_by:
        continue
    want = overrides[r]["glyph"] if r in overrides else p5_glyph[r]
    if mob_glyph_by[r] != want:
        where = "platform_overrides" if r in overrides else "manifest"
        p5b.append(f"  ROLE_GLYPH[{r!r}] = {mob_glyph_by[r]!r} != {where} {want!r}")

# THE OVERRIDES ARE HELD HONEST — a sanctioned exception that stops earning its
# keep, or one that hides a second drift, reds here.
for r, ov in overrides.items():
    if r not in p5_glyph:
        p5b.append(f"  platform_overrides[{mobile_surface!r}][{r!r}]: not a manifest role")
        continue
    if ov.get("glyph") == p5_glyph[r]:
        p5b.append(f"  platform_overrides[{mobile_surface!r}][{r!r}]: override equals the "
                   f"manifest glyph {p5_glyph[r]!r} — it no longer earns its exemption, delete it")
    if len((ov.get("reason") or "").strip()) < 40:
        p5b.append(f"  platform_overrides[{mobile_surface!r}][{r!r}]: a ruling needs a reason "
                   f"(>=40 chars) saying why conforming would be WRONG")
diverging = sorted(r for r in man_roles_order
                   if r in mob_glyph_by and mob_glyph_by[r] != p5_glyph[r])
if diverging != sorted(overrides):
    p5b.append(f"  platform_overrides[{mobile_surface!r}]: the roles that ACTUALLY diverge "
               f"{diverging} != the roles declared {sorted(overrides)} — every divergence is a "
               f"ruling or it is drift; nothing hides behind a sanctioned one")

# LABEL: the manifest label, sentence-cased. Mechanical, and still byte-exact.
for r in man_roles_order:
    if r not in mob_label_by:
        continue
    lab = p5_label[r]
    want = lab[:1].upper() + lab[1:]
    if mob_label_by[r] != want:
        p5b.append(f"  ROLE_LABEL[{r!r}] = {mob_label_by[r]!r} != sentence-cased manifest {want!r}")

# BOARD LANES: manifest ORDER, minus the roles that are not lanes.
want_board = [r for r in man_roles_order if r not in MOBILE_NON_LANE_ROLES]
if mob_board != want_board:
    p5b.append(f"  BOARD_ROLES: {mob_board} != manifest order minus "
               f"{sorted(MOBILE_NON_LANE_ROLES)} = {want_board}")

if p5b:
    print("status-manifest-check part 5: FAILED — the apps/mobile status-vocabulary twin is "
          "STALE vs design/status-manifest.json:", file=sys.stderr)
    for f in p5b:
        print(f, file=sys.stderr)
    print(f"\n  Fix: edit {mobile_path} to match design/status-manifest.json — "
          f"STATUS_TO_ROLE mirrors `statuses`; ROLE_GLYPH and ROLE_LABEL carry every "
          f"manifest role in manifest ORDER plus the `unknown` sentinel; labels are the "
          f"manifest label sentence-cased; BOARD_ROLES is manifest order minus "
          f"{sorted(MOBILE_NON_LANE_ROLES)}. A glyph that MUST differ on this platform is a "
          f"RULING and belongs in the manifest's platform_overrides with its reason — never "
          f"as a silent skip here. The sibling pin that runs inside the mobile suite is "
          f"apps/mobile/__tests__/statusManifestParity.test.ts.", file=sys.stderr)
    sys.exit(1)
print(f"status-manifest-check part 5b: PASS — apps/mobile vocab twin in lockstep "
      f"({len(mob_s2r)} statuses, {len(mob_glyph_by)} roles, {len(mob_board)} board lanes; "
      f"{len(overrides)} recorded platform override(s)).")
PY
