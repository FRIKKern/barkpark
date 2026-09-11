# cch-w65 — a task document has no author field, and the cancel census has two honest derivations

Packet date: **2026-09-11** (clock read `date -u` = 2026-09-11T08:26:13Z).
Row: `cch-w65-bl-a-task-document-has-no-author-field`.
Base: origin/main `4612977fc3628b39e98d7177e2f11155c00835a6`.
Every file:line below is read from that tree.

Every integer in this packet is either (a) quoted from the charter with its
date, (b) a count of lines I read in the named file, or (c) attributed to a
probe comment written by someone else and labelled as such. Nothing here is a
live store measurement — I ran no query against the ledger.

---

## c0 — CONFIRMED BY SCHEMA: the `task` type declares no author-like field

Read `api/lib/barkpark/tasks/schema.ex` — `task_schema/1` is the whole declared
field list for `type:task`. Its `fields:` list declares, in declaration order:

```
title  brief  description  purpose  design  design_doc  acceptance_criteria
estimate  execution_policy  queue_gate  due_at  priority  labels  tags
parent_id  lifecycle_status  assignee  worklog  blocked_reason  attachments
sessions  outcome  close_reason  retro  kind  claim  dependencies  papers
history  history_summary
```

(30 top-level fields; derived by reading every `"name" =>` at field depth in
`api/lib/barkpark/tasks/schema.ex:190-800`, excluding the `groups`,
`desk_groups`, `cross_validations`, `actions` blocks and the nested object
members, and excluding the separate `listener_schema/1` at :840-882.)

**There is no `author`, no `created_by`, no `filer`, no `actor`.** The three
identity-shaped fields that DO exist name someone other than the filer:

| field | who it names | anchor |
|---|---|---|
| `assignee` | who the row is FOR | `tasks/schema.ex:554` |
| `claim.worker` / `claim.closed_by` | who holds / sealed the lease | `tasks/schema.ex:731`, `tasks/close.ex:655,1337` |
| `worklog[].worker` | who appended a log line | `tasks/schema.ex:578` |

None is written at create time. The row's filer is nowhere in `content`.

### The `documents` table has two author-shaped columns, and neither helps

`api/lib/barkpark/content/document.ex` is the Ecto schema for the single
`documents` table every type shares. Two columns look like candidates:

* `field :author_text, :string, read_after_writes: true` (`document.ex:31`).
  Migration `20260718090000_add_documents_facet_generated_columns.exs:29`
  declares it `GENERATED ALWAYS AS (content->>'author') STORED`. A task's
  `content` has no `author` key (the field list above), so `author_text` is
  NULL on every `type:task` row by construction. It is a search-facet mirror,
  not an identity.
* `field :owner_id, :binary_id` (`document.ex:57`). `content/write_scope.ex:109`
  stamps it **only for `owner_scoped` types**. `SchemaDefinition` defaults
  `field :owner_scoped, :boolean, default: false`
  (`content/schema_definition.ex:18`), and `task_schema/1` never sets it —
  `grep -n owner_scoped api/lib/barkpark/tasks/schema.ex` returns **zero
  lines**. So `owner_id` is NULL on every task row too.

### The actor/event rail exists — and the CREATE event is the one it misses

`api/lib/barkpark/tasks/internal.ex` carries a real actor rail:

* `caller_stamp/1` (`internal.ex:732`) merges `"caller_token_id"` — the
  authenticated bearer — into the mutation event's `document`.
* the actor stamp (`internal.ex:735-763`) stamps WHO held the lease and on
  which epoch, so a close/claim is attributable from the event feed alone.

That rail is threaded by **every task verb** — `claim.ex:552,631`,
`close.ex:654`, `pulse.ex:223`, `stage.ex:779`, `move.ex:146`, `stamp.ex`,
`landed.ex:231`, `renew.ex:361`, `fence.ex:75`, `discharge.ex:172`,
`mutations.ex:68,157`.

**`create` is not one of them**, because there is no task create verb. The
tasks plugin's route table (`api/lib/barkpark/plugins/tasks.ex:533-590`)
declares GET/POST for index, ready, prime, events, claim, edges, show, close,
release, stamp, pulse, landed, discharges, renew, labels, papers, sessions,
move, stage, fleet — and **no `POST /v1/tasks`**. A task is born through the
generic document door, so its birth event is written by
`Barkpark.Content.Broadcast.save_event/6` (`content/broadcast.ex:435-460`),
whose changeset is `dataset, type, doc_id, mutation, rev, previous_rev,
document: Envelope.render(doc, nil, :internal), source, workspace_id,
project_id, dataset_id, inserted_at` — **no `caller_token_id`, no actor, no
`extra_document` seam at all**. The one create-time actor slot that exists,
`tap_broadcast`'s 7th arg `actor_user_id` (`content/broadcast.ex:113`), is fed
`Keyword.get(opts, :user_id)` at the birth call site
(`content/writer.ex:1090-1092`) — and no HTTP controller passes `:user_id` into
a content write (`grep -rn "user_id: " api/lib/barkpark_web/` returns only
auth/session/settings/presence uses, none of them a `create_document` opt). So
`revisions.actor_user_id` and the audit event's `actor_type`/`actor_id`
(`audit/event.ex:20-21`) are nil for an API-created task as well.

**VERDICT c0: CONFIRMED, not a perspective artefact.** The field is absent from
the type declaration, absent from the physical row, and absent from the birth
event. No query perspective is withholding it.

PR #17209's task-events feed does name its actor — but only for the verbs that
route through `Tasks.Internal.insert_mutation_event!/5`. It does not record a
filer, because the create it would have to observe never reaches that writer.

---

## c1 — PRICE of adding it

**Writers that would have to stamp it.** Because creation is the generic
document door, there is no single task-shaped chokepoint. The stamp would have
to land at the Writer seam, and every door below inherits it:

1. `Barkpark.Content.Writer` birth arm (`content/writer.ex:1077-1095`) — the
   one place a `type:task` row is inserted. A task-typed stamp here would need
   the caller identity, which today reaches the Writer only as
   `opts[:caller_context]` (used for tenancy) and `opts[:user_id]` (never set).
2. `BarkparkWeb.MutateController` — `/v1/data/mutate`, the door `bp task create`
   drives. It builds a `%CallerContext{}` (`mutate_controller.ex:124-130`) and
   would have to thread it as the author.
3. `bp` CLI `task create` (`internal/cli/`) — OUT OF FENCE; it would need to
   send, or the server to derive, a worker identity distinct from the bearer.
4. MCP `task_create` — same shape as (3).
5. Studio create (`live/studio/studio_live/handlers/fields.ex:95`) and
   `bulldocs_form_controller.ex:211` — the two other `create_document/4`
   callers in `api/lib/barkpark_web/`.

Note the identity mismatch that makes this more than plumbing: the rail that
exists names a **token** (`caller_token_id`) or a **user**, while every Law-0
claim is about a **worker/agent string** (`lead-api-r9`, `epic-builder-…`). One
bearer token drives dozens of agent sessions — `tasks/session_id.ex:11` says so
in those words: "`Tasks.Internal.caller_stamp/1` does not help: every session on
the [box shares one token]". A `caller_token_id` author field would therefore
be honest about authentication and still useless for "self-filed vs foreign".
Whatever ships must accept a **self-declared** filer string, the same trust
model `claim.worker` already runs on.

**BACKFILL FOR THE ~855 EXISTING CHILDREN: NOT POSSIBLE. Say so plainly.**

There is no surviving source to backfill FROM:

* the birth `mutation_events` row carries no actor at all
  (`content/broadcast.ex:435-460`, above) — there is nothing to copy;
* `revisions.actor_user_id` is nil for API creates (no controller passes
  `:user_id`);
* `documents.owner_id` is nil (task is not `owner_scoped`);
* `documents.author_text` is NULL (`content->>'author'` on content with no
  `author` key).

The only remaining signal is the slug prefix — which is the inference this row
exists to retire. **Backfilling from the slug would write the heuristic's
output into a field that then looks like a measurement.** That is strictly
worse than a null: it launders an inference into a record. The honest shape is
`author: null` on every pre-existing row, with the field's own contract saying
that null means "born before the field existed", never "unknown filer".

Proposed disposition: add the field **forward-only**, leave 855 nulls, and make
every Law-0 census state its own denominator as "N rows carry an author; M do
not" rather than scoring a percentage over a field that is null almost
everywhere. (A field that is null everywhere discriminates nothing — the census
must survive the transition period, not be broken by it.)

---

## c2 — THE CANCEL-WITHOUT-A-CLOSE-RAIL SHAPE

### The charter's two references

D798 (`.claude/workflows/bp-cloud-console-hardening-charter.md:1269`), verbatim:

> `cch-w60-s6` is `cancelled` with **`claim: null`** — no `closed_at`, no
> `closed_by`, no epoch — so a claim-rail census cannot see it while a
> lifecycle census sees it without a worker; its description says "this row
> closes with it" and its successor `cch-w63-s8` **is still open**, i.e. it was
> cancelled ahead of its successor.

and, in the same ruling:

> **THE INSTRUMENT'S OWN HOLE, stated because it is this epic's subject one
> layer up: a task document carries NO author field at all.** "Self-filed vs
> foreign" is a slug-prefix INFERENCE with five known holes on this epic's own
> roster (four hash-slugged rows created 08-08/09 plus a typo'd `cchi-`
> prefix). Every wave's "zero foreign filers" claim, D780's included, rests on
> a convention any filer can imitate or omit.

D780 (`…charter.md:1251`) is the ruling those integers answer to, verbatim:

> **RULING: every wave states CLOSES, MOVES and SELF-FILED as three separate
> integers and scores its floor against `LIVE_final − self_filed`.**

**A DISAGREEMENT BETWEEN THE TWO CHARTER ENTRIES, recorded because a future
reader will otherwise trust whichever they read first.** D798 (:1269) says
`cch-w60-s6` carries `claim: null`. D808 (`…charter.md:1279`) says the same row
carries `claim: {}`. Those are different values and only one can be the stored
one; I did not query the store, so I am not adjudicating it. It does not change
the finding — an empty map carries no `closed_by` either — but a census written
against `claim IS NULL` and one written against `claim->>'closed_by' IS NULL`
would disagree on this row for a THIRD reason, on top of the two below.

### Why the two derivations disagree — the mechanism, from the code

The Law 0 census has no executable home: `grep -rln "Law 0\|LIVE_final\|self_filed"` over
`tooling/ .claude/ docs/` returns ledger `.md` packets and the charter, and
`tooling/grip/census.mjs` is a recipe re-runner (its header: "re-execute stored
recipes and report whether they STILL ANSWER") that references neither
`lifecycle_status` nor the claim rail. So the derivation is prose, and the two
candidate rules are:

* **A — lifecycle rail:** terminal ⇔ `content.lifecycle_status in ("done","cancelled")`.
* **B — claim rail:** terminal ⇔ `content.claim.closed_by` / `closed_at` present.

They are not two readings of one fact. They are two DOORS, and the code makes
them structurally unequal:

```
                       who may write this status?
  open → done       ── ONLY Tasks.Close ─────────────→ mints claim.closed_by/closed_at/epoch
                       (transitions.ex has NO {_, "done"} pair; the
                        Writer seam refuses it — writer.ex:1163-1176)

  open → cancelled  ── Tasks.Close  ──────────────────→ mints the rail
                    └─ raw /v1/data/mutate ──────────→ NO rail at all
                       ({"open","cancelled"} IS a legal pair —
                        transitions.ex:58; and :61 for blocked→cancelled)
```

Anchors for each leg:

* `api/lib/barkpark/tasks/transitions.ex:46-67` — the legal `{from,to}` set.
  `{"open","cancelled"}` at :58 and `{"blocked","cancelled"}` at :61 are
  present; **no pair whose `to` is `"done"` exists**, which the moduledoc
  states in those words at :25-27: "`any → done` … `done` is reached ONLY
  through the `close` primitive, never a user-forgeable patch/stage."
* `api/lib/barkpark/content/writer.ex:1163-1176` —
  `ensure_task_transition_legal/6`, the Writer seam that enforces that table on
  "Every HTTP door that can change a `type:task` row's `lifecycle_status`"
  (:1127). Its own comment at :1160-1162 says it plainly: "LEGAL terminal
  transitions (`open → blocked`, `open → cancelled`) still pass with the rev
  escape exactly as before."
* `api/lib/barkpark/content/writer.ex:1212-1230` —
  `ensure_close_reason_lands_with_a_close/6`. The fence is **one-directional**:
  a `close_reason` requires a terminal status (:1227), but a terminal status
  requires no `close_reason`. So a raw `open → cancelled` patch carrying
  neither reason nor claim is accepted by design.
* `api/lib/barkpark/tasks/close.ex:1337-1338` — the only place `closed_by` and
  `closed_at` are stamped (`:655` re-stamps on the idempotent-replay arm).
  A cancel that did not come through `Tasks.Close` has neither.

**Stage is NOT the door — I checked and it is not.** `stage.ex:233` declares
`@stageable ~w(considering researching open)` with the comment "Kills
(`cancelled`) go through `close`", and `:572` gates on
`to in @stageable or from == to`. So the current `stage` verb cannot mint a
cancel. The rail-less cancel comes from the raw mutate door, not from `stage`.

### RULING: `lifecycle_status` is the canonical Law-0 CLOSES derivation

Not a preference — a consequence of the asymmetry above:

1. Derivation B is **structurally blind** to a sanctioned write. The raw-door
   cancel is legal by explicit design (transitions.ex:58, writer.ex:1160-1162),
   so B undercounts by however many cancels took that door — and B cannot be
   audited into agreement, because the rows it misses left no trace for it to
   find.
2. Derivation A sees every terminal row regardless of door, because
   `lifecycle_status` is the field the door writes.
3. Every in-code consumer already derives terminality from A, and **none** from
   B: `tasks/board.ex:475` splits cancelled off `lifecycle_status`;
   `tasks/compactor.ex:137` selects on `@default_lifecycle_statuses ~w(done cancelled)`;
   `tasks/dedup.ex:631` filters `content->>'lifecycle_status' != 'cancelled'`;
   `tasks/close.ex:1987` `@terminal_for_disposition ~w(done cancelled)`;
   `content/writer.ex:50` `@terminal_lifecycle_statuses ~w(done cancelled blocked)`.
   The prose census was the only reader that ever used B.

**The claim rail is an ATTRIBUTION rail, not a census rail.** It answers "who
sealed this row, when, on which epoch" for the rows that came through `close`.
`close.ex:613` records a probe comment — someone else's measurement, not mine —
reading "6,332 rows DO carry `claim.closed_by`", which is a large majority and
is exactly why the rail is tempting as a census. It is still the wrong
instrument: a majority that omits a class of rows by construction is a biased
sample, not a count.

Restated as the rule a future wave should apply:

> **CLOSES is counted off `content.lifecycle_status` ∈ {done, cancelled}.
> `claim.closed_by` is never a CLOSES denominator; it is the attribution you
> quote BESIDE a close, and a close with no `closed_by` is reported as
> "closed, unattributed" — not dropped, and not counted twice.**

Wave 65 measured CLOSES at 15 where wave 64 stamped 14. Under this rule the
fifteenth (`cch-backlog-law0-curl-has-no-truncation-guard`, and the rail-less
`cch-w60-s6`) are IN — D798's own correction (":1269", quoted above) already
reached that answer row by row; this packet supplies the reason it is the right
answer in general rather than a one-row adjustment.

### Why I did not "make the other agree in code"

Making B agree means making the raw cancel door mint a close rail. That edit
lives in `api/lib/barkpark/content/writer.ex` — **outside this row's fence**
(`api/lib/barkpark/tasks/**`). It is also not obviously correct: the rail
carries a worker, an epoch and a CAS, and a raw-door cancel has no claim to
fence on, so minting one would either fabricate a holder or invent a
null-worker rail shape that B would still have to special-case. Filed as a
REQUEST rather than done here. The choice is DOCUMENTED, which is the branch
c2 offers when the fix is out of reach.

---

## What I did NOT do

* I ran **no query against the live ledger**. Every count in this packet is a
  count of declarations in files at `4612977fc`, or a charter quote, or an
  attributed probe comment. The "~855 children" figure is D800's
  (`…charter.md:1271`, published 2026-08-09), quoted, not re-measured.
* I did not adjudicate D798's `claim: null` against D808's `claim: {}`.
* I did not touch `tooling/grip/census.mjs`, `router.ex`, or any doc under
  `docs/`.
