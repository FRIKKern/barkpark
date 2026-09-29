<!-- doc-tier: cold | canonical-for: pds-w33-write-receipt-buckets | budget: 6000tok -->
# PDS w33 follow-on — the write receipts, bucketed per site

**HISTORICAL RECORD, 2026-09-16.** Every figure below was RE-DERIVED at base sha
`d8bd23c1d` by running `elixir scripts/pds-elixir-receipt-census.exs --sites` in a clean
worktree off `origin/main`. Nothing here is transcribed from the filing row, from
PDS-D448, or from the owning doc. The counts the row carried are refuted below by name.
The owning doc is `docs/decisions/success-claim-census.md`; this file is its per-site
appendix, and the doc carries only the totals and the ruling.

**AMENDMENT, 2026-09-18 (task-477972989335da51).** The `d8bd23c1d` figures below are left
exactly as they were re-derived; this note records what moved after them, because a
HISTORICAL RECORD is amended, never re-typed. Three of the sites this file names as
undeclared have since been ruled on IN THE CODE (#18899, merge sha `16606806`) and
REGISTERED in the census's `@declared` (this task):

| site | fn | was | now |
|---|---|---|---|
| `search_controller.ex` | `delete_search_synonym/2` | CATCH-ALL-TO-SUCCESS, undeclared — a live defect in §"only 2 sites are live defects" below | DECLARED-HONEST, registered; basis token `NO FAILURE REACHES THIS RECEIPT` |
| `v1/media_controller.ex` | `delete_search_synonym/2` | CATCH-ALL-TO-SUCCESS, undeclared — the other of those 2 | DECLARED-HONEST, registered; same token, its own span |
| `auth_controller.ex` | `request_magic_link/2` | PURE ECHO — DECLARED, with a **named exposure** and no row of its own (see the Corner 2 table) | the exposure now has its own ruling and its own register row; basis token `WHY IT MUST MERGE` |

The class line the census prints moved with it: `CATCH-ALL-TO-SUCCESS FINDINGS  2
undeclared of 3 fired` → `0 undeclared of 3 fired`, and the `@declared` register went 5
rows → 8. **The count is not the point and a green census alone does not discharge this.**
A register row that silences a finding while the api-side ruling is absent is the exact
inversion the register exists to catch, so each of the three rows is anchored on a token
that occurs ONLY inside the block #18899 added: deleting any one of those blocks reds
`DECLARED-BASIS-INTACT` at rc 1 and the fail line names that site. Proved by deletion,
one site at a time, on the filing branch — and the fourth CATCH-ALL row
(`github_webhook_controller.ex:100`, declared since wave 35) stayed SUPPRESSED and
unnamed through all three.

The §"only 2 sites are live defects" argument below is therefore SPENT, not refuted: it
was the correct reading of the tree at `d8bd23c1d`, and the repair order it issued has
been filled. The ruling it supports (PDS-D454 — no number-shaped gate over this
population) is untouched by that.

## The population, and why it is 81 and not 64

`scripts/pds-elixir-receipt-census.exs` prints its own depth sweep. At base sha
`d8bd23c1d`:

| depth | write | read | unrouted | POST-READ |
|---|---|---|---|---|
| 6 (`@evidence_depth`, the shipping classification) | 57 | 29 | 14 | 21 |
| 10 (`@route_depth`, the measured closure — flat at 12/14/16) | 81 | 16 | 3 | 54 |

**POPULATION = 81** — the write-routed set at the depth where the route relation CLOSES.
A receipt whose write is only reachable at depth 9 still claims a state change; excluding
it would make the population a property of a knob. **EVIDENCE stays at depth 6**: the
doc's own finding is that POST-READ above 6 is a compliance dial (7 sites launder in at
depth 7 alone, six of them certified by a webhook-failure counter). So the POST-READ
bucket below is the 21 admissible at depth 6, never the 54 the dial prints at 10.

The depth-10 per-site list was taken with a SCRATCH COPY of the census
(`@evidence_depth 6 -> 10`, one line, outside the repo). CONTROL: that copy reproduced
`write 81 / read 16 / unrouted 3` exactly — the figures the unmodified script derives for
depth 10 in its own sweep table — so it is measuring the same population. It exits 1 on
`D448-DRIFT-REFUSES`, correctly, because moving the lens is a drift.

**The row's `64` is refuted as a current figure and upheld as a FLOOR.** PDS-D448's
hand-followed 64/17/10 is not this lens at any depth: today write reads 57 at depth 6,
64 at depth 8, 81 at closure. 81 >= 64, so the floor holds; the integer does not.

## Buckets — 49 classified + 32 UNCLASSIFIED == 81

| bucket | n | basis |
|---|---|---|
| DECLARED-HONEST | 24 | the receipt asserts only what it measured, or NAMES what it did not |
| POST-READ (admissible @6, not proven) | 21 | census ARM 1: `select:` scoped to the updated query |
| UNCLASSIFIED | 32 | evidence held, no verdict taken — every one named below |
| CATCH-ALL-TO-SUCCESS | 2 | receipt emitted inside a failure-discarding clause |
| PURE ECHO — DECLARED | 2 | keyed on the verb, deliberately, for anti-enumeration |
| CAS-CONFIRMED ECHO | 0 | none proven; not guessed |
| WRONG-ROW | 0 | needs row identity, not the verb — this pass took no dataflow |
| DISCARDED-POST-READ | 0 | needs dataflow from the read to the printed value |

`24 + 21 + 32 + 2 + 2 + 0 + 0 + 0 = 81`. The partition is by SITE KEY
(`file:line`), each site appearing exactly once.

## The taxonomy name the row carried does not exist in the instrument

The row names **UNREACHABLE-ERROR** and says it has 3 members. The census emits no such
shape. What it emits is **CATCH-ALL-TO-SUCCESS**, and it fires **3** times today —
2 undeclared findings plus 1 declared/suppressed. The count re-derives; the name does
not. Recorded rather than silently mapped.

## Corner 1 — `github_webhook_controller.ex`: 17 sites, 14 DECLARED-HONEST

The row said 15. Re-derived: **17** (11 unrouted @6 + 6 read @6; all 17 write-routed at
closure). **This is the population's best DECLARED-HONEST exemplar and it is not paid.**

`ok: true` on this controller means *"the delivery was verified and the named outcome
happened"*. Every clause carries an explicit discriminator (`ignored:`, `dropped:`,
`detached:`, `refused:`+`outcome:`, `reconciled:`), every genuine failure has its own 5xx
clause, and the case is closed so a new tag CaseClauseErrors rather than passing as
success. Demanding a post-condition read here would be the WRONG law: **there is no state
to read back.** A no-op that wrote nothing, read back, still shows nothing — the read
would be theatre, and the receipt would go from naming its outcome to asserting one.

| line | receipt | verdict |
|---|---|---|
| 99 | `ok: true` (ping) | DECLARED-HONEST — install handshake; claims nothing |
| 100 | `ok: true, ignored: "event"` | DECLARED-HONEST — catch-all over event NAMES with a discriminator; declared in the register; failures are 5xx one frame down |
| 124 | `ok: true, detached: true` | **UNCLASSIFIED** — relays `{:ok, :detached, doc_id}`; the tag is the callee's, not a local verb, so NOT pure echo — but proving the callee measured needs its dataflow, not taken |
| 128 | `ok: true, dropped: true` | DECLARED-HONEST — deliberate bot-echo no-op |
| 133 | `ok: true, ignored: "action"` | DECLARED-HONEST — named no-op |
| 165 | `ok: true, ingested: true, outcome: born\|exists` | **UNCLASSIFIED** — same relayed-tag shape as 124; `outcome` already names WHICH ingest, which is the repair of an earlier discarded tag |
| 170 | `ok: true, dropped: true` | DECLARED-HONEST |
| 174 | `ok: true, ignored: "action"` | DECLARED-HONEST |
| 186 | `ok: true, refused: true, outcome: "dedup_refused", recorded: <bool>` | DECLARED-HONEST — `recorded` is MEASURED: `intake.ex:299-300` returns `:dedup_recorded` on `:ok` and `:dedup_unrecorded` on `:error` from the dead-letter write |
| 202 | `... outcome: "vetoed", recorded: false` | DECLARED-HONEST — **the strongest exemplar in the population: a receipt that names the absence of a write.** `intake.ex:249-253`: this arm writes nothing by construction |
| 212 | `... outcome: "unspecified"` | DECLARED-HONEST — legacy 2-tuple; refuses to fabricate a `recorded` boolean nobody measured |
| 242 | `ok: true, stamped: true, task:, criteria:` | **UNCLASSIFIED** — relayed tag + indices; claims criteria flipped |
| 252 | `ok: true, reconciled: "unflagged_merge_gates", criteria:` | DECLARED-HONEST — a REPORTED no-write that NAMES the criteria rather than counting them |
| 261 | `ok: true, reconciled: <tag>` | DECLARED-HONEST — `already_stamped` / `no_marker` / `no_guardable_marker`, all named no-writes |
| 267 | `ok: true, ignored: "ambiguous_trailer", tasks:` | DECLARED-HONEST — refused, not guessed |
| 272 | `ok: true, ignored: "unknown_task", task:` | DECLARED-HONEST |
| 276 | `ok: true, ignored: <tag>` | DECLARED-HONEST |

**A FINDING FOR THE OWNING DOC.** Its "The 12 unrouted sites" section calls `gwc:161` the
**one open MIXED defect** — one receipt covering both a best-effort dead-letter write and
a `{:halted, _}` veto that wrote nothing. **That defect is REPAIRED on `main` at
`d8bd23c1d`** and the doc still carries it as open. `intake.ex:134` now types the refusal
as `:dedup_recorded | :dedup_unrecorded | :vetoed`, and the controller gives each its own
clause (186 / 202 / 212). The line has also moved: 161 -> 186.

## Corner 2 — `auth_controller.ex`: 12 sites (the row said 11), 10 DECLARED-HONEST

Every one sits in a clause gated on the write's own return tag, with a distinct error
arm — the D313 test passes: the printed sentence changes when the result says the
opposite.

| line | fn | verdict |
|---|---|---|
| 191 | `erase/2` | DECLARED-HONEST — `erased: summary` is the erase's own measured output |
| 230 | `change_password/2` | DECLARED-HONEST — gated on `{:ok, _}`; `{:error, :invalid_current}` has its own arm |
| 447 | `revoke_session/2` | DECLARED-HONEST — gated; NOTE `current:` is request-derived, not state-derived |
| 479, 480 | `logout/2` | DECLARED-HONEST — `revoked` is the measured count; the in-file comment records the repair of the discarded-count version where "a live session died" and "nothing to revoke" were byte-identical |
| 508 | `verify_email/2` | DECLARED-HONEST — gated on `{:ok, _user}` |
| 534 | `request_reset/2` | **PURE ECHO — DECLARED.** `ok: true` prints unconditionally, on purpose: any outcome-revealing receipt is an account-enumeration oracle. Declared in the register. Honest BY DESIGN, and it is still a verb-keyed sentence — both halves are stated |
| 562 | `request_magic_link/2` | **PURE ECHO — DECLARED**, same rationale. **Named exposure:** the `{:error, changeset}` arm records a `:dispatch_crashed` withhold and then falls through to the SAME `ok: true` — a token-mint failure is indistinguishable to the caller. Deliberate, and worth a separate row if the enumeration risk is ever priced |
| 616 | `reset/2` | DECLARED-HONEST — `sessionsRevoked` is a measured count |
| 681 | `mfa_verify/2` | DECLARED-HONEST — `recovery_codes` are produced by the write |
| 720 | `mfa_disable/2` | DECLARED-HONEST — gated; `else` is 403 |
| 753 | `mfa_step_up/2` | DECLARED-HONEST — gated |

## Corner 3 — `bulldocs_ingest_controller.ex`: 12 sites (the row said 9)

3 are POST-READ admissible at depth 6 (`:393`, `:1422`, `:1503` — all via
`BlockOps.fenced_paper_update/4`, `select:` scoped to the updated query). The other 9
(`:374 :565 :851 :992 :1079 :1207 :1283 :1331 :1652`) are **UNCLASSIFIED**: scanned,
write-routed, no verdict taken. This is the named remainder, not a silence.

## The 32 UNCLASSIFIED, named in full

3 in `github_webhook_controller.ex` (`:124 :165 :242`, relayed-tag, above) plus these 29:

```
app_token_controller.ex:291            bulldocs_form_controller.ex:53
bulldocs_form_controller.ex:57         bulldocs_ingest_controller.ex:374
bulldocs_ingest_controller.ex:565      bulldocs_ingest_controller.ex:851
bulldocs_ingest_controller.ex:992      bulldocs_ingest_controller.ex:1079
bulldocs_ingest_controller.ex:1207     bulldocs_ingest_controller.ex:1283
bulldocs_ingest_controller.ex:1331     bulldocs_ingest_controller.ex:1652
bulldocs_intents_controller.ex:79      github_status_controller.ex:92
oidc_controller.ex:108                 plugin_settings_controller.ex:83
pulse_controller.ex:59                 saml_controller.ex:93
search_controller.ex:403               search_controller.ex:406
secret_controller.ex:123               social_controller.ex:80
tickets_controller.ex:263              v1/media_controller.ex:264
v1/media_controller.ex:267             webauthn_controller.ex:64
webauthn_controller.ex:179             webauthn_controller.ex:233
plugins/sheets/web/import_controller.ex:67
```

Three of those 29 (`bulldocs_form_controller.ex:53`, `:57`, `github_status_controller.ex:92`)
are READ-routed at depth 6 and only join the write population at closure — the budget,
not the code. `tickets_controller.ex:263` is write-routed ONLY through an AMBIGUOUS CALLER
SET (4 of 6 callers write); the census names it as such and so does this table.

## Are the 10 previously-unrouted sites resolved? (the floor, re-derived)

The row inherited **10**. The owning doc carries **12**, dated `4ecd652ee`. Neither is
today's figure.

- **Unrouted at depth 6: 14.** Not 10, not 12.
- **11 of those 14 route at depth 10** — all `github_webhook_controller.ex`
  (`:99 :100 :124 :128 :133 :165 :170 :174 :186 :202 :212`). RESOLVED: the depth budget,
  not the code. They are in the 81 and bucketed above.
- **3 are STILL unrouted at closure** and are the residual finding, by name:
  `search_controller.ex:232` (reindex -> `Oban.insert()`), `self_update_controller.ex:25`
  (GenServer + `Port.open`), `site_deploy_controller.ex:132` (deploy runner, status via
  ETS). The doc's own prose already judges all three honest post-reads via non-`Repo`
  state. **They are NOT in the 81** — a site that reaches no write is not a write receipt.
- CONTROL against a broken query: the same extraction that returns 3 unrouted returns
  81 write and 16 read from the same file, summing to the emitted 100 the census
  partitions independently (`EMITTERS-PARTITION`, `CLASSIFICATION-TOTAL`). A zero here
  would not have summed.

**One line number in the row does not resolve to what the row says it is.** The row
names the POST-READ bucket by 8 sites — `writer.ex:1063`, `block_ops.ex:958`,
`auth.ex:148`, `webhooks.ex:487`, `access.ex:206`, `cycle_fleet.ex:652/2359/2379`. Those
are **not receipt sites**; they are the *evidence* frames — the callees whose `select:`
the census reads. The POST-READ bucket today holds **21 sites, none of them in those
files**: they are in `bulldocs_ingest_controller.ex` (3), `github_adopt_controller.ex` (2)
and `tasks_controller.ex` (16). The row conflated the evidence with the receipt.

## The gate ruling

**NO GATE.** Recorded as the outcome the owning doc's standing rule admits, not as a
failure to decide. The evidence:

1. **The largest bucket is UNCLASSIFIED (32 of 81, 39.5%).** A gate calibrated against a
   population that is two-fifths unjudged pins the lens, not the law.
2. **The second-largest is DECLARED-HONEST (24 of 81, 29.6%)** — sites where asserting a
   post-condition would be the wrong law. Any floor-shaped guard over "receipts backed by
   a read" would red on 24 correct receipts, and the only way to stay green is to write
   reads that measure nothing. A gate that pays for theatre is worse than no gate.
3. **Only 2 sites are live defects** (`search_controller.ex:381`,
   `v1/media_controller.ex:223` — CATCH-ALL-TO-SUCCESS, undeclared). Two sites is a
   REPAIR ORDER, not a gate population — the same ruling shell got at 2 sites, for the
   same reason.
4. **The one number a gate could key on moves with a knob.** write is 57/64/81 at depths
   6/8/10 on one unchanged tree. PDS-D454 already named a number-shaped guard over these
   integers as the defect this epic keeps filing.

What ships instead is what already ships: the census's own INTEGRITY arms, which CAN go
red (`CLASSIFICATION-TOTAL`, `ROUTED-POPULATION-COMPLETE`, `D448-DRIFT-REFUSES`), plus
these buckets as the calibration the next wave measures against.
