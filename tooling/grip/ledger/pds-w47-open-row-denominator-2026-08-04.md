# PDS wave 47 — THE open-row denominator, re-derivation recipe

Taken 2026-08-04 ~11:56 UTC against `origin/main` 49345a98c1dbd9c768f3312185be0f5483878241
and the live board at https://guerrilla.barkpark.cloud.

## RULING (one field, one closure rule)

- **THE FIELD:** `lifecycle_status == "open"`, case-exact. Not `disposition`
  (an adjudication annotation — 216 live rows carry none), not "live/non-terminal"
  (that folds in `considering` 30 + `blocked` 1, and `considering` PRECEDES open).
- **THE CLOSURE:** transitive descendants over `parent_id`, keyed on the **slug**
  (`doc_id`, = `_id` in `/v1/data/query`), root `task-2ac1f95237c4a8e5`, with the
  fixpoint assertion. Max depth observed: **2**.
- **THE NUMBER:** **374** through the published lens (what the census prints and what
  any `/v1/data/query` instrument can see). **376** is the honest total of open rows
  that exist; the extra 2 are never-published drafts. **379 double-counts 3 phantoms.**

## THE PREMISE THAT IS WRONG

`parent_id` is NOT mixed-keyed. **0 of 4,592** parent_id values corpus-wide resolve as a
UUID `id`; 4,537 resolve as `doc_id`; 55 point at non-task docs (goals/papers), none PDS.
The "344 UUID-only closure" is not a lens — it is a **depth-1 truncation**: the walk pushes
`c['id']` (a UUID) onto the frontier, which matches no `parent_id`, so it stops after level 1.
549 = the direct children; 110 grandchildren are simply never visited (35 of them open).

## RE-DERIVE

    bp task ls --all -o json > /tmp/all.json
    python3 - <<'PY'
    import json,collections
    docs=json.load(open('/tmp/all.json'))['docs']
    byd={d['doc_id']:d for d in docs}
    k=collections.defaultdict(list)
    for d in docs:
        if d.get('parent_id'): k[d['parent_id']].append(d)
    seen={};st=['task-2ac1f95237c4a8e5']
    while st:
        x=st.pop()
        for c in k.get(x,[]):
            if c['id'] in seen: continue
            seen[c['id']]=c; st.append(c['doc_id'])   # SLUG, never c['id']
    pub=[d for d in seen.values() if d.get('status')=='published']
    print('closure',len(seen),'published',len(pub))
    print('DENOMINATOR',sum(1 for d in pub if d['lifecycle_status']=='open'))
    for d in seen.values():
        if d.get('status')!='published' and d['lifecycle_status']=='open':
            t=byd.get(d['doc_id'].split('drafts.',1)[-1])
            print('draft-open',d['doc_id'],'twin=',t['lifecycle_status'] if t else 'NO-TWIN')
    PY

Expected (2026-08-04): `closure 659 published 653` / `DENOMINATOR 374` /
3 draft-open rows with a `done` twin (PHANTOMS) + 2 `NO-TWIN` (genuinely invisible).

Cross-check against the census's own numbers:

    cd $(mktemp -d) && git -C <repo> archive origin/main | tar -x \
      && BARKPARK_SERVER=https://guerrilla.barkpark.cloud bash scripts/pds-ledger-census.sh

prints `closure 653 … max depth 2`, `live 405`, `open 374`. 374 + considering 30 +
blocked 1 = 405. Every figure reconciles; the census's closure does NOT inherit any hole.

## KNOWN BLIND SPOTS OF THIS DENOMINATOR (enumerate, never round off)

1. `drafts.task-85d64913a19c0d70` — open, never published, invisible to the census.
2. `drafts.pds-bl-wrongpath-arm-blind-to-wrong-id` — same.
3. `pds-bl-merge-gated-criteria-carry-the-flag` — **open, PDS-slugged, parented to
   `task-lifecycle-visibility-epic`**. No root-anchored closure can ever see it.
   (6 more `pds-*` rows sit outside the closure; all are done/cancelled.)

## RIDER — clause-7 drafts undercount, MEASURED (pays `pds-w43-bl-lapse-lens-drafts-undercount-unmeasured`)

Same instant, same three shape keys, both lenses:

| shape | published (census) | drafts-inclusive | delta |
|---|---|---|---|
| A reverted-to-open after expiry | 24 | 27 | **+3** |
| B in_progress past TTL | 0 | 0 | 0 |
| C open with claim never cleared | 0 | 0 | 0 |

The +3 are named and are exactly the three PHANTOMS:
`drafts.pds-w29-s3-fake-fails-closed`, `drafts.pds-w27-census-self-honesty`,
`drafts.pds-bl-tagregistry-guard-no-rung` — each `open` in draft while its published
twin is `done`. So the published lens does not undercount shape A; **the drafts lens
manufactures 3 false lapses.** Clause 7's caveat should be amended to say so, with the
number, rather than retired.
