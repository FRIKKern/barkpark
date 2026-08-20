# cch-w16 — charter coverage read (v-charter-coverage-read), 2026-08-01

Re-derivation recipes for the wave-16 authority questions. Every command reads `origin/main`
(`c48fb17d565cc9c4207fd3a3fa8ac28ff38954f9` at time of writing), never a working tree.

## 0. Fetch both charters

```bash
git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md > /tmp/charter.md   # 1846 lines
git show origin/main:.claude/workflows/bp-cloud-gui-remake-charter.md      > /tmp/gui.md        # 1991 lines
```

## 1. GR11 / GR25 / GR116 are NOT defined in the hardening charter

```bash
grep -nE 'GR11\b|GR25\b|GR116\b' /tmp/charter.md      # 4 hits, ALL inside D-rulings (303,307,316,554)
grep -nE 'GR11\b|GR25\b|GR116\b' /tmp/gui.md          # 25 / 40 / 502 = the definitions
sed -n '25p;40p' /tmp/gui.md | fold -w 190            # GR11, GR25 verbatim
sed -n '502,512p' /tmp/gui.md | fold -w 190           # GR116 verbatim
```

## 2. The quarantine forbids EDITING, and `.status-pill-label` already carries the declaration

```bash
git show origin/main:cloud/priv/static/app.css | sed -n '2913,2942p'   # .status-pill block
git show origin/main:cloud/priv/static/app.css | grep -n '\.status-pill-label'
#   2935:.status-pill-label { font-weight: 600; flex: 0 0 auto; }
git show origin/main:cloud/priv/static/app.css | sed -n '2188,2200p;2265,2272p'  # in-file GR11/GR25 notes
```

## 3. D157's carve-out predicate (empty class), and the sanctioned wrapper precedent

```bash
sed -n '307p' /tmp/charter.md | fold -w 190     # D157 — "ONE ADDITIVE rule ... an ADD, not a restyle"
sed -n '316p' /tmp/charter.md | fold -w 190     # D165 — wrapper fix (.fleet-row/.fleet-badges)
sed -n '330p' /tmp/charter.md | fold -w 190     # D179 — wrapper fix (.fleet-main), scoped to min-width:900
```

## 4. `__bpTestHook`: D63 is silent; GR11/OC9 + D33 govern; the seam's exports already exist

```bash
grep -n '__bpTestHook' /tmp/charter.md          # ONE hit: line 181 = D33 ("must widen __bpTestHook")
sed -n '211p' /tmp/charter.md                   # D63 — no mention of the hook at all
sed -n '25p' /tmp/gui.md | grep -o 'OC9 append-only-tails[^)]*)'
git show origin/main:cloud/priv/static/app.js | grep -n 'tierCardHtml\|planCatalog'
#   18968:      planCatalog: PLAN_CATALOG.slice(),
#   18983:      tierCardHtml: tierCardHtml,
```

## 5. D105 on `drafts.*`

```bash
sed -n '253p' /tmp/charter.md | fold -w 190 | tail -4
#   "Any future census must count `drafts.*` entries as duplicates, never as rows."
#   Remedy actually performed: `bp doc discard-draft` (NOT a task close/cancel).
sed -n '25,40p' /tmp/charter.md                 # standing law 0 restates it
```

## 6. D180 / D183 ARE on origin/main (refutes the survey)

```bash
grep -n '| D180 |\|| D183 |' /tmp/charter.md    # 331, 334
```
