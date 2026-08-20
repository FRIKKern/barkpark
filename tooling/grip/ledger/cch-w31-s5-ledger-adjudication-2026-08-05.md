# cch-w31 S5 — ledger adjudication: re-derivation recipes (2026-08-05)

Slice `cch-w31-s5-ledger-adjudication`. Every verdict below was re-derived at
`origin/main 467f7e283` inside worktree `wf_f10ca12d-5bd-34`, which is branched from it.
Nothing here was taken from an inherited brief without a command behind it.

**No repo behaviour changed in this slice.** The only committed file is this one. Every other
write landed on the Barkpark ledger, and each of those was read back from the server before the
next one was issued — a printed `rev` is not persistence.

## 0. The state before anything was touched

    bp task get cloud-console-hardening-epic -o json | python3 -c "import json,sys;d=json.load(sys.stdin);ch=d.get('children') or [];op=[c for c in ch if c['lifecycle_status']=='open'];print('children',len(ch),'open',len(op),'open drafts',len([c for c in op if c['doc_id'].startswith('drafts.')]))"
    # children 349 open 96 open drafts 3

    # criteria-less open rows — the rows no met/total census can see, in EITHER direction
    # (same JSON, filtering children where criteria_progress is absent or total == 0)
    # BEFORE: 2
    #   cch-w24-bl-word-break-alias-has-no-ruling
    #   cch-w24-bl-account-menu-lines-nowrap-clipped-at-every-width

## 1. `cch-w30-bl-preview-fixture-nine-event-vocabulary` — CLOSED (1/1, bookkeeping)

The row was already stamped met; its stated close condition was "the LEAD closes this row when
S1 merges". S1 merged.

    git merge-base --is-ancestor 9d56c0406 origin/main && echo ancestor
    # ancestor

    git show origin/main:cloud/priv/static/__preview__/scenarios.mjs | sed -n '1629,1632p'
    # const NOTIF_EVENT_KEYS = [
    #   "provision_succeeded", "provision_failed", "deployment_failed",
    #   "agent_reachable", "agent_unreachable", "subscription_past_due",
    # ];

    git show origin/main:cloud/priv/static/__preview__/scenarios.mjs | grep -n 'deployment_succeeded'
    # 1623:// SIX, NOT NINE (wave 30 S1). `deployment_succeeded`, `member_invited` and
    # (the header comment only — no fixture seeds a route or boolean for a dropped column)

    cd cloud/priv/static && node --test __app.test.mjs
    # # tests 826 / # pass 826 / # fail 0

    bp task get cch-w30-bl-preview-fixture-nine-event-vocabulary -o json
    # lifecycle done  prog {'met': 1, 'total': 1}

## 2. `cch-w29-bl-event-email-scrub-comment-stale` — STAMPED FIRST, then CLOSED (2/2)

Both criteria were substantively paid by `40097d1d2` (#9463) and both still read `met:false`
with **empty** evidence. Closing first would have destroyed the receipts, so both were stamped
and read back before the seal.

    git merge-base --is-ancestor 40097d1d2 origin/main && echo ancestor
    # ancestor

    git show 40097d1d2 --unified=0 -- cloud/lib/barkpark_cloud/notifications/event_email.ex | grep -E '^[-+]'
    # -  # `:detail` in the email channel; `Notifications.Render.render/2` never reads it,
    # -  # so chat is not a leak channel and is deliberately not touched here.
    # +  # `:detail` in the email channel.
    # +  #
    # +  # WAVE 29 CORRECTION: `Notifications.Render.render/2` DOES read `:detail` now — …
    # every changed line is a comment line: the edit cannot change behaviour

    git show origin/main:cloud/lib/barkpark_cloud/notifications/render.ex | sed -n '86,94p'
    # cause/1 reads :detail under both key shapes and routes it through humanize/1
    # (moduledoc :19-29 — "humanize/1 is classify() |> scrub()")

    gh pr view 9463 --json statusCheckRollup
    # "Cloud control-plane (test) (27.0, 1.18.1)" SUCCESS · "Cloud gate" SUCCESS · "Elixir gate" SUCCESS

    bp task get cch-w29-bl-event-email-scrub-comment-stale -o json
    # before the close: prog {'met': 2, 'total': 2}, evidence 768 and 852 bytes
    # after  the close: lifecycle done  prog {'met': 2, 'total': 2}

**Not re-run locally.** `cd cloud && CC=clang MIX_ENV=test mix test test/barkpark_cloud/notifications/`
aborts in this worktree with `the dependency is not available` for every hex dep. A comment-only
diff plus a green required gate is the stronger evidence anyway, and the stamp says so rather
than implying a run that did not happen.

## 3. `cch-w29-bl-token-expiring-toggle-default-on-fires-nothing` — CLOSED (4/4)

Remedy = **removal**, end to end. Each dropped toggle carries its OWN verdict; a blanket answer
would not have satisfied criterion 1.

    sed -n '1,50p' cloud/priv/repo/migrations/20260804123000_drop_producerless_notification_events.exs
    # token_expiring    → SAFETY verdict: dispatch_event/3 fans to team_member_emails/1 (EVERY
    #                     member) while a user_tokens row belongs to ONE user, so the obvious
    #                     producer would have converted a missing alert into a cross-member
    #                     credential disclosure
    # member_invited    → REDUNDANCY with Transactional.deliver_invite/1
    # deployment_succeeded → the settle_live/2 verdict (may legally re-report live -> live)
    # up/0 drops all three columns; down/0 restores names, types and defaults

MUTATION, run first-hand (this is the guard that can lose):

    # re-add ["token_expiring", "API token expiring"] to NOTIF_EVENTS in cloud/priv/static/app.js
    cd cloud/priv/static && node --test __app.test.mjs
    # not ok 755 - cch-w30-s1: the matrix offers SIX toggles — the three producerless ones are gone
    # not ok 758 - cch-w30-s1 census ARM (a): every event the console OFFERS has a producer in cloud/lib
    # # tests 826 / # pass 824 / # fail 2
    git checkout -- cloud/priv/static/app.js   # reverted; git status clean

The census counts all four producer idioms with per-idiom blindness floors, including the one a
naive census misses:

    sed -n '12358,12363p' cloud/priv/static/__app.test.mjs
    # dispatch_event (floor 2) · dispatch_site_event (floor 1) ·
    # dispatch_barkpark_event (floor 2) · enqueue_channel (floor 1, the string-shaped idiom)

    bp task get cch-w29-bl-token-expiring-toggle-default-on-fires-nothing -o json
    # lifecycle done  prog {'met': 4, 'total': 4}

Criterion 4 is MERGE-GATED and the CLI **refused** the plain stamp —

    bp task stamp … --criterion 3 --met …
    # {"error":{"code":"merge_gated_criterion","message":"refusing to stamp a MERGE-GATED
    #  criterion met: … that row is the lead's to close (a builder flipping it fabricates a done
    #  before the PR exists). Pass --merge-gated to override only if you are the lead closing the gate."}}

— which is a guard doing its job. It was flipped only with `--merge-gated`, and only because
#9517 is genuinely merged with all four required contexts SUCCESS.

## 4. `cch-w27-bl-deployment-failed-toggle-fires-nothing` — CLOSED (6/6), **NOT RETITLED**

Policy = PRODUCE for `deployment_failed`, REMOVE for the other three.

    sed -n '6650,6661p' cloud/lib/barkpark_cloud/registry.ex
    # defp maybe_dispatch_deployment_failed("failed", _updated), do: :ok        <- the EDGE guard
    # defp maybe_dispatch_deployment_failed(_prior, %Deployment{status: "failed"} = updated),
    #   do: dispatch_deployment_failed(updated.site_id, updated.failure_reason)

    grep -n 'test "' cloud/test/barkpark_cloud/notifications/deployment_failed_dispatch_test.exs
    # 8 producer-level tests: fenced writer · reaper JOINED pass · reaper PLAIN pass ·
    # push webhook · rollback sends nothing · failed -> failed re-drive sends no second alert ·
    # mass reap caps and LOGS the suppressed · the alert names the SITE and leads with the class
    # none is a hand-built EventEmail.build/4 fixture — they enter through the real sites

    sed -n '52,56p' cloud/lib/barkpark_cloud/notifications/email_settings.ex   # @events = the six
    sed -n '66,71p' cloud/lib/barkpark_cloud/notifications.ex
    # @chat_events = Enum.map(EmailSettings.events(), &Atom.to_string/1) ++ ["test"]
    # it DERIVES from the schema — the two halves cannot drift apart in a future edit
    sed -n '2725,2732p' cloud/priv/static/app.js                               # NOTIF_EVENTS = the same six

**Its headline is now refuted, and that is correct.** The row is titled *"…and nothing can ever
send them"*; `:deployment_failed` has had a producer since wave 28 S6. A row whose defect was
repaired CLOSES — retitling it would be the fabrication. The close reason opens with
`NOT RETITLED, DELIBERATELY` and states that the headline describes the **repaired** defect, so a
future title-keyed sweep reads that sentence instead of resurrecting the row.

    bp task get cch-w27-bl-deployment-failed-toggle-fires-nothing -o json
    # lifecycle done  prog {'met': 6, 'total': 6}  title UNCHANGED

Second mutation, **not re-run here**: collapsing the `("failed", _updated), do: :ok` edge clause
takes `deployment_failed_dispatch_test.exs` from 8/0 to 8 tests, 1 failure (wave-31 Decide-phase
run). This worktree has no cloud deps, so it was not re-driven — but it is structurally
checkable: collapsing that clause routes a `failed -> failed` re-drive into the dispatching
clause, and the file carries exactly the test that must then red.

## 5. The three draft twins — DISCARDED, never closed, **worth zero**

All three read live `open` while their published twins read `done`. Publishing one would
overwrite a done row with a `met:false` one; the API may refuse with `criteria_regression`, which
is the guard working.

    bp doc discard-draft task cch-w22-s2-site-row-name-and-host-bounded --yes   # rev ce3ae230a6c8ac3666c2a4530f7055be
    bp doc discard-draft task cch-w26-bl-deploy-row-siblings-unwrapped  --yes   # rev 19b50e3b2a5f1b6dbad84d0dfb32eaed
    bp doc discard-draft task task-1daff7bc1bf46ceb                     --yes   # rev 2ce5ab34ed82e95bbb903c32d4c559c5

Per charter **D105 / D190 / D347** these three are worth **ZERO** against standing law 0. They
were never real open work; they were shadows of rows already done. Removing them corrects an
instrument, it does not shrink a backlog, and this write-up does not count them as one.

**The draft population is FOUR, not three.** Read-back after the discards:

    # drafts rows: [('drafts.task-c64f2a37d7f97bd8', 'cancelled')]
    # open drafts 0

`drafts.task-c64f2a37d7f97bd8` is cancelled on both sides and sits outside the open set. **Any
future draft census must key on the `drafts.` PREFIX plus lifecycle, never on the three literal
ids** this row names — keyed on the literals it would pass while blind to a fourth.

## 6. The two criteria-less rows — ruled BY READING: give criteria, do not close

Neither is paid. Closing either would be exactly the fabrication this epic exists to remove, so
both were made **visible to a census** instead — 5 criteria each, published.

`cch-w24-bl-word-break-alias-has-no-ruling` — the ambiguity is live at `origin/main`:

    grep -c 'word-break' cloud/priv/static/app.css   # 20
    grep -c 'break-all'  cloud/priv/static/app.css   # 8

D229 still says `break-word` "leaves min-content intact" without naming the property, which is
true of `overflow-wrap: break-word` and false of `word-break: break-word`. Its new criteria
require the counts to be **derived at the tree under test, never quoted from here**, forbid a
mechanical conversion, and demand a guard that can lose.

`cch-w24-bl-account-menu-lines-nowrap-clipped-at-every-width` — reading DID advance it:

    sed -n '6098,6101p' cloud/priv/static/app.css
    # .am-line { font-size: 12px; … overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    grep -n 'am-line' cloud/priv/static/app.js
    # 757:  '<div class="am-line">' + esc(accountIdentityLine(model)) + "</div>"

So an ellipsis **cue does render** — the row's own honest limit said that could make this correct
truncation rather than a defect — but the markup carries **no `title` attribute**, so the full
value has no other reach. That is not enough to close it, and it is more than the row knew. Both
findings are written into its new criteria, which still demand the driven measurement at 320/600/900.

    bp task get cch-w24-bl-word-break-alias-has-no-ruling -o json
    # lifecycle open  status published  prog {'met': 0, 'total': 5}
    bp task get cch-w24-bl-account-menu-lines-nowrap-clipped-at-every-width -o json
    # lifecycle open  status published  prog {'met': 0, 'total': 5}

## 7. The honest denominator, re-derived after every write

    bp task get cloud-console-hardening-epic -o json | python3 -c "…same one-liner as §0…"
    # AFTER:  children 346 open 89 open drafts 0
    # BEFORE: children 349 open 96 open drafts 3

Re-run four minutes later, at commit time, it read `children 347 open 90 open drafts 0` — a
sibling slice filed a row mid-run. The `open drafts 0` half is the stable part; the other two
move under you, which is the whole reason §7 says derive rather than quote.

Arithmetic, stated rather than implied:

| | before | after |
|---|---|---|
| children | 349 | 346 |
| open (raw) | 96 | 89 |
| open `drafts.*` phantoms | 3 | 0 |
| **real open rows** (raw open minus phantoms) | **93** | **89** |
| open rows invisible to a met/total census | 2 | 0 |

**Four real closes.** 93 → 89. The three discards move the phantom count 3 → 0 and are **not**
part of that four — they were never real open rows, so they cannot be counted as a row-shrink
against standing law 0 (D105/D190/D347). The raw `open` figure moved further than the real one
precisely because it had been counting shadows; that difference is the instrument correcting, not
work disappearing.

Two more figures worth stating so a later reader does not misread the arithmetic:

* The epic **grew during this wave** — wave 30 Decide read 78 open, the wave-31 brief was cut at
  93 real open, and §0 measured 93 at claim time. Other wave-31 slices are filing rows while this
  one runs, so a census taken at a different minute will not match; re-derive, never quote.
* `cch-w30-bl-discard-three-stranded-draft-twins` is parented to `cch-instruments-epic`, **not**
  to this epic. Closing it does not shrink `cloud-console-hardening-epic` by one, and this row
  does not count it.

## 8. What this slice deliberately did NOT do

* Did not retitle a repaired row (see §4).
* Did not close either criteria-less row (see §6) — neither is paid.
* Did not re-run the Elixir mutations (no cloud deps in this worktree); both stamps say so
  in the evidence rather than implying a run.
* Did not publish any draft twin — `discard-draft` only (see §5).
