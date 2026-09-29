# Park-note recovery — the read surface ALREADY SHIPPED (dw27, pds-bl-recover-lost-park-notes, 2026-09-16)

Verdict, in one line: **the row's HARD CONSTRAINT is stale.** Recovery needs neither a production DB read
on guerrilla nor a new endpoint — `bp task events --payload` is a shipped, documented recovery channel, and
it answered every question this row asks. The numbers in the row body are also stale: the target set is
**88 rows**, not 130, and its prefix mix is not the one the row states.

## c0 — the recovery path: NEITHER DB read NOR new endpoint. It exists.

The row says `bp task events` "deliberately projects only id/event/doc_id/rev/at". That is true **only of
the default projection**. `bp task events --help` names the flag and its purpose verbatim:

> `--payload` … **THE RECOVERY CHANNEL for a clobbered note**: a `task.staged` event's
> `payload.staged.superseded_note` is the disposition_reason that stage displaced, and
> `payload.staged.note` the one it wrote.

Re-derivation, on the row that asserts the blocker:

    env -u BARKPARK_TOKEN bp task events pds-bl-recover-lost-park-notes --payload -o json

That returns `payload.staged.note` in full. Two further facts the flag exposes, neither of which the row
anticipates:

  * **A global feed exists** — omit the `doc_id` and `bp task events` streams every task event, keyset
    paged on `--since`. The whole backlog is **420,110 events over 841 pages of 500**, exhausted to
    `has_more: false`. Enumeration is a complete-denominator read, not a sample.
  * **`publish` events carry the ENTIRE document snapshot**, `disposition_reason` included. The event log
    is a far richer archive than "the note" — it is every published revision of every row's content.

**Recommendation for the api lane: build nothing.** The surface exists; the defect was a stale premise in
a task body, not a missing capability. The one thing worth owning is that the `--payload` flag is
discoverable ONLY from `bp task events --help` — no card and no contract names it. The cheap durable fix is
one line in `docs/contracts/document-graph-and-history.md` pointing at the flag as the recovery channel, so
the next lane does not re-derive this. A one-off DB read would have recovered the data once and taught
nobody; this path is already repeatable by anyone with a token.

## c3 — retention: NO time-based pruner, and the finding is dated, not proven-forever

`mutation_events` has **three** migrations (`20260413000002` create, `20260626130000` add source,
`20260902001100` add index). None deletes. Searches run against `api/lib`, `api/config`, `api/priv`,
`scripts/`, `deploy/`:

  * **CONTROL first** — `grep -rln "MutationEvent" api/lib` hits **17 files**, so the grep reaches the tree.
  * All **43** `Repo.delete_all` call sites enumerated by hand: none names `MutationEvent` or
    `mutation_events`. The only raw `DELETE FROM` statements (3, all `tenancy.ex`) run over the
    workspace-teardown table allowlist.
  * The full Oban crontab (static, plus all three plugin `oban_crontab/0` callbacks) was read entry by
    entry. Every GC in it is named after the table it sweeps — `login_tickets`, `idempotency_keys`,
    `preview_token_jti`, `paper_access_log`, playground workspaces, search crystals. **None is
    `mutation_events`.** This repo documents each sweeper at length in the crontab itself, so an
    undocumented one would be against the grain of the file.

**Two traps to name, because both look like a pruner and are not:**

  1. `{Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}` prunes **`oban_jobs`**, not `mutation_events`.
     It is the nearest-miss answer and it is wrong.
  2. `Barkpark.Tasks.Compactor` sounds like the pruner and is the opposite: it compacts
     `documents.content` and **emits** `MutationEvent` rows (`compactor.ex`, two insert sites). It also
     snapshots pre-compaction content into `revisions` reversibly.

The **one** path that deletes `mutation_events` rows is workspace deletion: `Tenancy.delete_workspace/1`
lists `mutation_events` in "class 2 — rows that are just rows … can ride SQL CASCADE". That is a
destructive whole-workspace operation, not a clock.

Corroborating measurement from the repo's own code: `tenancy/workspace_bundle.ex` sizes `mutation_events`
on guerrilla at **~1.31 GB / 478 MB** and calls it the largest table it exports. That is the shape of a
table nothing has ever pruned.

**The honest form of the verdict:** *no pruner found in the tree, with these searches, which is not the
same as proving none exists.* What would prove it: (a) `SELECT min(inserted_at), min(id) FROM
mutation_events` on guerrilla — if the floor is the table's creation date (2026-04-13) nothing has ever
been deleted; and (b) `\d+ mutation_events` plus a `pg_cron` / `cron.job` read on the box, since a
DBA-side job would be invisible to every grep above. Both need prod access this lane does not have.

**Consequence for priority:** the recovery is **not** on a clock. The window is "until someone deletes the
workspace". c1 is not urgent on retention grounds — which is the opposite of what the row feared.

## c2 — latest-wins, and the measured loss is ZERO

The rule: **latest-wins, ordered by `mutation_events.id`** (not `at` — id is the monotonic keyset the feed
itself pages on, and two events can share a timestamp).

This was decided by measurement, not by preference. Of the 88 rows carrying a recoverable note, **78 are
multi-note** — which looks exactly like the hazard the row warns about. But **0 of those 78 carry a
distinct note text.** The duplication has a mechanical cause: `TtlSweeper` lapses the engagement and its
`task.engagement_lapsed` payload re-emits the *same* `engagement.note` the preceding `task.staged` wrote.
The second "note" is an echo of the first, not a later overwrite.

**What latest-wins loses: nothing, on this target set, measured.** Its residual risk is that a future
multi-stage row genuinely re-notes; the dataset below therefore carries `all_notes` in full alongside
`recovered_note`, so the choice is reversible without re-reading the feed. `superseded_note` — the field
that would carry a displaced reason — is present on **0** events across the target set, because all but
23 staged events on these rows predate the triple-bearing stage shape.

## c1 — enumerated from the server; the restore is deliberately NOT executed

Enumeration is now done and is a complete-denominator read:

    tooling/grip/ledger/pds-r20-recoverable-park-notes-2026-09-16.json   # 88 rows

Method: exhaust the global feed for `task.staged` + `task.engagement_lapsed` (2,789 + 385 events over
2,025 distinct doc_ids), intersect with the live corpus from `bp task ls --all -o json` (**9,426 rows**, no
truncation warning), keep rows whose live `content.disposition_reason` is absent, then pull
`--payload` per candidate.

**The row's arithmetic does not survive the read.** Measured today:

| | row body claims | measured |
|---|---|---|
| target rows | 130 | **143** candidates, of which **88** actually carry a note |
| `tgw*` | 45 | **5** |
| `connectors-*` | 12 | **12** |
| `task-*` | 15 | **16** |
| other prefixes | 0 (unmentioned) | **55** |

The `tgw*` gap is not a contradiction of PDS-D309 — it is remediation that has already happened. **72 of
160** `tgw*` rows now carry a durable `disposition_reason`; only 5 still lack one. The row's own body is a
snapshot of 2026-07-28 and has since been overtaken.

Also stale: the row states "ZERO still carry `content.engagement`". Measured now: **3**.

**The restore was NOT executed, deliberately.** Writing 88 rows that a live six-lane campaign holds would
409 their holders' closes. The dataset above is the handoff: it is executable input, not a written finding
that fires by itself.

## PDS-D298 — the refutation is CONFIRMED, and it is not this row's to make

D298's factual verdict is already **refuted and superseded on main** by **PDS-D309**
(`grep -n 'PDS-D309 —' .claude/workflows/bp-pds-charter.md`), which proves the deleter is our own `TtlSweeper` at a measured **15m00.97s** and withdraws D298's wave-10
verdict while reaffirming its proof standard. D309 also states the "exactly 45 `tgw*` … all 45 contain a
`REACTIVATE:` trigger" figure. So this row does not need to establish the refutation; it inherits it.

Verified independently: `ttl_sweeper.ex` deletes **exactly one key by name** (`content.engagement`) and
**emits** a `task.engagement_lapsed` MutationEvent. It never deletes from `mutation_events`. The mechanism
D309 describes is the mechanism in the code.

Both charter D-numbering styles were checked (`### ` headings and the `- **PDS-D` list); D298 appears only
in the list style.

## One method note

My first extraction read `payload.engagement_lapsed.note` and scored 55 of 143 rows as "no recoverable
note". That was **my key being wrong**, not an absence: the note is nested one level deeper at
`payload.engagement_lapsed.engagement.note`. Printing the actual payload key set — rather than reading the
empty result — caught it. An absence is never caught by inspection.
