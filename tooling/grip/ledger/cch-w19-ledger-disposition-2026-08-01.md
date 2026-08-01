# Re-derivation recipes — CCH wave 19 ledger disposition (2026-08-01)

Verifier lane `ledger-disposition`. Questions: are the candidate duplicate pairs the
same defect **by body**; which rows are stale-open at N/N on merged code; and what is
the exact `bp` verb sequence that pays `cch-w18-s3-residue-paid-by-driving`'s criteria
1, 5 and 8.

Everything below was read live from `guerrilla.barkpark.cloud` or from `origin/main`
(fetched 2026-08-01). **No command below measures an exit code through a pipe.**
**NOTHING WAS WRITTEN** — every `bp` mutation shape was proven with `--dry-run` only.

The denominator is the seal predicate's OWN roster read (Standing Law 0's protocol),
replicated verbatim from `seal-predicate.mjs:231` — never `bp task ls`.

| # | Claim | Command |
|---|---|---|
| 1 | The epic roster is **231 children: 84 open · 1 considering · 128 done · 18 cancelled**. 84 live is the wave's opening denominator, not ~70 | `curl -sG "$BP_SERVER/v1/data/query/production/task" --data-urlencode 'filter[parent_id]=cloud-console-hardening-epic' --data-urlencode 'limit=500' -H "Authorization: Bearer $BP_TOKEN" \| jq -r '.result.documents\|group_by(.lifecycle_status)\|map({s:.[0].lifecycle_status,n:length})'` |
| 2 | The seal predicate refuses TERMINAL on that same read and names the same 84 | `node cloud/priv/static/__preview__/seal-predicate.mjs --successor TERMINAL` |
| 3 | **`bp task get -o json` puts criteria at `.doc.content.acceptance_criteria`, NOT `.doc.acceptance_criteria`** — reading the wrong path yields 0/0 on every row. This is the "comforting ZERO" trap | `bp task get cch-w18-s3-residue-paid-by-driving -o json \| jq -r '.doc.content.acceptance_criteria\|length'` (9) vs `… \| jq -r '(.doc.acceptance_criteria//[])\|length'` (0) |
| 4 | The roster query DOES carry `acceptance_criteria` at top level for 228 of 231 docs; **3 open rows carry `null`** — `task-0b23fb7452aa457a`, `task-d862cf7f8e1108c1`, `cch-bl-cloudflare-identity-echo-no-surface` — so they are structurally unstampable | `jq -r '[.result.documents[]\|(.acceptance_criteria\|type)]\|group_by(.)\|map({t:.[0],n:length})' epic-roster.json` |
| 5 | **STALE-OPEN AT N/N: exactly three** — `cch-w15-bl-preview-only-site-fixture-missing` 3/3, `cch-w16-s8-drop-900-tier-rule-axis-and-baseline` 10/10, `cch-w16-s6-billing-chip-two-tablet-bands` 10/10 | `jq -r '.result.documents[]\|select(.lifecycle_status=="open")\|select((.acceptance_criteria\|type)=="array" and (.acceptance_criteria\|length)>0)\|select((.acceptance_criteria\|map(select(.met==true))\|length)==(.acceptance_criteria\|length))\|._id' epic-roster.json` |
| 6 | At N-1/N: `cch-w14-bl-status-pill-label-overflows-rail` 4/5, `cch-w15-bl-fleet-support-detail-truncated-stacked-band` 3/4, `cch-w16-s4-visit-link-gated-on-deployment` 9/10, `cch-w12-bl-filing-law-parent-charter-half` 2/3, `gr-backlog-css-check-missing-classes` 2/3 | same jq with `==((.acceptance_criteria\|length)-1)` |
| 7 | **PAIR A** `cch-w15-s8` (0/10) ⊂ `cch-w16-s7` (0/13): same defect (E11 widening + citation re-anchoring); w16-s7 crit 4 explicitly STRIKES w15-s8's two wrong corrections. w15-s8's UNIQUE content is its crit 6 (workflow comment repair) | `bp task get cch-w15-s8-citation-anchors-e11-widening -o json`; `bp task get cch-w16-s7-citation-anchors-e11-widening -o json` |
| 8 | **PAIR B** `cch-w15-bl-drop-900-…` (0/4) ⊂ `cch-w16-s8-drop-900-…` (10/10): identical remedy (delete the one `max-width: 900px` tier-grid rule) + identical four co-scoped artifacts. Shipped: `grep -c "max-width: 900px"` on main = **0** | `git show origin/main:cloud/priv/static/app.css \| grep -c "max-width: 900px"` |
| 9 | **PAIR C** `cch-w15-bl-visit-link-ungated-…` (0/3) ⊂ `cch-w16-s4-visit-link-gated-…` (9/10, merged #8849 `1831b6a5361d`) | `gh pr view 8849 --json state,mergeCommit` |
| 10 | **PAIR D** `cch-w17-bl-op-gate-pill-paints-outside-chip` (0/5) ≡ `cch-w18-bl-operator-gate-pill-clipped-on-phone` (0/5): SAME element — `operatorPillHtml` emits `.status-pill` "Gate" inside `<p class="op-gate">`; same three operator scenarios; same 53 vs 36/38/40. **Charter D210 names w17-bl as the survivor by construction** | `git show origin/main:cloud/priv/static/app.js \| sed -n '6969,6973p;7002p'`; `git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \| grep -n D210` |
| 11 | No overflow-guard leg drives `operator-*` at any width (w17-bl's "NO GUARD COVERS IT" holds) | `git show origin/main:cloud/priv/static/__preview__/overflow-guard.mjs \| grep -c operator` → `0` |
| 12 | **PAIR E — A FIFTH PAIR THE BRIEF DID NOT NAME.** `cch-w15-s7-sweep-axes-theme-height-scenario` (open, 0/10) is fully superseded by `cch-w16-s2-sweep-axes-theme-height-scenario` (**done 11/11**, #8817 `909a5d742b14`): theme axis, height axis, 74-entry scenario allowlist, fatal staleness and `--cell a,b,c` are each paid by a w16-s2 criterion | `bp task get cch-w16-s2-sweep-axes-theme-height-scenario -o json`; `gh pr view 8817 --json state,mergeCommit` |
| 13 | Every merge SHA the disposition leans on is an ancestor of `origin/main` — `17ec78adc` (#8818), `626466a0c` (#8851), `909a5d742` (#8817), `1831b6a53` (#8849), `45cb38347` (#8891) | `for s in 17ec78adc… ; do git merge-base --is-ancestor $s origin/main; echo "$s rc=$?"; done` |
| 14 | **#8850 has NO merge commit** (state CLOSED) — it was the base of a stack brought in by #8851, exactly as `cch-w16-s8`'s crit-9 evidence states | `gh pr view 8850 --json state,mergeCommit` |
| 15 | #8818 IS `cch-w16-s3`'s PR (its body carries `Task: cch-w16-s3-…` and names both rows it pays); the row's `github.issue = 8790` is a **mirror issue number, not a PR** — `gh pr view 8790` fatals `Could not resolve to a PullRequest` | `gh pr view 8818 --json body`; `gh pr view 8790 --json state` |
| 16 | #8818's ONLY red is `Required-check spec drift (advisory)` — which is red on main itself; every blocking context passes | `gh pr checks 8818` |
| 17 | #8818 touches exactly `app.css`, `overflow-guard.mjs`, `cssom-heads.baseline`; `FLEET_KNOWN` is `[]` on main, proving the fleet row's crit 2 | `git show --name-only --format= 17ec78adc…`; `git show origin/main:cloud/priv/static/__preview__/overflow-guard.mjs \| grep -n "FLEET_KNOWN = "` |
| 18 | `cch-w16-s4` crit 5 is ALREADY AMENDED and satisfiable — "closed with the SHA of the PR that pays it"; the paying PR is `cch-w18-s4`'s #8891 `45cb38347` | `jq -r '…\|.acceptance_criteria[5].criterion' epic-roster.json` |
| 19 | **`cch-w18-s3` crit 1 is NOT bookkeeping and its number is CONTESTED**: the row demands a mutation run "exits 1 with **68** findings"; charter **D203 records 44** for the same fleet mutation on the same merged bytes. Re-derive; inherit neither | `bp task get cch-w18-s3-residue-paid-by-driving -o json \| jq -r .doc.content.description \| grep -n "68 findings"`; `git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \| grep -n "44 findings"` |
| 20 | `cch-w18-s3` crit 5's off-by-one is CORRECT AS WRITTEN: w16-s3's blockers are stored indices **8 and 9** (board numbers 9 and 10), and stored index 7 is already met | `jq -r '…cch-w16-s3…\|.acceptance_criteria\|to_entries[]\|"\(.key) \(.value.met)"' epic-roster.json` |
| 21 | `cch-w12-s6-ledger-truth-closes-and-collapses` is a PRIOR duplicate-collapse slice stalled at **2/11**; `cch-w13-s6` (done 9/9) and `cch-w16-s5` (done 12/12) are the two that finished. A wave-19 M4 is the FOURTH instance of this slice shape unless w12-s6 is disposed | `bp task get cch-w12-s6-ledger-truth-closes-and-collapses -o json` |
| 22 | Verb shapes proven without writing: `claim` POSTs `{worker_id}`; `close <id> <worker> <epoch> cancelled "<reason>"`; `stamp <id> <worker> <epoch> --criterion N --met --evidence … --criterion-text "<verbatim>"` (N is ZERO-BASED; `--criterion-text` is the off-by-one guard) | `bp task claim <id> <w> --dry-run`; `bp task close <id> <w> 1 cancelled "…" --dry-run`; `bp task stamp <id> <w> 1 --criterion 4 --met --evidence "…" --criterion-text "…" --dry-run` |

## The disposition, in order

Cancels (5): `cch-w15-s8-…` → w16-s7 · `cch-w15-bl-drop-900-…` → w16-s8 ·
`cch-w15-bl-visit-link-ungated-…` → w16-s4 · `cch-w18-bl-operator-gate-pill-clipped-on-phone`
→ w17-bl (D210) · `cch-w15-s7-…` → w16-s2.

Closes (7), in dependency order: `cch-w15-bl-preview-only-site-fixture-missing` (3/3) →
`cch-w16-s4` (stamp 5) · `cch-w16-s8` (10/10) · `cch-w16-s6` (10/10) ·
`cch-w14-bl-status-pill-label-overflows-rail` (stamp 4) ·
`cch-w15-bl-fleet-support-detail-truncated-stacked-band` (stamp 3) ·
`cch-w16-s3` (stamp 8 then 9).

Net: 84 → 72 live before `cch-w18-s3` itself closes.
