# Personal Development Server — Epic Charter (epic-cycle charter slot)

> NOTE ON THIS PATH: this filename is the rotating epic-cycle charter SLOT and has carried
> earlier epics. The prior occupant — **Studio Space-Priority Desk** (decided 2026-07-19) — is
> preserved verbatim at `.claude/workflows/bp-studio-space-priority-desk-charter.md`. Do NOT
> read this file for studio-desk history. This slot is now the memory of the
> **Personal Development Server (PDS)** epic.
>
> Epic anchor: bp task **`task-2ac1f95237c4a8e5`** (published, guerrilla).
> Product charter paper: **`/papers/personal-development-server-plan`** (rev 3, §1–9 incl. the
> user-ratified TWIN DOCTRINE: Personal Local free forever + Personal Cloud $29 twin,
> offline-first, G8 = `bp dev sync` local⇄cloud).
> Wave 1 paper: **`pds-wave-2026-07-19`** (style=article). Decided 2026-07-19.
> Wave 2 paper: **`pds-wave-2-2026-07-19`** — "The Honest Clone" (style=article). Decided 2026-07-19.
> Wave 3 paper: **`pds-wave-3-2026-07-19`** — "The Crown Proof" (style=article). Decided 2026-07-19.
> Wave 4 paper: **`pds-wave-4-2026-07-19`** — "The Crown Proof Paid" (style=article). Decided 2026-07-19.
>
> NOTE ON THE CHARTER SLOT: the epic-cycle harness names
> `.claude/workflows/bp-cloud-gui-remake-charter.md` as its default charter path. That file is the
> LIVE memory of a DIFFERENT epic (Cloud GUI Remake, `task-47bc4168392dec17`). PDS decisions must
> never be written there. **This file is the PDS epic's charter** — every PDS wave reads and
> amends it.

## Vision

A developer pulls a real dataset out of a production Barkpark into a personal instance with one
verb and zero fear: `bp cloud workspace export <slug> --profile dev --dataset <slug>` produces a
scrubbed, dataset-granular bundle provably containing ZERO secrets; `import --merge` upserts it
into a personal-local or Personal Cloud target, re-run = refresh; media serves on arrival because
blob bytes ride an edge-to-edge sidecar channel and paths are preserved verbatim. The engine is
`Barkpark.Tenancy.WorkspaceBundle` grown profile-aware — NOT a rival pipeline — under one hard
rule: the full-fidelity backup profile stays byte-identical to today (the
`workspace_bundle_test.exs` md5-parity suite is the permanent regression tripwire; green baseline
run recorded 2026-07-19, HEAD 3c14c531c, 16/16). Guardrails: prod is never a write target
(fail-closed opt-IN on the target, never a denylist keyed on an unset "prod" label); the control
plane keeps its no-customer-content invariant — pulls are edge-to-edge, the control-plane HTTP
client is never imported into the content-transfer path.

## Decisions

- **PDS-D1 — Grow the bundle engine; rival pipeline rejected.** One engine, one format, one
  completeness proof; `bp migrate` covers documents only and client-side scrub is fail-open by
  construction. Why: every load-bearing engine claim survived verification with file:line + run
  proof; Candidate B's one virtue (backup-path safety) is absorbed by the byte-identical rule.
- **PDS-D2 — The "export 500" was a 406; fix BOTH ends + the test that hid it.** Server:
  `AcceptBarkparkVendor` gains an `application/x-tar` rescue branch mirroring its SSE branch;
  CLI: `Accept: application/x-tar, application/json`; CLI tests must exercise real content
  negotiation (the httptest mock returned 200 regardless of Accept, hiding this since #3012).
  Why: live-proven — `Sent 406 in 371µs` server-side; the identical request with `Accept: */*`
  returned 200 + a valid 205MB POSIX tar. The engine works; negotiation rejected the CLI.
- **PDS-D3 — Format string stays `bp-export-v1`; profile/dataset/provenance are additive
  manifest fields.** Why: import's hard `format ==` check is the compatibility contract; the
  manifest tolerates additive keys (verified), so old consumers stay whole.
- **PDS-D4 — Dev profile = a second catalog partition, deny-by-default, fail-closed sentinel.**
  Every tenant table classified `copy | deny | scrub_fields`; an unclassified new table FAILS the
  dev sentinel (mirror of `assert_partition!/1`). Deny set from the verified census: api_tokens,
  secrets, secrets_audit, data_keys, access_grants, **webhooks** (8/8 live rows carry PLAINTEXT
  signing secrets AND are 100% dataset_id-NULL), share_links, registered_chat_hosts,
  preview_token_jti, audit_events (39,481 rows), chat_execution_leases/events,
  workspace_memberships, sync_*, cycle_*/epic_* fleet tables — plus SIZE-denies **mutation_events
  (241MB)** and **revisions (192MB)**. Why: fail-closed is the charter's law; the size-denies keep
  dev bundles ~42MB instead of ~475MB (guerrilla live numbers) and close the ticket-snapshot back
  door through revisions/mutation_events in the same stroke.
- **PDS-D5 — Ticket documents are FULL-DENY in the dev profile (type-aware scrub axis).**
  `documents` is `copy` with a per-type deny of `type='ticket'` (live: 1 ticket doc exists);
  revisions/mutation_events being table-denied closes the snapshot cascade. Why: tickets are
  customer PII conversations, not content; full-deny is simpler and fail-closed vs field-scrub.
- **PDS-D6 — Scrub happens AT EXPORT.** Secret bytes never enter the artifact; the zero-secrets
  proof scans BOTH bundle bytes and the target DB. Why: the charter demands secrets never leave
  the source; client-side scrub is fail-open.
- **PDS-D7 — G1 dataset granularity.** Group-A tables (dual dataset columns): `WHERE dataset_id
  = $target` — dataset_id is canonical (uniqueness-authoritative post-flip), never the string
  mirror; live NULL-rate is 0% on all copied content tables (webhooks' 100% NULL is moot —
  denied). The pull always carries the TRIAD roots (1 workspaces + 1 projects + 1 datasets row);
  the E2 `datasets` extraction gains the same dataset filter. E3 bare-slug members go through the
  existing `dataset_slugs_for` exclusivity gate, never a bare-slug WHERE. Group-C (28
  workspace-only tables): those classified `copy` travel workspace-whole (they are workspace
  config — roles, role_permissions, projects); there is no row-level dataset grain to fake.
- **PDS-D8 — Merge import = temp-table `ON CONFLICT (pk) DO UPDATE` promotion, root included.**
  Live-proven recipe (probe: clean re-import aborts 25P02; merge converges, 17/17 green; 94/94
  tables have a single-column PK; arbiter = the manifest's existing `order_columns`, zero
  manifest change). E3/allowlist stays `DO NOTHING` (first-workspace-wins is a deliberate
  semantic, not W1's to change). Default mode `:clean` is byte-identical to today. Scope =
  single-source refresh; cross-instance identity reconciliation on secondary unique keys is G8
  backlog.
- **PDS-D9 — Fresh-target root-slug collision: empty-shell replacement, else fail-closed
  refusal.** Every fresh `barkpark up` target carries a migration-seeded `slug='default'`
  workspace under a DIFFERENT id, so first pull always collided on `workspaces_slug_index`
  (live-proven), masked as 25P02. Merge-mode pre-flight: same slug + different id → if the
  target workspace is provably EMPTY (0 documents, 0 media_files), delete the shell inside the
  import transaction and proceed; otherwise REFUSE with an actionable error naming the
  collision. Why: makes first-pull-into-fresh-local work out of the box while never silently
  merging into a workspace that already has content under a foreign identity.
- **PDS-D10 — Prod guard is a NEW server-side fail-closed opt-IN, not migrate's warn.**
  No prod-class concept exists; `instance_env` has the wrong polarity (guerrilla = nil), and
  migrate's "guard" is warn+`--yes`. Dev-profile/merge imports REFUSE unless the target sets
  `BARKPARK_ALLOW_BUNDLE_IMPORT=1` (config `:allow_bundle_import`); `bin/barkpark up` writes it
  into the personal-local `.env` (a personal-local box is definitionally a dev target); prod
  never sets it. The clean full-fidelity restore path is untouched — the five Cloud consumers
  (backup/eject/rebalance/graduation/migration) keep working. The CLI adds a friendly
  `ServerKind`-based warning as defense-in-depth, never as the enforcement.
- **PDS-D11 — Blob channel: edge-to-edge sidecar via the CLI + a path-preserving write
  primitive.** Naive re-POST to `/media/upload` is WORSE than the bug (`unique_filename/1`
  randomizes paths → imported row 404s + orphan blob — verified). New admin-gated
  `PUT /api/workspaces/:workspace_slug/media/blob/*path` writes bytes verbatim at a validated
  relative path (tight allowlist regex, no traversal); fetch = existing `GET /media/files/*path`
  with the source admin bearer. The CLI streams per-file — blob bytes never ride the in-RAM tar.
  Renditions regenerate lazily on the target; only originals move (guerrilla default: 34 assets
  ≈ 8MB).
- **PDS-D12 — Media honesty:** serving a media_files row whose blob is missing returns an honest
  404, never the current `MatchError`/`:enoent` 500 (live-proven); `media_upload_dir` gains a
  runtime env override (`BARKPARK_MEDIA_DIR`, default unchanged) — today two instances sharing a
  checkout silently share one blob dir (compile-time path — real cross-instance bleed, proven).
- **PDS-D13 — `BARKPARK_KEK` joins `Release.Secrets.write_env/1`.** `bin/barkpark up` cannot
  boot a fresh checkout at all today (runtime.exs:190 raises; deterministic, proven twice) —
  this breaks the "Personal Local free forever" onboarding promise and blocks every builder's
  live proof. Wave-blocking round-1 fix.
- **PDS-D14 — Incremental v1 = honest re-run upsert; `--since` REJECTED.** Hard deletes are
  architecturally invisible to ANY timestamp filter (delete_all leaves no trace; 9 tables have
  no updated_at at all). Delete-reconciliation (id-set diff prune) is backlog, not W1.
- **PDS-D15 — Provenance home A: `workspaces.settings["pull_provenance"][dataset_slug]`.**
  Zero migration; mirrors the shipped theme/plugins nested-key pattern; stamped by the import
  controller after success from additive manifest fields (source_server, source_workspace,
  source_dataset, exported_at, profile) + pulled_at; surfaced in the import response and CLI
  receipt. Option B (datasets.metadata column) rejected as strictly more plumbing for the same
  information.
- **PDS-D16 — Bootstrap clobber guard, keyed on provenance.** `register_all_schemas/0` (every
  boot) run-provenly reverts imported customized plugin schemas (title/icon/visibility/fields →
  canonical; no import ordering escapes it; the write is tenancy-blind). Guard: skip
  content-column overwrite for schema rows whose (workspace, dataset) is covered by a
  `pull_provenance` stamp — log a drift warning; insert-if-absent unchanged. Blanket
  never-update rejected (freezes legitimate plugin schema evolution).
- **PDS-D17 — `-w` no-op verdict: CLI-cosmetic, NOT a server hole.** The server scopes correctly
  per URL slug (different payloads per slug, 404 fail-closed on bogus slug — proven); flat routes
  hardcode the Default workspace server-side; ScopedMirror is dead code in v1. The
  silent-wrong-workspace UX bug is backlogged; G1 code uses slug-in-URL discipline
  (`apiclient.ScopedURL`), never `-w`.
- **PDS-D18 — No streaming refactor in W1; size discipline instead.** The engine is in-RAM both
  directions (verified; guerrilla full bundle >205MB); W1's dev-profile deny set keeps pull
  bundles small enough. Streamed/chunked bundle channel + import-body streaming + per-member
  savepoint error honesty (the 25P02 masking) = backlog slices.
- **PDS-D19 — Transaction granularity unchanged.** One transaction wraps import; merge mode
  prevents the collision class rather than catching it mid-poison.
- **PDS-D20 — Stale-task hygiene closes.** task-8df445f5c4482c9f (BROKEN MAIN sentinel) closed —
  fix 064be43c5 is an ancestor of HEAD and the suite ran 16/16 green; task-448943f026b431c1
  (@canonical marker placement) closed — the marker sits 1 line above `def export/2`, inside its
  own 6-line acceptance window.

### Wave 2 amendments — "The Honest Clone" (decided 2026-07-19, paper `pds-wave-2-2026-07-19`)

Wave 2's identity: the product is a TRUSTWORTHY data plane, not merely a working pull. Every
green must be one a broken build could NOT also produce (PDS-D20). Verification round 2 ran the
code rather than reading it, and it CORRECTED the plan in five places — D21, D22, D24, D25, D26
below are all evidence-forced reversals of what wave 1 assumed.

- **PDS-D21 — The Bootstrap clobber has TWO legs, not three; the guard is a provenance-keyed SKIP
  and nothing else.** Run-proven (7/7 probe scenarios): the mechanism is neither "Default-project
  only" (surveyor #1) nor "fully unscoped, any workspace" (surveyor #2) — it is
  **DEFAULT-DATASET-SLOT MATCHING**. `scope_to_workspace_global/1` really is `do: query` (no
  workspace filter), but `scope_schema_to_dataset/3` narrows the read to the Default project's
  production dataset OR the single global nil-`dataset_id` row. A properly-backfilled foreign
  workspace row is NEVER touched (S1/S4/S6); two nil-`dataset_id` rows of the same
  `(name, dataset)` cannot even coexist (partial unique index `20260704120000`), so the
  `asc_nulls_last` "coin flip" is unreachable. Surveyor #2's *nilling* claim is REFUTED —
  `put_scope_attrs` DROPS then RE-STAMPS the scope keys with Default's ids
  (`workspace_id nilled? false / project_id nilled? false / dataset_id nilled? false`).
  Therefore: the guard must NOT filter `get_schema`'s read by `workspace_id` and must NOT thread a
  scope opt into `Bootstrap` — both are dead weight. It is exactly PDS-D16 as ratified: skip the
  content UPDATE when the matched row carries a pull-provenance stamp; insert-when-absent
  unchanged. Why: PDS-D9 adoption makes the PULLED workspace BE the Default slot (guerrilla's
  exportable workspace slug is literally `default`, 36/36 schema rows non-null `dataset_id`), so
  the pulled rows land in the exact slot bootstrap targets.
- **PDS-D22 — The clobber's blast radius is 8 columns, four of them to bare plugin-struct
  defaults.** Run-proven S7: `title · icon · visibility · owner_scoped · fields · cors_origins ·
  desk_groups · list_preview`, in-place UPDATE on the same row id. A plugin that says nothing
  about `cors_origins` still wipes it. Why: the regression bar for the guard is the full 8-column
  set, not the "title/fields revert" the wave-1 live proof measured.
- **PDS-D23 — The crown proof REBOOTS the scratch target between its two pulls.** The clobber
  fires only on boot; a convergence proof without a restart is exactly the vacuous green PDS-D20
  forbids. Why: it is the only step that makes the guard's third proof leg real.
- **PDS-D24 — `payload_snapshot` is RULED OUT as a scan target; `webhooks.secret` is the sole
  discriminator.** REFUTED live: guerrilla's 10,544 `webhook_deliveries` rows are 100%
  `source_kind=document` with `payload_snapshot` NULL — and structurally, `media` is the only kind
  that embeds a secret while `create_media_delivery/1` sets NO `endpoint_id`, so the E2 INNER JOIN
  excludes those rows from EVERY bundle in EVERY profile. A scan anchored on `payload_snapshot`
  scores zero on the full bundle too — a control that silently stops controlling. Ammo census:
  8 webhooks, 8 distinct 43-char plaintext secrets, workspace-attributed, E1; `secrets`/
  `secrets_audit` are one `workspace_id IS NULL` row structurally excluded by the tenant wall;
  `api_tokens` are hashed; `access_grants` is 2 revoked synthetic `@example.com` rows. Value-scan
  of all 17 dev-copy tables against the 8 secrets returns 0 for every table.
- **PDS-D25 — "Provably stripped" this wave means provably ABSENT TABLES, not field-scrub.**
  `@dev_scrub` is genuinely `%{}` — the dev partition contains zero `{:scrub_fields, _}` entries.
  Why: the Paper and the crown proof must say deny, not scrub; claiming field-level scrubbing
  would be an overclaim with no code behind it.
- **PDS-D26 — The ticket-deny leg is proven by a RAW BYTE-SCAN with the full bundle as positive
  control, never by a count diff.** `/v1/data/counts/:dataset` has NO perspective parameter — it
  hard-codes `perspective: "published"` and filters `not like(d.doc_id, "drafts.%")`; `?perspective=raw`
  and `?perspective=drafts` return byte-identical published bodies (live-proven). Guerrilla's SOLE
  ticket is a DRAFT (`drafts.ticket-34751d4f62f4a8f0`), so a build that omitted the deny WHERE
  clause entirely would print an IDENTICAL count diff. Worse: 213 draft rows across 8 types are
  invisible to that endpoint for every type. Ruling: (a) the crown proof's census is
  RAW-perspective (`?perspective=raw&count=true` per type, or direct SQL on both ends) — the
  counts endpoint is never the carrier; (b) the ticket leg asserts `grep -c` of the ticket doc_id
  token over `tables/documents.copy`: full bundle ≥ 1 (control FIRES) and dev bundle == 0, plus
  the manifest cross-check `documents.row_count(dev) == documents.row_count(full) - 1`; (c) do NOT
  seed a published ticket on guerrilla — prod is never a write target; seed tickets in the
  dev-export unit fixture instead.
- **PDS-D27 — The type-deny does NOT cascade, and dev-export must make it cascade.** `copy_where`
  `:e3_doc` (`EXISTS … doc_id/dataset`) and the E2 joins (`JOIN documents d ON d.id = t.from_id`)
  are type-blind, so a denied ticket's `content_edges`/`task_edges`/`plugin_doc_state`/
  `chat_runtime_usage_receipts` rows would still travel as orphans/FK violations. Live data cannot
  catch this (guerrilla's ticket has 0 rows in all three) — it is a UNIT-test obligation on
  dev-export: seed a ticket + a `content_edge`, assert both absent.
- **PDS-D28 — `dev_action/1` alone is NOT the exporter's driver.** It deliberately flattens
  `{:copy, deny_types: ["ticket"]}` to a bare `:copy` (run-proven `dev_action("documents") == :copy`).
  A builder driving off `dev_action/1` alone gets a correct-looking `:copy` for documents and ships
  every ticket — invisible to a count diff (D26). The exporter MUST read `dev_doc_type_deny/0`
  explicitly alongside it.
- **PDS-D29 — The `--dataset` arbiter must NOT resolve through `dataset_slugs_for/1`.** Live trap:
  guerrilla's `manifest.dataset_slugs` is `["bl-preview-crash-scratch","papers","tasks"]` — it
  OMITS `production`, because `dataset_slugs_for/1` drops any slug also owned by another
  workspace's project. Resolving the target through it would silently select the empty set on the
  very host the crown proof targets. Ruling: resolve by joining `datasets → projects → workspace`
  — the single dataset row whose slug matches AND whose project belongs to the target workspace;
  more than one match → an explicit error, never a silent pick. E3 dataset-keyed members keep
  going through `dataset_slugs_for/1` and INTERSECT with the target slug (fail-closed empty when
  the slug is shared) — never a bare-slug WHERE.
- **PDS-D30 — Convergence is claimed for the DEV profile only, and scoped honestly.** Three
  consecutive HEADs of the full guerrilla bundle returned 918,436,864 / 918,485,504 / 918,486,016
  bytes — the source is live and `mutation_events`/`audit_events` grow continuously, so
  byte-identical convergence is IMPOSSIBLE for `:full` and plausible for `:dev` only because dev
  denies every append-only event table. And per PDS-D8, E3/allowlist stay bare `ON CONFLICT DO
  NOTHING` in BOTH modes: root+E1+E2 converge on CONTENT, E3/allowlist on PRESENCE only. The wave
  states that boundary rather than overclaiming.
- **PDS-D31 — Export RAM is a live operating constraint: serialize, and prefer `:dev`.** A full
  guerrilla export peaks `beam.smp` at **1.83 GB RSS** on a **3.8 GB** box, dropping MemAvailable
  from 2.70 GB to 816 MB (1 Hz sampled, run-proven; 64s wall, 918 MB, exit 0 — Decide's open item
  (d) is CLOSED, the export completes). Two concurrent full exports OOM the LIVE content API.
  Ruling: never two exports at once; the crown proof runs `:dev` (projected ~50.6 MB, an 18×
  reduction) for everything except ONE full-fidelity positive-control bundle; and the deny must be
  a SKIP at COPY time, never a post-filter — a post-filter keeps the 1.9 GB peak even for `:dev`.
- **PDS-D32 — The crown proof asserts source/target `schema_migrations` parity before the first
  COPY.** #4392 widened `documents_task_lifecycle_status_check` from 5 to 7 values; Postgres
  enforces CHECK constraints on COPY, and guerrilla auto-deploys on merge. A target migrated from
  an older sha fails mid-transfer on any task row with `lifecycle_status` in
  `{considering, researching}`. `bin/barkpark up` migrates from the same checkout, so this is a
  stated PRECONDITION, not a free property — and it generalizes to any future source-side
  CHECK/enum widening.
- **PDS-D33 — Import mode is pinned `:merge` for the crown proof.** PDS-D9 adoption runs only in
  merge mode; any other mode flips the failure shape to "pulled rows safe, but a duplicate
  Default-scoped plugin row appears alongside them", which also breaks a naive per-type count diff.
- **PDS-D34 — The scratch-target boot recipe is a shipped script, not builder folklore.** Five
  traps are run-proven and none are documented: (1) `bin/barkpark up` never runs `mix deps.get` —
  a fresh worktree dies in `ensure_secrets`; (2) `CC=/usr/bin/clang` is MANDATORY because
  `~/.local/bin/cc` is `exec claude …` and the argon2 NIF build fails with `unknown option '-g'`;
  (3) `BARKPARK_HOME` must be **under ~85 chars** — the Postgres unix socket lives inside it and
  caps at 103 bytes, so agent scratchpad paths FAIL with `could not create any Unix-domain
  sockets`; (4) `bin/barkpark up | tail` HANGS FOREVER on a first boot (the spawned daemons
  inherit the pipe) — redirect to a file; (5) a fresh box has NO admin token and no mix task to
  mint one — the blob push 401s until a row is hand-inserted into `api_tokens`. Also: `bin/barkpark`
  never sets `BARKPARK_MEDIA_DIR`, and the compiled default is the RUNNING TREE's `api/uploads` —
  a harness that forgets it writes pulled blobs into the shared dev tree.
- **PDS-D35 — Sentinel re-check is step zero of every catalog-touching slice.** Both
  `assert_partition!/1` and `assert_dev_partition!/1` are GREEN at `567bf6e39` and the proof is
  non-vacuous (injecting a `workspace_id` table made BOTH fire with the right message; dropping it
  restored green). The delta `567bf6e39..87463fa3b` is docs-only — zero migrations, zero
  create-table. But the proof is sha-scoped by construction and concurrent cycles land `api/**`
  continuously, so each slice re-runs the sentinels at its own branch point.
- **PDS-D36 — The dev partition is 17 copy / 45 deny / 62 total. #4384's commit message saying 18
  is WRONG; the code is right.** Root cause traced: the squashed merge kept the FIRST sub-commit's
  pre-review count, and the second sub-commit flipped `search_intel_events` copy→deny (exactly the
  missing 1). No builder may "reconcile" the code to the message.
- **PDS-D37 — Task 24913529 (WorkspaceBundle streams instead of materializing) is sequenced OUT of
  wave 2.** It rewrites the exact functions (`do_export`, the import body read) that dev-export and
  provenance-guard touch. Why: a parallel claim guarantees conflicts on the same functions; it
  lands after this wave, informed by D31's measured numbers.
- **PDS-D38 — Every wave-2 builder is `opus`.** Fable 5 is spend-limited this session. Not a
  quality judgment — a hard constraint carried from the wish.

### Wave 3 amendments — "The Crown Proof" (decided 2026-07-19, paper `pds-wave-3-2026-07-19`)

Wave 3 opened on a world that changed mid-survey. Two surveyors built elaborate, well-evidenced
cases for a dead deploy pipeline and a box pinned at `7a43e5847`; both were TRUE WHEN WRITTEN and
FALSE by Decide. Every ruling below is anchored to run output taken after that turn, not to the
prose that preceded it.

- **PDS-D39 — THE PROOF IS THE PROGRAM: the crown proof is authored FIRST as an executable
  ladder, not last as a report.** `scripts/pds-pull-proof.sh` is a red-to-green ladder whose every
  step either PASSES with run-time-derived numbers or ABORTS naming exactly which merge it waits
  on; each engine merge flips named steps from ABORT to PASS, and the deliverable is the
  transcript. Why: wave 2 graded A- with three green engine slices and an UNPAID headline claim
  precisely because the proof was terminal — under this shape a partial transcript with honestly
  named ABORTs is still a real artifact that tells the truth about where the data plane stands.

- **PDS-D40 — P0 and P0.5 are CLOSED by evidence, not by work; do not spend a slice on either.**
  #4438/#4439/#4440 merged 18:54:55–18:55:14Z and #4412 (the D21–D38 amendment) merged after;
  push-triggered `deploy.yml` fired again at 18:55Z and guerrilla's deployed HEAD is `ec70fdc3d`,
  origin/main's tip, re-confirmed by SSH against `/opt/barkpark` and `/status.json`
  (`version 0.2.25.1308`). The dev dialect is LIVE: `export?profile=dev&dataset=production` →
  200, 51,623,424 bytes in 6.7 s, filename `default-production-dev.tar`, manifest carrying
  profile/dataset/source_dataset/source_workspace/source_server. Why: the strategy's headline
  prediction — that guerrilla would serve opts-discarding code and return a full bundle wearing a
  dev command line — is now wrong in the wave's favour; the source-freshness gate still ships,
  but it will PASS on first run rather than ABORT.

- **PDS-D41 — The anti-vacuity control is PAID: the ammo FIRES.** Same scan binary, same 8 ammo
  values, minutes apart: `full.tar` (941,046,272 bytes, 63 members) → **8 HITS, all in
  `tables/webhooks.copy`, one per line, exit 1**; `dev.tar` (51,841,024 bytes, 18 members) →
  **CLEAN, 0 hits, exit 0**. Why: an empty or truncated tar could not produce that bijection, so
  today's clean dev result is discriminating rather than the vacuous green PDS-D20 forbids.

- **PDS-D42 — Export gets an explicit timeout; it was the only unprotected path.**
  `run_copy_out/1` is `Repo.query!(sql, [])` with NO `:timeout` (workspace_bundle.ex:601-604), so
  every COPY inherits Ecto's 15,000 ms default; the file's sole `timeout: :infinity` (L229) guards
  the IMPORT transaction only. Live: the first full export died **HTTP 500 after 27.0 s**
  (`DBConnection.ConnectionError … workspace_bundle.ex:602: run_copy_out/1`), the retry succeeded
  in 193.7 s on a page cache warmed by the operator's own queries. Why: the wave's most expensive
  step cannot be intermittent, and closing a one-line asymmetry is cheaper than a retry policy.

- **PDS-D43 — An export failure is an honest envelope, never a bare 500.** `export_bundle/2`
  rescues only `WorkspaceBundle.ExportScopeError`, so a DBConnection raise degrades to
  `internal_error / unknown error` with no reason and no hint. Why: `bp dev pull` cannot tell
  "retry me" from "permanently broken" without a code, and a request_id the caller cannot resolve
  is not a signal.

- **PDS-D44 — PDS-D31's one-export budget counts ATTEMPTS, not successes.** Measured on the
  **active GREEN slot** (blue is `inactive` with `MemoryPeak=[not set]` — the obvious probe
  measures nothing): baseline `MemoryPeak=734547968` (700 MiB) → **2.65 GiB after the FAILED
  export** → **2.90 GiB after the successful one**, on a 3819 MB box already ~979 MB into swap at
  rest. Why: neither the charter's 1.83 GB design estimate nor the digest's 3.0 G is the planning
  number, and an export that dies still pays nearly the full memory cost — a retry loop counting
  only successes OOMs the live content API.

- **PDS-D45 — `:full` is NOT lossless, and the crown proof PRE-DECLARES the shortfall.**
  `production` is owned by BOTH `default` and `gyldendal`, so `dataset_slugs_for/1` drops it under
  the D21 exclusivity rule and bare-slug E3 tables get `dataset = ANY('{}')`: the single `shares`
  row at `dataset='production'` is silently omitted — `tables/shares.copy` is **0 bytes** in the
  full bundle. Why: this will surface in the per-type count diffs as an unexplained shortfall and
  discovering it mid-run looks like corruption, so the parity assertion must exclude bare-slug E3
  tables or assert the shortfall as EXPECTED with this explanation attached. The engine fix is
  backlog, not this wave.

- **PDS-D46 — Empty `dataset_slugs` is correct by design and is NOT in the provenance path.** It
  is the workspace-EXCLUSIVE bare-slug attribution set, not "datasets in this bundle"; the code
  comment predicts the symptom verbatim ("guerrilla's manifest omits `production` for exactly this
  reason"), and an unscoped export of the same workspace returns
  `['bl-preview-crash-scratch', 'papers', 'tasks']`. The lineage fields the stamp reads are
  `source_server/source_workspace/source_dataset/exported_at/profile/pulled_at`, all non-empty.
  Why: the digest flagged it as an unexamined anomaly sitting in the provenance path; it is
  neither an anomaly nor in that path.

- **PDS-D47 — Step 0's "schema_migrations parity" is REFRAMED to deploy-provenance.** There is no
  `schema_migrations` HTTP surface anywhere and guerrilla's Postgres is unreachable externally;
  `/status.json`'s `"migrations":"operational"` is a boolean over the RUNNING BINARY's own
  migration files, so a stale build prints identical green. Why: PDS-D20 forbids a green a broken
  build could also produce — the executable substitute is the deployed sha (`gh run list
  --workflow deploy.yml`, `/status.json` version, and the box's own git HEAD where SSH is
  reachable) asserted to equal or be an ancestor of the worktree the scratch target migrated from.

- **PDS-D48 — The bootstrap mechanism is RE-PROVEN and the probe is COMMITTED this wave.** The
  7-scenario probe ran **7/7 green on `ec70fdc3d`** and was mutation-tested — inverting S7 fails
  with `left: [] right: ["https://pulled.example"]`, inverting S1 with `left: "Pulled Title"
  right: "Plugin Title"` — but it has never existed as a tracked file
  (`grep -rn 'PDS-D21|PDS-D22|PDS-D23|DEFAULT-DATASET-SLOT'` over `.md/.ex/.exs/.sh/.go` returns
  zero hits). Why: wave 2's exact failure mode was a mechanism proven and then lost back to prose;
  a decision without a re-runnable artifact is not a decision.

- **PDS-D49 — `bootstrap.ex:232-233`'s comment is FALSE and is corrected in the guard's own PR.**
  It asserts `SchemaDefinition.changeset/2` does not cast the tenancy FKs;
  `schema_definition.ex:77-79` casts all three, so `stamp_scope/2`'s `is_nil` clause is
  unreachable whenever a Default workspace exists and the S3 tenancy rewrite flows through `cast`,
  not `stamp_scope`. Why: the stale comment sits directly above the line the guard modifies and
  will make a builder gate the wrong write.

- **PDS-D50 — An empty or truncated bundle is a 422, not a 500 — and the fix RIDES the
  provenance-guard slice.** `archive.ex:46` hard-matches `{:ok, entries} = :erl_tar.extract(…)`,
  so `{:error, :eof}` raises MatchError through `workspace_controller.ex:258` (proven live on the
  scratch box). Why: pull-cli's streamed channel WILL produce truncated bodies during development,
  and folding the fix into the slice that already owns the import half of the controller removes a
  same-region collision instead of creating one.

- **PDS-D51 — `internal/cli/cloud_workspace_cmd.go` is NOT greenfield.** 340 lines plus a 270-line
  test file already implement `bp cloud workspace export|import` for the shipped B2 bundle route
  (#3013, #4382). Why: a builder told to claim an empty file will either wedge the pull dialect
  into an unrelated verb family or lose a cycle discovering the collision — the slice EXTENDS the
  existing verb switch.

- **PDS-D52 — `empty_body` and `invalid_path` map to `exitValidation` (5).** Both are live 422s
  from `media_controller.ex:206-234` — the exact blob endpoint the sidecar calls — and neither has
  a `codeExit` entry, so today they fall through to `exitGeneric` (1). Why:
  `docs/cli/error-exit-table.md`'s own logic buckets 422 to exitValidation; leaving it unruled
  makes the builder invent a mapping under an exit-code assertion.

- **PDS-D53 — The scratch teardown's orphan-postgres matcher SELF-MATCHES and is fixed before the
  proof runs.** `ps -Ao pid=,command= | grep -F "$home" | grep -F postgres` has no self-pid
  exclusion and no anchor on the postgres server binary, so any argv naming both the root and the
  substring scores as an orphan — proven: identical root, identical state, teardown FAILED twice
  from a naming command line ("orphan postgres processes … 38130", roots left standing) and PASSED
  from a wrapper, with Postgres fully down throughout. Why: `pds-pull-proof.sh` will name the
  scratch root and the word postgres on one command line and turn its own teardown red.

- **PDS-D54 — Pin `BARKPARK_HOME` and `PDS_SCRATCH_POINTER` explicitly, per run.** `/tmp` is the
  69 GiB boot volume while the worktree is on 1.6 TiB; the 85-byte root cap is real and enforced;
  the pointer file is ONE global path that two concurrent PDS runs clobber. Cold boot measured
  3m17s, a warm re-boot with the full verify suite 14.6s — so step 6's convergence reboot is
  essentially free. Why: this wave runs beside two other cycles on one host.

- **PDS-D55 — The repo-wide 87-file `mix format` drift does NOT ride this wave.** It is
  pre-existing, disjoint from every PDS diff (checked file-by-file against all three merged PRs),
  behaviour-neutral after reformat (164/164 tenancy + 74/74 across a sample of the files the diff
  actually touched), and the check is labelled advisory — all four PDS PRs merged with it red.
  Why: a reformat touching `barkpark_web/controllers/**` is a gratuitous conflict surface against
  the concurrent Studio and cloud/ cycles; it lands as its own hygiene PR when they are quiet.

- **PDS-D56 — Every wave-3 builder runs `opus`.** Why: Fable 5 is spend-limited; the constraint is
  a hard input to the wave, not a preference.

- **PDS-D57 — `scripts/pds-pull-proof.sh` has two owners IN SEQUENCE, never in parallel.** The
  harness slice AUTHORS the ladder in round 1 and commits the first honest partial transcript; the
  crown-proof slice RUNS it in round 2 and edits it only where the live run forces a change. Why:
  proof-first only pays if the script exists before the engines land, and one file with two
  concurrent owners is a merge conflict wearing a plan.


- **PDS-D58 — The pull front door is the two-command PAIR, never a single `bp dev pull` verb.**
  `pds-w1-pull-cli` shipped the pull as `bp cloud workspace export --profile dev --dataset <ds>
  --with-blobs` followed by `import --yes --merge --with-blobs`; a single-verb wrapper was REFUSED
  by the task dedup wall as a duplicate of that slice. Why: any brief or script text claiming
  step 1 self-greens on the CLI merge is describing a verb that does not exist — the crown proof
  must wire the pair itself. (A unified `bp dev pull` belongs to the later `bp dev` namespace.)

- **PDS-D59 — The round-2 fidelity slice is `pds-w3-shares-fidelity`.** The wave-3 roadmap named
  `pds-w3-full-fidelity-shares-gap`, a task id that was never published. Why: a roadmap pointing at
  a nonexistent id strands the lead's dispatch the moment round 1 clears.

- **PDS-D60 — All four wave-3 PRs are MERGED and DEPLOYED; the stale-box hazard is closed by
  measurement, and the LOCAL-source-plane contingency is RETIRED.** #4476/#4478/#4479 merged
  20:40–20:41Z, #4477 merged 20:55:03Z after registering `export_failed` in
  `Content.Errors.@public_inline_codes` + openapi + api-v1 §9; guerrilla's box HEAD, its
  `.instance-deploy-last`, and origin/main are all `b7d6ce8ee`, and `strings` on the LIVE slot's
  `Elixir.Barkpark.Tenancy.WorkspaceBundle.beam` finds `export_copy_timeout` where the previous
  build finds zero. Why: the two-plane hedge was a rejected Strategize rival that never reached the
  charter or the ledger — hedging against a hazard that has been measured away spends the wave's
  budget on nothing. The proof runs on the real guerrilla source plane, and says so in its banner.

- **PDS-D61 — `bp cloud workspace export --dataset` is a SILENT NO-OP and must be fixed before the
  crown proof runs.** `-d/--dataset` is a GLOBAL flag consumed by `globals.go:189` wherever it
  appears in argv, so `cloud_workspace_cmd.go:129`'s local `dataset` flag always resolves empty and
  `bundleScopeQuery` omits it; `--dry-run` renders `…/export?profile=dev` with no dataset in every
  spelling. The bundle taken this way carries `dataset: null` and three exclusive `dataset_slugs`
  — a WHOLE-WORKSPACE bundle wearing a dataset-scoped command line. `cloud_site_cmd.go:163-172`
  documents the identical collision and works around it; export never got the treatment. Why: this
  is the same silent-wrong-answer shape step 0b exists to kill, one layer lower — in the CLI, not
  the deploy.

- **PDS-D62 — The dropped `--dataset` leaves the Bootstrap clobber guard INERT, so step 6 requires
  a dataset-narrowed pull.** `stamp_provenance` keys the stamp by `manifest["dataset"] ||
  source_dataset`, else `dataset_slugs`; with dataset null it stamped `tasks`/`papers`/
  `bl-preview-crash-scratch`, while all 36 imported `schema_definitions` rows are
  `dataset='production'` and `provenance_covered?` looks up `pull_provenance(ws, row.dataset)` —
  `settings->'pull_provenance'->'production'` reads `null`. Structurally a whole-workspace bundle
  can NEVER stamp `production`, because `dataset_slugs_for/1` drops cross-tenant-shared slugs by
  design (D21/D46). Why: a step-6 convergence green taken on a workspace-grain pull measures
  identical plugin declarations, not a guard — the exact vacuous green D20 forbids.

- **PDS-D63 — The CLI env dialect is `BARKPARK_API_URL` + `BARKPARK_API_TOKEN`, and every rung
  passes `-s <url> --token <tok>` explicitly.** `BARKPARK_TOKEN` is read NOWHERE (`cli.go:631-640`);
  the prescribed line ran with the guerrilla admin token from `~/.config/barkpark/config.json` and
  answered `unauthorized`. Why: the mirrored typo aims a production admin token at production —
  explicit flags cannot inherit ambient config.

- **PDS-D64 — Step 0c's `MIX_ENV=dev mix run` targets the DEVELOPER'S `barkpark_dev`, never the
  scratch DB, and must be corrected in the same slice.** With `BARKPARK_HOME`, `BARKPARK_PG_PORT`,
  `PDS_SCRATCH_DB` and `DATABASE_URL` all pointed at a scratch instance, the Repo resolved
  `[username: "postgres", hostname: "localhost", database: "barkpark_dev"]` — `dev.exs:4-12`
  hardcodes host/port/user and `DATABASE_URL` is read only in the prod branch. Step 0c has never
  executed its body, so the defect is latent, not yet recorded. Why: a "SENTINELS OK" measured
  against the wrong database is a vacuous green with a transcript line.

- **PDS-D65 — The provenance off-switch is a direct `psql` UPDATE with a `RETURNING` assertion, and
  the reboot is `bin/barkpark stop && up`.** There is no CLI/HTTP surface for
  `set_pull_provenance(ws, ds, %{})` (`tenancy.ex:604-606` says so verbatim); direct-SQL mutation of
  the scratch DB is already the sanctioned idiom (`pds-scratch-target.sh:167-176` mints the admin
  token that way). `jsonb_set` is a silent NO-OP when the `pull_provenance` parent is absent —
  proven — so the clear must assert its `RETURNING` value or use the `#-` delete form.
  `pds-scratch-target.sh` has NO `restart` verb and `teardown` stops Postgres. Why: step 6's
  failure demonstration is the only thing that makes its green an instrument.

- **PDS-D66 — The census carrier hazard is REFUTED, but the roster is derived at RUN TIME and the
  authedness is asserted.** The scratch target's own minted admin token reads as authed on
  `?perspective=raw&count=true` (authed raw 404 papers vs published 397; target authed raw 1 vs
  published 0). Two live traps remain: an UNAUTHED raw query does not 401, it silently returns
  published-only (a 7-document false differential on this bundle), and anonymous callers on
  PRIVATE-visibility schemas get a flat 404 rather than a pinned perspective. `production/post`
  returns 0 on BOTH ends because this workspace has no `post` documents at all. Why: a census that
  hardcodes a type or loses its token reads as data loss, not as an instrument failure.

- **PDS-D67 — Step 5 resolves from the TARGET's own `/v1/media/:dataset` index, takes `originalUrl`
  and `size` VERBATIM, and asserts 200 AND `content-length == size` for EVERY asset.** Run-proven
  34/34, 0 mismatches, surviving a reboot. `media_files.size` is stamped once at upload from
  `File.stat` and round-trips byte-for-byte through the bundle COPY; `put_blob` writes bytes and
  never touches the DB, so the stored size is an INDEPENDENT witness. A truncated blob still serves
  200 with a matching `content-length` (Plug's `send_file` reports on-disk bytes) — only the stored
  size convicts it; a missing blob answers the typed 404 `media blob missing`. The FLAT `/media`
  index emits no `originalUrl` and ignores `limit`, and `originalUrl` may be signed. Why: a
  source-guessed path or a rebuilt URL proves the harness's arithmetic, not the pull.

- **PDS-D68 — `UNSCANNED > 0` is a HARD GATE in step 4's target-DB half.** `pds-secret-scan.sh`'s
  own exit code is driven only by `$HITS`; `UNSCANNED` prints a NOTE and never fails, and a table
  the connecting role has NO privilege on does not even reach the UNSCANNED branch — it drops out
  of `information_schema.tables` entirely and the scan reports `tables scanned: 0 · CLEAN` with the
  secret sitting in the database. The instrument itself is sound: `control` exits 0 and
  `control --simulate-broken-instrument` exits 3. Why: a partially-permissioned target reading as
  CLEAN is indistinguishable from a genuinely clean one — the disclosure must gate, not narrate.

- **PDS-D69 — ONE full export, run-STABLE path, ATTEMPT-counted before the request, mkdir-locked,
  with five declared abort conditions printed before any byte moves.** There is NO server-side
  serialization: `workspace_controller.ex:154` has no lock or semaphore and `send_resp(200, bundle)`
  materialises the whole ~941 MB tar as one BEAM binary, so PDS-D31's "never two at once" is a
  policy the runner's own client-side lock is the only enforcement of. `flock` does not exist on
  Darwin, so the lock is `mkdir`. `ART_DIR` is `RUN_TAG`-scoped and changes every invocation, so a
  bundle parked there is invisible to the next run and tempts a second attempt. Gates: (a) served
  sha re-pinned and equal to step 0a's, (b) `MemAvailable >= 2200 MB`, (c) attempts < budget,
  (d) no `deploy.yml` run in progress, (e) lock acquired. Why: PDS-D44 counts ATTEMPTS — a dead
  export already pays 2.65 GiB on a 3.8 GB box that was measured falling from 2618 MB to 1927 MB
  available in twelve idle minutes.

- **PDS-D70 — The export's memory cost is measured by a 1 Hz `ps` RSS sampler over SSH; the slot is
  NOT restarted.** `memory.peak` is mode `0444` on kernel `6.8.0-106` (writable reset landed in
  6.12), so the cgroup counter can only be zeroed by restarting the unit — measured at ~26 s of
  live content-API downtime, an authorization-requiring act. The cgroup figure is therefore reported
  as CUMULATIVE since `ExecMainStartTimestamp` and explicitly labelled contaminated. No RSS
  instrumentation exists anywhere in the repo; the sampler is new code. Neither PDS-D31's 1.83 GB
  (1 Hz sampled) nor PDS-D44's 2.65/2.90 GiB (monotonic, never reset between the failed and the
  successful attempt) is the run's number. Why: the run's own measurement is the only honest one,
  and a 26-second outage is not a free instrument tweak.

- **PDS-D71 — The ladder is SEVERABLE: the dev-pull rungs run regardless of the full-export gate.**
  Steps 0/0b/0c/1/2/5/6/7/8 need only the cheap dev export (7.2 s, 52.9 MB, 34 blobs, +33.5 MiB
  cgroup peak — measured). Steps 3 and 4 alone consume the one full bundle. Why: a headroom ABORT
  must cost two rungs, never the crown proof's core — and an ABORT on (b) is the CORRECT behaviour,
  not a wave failure.

- **PDS-D72 — A closing re-pin rung is MANDATORY.** `DEPLOYED_SHA` is captured once at
  `pds-pull-proof.sh:382` and read by every later step without ever being re-queried; the box
  redeployed three times inside one 15-minute survey and once inside a three-minute read-only probe
  (`d220c53e → b7d6ce8e`, Caddy's upstream flipping `:4000 → :4001` mid-command). The rung re-reads
  the sha over SSH and compares, with `status.json`'s process-relative `uptime_seconds` as the
  SSH-free fallback (weaker: it detects a restart, not which sha). Why: a differential straddling
  two binaries is not a differential.

- **PDS-D73 — Step 7's 403 `bundle_import_disabled` proof is scoped to `mode=merge` ONLY.** The
  `:allow_bundle_import` gate wraps only the merge branch (`workspace_controller.ex:258-282`);
  `clean` is the DEFAULT mode and is ungated, and a clean import into a populated target answers an
  opaque 500 whose true cause is a `25P02 in_failed_sql_transaction` at
  `workspace_bundle.ex:233`. The refusal code itself is real and pinned by tests — the earlier
  "exists nowhere in api/" survey claim was a primary-checkout artifact. Why: claiming "guerrilla
  cannot be written" from a merge-mode 403 overstates what was proven.

- **PDS-D74 — `shares` and `preview_token_jti` get DIFFERENT answers, and the fix lands AFTER the
  crown proof.** `shares` carries `workspace_slug NOT NULL` with a unique
  `(workspace_slug, project_slug, dataset)` index, so correct-export is `WHERE t.workspace_slug =
  <lit>` — no triad, +50 lines, 0 test edits, the line-222 cross-tenant refute untouched, and the
  md5 parity suite compares run-to-run rather than golden hashes. `preview_token_jti` carries ONLY a
  bare `dataset` string, so any triad predicate resolves by slug STRING, matches BOTH colliding
  workspaces and flips that refute into a live leak — its answer is a DECLARED LOSS in the manifest.
  A prototype also exposed that `tenancy.ex:1234` claims the teardown predicates are "the EXACT
  keystone extraction shapes" while `delete_e3_dataset_keyed` hardcodes the bare slug ANY, and 98
  tests stay green across the drift. Why: one answer across `@e3_dataset_keyed` either strands the
  loss or opens the leak, and landing a fidelity change underneath a running proof invalidates its
  census.

- **PDS-D75 — Criterion 7 of `pds-w1-crown-proof` is REWRITTEN, not word-patched.** The criterion
  said "the scratch target is REBOOTED between the two pulls and the second pull converges
  byte-identically." The shipped step 6 (`scripts/pds-pull-proof.sh:1910-2006`) runs ONE pull —
  it ABORTs naming step 1 if `PULL_BUNDLE` is empty — then a real reboot (`bin/barkpark stop`
  then `up` in the same `BARKPARK_HOME`; there is no restart verb), an md5 digest over the EIGHT
  guarded columns (`title, icon, visibility, owner_scoped, fields, cors_origins, desk_groups,
  list_preview`) `string_agg`'d `ORDER BY (dataset, name)` — that pair, not `name` alone, being the
  table's unique index — and then a SEPARATE guard-off control. Why: swapping the single word
  "byte-identically" (already forbidden by D30) would leave the criterion describing a two-pull
  test nobody runs, so the climber either fails a healthy rung or overclaims a green one.

- **PDS-D76 — Criterion 6 grows the rung's real strength: EVERY asset, the typed 404, and a
  fail-demo that must have fired.** The criterion asked for "an imported asset path" (singular)
  while step 5 asserts every asset resolved from the TARGET's own `/v1/media/:dataset` and
  additionally asserts a typed 404 on a missing blob. Why: a criterion strictly weaker than its
  rung is satisfied by one asset, and `PDS_STEP5_FAILDEMO=0` still emits `PASS 5` with only an
  informational "the pass below is weaker for it" note (`:1874`).

- **PDS-D77 — Criterion 10 grows CLOSING teeth; an opening banner alone never satisfies it.**
  Step 8 (`:2056-2109`) can `fail 8 "THE SOURCE REDEPLOYED UNDER THIS RUN"` or ABORT with no
  re-pin signal, and NO acceptance criterion covered it. Criterion 10 now requires the banner to
  open AND step 8 to have run with its verdict printed; a step-8 ABORT is reported as an UNDATED
  transcript and does not satisfy the criterion. Why: the wish demands the closing re-pin, and a
  criterion satisfied before the run's most dangerous window has no teeth where they are needed.

- **PDS-D78 — THE DEPLOY EPOCH: a differential is valid only inside one epoch, and a red 0b from
  a box-ahead is an epoch event, never an assertion to loosen.** Deploy fires 58×/24h with a
  ~28.5-minute median and no quiet-window mechanism exists anywhere. Rung 0b asserts
  `merge-base --is-ancestor DEPLOYED_SHA worktree_sha` — TOLERANT of the worktree being ahead,
  FAILING two ways when the BOX is ahead (`cat-file -e` misses the object, `:645-647`; or
  is-ancestor is false, `:655-657`). The transcript prints the epoch boundary; a differential
  straddling two binaries is reported UNDATED rather than as a result; a red 0b means re-fetch,
  rebase the climb worktree, restart the run and SAY SO. Why: at preflight the box sat one commit
  behind main with a loaded deploy pending, so this red is the wave's single highest-probability
  event and it looks exactly like an assertion worth relaxing.

- **PDS-D79 — `PDS_CONTROL_PG` must be exported into the HARNESS's own environment or rung 4
  cannot close.** Step 4 gates its control call on `[ -n "${PDS_CONTROL_PG:-}" ]` (`:1648`) and
  does NOT fall back to the bare `postgres` conninfo that `pds-secret-scan.sh control` defaults to
  standalone; the else-branch prints `instrument control: NOT RUN` and the step still passes. The
  control itself is proven end to end: `CONTROL EXIT=0`, FIRE (2 hits, full bundle) / FIRE (2 hits,
  target DB) / CLEAN (0 hits, deny-shaped dev bundle), throwaway DB dropped. Why: one forgotten
  env var silently costs the closing rule its rung-4 leg while printing green.

- **PDS-D80 — `PDS_AMMO_FILE` REPLACES the real ammo and is never set in the climb's own
  environment.** `resolve_ammo()` short-circuits on it with an early return before `ssh_available`
  (`:1591-1594`). A leaked value makes all three of step 4's legs — dev-clean, target-DB-clean and
  the full-bundle FIRE — measure the literal string, so a poisoned run prints three greens while
  proving nothing about `webhooks.secret`. Mutations run as their own throwaway `--only`
  invocations with the variable unset for the climb. Why: this is the wave's most dangerous
  vacuous-green, and it is one exported variable away at all times.

- **PDS-D81 — Safeguards fall into THREE unequal classes and the transcript records demo status
  per rung.** DEMONSTRATED BY DEFAULT: steps 5 and 6 (`PDS_STEP5_FAILDEMO`, `PDS_STEP6_GUARD_DEMO`,
  both default 1). DEMONSTRATED BUT SEVERABLE: steps 3 and 4's positive controls, whose proof
  capability is itself conditional on the one full export. UNDEMONSTRATED PASSIVE: everything else,
  including step 2's ERR row and step 3's COPY-TEXT grammar check. Why: the wave's own commitment
  ("every first-pass rung owes a mutation") was only two-fifths satisfied, and treating all named
  safeguards as equivalent hides which greens were ever shown able to go red.

- **PDS-D82 — The two first-pass mutations are PROVEN, BOUNDED and SCOPED.** Step-4 ammo poison:
  `bp-export-v1` (12 bytes, clear of `MIN_AMMO_LEN=8`) is present in every real bundle because
  `Archive.pack/2` calls `:erl_tar.create(path, members, [])` with an EMPTY option list — nothing is
  compressed — and the scanner greps EXTRACTED members; it reddens step 4's PRIMARY dev-clean
  assertion at exit 1 and returns before the export-costing control, spending zero budget. Step-1
  cheap-fail: a nonexistent slug exits 4 (`exitNotFound`) in ~0.09 s with NO output file created.
  SCOPE: the poison proves the extraction+grep plumbing and the HIT→FAIL conversion, NOT the dev
  partition's table DENY; the cheap-fail is non-discriminating (a bogus token returns the identical
  `not_found` envelope and identical exit 4) and it kills steps 2/5/6, so it runs alone.

- **PDS-D83 — THE BUCKET RULE: every red rung is sorted BEFORE anything is touched.** HARNESS BUG →
  fix the instrument, and show the corrected assertion still fails on the pre-fix condition. ENGINE
  FAIL → report it, file it, do NOT fix it this wave. Why: editing the harness until the red goes
  away converts an engine FAIL into a vacuous green at exactly the moment it is most tempting.

- **PDS-D84 — THE CLOSING RULE, pre-declared before the climber meets it.** `pds-w1-crown-proof`
  closes ONLY if rungs 3 and 4 pass WITH their controls FIRING off the one full bundle AND rungs
  1/2/5/6 pass against a real booted target. A severable headroom ABORT of 3/4 is an honest
  designed outcome and does NOT close the task. Why: the wish's own "zero ABORTs → close" invites
  closing on a run whose full export was legitimately refused, and 3/4 are the exact leg the
  zero-secrets headline stands on.

- **PDS-D85 — `merge_upsert` DOES carry `media_files.size`; the live-bug premise is REFUTED and the
  residue is a COVERAGE gap.** `media_files` is `@pinned_e1` → `import_strategy(_) → "copy"` →
  `merge_upsert`, whose `DO UPDATE SET` is built generically over `cols -- order_cols`, so `size`
  is updated with no special-casing; it also rides `@dev_copy` with an empty scrub set. Two probes
  converge, including step 1's exact dev+merge path. The mutation proof: excluding `size` from that
  update set reddens ONLY the new probe — 25 tests, 1 failure — because the md5-parity merge test
  drifts workspaces/documents/content_edges/authoring_exemptions and never touches `media_files`,
  and the only other merge-mode test asserts `total_rows > 0`. Why: pin the property, do not "fix"
  an engine that is healthy.

- **PDS-D86 — `ensure_bp()`'s freshness gate checks three of the four flags its own prose claims.**
  The case-statements at `:358-362` assert `--profile full|dev`, `--merge`, `--with-blobs`; there is
  no `--dataset` branch, while `:331` and `:839` both claim the check covers it. Latent, not
  live-broken — the harness always builds fresh from the worktree and ABORTs rather than falling
  back to PATH. Why: the wave's headline defect class (D61's silent `--dataset` drop) is the exact
  regression this gate would be blind to.

- **PDS-D87 — The transcript is a DURABLE, CITED receipt and the stale one is RETIRED in the same
  PR.** `scripts/pds-pull-proof.first-run.txt` is the pre-#4586 run (3 PASS · 7 ABORT · 0 FAIL, sha
  `ec70fdc3d`, no step 8, ABORT stubs for 1/2/5/6) and is cited by NO doc, card, paper or charter
  line across all 627 tracked `.md` files. The crown transcript lands as
  `scripts/pds-pull-proof.crown-transcript.txt`, append-only (attempt 1's reds are never deleted),
  the orphan is deleted in the same PR, and both the charter and an evidence paper cite the new
  path. Why: two receipts in one directory means the stale one gets read as the crown proof.

- **PDS-D88 — `bp search` EXISTS as `barkpark search query`.** Six surveyors reported it missing and
  fell back to grep; two later probes ran it successfully (1287 hits). Every "no prior art"
  conclusion this epic recorded on the strength of its absence is re-openable. Why: a false
  negative on the prior-art tool silently weakens every novelty claim built on top of it.

- **PDS-D89 — `--only X --plan` RUNS LIVE.** The arg parser is a `case` on `$1` only (`:2209`) with
  no shift loop, so trailing flags are silently ignored and a preflight operator reaching for the
  safety flag in the wrong position takes a real export. Why: the dry-run flag is only safe first,
  and that is a property to fix in the instrument rather than to remember.

- **PDS-D90 — Charter continuity: the amendment LANDS #4494 REBASED, never re-authored, and
  `reset --hard origin/main` on the primary checkout stays forbidden.** #4494 is a strict superset
  of local main's stranded `90b13ad83` (diffing entry headings yields only `>` lines), is contiguous
  D1–D74 with no gaps, and rebases conflict-free (merge-base `b7d6ce8ee`, origin never touched the
  file since). Local main is DIVERGENT — 58 behind, 9 ahead — so a push is impossible and a blind
  rebase-and-push would REVERT four charter files origin advanced, one of which
  (`bp-task-design-language-spec.md`, −65 lines) no local commit even touches. Why: the already-filed
  `pds-bl-charter-slot-durability` warns a blanket reset destroys five epics' charters at once,
  including the TLV charter that exists nowhere but local main.

- **PDS-D91 — The export route is `/api/workspaces/:slug/export`, NOT `/v1/workspaces/...`.** Three
  runs of the `/v1` path returned `HTTP=404 BYTES=206 {"code":"not_found"}`; `router.ex:2443` scopes
  it under `/api` and the harness itself calls `/api/...` at `:580` and `:1365`. With `/api` it
  returns 200 / 54,812,160 bytes / 18 members. Why: a "VERIFIED FACTS, do not re-derive" line was
  wrong, and a worker who trusted it would have measured nothing and blamed the engine.

- **PDS-D92 — The headroom gate is CHECK-AND-GO on a ~10-minute retry cadence.** MemAvailable was
  above the 2200 MB floor in 97/97 five-second samples across 486 s, and in 51.7% (worst day) to
  73.4% of every 10-minute `sar` sample over four days, with a 130-minute continuous open window on
  the worst day. A failed gate (b) `return 1`s at `:1330` BEFORE `spent_now=$((spent + 1))` at
  `:1334`. Why: a closed window costs ZERO attempts, so polling is free and the window is the box's
  majority state — not a knife-edge to be timed.

- **PDS-D93 — The deploy pounce is REFUTED and FORBIDDEN.** Across all 30 slot restarts on one day a
  deploy is worth mean +174 MB / median +146 MB with 9 of 30 NEGATIVE, and the three large rises all
  began from depressed baselines (regression to the mean, not headroom manufacture). guerrilla is
  blue/green, so a deploy is a memory TROUGH first — three coexisting BEAMs plus a live
  `deps/req` compile bottomed at 2248 MB. Worse, pouncing breaks gate (a) (`DEPLOYED_SHA` is pinned
  once at `:562`) AND step 0b (`:661` hard-fails when the served sha is not an ancestor of the
  worktree). Why: it trades a gate the box passes most of the time for two gates it is guaranteed to
  fail. The dominant driver of MemAvailable here is aggregate quiet, not BEAM freshness.

- **PDS-D94 — Step 0c FAILED its first-ever live execution: `mix run --no-start` starts no dep apps.**
  Measured inside the BEAM: `db_connection started? nil · postgrex started? nil · Watcher alive? nil`,
  so `Barkpark.Repo.start_link()` dies on `GenServer.call(DBConnection.Watcher, …)`. Starting only
  `:postgrex` is insufficient — `Ecto.Repo.Registry` is next. The fix is
  `Application.ensure_all_started(:ecto_sql)` + `(:postgrex)` immediately before the `put_env` block,
  which flips `--only 0c` from `HARNESS_EXIT=1 / FAIL` to `HARNESS_EXIT=0 / PASS` printing
  `REPO IS barkpark:43195`. Why: HARNESS BUG, PREFLIGHT-fixable, and the rung is otherwise sound —
  with the apps started both sentinels return `SENTINELS OK` against the scratch target.

- **PDS-D95 — PDS-D64's guard is an INSTRUMENT, not a decoration — proven by mutation.** With the
  apps started but the `put_env` removed, the Repo landed on `REPO IS barkpark_dev:5432` and the
  self-check fired `REPO MISMATCH — wanted barkpark:43195`. The developer's own `barkpark_dev` is
  live on this host at localhost:5432, so D64's hazard is reachable, not theoretical.

- **PDS-D96 — Step 0c's catch-all `else` at `:788` reports ANY non-zero exit as "a sentinel RAISED".**
  A Repo boot crash in which no sentinel executed was reported verbatim as
  `FAIL 0c a sentinel RAISED (exit 1) — … A new/unclassified tenant table must be classified`. Why:
  under the bucket rule that line becomes a FILED engine defect that does not exist, and a false
  ENGINE FAIL is the most expensive sentence the append-only transcript can carry.

- **PDS-D97 — Step 4 has NO cross-invocation guard, and its PASS line overclaims a leg that did not
  run.** `awk '/^step_4\(\)/,/^step_5\(\)/' | grep -c PULL_BUNDLE` returns 0, while steps 2/5/6 each
  abort `step:1` at `:1135` / `:1769` / `:1940`; step 4's target leg gates only on
  `if load_target && [ -n "$TARGET_DB" ]` (`:1680`). Live `--only 4` against a stale target printed
  `no dev bundle from step 0a — the bundle half of this step did not run` and would still terminate
  in `pass 4 "… all three legs this run: the DEV bundle is CLEAN …"`. Why: rung 4 is one of the two
  control-bearing rungs D84 names, so a partial-invocation pass is exactly the confident-wrong
  artifact this wave exists to prevent.

- **PDS-D98 — Gate (d) fails OPEN on a GitHub API error.** 5 of 8 back-to-back
  `gh run list --workflow deploy.yml --branch main --status in_progress` calls returned
  `HTTP 503: No server is currently available`; `2>/dev/null … || true` (`:1298-1307`) makes an
  errored call indistinguishable from "no deploy running" and reports
  `cond_d="OK (no deploy.yml run in progress)"`. Why: gh-MISSING fails closed (`ok=0`) but
  gh-ERRORING fails open — the inverse hazard, on the gate that protects the one attempt.

- **PDS-D99 — `grep -c … || echo 0` at `:1687` yields the two-line string `0\n0`, silently skipping
  the PDS-D68 UNSCANNED gate.** `grep -c` prints `0` AND exits 1 on no-match, so both branches emit;
  `[ "0\n0" -gt 0 ]` then errors to stderr and evaluates FALSE. Reproduced live:
  `line 1701: [: 0\nERR: integer expression expected`. Benign TODAY only because
  `pds-secret-scan.sh:278` emits the NOTE the `sed` at `:1686` catches whenever the true count is >0.
  Why: a raw bash error inside an append-only evidence artifact, plus a dead tripwire that is the
  sole detector if that NOTE's wording ever changes.

- **PDS-D100 — THE HARNESS FREEZE.** Every harness change lands in PREFLIGHT, before attempt 1. From
  attempt 1 onward the harness is FROZEN and each red sorts into exactly one bucket BEFORE anything
  is touched: HARNESS BUG (filed; the corrected assertion must be SHOWN still failing on the pre-fix
  condition) or ENGINE FAIL (filed, NOT fixed). Why: the freeze is what makes the transcript
  trustworthy — it removes the climber's ability to edit a red away exactly when doing so is most
  tempting.

- **PDS-D101 — Anything touching rungs 2–6 runs as a full `--all`; `--only 3,4` is FORBIDDEN.**
  `canonical_order` (`:2177-2191`) enforces ladder order only WITHIN one process; DEV_BUNDLE and
  PULL_BUNDLE are bash globals that do not survive a process boundary; step 6's guard-off control
  clears the stamp and reboots with no restore; and step 4 has no guard (D97). So a deferred 3/4
  re-run must be `--all`, which necessarily re-imports the clobber, re-pins the sha, re-brackets
  step 8, and re-runs 6 AFTER 4 — and reuses a parked bundle for 0 attempts when the sha held
  (`:1249-1261`). THE DEFERRAL RULE: any deferral of 3/4 also defers 6, enforced by making `--all`
  the only deferral mechanism.

- **PDS-D102 — Env hygiene is MECHANISM, not discipline: the run greps its own transcript.** D79
  fires (an unexported `PDS_CONTROL_PG` prints `instrument control: NOT RUN` and still reaches a
  terminal `PASS 4` — the else-branch at `:1668-1670` is `info`-level with no `return`) and D80's
  substitution fires (`ammo 1 value(s) from PDS_AMMO_FILE` replacing
  `8 webhook secret(s) pulled read-only from the source DB this run`). But D80's stated OUTCOME is
  REFUTED: the literal `bp-export-v1` reddens the DEV leg at exit 1 (D82 was right, D80's
  "three greens" was wrong). The true vacuous window is a full-bundle-ONLY literal — the shape of a
  STALE or PARTIAL real ammo file. Why: the absurd poison fails loudly and the plausible one passes
  silently, so the climb must `export PDS_CONTROL_PG`, `unset PDS_AMMO_FILE`, and ASSERT the two
  strings `instrument control: PASSED` and the 8-secret provenance line in its own output.
  NOTE: the mandated D79 repro `PDS_CONTROL_PG=… sh -c '…'` is an EXPORT prefix and tests the wrong
  condition; the real shape is `sh -c 'PDS_CONTROL_PG=…; script'`.

- **PDS-D103 — RSS must NOT be extrapolated from the cheap leg; criterion 9 is
  UNMEASURABLE-BY-DESIGN on a headroom abort.** A paired n=8 interleaved design gives a mean diff of
  +31.7 MiB, 95% bootstrap CI [−21.5, +92.1] (spanning zero), sign test 4/8 — multiplier 0.60x, CI
  [−0.41x, 1.76x] — against PDS-D44's full-leg 2.53x delta: a 4.2x undershoot (543 MiB predicted vs
  2270 MiB measured). Mechanism: at 52 MiB the transient binary is absorbed by allocator slack (idle
  RSS alone swings 378 MiB over 135 s with zero requests) and at 897 MiB it is paid. The attempt
  counter and RSS sampler both sit AFTER gate (b), so a headroom abort leaves NOTHING to report.
  Why: "unmeasurable" is a stronger and more honest closing line than a confident wrong number, and
  the unaffordability finding stands on the code read plus D44 without it.

- **PDS-D104 — PDS-D70's 1 Hz sampler is under-specified; any RSS claim needs a paired idle control
  and a stated sampling rate.** Sampling at 8.4–8.7 Hz still could not resolve the dev export
  against a background moving 335.7 MiB per 10 s. Why: an uncontrolled RSS number on this box is
  noise, which is exactly the vacuous green the core rule forbids.

- **PDS-D105 — The ~941 MB single-binary export is the wave's HEADLINE ENGINE FAIL: FILED, not
  fixed.** `workspace_bundle.ex:259-276` accumulates every table's COPY bytes into one live `dumps`
  map; `archive.ex:56-57` writes a temp tar and `File.read!`s it back into a second full-size binary
  while the first is still an argument (`:27` admits ":erl_tar has no in-memory create");
  `workspace_controller.ex:157` then `send_resp(200, bundle)` once, with no lock or semaphore
  anywhere near the route (`:126` documents this in-code). ~2x-the-tar floor, ~1.9–2.2 GB for ONE
  request on a 3.9 GB box — architecturally unaffordable here, permanently. A working chunked pattern
  already exists in the same tree (`export_controller.ex:9-28`, `send_chunked` + per-line `chunk`).
  Why: the epic needs the VERDICT before it needs the fix, and landing a fidelity change underneath a
  running proof invalidates its census (the ruling D74 already makes about `shares`).

- **PDS-D106 — Single ownership is enforced at `/tmp`, not per-`BARKPARK_HOME`.**
  `FULL_ATTEMPTS_FILE=/tmp/pds-full-export/attempts` and `FULL_LOCK=/tmp/pds-full-export/lock`
  (`:125-129`) are machine-global and independent of `BARKPARK_HOME`, so a second agent with a
  different home shares the budget, the lock and the parked bundle. Concurrent wave-6 activity was
  observed live: three unowned memory-watch loggers running on guerrilla and fresh `/tmp/pds-*`
  artifacts from another session. Why: the wish's single-owner rule is load-bearing at the machine
  level, and the climber must claim its bp task before touching the store.

- **PDS-D107 — The scratch pointer dangles on macOS because the write path realpaths and the read
  path does not.** `new_scratch_home` canonicalises with `cd -P` (`scratch-target.sh:131`) before
  writing the pointer (`:268`), while `resolve_home` returns `BARKPARK_HOME` verbatim (`:139-147`),
  so the string compare at `:533` can never match under `/tmp` → `/private/tmp`. Reproduced in one
  second with a hand-made home, no boot needed. teardown still reports PASS, still releases both
  ports and still removes the root — the failure is loud-never-dangerous, and a later unguarded call
  dies with `scratch root … does not exist (already torn down?)`. Why: post-climb cleanup is the
  bite window, and the wave's "pin both vars explicitly" rule is necessary but does not fix it.

- **PDS-D108 — The deliverable's publication path is PROVEN, end to end, with residue removed.** A
  live create+publish+delete probe cleared the label spine, the tag registry and the dedup wall on
  the first try; `bp doc create <type> --file -` DOES honour stdin (a bare pipe without `--file -` is
  REFUSED with `piped stdin is unused; pass --file -`, exit 2, never silently ignored); and a `patch`
  mutation missing `type` returns 400 `malformed` (`mutations.ex:266` pattern-matches `id`+`type`,
  `:325` is the catch-all). Why: the deliverable dies at the last step otherwise, and three prior
  dedup rejections are on record for this epic's papers — choose a title that diverges from the six
  existing PDS paper titles.

- **PDS-D109 — Step 3's full-bundle control-leg grammar asymmetry is REAL but NOT exploitable; the
  harness freezes as it stands.** The dev leg's three-part guard (`:1491`, `:1495`, `:1496-1499`)
  has no equivalent on the full-bundle control leg (`:1560-1587`) — but the control's assertion
  polarity is `> 0`, and every garbage grammar collapses NF to 1 so `$idc`/`$it` evaluate empty and
  the count comes out 0, taking the `fail 3 "THE CONTROL DID NOT FIRE"` branch. Measured: CSV = 0,
  JSON-lines carrying a literal `ticket` = 0, zero-byte = 0, +1-column drift = 0, honest COPY TEXT
  = 1. The one spurious-non-zero path (EMPTY ammo against an NF<idc member) is unreachable because
  `doc_id` is hard-guarded non-empty at `:1431-1434`. Why: no PREFLIGHT fix is justified — but the
  transcript must state that the control is guarded by POLARITY, not by a grammar assertion, and
  that its failure message would misdiagnose a grammar change as an ammo problem.

- **PDS-D110 — Step 5's PASS line does not self-declare a disabled FAILDEMO; this is WAIVED, not
  fixed.** `${demo:+…}` at `:1887` contributes nothing when `PDS_STEP5_FAILDEMO=0` because `demo`
  is never assigned, whereas step 6's disabled note is a hardcoded literal inside its own `pass`
  call (`:1976-1982`). The default is `1`, the disabled state IS visible in the immediately
  preceding `info` line (undeletable under D87), and acceptance criterion index 5 already
  disqualifies the close outright for any transcript carrying
  `failure demo DISABLED (PDS_STEP5_FAILDEMO=0)`. Why: wave 5 surveyed this exact asymmetry (D76)
  and chose criterion-hardening over a harness patch — a stronger and more general mechanism than
  the wish's literal "in its own PASS line" phrasing.

- **PDS-D111 — Wave 6 is THREE preflight slices then ONE serial climb.** Round 1 = charter
  amendment + harness fixes + pointer fix, three disjoint files, dispatched in parallel. Round 2 =
  `pds-w1-crown-proof` alone, single-owner, strictly serial, after all three MERGE. Why: every
  harness edit must be on origin/main BEFORE the freeze (D100), and the climb is one job by
  construction — the sequenced-rounds law forbids dispatching it beside its unmerged dependencies.

### Wave 7 amendments — "The Swept Instrument" (decided 2026-07-20, paper `pds-wave-7-2026-07-20`)

- **PDS-D112 — THE HEADROOM GATE IS NOT THE BLOCKER; the premise that framed six waves is REFUTED
  by measurement.** Gate (b)'s own read path, sampled 260 times over 21.5 minutes against a WARM
  107-minute BEAM, cleared the 2200 MB floor in **227 samples (87.3%)**, longest continuous open run
  **640 s**, mean 2600 MB. An independent pre-existing sampler covering the identical window agreed
  at **225/259 (86.9%)** — 0.4 pp apart, two instruments. `sar` reproduces PDS-D92's four-day claim
  almost exactly (07/17 62.5% · 07/18 70.1% · 07/19 52.1% · 07/20 57.1% vs the charter's stated
  51.7–73.4%). Why: the four "all below" readings (1908, ~2087, 1979–2111, 2158) all land inside ONE
  depressed trough (01:00–02:11Z, which `sar` independently records as five consecutive below-floor
  10-minute samples). Four samples of one trough is ONE observation, not four. **The "measured
  window" design is DROPPED as over-engineered; PDS-D92's check-and-go is the climb procedure.**

- **PDS-D113 — THE REAL BLOCKER IS THE FROZEN INSTRUMENT'S OWN SAMPLER, and its fix is
  ENVIRONMENTAL, not a harness edit.** `pds-pull-proof.sh:1382` selects the sampled process with
  `pgrep -f beam.smp | head -1`. `-f` matches the FULL COMMAND LINE, so any process whose args merely
  contain the string matches, and `head -1` takes the LOWEST PID. Verified live at 02:36:39Z by three
  independent verifiers and again by Decide: `head -1` → **619341, a sampler shell, RSS 1844 kB**;
  `pgrep -o beam.smp` → **663029, the real BEAM**. Firing today prints *"beam.smp RSS peaked at
  1 MB"* into the honesty banner at `:1417` as the run's OWN measured peak, on the single
  unrepeatable attempt — precisely the confident-wrong number PDS-D103 exists to forbid, and
  unfalsifiable after the fact. FILED, never fixed (the freeze holds). Why the fix is legal: the
  defect fires only when a lower-PID matcher EXISTS, so sweeping the box until
  `pgrep -f beam.smp | head -1` **==** `pgrep -o beam.smp` makes the frozen sampler correct without
  touching one byte of it. The equality is asserted immediately BEFORE and AFTER the attempt and both
  readings go in the transcript. Corollary: the BEAM's PID is always RECENT (it respawns on every
  `api/**` auto-deploy), so ANY long-lived shell predating the last restart wins `head -1` — the bug
  is INTERMITTENT, which is worse than deterministic, and a plausible-looking number after the sweep
  is not proof the sampler was sound.

- **PDS-D114 — NO RSS FIGURE IS ENTITLED TO THE BANNER WITHOUT ITS SWAP CONTEXT.** The ">2x method
  divergence" (750–867 vs 256–438 vs 385 MB) is NOT a method divergence: six measurement methods
  (`ps -C`, `ps -p`, `VmRSS`, `statm`, cgroup `memory.current`, `memory.peak`) agree to within 0.5%
  at the same instant — 992188 kB on all four per-process methods. What varies is TIME, and the
  driver is SWAP: the same PID went 1,024,468 kB → 216,852 kB in 55 seconds while `VmSwap` rose
  51,624 → 874,760 kB. The stable invariant is **RSS + VmSwap ≈ 1.07–1.35 GB**. So RSS on this box is
  a swap-residency meter, not a memory-consumption meter, and the harness's 1 Hz RSS peak is a LOWER
  BOUND whose value depends on sampling phase. The transcript quotes the harness's figure verbatim
  AND annotates it as such, with `VmSwap` sampled alongside out-of-band. If the D113 sweep cannot be
  proven, the run must take the `:1419` branch and quote NO figure at all.

- **PDS-D115 — GATE (b) IS ANTI-CORRELATED WITH HEALTH, and this is a first-class verdict.**
  MemAvailable crosses the floor partly BECAUSE the BEAM is being swapped out: at 02:13:23Z
  VmSwap 859,944 kB / MemAvail 2,206,172 kB, and 7 of 8 samples PASSED the gate in exactly that
  state. So gate (b) opens most reliably in the condition where materialising a 941 MB single binary
  is MOST dangerous — the working set is on disk and the export must fault it all back. This is not a
  reason to fire or not fire (changing the criterion would be a harness edit), but the floor is not a
  safety property and the transcript must say so.

- **PDS-D116 — ONE `--all` INVOCATION, NEVER SPLIT.** Step 6's terminality is enforced by
  `canonical_order()` (`:2240`, silently re-sorts ANY `--only` list into ladder order and prints a
  NOTE) plus step 4's own PULL_BUNDLE-this-run guard (`:1665`, PDS-D97) — NOT by anything inside
  `step_6`, whose only cross-step precondition is `PULL_BUNDLE` (`:2003`, step 1's artifact). Both
  mechanisms are PER-INVOCATION. A split climb (bank the cheap ladder now, take 3/4 later on the same
  target) defeats both: step 4 would scan a step-6-clobbered target with nothing to stop it and print
  CLEAN off contaminated state. Severability still holds WITHIN one run — `run_steps` (`:2256`) is an
  unconditional loop with no short-circuit, so an aborted 3/4 still lets 5/6/7/8 execute.

- **PDS-D117 — THE RUNBOOK CARRIES THE INVOCATION; the harness must never self-heal it.** The
  harness pins `BARKPARK_HOME` / `PDS_SCRATCH_POINTER` per-invocation from a `date+$$` RUN_TAG
  (`:113-114`), while `pds-scratch-target.sh` mktemps its own root when they are unset
  (`:156-166`) — so two unpinned invocations allocate two different roots and every target rung
  ABORTs `env:scratch-target-not-booted`. Reproduced before booting anything. The danger is that this
  ABORT is INDISTINGUISHABLE at a glance from an honest environmental blocker, and the exit-2 BLOCKED
  result reads like a designed severable outcome. Both vars are exported to ONE shared short root
  (the harness's own `target_hint()` at `:296-299` prints the correct form), `PDS_CONTROL_PG` is
  EXPORTED, `PDS_AMMO_FILE` is UNSET. Correcting the runbook is legal post-freeze; teaching the
  harness to self-heal is not.

- **PDS-D118 — 0c AND 1 PASS COLD; THE WAVE INHERITS NO PREFLIGHT DEBT.** Run live on the frozen
  harness (worktree == origin/main == 1f15017bf, `git diff --stat` empty before and after) against a
  real booted scratch target: **2 PASS · 0 ABORT · 0 FAIL, exit 0**, attempt budget untouched. 0c
  printed `REPO IS barkpark:21980` asserted from INSIDE the BEAM — PDS-D64's wrong-database defect is
  refuted in practice and PDS-D94's `ensure_all_started(:ecto_sql)` fix holds COLD on a
  never-before-existing target. Step 1 exported 55,533,056 bytes / 34 blobs in 7 s and imported exit
  0 in 6 s, with the manifest grain assertion evaluating LIVE values (`profile='dev'
  dataset='production'`). Two bounds recorded rather than glossed: 0c's never-exported
  `PDS_PG_PASSWORD` defaults to `""` and holds ONLY because the scratch target's `pg_hba.conf` is
  `trust` — unexercised, not robust; and step 1's grain assertion has **no firing control**, the only
  asserting rung without one (contrast `:1584`, `:1768`, `:1893`), so "it matched" must never be
  written up as "the grain guard is proven able to catch a workspace-grain bundle."

- **PDS-D119 — #4686's ELIXIR RED WAS A FLAKE; THE FREEZE RESTS ON A SOUND INSTRUMENT — but the
  gate did not hold, and the transcript says so.** Re-run on the IDENTICAL sha `35b1f4f4c`:
  **11957 tests, 0 failures** (the original failed run: Sheets `EnginePerfTest` linearity 6.1x vs a
  6.0 ceiling). Main's own Elixir Test gate on the frozen HEAD `1f15017bf` is green. Causally
  decisive: #4686 changed **exactly one file**, `scripts/pds-pull-proof.sh`, and across the whole
  base→merge range NO `api/` file changed at all — `git log 08c5756bd..1f15017bf --
  api/lib/barkpark/plugins/sheets/` is EMPTY, and the engine has not been touched since #2044. A
  regression in code nobody edited is not a regression. But `main` is NOT branch-protected
  (`gh api …/branches/main/protection` → 404) and #4686 DID merge on a red: the honest sentence is
  "the gate did not hold and the red was empty", never a phrasing that implies it held.

- **PDS-D120 — D105's CITATIONS ARE CORRECT; ITS HEADLINE ARITHMETIC IS NOT.** The digest's claim
  that "all four file:line citations point at wrong functions" was itself produced from a STALE
  checkout — the same trap the wish warned about. At origin/main, `workspace_bundle.ex:259-276` is
  exactly the `Enum.reduce` building the live `dumps` map, `archive.ex:56-57` is inside `pack/2` (the
  EXPORT path, not `unpack/1` at `:66`), and `workspace_controller.ex:157` is inside `export/2` (not
  `import/2` at `:258`). **Do not "correct" them.** What IS wrong is the premise "a 3.8 GB box whose
  BEAM idles at 750–867 MB" — an arbitrary swap-phase sample (D114). D105 is re-derived from
  COMMITTED footprint (RSS + VmSwap), and the 941 MB base is cited to PDS-D41's live measurement,
  never implied to be derivable from the three source files. The mechanism claim itself stands
  unchanged and is confirmed by code: two concurrent full-size binaries, unchunked, with no Mutex /
  Semaphore / `:global` / rate limit anywhere near the route, beside an in-tree streaming
  counter-example at `export_controller.ex:15,22`.

- **PDS-D121 — THE DELIVERABLE'S TITLE IS "PDS Crown Transcript — The Cold BEAM, the Full Bundle,
  and the Line It Could Not Cross".** Scored offline against all seven live PDS papers with a faithful
  replica of `dedup_wall.ex`'s algorithm (title+tag tokens, its literal stopword set, Jaccard, refuse
  at ≥0.55 AND ≥3 shared): worst case **0.208**, under both the 0.30 advise and 0.55 refuse
  thresholds. Why it matters: PDS-D108 records three dedup rejections on this epic already, and the
  wall fires only at PUBLISH (`dedup_wall.ex:92`), never on a bare create — so a draft create proves
  nothing.

- **PDS-D122 — THE CLOSING RULE IS UNCHANGED, and D112 does not soften it.** The crown-proof task
  closes ONLY if rungs 3 and 4 pass WITH their controls FIRING off the one full bundle AND 1/2/5/6
  pass against a real booted target. A severable headroom ABORT of 3/4 remains an honest designed
  outcome that does NOT close the task. Why restate it: now that the gate is known to be open most of
  the time, the temptation shifts from "lower the floor" to "call a lucky partial the crown proof."

- **PDS-D123 — `bp search` bare is not a verb; the doctrine that depends on it silently fails.**
  SIX independent verifiers typed `bp search "<text>"`, got `unknown command "search"`, and fell back
  to grepping the tree — while standing doctrine says search Barkpark BEFORE grepping. The manifest
  noun is `search` with verb `query`: `bp search query "<text>"` returns 872 documents. Why it is in
  scope: `internal/cli/` is PDS's own lane, the dispatch site is one function
  (`cli.go:498` `usageSuggestNouns`), and a verb-less noun that has an obvious default is a
  one-line-class fix with a real test — an epic that measures its own honesty should not ship a
  research instruction that cannot be executed.

- **PDS-D124 — THE SORT IS *BOTH*, AND THAT IS THE FINDING.** The wish called rung 6's red an
  ENGINE defect; the crown transcript called it "a HARNESS BUG, not an ENGINE FAIL"; the filed task
  agreed with the transcript; wave 8's Strategize agreed with neither. All were partly right and all
  missed the same thing: the assertion IS vacuous at sha parity **and** there is a real engine gap.
  Two different defects sharing one rung. Wave 8 does not choose between them — it fixes both.

- **PDS-D125 — THE ENGINE GAP IS A SECOND, UNGUARDED BOOT-TIME WRITER: `TagRegistry`.** Proven live,
  not reasoned: with a `pull_provenance` stamp PRESENT, a sentinel written into the `tag` row was
  REVERTED in four of the eight guarded columns (`title`, `icon`, `visibility`, `fields`) while
  `owner_scoped`, `cors_origins`, `desk_groups`, `list_preview` SURVIVED — because
  `TagRegistry.schema_attrs/0` declares a five-key map and `Ecto.Changeset.cast/3` ignores absent
  keys, whereas `Plugins.Bootstrap.upsert_one/3` builds attrs via `Map.from_struct` and therefore
  carries all eight. Same stamp, same dataset, opposite outcomes: the difference is solely which
  writer touches the row. `schema_bootstrap.ex:60` fires `TagRegistry.register!("production")` BEFORE
  the try/rescue and before `register_all_schemas/0`; `tag_registry.ex` has no `Tenancy` alias at
  all; `bootstrap_guard_test.exs` has ZERO tag coverage. The premise every prior wave reasoned from
  — "Bootstrap is the only clobber path" — is simply false.

- **PDS-D126 — THE FIX GUARDS THE UPDATE, NEVER THE INSERT.** A naive copy of Bootstrap's
  `pulled_row` skip into `TagRegistry` would make core `tag` registration silently skippable on a
  stamped workspace — trading a clobber bug for a boot-closed-guarantee bug, since PDS-D12 puts
  TagRegistry outside the rescue precisely so a missing core `tag` schema can never boot a system
  whose publish wall is dead. Guard the UPDATE-of-a-drifted-row path only; INSERT-when-absent stays
  unconditional. That is the split `bootstrap.ex:207-211` already makes and that
  `"INSERT-WHEN-ABSENT is unchanged inside a stamped workspace"` already pins.

- **PDS-D127 — THE CENSUS IS 34 + `tag` + `metric` = 36, AND THE 36TH ROW IS `metric`.** Identified
  by diffing guerrilla's live `/api/schemas` (36 names) against a pristine scratch boot (35): the
  sole extra is `metric`, declared by no local plugin and therefore never visited by Bootstrap's
  `Registry.all()` walk. Behaviour by class, measured on BOTH legs of a real reboot: the 34
  plugin-declared rows SURVIVE stamped and REVERT cleared; `tag` REVERTS on both legs; `metric`
  SURVIVES FOREVER on both. That is the two-row gap no prior wave could explain about `rows=36`
  against 34 SKIP / 34 REGISTER.

- **PDS-D128 — THE SENTINEL IS SCOPED TO THE 34, AND SCOPE IS THE FIX RATHER THAN A DETAIL OF IT.**
  A table-wide sentinel — the natural reading of "write a sentinel into the eight guarded columns on
  the pulled rows" — reds leg A on `tag` and hangs leg B red FOREVER on `metric`, and the transcript
  would show a digest that moved with the stamp present, which reads exactly like "the guard failed."
  The clause is `WHERE workspace_id = <the id stamp_before resolved> AND dataset = '$SOURCE_DS' AND
  name NOT IN ('tag','metric')`, verified live to select exactly 34.

- **PDS-D129 — THE EXCLUSION LIST IS HAND-MAINTAINED, SO IT MUST BE TRIPWIRED.** No column in
  `schema_definitions` records which plugin declared a row (23 columns; none is a source marker;
  `dataset_id IS NULL` is an artefact of hand-insertion, not a discriminator), so the roster cannot
  be derived in SQL. The sentinel `UPDATE`'s `RETURNING` count MUST therefore be asserted equal to
  the SKIP count in the target's own `server.log`. That single cross-check is what converts a future
  guerrilla-only orphan, or a third core writer, from a silent vacuous green into a loud red. It is
  load-bearing, not belt-and-braces.

- **PDS-D130 — LEG B ASSERTS PER-COLUMN REVERSION, NOT WHOLE-DIGEST MOVEMENT.** The sharpest attack
  on the sentinel was that it could MASK a partial clobber behind an aggregate that happened to move.
  No partial-coverage path exists inside `bootstrap.ex` today — `schema_definition.ex:58-98` casts a
  strict superset of the eight in one `Repo.update`, pinned by committed probe S7 — but the
  per-column assertion costs nothing and is the only shape that stays honest if the cast list ever
  narrows. Masking was never possible at that layer; it was possible one layer out, at TagRegistry,
  which is why D125 lands first.

- **PDS-D131 — THE SENTINEL WRITES A jsonb OBJECT, NEVER A jsonb ARRAY.** `fields` and `desk_groups`
  are POSTGRES `jsonb[]` (`udt_name` `_jsonb`); Ecto's `{:array,:map}` is a different view of the
  same column. `fields || '[{...}]'::jsonb` resolves as `array_append` and appends ONE element whose
  value is a JSON ARRAY. The `UPDATE` succeeds silently (`UPDATE 35`, no error) and the break
  surfaces only on the NEXT read, as an `ArgumentError` inside `Repo.all` → `/api/schemas` 500 →
  `reboot_target` polls for 90 s → the rung ABORTS looking like an environment fault. Two-stage
  silence, and the most deceptive failure available to this edit. Append a bare object, and
  `coalesce` `fields` — the one nullable column of the eight. Proven in both directions on a scratch
  target: prescribed form → HTTP 500; corrected form → HTTP 200, all 35 rows served, digest moved.

- **PDS-D132 — `stamp_before` MUST CAPTURE THE WORKSPACE ID.** Today it reads
  `... WHERE settings ? 'pull_provenance' LIMIT 1` with no `ORDER BY` and never selects the id, while
  the guard-off `UPDATE` uses the same predicate with NO `LIMIT` — the read samples one arbitrary
  stamped workspace, the write clears every one of them. Benign at exactly one stamped workspace
  (verified: today there is one), but the sentinel cannot reuse a resolution that does not exist.
  Capture `id … ORDER BY id LIMIT 1` and feed that id to BOTH writes, closing the asymmetry in the
  same edit.

- **PDS-D133 — THE STAMP CHECK HOISTS ABOVE `digest_before`.** `digest_before` is taken at `:2016`,
  the stamp-validity check at `:2023`; sentinelling a slot that turns out to be unstamped would leave
  a corrupted target behind. Order becomes: read stamp → validate stamp → write sentinel →
  `digest_before`. `digest_before` then reflects the SENTINELLED state, which is what turns leg A
  from "the columns did not change" (true even with the guard deleted) into "the guard PRESERVED a
  drifted row across a reboot" — the hazard the guard actually exists for.

- **PDS-D134 — THE THAW HONOURS THE FREEZE AND CARRIES THREE FAIL-DEMOS.** PDS-D100 licenses a filed
  HARNESS BUG to be corrected in PREFLIGHT with the corrected assertion SHOWN still failing on the
  pre-fix condition. Wave 8 pays that three times: (i) sentinel step disabled → the corrected rung
  RED, proving the fix is load-bearing and not decoration; (ii) stamp cleared → leg A RED, proving
  the corrected rung can still catch a broken engine (clearing the stamp IS disabling the guard —
  there is no separate branch to invert, so no new flag ships); (iii) a planted lower-pid foreign
  `beam.smp` matcher → the OLD selector picks it, the NEW one does not. The edit makes every rung
  STRICTER; nothing anywhere is loosened.

- **PDS-D135 — THE SAMPLER FIX RIDES THE SAME PREFLIGHT.** `pgrep -f beam.smp | head -1` (`:1382`)
  can select a foreign low-pid process whose cmdline merely contains the literal, with a captured
  ~342x RSS under-read. Criterion 9 demands the run's OWN measured peak, and wave 7 could only vouch
  for it with a manual `head1 == oldest` bracket around the export. An instrument whose honesty
  depends on a human side-check is not the instrument this epic claims to have built. Different
  region of the same frozen file, one builder, one re-freeze.

- **PDS-D136 — THE INSTRUMENT RE-FREEZES AT THE PREFLIGHT MERGE SHA.** The freeze until now is blob
  `5a7978e03` / commit `1f15017bf` (#4686), byte-identical across waves 6 and 7 — established by
  comparing blob OIDs, never by an empty `--stat` (an empty stat is also what a broken pathspec
  prints). Wave 8's preflight merge supersedes it; the new blob OID is recorded in the wave log and
  the harness is FROZEN again from attempt 1.

- **PDS-D137 — RAISE `PDS_FULL_EXPORT_BUDGET` TO 2, DELIBERATELY AND ON THE RECORD.**
  `/tmp/pds-full-export/attempts` reads `1` against a default budget of 1, and the parked 1.03 GB
  bundle is STALE (`served_sha 15e057f83` = #4717 versus guerrilla's live `3f16c9f43`), so the
  zero-attempt reuse path cannot fire. As configured, a re-climb ABORTS rungs 3/4 before measuring
  anything and D122 forbids closing on that. The script's own `cond_c` message names the remedy
  verbatim: "raise `PDS_FULL_EXPORT_BUDGET` deliberately or reuse `$FULL_TAR`". This is a DIFFERENT
  knob from `PDS_FULL_EXPORT_MIN_MEM_MB`, which is never lowered — the standing law prohibits the
  second, not the first. Do NOT reset the attempts file and do NOT repoint `PDS_FULL_EXPORT_DIR`:
  both defeat the store's "one attempt, ever, per store" intent more quietly than the bump the code
  itself prescribes.

- **PDS-D138 — THE CROWN WAS FALSELY CLOSED BY THIS EPIC'S OWN LEAD, SEVEN SECONDS AFTER #4722
  MERGED.** `pds-w1-crown-proof` carried `lifecycle_status: done`, `closed_by: oc-lead` at
  `04:13:22Z`, with criteria 6 (rung-6 convergence) and 10 (PR merged) both `met:false` — while the
  builder's own now-line on that same claim read "Task stays OPEN per D122 — rung 6 unmet." D122 was
  violated because nothing could stop it: `close.ex:157-161` compares ONLY the epoch, never the
  holder identity, and close never reads `acceptance_criteria` as a precondition. The task is
  reopened and the incident is RECORDED rather than quietly repaired, because an epic that grades its
  own honesty does not get to launder its own lapse.

- **PDS-D139 — THE REOPEN RECIPE IS TWO STEPS, AND THE SECOND IS THE ONE THAT MATTERS.** Patching
  `lifecycle_status=open` and republishing yields a task that READS open but is NOT claimable and
  does NOT appear in `bp task ready` — `QueueGate.execution_class` (`queue_gate.ex:70`) returns
  `foreign_claimed` on the surviving dead `claim.worker`, and `bp task release` refuses with
  `not_in_progress:open`. The way out of that catch-22 is a same-worker re-claim (the sanctioned
  lease renewal, `claim.ex:348-356`, epoch 11 → 12) followed by `release`, which nulls
  `claim.worker`. Both steps are first-class verbs; no claim-block surgery. A worker following the
  old one-step note verbatim sees "open", concludes success, and then cannot claim — with a
  misleading `not_ready` as the only signal.

- **PDS-D140 — CRITERION 10 WILL NEVER AUTO-STAMP.** `close.ex:344` auto-flips only criteria carrying
  `merge_gate: true`; crown criterion 10's keys are exactly `[criterion, evidence, met]`. The LEAD
  must stamp index 10 explicitly with `--criterion-text` verbatim, or the crown sits at 10/11 forever
  waiting on an automation that cannot fire. Conversely, once all 11 read met the cmux Stop hook WILL
  close the task without anyone typing it — so no criterion is stamped speculatively ahead of a green
  rung.

- **PDS-D141 — SOBELOW REDS ON MAIN ITSELF, IS ADVISORY, AND PDS BUILDERS INHERIT IT.** main's own
  `.sobelow-skips` pins `router.ex:2505` while the code reports `:2530` — reproduced identically on
  CI's pinned 1.18.1/OTP 27.0, which rules out toolchain fingerprint drift and leaves genuine
  baseline staleness. `tenancy.ex` and `tenancy/workspace_bundle.ex` — PDS's own lane — already carry
  line-shifted findings. Reconciliation is CI-only and human-reviewed by design
  (`sobelow-baseline-reconcile.sh`: `never-auto-commit`). A PDS PR NEVER "fixes" this by editing
  `.sobelow-skips`.

- **PDS-D142 — WAVE-7 RESIDUE IS FULLY LANDED; THE PLANNED "LAND THE RESIDUE" SLICE DISSOLVED.**
  #4722, #4723, #4724, #4725 and the charter amendment #4701 are all merged; `origin/main` is
  `11a34dda6`. The wish's "three of four blocked on pr-task-gate" was true when written and false by
  Decide — the gate is green on all four, having been unblocked by an ordinary re-claim. The general
  lesson is the recurring one: verify merge state at Decide, never plan around a Strategize snapshot.

- **PDS-D143 — `pds-w3-shares-fidelity` STAYS DEFERRED TO WAVE 9.** It cannot red step 2
  mechanically — `shares` and `preview_token_jti` are raw E3 tables that never enter the
  document-type census — but it falsifies the frozen harness's own printed shortfall banner
  ("`tables/shares.copy` is 0 BYTES in the full bundle for exactly this reason"). Landing it before
  or during the re-climb would leave the crown transcript narrating something no longer true. It is
  admitted only after a green re-climb closes the crown.

- **PDS-D144 — EVERY WAVE-8 BUILDER IS `opus`.** Fable 5 is spend-limited this session. Not a quality
  judgment — a hard constraint carried from the wish (PDS-D38/D56).

### Wave 8 review amendments (2026-07-20, D145–D146)

- **PDS-D145 — THE SKIP TRIPWIRE COUNTS BOOTSTRAP'S WALK ALONE.** Two writers now log the phrase
  "skipping the content update": `Plugins.Bootstrap.skip_pulled/3` (one line per plugin-declared
  row, the number the roster is reconciled against) and `Content.TagRegistry.skip_pulled/2` (the
  core `tag` row, which the sentinel scope EXCLUDES by construction per D128). An unscoped
  `grep -c` therefore reads 35 against 34 sentinelled rows and reds ROSTER DRIFT on a healthy
  target — a merge-blocking false red manufactured by wave 8's own two slices, each correct in
  isolation. Measured with the real emitted Logger lines, not approximations: unscoped 2,
  Bootstrap-scoped 1. The assertion is now `Plugins\.Bootstrap: schema .*skipping the content
  update`; the TagRegistry count is REPORTED but NOT asserted, because `SchemaBootstrap.init/1`
  hardcodes dataset `"production"` and the count is legitimately 1 or 0 depending on `SOURCE_DS`.
  D129 is undiminished: a third core writer still surfaces as a leg-A clobber of a sentinelled
  row. `scripts/pds-schema-row-census.md` §5 had already specified this scoping — the doc caught
  the harness, which is the direction this epic has been trying to achieve.

- **PDS-D146 — THE INSTRUMENT RE-FREEZES AT BLOB `e219e97ccf7f33797c86a2b84d998d599b6bda31`.**
  Supersedes `d299b6214` (the wave-8 builder's commit) and `5a7978e03`/`1f15017bf` (#4686, waves
  6–7). Per D136 the PR body quotes the POST-MERGE OID, and the harness is FROZEN from attempt 1
  of the re-climb. Every red in that run sorts per D100 — HARNESS BUG (filed; a corrected
  assertion must be shown STILL FAILING on the pre-fix condition) or ENGINE FAIL (filed; fixed
  only by a wave explicitly chartered to fix it).


### Wave 9 decisions — THE RE-CLIMB, resumed (2026-07-20, PDS-D147–PDS-D177)

_PDS-D147–PDS-D159 were DECIDED by the wave-9 cycle that died before a single rung ran; they were
stranded in an unpushed commit against the ROTATING slot and are rescued here verbatim, re-prefixed._

- **PDS-D147 — A zero-export dress rehearsal is authorized as a narrow carve-out from D101.** D101
  forbids partial runs touching rungs 2–6 because of *cross-process target contamination*, not
  because partial runs lie. A rehearsal that (a) spends zero export attempts, (b) runs under its own
  `BARKPARK_HOME`/`PDS_SCRATCH_POINTER` root against its own scratch target, and (c) is never quoted
  as crown evidence cannot cause the contamination D101 exists to prevent. *Why: rung 6 has never
  been green against a real booted target, and discovering that with the irreplaceable export
  already spent is the one outcome the wave cannot recover from.*

- **PDS-D148 — Phase isolation is by EXPLICIT distinct exported roots, never by a fresh RUN_ID.**
  `pds-pull-proof.sh:113` is `export BARKPARK_HOME="${BARKPARK_HOME:-/tmp/pds-proof.$RUN_TAG}"` —
  the RUN_TAG default fires **only when the var is unset**, and the reclimb brief *mandates*
  exporting it. The claim that a fresh RUN_ID structurally forces a fresh target is **refuted in
  code**. *Why: without this, phase B boots into the target phase A's rung 6 deliberately clobbered,
  and criterion 1's "freshly booted scratch target" is silently false.*

- **PDS-D149 — Criterion indices are ZERO-BASED, and the crown's substantive rung is index 6.**
  `bp task stamp --help`: "N is the ZERO-BASED index — the first criterion is 0, NOT 1." So the
  reclimb's "criterion 10" means *PR merged to main*, and the rung-6 criterion the whole wave exists
  to pay was named **nowhere** in the closure arithmetic. *Why: this is D138's false-close re-armed —
  unmet criteria never block a close, so an unnamed criterion dies quiet.*

- **PDS-D150 — Closure requires THREE manual stamps across TWO tasks, after re-claiming the crown.**
  Zero criteria on either crown task carry `merge_gate:true`, so `close.ex:355` autostamps nothing:
  `pds-w1-crown-proof[6]`, `pds-w1-crown-proof[10]`, `pds-w8-crown-reclimb[8]`. Stamping is
  holder-only with an epoch fence and the crown is unclaimed (released epoch 15 by `reopen-prober`).
  *Why: the honest path is manual and forgettable; the dishonest path is a single close command.*

- **PDS-D151 — `--criterion-text` is a `bp task stamp` flag; `bp task close` uses `--set criteria:=`.**
  *Why: a lead typing `bp task close … --criterion-text` errors at the exact moment of closure.*

- **PDS-D152 — Crown criterion 6's stored wording predates the sentinel and is amended BEFORE any
  claim.** As stored it required only "an md5 digest is taken over the EIGHT columns … and the
  digest is unchanged afterwards" — literally satisfied by the vacuous pre-#4771 rung wave 8
  rejected; the word *sentinel* did not appear. Amending changes the task's `work_digest` and trips
  close's fence for any live claim, so it happens while the crown is unclaimed. *Why: pre-declared
  closure arithmetic is only a D122 substitute if the arithmetic actually encodes wave 8's
  correction.*

- **PDS-D153 — The sentinel is 7/8 effective, not 8/8, and no assertion in the rung can notice.**
  `visibility = 'private'` is a literal, not a flip, so it is a no-op on any already-private row —
  `ticket` (`tickets.ex:97`) is the one such row of the 34, against a schema default of `public`.
  Fail-safe (a no-op column reds leg B, never greens it) and currently masked because 33 rows do
  drift. There is also no pre-sentinel column digest: the write's effectiveness is asserted at ROW
  granularity only (`RETURNING count(*)`). *Why: the pass banner's "sentinelled in all eight guarded
  columns" is one column short of true — never repeat it verbatim as a proven fact.*

- **PDS-D154 — The freeze value is a GIT BLOB hash. Verify with `git rev-parse`, never `shasum`.**
  `git rev-parse origin/main:scripts/pds-pull-proof.sh` → `e219e97ccf7f33797c86a2b84d998d599b6bda31`
  (exactly D146's pre-named value); `shasum -a 1` on the same bytes → `b9eb6e3a…`. *Why: a verifier
  reaching for shasum at fire time concludes the freeze broke and burns the window on a phantom.*

- **PDS-D155 — The deploy threat is api/+internal/ volume, NOT the cloud/ GUI cycle.** `deploy.yml:72`
  gates the instance job on `^(api|internal|deploy|connectors)/`; `cloud/**` is absent, so a
  cloud-only merge can never move guerrilla's sha, and `scripts/**` is not in `on.push.paths` at
  all. Measured job-level truth (run-level counts overstate — skipped instance jobs still report
  success): 33 guerrilla deploys/24h, median gap 22.6 min, min gap **9 seconds**, only 68.8% of gaps
  exceed 10 min. *Why: the mitigation was right but aimed through the wrong lens — "pick a gap" is
  not safe-by-default and must be re-sampled at fire time, never reused from a survey.*

- **PDS-D156 — The attempt store is HOST-LOCAL and its state does not transfer between machines.**
  `FULL_DIR` is the literal `/tmp/pds-full-export` while `BARKPARK_HOME` is RUN_TAG-scoped. Reuse is
  provenance-gated (sha mismatch → "STALE … Not reused" → overwrite), never appended. *Why:
  `attempts=1` is a fact about one Mac; the climb host may read 0 — bump `PDS_FULL_EXPORT_BUDGET`,
  and **never** `PDS_FULL_EXPORT_MIN_MEM_MB`, which encodes a real OOM risk to the live content API
  and is the most tempting and most dishonest act available.*

- **PDS-D157 — Round 1 carries no builder for merges the lead already owns.** Waves 5, 6 and 8 all put
  the climb in round 2 and never reached it. Round 1's three PRs merged 06:11–06:12Z and are already
  live on guerrilla (served sha `65541e2d4` = the #4772 merge). *Why: repeating a wave shape whose
  observed failure mode is "round 2 is never reached" is the same wave again.*

- **PDS-D158 — `bp search query` EXISTS.** Ten surveyors across this cycle independently reported "no
  such verb" — all ten ran `bp search "…"` without the `query` noun. `bp search query "…"` returns
  918 documents. *Why: ten waves of lost prior-art coverage from one missing word.*

- **PDS-D159 — A rehearsal red is a FILED TASK and a wave that does not climb, never a harness edit.**
  The freeze holds under D134/D136/D146; any correction becomes a chartered wave-10 preflight slice
  with its own fail-demo. *Why: the licence wave 8 used (D100) exists only for a rung that ACTUALLY
  failed — thawing on suspicion breaks the exact rule that made wave 8's own thaw honest.*

_PDS-D160–PDS-D177 are this cycle's, bought with eight verifier runs against live ground truth._

- **PDS-D160 — Crown criterion 6's sentinel amendment is ALREADY LANDED; it is NOT re-written.**
  The field is now 2256 bytes and contains `sentinel` 4×, LEG A, LEG B, and citations to
  D130/D145/D146/D153. It was written at `2026-07-20T06:50:00.121968Z`; all 50 revisions at or
  before `04:47:32Z` carry the 1411-char vacuous wording. Both surveyor camps told the truth — the
  contradiction was a TIME-OF-READ artifact. *Why: re-writing correct text would clobber live
  citations to decisions that are themselves still off-main.*

- **PDS-D161 — The one real defect in the amended criterion 6 is the D153 parenthetical's INVERTED
  SCOPE, fixed by a one-clause patch, never a rewrite.** As stored it reads "visibility is a
  literal, hence a no-op on the already-private `ticket` row" — naming ONE exception. Measured on a
  booted target: the literal `private` write is a no-op on 31 of the 34. *Why: as worded, a reader
  dismisses a roster-wide hazard as a single row.*

- **PDS-D162 — Exactly THREE of the 34 declare public — `command`, `paper`, `task` — not two, and
  `task`'s is a bare Elixir struct literal.** `tasks/schema.ex:49` carries no `Map.get` default, so
  it cannot be flipped by JSON or config. Live count on a booted target: 4 public across 35 rows
  (`command`, `paper`, `tag`, `task`), 3 within the guarded 34. *Why: `pds-bl-legb-visibility-
  false-red` is comfortably DORMANT — going all-private needs three independent flips across three
  plugins, one of them an edit to Barkpark's own task substrate.*

- **PDS-D163 — Criterion 10 gets the protection, not criterion 6: it must not be stamped until
  rungs 3 and 4 are GREEN in THIS transcript.** No `merge_gate` key exists anywhere in the crown
  document (20 criteria parsed, 0 occurrences), and criteria 0–5 and 7–9 are already met from the
  wave-7 climb — so criterion 6 plus criterion 10 completes 11/11 and the next Stop event closes
  the task with nobody typing a close command. *Why: PDS-D138's false close, re-armed in a shape
  nobody has to type.*

- **PDS-D164 — The full re-anchor of criteria 0–9 is DROPPED.** The survey's heaviest question came
  back against it: criterion 6 was already amended, the round-1 engine fixes touch no rung except
  6, and the Stop hook cannot fire without criterion 10. *Why: the minimum viable form buys the
  same integrity at a fraction of the blast radius, and unstamping nine earned proofs would move
  the crown backwards from 9/11 to 2/11 for an aesthetic.*

- **PDS-D165 — The cmux Stop hook DEFEATS the work-digest fence by construction, so "amend while
  unclaimed" is right for a different reason than assumed.** `close.ex:182` short-circuits
  `check_work_digest` whenever `observed_rev` is non-nil, and `cmux_hook.go:245` ALWAYS passes a
  fresh rev. Proven live: a close rejected `doc_changed_since_claim` succeeded unchanged once
  `observed_rev` was supplied. *Why: no rule may rely on the fence catching a bad amendment — it
  protects a human closer and is skipped for the hook.*

- **PDS-D166 — `bp doc patch` on a task is EVENTUALLY CONSISTENT (~20–30 s) and the lag is
  invisible to EVERY read perspective, including the hook's own `?perspective=drafts`.** Measured:
  patch at t+0, published still stale at t+10 and t+20, landed between t+20 and t+30. *Why: an
  immediate read-back reads stale and invites a DOUBLE write to the crown ledger — poll until
  visible, never sleep-and-assume.*

- **PDS-D167 — MOVE 2 IS ALREADY PAID; the mutation rehearsal is NOT re-run.** Wave 8 produced both
  demos on unshipped copies (`.pds-demo1-nosentinel.sh`, `.pds-demo2-nostamp.sh`, deleted after
  capture), and this cycle independently ran the FROZEN harness `--only 1,6` GREEN against a fresh
  disjoint scratch target with both legs and both controls firing — leg A held digest
  `d7897ebddcf7af64a7612b2f458ead0f` at 34/34 sentinels intact, leg B moved to
  `c3b6f2d3950a9a9ec8f5f13e9c4243a7` wiping 0/34 — with the attempt store byte-identical `1` → `1`.
  *Why: the rehearsal's central risk, that it is expensive or spends export budget, is refuted by
  measurement rather than argument.*

- **PDS-D168 — The SQL stamp-clear DISCHARGES "the provenance guard inverted"; "inverted" is the
  wish's word, not the epic's.** PDS-D134 charters demand (ii) as "stamp cleared" and denies an
  invertible branch in the same sentence; `git log -S invert` shows D134's own commit introduced
  the word to this charter. On the merits stamp-clear is STRICTLY STRONGER: the guard is one
  boolean over one runtime input, so clearing the stamp exercises the whole chain while an
  inversion short-circuits it. *Why: a control that cannot prove its input is load-bearing is the
  weaker control, and an inversion additionally forces a 124-of-786-module recompile inside rung
  6's own 90 s reboot poll — a red that reads as "the target did not come back".*

- **PDS-D169 — cond_b, not the attempt budget, is the binding constraint, and the floor is ALREADY
  ~35 MB TOO LOW.** Eight live samples over six minutes: min 1345.15 / median 1788.07 / max 2017.89
  MB against a 2200 MB floor — 0 of 8 passed, the best 182 MB short, with 685/2047 MB swap already
  used. The wave-7 bundle's own meta gives 2483304 − 194228 kB = 2235 MB incremental demand, and
  `pds-export-cost-derivation.md:259` already records the floor as below the demand it gates.
  *Why: lowering `PDS_FULL_EXPORT_MIN_MEM_MB` would WIDEN a gate already too narrow to protect the
  LIVE content API — the integrity ban and the arithmetic agree for once.*

- **PDS-D170 — Scheduling is the ONLY honest lever on cond_b: the climb samples for a window up to
  a declared bound, then reports honestly either way.** Wave 7's committed transcript reads
  `(b) OK (2765 MB available, floor 2200 MB)` at 03:25Z, so windows are real, not hypothetical.
  *Why: a run that aborts rungs 3/4 is a legitimate, reportable outcome; a run that lowers the
  floor to avoid that is the single most tempting and most dishonest act available.*

- **PDS-D171 — The climber NEVER stamps `pds-w1-crown-proof`. It stamps only its own task; the LEAD
  stamps the crown off the committed transcript.** `pds-w5-criteria-reconcile` already established
  that the climber must not author the criteria it will be judged by. *Why: it removes
  self-attestation AND the ordering coupling between the ledger slice and the shot, which is what
  lets both dispatch in round 1 instead of deferring the shot for a fourth wave.*

- **PDS-D172 — Step 0b asserts ANCESTRY, not sha equality; the WORKTREE drifting ahead is a real
  failing direction too.** `pds-pull-proof.sh:655` equality is a fast path; `:660`
  `merge-base --is-ancestor DEPLOYED worktree` is the assertion. Guerrilla serves `65541e2d4`,
  origin/main is `c30d4a2d2` — 1 ahead, 0 code-ahead — so 0b passes on the ancestry branch today.
  *Why: the wish's restatement is looser than the code, and 0b never checks a dirty tree at all
  (zero `git status`/`--porcelain` calls), so an uncommitted engine edit is invisible to it.*

- **PDS-D173 — #4787 did NOT restart guerrilla, and `cloud/**` structurally cannot; the instance
  trigger is `^(api|internal|deploy|connectors)/`.** `c30d4a2d2` touches only a Studio charter, a
  measurements JSON and `scripts/studio-desk-measure.mjs`; `scripts/**` is not even in deploy.yml's
  trigger paths. Job-level cadence sampled fresh: last instance-job completion 06:19:14Z, ZERO in
  the strict last three hours, gaps ranging 33 s to 67 min. *Why: PDS's own lane (api/ + internal/)
  is the real restart risk, and any cadence number must be re-sampled at fire time.*

- **PDS-D174 — The 36/34 roster reconciles; ROSTER DRIFT will not red on bookkeeping.** #4772's
  committed map (§1 "34 + `tag` + `metric` = 36") was cross-checked two independent ways — against
  a tree-derived plugin roster at origin/main and against a live booted target — SET-IDENTICAL at
  34. Every `34`/`36` in the harness is a comment; the tripwire is purely relational
  (`RETURNING count(*)` vs the Bootstrap-prefix-scoped SKIP count). *Why: no slice may be spent
  "fixing" a roster that is already right.*

- **PDS-D175 — The harness is NOT RELOCATABLE: a bare copy cannot run.**
  `git show origin/main:scripts/pds-pull-proof.sh > /tmp/x.sh && bash /tmp/x.sh --only 1,6` dies at
  `:2546` on the missing sibling `SCAN_SCRIPT`, before any `--only` gating. *Why: every rehearsal
  recipe must run from inside a checkout holding the whole `scripts/` trio, proven byte-identical
  by `git rev-parse` — never `shasum` (PDS-D154, re-demonstrated live).*

- **PDS-D176 — The two fail-demos exist ONLY in the bp ledger, and that gap is closed by a
  COMMITTED RECORD, not by re-running them.** `gh pr view 4771 --json body | grep -icE
  'demo1|demo2|nosentinel|nostamp|FAIL-DEMO'` returns 0, and both scratch copies were deleted after
  capture. *Why: PDS-D100's precondition is about evidence being auditable, and re-running a demo
  that already reddened buys nothing a verbatim quotation does not.*

- **PDS-D177 — The charter lands in `.claude/workflows/bp-pds-charter.md` from a FRESH origin/main
  worktree; the rotating slot is never touched and local main is never pushed.**
  `bp-cloud-epic-charter.md` on origin/main belongs to the Studio Space-Priority Desk epic with
  rounds 3–4 in flight, and local main sits 12 ahead / 99 behind carrying five epics' charters.
  *Why: a wrong push costs another live epic its charter, and this is the third consecutive wave
  needing a charter rescue.*

### Wave 9 verdict — THE CROWN IS PAID ON RUNG 6 AND REFUSED ON cond_b (2026-07-20, PDS-D178–PDS-D189)

_These decisions were taken with the expensive climb ALREADY FIRED. Wave 9's planned composition
predicate was withdrawn, not authored — twelve verifier runs against live ground truth showed the
question it was built to answer had been settled by evidence three hours earlier._

- **PDS-D178 — THE COMPOSITION PREDICATE IS WITHDRAWN, NOT AUTHORED.** This wave was directed to
  pre-declare a three-legged rule (frozen harness blob identical · served sha identical-or-ancestor ·
  scratch boot recipe unchanged) that would rule whether a fresh rung-6-only run could be composed
  with wave 7's rungs 3/4. It is moot: commit `9e838499f` carries a full serial `--all` fired
  11:40:22Z under `PDS_RUN_ID=pdsw9-reclimb-20260720` off the frozen blob, `9 PASS · 2 ABORT
  (named, severable, environmental) · 0 FAIL`, with rung 6 GREEN inside it. Criterion 6 is payable
  from ONE UNSPLIT INVOCATION — exactly the shape D101 and D116 already demand — so no composition
  occurs and no rule is needed. *Why: authoring a composition law whose only effect is converting
  this wave's red into a payable crown is the self-attestation D171 exists to prevent, at the grain
  that matters. A rule that is not needed must not be written merely because it was planned.*

- **PDS-D179 — STANDING LAW ALREADY ANSWERED THE MOSAIC QUESTION, AND THE ANSWER WAS MOSAIC.** Had
  the cheap leg been needed, D101's heading ("anything touching rungs 2–6 runs as a full `--all`")
  and D116's title ("ONE `--all` INVOCATION, NEVER SPLIT") forbid it outright, and the frozen
  harness states the principle in its own bytes at `pds-pull-proof.sh:1694-1699`: *"a target
  populated by an earlier run is not evidence for this one."* Because `step_6` aborts unless step 1
  ran in the same invocation (`:2094-2097`), any rung-6 climb necessarily imports into a fresh
  target, so wave 7's rung 4 could never have been evidence for a wave-9 transcript. *Why: the
  epic's instinct that this was an open question was wrong; it was a settled question nobody had
  looked up. Correction to the wave's own framing: PDS-D138 is a mechanism-bug incident record, NOT
  a composition ruling, and must never be cited as if it says "mosaic forbidden."*

- **PDS-D180 — CROWN CRITERION 6 IS PAID, BY THE LEAD, OFF THE COMMITTED TRANSCRIPT.** Rung 6
  passed with its control firing in BOTH directions for the first time in the epic's life: leg A
  wrote 34 sentinelled rows, the stamped reboot preserved the digest unchanged and `34 of 34` rows
  still carried the drift; leg B cleared the stamp by asserted SQL (`RETURNING {"production": {}}`,
  so the `jsonb_set` no-op trap did not fire), the next boot moved the digest and `0 of 34` rows
  retained any trace, with all eight columns reverting per-column. Independently reproduced the
  same day by a separate `--only 1,6` run on a disjoint scratch target. *Why: this is the rung that
  three waves could not pay, and it is now paid on an unsplit `--all` with zero export attempts
  spent.*

- **PDS-D181 — QUOTE LEG B'S PER-COLUMN RESULT, NEVER THE BANNER PHRASE.** The raw PASS line at
  transcript `:789` says "sentinelled in all eight guarded columns." D153 already warns that phrase
  is one column short of literally true, and this wave MEASURED the shortfall: 31 of the 34 in-scope
  rows are natively `visibility='private'`, so the sentinel's write of `'private'` is a literal
  no-op on 31 rows and leg B's visibility control rests on **n=3**. Non-vacuous, but thin. Any stamp
  of criterion 6 quotes the per-column reversion result instead. *Why: the epic's own honesty rule
  is that a green must not claim more than it measured, and this is the exact overclaim D153 was
  written to stop.*

- **PDS-D182 — CROWN CRITERION 10 IS REFUSED, NAMED, AND PRECISELY LOCATED — cond_b.** Rungs 3 and
  4 ABORTED: `cond_b FAILED (1249 MB vs floor 2200)` and `(1224 MB)`, after 90 samples over 90
  minutes with 0 of 90 clearing and SwapFree DRAINING 1294 → 750 MB across the wait. Per D122 a
  severable headroom ABORT is an honest designed outcome that does NOT close the task. The refusal
  is recorded as a `--miss` attempt on criterion 10; `pds-w1-crown-proof` STAYS OPEN at 10/11.
  *Why: "we did not attempt it" is not a reason — this refusal has a measured one, and it is
  located on the exact rung and the exact gate that produced it.*

- **PDS-D183 — THE REFUSAL MUST NOT SAY "NO WINDOW EXISTS." IT SAYS THE BOX IS TOO SMALL.** The
  broad claim is refutable by our own data: 00:10→00:50Z today held ~40 minutes at min 2378 MiB.
  The true and stronger statement is that no window exists in the hours this epic operates in, the
  only clearing band is 00:00–03:00Z, and three of today's four longest windows PASS cond_b's 2200
  floor while FAILING the corrected demand — the precise trap of a run that clears the gate and
  cannot afford the export. The structural fact behind all of it: the box is 3819 MB total and
  `beam.smp` — the LIVE content API the floor exists to protect — holds ~1352 MB. *Why: a wave
  whose identity is that the verdict has a rule must not put a refutable claim on the ledger.*

- **PDS-D184 — THE NAMED cond_b LEVER IS REFUTED BY MEASUREMENT.** `pds-bl-guerrilla-ssr-leftovers`
  claims eight leftover `barkpark-site@*` SSR services "hold the memory cond_b gates." All eight are
  live; their combined `MemoryCurrent` is 22,245,376 bytes = **21 MB** against an 894 MB shortfall —
  2.4% of the gap. A second reading via top-RSS put the node process at ~490 MiB, which still lands
  at ~2220 MiB, clearing the 2200 floor and STILL short of the 2235.43 MiB demand. Reclamation is
  therefore not a fix and, taken alone, MANUFACTURES the D183 trap. That task is re-scoped to
  hygiene and must never again be filed as the crown's unblocker. *Why: this epic has now been
  burned twice by a memory premise nobody measured (D112 refuted six waves of pessimism; this
  refutes one wave of optimism). Measure the lever before naming it.*

- **PDS-D185 — THE EXPORT-COST ARITHMETIC IS 2235.43 MiB / ~35 MB, NOT 2231 / ~31.** A unit-mixing
  slip (a `/1000`-scaled baseline read of 194,228 kB as ≈194 subtracted from a `/1024`-scaled peak)
  put the wrong delta in four places across two committed files. Correct: 2,483,304 − 194,228 =
  2,289,076 kB = **2235.43 MiB**, so the 2200 floor sits **35.43 MiB BELOW the demand it gates**.
  The t=0 baseline is RULED to be 194,228 kB, the pre-fire single-shot: the sampler's first tick
  (230,072 kB) is taken at t≈+1s and already contains part of the export's own allocation, so using
  it subtracts part of the thing being measured, in the direction that flatters the floor. **Under
  ALL THREE candidate baselines the demand exceeds 2200 MiB** (2239.86 / 2235.43 / 2200.42) — the
  ambiguity moves the magnitude of the shortfall, never its sign, so the verdict states it
  unconditionally. Per D114 the 1 Hz peak is a LOWER BOUND, so 2235.43 understates. *Why: the
  refusal's central number must be right, and the correction makes the floor look WORSE, not better.*

- **PDS-D186 — CORRECTING THE TRANSCRIPT PREAMBLE DOES NOT THAW THE FREEZE.** The transcript states
  at `:9` that `"RAW RUN OUTPUT" onward is the harness's own bytes, unedited`; that marker is at
  line **376** and all four slips sit at `:243`, `:260`, `:321`, `:333-334` — every one in the
  human-authored preamble ABOVE it. The correction touches zero harness bytes and zero raw output.
  *Why: D100's freeze protects the instrument and its emitted bytes, not an operator's arithmetic
  error in the annotation, and leaving a known-wrong number standing to avoid touching a file is
  cargo-cult honesty.*

- **PDS-D187 — THE TAGREGISTRY GUARD GETS NO RUNG; SUITE-ONLY COVERAGE IS THE STANDING POSITION,
  AND `metric` IS NOT A COMPARABLE GAP.** The engine fix landed in wave 8 (`tag_registry.ex:126`
  calls `Tenancy.pulled_schema_row/2`) and is proven by **12** tests — not the 16 the wave brief
  claimed — with 32 across the three-file gate, 0 failures, including a real negative control and a
  fail-open test. Adding a rung mid-verdict-wave is a D100 thaw. Separately, `metric` has **no
  writer anywhere in the repository**: it is a live-only orphan declared by no local plugin (D127),
  so its zero coverage reflects the absence of a writer, not an audit failure, and it must not be
  folded into the same "add a rung" framing. Rung 6 already scrapes `tag_skip_count` and
  deliberately does not assert on it (D145) — that stays true and every future climb transcript
  says so. *Why: a gap that is real, low-severity and cheap to close later is a filed successor,
  not a reason to unfreeze the instrument during the wave that is issuing the verdict.*

- **PDS-D188 — THE CHARTER LANDS FROM `400d389ae` ONLY; TWO RIVAL BRANCHES ARE POISON.**
  `pds-w9-charter` @`ea909fb2c` carries byte-identical charter content on a different base and is
  referenced by no task — pushing both creates duplicate PRs. `charter-residue-2026-07-20` is a
  REGRESSION WEARING A RESCUE: its own `bp-pds-charter.md` is 1186 lines topping at D111 against
  main's 1663 at D144, and its commit `6525a61f0` — titled as a PDS charter amendment — touches
  ONLY `.claude/workflows/bp-cloud-epic-charter.md`, rewriting another epic's rotating slot 137
  ins / 175 del. Correction to the lead note: the clobbered occupant was **Task Lifecycle
  Visibility** (now Studio Space-Priority Desk), never Cloud GUI Remake. *Why: the rotating-slot
  trap at full strength, and a cherry-pick that reads as a rescue would have cost this epic 33
  decisions and another epic its memory.*

  > **Correction, 2026-07-20 (wave-9 review).** D188 named `400d389ae` as the landing vehicle when
  > it was written; the Decide phase then committed the SUPERSET — `7d2cf5a82`, D145–**D189**, 461
  > insertions, one file, pure additions — to the primary checkout's **local `main`**, where it sat
  > unpushed and invisible to every gate (the diverged-local-main trap). `400d389ae` (D145–D177,
  > 334 insertions) is now a strict SUBSET and is retired, not merged. The rescue was performed the
  > chartered way: `7d2cf5a82` cherry-picked onto a branch based on `origin/main`, verified as a
  > one-file pure-addition diff that touches no other epic's charter, and carried here. The
  > poison-branch ruling on `pds-w9-charter` @`ea909fb2c` and `charter-residue-2026-07-20` stands
  > unchanged — both remain unmerged. **Superseded by:** land the charter from `7d2cf5a82` only.

- **PDS-D189 — CRITERIA 6 AND 10 MUST NEVER BOTH READ MET BEFORE THE LEAD INTENDS AN IRREVERSIBLE
  CLOSE.** `hookStopClose` (`cmux_hook.go:193-252`) closes on all-met with an ownership-not-identity
  re-claim; `close.ex:157-163` fences on epoch ALONE and the server imposes no criteria precondition
  (unmet criteria are an advisory warning on an already-successful close). Criterion 10 carries no
  structured `merge_gate` key, so autostamp can never fire and it must be HAND-stamped — but nothing
  mechanical stops a premature manual stamp from auto-closing the crown on the next Stop event.
  This wave's REFUSAL leaves the hazard dormant; the ordering rule is now law regardless. *Why:
  criterion 10's fence is prose, not a guard, and it fails open — the only thing between a cheap
  green and a repeat of D138's false close is this ordering.*

## Roadmap

Wave 1 — data plane honest (COMPLETE; 8 slices; ROUNDS ARE LAW):

- R1 `pds-w1-export-406` (opus, S): x-tar 406 fix, both ends + honest negotiation tests.
- R1 `pds-w1-local-boot-media` (opus, L): KEK autogen · missing-blob 404 · BARKPARK_MEDIA_DIR ·
  path-preserving blob-write endpoint · allow_bundle_import config plumb + personal-local .env.
- R1 `pds-w1-dev-catalog` (fable, M): dev-profile partition (copy|deny|scrub_fields) +
  fail-closed dev sentinel + doc-type deny axis + every-copy-table-has-a-PK assertion.
- R1 `pds-w1-merge-import` (fable, L): `:merge` mode (root+E1+E2 ON CONFLICT (pk) DO UPDATE),
  empty-shell root adoption, fail-closed refusal, server-side allow_bundle_import guard.
- R2 `pds-w1-dev-export` (fable, L; after dev-catalog + merge-import): profile+dataset export —
  scrub-at-export, dataset WHEREs, triad roots, E3 exclusivity, additive manifest fields.
- R3 `pds-w1-provenance-guard` (opus, M; after dev-export): pull_provenance accessors + import
  stamp + response surface + Bootstrap clobber guard.
- R3 `pds-w1-pull-cli` (fable, L; after export-406 + local-boot-media + merge-import +
  dev-export): CLI `--profile/--dataset/--merge/--with-blobs`, streamed blob sidecar sync,
  provenance receipt, ServerKind warning.
- R4 `pds-w1-crown-proof` (fable, M; after provenance-guard + pull-cli):
  `scripts/pds-pull-proof.sh` + secret-scan tool + the LIVE crown proof (guerrilla
  default/production → scratch: green count diffs, served asset, zero-hit secret scan of bundle
  bytes AND target DB, re-run converges).

Wave 2 — THE HONEST CLONE (COMPLETE — all 6 slices merged 2026-07-19; 6 slices; all builders `opus` per PDS-D38):

- R1 `pds-w1-dev-export` (opus, L): profile+dataset export — deny SKIPPED at COPY time (D31),
  documents type-deny read from `dev_doc_type_deny/0` not `dev_action/1` (D28), the deny CASCADED
  to E2/E3 children (D27), the dataset arbiter resolved via datasets→projects→workspace (D29),
  additive manifest fields, `:full` byte-identical (md5 tripwire).
- R1 `pds-w2-scratch-harness` (opus, M): `scripts/pds-scratch-target.sh` — the run-proven isolated
  personal-local boot (D34's five traps + `BARKPARK_MEDIA_DIR` + admin-token mint + clean
  teardown), with a NEGATIVE CONTROL proving the media redirect is real.
- R1 `pds-w2-secret-scan` (opus, M): `scripts/pds-secret-scan.sh` — value-based (not column-name)
  scan over raw bundle bytes AND a target DB, anchored on `webhooks.secret` (D24), proven with a
  LOCAL seeded full-vs-dev positive control so no gratuitous 1.9 GB live export is spent (D31).
- R2 `pds-w1-provenance-guard` (opus, M; after dev-export): `pull_provenance` accessors + import
  stamp + receipt + the two-leg Bootstrap guard (D21) with the 8-column regression bar (D22).
- R2 `pds-w1-pull-cli` (opus, L; after dev-export): CLI `--profile/--dataset/--merge/--with-blobs`,
  streamed blob sidecar, provenance receipt, `ServerKind` warning.
- R3 `pds-w1-crown-proof` (opus, L; after provenance-guard + pull-cli + both R1 tools):
  `scripts/pds-pull-proof.sh` + THE LIVE RUN — raw-perspective census (D26), byte-scan ticket leg
  with a firing full-bundle control, migration parity precondition (D32), `:merge` pinned (D33),
  REBOOT between the two pulls (D23), honestly-scoped convergence (D30).

Wave 3 — THE CROWN PROOF (COMPLETE — round 1 merged + deployed 2026-07-19; 6 slices; PROOF-FIRST per D39; every builder opus
per D56):

- R1 `pds-w3-proof-harness` (opus, L): `scripts/pds-pull-proof.sh` authored as a FAILING
  executable specification — every step PASSES with run-time-derived numbers or ABORTS naming the
  merge it waits on; consumes (never duplicates) `pds-scratch-target.sh` + `pds-secret-scan.sh`;
  fixes the self-matching teardown orphan check (D53); reframes step 0 to deploy-provenance (D47);
  pre-declares the bare-slug E3 shortfall (D45); commits the first honest partial transcript.
- R1 `pds-w3-export-timeout` (opus, S): `run_copy_out` gets an explicit timeout mirroring import
  (D42) and a DBConnection failure becomes an honest `export_failed` envelope, never a bare 500
  (D43). Owns the EXPORT half of `workspace_controller.ex` only.
- R1 `pds-w1-provenance-guard` (opus, L): `pull_provenance` accessors + import stamp + receipt +
  the provenance-keyed Bootstrap SKIP with the 8-column regression bar (D21/D22), the COMMITTED
  7-scenario probe (D48), the corrected `bootstrap.ex` comment (D49), and the truncated-bundle 422
  (D50). Owns the IMPORT half of `workspace_controller.ex` only.
- R1 `pds-w1-pull-cli` (opus, L): extends the EXISTING 340-line `cloud_workspace_cmd.go` (D51) —
  `--profile/--dataset/--merge/--with-blobs`, streamed blob sidecar, provenance receipt,
  `ServerKind` warning, `empty_body`/`invalid_path` → exitValidation (D52).
- R2 `pds-w1-crown-proof` (opus, L; after the four R1 slices merge): THE LIVE RUN — a real
  guerrilla dataset pulled into a scratch box, per-type raw-perspective census, a served asset, a
  zero-hit value scan with the 8-webhook control FIRING, a rebooted convergence, and the 403
  refusal. The transcript IS the deliverable.
- R2 `pds-w3-shares-fidelity` (opus, M; after crown-proof establishes the baseline; renamed
  per D59 from the never-published `pds-w3-full-fidelity-shares-gap`):
  close D45 — bare-slug E3 rows under a cross-tenant-shared slug are silently dropped from a
  "byte-identical" backup.

Wave 4 — THE CROWN PROOF PAID (ROUND 1 COMPLETE — #4586-#4589 all merged 2026-07-19T22:24Z and
all four merge commits are ancestors of origin/main; 6 slices; every builder `opus` per D38/D56; the ladder
is FINISHED before it is CLIMBED — merging the wave-3 PRs greened zero blocked rungs):

- R1 `pds-w4-pull-dataset-flag` (opus, M): fix the silently-dropped `--dataset` on
  `bp cloud workspace export`/`import` (D61) WITHOUT letting ambient config silently narrow an
  unflagged export, add a `--source-server` surface so a CLI-taken bundle stops stamping
  `source_server: null`, and add the ARGV-LEVEL test the existing direct-call harness structurally
  cannot fail (D61's vacuous green).
- R1 `pds-w4-harness-rungs` (opus, L): the SINGLE owner of `scripts/pds-pull-proof.sh` (D57) closes
  every unwritten rung — step 1's two-command pull (D58/D63), step 2's target half (D66), step 5
  (D67), step 6 with its guard-disabled failure demonstration (D62/D65), step 0c's Repo targeting
  (D64), step 4's UNSCANNED hard gate (D68), the ONE shared full-export acquisition (D69/D70), the
  severability of the ladder (D71), and the closing re-pin rung (D72). Every rung's assertion is
  PRE-DECLARED in `--plan` before it is written.
- R1 `pds-w4-guard-test-eight` (opus, S): widen the escape-hatch test to the full 8-column revert
  (it asserts 3 of 8 today) so both polarities of the Bootstrap guard carry the same bar (D22).
- R1 `pds-w4-media-size-roundtrip` (opus, S): pin `media_files.size` surviving a bundle round-trip
  — the property step 5 depends on has NO in-tree test (D67).
- R2 `pds-w1-crown-proof` (opus, L; after the two R1 harness/CLI slices merge): THE RUN. One
  serialized owner of the scratch target, the one full export and the transcript. A FAIL is the
  interesting outcome and is never downgraded or re-run until explained.
- R2 `pds-w3-shares-fidelity` (opus, M; after the crown proof establishes the census baseline):
  close D45 per-table (D74), and split `delete_e3_dataset_keyed` so export and teardown stop
  disagreeing.


Wave 5 — CLIMB THE LADDER (DECIDED 2026-07-20; 6 slices; every builder `opus` per PDS-D38/D56):

- R1 `pds-w5-criteria-reconcile` (opus, S): rewrite criteria 6, 7 and 10 of `pds-w1-crown-proof`
  in the ledger per D75/D76/D77 — the climber must not author the criteria it will be judged by.
- R1 `pds-w5-harness-hygiene` (opus, M): close `ensure_bp`'s missing `--dataset` branch (D86),
  make `--plan` win in any argument position (D89), and tag the three uncited rulings the code
  already implements — `(PDS-D67)` on step 5, `(PDS-D70)` on the RSS sampler, `(PDS-D71)` on the
  severability abort.
- R1 `pds-w5-merge-mode-size-pins` (opus, M): land the two mutation-proven pins for
  `media_files.size` under `mode: :merge`, including step 1's exact dev+merge path (D85).
- R1 `pds-w5-ledger-merge-stamps` (opus, S): stamp the `PR merged to main` criterion on the 14
  done PDS tasks whose merge commits are confirmed ancestors of origin/main — `pds-w4-harness-rungs`
  is deliberately EXCLUDED (4/14; its other nine criteria belong to the climb).
- R2 `pds-w1-crown-proof` (opus, L; after the two R1 harness/ledger slices): THE CLIMB. One owner,
  one `BARKPARK_HOME`, one `PDS_SCRATCH_POINTER`, one ATTEMPT-counted full export. Transcript +
  evidence paper; the orphan `first-run.txt` retired in the same PR (D87).
- R3 `pds-w3-shares-fidelity` (opus, M; after the crown proof captures the census baseline):
  close D45 per-table (D74) and split `delete_e3_dataset_keyed`.

Wave 6 — lifecycle honest: `bp dev reset` over the Tenancy cascade; snapshot/restore round-trip
byte-identical; delete-reconciliation refresh; streamed bundle channel (task 24913529, unblocked
once wave 2 merges — PDS-D37).
Wave 7 — `bp dev` namespace + repo profiles (`bp dev up|pull|reset|promote`), single-verb pull.
Wave 8 — $29 dev tier via the existing billing gateway (Stripe wiring = human gate).
Wave 9 — agent-fleet sandbox proof: one destructive fleet wave against a PDS, zero writes to
guerrilla. G8 twin sync (secondary-unique identity reconciliation) rides behind W6/W7.

Backlog (filed as published child tasks of the epic): flat-verb `-w` honesty · streamed bundle
channel + import-body streaming · delete-reconciliation refresh · G8 secondary-unique identity
reconciliation · `bp dev pull` single verb · CI scratch-target HTTP round-trip job · per-member
savepoint import error honesty · **wave-2 additions:** Bootstrap S3 cross-tenant workspace theft on
nil-`dataset_id` rows · `/v1/data/counts` silently ignores `?perspective` (213 draft rows
invisible) · `docs/setup/personal-local.md` staleness (D34's five traps documented nowhere) ·
`plugin_doc_state` unreviewed `:copy` classification · pin the `webhook_deliveries` E2 INNER JOIN
as a security invariant · no admin-token mint path on a fresh `bin/barkpark up` box · `bp search`
verb absent from this CLI build. · **wave-3 additions:** `:full` drops bare-slug E3 rows under a
cross-tenant-shared slug (D45 — a backup that is not a backup) · the repo-wide 87-file `mix format`
drift as its own hygiene PR (D55) · `bin/barkpark stop` port-4000 fallback · the scratch pointer
file as one global path (D54).
· **wave-4 additions:** the export route has NO server-side serialization (D69 is a client-side
policy only) · `clean` import mode is ungated and answers an opaque 500 on a populated target
(D73) · the human import receipt prints `— rows across — tables` because the CLI decodes the
server's table MAP as an int · neither blob sidecar leg verifies transferred bytes against the
`media_files.size` it already holds · `memory.peak` cannot be reset below kernel 6.12 · the
export/teardown lockstep is prose-only and asserted by no test (D74) · the scratch pointer is one
global path and other sessions were observed using it concurrently (D54).


Wave 6 — THE CLIMB (IN FLIGHT; 4 slices; ROUNDS ARE LAW; paper `pds-wave-6-2026-07-20`):

- R1 `pds-w6-charter-amendment` (opus, S): land D91–D111 on origin/main so every builder and every
  future wave reads the same memory. `.claude/workflows/bp-pds-charter.md` only.
- R1 `pds-w6-preflight-harness-fixes` (opus, M): the LAST legal harness edit before the freeze —
  0c's `ensure_all_started` (D94), 0c's misattributing `else` (D96), step 4's cross-invocation
  guard + honest PASS line (D97), gate (d)'s fail-open (D98), the `0\n0` UNSCANNED parse (D99).
  Each fix carries a mutation proof: the corrected assertion still FAILS on the pre-fix condition.
  `scripts/pds-pull-proof.sh` only.
- R1 `pds-w6-scratch-pointer-canonicalize` (opus, S): teardown clears the pointer it wrote (D107).
  `scripts/pds-scratch-target.sh` only.
- R2 `pds-w1-crown-proof` (opus, L; AFTER all three R1 slices MERGE): the climb itself, under the
  freeze — check-and-go on headroom (D92), never a pounce (D93), `--all` only (D101), env asserted
  from the transcript (D102), RSS never extrapolated (D103). Deliverable:
  `scripts/pds-pull-proof.crown-transcript.txt` (append-only, D87) + a published Barkpark paper +
  every FAIL filed as a task rather than fixed away (D100).

Wave 7 — "The Swept Instrument" (DECIDED 2026-07-20; 4 slices, ALL ROUND 1, all opus per D38/D56):

- R1 `pds-w1-crown-proof` (opus, L): THE CLIMB. Sweep the box until
  `pgrep -f beam.smp | head -1` == `pgrep -o beam.smp` (D113), invoke ONE `--all` with pinned
  `BARKPARK_HOME`/`PDS_SCRATCH_POINTER`, exported `PDS_CONTROL_PG`, unset `PDS_AMMO_FILE` (D117),
  check-and-go on gate (b) (D112). Deliver `scripts/pds-pull-proof.crown-transcript.txt`
  (append-only), DELETE `scripts/pds-pull-proof.first-run.txt` in the same PR (D87), add
  `scripts/pds-crown-runbook.md`, publish the paper titled per D121.
- R1 `pds-w7-export-cost-derivation` (opus, M): re-derive D105 from committed footprint
  (RSS + VmSwap), re-verify its three citations at a NAMED sha, correct the stale-checkout claim.
  `scripts/pds-export-cost-derivation.md`. Read-only on guerrilla, single-shot reads ONLY.
- R1 `pds-w7-sheets-perf-flake` (opus, S): the linearity guard reds main on loaded runners with
  ~1.0–1.2x real headroom. `api/test/barkpark/sheets/engine_perf_test.exs`.
- R1 `pds-w7-bp-search-verbless` (opus, S): `bp search "<text>"` must not dead-end (D123).
  `internal/cli/`.

FILED, NOT BUILT (the freeze forbids touching the instrument):
`pds-bl-harness-pgrep-wrong-process` (D113) · `pds-bl-step1-grain-no-control` (D118) ·
`pds-bl-artdir-no-cleanup` · `pds-bl-gate-b-anticorrelated` (D115) ·
`pds-bl-deployed-sha-override-unimplemented` · `pds-bl-templates-deploy-noop`.

HELD BEHIND THE TRANSCRIPT: `pds-w3-shares-fidelity` — it moves the census baseline (D45/D74).


Wave 8 — pay the crown (DECIDED; 4 slices; ROUNDS ARE LAW; every builder `opus` per PDS-D144):

- R1 `pds-w8-tagregistry-guard` (opus, M): ENGINE — `TagRegistry.register_attrs!/2` stops clobbering
  a drifted row inside a pull-provenance-stamped slot; INSERT-when-absent stays unconditional
  (PDS-D125/D126). Differential test: same stamp, `tag` row survives all eight, absent `tag` row is
  still created.
- R1 `pds-w8-rung6-sentinel` (opus, L): HARNESS PREFLIGHT — step 6 gets a sentinel scoped to the 34
  Bootstrap-owned rows, per-column leg B, workspace-id capture, stamp-check hoist, plus the `pgrep`
  sampler fix; three fail-demos (PDS-D128..D135). Re-freezes the instrument at the merge sha.
- R1 `pds-w8-schema-row-census` (opus, S): the committed derivation of the 36-row taxonomy the
  exclusion list rests on — 34 plugin + `tag` + `metric`, per-leg behaviour, and why no SQL
  discriminator exists (PDS-D127/D129).
- R2 `pds-w8-crown-reclimb` (opus, L; AFTER `pds-w8-tagregistry-guard` + `pds-w8-rung6-sentinel`
  merge): one serial `--all`, fresh RUN_ID, `PDS_FULL_EXPORT_BUDGET=2`, the transcript deliverable,
  and `pds-w1-crown-proof` closed ONLY if every rung passes with its controls FIRING (PDS-D122).



**Wave 9r — THE RE-CLIMB, RESUMED (this wave, 4 slices, ALL round 1, file-disjoint; every builder
`opus` per PDS-D38/D56).** The premise correction wave 8 bought is carried; the shot has never been
fired, and the binding constraint turned out to be MEMORY, not budget.

| # | Slice | Task | Surface | Size | Model | Round |
|---|---|---|---|---|---|---|
| 1 | The one shot — sample for a cond_b window, fire ONE serial `--all`, report honestly | `pds-w9-the-shot` | `scripts/` transcripts | large | opus | 1 |
| 2 | Crown ledger fence — fix criterion 6's D153 clause, protect criterion 10 | `pds-w9-crown-ledger-fence` | bp ledger + `scripts/pds-crown-ledger-2026-07-20.md` | small | opus | 1 |
| 3 | Fail-demo provenance record — the two wave-8 reds become auditable on GitHub | `pds-w9-faildemo-record` | `scripts/pds-rung6-faildemo-record.md` | small | opus | 1 |
| 4 | Charter record — rescue PDS-D145–D159, land PDS-D160–D177 | `pds-w9-charter-record` | `.claude/workflows/bp-pds-charter.md` | small | opus | 1 |

Slice 1 owns the box, the pointer and the one attempt, and stamps ONLY its own task (PDS-D171).
Slices 2–4 never touch the box. All four file sets are disjoint by construction.

**Wave 10 — THE VACUITY VEIN** (filed as backlog now; licensed only by PDS-D100 once a rung
actually fails, or by an explicit charter thaw — see PDS-D159): seven undemonstrated-passive rungs,
rung 1's absent control, the stale `tag`-exclusion comment #4770 falsified, the TagRegistry guard's
missing rung, and guerrilla's leftover SSR services that eat the memory cond_b gates.

## Wave log

### Wave 9 2026-07-20 — "The Verdict Has a Rule" — R1 built + reviewed, grade A− (paper `pds-wave-9-verdict-2026-07-20`)

**The crown is resolved, and it is resolved in writing.** Four round-1 slices, all green, all
disjoint. `pds-w9-crown-verdict-record` is the wave: one committed document
(`scripts/pds-crown-verdict-2026-07-20.md`, 106 lines) that states criterion 6 **PAID** off
`9e838499f` and criterion 10 **REFUSED** on cond_b, with the crown left OPEN at 10/11 per D122.
Three waves of crown state that lived in claim now-lines and unpushed branches now lives in git.
Every one of the four judgment traps the brief named was actually handled, not gestured at: leg B is
quoted per-column with the `:789` banner flagged as an overclaim (31 of 34 rows natively private,
visibility control rests on n=3, D181); the refusal states the NARROW claim and names the
pass-the-gate-cannot-afford-the-export trap rather than the refutable "no window exists" (D183); the
structural argument is given (3819 MB box, `beam.smp` ~1352 MB, demand 2235.43 MiB, 0-of-90 +
0-of-36 + 0-of-7 with SwapFree draining 1294 → 750 MB); and the SSR lever is recorded REFUTED at
21 MB against an 894 MB shortfall (D184). The three non-actions each carry the check that proves
them.

`pds-w9-export-arithmetic` corrected a unit-mixing slip in four verified places — a `/1000`-scaled
baseline subtracted from a `/1024`-scaled peak — establishing **2,235.43 MiB** and a **35.43 MiB**
shortfall (D185), and added §6b.1 to the derivation with all three candidate baselines tabulated so
the ambiguity is shown to move magnitude and never sign. The freeze held and was proven POSITIVELY,
not by line arithmetic: the region below the RAW RUN OUTPUT marker hashes byte-identical before and
after (`e14967d5a…`), and `HEAD:scripts/pds-pull-proof.sh` is still `e219e97cc…` (D186).
`pds-w9-tagregistry-ruling` discharged `pds-bl-tagregistry-guard-no-rung` at 0/4 with a written NO
RUNG (D187), re-deriving rather than copying — it corrected the count to **12 tests, not 16**, and
corrected "two implementations" to **one predicate with two faces** (`pulled_schema_row/2` plus its
boolean wrapper), disposed of `metric` with a proof of ABSENCE, and honestly recorded that its own
brief's "done 4/4" is **4 of 6**. `pds-w9-close-payload-guard` pinned the close payload key sets as
a whitelist and was shown able to fail, with the mutation demonstrating that the existing hook tests
do NOT notice — which is precisely the gap D189 leans on.

**What the review changed.** One real defect: the arithmetic slice inserted 12 lines into the
transcript preamble and then cited the raw region by its PRE-shift line numbers, so all three new
citations in §6b.1 and the CORRECTION block pointed at unrelated text in the very file the same
commit shifted (`:636→:648`, `:778→:790`, `:900→:912`). Fixed on
`…the-export-cost-arithmetic-says-2235-43--1-r`. Everything else was already right.

**What stalled, and it is the wave's one structural weakness: nothing that matters is on
`origin/main`.** The verdict record's own evidence — the wave-8 transcript at `9e838499f`, which
carries the fail-demos — sits on an unmerged branch, and the charter carrying D145–D189 sat as
`7d2cf5a82` on the primary checkout's **local `main`**, unpushed and outside every gate. The Decide
phase classed both as lead work rather than builder slices, which is defensible, but it left the
wave's headline document citing a commit and forty-five decisions that a reader of `origin/main`
could not resolve. The review rescued the charter the chartered way (see the D188 correction above)
onto `…pds-w9-charter-and-wave-log-r`. The transcript still needs the lead: **merge
`loop-epic/the-crown-gets-paid-or-gets-named-one-se-0` FIRST, and never squash it** — a squash
re-writes `9e838499f` and silently breaks the verdict record's provenance line.

**Next wave.** The crown's sole remaining gate is `pds-bl-source-box-too-small-for-full-export` — an
infrastructure decision, not a code fix, and D184 forbids re-filing the refuted SSR lever as its
unblocker. The honest engine successor is `pds-backlog-streamed-bundle-channel`: chunk the export so
the demand stops being 2.25× the payload in one BEAM binary, at which point cond_b becomes
satisfiable rather than structurally unreachable. Secondary: `pds-w9-stale-2231-in-papers` (sweep
the retired figure out of Barkpark-side prose), and the Elixir-side counterpart to the close-payload
guard — an assertion that `autostamp_merge_gate` is unreachable with an absent or empty `landed`,
which the Go whitelist cannot pin.

### Wave 8 2026-07-20 — "Pay the Crown" — R1 built + reviewed, grade A (paper `pds-wave-8-2026-07-20`)

All three round-1 slices landed green and compose with zero conflicts (file-disjoint by
design; union 6 files, 1096 insertions). The crown itself is NOT paid — `pds-w8-crown-reclimb`
is round 2 and does not dispatch until these merge, which is the sequenced-rounds law working,
not a shortfall.

**The wave's real finding came from reading the two engine slices AGAINST EACH OTHER, and it
was merge-blocking.** `pds-w8-tagregistry-guard` gives `TagRegistry` a skip warning that
deliberately mirrors Bootstrap's wording — including the literal phrase *"skipping the content
update"*. `pds-w8-rung6-sentinel`'s roster tripwire grepped that phrase UNSCOPED and asserted
the count EQUALS the sentinel row count. But the sentinel scope excludes `tag` by construction
(PDS-D128), so on a stamped target the two numbers are **35 and 34** and rung 6 reds ROSTER
DRIFT on a perfectly healthy box. The first re-climb after both slices merged would have failed
for a reason manufactured entirely by this wave — and it would have looked exactly like the
roster drift the tripwire exists to catch. Neither builder could have seen it: both are correct
in isolation and they were built in parallel. Proven with the writers' REAL emitted Logger lines
rather than hand-written approximations: unscoped `grep -c` = 2, Bootstrap-scoped = 1.

**PDS-D145 — THE TRIPWIRE COUNTS BOOTSTRAP'S WALK ALONE, AND THE CENSUS ALREADY SAID SO.** The
right side of the `RETURNING == SKIP` assertion is `Plugins.Bootstrap: schema "…" …skipping the
content update` — Bootstrap's own `Registry.all()` walk, which is what the roster is reconciled
against. `TagRegistry`'s skip of the core `tag` row is counted SEPARATELY and REPORTED but NOT
asserted, because `SchemaBootstrap.init/1` hardcodes dataset `"production"`: the count is
legitimately 1 when `SOURCE_DS` is production and 0 otherwise, so asserting it would hard-code
an assumption the harness does not otherwise make. D129's protection is undiminished — a third
core writer still surfaces as a leg-A clobber of a sentinelled row. Note for the record: §5 of
`scripts/pds-schema-row-census.md` had ALREADY specified the Bootstrap-scoped grep. **The doc
was right and the instrument was wrong**, and the review aligned the instrument to the doc
rather than the reverse — the first time in this epic that the committed derivation caught the
harness rather than trailing it.

**PDS-D146 — THE INSTRUMENT RE-FREEZES AT BLOB `e219e97ccf7f33797c86a2b84d998d599b6bda31`.**
This supersedes the builder's `d299b6214`, which in turn superseded `5a7978e03`/`1f15017bf`
(#4686). Per PDS-D136 the PR body must quote the POST-MERGE OID. The harness is FROZEN again
from attempt 1 of the re-climb.

Two smaller review fixes. The TagRegistry guard's fail-open `rescue` — which the builder named
as "the branch most likely to matter in production and least covered here" — is now pinned by a
NUL-byte fault injection (`22021 character_not_in_repertoire`) that raises out of
`Content.get_schema/3` WITHOUT aborting the sandbox transaction, plus an assertion that the
fault is not sticky; that is the one forcing function available, since `pull_provenance/2`
guards every malformed shape it is handed. And `log_off` in step 6 was silently degrading: a
failed redirection leaves the pipeline's exit status at `tr`'s, so `|| printf 0` never fires and
the empty value makes `$((…))` restore the whole-file SKIP count the offset exists to prevent.

The census doc got a DATED CORRECTION rather than a silent rewrite: it is accurate at its anchor
sha `3be27f0fd`, but the sibling slice invalidates §2 in the same wave — post-merge `tag`
SURVIVES leg A instead of reverting on both, and the `grep -c "pull_provenance\|Tenancy"` → `0`
becomes evidence *of the defect* reproducible only at or before that sha. §1's arithmetic is
untouched and was independently re-derived at review (34 SKIP / 34 REGISTER / `diff` IDENTICAL,
`tag` and `metric` absent from both sets).

Verified honest rather than assumed: the 22 failures in the wider Elixir run are
`Tickets.ThreadTest` + `Tasks.Web.BoardLiveTest` and reproduce IDENTICALLY (22/22, same modules)
on clean `origin/main` — the wave contributes zero. `pds-w1-crown-proof` is correctly reopened
per PDS-D138/D139: lifecycle `open`, claim released so it is actually claimable, 9/11 with
criteria 6 and 10 honestly unmet.

Filed at review, none of it taken this wave: `pds-bl-legb-visibility-false-red` (leg B's
per-column assertion can false-red on `visibility` if the plugin roster ever goes all-private —
fails SAFE, so not re-climb-blocking, and the instrument is frozen),
`pds-bl-tag-schema-frozen-in-stamped-slot` (the honest cost of D126: a stamped workspace never
takes a `schema_attrs/0` update again, and D12's guarantee covers MISSING but not BROKEN), and
`pds-bl-scripts-md-budgets-unenforced` (these derivation docs declare byte budgets that
`check-doc-budgets.sh` does not gate — an unenforced gate that looks enforced is the same
vacuous-green shape as a rung that measures nothing while printing PASS).

**Next wave takes the crown.** Merge round 1 — `pds-w8-tagregistry-guard`, then
`pds-w8-rung6-sentinel`, then `pds-w8-schema-row-census` (order is cosmetic; they are
file-disjoint) — and only then dispatch `pds-w8-crown-reclimb`, whose four preconditions are
unchanged and whose closing rule is unchanged: close `pds-w1-crown-proof` ONLY if every rung
passes with its controls FIRING. `pds-w3-shares-fidelity` stays deferred until after a green
re-climb (PDS-D143). One thing the re-climb must expect that no prior wave did: after step 6's
guard-off control the target is clobbered, and a re-pull into a populated target is now known to
500 with a masked 25P02 (`pds-bl-repull-into-populated-target-500`) — harmless within a single
`--all` run, since step 6 is terminal and the next run boots a fresh target, but fatal to any
plan that re-pulls in place.

### Wave 8 2026-07-20 — "Pay the Crown" — DECIDED, 3 R1 slices building (paper `pds-wave-8-2026-07-20`)

The verify round settled the sort in a way nobody argued for, and it is the wave's whole shape.
The wish said ENGINE defect. The crown transcript said "a HARNESS BUG, not an ENGINE FAIL." The
filed task agreed with the transcript. Strategize agreed with neither. All three were partly right
and all three missed the same thing: **rung 6's assertion is vacuous at sha parity AND there is a
real engine gap, and they are different defects sharing one rung** (PDS-D124).

The engine gap is a SECOND unguarded boot-time writer. `TagRegistry.register!/1` calls
`Content.upsert_schema` directly, every boot, hardcoded to `"production"` — which is the harness's
own default `SOURCE_DS` — with no provenance check of any kind. Measured, not argued: under a
PRESENT stamp the `tag` row lost `title`/`icon`/`visibility`/`fields` and kept
`owner_scoped`/`cors_origins`/`desk_groups`/`list_preview`, because TagRegistry declares a five-key
map and Ecto's `cast/3` ignores absent keys. Under the identical stamp a Bootstrap-owned row
survived all eight. Same stamp, same dataset, opposite outcomes (PDS-D125). Zero existing test
coverage. The premise every prior wave reasoned from — one clobber path, one guard — was false.

The census closed too. The 36th row is `metric`: present on guerrilla, declared by no local plugin,
never walked by `Registry.all()`, and therefore never reverted on EITHER leg. So a table-wide
sentinel would red leg A on `tag` and hang leg B red forever on `metric` — scope is the fix, not a
detail of it (PDS-D127/D128). And the sentinel's own SQL had a trap the brief got wrong: `fields`
and `desk_groups` are Postgres `jsonb[]`, so the prescribed `|| '[{...}]'::jsonb` appends an array
INTO an array, the UPDATE succeeds silently, and the break surfaces one read later as a 500 that
`reboot_target` reports as a 90-second environment abort (PDS-D131). Both forms were run; the
corrected one keeps `/api/schemas` at 200 and moves the digest.

Two blockers arrived that had nothing to do with rung 6. The export budget is already spent (1 of 1)
AND the parked bundle is stale, so a re-climb fired as configured aborts 3/4 before measuring
anything — remedied by the knob the script itself names, `PDS_FULL_EXPORT_BUDGET=2`, recorded here
rather than typed quietly (PDS-D137). And `pds-w1-crown-proof` had been FALSELY CLOSED by this
epic's own lead seven seconds after #4722 merged, with criteria 6 and 10 unmet, while the builder's
own now-line said the task must stay open. `close.ex` compares only the epoch, never the holder, and
never reads the criteria — D122 had zero mechanical enforcement (PDS-D138). The reopen needed a step
the eleven-day-old note omits: the dead claim lease must be renewed and released, or the task reads
open and still cannot be claimed (PDS-D139).

The thaw is chartered and bounded: PREFLIGHT only, three pre-declared fail-demos, every rung made
STRICTER, re-freeze at the merge sha (PDS-D134/D136). `pds-w3-shares-fidelity` stays deferred to
wave 9 — it moves nothing the census asserts, but it falsifies a banner the transcript prints
(PDS-D143).


### Wave 7 2026-07-20 — "The Swept Instrument" — DECIDED, 4 R1 slices building (paper `pds-wave-7-2026-07-20`)

The verify round moved the ground under the wave's own direction, and the correction is the best news
the epic has had in seven waves: **the headroom gate was never the blocker.** 227 of 260 samples of
gate (b)'s own read path cleared the floor (87.3%), a second independent sampler agreed to 0.4 pp,
and `sar` reproduced PDS-D92 across four retained days. The four readings that framed waves 6 and 7
were four samples of ONE trough. PDS-D93's refutation of the deploy pounce also survived, with a
sharper proof than wave 6 had: the live restart curve shows a memory TROUGH first (t+15s → 1761 MB),
and the night's largest open window (785 s) had nothing to do with a deploy.

What replaced it is a defect nobody had looked for. Three verifiers independently found, and Decide
re-confirmed live at 02:36:39Z, that the FROZEN harness samples the wrong process:
`pgrep -f beam.smp | head -1` returns a 1.8 MB sampler shell, not the 200–990 MB BEAM. Firing today
would have written *"beam.smp RSS peaked at 1 MB"* into the honesty banner as the run's own measured
peak, on the one unrepeatable attempt. It is FILED, not fixed — and its remedy is environmental
(sweep the box until `head -1` == `pgrep -o`), so the freeze holds and the sampler still comes out
correct. That is the wave: the instrument gets swept, not edited.

Two contradictions closed on the way. The ">2x RSS method divergence" was never a method divergence —
six methods agree to 0.5% at the same instant, and what moves is swap (RSS + VmSwap ≈ 1.07–1.35 GB is
the invariant). And #4686's Elixir red, which shadowed the freeze, re-ran green on the identical sha
(11957 tests, 0 failures) against a PR containing zero Elixir.

Round 1 (4 slices, disjoint files, all `opus` per D38/D56):

- `pds-w1-crown-proof` → the climb + transcript + paper (`scripts/pds-pull-proof.crown-transcript.txt`,
  `scripts/pds-crown-runbook.md`, deletes `scripts/pds-pull-proof.first-run.txt`).
- `pds-w7-export-cost-derivation` → D105 re-derived from committed footprint
  (`scripts/pds-export-cost-derivation.md`).
- `pds-w7-sheets-perf-flake` → the linearity guard that reds main
  (`api/test/barkpark/sheets/engine_perf_test.exs`).
- `pds-w7-bp-search-verbless` → `bp search "<text>"` dead-ends six verifiers (`internal/cli/`).

The closing rule is unchanged (D122): the crown proof closes only if 3 and 4 pass with their controls
firing off the one full bundle AND 1/2/5/6 pass against a real booted target. A severable headroom
ABORT is honest and does not close it — and now that the gate is known to be open most of the time,
the temptation to call a lucky partial "the crown proof" is the one this wave has to refuse.


### Wave 2026-07-19 — W1 round 1 built + reviewed, grade A-

Round 1 (4 of 8 slices) built, adversarially reviewed, all gates green on final state:

- `pds-w1-export-406` → `loop-epic/bp-cloud-workspace-export-negotiates-x-t-0` (no fixes).
  x-tar rescue in AcceptBarkparkVendor mirrors the SSE branch; CLI Accept states both
  types; the #3012 200-always mock now enforces json-negotiability.
- `pds-w1-local-boot-media` → `loop-epic/personal-local-boots-fresh-media-honesty-1-r`
  (review fix 1d35bd47f: zero-byte blob push refused 422 `empty_body` — the mislabeled
  content-type trap the builder flagged was real). KEK autogen · missing-blob 404 ·
  BARKPARK_MEDIA_DIR · blob-push route · allow_bundle_import plumb.
- `pds-w1-dev-catalog` → `loop-epic/dev-profile-catalog-partition-copy-deny--2-r`
  (review fix 122db8e98: `search_intel_events` copy→DENY — raw user query text +
  actor_key/session_key is per-user behavioral telemetry; derived crystals/merge_patterns
  aggregates stay copy). DEVIATION ratified: PK census is 86/94 single-column (not the
  brief's 94/94); composite arbiters allowlisted (`plugin_doc_state`,
  `authoring_exemptions`) and pinned to live reality by a no-rot test.
- `pds-w1-merge-import` → `loop-epic/merge-import-mode-on-conflict-do-update--3`
  (no fixes). :merge convergence proven md5-stable across 2nd+3rd import; PDS-D9
  shell adoption + fail-closed refusal; guard tested both polarities; clean path
  byte-identical.

Ledger fix at review: the four deferred round-≥2 tasks were open with NO dependencies
(claimable early) — `content.dependencies` set + re-published; `bp task ready` now
strands them until deps merge.

Next: merge round 1 (rebase-check catalog.ex vs the Connectors epic first; lead closes
the merge-gated criteria) → re-verify export live on guerrilla → dispatch
`pds-w1-dev-export` (R2) → `pds-w1-provenance-guard` + `pds-w1-pull-cli` (R3, parallel)
→ `pds-w1-crown-proof` (R4, the live zero-secret pull proof). Debrief: paper
`pds-wave-2026-07-19`.

### Wave 4 2026-07-19 — "The Crown Proof Paid" — DECIDED, 4 slices building

All four wave-3 PRs merged AND deployed (D60): guerrilla's box HEAD, `.instance-deploy-last` and
origin/main are all `b7d6ce8ee`, and the LIVE slot's compiled `WorkspaceBundle.beam` carries
`export_copy_timeout` where the previous build carries none. The stale-box fear is closed by
measurement and the LOCAL-source contingency is retired.

But merging those four greened ZERO blocked rungs. Steps 1, 2-target, 5 and 6 of
`scripts/pds-pull-proof.sh` are ABORT STUBS — prose, a blocker name, no implementation — and steps
3 and 4 abort independently for want of a full bundle nobody takes. Running `--all` today yields a
transcript byte-similar to one obtainable before the wave started. So this wave FINISHES the
ladder, then climbs it: D61–D74 amend the charter, four round-1 slices close the rungs and the CLI
defect that would have made step 6 vacuous, and round 2 is the single serialized RUN.

Verification also killed three assumptions and one instrument: `--dataset` on
`bp cloud workspace export` is a silent no-op that leaves the Bootstrap guard inert for
`production` (D61/D62); step 0c's `mix run` targets the developer's own `barkpark_dev` (D64); the
census-carrier false-differential hazard is REFUTED but the unauthed-degradation and hardcoded-type
traps are real (D66); and `UNSCANNED` in the secret scan never gates, with zero-privilege tables
invisible even to the disclosure (D68).

Slices: `pds-w4-pull-dataset-flag` · `pds-w4-harness-rungs` · `pds-w4-guard-test-eight` ·
`pds-w4-media-size-roundtrip` (R1) → `pds-w1-crown-proof` → `pds-w3-shares-fidelity` (R2).
Paper: `pds-wave-4-2026-07-19`.

### Wave 5 2026-07-20 — "Climb the Ladder" — DECIDED, 4 R1 slices building

The wave opened believing its first job was to merge four PRs. Digest killed that: #4586-#4589
merged at 22:24Z and every merge commit is an ancestor of origin/main. `scripts/pds-pull-proof.sh`
— 2244 lines, 11 rungs plus `--plan` — is LIVE ON MAIN with ZERO hardcoded ABORTs.

A PREFLIGHT then bet nothing and learned everything: a live `--only 0a,0b,7,8` returned
**4 PASS · 0 ABORT · 0 FAIL**, pinning `version=0.2.25.1330 sha=0b4c677fd`, a 200/53,932,544-byte
dev export carrying `profile=dev dataset=production`, a live 403 `bundle_import_disabled`, and a
step-8 re-pin on the SAME sha with monotonic uptime. The one full-export ATTEMPT is genuinely
unspent (`spent so far=0 · on-disk bundle=absent`), the host holds no scratch pointer, and the
control fires end to end (`CONTROL EXIT=0`, FIRE/FIRE/CLEAN, throwaway DB dropped).

The climb is dispatchable — and four rulings had to be made before it could be climbed honestly.
Criterion 7 described a two-pull byte-identity test the shipped step 6 does not run (D75), so it is
rewritten rather than word-patched; criteria 6 and 10 grew the teeth their rungs already have
(D76/D77). The 0b deploy race is pre-ruled an EPOCH event, never an assertion to loosen (D78) —
at preflight the box sat one commit behind main with a loaded deploy pending. And two silent
vacuous-greens are now law: `PDS_CONTROL_PG` unset costs rung 4 its control while printing green
(D79), and a leaked `PDS_AMMO_FILE` makes all three of step 4's legs measure the literal string
`bp-export-v1` (D80).

Verification also refuted the wave's own most alarming premise. `merge_upsert` DOES carry
`media_files.size` — but nothing on main convicts a regression: excluding `size` from the
`DO UPDATE` set reddens exactly ONE test out of 25, and that one is new (D85). Healthy engine,
real coverage hole. Two smaller instrument holes are filed, not fixed mid-climb:
`ensure_bp` never checks `--dataset` while claiming it does (D86), and `--only X --plan` runs LIVE
(D89).

Slices: `pds-w5-criteria-reconcile` · `pds-w5-harness-hygiene` · `pds-w5-merge-mode-size-pins` ·
`pds-w5-ledger-merge-stamps` (R1) → `pds-w1-crown-proof` (R2, THE CLIMB, single owner) →
`pds-w3-shares-fidelity` (R3). Paper: `pds-wave-5-2026-07-20`.

Backlog seeded this wave: whole-process RSS is quoted without an ambient-load caveat · the harness
asserts no `lifecycle_status` CHECK/migration precondition (0 grep hits) and step 0b's sha proxy is
skippable on `--only` re-runs · each step 0a leaks ~51 MB into an uncleaned artifacts dir · the TLV
charter exists only on local main, in no PR, while its work PRs merged · a CI deploy run reported
SUCCESS for `7f8a0dd7f` while the box stayed at `0b4c677fd`.

### Wave 5 2026-07-20 — R1 built + reviewed, grade A− (paper `pds-wave-5-2026-07-20`)

Round 1 shipped FIVE slices, not the four Decide listed: `pds-w5-charter-amendment` was dispatched
alongside the roster above. All five gates re-run green on the reviewer's final state.

- `pds-w5-criteria-reconcile` → `loop-epic/the-crown-proof-is-judged-by-the-test-th-0` (no fixes).
  Crown-proof criteria 6/7/10 rewritten to the harness that actually shipped, BEFORE the climber
  dispatches, so the climber does not author its own rubric. Criterion 7 no longer demands a
  two-pull byte-identity test step 6 never performs (PDS-D30 rules byte-identity impossible);
  it now names the eight guarded columns, the `(dataset, name)` key and `PDS_STEP6_GUARD_DEMO=1`.
  Ledger-only — the branch carries an `--allow-empty` commit whose message IS the artifact.
- `pds-w5-harness-hygiene` → `loop-epic/the-proof-harness-stops-overclaiming-its-1-r`
  (review fix 987a22df1). `ensure_bp` now asserts the fourth flag its own prose claimed (`--dataset`,
  the D61 class); `--plan` wins in any argv position so `--only 0a --plan` no longer takes a real
  ~51 MB live export while printing "dry run"; three implemented-but-uncited rulings tagged.
  REVIEW FIX: a partial `--only` run closed with "RESULT: PASS — the whole ladder ran and held"
  after four of eleven rungs — the harness's own loudest overclaim, and the exact line a reader
  lifts into a transcript as the crown proof. It now reads `PASS (PARTIAL) … NOT the crown proof`.
- `pds-w5-merge-mode-size-pins` → `loop-epic/media-files-size-under-mode-merge-gets-t-2` (no fixes).
  Two tests pin `media_files.size` under `mode: :merge` — step 1's exact path. Mutation re-proven
  INDEPENDENTLY at review: excluding `size` from `merge_upsert`'s DO UPDATE set reddens exactly
  these two and nothing else (26 tests, 2 failures), while the sibling dev-profile file stays
  15/15 GREEN under the same broken engine. The coverage hole was real, not a story.
- `pds-w5-ledger-merge-stamps` → `loop-epic/fourteen-done-pds-tasks-stop-under-repor-3` (no fixes).
  Fourteen done PDS tasks now carry the sha proving their merge criterion, each re-verified three
  ways (ancestry, `gh pr view` mergeCommit compared programmatically, the PR body's own `Task:`
  line). `pds-w4-harness-rungs` deliberately EXCLUDED and left at 4/14 — nine of its criteria are
  "AUTHORED AND GATED, NOT RUN" and belong to the live climb. Ledger-only, already live.
- `pds-w5-charter-amendment` → `loop-epic/the-epic-s-memory-stops-being-three-diff-4-r`.
  Charter is contiguous D1–D90 at 942 lines; all 22 harness-cited D-numbers resolve (slash-expanded).

STALE-MERGE MYSTERY, CLOSED. The builder found #4494 merged carrying only D39–D74 and flagged as
its main blind spot that it could not tell a one-off from a systemic rebase-then-merge race —
asking the lead to audit other PRs. Resolved at review: `356aa57d5` was AUTHORED at 23:13:26Z,
twenty seconds AFTER the PR merged at 23:13:06Z, and GitHub's record shows headRefOid never left
`21c144f2f`. Nothing stale was merged; two concurrent agents raced, one merging while the other
was still writing onto the branch. NOT systemic — no PR audit is warranted, and the re-land onto a
fresh branch is the correct remedy.

WHAT DID NOT HAPPEN: the wish's headline job, `pds-w1-crown-proof`, did NOT run this wave. It is
round 2 by the sequenced-rounds law — it depends on `pds-w5-criteria-reconcile` (which rewrites
three of the criteria it is judged by) and `pds-w5-harness-hygiene` (which closes two holes in the
instrument it runs). Round 1 was entirely enablers. The epic's headline claim remains UNPAID and
the ladder still has never been run end to end; `pds-w1-crown-proof` stays `open` at 0/11.

NEXT WAVE: merge round 1 (the charter branch FIRST or with the hygiene branch — the hygiene harness
cites D86/D89, which exist only in the amended charter). Then dispatch `pds-w1-crown-proof` as a
single owner, strictly serial, one `BARKPARK_HOME` / one `PDS_SCRATCH_POINTER` / one ATTEMPT-counted
export. Only after its transcript lands does `pds-w3-shares-fidelity` go, because it moves the
census baseline (PDS-D45 — the manifest's `dataset_slugs` came back `[]`, re-confirmed live).

### Wave 6 2026-07-20 — PREFLIGHT round 1 built + reviewed, grade A− (paper `pds-wave-6-2026-07-20`)

Round 1 shipped THREE disjoint preflight slices — one file each, no collisions. All gates re-run
green on the reviewer's final state. THE CLIMB DID NOT RUN: `pds-w1-crown-proof` is round 2 by the
sequenced-rounds law and dispatches only after these three merge (PDS-D111). The epic's headline
claim remains UNPAID and the ladder has still never been run end to end.

- `pds-w6-charter-amendment` → `loop-epic/the-wave-6-charter-reaches-origin-main-d-0-r` (no code
  fixes; the `-r` branch exists only to carry THIS wave-log entry). D91–D111 + the wave-6 roadmap
  landed on origin/main, copied VERBATIM from local main's `32b8cded4` via `git show` — never
  re-authored (PDS-D90). Strict superset proven three ways at review: `--numstat` = `193 0`, zero
  `^<` lines with all hunks pure-append, and byte-identity with the source commit. D-numbers
  1..111 contiguous, zero duplicates; the four H2s are the only H2s; the Wave-log body was left
  byte-identical for Review to extend.
  THE GATE LITERAL WAS WRONG AND THE ARTIFACT WAS HEALTHY: Decide asserted 1187 lines, the truth is
  1186 (`993 + 193 − 0`). The builder corrected the ASSERTION and left the ARTIFACT alone, which is
  the load-bearing call — padding to 1187 would have committed an invented line into ratified
  memory, and the mutation demo shows the original gate PASSES a corrupted charter and FAILS the
  true one. Filed as `pds-w6-gate-linecount-offbyone`, not fixed away.
- `pds-w6-preflight-harness-fixes` → `loop-epic/the-last-legal-harness-edit-before-the-f-1-r`
  (review fix `35b1f4f4c`). THE LAST LEGAL HARNESS EDIT BEFORE THE FREEZE (PDS-D100). Five proven
  instrument bugs fixed, each with a mutation proof that the corrected assertion still fails on its
  pre-fix condition: D94 (`--no-start` starts no dep apps, so `Repo.start_link` died — proven live
  against a booted scratch target), D96 (a boot crash reported as "a sentinel RAISED", i.e. a FALSE
  ENGINE FAIL), D97 (step 4's missing `PULL_BUNDLE` cross-invocation guard + a PASS claiming a
  DEV leg that never ran), D98 (gate (d) failing OPEN on a GitHub 503), D99 (`grep -c … || echo 0`
  yielding `0\n0`, silently skipping the D68 gate). D109/D110 deliberately untouched.
  REVIEW FIX: the D96 branch routed BOTH no-`REPO IS` cases to one message asserting "the scratch
  Repo never connected (exit $rc)" — but with `rc=0` the probe ran to completion and printed
  neither marker, so the message named a cause it had not measured. That is the same defect class
  D96 exists to remove, one layer in. Split: `rc!=0` keeps the boot wording, `rc=0` reports
  UNDIAGNOSED and explicitly a HARNESS bug. All four polarities re-proven — critically, a GENUINE
  sentinel raise is still reported as a raise, so the fix cannot swallow an engine finding.
  REVIEW ALSO RESOLVED the builder's two open self-doubts with measurement rather than argument:
  real `gh run list` on an empty result exits 0 (4/4), so D98's fail-closed gate will NOT spuriously
  block the climb; and the step-4 guard's top-of-step placement is the ESTABLISHED idiom, since
  steps 5 and 6 place the identical guard at the top of their own step.
- `pds-w6-scratch-pointer-canonicalize` → `loop-epic/teardown-clears-the-pointer-it-wrote-the-2-r`
  (review fix `970c21527`). PDS-D107: the write path canonicalised with `cd -P` while the read path
  returned `BARKPARK_HOME` verbatim, so teardown's exact-string pointer compare could never match
  where `/tmp` is a symlink to `/private/tmp` — every run removed the root, printed PASS, and
  stranded a dangling pointer. One `canonicalize_path` helper now backs all three sites; both sides
  of the compare are canonicalised, which makes the non-clobber property hold STRUCTURALLY (it
  collapses two spellings of one root and can never merge two different roots) rather than by luck.
  REVIEW FIX: `canonicalize_path('/')` returned the EMPTY STRING (`${p%/}` strips the root's only
  character), and `''` does not match the `case "$home" in /) die "refusing to remove"` interlock
  guarding the `rm -rf` in `cmd_teardown`. Harmless in effect (`rm -rf ''` is a no-op) but a safety
  interlock that silently stops firing is not a safety interlock. Root now round-trips as `/`.

WHAT DID NOT HAPPEN: the wish's headline job, `pds-w1-crown-proof`, did NOT run — BY DESIGN, and it
stays `open` at 0/11. Wave 5 was an enabling wave; wave 6 round 1 was ALSO an enabling wave, and
says so plainly rather than dressing three instrument repairs up as a verdict on the data plane.
Two waves of enablers without a climb is the risk this epic must now retire.

NEXT WAVE: merge round 1 — the charter branch FIRST (both harness slices cite D-numbers that exist
only in the amended charter), then the two `-r` script branches, whose file sets are disjoint. Then
dispatch `pds-w1-crown-proof` ALONE: single owner, strictly serial, one `BARKPARK_HOME`, one
`PDS_SCRATCH_POINTER`, ONE attempt-counted full export, harness FROZEN from attempt 1. Run PREFLIGHT
first (`--plan`, `--only 0a,0b,7`, a scratch boot + `--only 0c`, a `bp` verb check, a source
MemAvailable read, a parked-bundle `.meta` check) — it costs zero export budget and decides whether
the climb dispatches at all. `pds-w3-shares-fidelity` STAYS HELD behind the transcript: it moves the
census baseline (PDS-D45).
