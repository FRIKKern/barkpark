# Re-derivation recipes — charter citation remedy (cloud-console-hardening wave 48, 2026-08-07)

Baseline: `origin/main`. Every command reads `origin/main` directly, never the primary checkout
(which D274 measured 327 commits behind at wave 22 and which is dirty today).

Setup used by rows 3-9:

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md > /tmp/vch.md
    git show origin/main:cloud/priv/static/app.js       > /tmp/w48app.js
    git show origin/main:cloud/priv/static/index.html   > /tmp/w48index.html
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex > /tmp/w48router.ex

| # | Claim | Re-derive with |
|---|---|---|
| 1 | The wave-6 citation audit rules NO remedy shape — it is 15 re-derivation recipe rows; only its row 7 records a stale-line finding | `cat tooling/grip/ledger/charter-citation-audit-wave6-2026-07-28.md` |
| 2 | The remedy shape IS ruled, in this charter, twice: D67 `source-citation-line-drift`: **BAN THE SHAPE, do not build a verifier** (cites honest-gates D5), and D274 **ANCHOR BY SYMBOL, READ FROM `origin/main`** / "NO BUILDER MAY BE HANDED A PRE-#9101 LINE NUMBER"; D159 adds "slice boundaries are NAMED ANCHORS, NEVER LINE RANGES" | `sed -n '351p;445p;562p' /tmp/vch.md` |
| 3 | D67's ban SHIPPED as **E11** in `__css_check.mjs` and is MERGE-BLOCKING — it runs as the "CSS/token drift gate" step under the required `Console gate` aggregator | `git show origin/main:cloud/priv/static/__css_check.mjs \| grep -n 'E11'` ; `git show origin/main:.github/workflows/console-harness.yml \| grep -n '__css_check.mjs'` ; `git show origin/main:.github/required-checks.json \| grep -n 'Console gate'` |
| 4 | E11's fence STOPS at `cloud/priv/static/*.{js,mjs,css}` source comments: `router.ex:<line>` cites are explicitly OUT (filed `cch-bl-citation-drift-cross-language`, still `published`), and charter markdown is out of the console fence entirely | `git show origin/main:cloud/priv/static/__css_check.mjs \| sed -n '750,760p'` ; `bp task get cch-bl-citation-drift-cross-language -o json` |
| 5 | **NO gate reads the charter.** `docs-anchors-check.sh` prunes `.claude` by design ("git worktrees + charters"), and `doc-gates` — which does trigger on `**/*.md` for `pull_request` — is NOT in the four-name required set (Cloud gate, Console gate, Elixir gate, PR references an active task) | `grep -n 'charters' scripts/docs-anchors-check.sh` ; `git show origin/main:.github/workflows/doc-gates.yml \| sed -n '140,143p'` ; `git show origin/main:.github/required-checks.json \| grep -c '"context"'` |
| 6 | No symbol-anchor checker for the charter exists anywhere in `scripts/` or `tooling/` | `ls scripts \| grep -i 'charter\|citation\|anchor'` (returns only `docs-anchors-check.sh`) |
| 7 | Built one to MEASURE (report-only, ±2-line tolerance, per `dr-w11-bl`'s "REPORTS and never auto-corrects"): **53 machine-decidable symbol anchors, 48 stale, exit 2**; stale by file `{router.ex:4, app.js:44}` | `node <scratch>/anchor.mjs` — source recorded in the wave-48 Paper; two-way losability proven: `app.js:8135` for `updatePanelHtml` → exit 0, `:8140` → exit 2 |
| 8 | **D524 cites the WRONG FILE.** charter:802 gives `#overview-launch` (`:20279`) and `#fleet-launch` (`:20281`) with `app.js` as the row's file; app.js:20279-20281 is a comment about a selection-index reducer. Both ids live in `index.html:296`/`:312` | `sed -n '20279,20281p' /tmp/w48app.js` ; `grep -n 'id="overview-launch"\|id="fleet-launch"' /tmp/w48index.html` |
| 9 | **D532's `updatePanelHtml` is +1181 stale**: cited `app.js:6954` (a comment), declared at `:8135`. Its two siblings in the same row are stale too — `instanceHeaderHtml` `:6678`→`:6911`, `adminWriteControlHtml` `:6775`→`:6894` | `grep -n 'function updatePanelHtml\|function instanceHeaderHtml\|function adminWriteControlHtml' /tmp/w48app.js` ; `sed -n '6954p;6678p;6775p' /tmp/w48app.js` |
| 10 | **The collision claim is measurable and mostly FALSE.** Six consecutive charter commits touch exactly two hunk regions — the D-row append point (~`755`-`812`) and the wave-log append point (~`2024`-`2270`). NOTHING has touched charter lines `361`-`750`, where 34 of the 48 stale anchors live | `for c in $(git log --format=%h -6 origin/main -- .claude/workflows/bp-cloud-console-hardening-charter.md); do git show $c -- .claude/workflows/bp-cloud-console-hardening-charter.md \| grep -oE '^@@ [^@]*@@'; done` |
| 11 | The 12 anchors that DO collide (charter `799`-`822`) are exactly the ones the wave most wants — they sit inside wave 47's own hunk `@@ -798,9 +798,67 @@`, adjacent to wave 48's D535 append point. D524 (`:802`) and D532 (`:810`) are both in that band | same command as row 10, first entry `1bc919777` |
| 12 | Only TWO open PRs touch this charter and both are `CONFLICTING` zombies whose content already landed (#10256 = wave 45 = charter D533; #10054 = wave 40) | `gh pr list --state open --limit 40 --json number,title,files` filtered on the charter path ; `gh pr view 10256 --json mergeable` |

Trap note (recurring, D-ledger): never `cmd \| head && echo ok` — `head` supplies the exit status and
masks a failing `cmd`. Row 7's exit codes were taken with `${pipestatus[1]}`, not `$?` after a pipe.
