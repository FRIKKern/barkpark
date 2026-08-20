# pds-w30 — the fence is ON the live path, proven BY MUTATION (2026-07-31)

Companion to `pds-w30-write-fence-live-2026-07-31.md`. That file shows five real write verbs
passing the fence against `guerrilla.barkpark.cloud`. A pass alone cannot distinguish "the fence
ran and approved" from "the fence never ran". This mutation settles it.

## The recipe

    SP=<scratchpad>
    git worktree add --detach $SP/v9om origin/main
    cp -R $SP/v9om $SP/mut && rm -f $SP/mut/.git          # copy OUT of git — never mutate a worktree

    python3 - <<'PY'
    f="$SP/mut/internal/cli/run.go"
    s=open(f).read()
    old='func unreadableWriteReceipt(body []byte) string {'
    assert s.count(old)==1
    open(f,'w').write(s.replace(old, old+'\n\treturn "MUTATION: forced refusal to prove the fence is on the live path"'))
    PY

    cd $SP/mut && CC=/usr/bin/clang go build -o $SP/bp-mut ./cmd/barkpark
    T=pdsW30FenceProbe; ID=pds-w30-fence-mut-$(date +%s)
    $SP/bp-mut doc create $T --set _id=$ID --set title=mut-probe -o json --yes < /dev/null
    # ALWAYS clean up — the mutated binary REFUSES the receipt but the write still landed:
    $SP/bp-v9 doc delete $T $ID -o json --yes < /dev/null

## The measurement

    mut_create_rc=1
    {"error":{"code":"unreadable_write_receipt",
      "message":"unreadable write receipt: HTTP 200 MUTATION: forced refusal to prove the fence
                 is on the live path (422 bytes): {\"results\":[{\"id\":\"drafts.pds-w30-fence-mut-…",
      "hint":"the transport, not the write: … The write may still have landed — re-read the target
              before retrying …"},"ok":false}

A REAL 200 from a REAL Barkpark server, carrying a REAL 422-byte create receipt, reddened at rc=1
the instant the discriminator was forced. The unmutated `bp-v9` binary printed the same receipt at
rc=0. Therefore `screenWriteReceipt` (run.go:248) genuinely executes on the live `doc create`
path, and the wave-29 green is not vacuous for this verb.

## What this does NOT prove

The refusal fired on a FORCED predicate, not on a genuinely poisoned body. Real Hetzner-style
"the API lies" staging is still impossible against a correct server: guerrilla will not return
`{}`, `null` or an HTML 200 to `/v1/data/mutate/production` on demand. The nine-poison population
stays fixture-proven. What is now L1 is (a) the fence is reachable and firing on live traffic,
(b) it does not red honest live traffic across five write verbs, and (c) a non-JSON 2xx really is
one followed redirect away on this very host (see R5 of the companion file).

## Cleanup contract

Every probe id in both files was deleted and verified gone at `count=0` under all three
perspectives (`published`, `drafts`, `raw`) on type `pdsW30FenceProbe`, which held zero documents
before the run and holds zero after.
