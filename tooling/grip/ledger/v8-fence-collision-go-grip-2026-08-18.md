<!-- doc-tier: cold | canonical-for: v8-fence-collision-go-grip-recheck | budget: 900tok -->

# V8 fence-collision recheck — Go/grip security sweep (2026-08-18)

> HISTORICAL RECORD (2026-08-18) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Verdict: the 3 fix loci are collision-CLEAR against every open PR; zero open PR touches `tooling/grip/*.mjs`.

## Re-derivation recipe

Enumerate open PRs, then grep each PR's file list for the fix loci + grip code:

```
cd <repo>
for pr in $(gh pr list --state open --limit 200 --json number --jq '.[].number'); do
  gh pr view $pr --json files --jq '.files[].path' \
    | grep -E 'internal/(runtime/runtime|cli/scaffy_remote_cmd|cli/builtins|manifest/manifest|manifest/fetch)\.go|tooling/grip/.*\.mjs' \
    | sed "s/^/PR $pr: /"
done
```

## Findings (2026-08-18 snapshot)

Five open PRs touch `internal/**.go`: 11770, 11766, 10811, 10720, 10129.

| PR | internal/*.go touched | hits a fix locus? |
|---|---|---|
| 11770 | pdrender/pdrender.go, pdrender/route.go, pdrender/route_test.go | no |
| 11766 | manifest/fetch.go | NO — fetch.go, not manifest.go (same pkg, different file) |
| 10811 | cli/cloud_deploy_census_cmd.go, cloudclient/client.go | no |
| 10720 | cli/cloud_status_cmd.go | no |
| 10129 | cli/cloud_status_cmd.go, semrole/semrole.go, cloudclient/client.go | no |

Fix loci (defects 1-3): `internal/runtime/runtime.go`, `internal/cli/scaffy_remote_cmd.go`, `internal/cli/builtins.go`, `internal/manifest/manifest.go` (Parse at line 166). NONE appears in any open PR file list.

`tooling/grip/*.mjs`: zero open PRs. (Charter PRs 12223/12147/11924/10522/10496/10407/10173 DO add `tooling/grip/ledger/*.md` rows — the shared scratchpad, distinct filenames, no collision — but that is not the grip code layer and not a fix locus.)

## Residual for Decide

11766 is package-adjacent: it edits `manifest/fetch.go` while defect-3's client-side fix would land in `manifest/manifest.go` (Parse validation) or `cli/builtins.go` (emitter). Same Go package `manifest`, different file → zero textual conflict, but if both land the builder should recompile the package. No rebase forced by file overlap.
