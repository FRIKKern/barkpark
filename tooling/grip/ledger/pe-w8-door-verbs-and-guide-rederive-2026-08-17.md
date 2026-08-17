# pe-w8 door-verbs-and-guide — re-derivation recipes (2026-08-17)

Verifier assignment [door-verbs-and-guide]. Each row re-derives a load-bearing fact for the cold-agent run.

## Guide primary door = `bp paper new` → `bp paper push` (raw-API is the alternative)
```
bp paper pull paper-authoring-excellence
grep -nE 'bp (paper|bulldocs|doc|media)' .barkpark/papers/paper-authoring-excellence.bpml
```
Line 7 `pax-code-door`: `bp paper new my-paper` (local scaffold) then line 9 `bp paper push my-paper`
(validate + publish; creates the paper when absent). Line 15 `pax-p-door3`: raw-API alternative
`bp bulldocs publish <slug> --file payload.json --yes` "stays for pipelines that assemble JSON."

## Guide NAMES literal tags authoring-excellence + bulldocs, both REGISTERED (flips tag-422 to AGENT-defect)
```
sed -n '16,30p' .barkpark/papers/paper-authoring-excellence.bpml   # pax-code-shape payload example
bp doc get tag authoring-excellence
bp doc get tag bulldocs
```
Both return a live `_type:"tag"` doc. Guide example tags are valid → a run 422-on-tags is an agent
invention, not a door defect.

## Installed bp is PRE-#11934 — does NOT answer `bp paper new` yet
```
bp version                                   # commit a653550420, cli_version dev
bp paper --help 2>&1 | grep -c new           # 0
```
Help still routes writes to `bp bulldocs publish`. cli-build after #11934 merge is mandatory before ignition.

## #11934 adds the `new` verb + create-on-push (D41)
```
gh pr view 11934 --json state,mergeStateStatus  # OPEN / BLOCKED (not merged at run time)
gh pr diff 11934 | grep -nE 'case "new"|paper_new_cmd'
```
`case "new": ... return runPaperNew` dispatch; new file internal/cli/paper_new_cmd.go; server
create-on-push arm (sync_create/6).

## Guide rev pin
rev 2, remote current; local file sha256 c7fd951b8e5fccbb0664337d99111c402a84f8dbd2f50d51a257c0dd490ad64b
```
bp paper status paper-authoring-excellence
shasum -a 256 .barkpark/papers/paper-authoring-excellence.bpml
```
