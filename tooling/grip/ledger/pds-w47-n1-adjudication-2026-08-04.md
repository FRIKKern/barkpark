# PDS w47 — adjudicating the seventeen one-criterion-from-done rows

**Task:** `pds-w47-n1-adjudication` · **worker:** `epic-builder-the-seventeen-one-criterion-from-done-ro`
**Board writes made as:** `pds-w47-adjudicator` · **date:** 2026-08-04 · **branch:** `loop-epic/the-seventeen-one-criterion-from-done-ro-4`

Seventeen open PDS rows sat exactly one criterion from done. This slice adjudicated all seventeen
and wrote to seven of them. **Nothing was closed** — every board write is a `bp task stamp` with
quoted, re-derived evidence; the `bp task close` seal is the lead's.

The wish this serves: *a verb, receipt, class, gate or price must descend from a measurement or
refuse*. An open row is a claim. Closing thirteen because thirteen PRs merged would have asserted a
disposition that does not descend from the measurement the rows' own criteria name — eleven of the
thirteen conjoin an **independent lead re-derivation** and each forbids re-reading the builder's.
So: two closed on evidence in hand, five were **bought by run**, ten stay open, and the ten are
named with the measurement each still owes.

---

## 0. The population, re-derived — not inherited

```
bp task ls --all -o json > /tmp/w47board.json
python3 -c "import json;d=json.load(open('/tmp/w47board.json'))['docs'];
print(sum(1 for x in d if x.get('lifecycle_status')=='open'
      and (x.get('doc_id') or '').startswith('pds-')
      and (c:=(x.get('content') or {}).get('acceptance_criteria'))
      and len(c)-sum(1 for a in c if a.get('met'))==1))"
→ 17
```

Still 17 at 2026-08-04T12:52Z, and the member set matches the brief exactly. The population is a
point-in-time read: another session closing one changes it, which is why it is re-derived here
rather than carried forward.

**The same filter, re-run after this slice's seven stamps, answers `10`** — the seven rows moved out
of the N−1 class because each now sits at N/N (`in_progress`, awaiting the lead's seal), and the ten
that stay open are exactly the ten named below. The filter is the deliverable's own meter, and it
moved by seven.

| row | N | class |
|---|---|---|
| `pds-w45-bl-sweep-adjudication-frozen-blob` | 7 | **closed on evidence in hand** (stamped) |
| `pds-w41-residue-lens-unrun` | 10 | **closed on evidence in hand** (stamped) |
| `pds-w38-falsifier-promotion` | 10 | **bought by run** (stamped) |
| `pds-w39-record-parity-shallow-guard` | 10 | **bought by run** (stamped) |
| `pds-w34-owning-doc-amendment` | 12 | **bought by run** (stamped) |
| `pds-w38-verdict-freshness-arm` | 12 | **bought by run** (stamped) |
| `pds-w38-charter-ledger-disagreement-sweep` | 10 | **bought by run** (stamped) |
| `pds-w42-paper-op-principal-gate` | 10 | expensive — stays open |
| `pds-w42-liveview-authorization-column` | 14 | expensive — stays open |
| `pds-w41-hop-arg-producer` | 11 | expensive — stays open |
| `pds-bl-w41-readonly-member-sees-published-only` | 13 | expensive — stays open |
| `pds-w40-scim-groups-list-members` | 9 | expensive — stays open |
| `pds-bl-status-only-residue-payment` | 8 | expensive — stays open |
| `pds-bl-charter-says-opaque-callers` | 1 | **misfiled** — re-scoped, not closed |
| `pds-bl-w41-component-gate-blast-radius` | 1 | **misfiled** — re-scoped, not closed |
| `pds-w25-round-parked` | 8 | **misfiled** — re-scoped, not closed |
| `pds-w25-round-open` | 8 | **misfiled** — re-scoped, not closed |

---

## 1. THE PR-RESOLUTION RECIPE — commit this so the next wave does not rediscover it

**`content.github.issue` is the mirrored ISSUE number, never a PR number.** Treating it as a PR
fails on every row:

```
$ gh pr view 9259 --json state
GraphQL: Could not resolve to a PullRequest with the number of 9259. (repository.pullRequest)

$ gh pr view 8787 --json state
GraphQL: Could not resolve to a PullRequest with the number of 8787. (repository.pullRequest)

$ gh issue view 9259 --json number,title,state
issue 9259 OPEN: A write-denied Studio member stops writing papers through handle_info
```

The number resolves as an **issue** and only as an issue. Note the second trap: `gh pr view … | head`
returns rc=0 for the *pipeline* even as the view fails, so read the unpiped rc or the stderr text.

**The charter's task-to-PR tables are the only working resolver**, and they resolve cleanly:

```
$ git show origin/main:.claude/workflows/bp-pds-charter.md > /tmp/charter_main.md
$ grep -n "pds-w34-owning-doc-amendment" /tmp/charter_main.md
3962:| `pds-w34-owning-doc-amendment` | `pds-w39-r-owning-doc` | #9117 | the owning doc's population
      becomes `router.ex`; … first byte-gate enrolment at a MEASURED cap |
```

`#9117` is a real PR and `gh pr view 9117` answers. The recipe is therefore:
**grep the charter on `origin/main` for the task slug → read the `#NNNN` column → verify with
`gh pr view`, `git merge-base --is-ancestor <mergeCommit> origin/main`, and check-runs on the PR
head against the four names in `.github/required-checks.json`.**

**The four required contexts are themselves a read, not a memory:**
`git show origin/main:.github/required-checks.json` → `protection.required_status_checks.checks` =
`Cloud gate`, `Console gate`, `Elixir gate`, `PR references an active task` (app_id 15368 each).

**One more trap, recorded because it cost a round-trip.** `bp task stamp` refuses a `--met` whose
`--criterion-text` **contains the phrase** `MERGE-GATED` anywhere:

```
bp: refusing to stamp a MERGE-GATED criterion met: --criterion-text carries the MERGE-GATED marker,
    and that row is the lead's to close … Pass --merge-gated to override only if you are the lead
    closing the gate.
```

Every stamp below carries the explicit `--merge-gated` override. That is recorded here rather than
hidden.

**And the tripwire over-fires**, which is worth more than the round-trip it cost. This slice's *own*
criterion 5 — *"THE FOUR MISFILED ROWS ARE RE-SCOPED IN PROSE with the measurement that shows why
they are **not merge-gated** …"* — is builder-owned, has no merge gate, and was refused with
`merge_gated_criterion` until `--merge-gated` was passed. The match is on the phrase, not on the
marker's position. The cost is not a blocked write; it is that **the override becomes routine**, and
an override typed by habit stops protecting the rows it exists for. This is not a new finding:
`pds-w27-bl-stamp-guard-substring-false-positive` filed it nine waves ago and is **still open at
0/4**. A duplicate row opened here was adjudicated `disposition: closed` and points at the wave-27
row, which now inherits this fresh 2026-08-04 reproduction.

The guard behind it is nonetheless real, not decorative — probed by mutation on a live row:

```
# same index, ONE phrase deleted from the criterion text
bp task stamp … --criterion 0 --criterion-text "THE POPULATION IS RE-DERIVED FIRST, : the count …"
rc 5
bp: the criterion text you passed is NOT the wording stored at that index … Nothing was written.
```

---

## 2. The two that closed on evidence in hand

### `pds-w45-bl-sweep-adjudication-frozen-blob` — criterion 6 → MET (row now 7/7, still open)

Its unmet criterion has **no second conjunct**: *"MERGE-GATED (the LEAD closes this): the PR is
merged to main with all four required contexts green."* Merge + 4/4 discharges it in full — the only
unconditionally free one in the set.

```
$ gh pr view 9476 --json number,state,mergedAt,mergeCommit
{"mergeCommit":{"oid":"430480ce0d28fc4ed3b408afca2ee2e9a8a84b91"},
 "mergedAt":"2026-08-04T11:12:01Z","number":9476,"state":"MERGED"}

$ git merge-base --is-ancestor 430480ce0d28fc4ed3b408afca2ee2e9a8a84b91 origin/main && echo ANCESTOR
ANCESTOR

# check-runs on PR head 8dcb5771a16d03fc45f92dd433f46fa2af6f0b3e
Cloud gate                      completed  success
Console gate                    completed  success
Elixir gate                     completed  success
PR references an active task    completed  success
```

### `pds-w41-residue-lens-unrun` — criterion 9 → MET (row now 10/10, still open)

Its second conjunct is an **L2 → L1 promotion**: *"the lead confirms from the first CI run that the
case actually EXECUTED on the runner."* The local proof ran on Elixir 1.19.5 / OTP 28 while CI pins
1.18.1 / OTP 27.

*Merge half.* The case landed on head `59fdf4c9cd90f1f823aeb31e15fb189148a96662`;
`gh api repos/FRIKKern/barkpark/commits/59fdf4c9c…/pulls` → PR **#9296**, merged
2026-08-02T17:48:30Z, merge commit `0d875b35c02d1fd466afb7f2bb98928f8b3b0071`, ANCESTOR of
`origin/main`, 4/4 contexts success.

*Execution half.* Run `30759156397` (workflow `elixir`, headSha `59fdf4c9c`, conclusion success),
job `Test (Elixir 1.18.1 / OTP 27.0)` (`databaseId 91526559023`, success):

```
job log 6790-6791:  Run mix test          ← BARE mix test: no --only, no extra --exclude
job log 10076:      2026-08-02T17:46:46.6063042Z 27 doctests, 13408 tests, 0 failures, 48 excluded

$ git show 59fdf4c9c:api/test/barkpark/pds_residue_lens_test.exs | grep -cE '@tag|@moduletag'
0                                   ← and byte-identical to origin/main's copy (diff -q → IDENTICAL)
```

`api/test/test_helper.exs` excludes **only by tag** (`bokbasen_integration`, `phase8_demo`,
`requires_wi3`, `requires_wi4`, `flaky`, `boot_test`, `plugin_routes`, `requires_vips`,
`idp_interop`, `real_binary`), so an untagged case cannot be among the 48 excluded.

**THE INFERENCE, STATED RATHER THAN HIDDEN.** `mix test` prints no per-file line, and
`grep -niE 'residue_lens|residue lens'` over the full 11 029-line job log returns **zero hits**. This
is not a named log entry. It is a three-link exclusion argument:

1. the file sits under the default test path and carries no tag → `mix test` loaded it;
2. its `setup_all` calls `System.find_executable("elixir") || flunk(…)` and both tests shell that
   binary through `System.cmd`, so a runner **without** a bare `elixir` on PATH would fail loud, not
   skip;
3. the job reported **0 failures**.

Therefore the case executed and passed on 1.18.1 / OTP 27. L1 by exclusion — which is exactly the
promotion the criterion demanded, and is weaker evidence than a named log line would have been.

---

## 3. The five bought by run

Every merge half was re-resolved through the charter table and re-verified; every second conjunct
was re-derived on this host. **No builder transcript was read as evidence.**

| row | PR | merged | merge commit | ancestor | 4/4 |
|---|---|---|---|---|---|
| `pds-w38-verdict-freshness-arm` | #9112 | 2026-08-02T07:58:48Z | `9730f6931` | yes | yes |
| `pds-w38-falsifier-promotion` | #9113 | 2026-08-02T07:58:56Z | `716429bcb` | yes | yes |
| `pds-w39-record-parity-shallow-guard` | #9115 | 2026-08-02T07:59:03Z | `190cadf91` | yes | yes |
| `pds-w38-charter-ledger-disagreement-sweep` | #9116 | 2026-08-02T07:59:11Z | `aa81a9b6e` | yes | yes |
| `pds-w34-owning-doc-amendment` | #9117 | 2026-08-02T07:59:18Z | `8e1e27d6b` | yes | yes |

### 3.1 `pds-w38-falsifier-promotion` — the blinding mutation re-run → rc=1

```
# BASELINE, unmutated worktree cut from origin/main
$ elixir scripts/pds-elixir-receipt-census.exs; echo EXIT=$?
  checked 91 row(s) against 5 ARMED redding value(s) · 0 refusal(s) · 0 advisory contradiction(s)
  PASS  BASIS-FALSIFIERS   every decidable falsifier holds across the register's cited basis tokens
CENSUS OK
EXIT=0

# MUTATION: blind the context reads in
#   api/test/barkpark/plugins/github/inbound_events_test.exs
#   Content.get_document( :105 :163 · Conflicts.list( :112 · Repo.all( :119  →  Blinded.*
$ elixir scripts/pds-elixir-receipt-census.exs; echo EXIT=$?
  checked 91 row(s) against 5 ARMED redding value(s) · 3 refusal(s) · 0 advisory contradiction(s)
  FAIL  BASIS-FALSIFIERS   3 basis token(s) REFUSED by their own falsifier:
        …github_webhook_controller.ex [two_hop_composed] …inbound_events_test.exs:201 reads no
        persisted state — no `Repo.` / `Content.get_document(` / `Conflicts.list(` in the cited
        block or its helpers, so the second hop is not visible  (×2 at :201, once at :235)
CENSUS FAILED — an integrity check went red.
EXIT=1
```

The mutant leaves the test uncompilable and **must not be committed**: the file was restored
byte-for-byte and `git status --porcelain` is empty.

### 3.2 `pds-w39-record-parity-shallow-guard` — mutant (b) → the off-HEAD-graft fixture reds

Mutant (b) is the load-bearing one: it replaces the walk predicate with the *tempting wrong* guard,
the store-level `git rev-parse --is-shallow-repository`.

```
# BASELINE
$ bash scripts/pds-record-parity.test.sh
PASS  76 checks, 0 failures

# MUTANT (b): scripts/pds-record-parity.sh walk_truncation(), `true) : ;;` →
#   true) WALK_STATE="truncated"; WALK_GRAFT="<store-level --is-shallow-repository>"; return 0 ;;
$ bash scripts/pds-record-parity.test.sh
FAIL  the refusal names the GRAFT it stopped at
FAIL  a store-shallow repo whose HEAD history is COMPLETE still RUNS
FAIL  the off-HEAD-graft repo's full corpus is read (3 commits, 3 citations)
FAIL  the off-HEAD-graft repo greens on its real corpus
FAIL  a graft that is NOT an ancestor of HEAD does not truncate the walk
FAIL  76 checks, 5 failures
```

The sibling assertion *"an off-HEAD graft is a decided answer, not an unknown"* still passes, which
is right: mutant (b) makes the answer **wrong**, not **unknown**. Script restored; `git status`
empty.

### 3.3 `pds-w34-owning-doc-amendment` — the cap re-measured from the artifact

```
$ git show 8e1e27d6b:docs/decisions/success-claim-census.md | wc -c
18507
$ git show 8e1e27d6b:scripts/check-doc-budgets.sh | grep -n success-claim-census
69:docs/decisions/success-claim-census.md 19307

19307 − 18507 = 800 EXACTLY          ← the D507 headroom standard, to the byte

$ git log --oneline -1 -S"docs/decisions/success-claim-census.md 19307" -- scripts/check-doc-budgets.sh
8e1e27d6b docs(pds): the census doc's population is router.ex … and its cap is measured (#9117)
```

The cap was **born in this PR**. It is neither the void `15400` nor the independently-built
`15548 + 800 = 16348` that the row names as discarded prior attempts — it descends only from 18507.
The tier header reads `budget: 4800tok` and 19307/4 = 4826.75, i.e. roughly cap/4 as required.

```
$ bash scripts/check-doc-budgets.sh; echo RC=$?
ok:   docs/decisions/success-claim-census.md 19299B <= 19307B
check-doc-budgets: PASS
RC=0
```

**One honest observation, not a defect of this row:** the doc has grown 18507 → 19299 B on
`origin/main`, so **792 of the 800 B of headroom are spent and 8 B remain**. The cap is still
correct-by-derivation; the *headroom* is nearly gone and the next edit of any size reds the byte
gate. Filed as follow-up work rather than folded into the criterion.

### 3.4 `pds-w38-verdict-freshness-arm` — one REFUTED-row correction re-derived from source

Taking the `SessionController` row (one of the two):

```elixir
# 501fb9670 — the count is DISCARDED, so REFUTED was TRUE then
from(t in UserSession, where: t.token_hash == ^hash and is_nil(t.revoked_at))
|> Repo.update_all(set: [revoked_at: now])
:ok

# origin/main — api/lib/barkpark/accounts.ex:336-346
@spec revoke_user_session_token(binary()) :: {:ok, non_neg_integer()}
{revoked, _} = from(…) |> Repo.update_all(set: [revoked_at: now])
{:ok, revoked}

# and the CALLER reads it — api/lib/barkpark_web/controllers/session_controller.ex
:411   {:ok, n} = Barkpark.Accounts.revoke_user_session_token(token)
:420   |> put_flash(:info, sign_out_flash(revoked))
:429   defp sign_out_flash(0), do: "You were already signed out."
:430   defp sign_out_flash(_revoked), do: "Signed out."
```

The drive the roster note cites exists:
`api/test/barkpark_web/controllers/session_controller_test.exs:129` posts `/logout`, asserts
`"Signed out."`, then reads the **stored** `UserSession` row back through `Repo.one/1` and refutes
`revoked_at` is nil, then posts again and checks the timestamp is untouched.

Conclusion, derived here and not read: the `REFUTED` verdict outlived its defect; `PROVEN` is
correct on main, and the roster row's note at `census.exs:798-802` matches the source.

### 3.5 `pds-w38-charter-ledger-disagreement-sweep` — one disagreement re-derived from the LIVE ledger

`pds-w29-pay-lb`, the merged-but-open one:

```
charter :4649  | `pds-w29-pay-lb` | … | #8644 | all 16 non-destroy lb-family sites paid; … |
$ gh pr view 8644 → state=MERGED mergedAt=2026-07-31T20:49:30Z merge=9a1811da47402ef5e…
$ git merge-base --is-ancestor 9a1811da4 origin/main → ANCESTOR
$ bp task get pds-w29-pay-lb → lifecycle_status=open, 12/14, updated 2026-07-31T21:09:40Z
```

Merged, and still open — the disagreement is **real and still live on 2026-08-04**. And it is
*correctly* open, which is the point:

```
$ git show --stat 9a1811da4 | grep hetzner_net_cmd_test.go
 internal/cli/hetzner_net_cmd_test.go     |  13 +
```

`c13` forbids editing exactly that file (PDS-D433: *"c13 is VIOLATED BY MERGED CODE"*). The charter
and the ledger do not disagree about the facts — they disagree about the **disposition**, and the
ledger is the one that is right.

**"One slice buys five" was a plan hypothesis from criterion text, not a measured cost.** It held
this time. A row whose re-derivation had failed to reproduce would have stayed open, and that would
have been the correct outcome, not a failure of the slice.

---

## 4. The six expensive rows — untouched, with what each still owes

Read back after this slice's writes (`bp task get`, 2026-08-04):

| row | state | the re-derivation still owed | cost class |
|---|---|---|---|
| `pds-w42-paper-op-principal-gate` | open 9/10 | the lead must write **his own probe** of the write bypass; the row calls itself the wave's highest-flip-risk slice | Elixir/LiveView probe |
| `pds-w42-liveview-authorization-column` | open 13/14 | re-derive the REACH partition over **322 handlers** | wide manual partition |
| `pds-w41-hop-arg-producer` | open 10/11 | re-derive the producer claim independently | Elixir |
| `pds-bl-w41-readonly-member-sees-published-only` | open 12/13 | independent re-derivation of the read-path restriction | Elixir/LiveView |
| `pds-w40-scim-groups-list-members` | open 8/9 | confirm not-N+1 **by reading the emitted SQL** — needs an instrumented live run | **most expensive in the set** |
| `pds-bl-status-only-residue-payment` | open 7/8 | self-flagged HIGH-FLIP-RISK, citing a judgment class that flipped on #9052 | judgment, high flip risk |

None was written to. Each remains `open` at exactly N−1.

---

## 5. The four misfiled rows — re-scoped, and why none of them is merge-gated

These four were swept into the "one criterion from done" class by arithmetic. Arithmetic is not
adjudication: **none of the four is waiting on a merge**, so none of them can be discharged by the
merge evidence that discharges the other thirteen.

### `pds-bl-charter-says-opaque-callers` — 0/1, and its own grep RUNS RED

Its sole criterion: *"`grep -n OPAQUE_CALLERS .claude/workflows/bp-pds-charter.md` returns only
lines that explicitly mark themselves as pre-rename history."* Run against `origin/main`'s charter:

```
$ git show origin/main:.claude/workflows/bp-pds-charter.md > /tmp/charter_main.md
$ grep -n OPAQUE_CALLERS /tmp/charter_main.md
4502:  result: `TOTAL=50 NON_LITERAL=2 KEYS=52 OPAQUE_CALLERS=0 KINDS=13`.
4530:  reds by name. But binding `volume/detach`'s KIND through a local variable left `OPAQUE_CALLERS = 0`:
4569:  NON_LITERAL=2 KEYS=52 OPAQUE_CALLERS=0`, unchanged).
4696:  `pay-net-dns` must verify BY MUTATION that its change cannot make `OPAQUE_CALLERS` fail open. Beyond
9117:  file makes `OPAQUE_CALLERS` read 0 VACUOUSLY (measured: `hetzner_dns_cmd.go` de-globbed → TOTAL=44,
10034: TOTAL=50 NON_LITERAL=2 KEYS=52 OPAQUE_CALLERS=0) and the full `internal/cli` package passes in
10047: re-run ON THE ARM-A TREE still reds BY NAME, with `OPAQUE_CALLERS` still reading 0 — **so the row's
10355: arms PASS) — only the KEY NAME moved, `OPAQUE_CALLERS` → `OPAQUE_ACTION_CALLERS`, so a stale grep
```

**8 hits; only `:10355` marks itself pre-rename. Seven do not.** The criterion is therefore
*genuinely unmet* — and what it needs is a **charter edit**, not a close. It cannot be stamped by
this slice: the charter is append-only this wave and lives behind PR #9509.

### `pds-bl-w41-component-gate-blast-radius` — 0/1, no PR exists

Its sole criterion demands each candidate component (`paper_field_block`, `tree_codelist_field`) be
judged **by run** — a denied principal persisting state through `phx-target`, or a printed
falsifiable reason why no write path exists — and explicitly forbids an aggregate count without a
proven write path per clause. That is a build slice with no PR. It is 0/1 because it has never been
worked, not because it is one merge from done.

### `pds-w25-round-parked` and `pds-w25-round-open` — 7/8 each, and their criteria say so verbatim

```
pds-w25-round-parked [7]: "[MERGE-GATED] The lead re-derives this shard from the pinned manifest and
  confirms the 27 rows and the 8 unchanged hashes (LEAD closes this criterion; this slice has no PR)."

pds-w25-round-open  [7]: "[MERGE-GATED] The lead re-derives this shard from the pinned manifest and
  confirms the 103 rows plus every free close by content (LEAD closes this criterion; this slice has
  no PR)."
```

The parenthetical **"this slice has no PR"** is verbatim in both. They carry the `[MERGE-GATED]`
marker over work that never had a merge — which is why the exact-string count of
`MERGE-GATED (the LEAD closes this)` over the seventeen is **13, not 15**. Their outstanding work is
a manifest re-derivation (27 rows + 8 hashes; 103 rows + every free close by content), not a merge.

---

## 6. Two inherited premises, refuted by measurement — do not repeat them

1. **No lapsed claims.** None of the seventeen carried a claim: `claimed_by`, `claim_epoch`,
   `claim_expires_at` and `worker` were all NULL. The CAS-on-epoch close path does not apply, so
   each row written to here had to be **claimed first** (`bp task claim <row> pds-w47-adjudicator`),
   then stamped on the returned epoch. That claim flips `lifecycle_status` to `in_progress` — an
   expected and recorded side effect of stamping, not a close.
2. **The exact-string count is 13, not 15.** The two `pds-w25-*` rows say *"this slice has no PR"*
   verbatim (§5).

---

## 7. What this slice wrote, and what it deliberately did not

**Wrote** — seven `bp task stamp --met` calls, each with re-derived evidence, each read back from
the store and confirmed byte-identical to what was sent:

| row | criterion | after |
|---|---|---|
| `pds-w45-bl-sweep-adjudication-frozen-blob` | 6 | 7/7, `in_progress` |
| `pds-w41-residue-lens-unrun` | 9 | 10/10, `in_progress` |
| `pds-w39-record-parity-shallow-guard` | 9 | 10/10, `in_progress` |
| `pds-w38-falsifier-promotion` | 9 | 10/10, `in_progress` |
| `pds-w34-owning-doc-amendment` | 11 | 12/12, `in_progress` |
| `pds-w38-verdict-freshness-arm` | 11 | 12/12, `in_progress` |
| `pds-w38-charter-ledger-disagreement-sweep` | 9 | 10/10, `in_progress` |

**Did not** — no `bp task close`, on any row. Seven rows now stand at N/N with every criterion
carrying quoted evidence, waiting on the lead's seal. That is the shape this epic asks for: the
measurement is done and recorded; the *disposition* is still a human ruling.

No product code was changed. The two mutations (the census blinding, parity mutant (b)) were run and
reverted in-worktree; `git status --porcelain` is empty apart from this file.

**Filed, not folded in.** Work discovered during the re-derivations and left visible on the board
rather than smuggled into a criterion:

| new row | why |
|---|---|
| `pds-bl-w47-census-doc-headroom-spent` | open, p2 — 792 of 800 B of the census doc's headroom are spent (§3.3); the tempting wrong fix is to raise the cap by a number nobody measured |
| `pds-bl-w47-stamp-tripwire-false-positive` | opened, then **adjudicated `disposition: closed` as a duplicate** of `pds-w27-bl-stamp-guard-substring-false-positive` (open 0/4) — its one contribution, the fresh 2026-08-04 reproduction, is written into its disposition reason for the wave-27 row to inherit. Its lifecycle cancel is left to the lead; this slice closes nothing |
