# GR25 coverage check for wave-65 S1 (Arm A / Arm B) — re-derivation recipes

All commands read `origin/main`. Run from the repo root.

## 1. GR25's own text (cch charter :113-121)

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | sed -n '113,121p'

Decisive clause: "the quarantine forbids EDITING the four pill-family rule blocks
(`status-pill`, `dep-pill`, `tlv-badge`, `badge`/`fresh-badge`), never CONSUMING them …
Any slice that must edit inside the fence needs its own D157-shaped carve-out ruling,
argued as an ADD rather than a restyle."

## 2. GR25's definition of record (GUI-remake charter :40)

    git show origin/main:.claude/workflows/bp-cloud-gui-remake-charter.md | sed -n '40p'

## 3. Every D-row naming a pill family

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \
      | grep -n 'status-pill\|fresh-badge\|dep-pill\|tlv-badge\|D157'

D157 (`:474`) is the only dep-pill carve-out; its ruling sentence scopes itself:
"carved out for this ONE ADDITIVE rule" (`.dep-cancelled`). D198 (`:517`) extends it to
`.instance-card-head`, again "AS AN ADD". D411 (`:732`) is a third "D157-shaped ADD".
No row generalises the carve-out to future `.dep-*` additions.

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -n 'carve-out\|carve out'

## 4. Arm A's two reused classes exist (so Arm A is CSS-free = consume-only)

    git show origin/main:cloud/priv/static/app.css | grep -n '^\.fresh-badge--rebuild\|^\.status-pill--warn'
    # 1127/1128/1129 .fresh-badge--rebuild …   3522/3523 .status-pill--warn …

D773 cites these as `app.css:1119` and `:3514` — both **8 lines stale**; the rules exist,
the line numbers do not. Re-derive, do not quote D773's numbers.

## 5. `.dep-deferred` has zero rules today (Arm B is a genuine ADD)

    git show origin/main:cloud/priv/static/app.css | grep -c 'dep-deferred'   # 0

## 6. `__css_check.mjs` blindness split (Arm A vs Arm B)

    git show origin/main:cloud/priv/static/__css_check.mjs | sed -n '306p;350p'

`"fresh-badge fresh-badge--"` is allowlisted wholesale at `:306`, so the guard cannot see
Arm A at all. `DEPLOY_STATUSES` at `:350` is the six-value list D775 widens — Arm B only.

## 7. Foreign-charter claim on `cloud/lib/barkpark_cloud/registry.ex`

    for c in bp-honest-gates bp-pds bp-felix-pristine bp-deploy-reliability; do
      echo "== $c"
      git show origin/main:.claude/workflows/$c-charter.md 2>/dev/null | grep -n 'registry\.ex' | head -5
    done

honest-gates: zero hits. pds: `tag_registry.ex` only (different file). felix-pristine `:1603`:
D116 names a cloud `registry.ex` slice — but its task is CLOSED:

    bp task get task-felix-w18-registry-staleability-hardening -o json | head -c 400
    # claim.closed_at 2026-07-23T06:25:05Z

deploy-reliability: D15/D18 (`:123`,`:140`) DEFER to cch's own wave-31 s7; the registry.ex
slice rows at `:1236`/`:1629` are waves 4-5 (charter head is wave 32/33).

## 8. The live collisions that DO exist (open PRs, not charters)

    for p in 11443 10944 10722 10720 10400 10155 10154 10129 10086 10085 10006 9956; do
      f=$(gh pr view $p --json files --jq '[.files[].path] | map(select(test("registry\\.ex$|cloud/priv/static/|cloud/test/"))) | join(",")')
      echo "$p -> $f"
    done

- #10944 (open, MERGEABLE) edits `cloud/lib/barkpark_cloud/registry.ex` — hunks at `:53`
  and `:5202-5310`; S2's region is `:3828-3990` (`persist_update_unknown/2` at `:3949`).
  Rebase cost, not semantic overlap.
- #10006 (open, MERGEABLE) edits `cloud/priv/static/app.js` + `__app.test.mjs` — a real
  S1 textual collision if it merges first.
- #10085 edits `cloud/priv/static/__binding_census*.{mjs,js}` — inside S1's declared
  `cloud/priv/static/**` fence, though a different file set.
