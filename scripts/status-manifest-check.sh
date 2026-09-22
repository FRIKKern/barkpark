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
#   Part 5 — RETIRED (tlv-bl-js-vocab-generator). The react `STATUS_ROLES` and web
#     `STATUS_LADDER` twins used to be hand-maintained TS literals byte-checked
#     here. They are now GENERATED from the manifest by design/emit.mjs into
#     js/packages/react/src/status-vocab.gen.ts and web/lib/status-ladder.gen.ts,
#     so there is no hand copy left to drift: a byte-check of a generated file
#     against its own source is a tautology. design/check.mjs Part A re-emits both
#     from design/status-manifest.json and byte-compares the committed files, so a
#     HAND-EDIT of either generated file (or a manifest edit without a regen) reds
#     the design-token drift gate instead of this one.
#   Part 5b — apps/mobile: NO LONGER A HAND COPY EITHER. taskboard.tsx now reads
#     design/emit.mjs' "mobile status vocabulary" artifact
#     (apps/mobile/src/papers/portabledoc/blocks/status-vocab.gen.ts), so the last
#     hand-typed JS/TS vocabulary in the repo is gone. What survives here is a
#     FRESHNESS assertion plus the two things design/check.mjs Part A structurally
#     cannot make: the DERIVATION LOCK (taskboard.tsx still reads the projection
#     rather than retyping one) and OVERRIDE HONESTY (the manifest's own
#     platform_overrides ruling must name a real role, actually differ, carry a
#     reason, and be exhaustive — the emitter APPLIES that ruling, so a byte-parity
#     check agrees with whatever it says).
#
# The Elixir emitters need no check here: Render.StatusVocab reads THIS manifest
# at compile time, so they cannot diverge by construction.
#
# Usage: scripts/status-manifest-check.sh [--write | --selftest]
#
#   --selftest — prove every part above can still RED. Until cgsi-bl-status-
#     manifest-no-selftest this gate had NO selftest at all (its only modes were
#     the bare check and --write), so none of its five parts had ever been shown
#     to fail on a planted violation: a comparator that quietly stopped
#     discriminating would have gone on printing PASS lines forever. The harness
#     builds a THROWAWAY copy of the tree (this script plus the four files it
#     reads), plants ONE violation per arm, re-invokes THIS script inside that
#     copy — so the assertions drive the shipping comparator, not a second copy
#     of it — and then restores the planted file and re-runs to prove the arm
#     greens again. It plants NOTHING in this repo.
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$(dirname "$0")/.."

MANIFEST="design/status-manifest.json"
CSS="api/assets/paper-surface/paper-surface.css"
GO="internal/pdrender/gridblocks.go"
# apps/mobile: the surface that READS the generated vocabulary. It was absent
# from this gate entirely until mob-bl-status-manifest-mobile-gate, then a hand
# copy byte-checked here, and is now a consumer of the emitter like react and web.
MOBILE_TSX="apps/mobile/src/papers/portabledoc/blocks/taskboard.tsx"
# …and the GENERATED projection it reads (design/emit.mjs artifact "mobile status
# vocabulary"). Part 5b asserts THIS file is fresh vs the manifest and that
# MOBILE_TSX still derives from it rather than retyping a copy.
MOBILE_GEN_TS="apps/mobile/src/papers/portabledoc/blocks/status-vocab.gen.ts"
# `MODE="${1:-check}"` used to pass ANY argument straight through to the Python,
# which treats everything that is not `--write` as check mode — so a typo, or a
# `--selftest` this gate did not have, ran the ordinary check and exited 0.
# Refuse what we do not understand instead. `--selftest` is whitelisted here
# (cgsi-bl-status-manifest-no-selftest) and handled below, BEFORE the Python:
# it never reaches the check body's argv.
MODE="check"
if [ "${1:-}" = "--write" ]; then
  MODE="--write"
elif [ "${1:-}" = "--selftest" ]; then
  MODE="selftest"
elif [ -n "${1:-}" ]; then
  echo "status-manifest-check: unknown argument '$1' (expected --write, --selftest or none)" >&2
  exit 2
fi

# ── selftest: prove each part can still RED, and greens again on restore ─────
#
# The four files above ARE the gate's whole input. Each arm copies them (plus
# this script) into a throwaway tree, plants exactly ONE violation, and runs the
# copied script there — `cd "$(dirname "$0")/.."` makes the copy read the
# throwaway tree, so the REAL parts run against the planted corpus and this repo
# is never touched. Every arm asserts three things, in this order:
#   1. the PLANT actually changed bytes (a silently-failed plant would make the
#      green that follows vacuous — the planter exits 3 and the arm fails),
#   2. the gate exits 1 and NAMES the part it reds in,
#   3. restoring that one file from the real tree greens the gate again — so the
#      red is attributable to the plant and not to a broken throwaway tree.
ST_PLANT_PY='
import json, re, sys
root, kind = sys.argv[1], sys.argv[2]
CSS  = root + "/api/assets/paper-surface/paper-surface.css"
GO   = root + "/internal/pdrender/gridblocks.go"
MOB  = root + "/apps/mobile/src/papers/portabledoc/blocks/taskboard.tsx"
MOBG = root + "/apps/mobile/src/papers/portabledoc/blocks/status-vocab.gen.ts"
MAN  = root + "/design/status-manifest.json"

def rd(p): return open(p).read()
def wr(p, s): open(p, "w").write(s)

man = json.load(open(MAN))
first_role = man["roles"][0]["role"]

def go_first_value(txt, name, newval):
    mm = re.search(r"var %s = map\[string\]string\{(.*?)\n\}" % name, txt, re.DOTALL)
    if not mm:
        print("PLANT FAILED: var %s not found" % name, file=sys.stderr); sys.exit(3)
    body = mm.group(1)
    em = re.search(r"\"([a-z_]+)\":\s*\"([^\"]*)\"", body)
    if not em:
        print("PLANT FAILED: no entry inside %s" % name, file=sys.stderr); sys.exit(3)
    s, e = mm.start(1) + em.start(2), mm.start(1) + em.end(2)
    return txt[:s] + newval + txt[e:], "drifted %s[%s] from %r to %r" % (name, em.group(1), em.group(2), newval)

if kind == "tone":
    txt = rd(CSS)
    mk = re.search(r"(/\* BEGIN GENERATED: status-tones[^\n]*\*/\n)(.*?)(\n/\* END GENERATED: status-tones \*/)", txt, re.DOTALL)
    if not mk:
        print("PLANT FAILED: tone markers not found", file=sys.stderr); sys.exit(3)
    blk = mk.group(2)
    tm = re.search(r"(--st-[a-z0-9-]+:\s*)([^;]+)(;)", blk)
    if not tm:
        print("PLANT FAILED: no --st-* token in the generated block", file=sys.stderr); sys.exit(3)
    newblk = blk[:tm.start(2)] + "#010203" + blk[tm.end(2):]
    out, note = txt[:mk.start(2)] + newblk + txt[mk.end(2):], "hand-drifted the %svalue in the generated tone block to #010203" % tm.group(1)
    path = CSS
elif kind == "orphan-glyph":
    txt = rd(CSS); out = txt + "\n.bp-g--zzdrift::before { content: \"?\"; }\n"
    note = "hand-added an orphan glyph class .bp-g--zzdrift (no such manifest role)"; path = CSS
elif kind == "missing-glyph":
    txt = rd(CSS); out = txt.replace(".bp-g--" + first_role, ".bp-hidden-g--" + first_role)
    note = "renamed the .bp-g--%s rule out of existence (manifest role loses its glyph class)" % first_role; path = CSS
elif kind == "go-glyph":
    txt = rd(GO); out, note = go_first_value(txt, "roleGlyph", "¤"); path = GO
elif kind == "go-label":
    txt = rd(GO); out, note = go_first_value(txt, "roleLabel", "drifted"); path = GO
elif kind == "mobile-gen-label":
    # THE FRESHNESS ARM: hand-edit the GENERATED projection. Part 5b must catch a
    # generated file that no longer matches the manifest (the same edit
    # design/check.mjs Part A catches from the byte-parity side).
    txt = rd(MOBG)
    am = re.search(r"(?:export\s+)?const\s+MANIFEST_ROLE_LABEL\b[^=]*=\s*\{(.*?)\n\}", txt, re.DOTALL)
    if not am:
        print("PLANT FAILED: MANIFEST_ROLE_LABEL object not found", file=sys.stderr); sys.exit(3)
    em = re.search(r"([A-Za-z_][A-Za-z0-9_]*\s*:\s*.)([^\x27\"]*)(.\s*,)", am.group(1))
    if not em:
        print("PLANT FAILED: no entry inside MANIFEST_ROLE_LABEL", file=sys.stderr); sys.exit(3)
    s, e = am.start(1) + em.start(2), am.start(1) + em.end(2)
    out = txt[:s] + "Drifted" + txt[e:]
    note = "hand-drifted the first MANIFEST_ROLE_LABEL value in the GENERATED file to Drifted"
    path = MOBG
elif kind == "mobile-retype":
    # THE DERIVATION-LOCK ARM: put a hand-typed copy BACK into taskboard.tsx. This
    # is the edit that would make every freshness check above vacuous — the surface
    # would stop reading the projection and nothing downstream would notice.
    txt = rd(MOB)
    am = re.search(r"(export const ROLE_LABEL: Record<string, string> = \{)(.*?)(\n\})", txt, re.DOTALL)
    if not am:
        print("PLANT FAILED: ROLE_LABEL spread declaration not found", file=sys.stderr); sys.exit(3)
    man = json.load(open(MAN))
    body = "\n" + "\n".join("  %s: 'Retyped'," % r["role"] for r in man["roles"]) + "\n  unknown: 'Unknown',"
    out = txt[:am.start(2)] + body + txt[am.end(2):]
    note = "retyped the whole ROLE_LABEL table beside the manifest instead of reading the projection"
    path = MOB
else:
    print("PLANT FAILED: unknown plant kind %r" % kind, file=sys.stderr); sys.exit(3)

if out == txt:
    print("PLANT FAILED: %s is byte-identical after planting %r" % (path, kind), file=sys.stderr)
    sys.exit(3)
wr(path, out)
print(note)
print(path)
'

st_selftest() {
  local tmp bad=0 total=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  local -a INPUTS=(
    "design/status-manifest.json"
    "api/assets/paper-surface/paper-surface.css"
    "internal/pdrender/gridblocks.go"
    "apps/mobile/src/papers/portabledoc/blocks/taskboard.tsx"
    "apps/mobile/src/papers/portabledoc/blocks/status-vocab.gen.ts"
  )

  say() {
    total=$((total + 1))
    if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; bad=$((bad + 1)); fi
  }

  mk_tree() {
    local d="$1" f
    rm -rf "$d"; mkdir -p "$d/scripts"
    cp "$SELF" "$d/scripts/status-manifest-check.sh"
    for f in "${INPUTS[@]}"; do
      mkdir -p "$d/$(dirname "$f")"
      cp "$ROOT/$f" "$d/$f"
    done
  }

  run_tree() { # $1 tree, $2 output file -> echoes rc
    local rc=0
    bash "$1/scripts/status-manifest-check.sh" > "$2" 2>&1 || rc=$?
    echo "$rc"
  }

  arm() { # $1 label, $2 plant kind, $3 expected part token in stderr
    local label="$2" kind="$2" want="$3" d="$tmp/t" rc plantrc note path
    label="$1"
    mk_tree "$d"

    # CONTROL: the throwaway tree, unplanted, must GREEN. A red here means the
    # copy itself is broken and every "red" below would be unattributable.
    rc="$(run_tree "$d" "$tmp/pre")"
    if [ "$rc" -ne 0 ]; then
      say "$label — pristine throwaway tree GREENS before planting (got $rc)" 1
      sed 's/^/        /' "$tmp/pre"
      return
    fi

    plantrc=0
    python3 -c "$ST_PLANT_PY" "$d" "$kind" > "$tmp/plant" 2>&1 || plantrc=$?
    if [ "$plantrc" -ne 0 ]; then
      say "$label — plant applied (planter exit $plantrc)" 1
      sed 's/^/        /' "$tmp/plant"
      return
    fi
    note="$(sed -n '1p' "$tmp/plant")"
    path="$(sed -n '2p' "$tmp/plant")"

    rc="$(run_tree "$d" "$tmp/out")"
    if [ "$rc" -eq 1 ] && grep -q "$want" "$tmp/out"; then
      say "$label — RED (exit 1, \"$want\"): $note" 0
    else
      say "$label — expected exit 1 naming \"$want\", got $rc: $note" 1
      sed 's/^/        /' "$tmp/out"
      return
    fi

    # RESTORE: put the single planted file back; the same tree must GREEN again.
    cp "$ROOT/${path#$d/}" "$path"
    rc="$(run_tree "$d" "$tmp/post")"
    if [ "$rc" -eq 0 ]; then
      say "$label — GREEN again after restoring ${path#$d/}" 0
    else
      say "$label — restore should GREEN, got $rc" 1
      sed 's/^/        /' "$tmp/post"
    fi
  }

  echo "status-manifest-check --selftest (throwaway tree; plants nothing in this repo)"

  arm "part 1 tone block"        tone           "part 1: FAILED"
  arm "part 2 orphan glyph"      orphan-glyph   "part 2: FAILED"
  arm "part 2 missing glyph"     missing-glyph  "part 2: FAILED"
  arm "part 3 Go roleGlyph"      go-glyph       "part 3: FAILED"
  arm "part 4 Go roleLabel"      go-label       "part 4: FAILED"
  arm "part 5b generated drift"  mobile-gen-label  "part 5: FAILED"
  arm "part 5b retyped table"    mobile-retype     "part 5: FAILED"

  # ARG DISPATCH — an unknown flag is still a refusal (2), not a silent check.
  local rc=0
  bash "$SELF" --no-such-flag > "$tmp/arg" 2>&1 || rc=$?
  if [ "$rc" -eq 2 ] && grep -q -- "--no-such-flag" "$tmp/arg"; then
    say "unknown argument -> exit 2, names the argument" 0
  else
    say "unknown argument -> exit 2, names the argument (got $rc)" 1
    sed 's/^/        /' "$tmp/arg"
  fi

  echo ""
  if [ "$bad" -eq 0 ]; then
    echo "status-manifest-check --selftest: PASS ($total/$total)"
    return 0
  fi
  echo "status-manifest-check --selftest: FAILED ($bad of $total case(s))"
  return 1
}

if [ "$MODE" = "selftest" ]; then
  st_selftest
  exit $?
fi

python3 - "$MANIFEST" "$CSS" "$MODE" "$GO" "$MOBILE_TSX" "$MOBILE_GEN_TS" <<'PY'
import json, re, sys

manifest_path, css_path, mode, go_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
mobile_path = sys.argv[5]
mobile_gen_path = sys.argv[6]
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

# ── Part 5: RETIRED — the react + web twins are GENERATED ────────────────────
# tlv-bl-js-vocab-generator. `STATUS_ROLES` (js/packages/react/src/inline.tsx)
# and `STATUS_LADDER` (web/lib/component-projections.ts) were hand-typed copies
# of the manifest, and this part byte-checked them. Both now come from
# design/emit.mjs artifacts generated OFF THIS MANIFEST:
#   js/packages/react/src/status-vocab.gen.ts   (MANIFEST_STATUS_ROLES, …)
#   web/lib/status-ladder.gen.ts                (STATUS_LADDER, …)
# A generated file cannot drift from its own source, so re-checking it here would
# assert a tautology. What CAN still go wrong is someone hand-editing a generated
# file or landing a manifest edit without regenerating — and design/check.mjs
# Part A catches exactly that, by re-emitting both artifacts from this manifest
# and byte-comparing the committed bytes (CI: doc-gates "Design-token drift
# gate"). The react vocabulary is additionally pinned behaviourally by
# js/packages/react/tests/status-manifest-parity.test.ts, which imports the real
# constants and compares them to THIS file.
#
# The definitions below are NOT part 5 leftovers: part 5b (the one remaining
# hand-maintained twin, apps/mobile) reads them.
SANCTIONED_EXTRA = {"unknown"}
# The apps/mobile surface key, as it appears in the manifest's platform_overrides.
mobile_surface = "apps/mobile"
# The TERMINAL rung. Since task-881952f8d8417f4b every manifest role IS a board
# lane on every surface — `cancel` included — but it sorts LAST rather than in its
# manifest position, because a cancelled row is abandoned work and must neither
# vanish (the old drop) nor sit in `open`, the claimable lane `bp task ready`
# serves. Recorded here so the lane assertion stays a check against manifest ORDER
# rather than a second hand-kept list.
MOBILE_TERMINAL_ROLES = ["cancel"]
man_roles_order = [r["role"] for r in m["roles"]]
p5_glyph = {r["role"]: r["glyph"] for r in m["roles"]}
p5_label = {r["role"]: r["label"] for r in m["roles"]}
print("status-manifest-check part 5: RETIRED — the react + web vocabulary twins are "
      "GENERATED from this manifest (design/emit.mjs -> status-vocab.gen.ts / "
      "status-ladder.gen.ts); design/check.mjs Part A byte-checks them.")

# ── Part 5b: apps/mobile — a FRESHNESS assertion over the GENERATED twin ─────
# It used to byte-check a hand-typed copy. That copy is gone: apps/mobile now
# reads design/emit.mjs' `mobile status vocabulary` artifact,
# apps/mobile/src/papers/portabledoc/blocks/status-vocab.gen.ts, exactly as the
# react and web surfaces read theirs (the Part 5 retirement above).
#
# WHY THIS PART STILL EXISTS AT ALL. A byte-check of a generated file against its
# own source is a tautology, and design/check.mjs Part A already re-emits this
# artifact and byte-compares the committed bytes. What Part A does NOT do is hold
# design/status-manifest.json's own `platform_overrides` honest — the ruling that
# lets mobile diverge on `progress` lives in the MANIFEST, is applied BY the
# emitter, and would therefore be self-consistent with any value someone typed
# into it. So this part now asserts three things Part A cannot:
#   1. FRESHNESS — the committed generated file is in lockstep with the manifest
#      (statuses, role set, manifest ORDER, glyphs incl. overrides, sentence-cased
#      labels, default_role). This is the direction .github/workflows/mobile.yml
#      cannot see: it triggers on apps/mobile/**, never on design/**.
#   2. THE DERIVATION LOCK — apps/mobile's taskboard.tsx still READS the generated
#      projection instead of retyping it. A hand-typed role table coming back is
#      precisely the drift this gate exists to catch, and it is the edit that
#      would make every check above vacuous.
#   3. OVERRIDE HONESTY — every recorded override names a real role, ACTUALLY
#      differs from the manifest glyph, carries a stated reason, and the set of
#      roles that genuinely diverge EQUALS the set declared. Nothing hides behind
#      a sanctioned exception, and an exception that stops earning its keep reds.
# The JS-only `unknown` sentinel (D11) is the one sanctioned non-manifest role.
# It is NOT in the generated file — taskboard.tsx appends it, which is why it is
# the one role literal the derivation lock below permits there.

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


def parse_ts_record_optional(txt, var):
    """parse_ts_record, but a MISSING literal is the healthy case, not a failure:
    taskboard.tsx's tables are spreads of the generated Records now, so there IS no
    `{...}` literal to read there unless someone retyped one. Returns [] when the
    declaration carries no object literal."""
    am = re.search(r"(?:export\s+)?const\s+" + re.escape(var) + r"\b[^=]*=\s*\{(.*?)\n\}", txt, re.DOTALL)
    if am is None:
        return []
    rows = []
    for line in am.group(1).split("\n"):
        line = line.strip()
        if line.startswith("//") or line.startswith("*") or line.startswith("/*"):
            continue
        km = re.match(r"^['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?\s*:\s*['\"](.*)['\"]\s*,?\s*$", line)
        if km:
            rows.append((km.group(1), km.group(2)))
    return rows


def parse_ts_decl_body(txt, var, path):
    """Extract the raw right-hand side of a `const <var>[: T] = ...` declaration,
    up to the line that closes it. Used where the value is DERIVED (an expression)
    rather than a literal this gate could parse."""
    am = re.search(r"(?:export\s+)?const\s+" + re.escape(var) + r"\b[^=]*=\s*(.*?)\n(?:\]|\}|$)",
                   txt, re.DOTALL)
    if am is None:
        print(f"status-manifest-check part 5: FAILED — `const {var}` declaration not "
              f"found in {path}.", file=sys.stderr)
        sys.exit(1)
    return am.group(1)


gen_txt = open(mobile_gen_path).read()
mobile_txt = open(mobile_path).read()

p5b = []

# 0. ATTRIBUTION. The generated file must SAY it is generated, and name both the
#    emitter and the source — a file that loses its header is a file the next
#    reader hand-edits in good faith.
gen_head = "\n".join(gen_txt.split("\n")[:3])
if "Code generated by design/emit.mjs" not in gen_head or "design/status-manifest.json" not in gen_head:
    p5b.append(f"  {mobile_gen_path}: the first 3 lines do not carry the generated-by header "
               f"naming design/emit.mjs AND design/status-manifest.json.")

gen_s2r = dict(parse_ts_record(gen_txt, "MANIFEST_STATUS_TO_ROLE", mobile_gen_path))
gen_glyph_rows = parse_ts_record(gen_txt, "MANIFEST_ROLE_GLYPH", mobile_gen_path)
gen_label_rows = parse_ts_record(gen_txt, "MANIFEST_ROLE_LABEL", mobile_gen_path)
gen_glyph = dict(gen_glyph_rows)
gen_label = dict(gen_label_rows)

dm = re.search(r"export const MANIFEST_DEFAULT_ROLE\s*=\s*['\"]([^'\"]*)['\"]", gen_txt)
if dm is None:
    p5b.append(f"  {mobile_gen_path}: MANIFEST_DEFAULT_ROLE not found.")
elif dm.group(1) != m["default_role"]:
    p5b.append(f"  MANIFEST_DEFAULT_ROLE = {dm.group(1)!r} != manifest default_role "
               f"{m['default_role']!r} — STALE, re-run `node design/emit.mjs --write`.")

if not gen_glyph or not gen_label or not gen_s2r:
    p5b.append(f"  {mobile_gen_path}: parsed ZERO entries from one of the three Records — "
               f"the generated shape changed.")

# 1. FRESHNESS: statuses map, verbatim.
for status, role in m["statuses"].items():
    if status not in gen_s2r:
        p5b.append(f"  MANIFEST_STATUS_TO_ROLE: MISSING manifest status {status!r} (-> {role!r})")
    elif gen_s2r[status] != role:
        p5b.append(f"  MANIFEST_STATUS_TO_ROLE[{status!r}] = {gen_s2r[status]!r} != manifest {role!r}")
for status in gen_s2r:
    if status not in m["statuses"]:
        p5b.append(f"  MANIFEST_STATUS_TO_ROLE: non-manifest status {status!r} — STALE regen?")

# 1b. FRESHNESS: the role set and its ORDER, in both tables. The generated file
#     carries the manifest rungs and NOTHING else — the sentinel is appended by
#     taskboard.tsx, so it must NOT appear here.
for var, rows in (("MANIFEST_ROLE_GLYPH", gen_glyph_rows), ("MANIFEST_ROLE_LABEL", gen_label_rows)):
    seq = [k for k, _ in rows]
    if seq != man_roles_order:
        p5b.append(f"  {var}: role keys {seq} != manifest roles in manifest ORDER "
                   f"{man_roles_order} — STALE, re-run `node design/emit.mjs --write`.")
    for r in seq:
        if r in SANCTIONED_EXTRA:
            p5b.append(f"  {var}: carries the {r!r} sentinel — it is NOT a manifest rung and "
                       f"belongs in taskboard.tsx, which appends it.")

overrides = (m.get("platform_overrides") or {}).get(mobile_surface, {})
overrides = {k: v for k, v in overrides.items() if not k.startswith("$")}

# 1c. FRESHNESS: glyph == the manifest's, or the manifest's OWN recorded override.
for r in man_roles_order:
    if r not in gen_glyph:
        continue
    want = overrides[r]["glyph"] if r in overrides else p5_glyph[r]
    if gen_glyph[r] != want:
        where = "platform_overrides" if r in overrides else "manifest"
        p5b.append(f"  MANIFEST_ROLE_GLYPH[{r!r}] = {gen_glyph[r]!r} != {where} {want!r}")

# 1d. FRESHNESS: label == the manifest label, sentence-cased (mobile renders them
#     as column headings). Mechanical, and still byte-exact.
for r in man_roles_order:
    if r not in gen_label:
        continue
    lab = p5_label[r]
    want = lab[:1].upper() + lab[1:]
    if gen_label[r] != want:
        p5b.append(f"  MANIFEST_ROLE_LABEL[{r!r}] = {gen_label[r]!r} != sentence-cased manifest {want!r}")

# 2. THE DERIVATION LOCK. taskboard.tsx must READ the projection, not retype it.
if not re.search(r"from\s+['\"]\./status-vocab\.gen['\"]", mobile_txt):
    p5b.append(f"  {mobile_path}: no import from './status-vocab.gen' — the surface no longer "
               f"reads the generated projection, so nothing derives it from the manifest.")
for var, gen_name in (("STATUS_TO_ROLE", "MANIFEST_STATUS_TO_ROLE"),
                      ("ROLE_GLYPH", "MANIFEST_ROLE_GLYPH"),
                      ("ROLE_LABEL", "MANIFEST_ROLE_LABEL")):
    decl = parse_ts_decl_body(mobile_txt, var, mobile_path)
    if gen_name not in decl:
        p5b.append(f"  {mobile_path}: `const {var}` does not read {gen_name} from the generated "
                   f"projection — it was RETYPED beside the manifest.")
    manifest_keys = set(p5_glyph) | set(m["statuses"])
    retyped = sorted({k for k, _ in parse_ts_record_optional(mobile_txt, var)
                      if k in manifest_keys and k not in SANCTIONED_EXTRA})
    if retyped:
        p5b.append(f"  {mobile_path}: `const {var}` names manifest keys {retyped} as LITERALS. "
                   f"The only literal key this surface may carry is the {sorted(SANCTIONED_EXTRA)} "
                   f"sentinel, which is not a manifest rung; everything else comes from "
                   f"{gen_name}.")

# BOARD LANES: the value is checked in the mobile suite (it imports the real
# constant); what reds HERE is the shape — a hand-typed lane list beside the
# manifest, which is precisely the drift this gate exists to catch. A derivation
# names no manifest roles at all; a retyped list names several.
mob_board_decl = parse_ts_decl_body(mobile_txt, "BOARD_ROLES", mobile_path)
hardcoded_lanes = [r for r in man_roles_order if f"'{r}'" in mob_board_decl or f'"{r}"' in mob_board_decl]
hardcoded_lanes = [r for r in hardcoded_lanes if r not in MOBILE_TERMINAL_ROLES]
if hardcoded_lanes:
    p5b.append(f"  BOARD_ROLES: RETYPED beside the manifest — the declaration names "
               f"manifest roles {hardcoded_lanes} as literals. It must be DERIVED from "
               f"ROLE_LABEL's (manifest-ordered) keys with the terminal rung "
               f"{MOBILE_TERMINAL_ROLES} moved last, so a new manifest rung becomes a "
               f"lane automatically instead of being silently dropped.")
if "ROLE_LABEL" not in mob_board_decl:
    p5b.append("  BOARD_ROLES: the declaration does not read ROLE_LABEL — it is no longer "
               "derived from the manifest-ordered role table.")

# 3. THE OVERRIDES ARE HELD HONEST — a sanctioned exception that stops earning its
#    keep, or one that hides a second drift, reds here. design/check.mjs Part A
#    cannot do this: the emitter APPLIES the override, so the generated file agrees
#    with any value the manifest states.
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
                   if r in gen_glyph and gen_glyph[r] != p5_glyph[r])
if diverging != sorted(overrides):
    p5b.append(f"  platform_overrides[{mobile_surface!r}]: the roles that ACTUALLY diverge "
               f"{diverging} != the roles declared {sorted(overrides)} — every divergence is a "
               f"ruling or it is drift; nothing hides behind a sanctioned one")

if p5b:
    print("status-manifest-check part 5: FAILED — the apps/mobile status vocabulary is STALE "
          "vs design/status-manifest.json, or no longer derived from it:", file=sys.stderr)
    for f in p5b:
        print(f, file=sys.stderr)
    print(f"\n  Fix: the vocabulary is GENERATED — run `node design/emit.mjs --write` to "
          f"re-emit {mobile_gen_path} from design/status-manifest.json, and never hand-edit "
          f"either that file or the tables in {mobile_path} (which must read it). A glyph "
          f"that MUST differ on this platform is a RULING and belongs in the manifest's "
          f"platform_overrides with its reason — never as a literal in the surface and never "
          f"as a silent skip here. The sibling pin that runs inside the mobile suite is "
          f"apps/mobile/__tests__/statusManifestParity.test.ts; the byte-parity of the "
          f"generated file itself is design/check.mjs Part A.", file=sys.stderr)
    sys.exit(1)
print(f"status-manifest-check part 5b: PASS — apps/mobile reads the GENERATED vocabulary "
      f"({mobile_gen_path}: {len(gen_s2r)} statuses, {len(gen_glyph)} rungs in manifest order, "
      f"default_role {m['default_role']!r}); taskboard.tsx derives all three tables from it and "
      f"BOARD_ROLES from ROLE_LABEL with {MOBILE_TERMINAL_ROLES} last; "
      f"{len(overrides)} recorded platform override(s) held honest.")
PY
