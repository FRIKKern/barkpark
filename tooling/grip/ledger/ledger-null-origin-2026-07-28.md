# Re-derivation: can the ledger emit a 200 with a null/absent `result`? (honest-gates wave 4 verify)

Measured 2026-07-28 against live guerrilla, the working checkout at `/Volumes/SATECHI/github/barkpark`,
and a local ExUnit run. Lane: `ledger-null-origin`. Claim under test: *"the `missing` branch of
`scripts/pr-task-gate.sh` is reachable only via a 200-with-null — is such a response emittable at all?"*

VERDICT: **emittable server-side, unreachable by this gate's own request.** `GET /v1/data/doc/...`
answers 200 with NO `result` key whenever the caller suppresses the envelope
(`?filterresponse=false`, or `Accept: application/vnd.barkpark+json+filterresponse=false`), and the
gate's parser reads that body as `missing` → false accusation. The gate can never send either form:
`extract_task_id` strips `?` and `&` from the id. So the branch is dead **only because of a regex in an
unrelated function**. SHIP THE REROUTE (exit 2 UNCHECKED), do not delete.

| # | Claim | Command |
|---|---|---|
| 1 | Genuine nonexistence answers HTTP 404 with a `not_found` body — never 200 | `curl -s -w '\nHTTP=%{http_code}\n' https://guerrilla.barkpark.cloud/v1/data/doc/production/task/definitely-not-a-real-task-xyz123` |
| 2 | `Content.Query.get_document/4` returns `{:error, :not_found}` on `Repo.one() == nil` — `{:ok, nil}` is unrepresentable | `sed -n '725,740p' api/lib/barkpark/content/query.ex` |
| 3 | `Envelope.render/3` merges `_id` AFTER the content drop and `@reserved` keys are never redacted; `project_fields` keeps every `_`-prefixed key | `sed -n '50,70p;167,178p' api/lib/barkpark/content/envelope.ex; sed -n '745,756p' api/lib/barkpark_web/controllers/query_controller.ex` |
| 4 | EMITTER: `respond_json` skips the `%{result: …}` envelope when `conn.assigns.barkpark_filterresponse` is false, set by the vendor plug from `?filterresponse=false` or the Accept suffix | `sed -n '479,487p' api/lib/barkpark_web/controllers/query_controller.ex; sed -n '43,49p' api/lib/barkpark_web/plugs/accept_barkpark_vendor.ex` |
| 5 | Live proof of the emitter: same doc, 200, body starts `{"_createdAt":…` with no `result` key | `curl -s 'https://guerrilla.barkpark.cloud/v1/data/doc/production/task/task-615869d6e93ddb2b?filterresponse=false' \| head -c 120` |
| 6 | 7/7 unit proof: plain GET + `?fields=` + anonymous redaction always carry `result._id`; nonexistent id and real-id/wrong-type are both 404; both suppression forms are 200-without-`result` | `cd api && CC=clang mix test <scratchpad>/null_result_probe_test.exs` (fixture: dataset `nullprobe`, type `probedoc`) |
| 7 | The gate cannot send a suppressing request: the id extractor drops `?…`/`&…` | `PR_BODY='Task: task-abc?filterresponse=false' bash scripts/pr-task-gate.sh --extract-task-id` |
| 8 | Handed such a body, the gate today FALSELY ACCUSES (exit 1, "does not exist on the ledger") for both `{"result":null}` and the bare-doc shape | local fixture server on 127.0.0.1, `TASK_ID=nullres LEDGER_BASE=http://127.0.0.1:$PORT bash scripts/pr-task-gate.sh` |
| 9 | MUTATION PROOF of the fix: the same two fixtures become exit 2 UNCHECKED with the one-line reroute, a real claimed task still passes (exit 0), and a genuine 404 still reds definitively (exit 1) | patched copy in scratchpad, same three `TASK_ID`s + live guerrilla 404 |
| 10 | The reroute breaks no real detection: the full harness passes 62/62 against the patched copy (same as unpatched) | `cd <patched-copy> && bash scripts/pr-task-gate.test.sh` |
| 11 | The harness has NO fixture for the `missing` branch today (`missing.json` is a MALFORMED-JSON 200 → the `error` branch) | `grep -n 'missing' scripts/pr-task-gate.test.sh` |

DELETION IS NOT TWO LINES: the python emitter also emits `missing`, so removing the `case` arm falls
through with `lifecycle="."` into the catch-all at `scripts/pr-task-gate.sh:330`, which prints a second,
worse false accusation (`task 'X' is '.' — only 'in_progress' … back a change`).

CAVEAT FOR DECIDE: exit 2 still BLOCKS (the workflow turns UNCHECKED into a failure, by design, D24).
The reroute removes the false accusation and makes the red re-runnable; it does not make a correct PR
mergeable through a degraded ledger.
