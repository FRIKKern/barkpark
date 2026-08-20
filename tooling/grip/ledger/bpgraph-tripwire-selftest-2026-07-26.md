# Re-derivation recipes — bp-graph four-copy tripwire selftest proof, search-template W10, 2026-07-26

Verifier lane: `tripwire-selftest-proof` (task stw9-backlog-bpgraph-identity-tripwire).
Prototype script lives in the session scratchpad (NOT committed):
`…/scratchpad/check-bp-graph-drift.sh`. Every row is one literal command that re-derives the fact.

| # | Fact | Rerun |
|---|---|---|
| 1 | All four bp-graph.js copies are byte-identical on origin/main (guard is green-on-arrival) | `cd /Volumes/SATECHI/github/barkpark && for f in api/priv/static/assets/bp-graph.js templates/astro-search-starter/public/bp-graph.js templates/search-starter/public/bp-graph.js web/public/bp-graph.js; do git show origin/main:$f \| md5; done \| sort -u` |
| 2 | The file itself declares a DIRECTIONAL canonical (api/priv/static/assets), not mutual equality | `git show origin/main:api/priv/static/assets/bp-graph.js \| sed -n '1,13p'` |
| 3 | Prior art shape to clone: SOURCE\|DEST table + `cmp -s` + missing-counts-as-drift + `--selftest` | `git show origin/main:scripts/check-astro-finder-drift.sh \| sed -n '85,131p'` |
| 4 | Weaker prior art (do not copy): vendored-assets.yml is a bare `cmp`, no selftest | `git show origin/main:Makefile \| grep -A2 '^cli-assets-check:'` |
| 5 | astro-finder-drift.yml itself admits it does not block until a human registers it | `git show origin/main:.github/workflows/astro-finder-drift.yml \| sed -n '1,16p'` |
| 6 | main has NO branch protection at all — every workflow in this repo is advisory | `gh api repos/FRIKKern/barkpark/branches/main/protection` (404 "Branch not protected") |
| 7 | …and NO rulesets either (so it is not protection-by-ruleset) | `gh api repos/FRIKKern/barkpark/rulesets` (returns `[]`) |
| 8 | doc-gates.yml would NOT fire on a canonical-only edit: no `api/priv/**` and no `**/*.js` path | `git show origin/main:.github/workflows/doc-gates.yml \| grep -nE '^\s+- "' \| grep -E 'api/priv\|\*\*/\*\.js'` (no output) |
| 9 | Selftest CAN fail: neutering the comparison reds it | `sed 's/if ! cmp -s "$root\/$CANONICAL" "$root\/$mirror"; then/if false; then/' check-bp-graph-drift.sh > b.sh && bash b.sh --selftest` → `SELFTEST FAIL: one mutation reported 0 drift(s), expected 1` |
| 10 | Selftest BLIND SPOT: removing the missing-mirror arm still passes (cmp exits 2 on a missing file, so the count is right and only the REASON string degrades) | `printf 'a\n' > /tmp/a; cmp -s /tmp/a /tmp/nonexistent; echo $?` → `2` |
| 11 | Real-path mutation reds and names the exact drifted path | `printf 'x' >> templates/search-starter/public/bp-graph.js && bash <scratchpad>/repo/scripts/check-bp-graph-drift.sh; git checkout -- templates/search-starter/public/bp-graph.js` |
