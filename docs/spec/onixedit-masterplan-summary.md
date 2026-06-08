# OnixEdit Reference Plugin — Masterplan Close-Out

The OnixEdit reference plugin is the end-to-end Barkpark plugin: a `book`
schema, a Studio LiveView editor, an ONIX 3.0 export adapter, a live
publish flow against Bokbasen, an ack-loop with structured state, and a
sign-off gate visualized in BookEditor. It exists to exercise the full
plugin contract — Schema Definition v2 (composite / arrayOf / codelist /
localizedText), encrypted plugin settings, Oban-backed background work,
and structured PubSub-broadcast lifecycle — under one publisher's
real-world ONIX requirements (Bokbasen). Phases 4-8 land the plugin;
Phases 1-3 (Oban + plugin_settings + Cloak; plugin contract + scaffolder;
validation DSL + cross-codelist checkers) are the foundation it sits on.

## Status

- OnixEdit masterplan epic: closed at WI6 merge (this PR).
- Task #12 (predecessor record): marked `done` at WI6 merge per plan §WI6.
- Task #2 (active record): closed at WI6 merge.
- All Phase 4-8 work items have landed on `main`. Phase 8 WI3 / WI4 / WI5
  merged ahead of WI6 as PR #95 / PR #96 / PR #92 respectively
  (`35d61f5` / `8efebca` / `3e78fec`). The original WI3 PR #94 was
  recreated as #95, and the original WI4 PR #93 was recreated as #96,
  during the Phase 8 REDO sequence — both recreations carry the same
  scope as their predecessors and are recorded in the Phase 8 table for
  the historical record.

## Architecture

```
                      Studio (LiveView)
                          BookEditor
                          ┌─────────────┐
                          │ pill │ badge│
                          └──┬───┴──┬───┘
                             │      │
            "Publish" event  │      │ click-to-copy submission_id
                             ▼      ▲
                    Oban PublishWorker
            ┌─────────────────────────────────┐
            │ :pending → :staging → :staged   │
            │  → :polling → :accepted         │
            │             ↘ :rejected         │
            │             ↘ :failed           │
            │             ↘ :cannot_cancel    │
            │                  → :cancelled   │
            └─────────────────────────────────┘
                             │
                             ▼
              Bokbasen.Client (Req-based)
              stage / poll / cancel
                             │
                             ▼
                  OAuth2 token cache  ──► Bokbasen IDP
                             │
                             ▼
                  metadata-import endpoint
                             │
                             ▼
            build_rejected_envelope/2  ──►  last_error
                             │
                             ▼
                    Status.write/2
              (composite merge + signed_off
               auto-derivation)
                             │
                             ▼
              Phoenix.PubSub broadcast
              "bokbasen:document:#{doc_id}"
                             │
                ┌────────────┼────────────┐
                ▼            ▼            ▼
        BookEditor pill  sign-off badge  AdminLive row
                       (Phase 8 WI3)   (/admin/onixedit/bokbasen)
```

Out-of-band: the ONIX 3.0 export pipeline (Phase 6) produces the staged
XML — `Barkpark.Plugins.OnixEdit.Export.{to_iodata,to_string,to_file}` —
gated by an `xmllint`-driven XSD validator and drift-guarded by the
`proof/onix-sample.xml` reference artifact (Phase 6 WI8).

## Phase-by-phase recap

### Phase 4 — OnixEdit plugin scaffold + EDItEUR codelists (Task #8)

| WI  | Title                                              | PR  | Merge SHA   | Date       |
|-----|----------------------------------------------------|-----|-------------|------------|
| 4.1 | OnixEdit plugin skeleton + book schema             | #53 | `569b42d`   | 2026-04-26 |
| 4.2 | Sub-schemas (Contributor, text_content, Thema)     | #54 | `cb87910`   | 2026-04-26 |
| 4.3 | EDItEUR codelist parser + seed task (BYO snapshot) | #55 | `c840bed`   | 2026-04-26 |
| 4.4 | Studio editor adapter for plugin schemas           | #56 | `726cf76`   | 2026-04-26 |

Notable decisions:

- WI3 adopted the **Bring-Your-Own codelist snapshot model (D21)**: the
  plugin Hex package does not ship EDItEUR codelist XML; the publisher
  supplies it via `BARKPARK_ONIX_CODELIST_PATH`. Closes round-2 critic R1
  license blocker.
- WI4 fixed the **TUI as read-only for plugin schemas in v1 (D12)**:
  composite / arrayOf / codelist / localizedText render as JSON dumps in
  the TUI; the Studio is the only editing surface for plugin schemas.

Format-pass commits unblocking Phase 5 (no PR; landed on main 2026-04-27):
`bd7ab82` (#58), `ad4da2e` (#59).

### Phase 5 — book schema + BookEditor + Thema picker (Task #9)

| WI  | Title                                          | PR  | Merge SHA   | Date       |
|-----|------------------------------------------------|-----|-------------|------------|
| 5.1 | BookEditor LiveView shell + 8-tab framework    | #57 | `ba2cc0e`   | 2026-04-27 |
| 5.2 | ThemaTreePicker LiveComponent                  | #63 | `b7460e0`   | 2026-04-27 |
| 5.3 | Subjects tab autosave (parent-emission wire-up)| #65 | `7014009`   | 2026-04-27 |
| 5.4 | Remaining 6 BookEditor tabs                    | #66 | `b03aef7`   | 2026-04-27 |

Schema-alignment follow-up: `themaSubjectCategory` multi-select fix —
PR #68 / `7a18931` / 2026-04-27 (Task #35).

### Phase 6 — ONIX 3.0 export adapter (Task #43)

| WI    | Title                                                  | PR  | Merge SHA   | Date       |
|-------|--------------------------------------------------------|-----|-------------|------------|
| 6.1   | Spec extraction + mapping doc + EDItEUR XSD bundle     | #74 | `2955d23`   | 2026-04-29 |
| 6.2   | Skeleton ONIXMessage + Header builder                  | #75 | `d22277f`   | 2026-04-29 |
| 6.3   | DescriptiveDetail + bibleVersion fix                   | #76 | `eb7ad19`   | 2026-04-29 |
| 6.4   | Collateral + Publishing + Supply (Norwegian locale)    | #77 | `fe963e4`   | 2026-04-29 |
| 6.5   | XSD validation gate via xmllint                        | #78 | `c3e1cac`   | 2026-04-30 |
| 6.5.5 | ONIX-spec fix-pack (extra; Boss Option 2)              | #79 | `b9602eb`   | 2026-04-30 |
| 6.6   | File output API + Studio Export button                 | #80 | `8ff25a6`   | 2026-04-30 |
| 6.7   | Bokbasen pre-flight + Norwegian locale audit (docs)    | #81 | `4bc3ee5`   | 2026-04-30 |
| 6.8   | End-to-end demo + `proof/onix-sample.xml`              | #82 | `81adb84`   | 2026-04-30 |

Notable decisions:

- **RecordReference format (Q1):** `barkpark.cloud:<_publishedId>`; the
  `drafts.` prefix is stripped so a published doc and its draft share the
  same RecordReference.
- **Fix-pack-first (WI5.5, Boss Option 2):** WI5.5 was inserted between
  WI5 and WI6 to land 4 ONIX-spec fixes (MainSubject placement, ISO 639-2/B
  language codes, Agent chain, fixture extensions) before WI6's
  user-facing surfaces, keeping the WI6/7/8 baseline clean.
- **Q7 deferral:** the `bp_export_status` composite promotion was visibly
  on-deck during WI6 and explicitly deferred to Phase 8 WI1.

### Phase 7 — Bokbasen integration (Task #1)

| WI  | Title                                                | PR  | Merge SHA   | Date       |
|-----|------------------------------------------------------|-----|-------------|------------|
| 7.1 | Bokbasen API contract spec                           | #83 | `8ca60b5`   | 2026-04-30 |
| 7.2 | Credentials + config plumbing (encrypted)            | #84 | `ea67f92`   | 2026-04-30 |
| 7.3 | HTTP client (Req-based) + OAuth2 cache + Errors      | #85 | `122988a`   | 2026-04-30 |
| 7.4 | Oban PublishWorker (single-phase async-poll)         | #86 | `6c10175`   | 2026-04-30 |
| 7.5 | BookEditor publish action + 9-state status pill      | #87 | `71414c0`   | 2026-04-30 |
| 7.6 | Mix tasks + admin LiveView at `/admin/bokbasen`      | #88 | `1f797e6`   | 2026-04-30 |
| 7.7 | E2E test with Bypass mock + redacted fixtures        | #89 | `53e843d`   | 2026-04-30 |

Notable decisions:

- **WI1 Amendment (2026-04-30T12:07:00Z):** the API is **single-phase
  async-poll, not two-phase claim**. Re-framed WI3 (`stage`/`poll`/`cancel`,
  no `claim`) and WI4 lifecycle (drop `:claiming`/`:claimed`, add
  `:polling`).
- Boss decisions Q-A / Q-C / Q-G / Q-J resolved: single-phase async-poll;
  Bypass-mock-only sandbox tests until partner credentials arrive;
  conservative rate-limit defaults (1 req/sec, max 10 concurrent,
  exponential backoff with jitter on 429, respect `Retry-After`); OAuth2
  client role = Publisher (Onix-Block-access scope, Blocks 0-12).
- WI4 wrote `bp_export_status` as a string per spec; composite promotion
  was deferred to Phase 8 WI1.
- WI6 admin LV piggybacked on the `:admin` role with a TODO at
  `router.ex:62` for a dedicated `:ops` role — closed by Phase 8 WI5.

### Phase 8 — Ack-loop + sign-off + composite + stale-codelist remediation (Task #2)

| WI  | Title                                              | PR  | Merge SHA   | Date       | Status     |
|-----|----------------------------------------------------|-----|-------------|------------|------------|
| 8.1 | `bp_export_status` composite promotion             | #90 | `deaf4d2`   | 2026-05-01 | merged     |
| 8.2 | Ack-loop full state capture                        | #91 | `968c092`   | 2026-05-01 | merged     |
| 8.3 | Sign-off gate visualization in BookEditor          | #95 (recreates #94) | `35d61f5`   | 2026-05-03 | merged     |
| 8.4 | Stale-codelist remediation                         | #96 (recreates #93) | `8efebca`   | 2026-05-03 | merged     |
| 8.5 | Carryover nits + Phase 8 e2e demo                  | #92 | `3e78fec`   | 2026-05-03 | merged     |
| 8.6 | Masterplan close-out doc + README update           | (this PR) | (this commit) | 2026-05-03 | this WI |

*WI3 / WI4 / WI5 merged on `main` ahead of WI6 (this PR). Their merge
SHAs were backfilled into the table above in the WI6 backfill commit.
PR #94 was recreated as #95 (WI3) and PR #93 was recreated as #96 (WI4)
during the Phase 8 REDO sequence — see the Status section for context.*

Per-WI summaries:

- **WI1 (#90 / `deaf4d2`)** — Promoted `bp_export_status` from a single
  string to a 9-state composite (5 timestamps, `last_error` envelope,
  `attempt_count`, `retry_at`, auto-derived `signed_off`). Added the
  `Bokbasen.Status` module: `read/1` is backwards-compatible across four
  legacy input shapes (`nil`, bare string, JSON-encoded string, native
  map); `write/2` re-fetches the document from the DB before merging the
  patch (concurrent-write safe), broadcasts on
  `bokbasen:document:#{doc_id}`, and auto-derives `signed_off=true` when
  `accepted_at` is set unless the caller explicitly passes `false`. The
  Ecto migration is idempotent and reversible. PublishWorker was
  rewritten to write the composite at every transition; BookEditor and
  AdminLive switched to `Status.read` with no visible UI change.
- **WI2 (#91 / `968c092`)** — Full state capture in the ack loop.
  `extract_submission_id/1` strips trailing slash and query string with
  a 3-tier fallback (Client-parsed → `poll_url` → raw value).
  `parse_retry_after/{1,2}` supports both integer-seconds and RFC 7231
  IMF-fixdate, returning a UTC `DateTime`. `build_rejected_envelope/2`
  parses XML rejections via regex into `details.error_text` and
  `details.error_attrs`; `raw_xml` is truncated to 4096 bytes.
  `http_status` sentinel `200` marks body-level rejection (HTTP succeeded,
  content rejected) and is distinct from transport-level 422. Nine
  lifecycle transitions write the composite via `Status.write/2`;
  `:cancelled` is **state-only** by design (Bokbasen returns 204; treated
  as stateless, no `cancelled_at` written); `:cannot_cancel` preserves
  prior timestamps via `Status.write` merge semantics. The PubSub
  broadcast carries the full composite so AdminLive and BookEditor
  render `last_error` tooltips on the same message that flips the pill.
- **WI3 (#95 / `35d61f5`)** — Sign-off gate
  visualization in BookEditor. The toolbar sign-off badge appears only
  when `signed_off=true`; it is **absent from the DOM** (not hidden) when
  `signed_off=false` so screen readers do not announce it. The badge
  shows ISO-8601 `accepted_at` and the first 8 characters of
  `submission_id`, click-to-copy. A "Re-publish to Bokbasen" button +
  confirmation modal enqueues an Oban job with `notification_type='04'`
  (ONIX list 1: Update). An edit-warning informational modal appears on
  save when a book is signed off — Save anyway proceeds and acknowledges
  for the rest of the LV session, Cancel preserves edits. Autosave is
  intentionally NOT gated. WI3 was REDONE under the commit-per-file
  mitigation after a worktree wipe lost the prior PASS attempt.
- **WI4 (#96 / `8efebca`)** — Stale-codelist
  remediation. The migration walks `schema_definitions.fields` and
  `documents.content` and default-applies `issue_version: "73"` to every
  codelist reference (idempotent + reversible). 92 codelist references
  in `book.json` are pinned to `issue_version=73`. New module
  `Barkpark.Plugins.OnixEdit.Codelists.StalenessChecker`: `detect_stale/2`
  returns stale-ref structs `%{path, codelist, ref_issue, current_issue,
  status}`; `revalidate/1` returns a `%{added, removed, changed}` diff;
  pure module, no IO or DB. `mix codelists.staleness` supports `--report`
  and `--revalidate --book-id <id>`. New `/admin/onixedit/staleness`
  LiveView with table, Re-validate button, and Mark accepted button.
  `staleness_acknowledged` is a **top-level document flag**, not nested
  inside `bp_export_status` (WI1 owns the lifecycle composite). WI4 was
  also REDONE under the commit-per-file mitigation.
- **WI5 (#92 / `3e78fec`)** — Carryover nits +
  Phase 8 e2e demo. The pill helper was extracted to
  `Barkpark.Plugins.OnixEdit.Export.StatusPill` — a single-source-of-truth
  5-bucket mapping over the 9 lifecycle states. BookEditor and AdminLive
  delegate; rendering is byte-for-byte identical pre/post. A new `:ops`
  role is decoupled from `:admin` in `live_auth.ex`; `authorize/4` uses
  `Enum.any?` over the role list so an `:admin` token still passes an
  `:ops` gate (`:admin` remains a superset of `:ops` for backwards
  compatibility). `/admin/bokbasen` switched from `:admin` to `:ops`,
  closing the Phase 7 `router.ex:62` TODO. New `docs/auth.md` documents
  both auth hooks. New `phase8_e2e_test.exs` deliberately omits a
  module-level `@moduletag` and uses per-describe `@describetag`
  (`:phase8_demo` always-on; `:requires_wi3` and `:requires_wi4`
  auto-activate when those PRs merge). New `proof/onixedit-full-demo.md`
  is a 9-numbered-phase narrative reproduction of the full Phase 4 → 6 →
  7 → 8 happy path; zero real credentials.
- **WI6 (this PR)** — Masterplan close-out doc + README update. Closes
  Task #12 and the OnixEdit masterplan epic.

## Key decisions (cross-cutting)

- **`bp_export_status` composite promotion (Q7).** Visibly on-deck during
  Phase 6 WI6, deferred to Phase 8 WI1 to keep the WI6/7/8 baseline
  clean. Phase 7 WI4 wrote status as a string per spec; Phase 8 WI1
  promoted to a 9-state composite with timestamps, `last_error`
  envelope, and auto-derived `signed_off`.
- **Schema v2 + TUI read-only constraint (Phase 0 / D12).** Plugin
  schemas use four nested types (composite / arrayOf / codelist /
  localizedText). The Go TUI is read-only for plugin schemas in v1;
  Studio is the editing surface. Documented in `CLAUDE.md` and
  `docs/plugins/SCHEMA_V2.md`.
- **BYO codelist snapshot model (D21, Phase 4 WI3).** Plugin Hex package
  does not ship EDItEUR codelist XML; publisher provides via
  `BARKPARK_ONIX_CODELIST_PATH`. Closes round-2 critic R1 license blocker.
- **RecordReference format (Phase 6 Q1).** `barkpark.cloud:<_publishedId>`;
  `drafts.` prefix stripped so a published doc and its draft share the
  same RecordReference.
- **Phase 6 fix-pack-first (WI5.5, Boss Option 2).** Inserted between WI5
  and WI6 to land 4 ONIX-spec fixes (MainSubject placement, ISO 639-2/B
  language codes, Agent chain, fixture extensions) before WI6's
  file-output API and Studio button.
- **Single-phase async-poll, not two-phase claim (Phase 7 WI1
  Amendment).** Re-framed WI3 (`stage`/`poll`/`cancel`, no `claim`) and
  WI4 lifecycle (drop `:claiming`/`:claimed`, add `:polling`) post-PR
  #83.
- **Conservative rate-limit defaults (Phase 7 WI1, Q-G).** 1 req/sec,
  max 10 concurrent, exponential backoff with jitter on 429, respect
  `Retry-After` (integer-seconds and RFC 7231 IMF-fixdate per Phase 8
  WI2).
- **`:cancelled` is state-only; `:cannot_cancel` preserves prior
  timestamps (Phase 8 WI2).** Bokbasen returns 204 on cancel — treated
  as stateless, no `cancelled_at` written. `Status.write` merge semantics
  protect prior timestamps when the worker hits `:cannot_cancel`.
- **XML rejection envelope sentinel `http_status: 200` (Phase 8 WI2).**
  Distinguishes body-level rejection (HTTP 200, content rejected) from
  transport-level rejection (HTTP 422). Same response shape, different
  classification.
- **Concurrent-write safety in `Status.write/2` (Phase 8 WI1).**
  Re-fetches the document from the DB before merging the patch so
  back-to-back writes (transition + attempt-count bump) do not lose data.
- **`signed_off` auto-derivation (Phase 8 WI1).** Auto-flips `true` when
  `accepted_at` is written, unless the caller explicitly passes `false`.
  Single source of truth that WI3's badge gate consumes.
- **`:ops` role decoupled from `:admin` (Phase 8 WI5).** Closes Phase 7
  `router.ex:62` TODO. `:admin` remains a superset of `:ops` for
  backwards compatibility. `/admin/bokbasen` switched to `:ops`.
- **Worktree isolation + commit-per-file anti-loss (Phase 8 WI3 + WI4
  REDOs).** Both WIs lost a prior PASS attempt when the worktree was
  wiped before commit. The Boss-mandated mitigation: commit each file as
  soon as it compiles. Final PR is squashed; intermediate WIP commits
  are mandatory for durability.

## Lessons learned

- **Rate-limit recovery.** Bokbasen's published rate-limit numbers are
  partner-only, so Phase 7 WI1 (Q-G) adopted conservative defaults — 1
  req/sec, max 10 concurrent, exponential backoff with jitter on HTTP
  429, and honoring `Retry-After`. Phase 8 WI2 then taught
  `parse_retry_after/{1,2}` to handle both integer-seconds and RFC 7231
  IMF-fixdate so the worker can sleep the right amount even when the
  server replies with a wall-clock target.
- **Vercel skip-condition gotcha.** The Vercel ignore-builds default
  did not match the monorepo layout: pushes that did not touch `web/`
  were still triggering preview builds. The fix was an explicit
  `vercel.json` `ignoreCommand` override (PR #73 / `d383cdb`) that returns
  exit 0 when the changed paths fall outside the web project, suppressing
  the preview without breaking the deploy hook for the paths it should
  cover.
- **STM wait-hook bug.** The Doey orchestration layer had a wait-hook
  race that allowed a worktree to be wiped before its branch had absorbed
  in-flight commits — the immediate consequence in this masterplan was
  the loss of Phase 8 WI3 and WI4's first PASS attempts. The mitigation
  inside this repo is the commit-per-file protocol on Phase 8 REDOs;
  the underlying Doey fix is tracked in Doey infrastructure history,
  not in this repository.

## Deferred items / v2 follow-ups

- **Bokbasen real-sandbox smoke test.** `BOKBASEN_SANDBOX=1`-gated test;
  awaits partner sandbox credentials. Phase 7 WI7 ships Bypass-mock-only.
- **Real (redacted) Bokbasen ack fixtures in `fixtures/bokbasen/real/`.**
  Task #12 sign-off gate. The structured ack-loop composite (WI1+WI2) is
  implemented; the deployment-gated criterion (≥1 real redacted ack lives
  in fixtures AND parser successfully classifies it) awaits real
  credentials. Distinguishes "code complete" from "production-validated."
  See §"Sign-off gate (Task #12)" below.
- **Contributors tab in BookEditor.** The schema `arrayOf` shipped in
  Phase 4 WI2; the dedicated Studio tab is post-v1.
- **Additional plugin authoring guide.** Explicit deferred-items example
  in plan §WI6.
- **TUI editing for v2 nested types** (composite / arrayOf / codelist /
  localizedText). Declared v1 constraint per `CLAUDE.md` D12. v2 may add
  TUI editing once a publisher demands it.
- **ONIX issue 74+ ingestion.** Phase 8 WI4 implements detection;
  ingestion of issue 74 is a separate ops task when EDItEUR ships.
- **Multi-publisher support beyond Bokbasen.** Implied by the "reference
  plugin" framing; a second publisher (e.g. another ONIX ingestion
  partner) is post-v1.
- **Per-doc batch re-pick UI for stale codelists.** Task #12 defers to
  Phase 9. v1 stops at the report (mix task + admin LV table).
- **Field-path mapping for ack-loop messages.** Task #12 v1 simplified
  scope: surface raw error text linked to the document and Bokbasen
  submission. Per-field structured diagnostics deferred to v2.

## Sign-off gate (Task #12)

The original Phase 8 record (Task #12) carries an explicit deployment
gate: **≥1 real (redacted) Bokbasen ack must live in
`fixtures/bokbasen/real/` AND the parser must classify it correctly
before Phase 8 is treated as production-validated.** That gate is
distinct from masterplan code-completeness. WI1 + WI2 implement the
composite and the parsers; WI7 of Phase 7 ships the Bypass-mocked E2E.
The real-fixture gate opens the moment partner sandbox or production
credentials arrive — at which point the existing parser's classification
of that fixture is the criterion to honor.

## References

- [`docs/spec/bokbasen-api-contract.md`](bokbasen-api-contract.md) —
  wire contract, single-phase async-poll model, OAuth2 transport.
- [`docs/spec/bokbasen-onix-pre-flight.md`](bokbasen-onix-pre-flight.md)
  — Bokbasen sender pre-flight + Norwegian locale audit.
- [`docs/spec/onix-export-mapping.md`](onix-export-mapping.md) — book
  schema → ONIX 3.0 element mapping (~1000 lines, line-by-line).
- [`docs/auth.md`](../auth.md) — `:ops` and `:admin` role layering;
  LiveAuth and controller plug pipelines.
- [`proof/onix-sample.xml`](../../proof/onix-sample.xml) — XSD-validated
  ONIX 3.0 reference output, drift-guarded by Phase 6 WI8.
- [`proof/onixedit-full-demo.md`](../../proof/onixedit-full-demo.md) —
  9-numbered-phase happy-path narrative across Phase 4 → 6 → 7 → 8.
