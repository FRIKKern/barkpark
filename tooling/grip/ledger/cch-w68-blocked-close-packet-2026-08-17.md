# cch wave 68 — the Law-0 blocked-close packet (byte-exact), re-derivation recipe

Read timestamp (UTC): `2026-08-17` (verify phase, lane `blocked-close-packet`).
Re-derive, do not re-discover. Nothing in this file was written to the ledger by this lane —
the lead executes at Decide.

## 1. Required contexts (live read, never quoted)

```
gh api repos/FRIKKern/barkpark/branches/main/protection --jq '.required_status_checks.contexts'
["Elixir gate","PR references an active task","Cloud gate","Console gate"]
```

Exactly FOUR. Both blocked rows' merge-gate criteria are scored against this read.

## 2. The two rows, as stored

| row (doc_id) | PR | merge sha | compare→main | head sha | stored claim | progress | unmet index |
|---|---|---|---|---|---|---|---|
| `cch-w63-bl-teardown-failed-has-no-console-reader-at-all` | #11552 | `11412247df1db1293041c0adec4b5c0eb8e22250` | **ahead** (ahead_by=1) | `4958b757c510742a52cfd6af258ce9a6cfa711fb` | CLOSED by `codex-pr-audit` @ epoch 9 | 9/10 | **9** |
| `cch-w66-bl-site-delete-cascades-are-untested-and-one-is-three-days-old` | #11553 | `4b5d802a1d5a31030f79fa4eb8d4761eb4995db2` | **identical** (ahead_by=0, behind_by=0) | `7712ea9dbb942ced338140e6454e94ac06cc93b1` | CLOSED by `codex-pr-audit` @ epoch 7 | 8/9 | **8** |

Both heads: `Cloud gate`, `Console gate`, `Elixir gate`, `PR references an active task` = `success`,
`total_count=36` (< per_page=100, no truncation), each name appearing EXACTLY ONCE — no duplicated,
cancelled or skipped sibling of the four on either sha.

Re-derive:

```
gh api repos/FRIKKern/barkpark/compare/<merge-sha>...main --jq '"status=\(.status) ahead_by=\(.ahead_by) behind_by=\(.behind_by)"'
gh api 'repos/FRIKKern/barkpark/commits/<head-sha>/check-runs?per_page=100' \
  --jq '.check_runs[]|select(.name=="Elixir gate" or .name=="Cloud gate" or .name=="Console gate" or .name=="PR references an active task")|"\(.name) status=\(.status) conclusion=\(.conclusion)"'
```

## 3. Why the direction's close recipe is inert (verified, not assumed)

* Close-time autostamp fires ONLY on a criterion carrying an explicit `"merge_gate" => true`
  (`api/lib/barkpark/tasks/close.ex:689`, `autostamp_merge_gate/6` → `{:ok, :no_marker}` otherwise).
  Neither row has that key on ANY criterion (every entry's keys are
  `['criterion','evidence','met']`, plus `attempts` on row A index 8). So `close --set landed:=…`
  stamps nothing.
* `close --set criteria:=…` cannot flip the row either: the server's honesty gate refuses
  `criteria_unmet` with *"criteria flipped in this very close command do not count — that would be
  the closer grading its own homework"* (`api/lib/barkpark_web/controllers/tasks_controller/params.ex:722`).
* The flag lives on **stamp only** and is **client-side and help-invisible**:
  `internal/cli/tasks_stamp_cmd.go:322 stampMergeGateBlocked/324` refuses a `--met` whose
  `--criterion-text` matches `MERGE-GATED`/`MERGE GATED` (case-insensitive) unless `--merge-gated`
  is passed, and `:70-73` strips the token before the POST (the server does not declare it).
* Stamp is holder-only and epoch-fenced, so a FRESH claim is required. `blocked` IS claimable
  (`Validation.claimable_statuses/0 == ~w(open blocked)`, `api/lib/barkpark/tasks/claim.ex:28`), both
  rows have `dependency_count=0` and `queue_gate=null`, and both stored claims are CLOSED — so no
  `holder_override` is needed once the lead holds the claim.
* Claim bumps `current_epoch(doc) + 1` (`claim.ex:287`): expect **9 → 10** (row A) and **7 → 8**
  (row B). Read the epoch off the claim RESPONSE; never type the prediction.

## 4. Shell-quoting trap

Row A's criterion 9 text (404 chars) contains an apostrophe (`#11533's`) AND backticks. Single-quote
it with the `'"'"'` escape (backticks inside double quotes would execute). Row B's criterion 8 text
has no apostrophe — plain single quotes are safe. Both quoted forms were round-tripped through
`bp task stamp … --dry-run` (client-side preview, nothing sent) and the URL-encoded
`criterion-text=` matched the stored row.

## 5. The packet — run in this order, per row

Row A (`--criterion 9`), Row B (`--criterion 8`). `<EPOCH>` = the epoch the claim printed.

```
bp task claim <doc_id> cch-w68-lead
bp task stamp <doc_id> cch-w68-lead <EPOCH> --criterion <N> \
  --criterion-text '<byte-exact stored text>' \
  --met --evidence '<the sentence in §6>' --merge-gated --yes
bp task close <doc_id> cch-w68-lead <EPOCH> done '<one-line rationale>' --yes
```

The stamp's own read-back (PDS-D359/D361) re-reads the row and exits non-zero if the store does not
hold it — a printed `rev` is not persistence; trust the read-back line, not the envelope.

## 6. Row B's honest evidence sentence (compare is `identical`, not `ahead`)

`4b5d802…` IS `origin/main`'s tip (`gh api repos/FRIKKern/barkpark/commits/main --jq .sha` →
`4b5d802a1d5a31030f79fa4eb8d4761eb4995db2`). `identical` is the STRONGEST form of the criterion's
intent, not a miss: the merge commit is on main with nothing after it. It flips to `ahead` the
instant any commit lands. State it that way in the evidence — do not write `ahead`.
