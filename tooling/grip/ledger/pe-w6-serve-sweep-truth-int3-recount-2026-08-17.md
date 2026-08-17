<!-- doc-tier: cold | canonical-for: pe-w6-serve-sweep-truth-recount | budget: 500tok -->

# PE wave-6 — serve-sweep-truth: pe-w5-serve-and-sweep rehydrate DID run (live recount)

Verifier `serve-sweep-truth`, 2026-08-17. Settles the wish/ledger contradiction: the wish
calls the guerrilla `rehydrate --write` a still-pending human-gated lead-op; the closed task
`pe-w5-serve-and-sweep` (5/5 met, done 15:46 UTC) claims it ran (int_3 census 60->0).

Verdict: **PROVEN-RAN.** The live client-side recount (D33 recipe, `body_html_sv==3`
predicate) reads 0 published int_3 rows against `https://guerrilla.barkpark.cloud`.

## Re-derivation (bp reader against live, no SSH)

    bp doc query paper --limit 2000 --fields body_html_sv,_updatedAt -o json | \
      python3 -c "import json,sys;d=json.load(sys.stdin);r=d['documents'] if isinstance(d,dict) else d;\
print('total',len(r),'int3',sum(1 for x in r if x.get('body_html_sv')==3),\
'hex64',sum(1 for x in r if isinstance(x.get('body_html_sv'),str) and len(x.get('body_html_sv'))==64))"

Observed 2026-08-17 ~16:30 UTC: `total 780 int3 0 hex64 674` (106 rows carry no stamp).
0 = ran (recipe: ~60 would mean it did NOT). Newest paper `_updatedAt` = 2026-08-17T16:28Z,
sample stamp `c1d8a2b4...2312abe` (hex, not integer 3). Config `server` = guerrilla.

## Implication for the epic

Epic `task-4792223ca9eb5a7d` sits OPEN at 2/3 with met=[True,True,False]; idx0 (gap
analysis / FRICTION.md) and idx1 (before/after wave) are stamped and merge-independent — the
serve arm that underwrites the wave-5 close is now proven live. The 2/3 state is trustworthy.
Decide must NOT re-file the rehydrate as an unrun lead-op; it is complete. The wish's
"still human-gated / pending" framing for the rehydrate is STALE. (Framed-finale authoring
and live-pixel epic stamping remain separately lead/human-gated — untouched here.)
