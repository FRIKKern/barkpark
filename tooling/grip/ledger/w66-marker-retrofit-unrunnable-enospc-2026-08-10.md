# w66 verify — marker-retrofit-and-seven-rows: UNRUNNABLE (host ENOSPC), with re-derivation recipes

Date: 2026-08-10. Verifier: `marker-retrofit-and-seven-rows` (cloud-console-hardening wave 66).

## Harness fault (the finding)

Every `Bash` invocation in this phase died before the command ran:

```
ENOSPC: no space left on device, open
'/private/tmp/claude-501/-Volumes-SATECHI-github-barkpark/d10b01bb-c28b-4379-914a-ad1ad6677209/tasks/<id>.output'
```

Probed six times across ~15 minutes, including `true`, `echo alive`, and `df -h /`. The tool cannot
allocate its own stdout capture file, so ZERO commands executed — not `bp`, not `gh`, not `git show`.
This is the same wall three survey agents hit. It is the epic's own subject wearing a defect's face:
an environment fault that a gate would report as exit 1.

Only `Read` (direct FS) worked. Everything below marked RECIPE was NOT run.

## RECIPES — run these first, in this order, once the disk is freed

```sh
# 0. free the disk and PROVE it
df -h / && du -sh /private/tmp/claude-501/* | sort -h | tail -20

# 1. assignment (a) — the seven marker-bearing rows
for t in cch-w63-s7 cch-w63-s8 cch-w64-s6 cch-w65-s2; do bp task get "$t" -o json; done
bp task get cch-w65-bl-... -o json   # the three cch-w65-bl-* rows, ids resolved from the roster
gh api repos/:owner/:repo/pulls --paginate --jq '.[]|select(.body|test("Task: cch-w6"))|.number'

# 2. is the github plugin actually ON on guerrilla? (the real question behind (a))
bp capabilities -o json | jq '.plugins'          # is "github" listed/enabled?
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://guerrilla.barkpark.cloud/v1/plugins/github/webhook
#   404 => route not mounted => plugin NOT whitelisted => reconcile_merge_gate has NO live caller
#   401/403 => mounted, signature plug refused => plugin IS on
gh api repos/FRIKKern/barkpark/hooks 2>&1 | head    # does a webhook even exist?

# 3. origin/main truth for the code read below (the working tree is L3 and the charter copy is STALE)
git show origin/main:api/lib/barkpark/plugins/github.ex | grep -n 'default_enabled?\|required_creds'
git show origin/main:api/lib/barkpark_web/controllers/github_webhook_controller.ex | grep -n 'pull_request'
git show origin/main:api/lib/barkpark_web/controllers/tasks_controller.ex | grep -n 'parse_criteria_entry' 

# 4. assignment (b) — actionable retrofit scope (OPEN + merged-but-unclosed only, NOT the 400+ roster)
bp task get cloud-console-hardening-epic -o json | jq '[.children[]|select(.lifecycle_status=="open")]|length'
#   then per-row: does it carry merge_gate:true, and did its PR merge?
#   DO NOT run a bulk sweep — the whole-array patch is measured-lossy (no CAS).
```

## What was established WITHOUT bash (Read only, working tree = L3)

- `api/lib/barkpark/plugins/github.ex:75` — `def default_enabled?, do: false`.
- `api/lib/barkpark/plugins/github.ex:84` — `@required_creds ~w(repo app_id installation_id private_key webhook_secret)`;
  `validate_settings/1` refuses a half-provisioned App.
- `api/lib/barkpark/plugins/github.ex:242` — `POST /github/webhook` is mounted by `register_routes/1`,
  i.e. by the PLUGIN. Plugin off = route absent.
- `github_webhook_controller.ex:85` — `"pull_request" -> handle_pull_request(...)` is the ONLY caller
  of `MergeEvents.handle/2`, which is the only caller of `Tasks.reconcile_merge_gate/3` outside close.
- `merge_events.ex:64` — trailer regex `~r/^\s*task:\s*([a-z0-9][a-z0-9._\/-]*)/im`; `:no_trailer`,
  `{:ambiguous_trailer, ids}`, `{:unknown_task, doc_id}` are named refusals.
- charter (LOCAL COPY, stale — see D630) `:151` — "It does NOT touch `api/lib/barkpark/tasks/`,
  `tasks_controller.ex`, `plugins/tasks.ex`" — an EXCLUSION, not a grant.

## The structural claim this hands Decide

If the github plugin is not whitelisted with all five credentials on guerrilla, `reconcile_merge_gate`
has ZERO live callers on the merge path and the seven rows' `met:false` is fully explained by the
BINDING, not the marker. Recipe #2 settles it in one curl. Until it runs, no wave sentence may claim
the marker is the defect.
