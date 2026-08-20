<!-- doc-tier: cold | canonical-for: felix-w26-ledger-close-live-proof | budget: 900tok -->

# felix-w26 ledger-close live proof (2026-08-17)

## Claim proven

The bp re-claim → close → read-back recipe LANDS a lifecycle mutation. Executed live
end-to-end on the lowest-value D164 NO-OP row (never previously claimed).

## Re-derivation (exact commands)

    # 1. Baseline: confirm the row is open, claim=null
    bp task get felix-w23-bl-continue-on-error-flip \
      | python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'],d['claim'])"
    # -> open None

    # 2. Claim -> yields a FRESH epoch (prints 'help:' hints THEN the result line)
    bp task claim felix-w23-bl-continue-on-error-flip felix-verify-w26
    # -> felix-w23-bl-continue-on-error-flip epoch=1 rev=4cc03459b5a8511c34d2ffb791dfac81

    # 3. Close ON THAT EPOCH with an explicit lifecycle + reason
    bp task close felix-w23-bl-continue-on-error-flip felix-verify-w26 1 cancelled "NO-OP superseded per D164/D143"
    # -> felix-w23-bl-continue-on-error-flip epoch=1 rev=cf89afe21e9cec401bb40e001dfa413a

    # 4. Read back — PROVE the lifecycle actually changed (do not trust the printed rev alone)
    bp task get felix-w23-bl-continue-on-error-flip \
      | python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'],d['claim']['closed_by'],d['claim']['epoch'])"
    # -> cancelled felix-verify-w26 1

## Mechanics learned

- The close signature is: `bp task close <id> <worker> <epoch> <lifecycle> "<reason>"`.
  `<lifecycle>` is a positional arg (`cancelled`/`done`), NOT a flag.
- Both `claim` and `close` print `help:` suggestion lines BEFORE the result line.
  Those are guidance, not errors. The trailing `... epoch=N rev=...` line is the receipt.
- Close CAS-requires the epoch printed by the claim you just made. Pass that exact epoch.
- The read-back rev equals the close rev (cf89afe...), and `claim.closed_by`/`closed_at`
  are stamped. `status` stays `published`; `lifecycle_status` is the field that flips.

## Residual (Decide must not overstate)

This row was NEVER previously claimed (claim=null → epoch=1). It proves the BASE
mechanic. The 19 D164 PAID rows are suspected to carry a LAPSED prior claim; closing
those requires a RE-claim that supersedes the stale claim to mint a new epoch, then
close on the new epoch. That supersede-over-existing-claim path was NOT exercised here
(would require mutating a second real row, out of this verifier's one-row scope).
Recommend Decide's first D164 close be run live as a second proof of the lapsed path.
