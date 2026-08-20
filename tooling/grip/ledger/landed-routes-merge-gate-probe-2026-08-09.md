# `--set landed:=` routes; the merge gate is payable by any claim holder — w65 verify

Re-derivation recipes for the cloud-console-hardening wave-65 `landed-routes` verifier.
All server reads are `git show origin/main:<path>`. All bp runs are against a **scratch draft
task** created for the probe (three were created, all closed; nothing real was touched).

## 1. The manifest does not declare `landed`; the controller reads it anyway

    bp capabilities -o json | grep -c landed                 # => 0
    python3 -c "import json,sys;d=json.load(sys.stdin);print(d['commands'][131])" < caps.json
    # task/close: args [doc_id*, worker_id*, observed_epoch*, lifecycle_status, reason]
    #             flags [set, observed_rail_rev]        <- no `landed`
    git show origin/main:api/lib/barkpark_web/controllers/tasks_controller.ex | sed -n '490p'
    # |> Params.put_opt(:landed, params["landed"])

Why it still works: `task.close` declares **no `set_key`**, so `--set` merges FLAT into the
JSON body (`internal/cli/run.go:928-960` on origin/main, `setTarget := obj` when
`cmd.SetKey == ""`). Any `--set k:=v` becomes a top-level body key. No manifest arg is needed.

## 2. Proof by A/B on the same scratch task

    bp task create --set title='probe' \
      --set 'acceptance_criteria:=[{"criterion":"MERGE-GATED: the PR merges","met":false,"merge_gate":true},
                                   {"criterion":"plain unmet criterion","met":false}]' -o json
    bp task claim <id> w65verify -o json          # epoch 1
    bp task close <id> w65verify 1 -o json                       # => exit 2, criteria_unmet:0,1
    bp task close <id> w65verify 1 \
      --set 'landed:={"prs":[11435],"commit":"26b8614259"}' -o json  # => exit 2, criteria_unmet:1

Index 0 (the `merge_gate:true` row) is DEDUCTED from the unmet list iff `landed` rides the
close. Index 1 (plain) is not. `close.ex:448-460 unmet_after_autostamp/2`.

Single-criterion variant closes cleanly (exit 0) and autostamps:

    "evidence": "auto: lead-closed on merge by w65verify (epoch 1) — landed PR #11435 (commit 26b8614259) at 2026-08-09T21:12:31Z"

## 3. The `:=` trap (able-to-fail control, same task, two runs)

    bp task close <id> w65verify 1 --set  'landed={"prs":[11435]}' -o json  # exit 2 criteria_unmet:0
    bp task close <id> w65verify 1 --set 'landed:={"prs":[11435]}' -o json  # exit 0, autostamped

`landed=` sends a JSON **string**; `close.ex:675 when is_map(landed)` never matches, the
autostamp silently does not fire, and the refusal says nothing about `landed`.

## 4. What `landed` persists

    git show origin/main:api/lib/barkpark/tasks/close.ex | grep -n '@landed_keys'
    # 606:  @landed_keys ~w(prs files capability_slugs)

`commit` is NOT persisted (observed `content.landed == {"prs":[11435]}`); it survives only
inside the composed evidence sentence via `landed_summary/1` (`close.ex:738-741`).

## 5. Exit codes

    git show origin/main:internal/cli/cli.go | grep -n 'exit.* = '
    # 33: exitUsage = 2   36: exitValidation = 5

`exitValidation` is defined in `internal/cli/cli.go:36`, NOT in `errors.go` (errors.go only
USES the constant, 14 times). `criteria_unmet` is absent from `codeExit`; the server emits it
on the `{"ok":false,"reason":…}` branch, whose unknown-code fallback is `exitUsage` — measured
**2**, three times. The `exitValidation` (5) codes are the neighbouring criteria family:
`criteria_mismatch`, `criteria_index_out_of_range`, `criterion_text_required` (`errors.go:101-103`).

## 6. The enforcement gap (the actual finding)

Charter law 5 (`.claude/workflows/bp-cloud-console-hardening-charter.md:103-106`) says
MERGE-GATED criteria are "stamped by the LEAD, never the builder". The server enforces no such
thing: `autostamp_merge_gate/6` checks only `status == "done"` and `is_map(landed)`. Worker
`w65verify` (not a lead) paid a merge gate with an arbitrary PR number belonging to a
different epic, and the auto-composed evidence still reads "lead-closed on merge by w65verify".
Nothing verifies the PR exists, is merged, or references the task.

Second half of law 5 confirmed by measurement: this epic's criteria carry the marker in TEXT
only, never the flag —

    bp task get cch-w64-s5-law-0-twelve-closes-and-three-integers -o json
    # 12 criteria, merge_gate absent on all 12; criterion 11 text starts "MERGE-GATED (the lead
    # closes this)"; content.landed == null

So on this epic `--set landed:=` autostamps nothing today. The fix is two lines of AUTHORING
(add `"merge_gate": true` beside the MERGE-GATED wording), plus a decision about who may pay
it. No `api/` change and no manifest arg is required.

Scratch tasks used and closed: `task-f80d64a4b9e380be`, `task-837c98b7eb4d3150`,
`task-25b6a5de30e62e6a`, `task-3d59d0bc441b4b63` (all drafts, worker `w65verify`).
