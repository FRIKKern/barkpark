# vf-ledger-close-truth (task-TUI wave 22) — bequest reachability + close mechanics

Re-derivation recipes for the settlement + close-contract slices. All quoted from the live guerrilla server 2026-08-17.

## 1. Merge-gated close CAS strings (worker capped at 53 chars = the exact CAS value)

    for t in ttw19-bl-drafts-now-drop ttw20-wide-overflow-marker-clicks ttw21-hermetic-drive; do
      bp task get $t -o json | python3 -c "import sys,json;d=json.load(sys.stdin);c=d['doc']['claim'] or {};print('$t',repr(c.get('worker')),'epoch='+str(c.get('epoch')))"
    done

- ttw19-bl-drafts-now-drop        → worker `epic-builder-the-now-band-and-the-in-flight-count-tel` epoch 6
- ttw20-wide-overflow-marker-clicks → worker `epic-builder-the-wide-panes-overflow-markers-answer-c` epoch 6
- ttw21-hermetic-drive            → worker `epic-builder-the-drive-harness-goes-hermetic-fixture-` epoch 7

All three worker strings are exactly len=53 — server-side cap. The CAS matches the STORED value, so the truncated-at-53 string IS the correct close argument. Do NOT reconstruct a "full" worker slug.

## 2. api/ bequest home (ttw20-bl-prime-counts-collapse-twins)

    bp task get ttw20-bl-prime-counts-collapse-twins -o json | python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'],d['assignee'],d['claim'],d['labels'])"

→ `open None None ['area:api', 'files:api/lib/barkpark/tasks/prime.ex']`, parent_id=task-tui-goal, github issue 11864. Open + unclaimed + carries the api/ destination-fence labels an api-fenced wave surfaces. Reachable — no re-file needed.

## 3. D43 cross-surface chip reservation — NO open task home (charter-only)

TUI-side arm ttw18-chip-full-manifest is `done`. The pdrender/cross-surface in-body glyph unify is explicitly reserved out of p-tui-board-lang ("Out of scope: pdrender in-body chip glyph unification (reserved cross-surface slice, charter D43)"). `bp search query 'pdrender in-body chip glyph unify D43 cross-surface'` returns only papers + the done TUI task — zero open bequest home. → close contract MUST file one.

## 4. No recurring in-repo sweep re-stamps the goal close_reason

task-tui-goal close_reason = "Historical completion reconciled from 4/4 met acceptance criteria with recorded evidence…". This phrase appears in ZERO tracked files:

    git grep -lni 'Historical completion reconciled|met acceptance criteria with recorded evidence'   # empty

Scheduled workflows (`schedule:` cron) that could touch tasks: crown-reconcile.yml = platform_deliveries only; stale-verdict-watch.yml = PR check-rollup only; epic-zero-criteria-census.sh = read-only census (exit 0/1/2, never closes). None close tasks or emit this phrase. → No in-repo cron re-stamps a rewritten close_reason; close contract needs no guard against an in-repo sweep. RESIDUAL: phrase may originate server-side on guerrilla (not inspectable here); charter-lock (charter §D, line ~2002) is the actual re-flip protector.
