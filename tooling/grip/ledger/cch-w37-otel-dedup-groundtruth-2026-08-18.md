<!-- doc-tier: cold | canonical-for: cch-w37-otel-dedup-groundtruth | budget: 900tok -->

# W37 otel-dedup ground truth — the real cancel-one, not "already done"

Verifier [otel-dedup-groundtruth], wave 37, 2026-08-18. Turned the direction's
premise ("record the imessage-otel dedup as ALREADY done"): FALSE. There are
TWO live mutually-duplicate tracking rows for the identical residual, so the
wave has a REAL bp-only cancel-one action.

## The duplicate pair (same residual, filed twice by different waves)

Re-derive lifecycle + provenance:

    for t in connectors-imessage-otel-moderates connectors-imessage-otel-chain-residual; do \
      bp task get $t -o json | python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];c=d['content'];print(d['id'],'|',c['lifecycle_status'],'| gh',c['github']['issue'],'| created',d.get('created_at'))"; done

- #11951 `connectors-imessage-otel-moderates` (id a361ec17-…) — lifecycle **open**,
  created 2026-08-17, filed by **W35 Decide, charter D277**. NEWER re-file.
- #5759 `connectors-imessage-otel-chain-residual` (id 2359004e-…) — lifecycle
  **considering**, created 2026-07-22, filed **W32 D255/D258**. ORIGINAL; richer
  (wave_paper + purpose fields, cites charter D3/D44, records connectors/docs/npm-audit-triage.md).

Both describe: 12 MODERATE @opentelemetry advisories, chat-adapter-imessage@1.1.0
-> spectrum-ts -> @photon-ai/otel; npm's only fix is a BREAKING downgrade to
0.1.1 (never run --force); upstream-arrival-gated; never trips --audit-level=high.
Identical subject.

## The SEPARATE already-done pair (do not conflate)

    for i in 5771 5772; do gh issue view $i --repo FRIKKern/barkpark --json state,title -q '.state+" | "+.title'; done

- task-bbaa50b1a7414180 (#5771) — **done**, issue CLOSED.
- drafts.task-31e4a79d103c8e5b (#5772) — **cancelled**, issue CLOSED.
- Both titled "correct npm-audit-triage **doc** — otel loads import-time in ALL
  profiles + reachability tripwire" — a doc-correction dedup, DIFFERENT act,
  already resolved. This is the pair the direction was thinking of.

## Recommendation for Decide

Cancel the NEWER accidental re-file **#11951** (`connectors-imessage-otel-moderates`),
keep the original canonical **#5759** (`connectors-imessage-otel-chain-residual`).
Rationale: #5759 is the first filing, carries fuller provenance (D255/D258, D3/D44,
the npm-audit-triage.md pointer, wave_paper) and its "considering" lifecycle
correctly signals an upstream-gated, not-yet-actionable residual. #11951 is a
W35 re-file that did not spot the existing row and mis-set it "open". One
cancel, on the duplicate — not two closes, and NOT "already done".
