# W37 verify — wave-35 rows live state + pathfilter C4 (re-derivation recipe)

Verifier lane: wave35-rows-live-state. Both rows re-claimable (claim.worker=null, reaped at 2026-08-17T20:06:02Z); C4 still unsatisfiable at build time.

## Re-claim + close-by-evidence payloads

- `connectors-deployyml-scripts-connectors-pathfilter` (#11979): claim.worker=null, epoch 9, rev `c5ad3867af78ec52b760e4fa3cb1cfd5`. 4 criteria; crit-1/2/3 met:true (code-provable), crit-4 met:false MERGE-GATED ("a subsequent scripts/connectors-only merge ... shows deploy.yml firing with instance=true — run URL recorded") — leave HONESTLY OPEN.
- `connectors-telegram-webhook-mode-unwired` (#11980): claim.worker=null, epoch 8, rev `9a8f80ae5d8660044de2bf1be4948709`. 3 criteria; crit-1/2 met:true, crit-3 met:false MERGE-GATED ("PR merged; connectors.yml green") — merged (438f6c7) so verifiable, but merge-gated wording is lead's to close.

Re-derive exact criterion wording (verbatim needed for --set close payload; --met stamp 409s on mismatch):

    for t in connectors-deployyml-scripts-connectors-pathfilter connectors-telegram-webhook-mode-unwired; do echo "=== $t ==="; bp task get $t -o json | python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];print('claim.worker:',d['claim']['worker']);print('rev:',d['rev']);c=d.get('content',{});print(json.dumps(c.get('acceptance_criteria'),indent=1))"; done

## Pathfilter C4 unsatisfiability (still true)

e085a92 IS the pathfilter merge (#11979). Zero scripts/connectors-ONLY commits merged since — so no deploy has been triggered by a scripts/connectors change, so crit-4 cannot be closed:

    git fetch origin main -q
    git rev-list --count e085a92789147c2d599f62074ef8c9d6594c4822..origin/main -- 'scripts/connectors/'   # => 0

## Telegram interior clean on origin/main

    git show origin/main:connectors/src/connectors/telegram.ts | grep -n 'mode?'   # => 285:  mode?: "polling";
