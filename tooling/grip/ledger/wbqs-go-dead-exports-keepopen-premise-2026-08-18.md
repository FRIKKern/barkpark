<!-- doc-tier: cold | canonical-for: wbqs-go-dead-exports-keepopen-premise-smoke | budget: 900tok -->

# wbqs-go-dead-exports keep-open premise smoke (2026-08-18)

> HISTORICAL RECORD (2026-08-18) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Re-derivation recipe for the verdict that `wbqs-go-dead-exports-coordination-gated-backlog`
stays OPEN as genuine coordination-gated residue. Verified against origin/main @ `710c38f06a7e`.

## Claim: the named seams are still zero PRODUCTION callers (dead exports)

```
git grep -nE 'DefaultSpec\(|WithCredential\(|WithSSHPublicKey\(|ConfigFromEnv\(|GetCredentials\(' origin/main -- '*.go'
```

Read the results by seam:

- `azure.DefaultSpec()` — DEF-only at `internal/cli/cloud/azure/provider.go:62`. Zero callers.
  (Do NOT confuse with the generic `cloud.DefaultSpec(provider string)` at
  `internal/cli/cloud/provider.go:334`, which IS live — callers at provider.go:441,
  restore_driver.go:238. The azure analogue takes no args and is the dead one.)
- `azure.WithCredential()` — DEF-only at `internal/cli/cloud/azure/provider.go:113`. Zero callers.
- `azure.WithSSHPublicKey()` — DEF-only at `internal/cli/cloud/azure/provider.go:125`. Zero callers.
- `apiclient.ConfigFromEnv()` — DEF at `internal/apiclient/client.go:72`; only other hit is a
  prose comment at `internal/cli/cli.go:625`. Zero true call sites:
  `git grep -nE 'ConfigFromEnv\(\)' origin/main -- '*.go' | grep -vE 'client.go:72|// '` → empty.
- `cloudclient.GetCredentials(ctx, id)` — DEF at `internal/cloudclient/client.go:846`; every
  caller is in `internal/cloudclient/client_test.go` (219,226,264). TEST-ONLY.
  Production uses the sibling `GetCredentialsForTeam` (client.go:852; called from
  `internal/cli/cloud12_cmd.go:319,1621` and `internal/cli/setup_cloud_login.go:35,186`).

Word-boundary trap: `\bGetCredentials\b` does NOT match `GetCredentialsForTeam` (no boundary
before "ForTeam"), so isolate the bare method with `GetCredentials\(` then grep -v the ForTeam form.

## Claim: the gate that makes deleting these seams unsafe is still LIVE

```
bp task get azh-go-live-human-gate -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'],d['criteria_progress'])"
```
Expect `open {'met': 0, 'total': 4}`. While azh-go-live is open, the azure provider seams are
staged-not-yet-wired, not truly dead — removing them would undo staged go-live work.

## Row state (unclaimed, correctly parented)

```
bp task get wbqs-go-dead-exports-coordination-gated-backlog -o json
```
Expect `lifecycle open`, `claim None` (no re-claim needed), `parent wild-bulk-quality-sweep-2026-07-16-epic`, criteria 0/5.

## Verdict

KEEP OPEN. All five named code sites exist on origin/main; all are zero production callers;
the gating epic azh-go-live-human-gate is still open (0/4). Premise holds — not out of date.
