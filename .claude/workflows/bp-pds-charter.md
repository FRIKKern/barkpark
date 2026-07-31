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
  must stamp index 10 explicitly with `--criterion-text` verbatim, or the crown sits at 11/12 forever
  waiting on an automation that cannot fire. Conversely, once all 12 read met the cmux Stop hook WILL
  close the task without anyone typing it — so no criterion is stamped speculatively ahead of a green
  rung. **ARITHMETIC CORRECTED IN WAVE 15 (was "10/11" and "all 11"): the crown carries TWELVE
  criteria, indices 0–11** — census-confirmed `{met: 9, total: 12}` with 6, 10 and 11 unmet. A lead
  reconciling the finish line against the original wording mis-counts by one.

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

### Wave 10 — THE SCARCITY PREMISE IS RETIRED AND THE PREDICATE IS SELF-CONTRADICTORY (2026-07-20, PDS-D190–D203)

*Landed by the wave-10 REVIEW, not by a charter slice — wave 10 carried no charter-record builder, so
its five committed artefacts cited D190–D193 and D196 twenty-one times into a charter whose decision
log ended at D189. D190–D201 are the Decide phase's own twelve, transcribed from the wave Paper
`pds-wave-10-2026-07-20` (block `w10dec22`) and expanded with the evidence each one rests on. D202 and
D203 are new — findings the build round produced that the Decide phase could not have known.*

- **PDS-D190 — THE WINDOW IS THE BOX'S MAJORITY STATE, NOT A LOTTERY.** 1001 ten-minute `sar -r`
  samples across 2026-07-12..18, scored against D185's 2235.43 MiB demand: **791 clear (79.0%)**,
  median 2527 MiB (292 MiB of margin), p25 still clears, longest clearing streak 1050 minutes, worst
  FAIL streak 130 minutes. Every day cleared its majority; the worst cleared 60.8%. Evidence:
  `scripts/pds-window-availability-2026-07-20.md` §1, re-derived live off guerrilla, not copied.
  *Why: the six-point decay curve sampled one random phase per BEAM epoch. Nine waves built ever more
  elaborate pouncing machinery for a state the box is in four days out of five.*

- **PDS-D191 — PDS-D93 IS AMENDED, NOT REPEALED; CHECK-AND-GO, NEVER POUNCE, IS REAFFIRMED.** D93's
  *empirical* half is superseded in the POSITIVE direction — 107 isolated deploys mean +298 MiB, 84%
  positive, replicated across five isolation windows (n=87..9, +248..+426 MiB, 82–92% positive) — but
  its *mechanical* half stands untouched and cond_d kills the pounce independently. The aggregate runs
  the other way (deploy-dense days clear LESS); both are true, it is a Simpson's-paradox confound, and
  "drive deploys up before firing" is REFUSED. Evidence: `pds-window-availability-2026-07-20.md` §3.

- **PDS-D192 — NINE WAVES DIED ON BOOKKEEPING; THE PREFLIGHT IS THREE FREE LEGS.** (a) the worktree is
  0 commits behind `origin/main` — step 0b hard-fails when the served sha is not an ancestor of HEAD,
  and `fail()` only increments a counter, so a run fired in that state BURNS the export, greens rungs
  3/4 and STILL exits `RESULT: FAIL`; (b) `git rev-parse HEAD:scripts/pds-pull-proof.sh` equals the
  freeze blob `e219e97cc…` — **`git rev-parse`, never `shasum`** (D154); (c) the live served sha is an
  ancestor of HEAD, read over ssh NOW. Implemented inline in `scripts/pds-window-sentinel.sh` per D157.
  *Why: 0b fails and cond_c is exhausted right now, and neither costs a window to discover — the
  preflight had simply never been run. Wave 10 ran it and it was clean on the first try.*

- **PDS-D193 — THE FIRE PREDICATE HAS FOUR LEGS, AND THE THIRD IS NEW.** (i) `MemAvailable_MiB >= 2300`
  where MiB is **kB/1024, never kB/1000** (the `/1000` slip inflates the reading 2.4% and would let a
  draw ~56 MiB short read as clear); (ii) beam `VmSwap <= 100000 kB`; (iii) the `bp-site-build-*`
  running-unit listing is EMPTY; (iv) exactly one of `barkpark-slot@{blue,green}` reads active. The
  BEAM is sampled with `pgrep -o -x beam.smp`, **never `-f`** (D135). *Why: a single instantaneous read
  of one metric could never see the site-build channel or the D115 paging artefact.* **See D202 — as
  written, legs (i) and (ii) cannot both hold on this box.**

- **PDS-D194 — WAVE 9'S RUN ID CAN NEVER PAY CRITERIA 3 AND 4, SO CRITERION 6 MUST BE RE-EARNED.**
  Forced arithmetic: `pds-pull-proof.crown-transcript-w8.txt:322` and `:324` read ABORT
  (`cond_b FAILED`, 1249 MB and 1224 MB against a 2200 MB floor), and both criteria demand a control
  FIRING on the full bundle that run never took. Evidence:
  `scripts/pds-crown-fence-arithmetic-2026-07-20.md` §2, quoting both lines verbatim.

- **PDS-D195 — THE REFUSAL FLOOR IS BANKED WITH `--miss`, NOT A MET-FLIP ON CRITERION 11.** *Why: the
  met-flip removes the last auto-close brake and would leave a crown that closes carrying a fence field
  reading REFUSED.* Wave 10 honoured this: criteria 3 and 4 of `pds-w10-instrumented-climb` stand at
  `met=false` with empty evidence, and criterion 11 of the crown was never touched.

- **PDS-D196 — CRITERION 10'S WAVE-9-TRANSCRIPT CLAUSE IS A PREREQUISITE OF THE GREEN, AND THE APPEND
  ESCAPE IS REFUSED.** The stored row demanded rungs 3 and 4 be GREEN "in the wave-9 transcript" — a
  committed, self-declared APPEND-ONLY file recording both as ABORT forever. `pds-pull-proof.sh`
  contains NO output redirection to any `.txt` (verified: zero matches), so transcripts are
  hand-assembled per wave and a future green necessarily lands in a NEW file that cannot make a
  sentence about the wave-9 file true. The one letter-of-the-law escape — appending a later run into
  the wave-9 file — yields one transcript carrying TWO run ids for a reader to stitch, exactly the
  mosaic criterion 11 forbids, and is **REFUSED**. The clause now reads "in the transcript of the wave
  that pays this criterion"; nothing else in the row moved. *Why: the defect fails CLOSED, so it blocks
  only the green — which is why nine waves never hit it, and why a green window would have been spent
  for nothing.* Evidence: `scripts/pds-crown-ledger-w10-amendment.md`.

- **PDS-D197 — CRITERION 11 IS THE LEAST DURABLE OBJECT IN THE EPIC.** *Why: its own designated durable
  copy — `scripts/pds-crown-ledger-2026-07-20.md`, which declares "This file is the durable copy; the
  server's copy is not" — described an ELEVEN-entry array, so repairing the crown from that record
  deletes the fence silently: `bp doc patch` replaces the whole array, raises no error on a shortened
  one, and the fence's own job is to block an auto-close, so its removal surfaces as the crown closing
  MORE easily.* Fixed: that file's header now reads twelve and carries criterion 11's verbatim 1252-byte
  text, byte-identical to the server read.

- **PDS-D198 — RIVAL D (NARROW THE CONTROL BUNDLE) IS REFUSED ON TWO INDEPENDENT GROUNDS.** *Why: it is
  a literal thaw of the frozen acquisition path, and `production` is a shared slug whose fail-closed
  resolution drops the E3 tables.*

- **PDS-D199 — THE ENGINE FIX IS THE NAMED SUCCESSOR, SIZED, AND IT NEEDS A FENCE EXCEPTION.** *Why: the
  epic needs the verdict on the CURRENT engine before rewriting it, and the last leg edits a controller
  outside the tenancy fence.*

- **PDS-D200 — A MISSED WINDOW COSTS 20 SECONDS, NOT 90.** Measured warm with `api/_build` populated
  (290 MB / 71 deps): teardown 8.068s, teardown+up cycle 20.240s, later `up` 9.830s, first `up` of a
  session 32.742s where the extra ~20s is `mix deps.get` RESOLVING, not compiling. The old "~90s warm"
  was wrong by ~4.5x in the direction that made re-arming look expensive. Cold is a different regime
  entirely and exactly one thing decides which you are in: is `api/_build` empty (it is per-checkout,
  so a fresh worktree is always cold). A pre-booted SPARE drives the miss cost to ~0 — two targets
  provably coexist on disjoint HTTP and Postgres ports with the host dev server untouched, requiring
  BOTH `BARKPARK_HOME` and `PDS_SCRATCH_POINTER` pinned because `up` writes the one global pointer
  unconditionally. Evidence: `scripts/pds-scratch-target-cost-2026-07-20.md`.

- **PDS-D201 — THE WAVE-7 CLOCK IS SETTLED AT BEAM UPTIME 197s TO 473s.** *Why: the harness measured and
  printed it; every prior figure was inferred from CI timestamps whose lag varies by minutes.*

- **PDS-D202 — D193's LEGS (i) AND (ii) ARE JOINTLY UNSATISFIABLE ON THIS BOX, AND THAT MAY NOT BE
  RESOLVED BY LOOSENING.** 61 draws over 31 minutes: leg (i) 42/61, leg (iii) 39/61, leg (iv) 61/61,
  legs i+iii+iv together 38/61 — and leg (ii) **1/61**, with **0 of 61 satisfying (i) and (ii) at
  once**. Pearson r between `MemAvailable_MiB` and beam `VmSwap_kB` is **+0.677**, and a positive r
  between those quantities IS an anti-correlation between the two legs' satisfaction. The mechanism,
  which is the stronger evidence: on a 3820 MiB box at `swappiness=10` the headroom leg (i) reads is
  LITERALLY PRODUCED by the kernel swapping the BEAM out — RSS fell 736196 → 310116 kB while VmSwap
  rose 120120 → 511832 kB and MemAvailable climbed 2028 → 2719 MiB. VmSwap climbs monotonically from
  BEAM start and resets only on a slot restart, so leg (ii) is satisfiable only in roughly the first 18
  minutes after a restart — **precisely the interval D93/D190/D191 forbid entering.** The predicate's
  one open window sits inside the one region the charter bans. Re-derivation is
  `pds-w11-d193-leg-tension` (priority 0). **Raising `PDS_SENTINEL_SWAP_CEIL_KB` would green this in
  four seconds and would be a lie**; the sentinel hard-refuses a softened predicate by code, and that
  refusal is load-bearing, not decoration. *Caveat the finding states about itself: all 61 samples ride
  ONE BEAM pid across uptime 17:59–48:36, so the monotone-climb claim is n=1 at the level that matters,
  and the 164-build hour is an uncontrolled confound.* Evidence:
  `scripts/pds-pull-proof.crown-transcript-w10.txt` §4.

- **PDS-D203 — THE DEPLOY-DENSITY CORRELATIONS ARE CORRECTED TO r=−0.38 / r=−0.14.** The figures D190's
  survey ratified — daily r=−0.59, hourly r=−0.21 — are themselves the 07/12 `journalctl --since
  '8 days ago'` truncation artefact: that flag is relative to the invocation clock, so it cut 07/12 at
  22:41 and saw **3 of the day's 31** slot restarts, turning the week's highest-clearing day (99.3%)
  into an apparently deploy-free one — exactly the shape that manufactures the correlation. Recomputing
  with the truncated count reproduces −0.59 / −0.21 **exactly**, which identifies the source rather
  than merely suggesting it. **The sign survives, so D191's Simpson's reading and its refusal stand;
  the magnitude does not. Quote the corrected pair.** Evidence:
  `pds-window-availability-2026-07-20.md` §1b and §3b; open task
  `pds-w10-correlation-truncation-correction`.

### Wave 11 — THE ENGINE, NOT THE WINDOW (2026-07-20, PDS-D204–PDS-D216)

- **PDS-D204 — TRANSPORT AMENDED: `send_file/3` SUPERSEDES D199's `send_chunked`.** D199 and the root
  task's criterion 1 both name `send_chunked`; both are amended, on measurement, not preference. Probed
  against REAL Bandit 1.12.0 (not the Plug test adapter, which fakes the transport): `send_file` holds
  status 200, `content-type: application/x-tar`, the `content-disposition` attachment header, and
  `content-length` **exactly equal to `File.stat!` size** (3000037 == 3000037), body md5 identical, no
  `transfer-encoding`. `send_chunked` DROPS `content-length` and adds `transfer-encoding: chunked`.
  Content-Length is the load-bearing header — the frozen harness's acquisition line treats a
  `<1024`-byte body as a dead attempt and the CLI sizes its receipt from the stream. Bandit rides the
  real `:file.sendfile` syscall here because Caddy terminates TLS and `prod.exs` has no `https:` block
  (the SSL transport's hand-rolled `pread`+`ssl:send` fallback is never entered). **Two unpredicted
  facts that both cut FOR send_file:** Bandit GZIPS `send_resp` bodies when the client offers it
  (4,000,000 → 3,912 bytes, `content-encoding: gzip`), so today's CLI path pays a FIFTH uncounted
  full-size in-memory compression that `send_file` deletes; and the harness's `curl_src` never sends
  `--compressed`, so the 2235.43 MiB figure is uncontaminated — **the floor re-derivation MUST keep
  acquiring without gzip or it will not compare like with like.** The one regression is cosmetic:
  `send_resp` emits `vary: accept-encoding` and `send_file` does not. *Why: the successor must keep the
  header every client and the frozen harness actually depend on, and drop the one nobody reads.*

- **PDS-D205 — `export/2` KEEPS `{:ok, binary()}`; THE PATH SHAPE LANDS AS A SEPARATE ENTRY POINT.**
  D199's "ZERO changes to the 27 export and 20 unpack call sites" is FALSE as specified and the census
  is short by half: 1214-line `workspace_bundle_test.exs` is 27/20, but repo-wide it is **56 export +
  37 unpack across four test files** — D199 omits `workspace_bundle_dev_profile_test.exs` (23/15), the
  file that carries the PDS-D31 secret-leak proof, entirely. A bare `{:ok, path}` return was BUILT and
  RUN: **41 tests, 29 failures**, all one class (`InvalidBundleError` — a path IS a binary, so
  `import_bundle/2`'s `is_binary` guard passes and `extract!/1` fails on path TEXT). Preserving the
  binary contract and streaming the producer underneath was ALSO built and run: **41 tests, 2
  failures**, both producer-shape, **zero fidelity tests broken** — every md5-parity, row_count-parity,
  round-trip, merge-convergence and secret-scan assertion green, row counts IDENTICAL. So:
  `export/2` keeps `{:ok, binary()}` for its 56 test callers; a new public `export_to_file/2` returns
  `{:ok, path}` and `workspace_controller.ex` is its ONLY caller (there is exactly one non-test caller
  of `export/2` in all of `lib`). *Why: the measured cost of the two shapes is 29 edits versus 2.*

- **PDS-D206 — THE TWO TEST EDITS ARE NAMED, AND ONE OF THEM HAS A FORBIDDEN "FIX".**
  (a) `workspace_bundle_test.exs:867` traces `Repo.query!/3` by name and asserts `>10` COPY calls; the
  streamed producer never calls it, so it goes `0 > 10`. It must be **re-sited onto `Repo.transaction/2`**,
  because a 4-cell probe matrix proved PDS-D42 INVERTS under streaming: txn `:infinity` + stream
  `timeout: 300` survived 3002 ms (the stream-level `:timeout` is **INERT**), while txn `300` + stream
  `:infinity` died at 310 ms (the stream **cannot override** the transaction budget). A builder who
  moves `timeout: :infinity` onto the `SQL.stream` call ships a green suite and silently reinstates
  Ecto's 15,000 ms default in prod — the exact live failure D42 exists to close.
  (b) `workspace_bundle_dev_profile_test.exs:62` asserts `length(copies) == length(dev_copy_tables())`
  and goes **51 vs 17**, because `capture_queries` is TELEMETRY-based and `SQL.stream` emits one
  `[:barkpark, :repo, :query]` event PER FETCH. **The correct fix is `Enum.uniq` over the COPY sql
  strings before `length`. Relaxing the equality to `>=` is FORBIDDEN** — it would gut the PDS-D31
  skip-not-post-filter proof, whose whole content is that a denied table is never queried AT ALL.
  *Why: nobody named (b); a builder told "one edit, the trace test" would meet it and be tempted by the
  one repair that converts a real proof into a vacuous one.*

- **PDS-D207 — BYTE-IDENTITY IS THE DESIGN TARGET; MEMBER-LEVEL EQUIVALENCE IS THE GATE. D199's
  MANIFEST-**LAST** IS AMENDED TO MANIFEST-**FIRST**.** Proven on OTP 27 (erts 15.2.7.10):
  `erl_tar:open`+`add`-by-path is BYTE-IDENTICAL to today's `erl_tar:create` (`cmp` exit 0) **iff**
  four conditions hold — manifest FIRST (`manifest_LAST identical_to_create = false`, `cmp` differs at
  char 1); `{mtime,M},{atime,M},{ctime,M},{uid,0},{gid,0}` passed explicitly (without them the real
  stat uid=501 leaks in); the spill file's **mode is 0644** (mode is the ONE field with no `add_opt` —
  a 0600 spill diverges at byte offsets 105/106/153 — so `File.chmod(path, 0o644)` is mandatory); and
  the path is a **charlist** (an Elixir string is a binary, so `:erl_tar.add` silently archives the
  path TEXT as the member body — 115 bytes where the spill was 6000, no error). Holds for >100-char
  names, empty tables and default-umask spills. **BUT the gate may not be an unpinned two-export
  `cmp`:** today's engine is NOT self-reproducible — two identical-input `create` calls 1.1 s apart
  differ (`add1/4` stamps `mtime = os:system_time(seconds)`), and the manifest independently carries
  `exported_at`. Correcting the Vision's claim: the named tripwire hashes the MANIFEST's declared
  per-table md5 (`workspace_bundle_test.exs:355`), not the tar bytes, and `pds-pull-proof.sh` never
  hashes the bundle at all — byte-identity has always been asserted in prose and measured at member
  level. So the GATE is the root task's own criterion 3 (identical member names + identical per-table
  row counts + identical per-table md5) plus **ONE new pinned-mtime byte-identity test**.
  *Why: the achievable target and the honest gate are different objects, and conflating them would
  red the suite against the CURRENT engine.*

- **PDS-D208 — `/tmp` ON GUERRILLA IS EXT4, NOT tmpfs; THE SPILL DIRECTORY IS CONFIGURED, AND THE
  FREE-SPACE THRESHOLD IS DERIVED, NEVER BAKED.** The direction's sharpest attack is dead:
  `findmnt -T /tmp` → `/ /dev/sda1 ext4`, one physical disk (`sda1` 37.9G), `/tmp` is not a separate
  mount, `PrivateTmp=no`, and no `TMPDIR`/`TMP`/`TEMP` override exists anywhere in the boot chain
  including the live BEAM's `/proc/<pid>/environ`. `df -B1 /` → **14,251,499,520 bytes = 13.27 GiB**
  free (not "14G" — that is a round-up). RAM 3.7 Gi against disk 13.27 GiB is exactly the asymmetry
  THE SPILL exploits. Fresh COPY-time byte counts taken live today: **mutation_events 622,978,576 B**
  (61,614 rows, 9.02 s), revisions 498,201,323, documents 96,336,433, audit_events 19,282,039;
  `pg_database_size` = 942 MB, corroborating the ~941 MB framing. Peak transient disk under
  delete-as-you-add = bundle-so-far + largest single table ≈ **1.458 GiB**; a doubly-pessimistic bound
  where the discipline fails entirely is 1.989 GiB. Headroom ≈ 9.1x / 6.7x. **Disk is not the
  constraint.** But mutation_events has read 241 MB → 478 MB → 623 MB across this epic's own life, so
  a hardcoded guard would rot exactly as the frozen 2200 floor did: the preflight check computes its
  threshold LIVE from `pg_total_relation_size` over the fat tables, and the spill directory comes from
  configuration with a non-tmpfs default anchored under the release data dir plus a runtime assertion
  that the chosen path is not tmpfs. *Why: the one filesystem fact was load-bearing for all three
  rivals, and the one constant everyone wanted to bake is the one that provably moves.*

- **PDS-D209 — THE STORAGE HALF OF THE HONEST ENVELOPE WAS NEVER WRITTEN, AND IT SHIPS WITH THE
  SPILL.** Proven with a REAL `ENOSPC` (a 2 MB HFS+ volume with 4 KB free, `TMPDIR` pointed at it),
  not a mock: `:ok = :erl_tar.create(...)` does NOT raise `File.Error` — erl_tar RETURNS
  `{:error, :enospc}` and archive.ex hard-matches, so what reaches the edge is a **`MatchError`**,
  which escapes D43's deliberately two-clause rescue and renders verbatim
  `{"error":{"code":"internal_error","message":"unknown error",…}}` — **the exact string
  `workspace_controller.ex:146`'s own docstring says D43 eliminated.** This is the export half of the
  identical `=`-on-a-tuple defect PDS-D50 already fixed on the import side; pack was left carrying it.
  A rescue that adds only `File.Error` MISSES the dominant path. THE FIX: a typed
  `WorkspaceBundle.BundleIoError` (`"export_io_failed"`) raised by a `case` at every IO site, plus ONE
  new clause beside the DBConnection one returning the existing 503 envelope with reason
  **`"storage_unavailable"`**, distinct from `database_unavailable` because they are different retries.
  **A bare `rescue e ->` or a wide `File.Error` is FORBIDDEN** — D43's narrowness (`:214-217`) is the
  guarantee, not decoration. Also widen for **`Postgrex.Error` narrowed to `:query_canceled`**: the
  same configuration produced BOTH that and `DBConnection.ConnectionError` on different runs, so a
  streamed COPY timeout can escape D43 by a race. *Why: shipping the spill without this trades a memory
  bug for a NEW opaque-500 path on the exact resource the fix newly depends on.*

- **PDS-D210 — CLEANUP IS TWO-TIER, AND DISCONNECT IS SETTLED IN THE FAVOURABLE DIRECTION.** A real
  socket killed mid-transfer of a 300 MB `send_file` raised a **catchable `Bandit.TransportError`**;
  the `try/after` FIRED and the spill was removed. A brutal `Process.exit(pid, :kill)` did NOT run
  `after` and leaked the file. So `try/after` per spill file AND around the tar is SUFFICIENT for
  raise/throw/normal-exit/disconnect — and a **janitor is genuinely REQUIRED**, not belt-and-braces,
  because the scenario the spill exists to survive is the Linux OOM killer, which SIGKILLs the whole
  BEAM so no `after` clause anywhere in the VM runs. Today one stray tar leaks per crash; the spill
  makes it N-per-crash on the box whose disk headroom is the entire premise. No disk-space check and
  no janitor exist anywhere in `api/lib` (0 hits for enospc/disk_free/statvfs; one hit for
  `bp-ws-bundle`, the path construction itself). The janitor sweeps `bp-ws-bundle-*` and
  `bp-ws-spill-*` under the configured spill dir at application boot — a crashed BEAM's leftovers are
  collected by its successor, the only mechanism that works when `after` cannot run — and its
  staleness threshold must clear the longest OBSERVED export+transfer duration (wave-7 measured full
  exports at ~130 s server-side alone), never a guessed "5 minutes". *Why: one mechanism cannot cover
  both an unwinding exception and a SIGKILL, and the epic's own measurement says both happen.*

- **PDS-D211 — THE FLOOR LAW IS AMENDED, AND THE AMENDMENT IS STRICTLY STRONGER THAN WHAT IT
  REPLACES.** "NEVER lower `PDS_FULL_EXPORT_MIN_MEM_MB`" becomes **"THE FLOOR MUST NEVER SIT BELOW THE
  MEASURED DEMAND OF THE ENGINE ACTUALLY DEPLOYED."** That forbids wave 9's temptation absolutely,
  CONDEMNS today's 2200 (which sits 35.43 MiB below the measured 2235.43 MiB and therefore already
  violates it), and permits — requires — re-derivation when the engine changes. **Ordering is law:**
  the floor moves ONLY AFTER the spill is merged AND deployed, ONLY off a fresh peak-minus-baseline
  measurement against the deployed engine with a PDS-D104 paired idle control, in kB/1024. At no
  instant does a gate sit below the demand of the engine running. No thaw is required and none is
  permitted: `pds-pull-proof.sh:131` is a bare bash default with **zero validation**, no anti-loosening
  guard for this knob exists in code anywhere, the window sentinel's `check_predicate_integrity` guards
  a DIFFERENT private knob (`PDS_SENTINEL_MEM_FLOOR_MIB`) and disclaims this one in its own header, and
  D193 already set the env-only precedent by TIGHTENING it. The frozen blob stays
  `e219e97ccf7f33797c86a2b84d998d599b6bda31`. *Why: "never lower" was a proxy for the real invariant,
  and a proxy that condemns an honest re-derivation while permitting a floor already below demand is
  the weaker law.*

- **PDS-D212 — THE REACH IS DEFERRED TO WAVE 12, NAMED, NOT ATTEMPTED.** Three preconditions were
  reproduced by RUNNING the harness, not read. (i) Step 0b FAILS from the primary checkout — "the
  deployed sha bd2e72a897… is NOT an ancestor of the worktree e1c9ba13…" — but PASSES from a clean
  `origin/main` worktree ("deploy provenance holds … 1 commit(s) behind — 0 code, 1 docs-only"), so
  this is CHECKOUT HYGIENE, not a harness or engine defect. (ii) `/tmp/pds-full-export/attempts` reads
  **1 against a default budget of 1** — exhausted. (iii) The parked 1.03 GB bundle is **STALE**
  (`served_sha 15e057f83…` vs deployed `bd2e72a897…`), so the reuse guard refuses it and a fresh export
  would be taken. Raising `PDS_FULL_EXPORT_BUDGET` is explicitly pre-authorised by D137/D156 and has
  been executed twice already; resetting the attempts file or repointing `PDS_FULL_EXPORT_DIR` stays
  FORBIDDEN. **But the climb may not fire this wave regardless:** spending a sanctioned attempt against
  the engine this wave exists to replace buys nothing, and D211 forbids moving the floor before the new
  engine is deployed. The unsplit `--all` climb is wave 12's opening act, from a clean `origin/main`
  worktree, after the spill is merged and deployed and the floor re-derived. *Why: a named refusal is a
  win, and firing the climb early would burn the one knob the charter lets us turn.*

- **PDS-D213 — THE DUPLICATE TASK IS SETTLED AND THE CODE COMMENT IS REPOINTED.**
  `pds-bl-streaming-workspace-export` supersedes `pds-backlog-streamed-bundle-channel` for the EXPORT
  half: same parent (`task-2ac1f95237c4a8e5`), same defect, but the younger filing cites the current
  line numbers, carries `wave_paper`, and is named by the wave Paper's own opening line as this wave's
  root. The older task is RE-SCOPED to the IMPORT half only (D214) rather than closed, because that
  half is real and unfixed. `workspace_bundle.ex:636`'s comment — which still names the older slug, as
  does D199 — is repointed by the engine slice. *Why: two open tasks on the same lines is a licence for
  two PRs to collide.*

- **PDS-D214 — THE IMPORT PATH STAYS IN-MEMORY, ON AN HONEST BASIS, BECAUSE THE OLD BASIS WAS FALSE.**
  The justification that "wave 7 proved a ~941 MB import affordable on the scratch target" is
  FACTUALLY WRONG: **no wave has ever imported a full bundle anywhere.** Every recorded import — step
  1's export/import pair, step 6's reboot re-import — uses the `--profile dev` scrubbed bundle at
  51.6–55.9 MB, roughly 1/17th. The full bundle is `curl`-ed to a file and only ever tar-extracted on
  disk for byte/row scanning; `import_bundle` is never called on it. The out-of-scope call SURVIVES on
  a weaker, honest basis: the scratch target runs on the LOCAL 16 GB Mac (`hw.memsize` =
  17,179,869,184), never on guerrilla, with no concurrent live traffic and no lock-free public route.
  Fixing it would double the blast radius on exactly the functions D37 warned about, for zero movement
  on cond_b. FILED, not fixed. *Why: the call is right and the reason given for it was invented — the
  epic records which is which.*

- **PDS-D215 — `workspace_bundle_dev_profile_test.exs:265` IS A PRE-EXISTING LATENT FALSE-GREEN AND IT
  IS FIXED THIS WAVE.** The file's moduledoc (`:5-9`) asserts "every deny assertion is paired with a
  `:full`-profile positive control so a vacuous green … is impossible." **That is false at :265** — the
  one unguarded raw `refute` on a bundle value in the entire suite. Demonstrated by construction: a
  mirror of :265 against a bundle that provably carries the secret gave "1 test, 0 failures" while
  `File.read!(bundle) =~ secret` ALSO passed. L33/L36 are safe precisely because L33 is a positive
  control that would fail loudly. One line to add the control; the wave walks directly past it.
  *Why: a file that documents an anti-vacuity discipline it does not actually keep is worse than one
  that claims nothing.*

- **PDS-D216 — THE PAIRED IDLE CONTROL IS A PREREQUISITE OF THE POST-FIX NUMBER, NOT A NICE-TO-HAVE.**
  The canonical 2235.43 MiB (2,483,304 − 194,228 kB, D185's t=0 ruling, kB/1024) came from a 1 Hz `ps`
  sampler that satisfies only the STATED-RATE half of D104 — `grep` for "idle"/"paired" in
  `pds-pull-proof.sh` returns ZERO hits, and `pds-bl-rss-instrument-paired-control` is still 0 of 5.
  The root task's own criterion 2 demands "a paired idle control per PDS-D104". So the measurement
  lands as its OWN slice that builds the paired-control instrument beside the frozen harness (never
  inside it) and re-derives 2235.43 MiB's successor by the same procedure plus the control. The 1 Hz
  sampler reports a LOWER bound (D114) — it understates, which is the safe direction for a floor.
  `pgrep -o -x beam.smp` stays mandatory (D135: `-f` self-matches the ssh command line, `head -1` is a
  PID sort not an age sort; one captured run under-read by 342x). *Why: "same procedure as the number
  it must beat" and "satisfies the task's own acceptance bar" are two different claims, and the wave
  must not silently substitute the first for the second.*

- **PDS-D217 — THE LOW-PEAK THESIS SURVIVES, AND THE NUMBER THAT SAVES IT IS NEW.** The sharpest attack
  on wave 12 was that `revisions` (498,201,323 B, **no row count anywhere in this charter**) might hold
  ≤500 rows and so stream as ONE chunk under Postgrex's `max_rows` default, putting the old regime back.
  Measured live on `barkpark_prod`: **revisions 48,363 rows, mutation_events 62,441, documents 3,300**
  (re-confirmed independently at Decide; an earlier same-day read gave 48,271/62,286/3,294 — the tables
  drift, the conclusion does not). revisions streams as ~97 chunks and is NOT the peak driver. Worst-case
  500-row window computed in the engine's real `ORDER BY` pk stream order and converted from
  `octet_length(t::text)` to COPY bytes by the per-table measured ratio: **mutation_events 19.71 MiB (THE
  PEAK)**, documents 18.01 MiB, revisions 6.64 MiB. That is 0.9% of the 2200 MiB frozen floor.
  `Ecto.Adapters.SQL.stream(sql, [])` passes a LITERAL empty opts list (`workspace_bundle.ex:738`), so
  Postgrex's `@max_rows 500` governs. Three corrections the derivation MUST carry: (i) the 4.82 MiB
  figure circulated in the digest is an AVERAGE — the measured worst is 19.71 MiB, 3.9× it, and a floor
  derived off a mean is dishonest; (ii) **`documents` is an unnamed near-peer** at 18.01 MiB across only
  7 chunks (~30 KB/row, the densest table in the set) and sits 6 chunks from being a single-chunk table;
  (iii) chunk peak is order-sensitive by ~57% (physical order gives 28.80 MiB, id order 18.38 MiB) — the
  id-order figure is the correct one because `copy_out_sql` appends `ORDER BY t.<pk>`. The pathological
  ceiling (500 consecutive max-size rows) is 260 MiB — not realized today at 7.5% of it, but the honest
  upper bound. *Why: the epic spent two waves blocked by a memory wall; the number that proves the wall
  is gone had never been measured, and a mean would have hidden a 4× skew.*

- **PDS-D218 — THE WATCHDOG CANNOT EXIST. THE SAFETY POSTURE IS PRE-FIRE-ONLY, AND IT IS NAMED A
  SAMPLER.** Wave 12's own Ruling 1 required "a live MemAvailable watchdog with a pre-declared abort
  threshold". **That instrument is unbuildable, and this is now PROVEN, not argued.** A client was killed
  at 194 ms having received ZERO bytes; the server logged `Sent 200 in 7110ms` — a **36× overrun** — and
  a 0.25 s poll of the spill dir captured the ENTIRE lifecycle after the client was already dead: 15
  spills appearing, a tar growing to its full 66,596,864 bytes, then `after`-clause cleanup. Every byte
  was produced for a client that no longer existed. The mechanism: `export_bundle/2` sits in the `with`
  HEAD (`workspace_controller.ex:165`); the `try/after` wraps ONLY `send_file/3`. No disconnect can reach
  the export. Nor is there an external lever: `systemctl show` returns `MemoryMax=infinity`,
  `MemoryHigh=infinity`, `OOMScoreAdjust=0`, `OOMPolicy=stop` — no cgroup cap, no OOM biasing, and
  `OOMPolicy=stop` means a kernel OOM kill takes the LIVE content API down rather than shedding the
  export. `archive.ex` already conceded "SIGKILL is out of reach here by construction". **RULING: the
  pre-declared MemAvailable threshold checked BEFORE the request is issued is the ENTIRE safety
  mechanism, and the derivation must say so in those words. The monitoring loop is still run — it
  produces the peak series the floor is derived from — but it is called a SAMPLER, never a watchdog.**
  A loop that observes and logs while claiming an abort capability it does not have is a false safety
  net, which is the exact shape this epic exists to refuse. Note also: the export starves the DB pool
  (an `EdgeProjector.ProjectorWorker` timed out at 15000 ms six seconds after the killed export), so the
  cost lands on the live API whether or not anyone is waiting. *Why: `grep -c -i watchdog` over this
  charter returns ZERO — the watchdog was a strategy-note invention with no D-number behind it, and
  chartering it would have written an imaginary brake into law.*

- **PDS-D219 — THE INSTRUMENT INHERITED THE DEADLOCK, SO IT NEEDS A SECOND CHARTERED BYPASS, AND THAT
  BYPASS IS RECORDED AS A BYPASS.** D216 put the paired-control instrument BESIDE the frozen harness —
  but it carried the harness's floor with it: `pds-export-peak-measure.sh:121` reads the same
  `${PDS_FULL_EXPORT_MIN_MEM_MB:-2200}` and `:301-303` refuses a full acquisition below it. Live-refused
  twice, at 2055 and 2054 MiB. So the bootstrap deadlock Ruling 1 chartered a bypass FOR reproduces
  itself INSIDE the tool built to escape it. **RULING: the measure fires with `PDS_FULL_EXPORT_MIN_MEM_MB`
  explicitly exported to the pre-declared pre-fire threshold, and that export is recorded in the
  derivation AS A BYPASS, with the number and its basis — never as a quiet env tweak.** The threshold is
  a DERIVED safety artifact under D218 (it is the whole brake), never a token value like `100` chosen to
  make the gate pass. *Why: firing with a quietly-lowered floor and not writing it down is precisely the
  sin Ruling 1 was written to prevent, and the instrument's own §6c.3 says the floor is "read, never
  written" — that sentence must be amended by this decision rather than silently violated.*

- **PDS-D220 — TWO PRE-MERGE INSTRUMENT FIXES, AND THEY DO NOT BREAK THE FREEZE.** (a) **THE ZERO-SAMPLE
  NEGATIVE-DEMAND BUG.** `peak_kb_of` returns `0` for an empty log (`:247`) and `:388` subtracts the
  baseline unguarded, so an acquisition returning before the sampler's first ~1 s tick emits
  `export_samples=0 export_peak_kb=0 export_delta_mib=-847.18` **and exits 0**. No `-le 0` guard exists
  anywhere. A fast-failing full export — a 500 or a reset under memory pressure, precisely the regime
  here — would feed a NEGATIVE demand into the floor derivation. Fix: REFUSE (exit 2) when
  `EXPORT_SAMPLES` is 0. (b) **THE CONTROL MEASURES THE WRONG QUANTITY FOR D221's THRESHOLD.** The paired
  idle control emits BEAM RSS delta; D221's contamination threshold is stated on MemAvailable RANGE.
  Attaching one to the other would be a unit-class error of exactly the kind D185 exists to correct. Fix:
  add a MemAvailable sampling leg to the control window and emit its range. **Both are edits to
  `scripts/pds-export-peak-measure.sh`, which is NOT the frozen harness** — the freeze covers
  `pds-pull-proof.sh` at blob `e219e97ccf7f33797c86a2b84d998d599b6bda31` and is untouched. *Why: a
  pre-merge fix to a beside-instrument is not a mid-proof harness edit, and shipping a tool that can
  silently emit a negative demand is worse than shipping it a day later.*

- **PDS-D221 — THE CONTAMINATION-ABORT THRESHOLD IS 1048.16 MiB, ON MemAvailable RANGE.** No numeric
  contamination threshold existed anywhere in this ledger (`bp search`, 1118 hits, none carrying a
  number). Derived from 390 live samples (3 × 130 s idle windows, 1 Hz, kB/1024) on deployed guerrilla:
  per-window MemAvailable ranges 788.47 / 766.69 / 988.99 MiB → mean 848.05, population σ 100.06 →
  **mean + 2σ = 1048.16 MiB**. Distributional cross-check over all 390 points (σ = 262.29) puts a 2σ-on-
  range bound at 1148.81 MiB. The two derivations bracket [1048.16, 1148.81]; **take the LOWER**, because
  under D223's cheap exports a false abort costs one inexpensive export while a contaminated measurement
  poisons the floor law permanently — asymmetric cost, strict end of the bracket. **RULE: if the paired
  idle window's MemAvailable range ≥ 1048.16 MiB, the measurement is VOID and must be re-taken.** This
  attaches ONLY to the MemAvailable leg D220(b) adds. For the RSS control leg the entire evidence base is
  n = 1 (294.96 MiB) — **no threshold is derived from it, and none may be invented at the close.**
  *Why: "the control was large" is a judgement call at 3 a.m. unless a number was written down first.*

- **PDS-D222 — THE FLOOR IS DERIVED FROM THE DELTA, NEVER THE ABSOLUTE PEAK, AND THE MARGIN IS
  798.81 MiB.** Two things this decision pins, because both were about to be got wrong. (i) **UNITS.**
  The canonical 2235.43 MiB is a DELTA — the parked sidecar records `rss_peak_kb: 2483304` and
  `rss_baseline_kb: 194228`, and (2483304 − 194228)/1024 = 2235.4258 exactly; the ABSOLUTE peak was
  2425.10 MiB. `cond_b` compares the floor against live MemAvailable, and **MemAvailable measures
  headroom for NEW allocation while the baseline RSS is already resident** — so the floor is
  `measured_demand_delta + margin`, and adding the baseline back would DOUBLE-COUNT and over-set the
  gate. (A Decide-round reading that it would UNDER-set is wrong and is recorded here so it is not
  re-derived.) The old 2200 default sitting just under the 2235.43 delta confirms the convention was
  already delta-based. (ii) **THE MARGIN IS 798.81 MiB.** The floor gates a single INSTANTANEOUS pre-fire
  read and the export then runs; the quantity a margin must cover is the worst downward excursion from
  any authorising instant to any later instant in the same window — the maximum drawdown,
  `max_t ( v_t − min_{u≥t} v_u )`. Observed across the three windows: 570.44 / 756.35 / 798.81 MiB. **Take
  the MAX, not the mean** — a mean-sized margin is refuted by a third of the observed windows. Per D114
  this is a LOWER bound (1 Hz misses sub-second troughs, n = 3, and the build-contention channel was OFF),
  which is the safe direction. **FLOOR = measured demand + 798.81 MiB.** *Why: D190 §5 said "no floor
  value prevents this" — §5 is right that no floor CONSTRAINS the walk and wrong that none can SURVIVE
  it; 798.81 is the measured size of the walk.*

- **PDS-D223 — DELETING THE PARKED `.tar` IS PERMITTED; RESETTING `attempts` AND REPOINTING
  `PDS_FULL_EXPORT_DIR` REMAIN FORBIDDEN.** Ruling 2 forbids the climb reusing another invocation's
  bundle but named no mechanism, and the harness will defeat it on any RETRY: `acquire_full_bundle`
  reuses the park for ZERO attempts whenever `full_meta_ok` AND meta `served_sha == DEPLOYED_SHA`
  (`:1269-1283`, `return 0`). Today reuse cannot fire — the park records `15e057f83` against a deployed
  `bc64d869a`. **But the moment the climb's first `--all` takes its fresh export it writes a new `.meta`
  stamped `served_sha bc64d869a` (`:1452`); a second `--all` after a red at rung 5/6/7/8 then finds a
  MATCHING sha and silently REUSES, printing "0 attempts spent this run"** — that retry's rungs 3/4 would
  scan a bundle from the first invocation, the exact criterion-11 mosaic, arriving through the sanctioned
  path with no warning. `full_meta_ok`'s first test is `[ -s "$FULL_TAR" ] || return 1`, so **removing the
  `.tar` is the ONLY lever that forces a fresh export without touching either forbidden knob.** RULING:
  it is permitted, and it must be stated in the transcript when done. *Why: deleting the tar SPENDS budget
  where resetting `attempts` HIDES the spend — they are morally opposite acts that look superficially
  alike, and Ruling 2 was incomplete without saying which is which.*

- **PDS-D224 — THE BUDGET IS A FORMULA, NOT A LITERAL: `spent_at_fire_time + 2`.** `/tmp/pds-full-export/
  attempts` reads `1` against `FULL_BUDGET="${PDS_FULL_EXPORT_BUDGET:-1}"` (`:130`), and `cond_c` tests
  `spent < budget` (`:1313`) — so `1 < 1` is FALSE and the climb cannot fire at all today. Since `attempts`
  must not be reset (D223), the ceiling must exceed the spend: on THIS host that means **3** (1 spent +
  1 climb + 1 retry slack). But the store is HOST-LOCAL (D156) — a climb host reading `attempts=0` needs
  2, not 3. **RULING: the builder is handed the FORMULA `spent + 2` and MUST re-read `attempts`
  immediately before firing, never trusting a literal from a survey.** The raise is pre-authorised by
  D137/D156 and goes on the record. *Why: three waves have quoted a stale literal from a survey taken
  hours earlier on a different host.*

- **PDS-D225 — THE CLIMB WORKTREE RULE SURVIVES, BUT ITS JUSTIFICATION IS REPLACED.** D212 grounded the
  fresh-worktree requirement on "step 0b FAILS from the primary checkout". **That premise is REFUTED
  today**: the primary is `b3dac3e8e`, has `origin/main` as an ancestor (0 behind, 2 ahead, both docs-only,
  clean tree), so 0b would take the ancestor branch and PASS there. The rule is still right, on different
  grounds: **the primary checkout is VOLATILE** — it moved from `1ccf6206a` to `b3dac3e8e` inside a single
  session and accretes unpushed docs commits continuously, so a climb from it is a coin flip on whether it
  has diverged by fire time. Re-proven affirmatively: from a fresh worktree pinned to `origin/main`, `--only
  0a,0b` returns **`2 PASS · 0 ABORT · 0 FAIL`, exit 0**, with 0b taking the STRONGEST branch —
  "deployed sha EQUALS the worktree", not the weaker ancestor branch. Two operational corrections ride
  here: **`--step` IS NOT A FLAG** (the parser accepts only `--plan|--all|--only|--help` and exits 3 on
  anything else — a `--step 0a` line pasted into a brief runs NOTHING while printing a usage line a
  careless reader could skim as clean), and the spill dir is **`/opt/barkpark/api/tmp/bundle-spill`, NOT
  `/tmp`** (`config.exs:19`; `BARKPARK_BUNDLE_SPILL_DIR` unset on the live slot) — a `/tmp/bp-ws-*` glob
  returns "No such file" even mid-export and would be mis-sorted as "no export ran". *Why: a rule defended
  by a refutable premise gets discarded by the first reviewer who checks the premise.*

- **PDS-D226 — THE STAMP CEILING IS A NON-RISK; THE REAL TRAP IS CRITERION 11, AND THE LAW IS UNIFORM
  FETCH-TO-FILE.** Both halves of the stamp recipe were proven live. Pasting criterion 6 inline into a
  double-quoted string ran its four backtick pairs as command substitution and the server rejected the
  stamp `criteria_mismatch`, exit 2, **nothing written**; `--criterion-text "$(cat c6.txt)"` with the
  identical text stamped clean, exit 0. The ceiling was RE-DERIVED and the circulated figure is wrong:
  it is not "live-bisected between 8900 and 9002" but **total URL 10016 OK / 10017 FAIL**, bisected to one
  byte, reproduced 3/3 each side, and it is a TOTAL-bytes limit (re-bisecting with a 31-char criterion hit
  the same boundary with 2671 more evidence bytes). The mechanism is **Bandit's `max_request_line_length`
  default of 10_000** — not Caddy, not HTTP/2: over `--http1.1` and direct to `:4000` with Caddy bypassed
  the same byte returns a legible **414**, and `5 ("POST ") + 9984 + 9 (" HTTP/1.1") + 2 = 10000` closes
  exactly. `git grep max_request_line_length` returns NOTHING repo-wide. Durable law: **request target ≤
  9984 bytes.** Per-criterion evidence budgets run **7197 (c6, the tightest) to 9759 (c3)**; the successful
  c6 stamp spent **69 of 7197, under 1%**. **The ceiling is therefore DOWNGRADED — it cannot bite a terse
  stamp.** What IS sharp: criterion 6 is the only one of twelve unsafe in a double-quoted string (8
  backticks) and it fails LOUDLY, but **c5/c6/c11 carry single quotes, and criterion 11 carries exactly ONE
  in 1248 characters** — invisible on inspection, stamped LAST and ALONE at maximum fatigue, and its
  met-flip releases the auto-close brake. Two silent hazards: `` `command` `` is a zsh BUILTIN so it mangles
  with NO "command not found" line (3 of 4 pairs warn, the 4th does not), and `"$(cat f)"` strips ALL
  trailing newlines — safe here only because 0 of 12 criteria carry trailing whitespace, i.e. **safe by
  luck of the data, not by construction**, so extraction MUST be a JSON-field write, never a here-doc.
  **RULING: uniform fetch-to-file for ALL TWELVE, no per-criterion judgement.** Oversized stamps are
  fail-closed (a `SENTINEL` at 9000+ bytes wrote nothing), so recovery is "retry shorter", never
  "reconcile a half-write". Also: worker and epoch ride the BODY, not the URL. *Why: the circulated hazard
  was the wrong one, and per-criterion judgement is how someone eyeballs c11, sees no backticks, and types
  it inline.*

### Wave 13 — FIRE THE CLIMB (decided 2026-07-21, PDS-D227–PDS-D241, paper `pds-wave-13-2026-07-21`)

*Waves 10, 11 and 12 each planned the climb and each ended with an instrument — a sentinel, a paired
control, a preflight, a stamp script. Every one was justified. Net movement on the crown across three
waves: ZERO. This wave's success condition is THE TRANSCRIPT EXISTS, not that the preflight is better.*

- **PDS-D227 — cond_b IS NOT A LOTTERY. IT IS A READOUT OF THE BUILD QUEUE, AND THE FIRE PREDICATE'S
  LOAD-BEARING LEG IS `bp-site-build-*` IDLE.** Two concurrent 1 Hz instruments (600 samples, ~7 min,
  2026-07-21 03:03–03:10 UTC) settle the question the last three waves treated as luck. Clearance of the
  2200 MiB floor **conditional on build-idle is 244/246 = 99.19%; conditional on a build running it is
  5/54 = 9.3%.** 96% of below-floor samples (49 of 51) had a site build running; 2% of above-floor samples
  (5 of 249) did. Mean MemAvailable build-busy 2005 MiB vs build-idle 2466 MiB — a **461 MiB depression,
  squarely inside PDS-D190 §4's 379/496 MiB two-step, replicated a year of waves later on the deployed
  engine.** The two surveyors' amplitude disagreement (1614–2306 vs 1396.75–3060.76) is them sampling
  different mixes of build-busy and build-idle time. **RULING: poll on D193's legs with (iii) leading —
  `bp-site-build-*` running listing EMPTY, THEN MemAvailable ≥ floor, read in the same breath as firing.
  Never poll on MemAvailable alone; that is what makes it look like a lottery.** `scripts/pds-window-
  sentinel.sh` already implements this predicate — the wave needs NO new poller. *Why: three waves refused
  on a number they had not explained, and the explanation makes the gate near-deterministic.*

- **PDS-D228 — THE WINDOW IS LONG ENOUGH, AND IT WAS MEASURED, NOT ASSUMED.** Longest unbroken above-floor
  run **212 s** (1 Hz instrument) and **254 s** (per-sample-SSH instrument) — both exceed the ~150 s the
  export needs. 63 of 151 contiguous 150 s sub-windows held throughout (42%), rising to **66% conditional
  on firing from a build-idle, above-floor instant.** HONESTY LIMIT, and it must travel with the number:
  **those 63 windows are not 63 independent trials — they are sub-windows of ONE 212 s clean episode, n=1.**
  The frequency claim rests on the build journal instead (n=133 gaps, 134 build starts in 3.1 h — an
  07/17-class build-storm day). Hazard analysis over those gaps: waiting for **120 s of continuous build
  silence** raises P(≥200 s more silence) from 8% to 27%, at the cost of such moments arriving ~7.2/h
  instead of 43.3/h. Patience buys ~2.5×, not 10×. *Why: "nobody measured window length" was the wave's
  biggest unknown; it is now closed, and the honest n travels with it so no Paper quotes 42% as 151 draws.*

- **PDS-D229 — THE SWAP-EVICTION MECHANISM IS REGIME-DEPENDENT AND DID NOT DRIVE TODAY'S REGIME.** The
  digest asserted headroom appears because the production BEAM is SWAPPED OUT. Across 600 samples that
  mechanism is **absent**: SwapFree was FLAT (985.4 → 1008.4 MiB, whole-run range 23 MiB) and beam VmSwap
  **FELL** (192.9 → 175.1 MiB — the BEAM was being swapped *in*). `r(MemAvailable, SwapFree)` = −0.150 and
  +0.146 across the two instruments — sign-unstable and near zero. SwapFree sits at ~1008 of 2047 MiB, not
  the "728 of 2048, 64% spent" the digest reported, so the claimed hard ceiling on the window-opening
  mechanism is not there because the mechanism is not there. What actually moves the number is
  `r(MemAvailable, beam RSS)` = −0.500/−0.468 (ordinary RSS oscillation, PDS-D190 §2) plus D227's build
  channel, which dominates. **This charter does NOT rule that eviction never happens** — wave 10's
  transcript shows it was real then (VmSwap 81156 → 514516 kB with RSS collapsing). It rules that **it did
  not drive the 2026-07-21 03:03–03:10 regime, which was build-driven.** *Why: a mechanism claim stated
  timelessly would be refuted by the next regime and would poison the predicate that actually works.*

- **PDS-D230 — POLLING IS FREE AND cond_b IS NEVER RE-CHECKED MID-EXPORT, SO A TROUGH CANNOT FAIL THE
  HARNESS.** Read off the frozen blob, not argued: the failed-precondition `return 1` sits immediately
  above `spent_now=$((spent + 1))`, so **a closed gate costs zero export attempts** — polling is free. And
  the export is a **single `curl` between `t0` and `t1` with no memory re-check and no abort-on-trough path
  anywhere**, so a build arriving mid-export cannot make the harness abort. It can only hurt via a real
  kernel OOM — and the 2200 floor was sized for the OLD in-memory engine (D185's 2235.43 MiB demand) while
  the deployed spill engine's chunk peak is ~19.71 MiB. Today's *worst* observed MemAvailable, deep inside
  a build storm, was 1571.52 MiB: over 1.5 GiB of headroom against a ~20 MiB consumer, on a box with
  **zero OOM-kill lines in `dmesg`. RULING: fire; do not refuse on cond_b.** Poll the 4-leg predicate at
  10 s cadence, prefer a moment with ≥120 s of build silence behind it, budget 30 polls, fire on the first
  qualifying draw. 30 polls without one is itself a reportable stand-down that cost zero attempts.

- **PDS-D231 — cond_c IS THE ONLY HARD BLOCKER, AND ITS FIX IS DEMONSTRATED END TO END — BUT THE
  DESTINATION IS "GO WITH WARNINGS", NOT A CLEAN GREEN.** `PDS_FULL_EXPORT_BUDGET=3` (D224's `spent+2`,
  spent read as 1) flips CHECK 2 from `EXHAUSTED: 1 of 1` to `1 < 3, so cond_c passes`, and the overall
  `--strict` verdict from **rc=1 NO-GO to rc=2 GO WITH WARNINGS** — a licensed, documented exit
  (`pds-climb-preflight.sh:40`: "exit 0 GO · 2 GO-WITH-WARN · 1 otherwise"). **Exactly ONE check changed
  state**; CHECK 1/3/4 were byte-identical in substance across both runs, and CHECK 4 warns independently
  of the budget on #5097/#2907. The attempts file was **read but never written** by either run — it read
  `1` before, during and after, so D212/D223 was honored. The `required=3` figure was re-derived by the
  script itself, not echoed from an error string. **Anyone citing this must cite GO-WITH-WARN naming
  #5097/#2907 — never "the preflight went green".** *Why: precision loss here is the same failure class
  D185 exists to forbid, one layer up.*

- **PDS-D232 — THE FLOOR STAYS AT THE UNMODIFIED 2200, AND THE DERIVATION IS NOT PAYABLE THIS WAVE.**
  `19.71 + 798.81 = 818.52` is ARITHMETIC, not a licensed derivation. D217's **19.71 MiB is a worst-single-
  COPY-chunk WIRE-BYTE figure from a 0/4 census task**; D211/D222's "measured demand delta" is a **BEAM RSS
  peak-minus-baseline under a D104 paired control**. Substituting one for the other is exactly the
  unit-mixing PDS-D185 was written to forbid after wave 9/10 did it once already. Compounding it: **D221
  voids any idle leg whose MemAvailable range exceeds 1048.16 MiB, and today's live range measured
  1664.01 MiB** — an idle control sampled in the current regime would be VOID on its own rules. **RULING:
  fire at the unmodified 2200 floor, raising ONLY `PDS_FULL_EXPORT_BUDGET`. No bypass, because nothing
  needs bypassing — and a climb fired at the untouched floor carries no asterisk, where a climb fired
  after lowering the gate would forever be "the climb we fired after lowering the gate".** The derivation
  is filed as backlog and must never gate the shot.

- **PDS-D233 — RUN_TAG IS THE ONLY PER-RUNG ANCHOR THE HARNESS PRODUCES, AND PINNING THE THREE ENV VARS TO
  LITERALS DESTROYS IT.** `RUN_ID` reaches stdout in exactly TWO places — the banner (`:485`) and the
  summary (`:2448`). `head_step` carries none. But `RUN_TAG="$(printf '%s' "$RUN_ID" | cksum | awk …)"`
  (`:112`) seeds `BARKPARK_HOME`/`PDS_SCRATCH_POINTER`/`ART_DIR` via `${VAR:-default}`, and **those paths
  print inside rung bodies** — in wave 7, `3fa886ec` (re-derived by hand from the run id) appears at lines
  518–661 spanning steps 1, 3 and 4. That is a cryptographically checkable per-rung link. **Wave 9 pinned
  `BARKPARK_HOME=/private/tmp/pds-w9c` and the anchor VANISHED — 0 occurrences vs wave 7's 7.** **RULING:
  set the three vars to values that EMBED `$RUN_TAG` (e.g. `BARKPARK_HOME=/tmp/pds-w13.$RUN_TAG`), never
  to a fixed literal.** Concurrency isolation against sibling cycles is preserved AND every rung body that
  prints a path becomes self-anchoring. *Why: wave 9 gave up the anchor for nothing, and this cannot be
  retrofitted to a spent attempt.*

- **PDS-D234 — CRITERION 11's SCOPE IS ALL ELEVEN. THERE IS NO RUN-INVARIANT SUBSET AND NO CHEAP PARTIAL
  RE-STAMP.** Each criterion was classified by its own TEXT, not its evidence. **Every one of 0–9 is a
  claim about what a run did or what a transcript says**, in run-indexed language the authors chose
  deliberately ("re-derived at RUN TIME", "the run output is pasted", "the run's OWN measured RSS peak",
  "the run kept `PDS_STEP5_FAILDEMO=1`", "re-derived at run time rather than asserted from a snapshot").
  **Zero make a run-invariant structural claim.** Criterion 0 is the quietest trap: it is the only met
  criterion naming a run, so a stamper may leave it alone — but its claim is about the **deployed sha**,
  which has moved to `859c137cd`, so it is stale in SUBSTANCE, not merely attribution. Criterion 10 is a
  merge event, not a run, but must cite the run id **as a pointer** because its own text requires rungs
  3+4 green "in the transcript of the wave that pays this criterion". **RULING: 0–9 are re-stamped with
  the fresh RUN_ID; 10 carries the same id as a pointer and is stamped LAST by the LEAD on merge; 11 is
  stamped ALONE after verifying the eleven ids are identical.**

- **PDS-D235 — THE TWO EXISTING RUNS ARE EXACT COMPLEMENTS, AND THAT IS THE SHARPEST ARGUMENT FOR FIRING.**
  Read off the committed transcripts rather than the ledger: **wave 7** (`20260720T032558Z-28651`) was a
  complete `--all` — **10 PASS · 0 ABORT · 1 FAIL** — in which **rungs 3 AND 4 PASSED** off the one full
  bundle this epic has ever taken (1,037,336,576 bytes, 130 s, attempt 1 of 1); only rung 6 FAILED ("THE
  CONTROL DID NOT FIRE"). **Wave 9** (`pdsw9-reclimb-20260720`) paid **rung 6 PASS** but **3 and 4 ABORT**
  on `env:full-export-unavailable`. So the nine met criteria are probably not a mosaic in fact — they look
  like wave 7's output — but **neither run greens the whole ladder and the two are exact complements.**
  Stitching them is precisely and literally what criterion 11 forbids. **The crown is ONE rung-6 green away
  from complete, but only on a run that ALSO re-takes 3 and 4.** *Why: this reduces the epic to a single
  sentence and removes every temptation to reason about partial credit.*

- **PDS-D236 — "ONE RUN" IS PROVABLE, ON THREE LEGS, AND THE HARNESS STRUCTURALLY REFUSES TO OVERCLAIM.**
  (i) The summary roster prints `SUMMARY — run $RUN_ID` and then enumerates **every rung id with its
  outcome in one block emitted by one process after all rungs ran** — attribution by roster, not by
  per-rung token. (ii) Lines 2478–2486 gate the unqualified `RESULT: PASS — the whole ladder ran and held.`
  behind `n_ran == n_all`, else printing `RESULT: PASS (PARTIAL) … only \`--all\` can pay that claim.` **A
  transcript carrying the unqualified line cannot have come from a partial invocation.** (iii) D233's
  RUN_TAG paths, if embedded. What may honestly be asserted: *"Rung N passed under run `<id>`, as recorded
  in that run's own summary roster in a transcript whose banner and summary both carry `<id>` and which
  prints the unqualified full-ladder PASS line."* What may NOT: that each rung body is individually
  in-band tokened. **Without D233's embedding, attribution is process-level, not rung-level.**

- **PDS-D237 — THE IDLE SAMPLER CANNOT RIDE FREE AS WRITTEN, AND THE STRIP IS PROVEN BY CONTRAST.**
  `pds-export-peak-measure.sh` takes `$FULL_DIR/lock` — **byte-identically the path the frozen harness
  locks for the whole export** — UNCONDITIONALLY in preflight before Window 1, then evaluates the same
  2200 floor. Launched beside an active climb it does not degrade gracefully; it **REFUSES with a PDS-D31
  message that mid-wave reads as unrelated infra failure.** "Simply don't pass the flag" is unachievable:
  the leg is structurally in the way. A verifier BUILT the strip and proved it both ways — with a dummy
  lock held throughout, the stripped sampler ran 60 ticks to completion, `lock NOT TAKEN`, attempts
  unchanged at 1, rc=0; the **unstripped original REFUSED (exit 2, PDS-D31) under the identical lock.**
  **RULING: the sampler is permitted as a small stripped derivative (delete the lock block, the FULL_ACQ
  floor gate, and all of Window 2), it keeps both D220a zero-sample refusals verbatim, and it MUST NOT
  gate the fire.** If it is not ready, the climb fires without it.

- **PDS-D238 — cond_d HAS NO RESERVATION SEMANTICS, AND THE HOLD WAS REQUESTED, NOT GRANTED.** The harness
  checks `gh` ONCE before spending the attempt and **never re-polls during the ~130 s export**; a merge
  landing mid-export moves the sha and is caught only retroactively at step 8, **by which point the attempt
  IS spent**. `#5097` is MERGEABLE now and touches `api/**`; `#2907` is CONFLICTING and so not an immediate
  threat, but a rebase re-arms it. A hold was requested from the fleet and **no reply arrived. Silence is
  not consent. RULING: fire on cond_d's own check-and-go, accept the residual sha-drift window, and do NOT
  record the coordination attempt as having closed the risk.**

- **PDS-D239 — THE EXPORT STORE IS HOST-LOCAL BUT NOT RUN-LOCAL, AND THE CONTENTION WAS REPRODUCED LIVE.**
  guerrilla carries **zero** trace of the attempt store (`ls` and a `find` over `/tmp` and `/opt` both
  empty), so the counter is safe from the server. But `/tmp/pds-full-export/{lock,attempts}` is a literal
  absolute path **unscoped by worktree, RUN_ID or `BARKPARK_HOME`**, and a verifier watched the lock get
  taken at 05:03:50 and released by ~05:05:50 **by a process it did not start**, with no owner in `ps`, on
  a Mac running 90+ concurrent worktrees. Because `attempts` is written only AFTER the `mkdir` lock
  succeeds, two processes **cannot silently double-spend the same counter value** — the loser gets a named
  "lock held" NO-GO. **So the trap is contention and blocking, not silent corruption.** Filed since wave 6
  as `pds-bl-full-export-store-scoping` (0/5, still open). Note also: the reset/repoint prohibition is
  **POLICY, not a technical control** — nothing in the code refuses `echo 0 > attempts`.

- **PDS-D240 — RETRY DISCIPLINE, PRE-DECLARED SO IT IS EXECUTED AND NOT IMPROVISED AT 3 A.M.** D224's
  formula is re-read at fire time, never a literal. **D223's parked-`.tar` deletion is the ONLY sanctioned
  way to force a fresh export on retry**; resetting `attempts` and repointing `PDS_FULL_EXPORT_DIR` stay
  FORBIDDEN. A **dead HTTP attempt needs NO manual deletion** — the harness's own failure path `rm -f`s the
  tar, and the counter is flushed to disk BEFORE the request fires and is never decremented. **CAP: at most
  TWO fires this wave** (budget 3 = spent 1 + 2), so retries cannot quietly become a criterion-11 mosaic.
  The parked bundle is stale **in the wave's favour** — `served_sha 15e057f83` is a git-verified ANCESTOR
  of the spill merge `87c9995f6`, so the one full export this epic ever took **predates `send_file`
  entirely**, the reuse guard refuses it, and the climb takes its OWN fresh bytes exactly as criterion 11
  requires.

- **PDS-D241 — THE HARNESS FREEZE HOLDS EVERYWHERE A FIRE COULD ORIGINATE, AND RUNG 6's LAST LEVER IS
  ENVIRONMENTAL.** Blob `e219e97ccf7f33797c86a2b84d998d599b6bda31` (`git rev-parse`, **never `shasum`**,
  PDS-D154). Across all **1187 registered worktrees**: 984 lack the file, **128 match byte-for-byte, 75
  carry an older committed blob — and all 75 resolve to stale pre-freeze wave-3..6 loop-epic worktrees.
  ZERO uncommitted edits anywhere.** Every named wave-13 sibling worktree is clean and matches. The
  **PRIMARY checkout is UNSUITABLE to fire from** (HEAD `a96aacce6`, a genuine fork whose merge-base with
  origin/main is older than both; dirty) even though its own copy of the harness matches. On rung 6: the
  visibility split in the exact scope is **still 31 private / 3 public, unchanged from wave 9**, so leg B's
  visibility column still moves; the 3 public rows (`command`, `paper`, `task`) are **code-declared** by
  scaffy/bulldocs/tasks, not incidental. The roster tripwire holds for the right reason — 34 in-scope rows
  and **34 independently-derived Bootstrap REGISTER lines**. Two traps: `tag` is public too but excluded by
  scope, so re-running the check WITHOUT the exclusion reads `public 4` and wrongly concludes the split
  moved; and on a never-pulled target the table holds **35 rows, not 36 — `metric` is ABSENT pre-pull**, so
  the census's 36 is a POST-PULL count. **`PDS_STEP6_GUARD_DEMO` must be left UNSET** — `=0` gives a
  materially weaker green by the harness's own words. Boot cost is also on the critical path: `up --verify`
  measured **155.72 s** today, not the documented ~32.7 s, because the coarse WARM discriminator reported
  WARM while `api/_build/prod` had never been compiled. **Pre-warm `MIX_ENV=prod` before the timed window
  opens.**

### Wave 14 — DETACH THE CLIMB FROM THE TURN (decided 2026-07-21, PDS-D242–PDS-D249, paper `pds-wave-14-2026-07-21`)

The wave arrived as DETACH + DERIVE. Verification killed the DERIVE half by running the instrument,
and killed the DETACH half's literal incantation by running it. What survives is sharper than what
was planned: **the wall was never the floor. The wall was the TURN.**

- **PDS-D242 — R0 IS MOOT. THE FORK REPAIR ALREADY LANDED.** PRs #5228–#5232 are ALL MERGED
  (04:19:01Z–04:24:44Z), every `PDS-D217`–`D241` is present on origin/main (65 `PDS-D2` hits, each
  D-number ≥1), and `#5131`/`#5133`/`#5097`/`#5161` are confirmed ancestors of the tip. **NOTHING
  REMAINS TO LAND FOR PDS; no R0 slice is filed.** What survives is different: the PRIMARY checkout
  carries THREE still-stranded charter commits for OTHER epics (studio `b3dac3e8e`, gui-remake
  `1ccf6206a`, truth-grip `a96aacce6`) with no landing PRs, so **a blanket `reset --hard` there
  destroys them** — while the PDS commit `de42c2af0` is provably byte-redundant (0 deletions against
  origin/main's current file; a strict subsequence). D225/D241 stand unchanged: **fire from a FRESH
  origin/main worktree.** The one residue is a ledger stamp, not work: `pds-w13-charter-lands` reads
  5/6 with only "PR merged" unmet — the LEAD closes it, nobody rebuilds it.

- **PDS-D243 — `setsid` DOES NOT EXIST ON THIS HOST, AND `nohup … & disown` IS NOT KILLPG-IMMUNE.**
  The wave's own direction said "setsid/nohup"; run verbatim it fires NOTHING (`which setsid` → not
  found, exit 1; macOS 15.5). Proven by execution, not inference: `nohup … </dev/null >log 2>&1 &
  disown` survives a turn ending AND survives `kill -HUP -<pgid>`, but **DIES to `kill -TERM
  -<pgid>` and `kill -KILL -<pgid>`** — it keeps the LAUNCHER's pgid and never becomes a session
  leader (`STAT SN`, no `s`). The **only structurally immune form is `python3` `os.fork()` +
  `os.setsid()` + `os.execvp()`**: own pgid, own session (`STAT Ss`), `ppid=1`, and it SURVIVED the
  exact killpg that killed the nohup child. `os.closerange(3,64)` is not decoration — without it the
  child holds the harness's pipe write-end open and the launching tool call appears to hang, defeating
  "returns immediately" even when detachment is correct (`pds-scratch-target.sh:342` documents this
  hazard in-repo). **The knowledge was one grep away in a SIBLING charter for four waves**
  (`bp-search-template-charter.md` D36: "macOS is bash 3.2 with no `setsid`/`systemd-run`").

- **PDS-D244 — THE DERIVATION REFUSES ITSELF, AND THE RUNG IT NAMES IS NEW.** `#5131` was RUN
  end-to-end for the FIRST TIME EVER (closing a survey absence), scoped, against the deployed
  streaming engine. Its output: **export delta = 687904 − 695632 = −7728 kB = −7.55 MiB — NEGATIVE**
  — against a paired idle control drifting **+110.22 MiB**, ~15× its magnitude in the opposite
  direction. **A negative, drift-dominated delta yields no floor.** The instrument says so itself,
  unprompted, in its own COMPARABILITY block. The only derivable form is UNSCOPED, which fires a real
  ~2.2 GiB full export that the ledger **provably cannot see** (zero `FULL_ATTEMPTS_FILE` references
  in the instrument; a real `curl` at `:471`). **RULING: "derive the floor at zero attempt cost" IS
  NOT AN AVAILABLE OPTION. The floor stays at the unmodified 2200; R1 is REFUSED with the number
  attached, having spent ZERO attempts (3 before, 3 after, mtime unchanged).** This is the fifth
  consecutive wave's refusal and the FIRST to name this rung: not the gate, not the budget, not the
  regime — **the instrument's scoped output is empty.**
  Note what this does NOT rest on: **D221 does not void it.** The control's in-window MemAvailable
  range measured **117.61 MiB ≪ 1048.16**. Both D232's "1664.01 MiB" and this wave's strategize
  "1423.39–1830.73" are ranges of LEVELS ACROSS samples, **not one window's internal range, which is
  the only quantity D221 tests** (D221's own basis: 3 × 130 s windows at 1 Hz). D232's arithmetic
  objection stands; its D221 objection was itself a unit-class error.

- **PDS-D245 — cond_b IS A GATE, NOT A WATCHDOG, SO DETACH-ONLY IS PAYABLE AT 76.2%.** MemAvailable
  is read **ONCE**, at `pds-pull-proof.sh:1301`, via a single `ssh_src` inside the precondition block,
  and is **never re-read during the export**; D218 already established there is no abort-during-export
  mechanism. Therefore "the longest contiguous build-idle run is ~90 s against a ~150 s export" is a
  **SAFETY** argument about OOM risk, **not a GATE argument** — a qualifying draw fires and the export
  runs to completion regardless of a later dip. Steady-state build-idle clears 2200 in **32/42 =
  76.2%** of draws (mean 2239.25 MiB), against 97.2% inside the post-restart transient. An agent turn
  afforded 2–3 draws; **a detached hour at 10 s affords ~360.** 76.2% over 360 draws is not a wall.
  The absorption clause fires as written: **the derivation is DEMOTED to backlog and the wave fires
  detached at the untouched floor** — which is exactly PDS-D232's ruling, finally executed.

- **PDS-D246 — NO FIFTH PREDICATE LEG. BEAM WARMTH IS RECORDED, NEVER GATED.** Idle MemAvailable is a
  near-deterministic function of `beam.smp` RSS (**r = −0.986**, slope **−1.178 MiB per MiB**, n=87),
  which reconciles every "contradictory" live read as one warm-up curve rather than two regimes —
  extrapolating to the strategize-era RSS (1157.3 MiB) predicts ~1617 MiB, inside its reported range.
  Consequence: a long-running detached poller structurally **PREFERS post-restart transients**,
  exactly the draws D93/D190/D191 forbid. **The fix is NOT a warmth leg** — D193's four-leg predicate
  already went **0/61** precisely by ANDing one more condition, and this epic does not get to
  re-learn that. The launcher **RECORDS** beam RSS and slot uptime beside every draw so the fired
  draw is auditable after the fact, and the review rules on it. Observation, not gating. The
  "18-minute" transient in D93/D190/D191 is **too short for this confound** — the governing variable
  is RSS convergence, not a wall clock.

- **PDS-D247 — ONLY A `^RESULT:` LINE IS A FINISHED SIGNAL, AND THE LAUNCHER APPENDS ITS OWN EXIT
  SENTINEL.** Proven decisively: a SIGKILLed transcript was **byte-identical** to a still-running one.
  The harness runs under `set -euo pipefail` (`:85`) and emits `RESULT:` only from `summary()`
  (`:2462`–`:2487`), so a mid-rung abort terminates with **NO `RESULT:` line** — under a three-state
  grammar indistinguishable from an OOM-kill, and those are **different diagnoses** (a harness bug vs.
  the memory wall that is this epic's whole subject). The launcher-appended `EXIT: <code>` sentinel
  splits them, and redundantly carries the verdict (harness exits 0=PASS, 1=FAIL, 2=BLOCKED). **SIX
  states:** NO-TRANSCRIPT · CRASHED (sentinel, no RESULT) · FINISHED · FINISHED-nosent (every
  pre-w14 artifact, so the fallback is REQUIRED not optional) · STILL-RUNNING · KILLED. Liveness is
  `ps -p <recorded pid>`, **never `pgrep`** (PDS-D135; wave 13 burned exactly this). Two traps:
  `grep -c` **exits 1 on zero matches**, so every grep needs `|| true` under `set -e`; and
  `ps -p 999999` is a **VACUOUS** test — `kern.maxproc` is 4000, so it fails argument validation
  ("process id too large") rather than the not-found path. Also settled: **ANSI is a non-issue** —
  0 escape bytes from the harness, `bp`, `gh`, `mix` under redirection, and all three committed
  transcripts are already clean. **No ANSI mitigation is to be filed.**

- **PDS-D248 — A SIGKILL STRANDS THE EXPORT LOCK, AND NOTHING RECOVERS IT.** `FULL_LOCK`
  (`/tmp/pds-full-export/lock`) is a `mkdir` lock released **only** by `cleanup` via `trap cleanup
  EXIT` (`:193`), and **SIGKILL bypasses traps**. So the exact failure this wave braces for — an
  OOM-kill of a detached climb — permanently strands the lock, and since preflight takes it
  **unconditionally**, every subsequent run *including the retry* blocks. **The collector MUST check
  the lock whenever it returns KILLED and report it by name.** Related and unfixed: `#5131` takes the
  same lock unconditionally in preflight, **before** `FULL_ACQ` is evaluated, so a scoped run dodges
  the floor gate but **not the mutex** — any measure and any climb are strictly mutually exclusive.

- **PDS-D249 — THE BUDGET MUST BE READ, COMPUTED, EXPORTED AND EXEC'D IN ONE SHELL.**
  `FULL_BUDGET="${PDS_FULL_EXPORT_BUDGET:-1}"` (`:130`) resolves **once at process start**, and a
  child inherits its environment at fork/exec **only**. Proven by execution: exporting and launching
  in the SAME shell → the child read **5**; exporting in one tool call and launching in a later one →
  the child read **1**, the silent default, and cond_c then fails hours later with nothing visible at
  launch time. `attempts` reads **3** today, so D224's formula gives **budget = 5** — **re-read
  IMMEDIATELY before the fire, never a literal carried from this charter.** The store is HOST-LOCAL
  (D156); resetting `attempts` and repointing `PDS_FULL_EXPORT_DIR` remain FORBIDDEN (D223/D240), and
  the parked tar needs **no deletion for a first fire** — its stale `served_sha` (`15e057f83`) already
  routes the harness past reuse into a fresh export whose `curl -o` overwrites it in place.

**THE WAVE, three rungs, expensive move LAST.** R1 `pds-w14-detached-launcher` (round 1) commits the
arm+collect plumbing. R2 `pds-w14-crown-fire` (round 2) arms it and returns in under a minute. R3
`pds-w14-crown-collect-stamp` (round 3) collects, commits the transcript, and stamps — LEAD only,
never a builder alongside the rung it just ran. `pds-w14-peak-ledger-honesty` (round 1) rides beside
them, fixing the accounting blindness D244 exposed. **BUILD NO EIGHTH INSTRUMENT** — the launcher is
plumbing and measures nothing; the one thing this wave adds to the tree is a way to *leave*.

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

**Wave 12 — THE CROWN, ON THE STREAMING ENGINE** (paper `pds-wave-12-2026-07-21`). The memory
precondition that blocked waves 9–10 is GONE: the spill merged (#5083), the janitor merged (#5084),
and the deployed sha `bc64d869a` equals `origin/main`'s tip exactly. D217 measured the number that
proves it — worst 500-row COPY chunk is **19.71 MiB**, 0.9% of the frozen 2200 floor. The wave is a
strict four-round CHAIN, and the chain is the plan:

| R | # | Slice | Task | Files | Size | Model |
|---|---|---|---|---|---|---|
| 1 | 1 | Instrument merge-readiness — D220 fixes (a)+(b), push, PR | `pds-w12-instrument-merge` | `scripts/pds-export-peak-measure.sh`, `scripts/pds-export-cost-derivation.md` | medium | opus |
| 1 | 2 | Climb preconditions runbook — worktree, D223 tar rule, D224 formula, quietness re-check | `pds-w12-climb-runbook` | `scripts/pds-crown-climb-runbook.md`, `scripts/pds-climb-preflight.sh` | medium | opus |
| 1 | 3 | Stamp recipe — D226 fetch-to-file extractor + rehearsal | `pds-w12-stamp-recipe` | `scripts/pds-crown-stamp.sh`, `scripts/pds-crown-stamp-recipe.md` | small | opus |
| 2 | 4 | THE MEASURE — out-of-band, D219 bypass recorded, D221 threshold applied | `pds-w12-measure` | `scripts/pds-export-cost-derivation.md` | medium | opus |
| 3 | 5 | THE FLOOR — derive per D222, or refuse in writing | `pds-w12-floor-derivation` | `scripts/pds-export-cost-derivation.md`, `.claude/workflows/bp-pds-charter.md` | medium | opus |
| 4 | 6 | THE CLIMB — ONE unsplit `--all`, or a named refusal | `pds-w12-crown-climb` | `scripts/pds-pull-proof.crown-transcript-w12.txt` | large | opus |

Rounds 2–4 do NOT dispatch this run (sequenced-rounds law): slice 4 needs slice 1 ON MAIN, slice 5
needs slice 4's number, slice 6 needs slice 5's floor. Only round 1 builds. **A NAMED REFUSAL IS A
WIN** — if the measured demand does not land materially below 2235.43 MiB, D222's arithmetic puts
the floor above the box's own weekly maximum and the crown is unfireable; slice 5 then refuses in
writing with the number attached and slice 6 does not dispatch. That is strictly more than any prior
wave produced, because **no wave has ever measured this engine at all.**

## Wave log

### Wave 13 2026-07-21 — "Fire the Climb" — REVIEWED. THE CLIMB DID NOT FIRE. Grade C+ (paper `pds-wave-13-2026-07-21`)

**THE HEADLINE IS THE FAILURE, AND IT IS THE FOURTH IN A ROW.** The wave's stated success condition was
THE TRANSCRIPT EXISTS. It does not exist. `scripts/pds-pull-proof.crown-transcript-w13.txt` was never
written, the crown still reads **9/12**, and the pattern the wave was chartered to break — verify the
ground, find something real, build another instrument, don't take the shot — repeated with four more
instruments. No amount of quality in the four green slices changes that, and this entry leads with it
so no future reader mistakes a good review for a good outcome.

**HOW IT DIED, precisely, because the mechanism matters for wave 14.** It was NOT a refusal on the
merits and NOT a defect. The builder proved the freeze (`e219e97cc` by `rev-parse`, PDS-D154), booted a
fresh worktree off `origin/main`, embedded `$RUN_TAG` per PDS-D233, held all three non-actions (floor
untouched at 2200, no `PDS_STEP6_GUARD_DEMO`, `attempts` never reset), and armed a poller that would
fire the unsplit `--all` itself on a qualifying draw. **Guerrilla never offered one**: builds went idle
but MemAvailable read 1306 / 1725 / 1729 MiB against the untouched 2200 floor — the harness declining
correctly, exactly as PDS-D227 predicts. Then **the builder's turn was cut by the harness at poll 3 of
30**, and the worktree was reclaimed with the poller inside it. The shot was lost to AGENT-TURN LENGTH,
not to the box.

**THAT IS THE REAL FINDING OF WAVE 13, and it is a new one.** D227–D231 established the fire predicate
is near-deterministic and that polling is free. What nobody costed is that **a 30-poll × 10 s budget can
outlive the agent turn that owns it**, and a poller living in a workflow worktree dies with it. Every
prior wave's post-mortem blamed the window. This one cannot. **Wave 14 must make the fire survive its
launcher** — detach it from the agent turn, or fire from a persistent location, or shorten the wait so
the draw is taken inside one turn. Filing another instrument without solving this reproduces wave 13.

**NOTHING WAS BURNED.** `/tmp/pds-full-export/attempts` still reads **1**, so the `spent + 2` budget
(PDS-D224) is intact and wave 14 inherits a clean lever. The leaked scratch target was still LIVE at
review time (`beam.smp` on :48338, three Postgres on :21973, 76 MB under `/private/tmp/pds-w13.c0a98cf8`);
review ran `teardown` — PASS, both ports released, zero orphans, root removed.

**WHAT LANDED (four slices, all reviewed green, all file-disjoint, mergeable in any order):**

- `pds-w13-charter-lands` — **D217–D241 finally reach `origin/main`**, 431 insertions / **0 deletions**,
  one file, copied by git object (PDS-D90) never re-authored. This retires a real integrity hole: merged
  wave-12 scripts were citing D219/D223/D224/D226, text no reader of `origin` could resolve. Review
  independently read those four and confirms the citations are substantively honest — the check the
  builder correctly flagged as their own blind spot.
- `pds-w13-idle-sampler-strip` — `scripts/pds-idle-sampler.sh`, the lock-free paired control (PDS-D237).
  Takes no mutex, reads no floor, fetches nothing; both D220a refusals byte-identical to the parent.
- `pds-w13-scratch-cost-truth` — the boot-cost record stops lying by 4.75x. `ls -A api/_build` is coarse;
  the real trigger is **`api/_build/prod` ABSENT**, which costs a 155.72 s prod compile. Comments-only in
  the `.sh` (zero non-comment lines changed, proven).
- `pds-w13-stamp-epoch-guidance` — `pds-crown-stamp.sh` names the **stale-claim-epoch** rejection first,
  because `bp task pulse` bumps the epoch and across a 12-stamp climb that is the likeliest rejection.
  Review confirmed it live: pulsing the climb task moved its epoch 5 → 6 mid-review.

**CANDIDATE DECISIONS FOR WAVE 14 TO RATIFY (raised by review, not yet charter law):**

1. **THE PRE-WARM IS THE HIGHEST-LEVERAGE STEP IN THE RUNBOOK, AND IT NEEDS `CC=/usr/bin/clang`.** The
   climb ran the recipe for real and it **FAILED** first: `cc` resolves to the Claude CLI wrapper, so
   `argon2_elixir` dies with `error: unknown option '-g'`. With the override, dev+prod compiled clean and
   `up --verify` came back in **~10 s against the 155.72 s cold-prod figure**. `pds-scratch-target.sh`
   pins `CC` itself in `export_real_cc` (TRAP 2), but the MANUAL pre-warm bypasses the script entirely —
   which is exactly why the trap bit. Review committed the override into both the header and the cost
   record. Worth a D-number: without it an operator gets a failed pre-warm, not a slow one.
2. **A D220a GUARD MUST KEY ON THE VACUOUS PEAK, NOT ON THE SAMPLE COUNT.** Found by MUTATION during
   review. The guard tests `samples <= 0` but its own refusal text describes a NEGATIVE control — and
   those come apart: a log of well-formed lines whose `rss` field never arrived counts as samples > 0 and
   still peaks at 0 kB, yielding a **−191.63 MiB drift at exit 0**. Fixed in the new sampler (peak-keyed
   refusal, plus a non-refusing `negative_suspect` sign for the legitimately-negative blue/green case, no
   magnitude threshold invented per PDS-D232). **The parent `pds-export-peak-measure.sh` still has the
   hole and it feeds the floor re-derivation** — filed as `pds-bl-d220a-keyed-on-a-proxy`.

**WHAT WAVE 14 SHOULD TAKE:** merge these four, then dispatch `pds-w13-crown-stamp-and-seal` only after
a transcript exists. The wave is **one slice wide**: fire the climb, with the launcher problem above
solved first. Do not file a fifth instrument.

### Wave 13 2026-07-21 — "Fire the Climb" — DECIDED, 5 R1 slices building (paper `pds-wave-13-2026-07-21`)

> **Superseded as a status line, 2026-07-21 (review).** "5 R1 slices building" was true when written.
> Four built and passed review; the fifth, `pds-w13-crown-climb`, did NOT fire. See the review entry
> above. The decisions D227–D241 recorded below stand — none was reversed by the outcome.

THE PATTERN THIS WAVE EXISTS TO BREAK: waves 10, 11 and 12 each planned the climb and each shipped an
instrument instead. Net movement on the crown across three waves: ZERO, still 9/12. **Success this wave
is a committed transcript under one RUN_ID — anything else is failure, INCLUDING a better preflight.**

THE WINDOW IS OPEN AND THE BLOCKING PREMISE IS STALE IN THE WAVE'S FAVOUR. Verified at L1 during Decide:
guerrilla HEAD `859c137cd` (the spill engine #5083 AND the janitor #5084 are live) is a git-confirmed
ANCESTOR of origin/main `fd820ab66`, with none of the five intervening commits touching a deploy path —
`gh run list --workflow deploy.yml` shows its most recent run IS `859c137cd`, nothing in progress. At
03:14 UTC the box read **MemAvailable 2402.83 MiB, zero `bp-site-build-*` units running, SwapFree
1033.64 MiB, spill dir empty, lock free** — a firing draw on D227's predicate. **cond_c is the sole hard
blocker and its fix is pre-authorised and demonstrated** (D231).

FIVE PREMISES CORRECTED AT L1, three against the wave and two for it:
- AGAINST: cond_b is not a calm green (D227/D228) — but the volatility is *explained*, not merely
  measured: it is the `bp-site-build-*` channel at 99.19% vs 9.3% clearance, so the fire polls on
  build-idle FIRST. A ≥150 s window exists (212 s / 254 s measured), and n=1 episode travels with it.
- AGAINST: the idle sampler cannot ride free — it takes the harness's OWN lock and REFUSES beside a live
  climb (D237); the strip was built and contrast-proven, and it must not gate the fire.
- AGAINST: cond_d has no reservation semantics and the merge hold went unanswered (D238). Silence is not
  consent; the residual is accepted, not closed.
- FOR: the stamp tool is not lost — **PR #5133 MERGED 02:59:54Z and #5131 MERGED 02:56:32Z**, so
  `scripts/pds-crown-stamp.sh` and `scripts/pds-export-peak-measure.sh` are BOTH on main already.
- FOR: the parked bundle is stale by provenance, so the reuse guard refuses it and the climb takes its
  own fresh bytes — exactly what criterion 11 requires (D240).

THE MOVE THAT DISSOLVES THE PREREQUISITE CHAIN: wave 12's bootstrap deadlock was a claim about a live
number, and the live number contradicts it. **When the gate is open you walk through it; you do not first
build a better key.** Firing at the unmodified 2200 floor means NO bypass at all, so the transcript
carries no asterisk (D232). The floor re-derivation is NOT payable this wave — `19.71 + 798.81` mixes a
wire-byte figure into an RSS-delta slot, the exact unit error D185 forbids — and is filed as backlog
rather than allowed to delay a fourth consecutive wave.

THE STRANDED CHARTER IS RECOVERED. D217–D226 existed only on the primary checkout's unpushed local main
(`de42c2af0`) and on an unpushed branch; origin/main's charter carried **zero** hits for them, so every
wave-12 script comment citing D219/D223/D224/D226 cited text no reader of origin could verify. The block
is restored here VERBATIM via `git show` + `git apply` (PDS-D90 — copied, never re-authored), and landing
it on main is an explicit R1 slice rather than an assumption.

- R1 `pds-w13-crown-climb` (opus, L) — **THE FIRE.** One unsplit `--all`, fresh RUN_ID, unmodified floor,
  `PDS_FULL_EXPORT_BUDGET=3`, env pinned to `$RUN_TAG`-embedding paths (D233). Transcript OR a written
  refusal naming the exact rung. Sole file: `scripts/pds-pull-proof.crown-transcript-w13.txt`.
- R1 `pds-w13-charter-lands` (opus, S) — D217–D241 reach origin/main as a docs-only PR.
- R1 `pds-w13-idle-sampler-strip` (opus, S) — the lock-free sample-only derivative (D237).
- R1 `pds-w13-scratch-cost-truth` (opus, S) — the boot-cost record is wrong by 4.75× on a cold-prod
  worktree (D241); correct it and name the real COLD trigger.
- R1 `pds-w13-stamp-epoch-guidance` (opus, S) — re-apply the reviewed stale-claim-epoch rejection
  guidance onto current main (it is local-only and not a descendant of the merged tip).
- R2 `pds-w13-crown-stamp-and-seal` (opus, M) — the LEAD stamps 0–9 from the transcript, then 10 on
  merge, then **11 alone and last**. AFTER `pds-w13-crown-climb` and `pds-w13-charter-lands` merge.

### Wave 11 2026-07-20 — "The Spill" — R1 built + reviewed, grade A− (paper `pds-wave-11-2026-07-20`)

Wave 10 refuted the scheduling fix on measurement (0 of 61 joint clearances, D202). The crown's last
rung is unreachable by timing and reachable only by making the export not NEED 2.2 GB at once. This
wave builds the engine. Root task `pds-bl-streaming-workspace-export`.

**THE DEMAND IS FOUR STACKED MATERIALISATIONS, NOT ONE DOUBLING** — and D105/D199 name only two:
`run_copy_out/1` is `Repo.query!` + `IO.iodata_to_binary` (never streamed, no decision ever mentioned
it); the reduce retains every table in one live `dumps` map; `erl_tar.create` + `File.read!` makes a
second full copy; `send_resp(200, bundle)` a fourth. Wave 7 measured the sum at 2235.43 MiB, so the
frozen 2200 floor sits **35.43 MiB BELOW the demand it gates**. A fifth was found this wave: Bandit
gzips `send_resp` bodies for the CLI (D204).

**THE MECHANISM (all delivery-shape, ZERO fidelity change per D74).** PRODUCER —
`Ecto.Adapters.SQL.stream` over the COPY inside `Repo.transaction`, chunks written straight to a
per-table spill while folding `:crypto.hash_update` and accumulating `row_count`. CONTAINER —
`:erl_tar.open`/`add`-by-path (chunked at 64 KiB by erl_tar itself: a 20 MB file added with a
**12,960-byte process-memory delta**), manifest FIRST. TRANSPORT — `send_file`, Content-Length
preserved, zero client changes. HYGIENE — delete each spill as it is added; typed IO errors; a boot
janitor for the SIGKILL case.

**WHAT VERIFICATION CHANGED IN THE PLAN, ALL ADOPTED.** The tmpfs attack died (ext4, 13.27 GiB free).
The sandbox CAN host a COPY-bound cursor (39 fidelity tests green against a streamed producer). But
"zero test edits" is FALSE (29 failures under a path return; **exactly 2** under a preserved binary
contract — D205), byte-identity is NOT free (mode/uid/gid/charlist, manifest-FIRST — D207), the
charter had already ruled the other way on transport (amended by D204), the import justification was
invented (D214), disk-full escapes the honest envelope into a bare 500 (D209), and the reach is
blocked by three preconditions nobody had named (deferred by D212).

**R1 (dependency-free, file-disjoint, all opus):**

- R1 `pds-w11-spill-engine` (opus, L): the four moves end-to-end + `export_to_file/2` + the two named
  test edits + the pinned-mtime byte-identity test + D215's one-line control.
  Gate: `cd api && CC=/usr/bin/clang mix test test/barkpark/tenancy/workspace_bundle_test.exs
  test/barkpark/tenancy/workspace_bundle_dev_profile_test.exs
  test/barkpark_web/controllers/workspace_controller_test.exs` (79 tests green at baseline).
- R1 `pds-w11-spill-janitor` (opus, M): boot-time sweep of `bp-ws-bundle-*` / `bp-ws-spill-*` with a
  derived threshold and a liveness guard. New file + `application.ex`; disjoint from the engine.
- R1 `pds-w11-paired-control-measure` (opus, M): the D104 paired-control peak instrument, BESIDE the
  frozen harness. `scripts/pds-*` only; disjoint.

**R2 (deferred — the lead dispatches after the deps MERGE):**

- R2 `pds-w11-storage-honest-envelope` (opus, M) AFTER `pds-w11-spill-engine`: `BundleIoError`, the
  `storage_unavailable` 503 clause, the `:query_canceled` widening, the live free-space preflight.
- R2 `pds-w11-floor-rederivation` (opus, M) AFTER `pds-w11-spill-engine` + `pds-w11-paired-control-measure`:
  measure the deployed spill engine, re-derive the floor off the measurement, amend the env value.
  **Never before the engine is deployed (D211).**

**EXPLICITLY OUT OF SCOPE, in writing:** the import path (D214), `pds-w3-shares-fidelity` (D143), any
change to bundle CONTENT, any narrowing of the control bundle (D198), the crown climb itself (D212).
Fence: `api/lib/barkpark/tenancy/` + `internal/cli` + `scripts/pds-*`, PLUS explicit exceptions for
`api/lib/barkpark_web/controllers/workspace_controller.ex` (D199 flagged this) and
`api/lib/barkpark/application.ex` (janitor supervision only).

**REVIEW OUTCOME (2026-07-20, grade A−).** All three R1 slices built green and hold up on adversarial
read; every slice gate re-ran green on the reviewer's final state (engine 82/0, janitor 38/0, measure
bash-n+shellcheck+freeze-blob). Final branches for the lead to integrate, in order: engine
`loop-epic/the-spill-stream-the-copy-producer-tar-f-0-r`, janitor
`loop-epic/the-spill-janitor-collect-at-boot-what-a-1-r`, measure
`loop-epic/the-paired-control-peak-instrument-give--2-r`. ONE load-bearing defect found and fixed in
review: the janitor read config key `:workspace_bundle_spill_dir` while the engine writes to
`:bundle_spill_dir` — the janitor would have swept an empty dir forever while spills piled up out of
sight (the exact silent-wrong-answer this epic keeps killing). Aligned both onto `:bundle_spill_dir`.
Two moduledoc drifts also corrected (`export/2`'s stale "one non-test caller"; the janitor's key
prose). What this wave PROVES BY CONSTRUCTION but NOT YET BY MEASUREMENT: that peak RSS is materially
below 2.2 GB — the WISH's actual question — which is `pds-w11-floor-rederivation`'s (round 2) to
answer against the deployed engine; until then the crown's payability is an argument, not a number.
The liveness sidecar (`own/1`/`disown/1`) also ships UNWIRED (the fence forbade editing the engine),
so the derived 3600 s mtime cutoff is the only guard on a real box until round 2 wires it — folded
into `pds-w11-storage-honest-envelope`, which already edits `workspace_bundle.ex`. Ledger clean: all
three slices in_progress with real criteria stamped, only merge-gated "PR merged" left for the lead;
round-2 slices open/unclaimed by design; builder backlog (`pds-w11-router-export-comment-drift`,
`pds-w11-janitor-engine-handshake`) filed under the epic. MERGE ORDER for round 2: dispatch
`pds-w11-storage-honest-envelope` after the engine merges (same three files — must not run beside it);
dispatch `pds-w11-floor-rederivation` only after the engine is MERGED AND DEPLOYED and the measure
instrument has merged. Crown climb stays wave 12 (D212), gated on the measured floor.

### Wave 10 2026-07-20 — "The Predicate Refused Itself" — R1 built + reviewed, grade A− (paper `pds-wave-10-2026-07-20`)

**The crown's last rung is NOT paid, and the refusal is worth more than the payment would have
been.** Five round-1 slices, all green, all file-disjoint. The wish said pay criterion 10 in the
post-deploy memory window or refuse it again in writing. Wave 10 did neither of those things
exactly — it refuted the post-deploy premise itself (D190/D191), replaced it with an instrumented
check-and-go sentinel, fired that sentinel 61 times, and came back with a **measured proof that the
fire predicate is self-contradictory** (D202). Zero exports fired; `/tmp/pds-full-export/attempts`
reads 1 before and 1 after.

`pds-w10-instrumented-climb` is the wave. `scripts/pds-window-sentinel.sh` (382 lines) polls one ssh
round-trip per sample, carries the D192 preflight inline per D157 — which is why this wave *reached*
the climb where waves 5, 6 and 8 all put it in round 2 and never got there — writes nothing on the
remote, and logs every sample fire or stand-down. Preflight was clean on the first try; **preflight
was never the blocker.** 61 draws: legs i+iii+iv together 38/61, leg (ii) **1/61**, all four **0/61**.
The finding is D202: legs (i) and (ii) are two readings of the same axis with opposite signs, because
on a 3820 MiB box the headroom leg (i) reads is produced by the kernel swapping the BEAM out. Leg
(ii)'s only open window is the ~18 minutes after a slot restart — the exact interval D93/D190/D191
forbid entering. The builder could have greened criterion 4 in four seconds by raising the swap
ceiling and the sentinel refuses that by code so that nobody, including its author, can.

`pds-w10-window-availability-record` is the artefact that makes the verdict permanent either way, and
it **exceeded its brief in the one direction that mattered**: rather than transcribe the survey's
headline figures it re-derived the whole week live off the box, reproduced all four headlines to the
digit, then found that the ratified daily r=−0.59 / hourly r=−0.21 are *themselves* a `journalctl
--since '8 days ago'` truncation artefact (D203) and corrected them to −0.38 / −0.14 — identifying
the source by reproducing the published pair exactly from the truncated count. It also gave the
site-build contention channel its first corroboration beyond its own two samples (2228 units,
58.0% vs 85.1% clearing, and 41 sub-demand samples on a BEAM under 30 minutes old), which retires a
class of "unexplained" cond_b misses as sibling-cgroup contention.

`pds-w10-crit10-deadlock-reword` removed a deadlock nine waves never hit because it fails CLOSED and
so blocks only the green (D196). `pds-w10-fence-arithmetic` pre-declared the attribution arithmetic
before the climb so it could not be litigated after, and caught a **concurrent wave-10 actor patching
criterion 10 mid-slice** — recording it as a live instance of the D165 unfenced-patch hazard instead
of quietly reporting a clean diff. `pds-w10-scratch-target-truth` corrected a warm-path cost that was
wrong by ~4.5x (~90s claimed, 9.8–32.7s measured) and narrowed the re-pull 500 to rung 6's clobbered
state by running the clean experiment the blocker itself named as never-run.

**What the review changed.** Three fixes. (1) A real defect in the sentinel: `check_predicate_integrity`
compared the two predicate knobs with `[ -lt ]` but never validated they were integers, and
`[ abc -lt 2300 ]` is a bash error that evaluates FALSE — so `PDS_SENTINEL_MEM_FLOOR_MIB=abc` passed
the guard AND then disabled leg (i) at the same broken comparison in `take_sample`, making a 1200 MiB
draw read FIRE. Proven by mutation. The one guard whose entire job is to stop a manufactured green
could be disarmed by a typo; all four knobs are now integer-validated and `--max-samples 0` is
refused because it would report a STAND-DOWN with zero draws taken. (2) Both new crown records quoted
criterion 10's post-reword text as "the transcript of the **climb** that pays this criterion"; the
live array reads "**wave**" — a file whose central warning is that `--criterion-text` compares
byte-for-byte shipped a wrong copy. (3) The sign of r=+0.677 was clarified in the transcript, since
the headline invites the opposite reading.

**And the review landed the whole decision block into this charter**, because wave 10 carried no
charter-record slice: its five artefacts cited D190–D193 and D196 twenty-one times into a log that
ended at D189. D190–D201 are the Decide phase's own twelve, transcribed from the wave Paper's
`w10dec22` block and expanded with the evidence each rests on — the review's first pass wrongly read
D194–D200 as unallocated and would have shipped a D201 colliding with the Decide phase's wave-7-clock
decision; reading the Paper before writing the charter is what caught it. The build round's two new
findings are D202 (the leg tension) and D203 (the correlation correction).

**What stalled.** Criterion 10 remains unpaid and criteria 3/4 of the climb task are honest
`met=false` misses, not flips. `pds-w11-d193-leg-tension` (priority 0) carries the re-derivation, with
an explicit ban on resolving it by loosening.

**Next wave: re-derive the fire predicate before ever polling again.** The four candidate routes are
on `pds-w11-d193-leg-tension`; the one most likely to overturn D193 is that **leg (ii) may never have
been a sound proxy for export-time OOM risk at all** — leg (i) plus leg (iii) may already cover it,
and legs i+iii+iv cleared 38 of 61 draws. Any replacement needs a dataset spanning at least one slot
restart, because the monotone-VmSwap-climb claim rests on n=1 BEAM.

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

### Wave 15 — FIRE WHAT WAVE 14 BUILT, AND EXPECT THE REFUSAL (decided 2026-07-21, PDS-D250–PDS-D256, paper `pds-wave-15-2026-07-21`)

The wave arrived as DERIVE-THEN-ARM. The ground fact is that `pds-w14-crown-fire` and
`pds-w14-crown-collect-stamp` are both `open`, `claim:null`, 0/N met: **wave 14's rounds 2 and 3 were
filed and never dispatched. Nobody ever pulled the trigger.** Verification then did something the
direction did not plan for — it went and measured the thing the whole wave is gated on, and the
answer was worse than any prior wave's estimate.

- **PDS-D250 — THE FLOOR IS NOT CLEARING, AND D245's 76.2% IS SUPERSEDED. A COMMITTED STAND-DOWN
  DATASET IS THIS WAVE'S FIRST-CLASS WIN.** D245 read 32/42 = 76.2% off a PARTIAL file (159 of 360
  samples, no DONE sentinel) still inside a beam-RSS warm-up, and said so. Wave 15 took the completed
  measurement D245 never had: a **gapless 1200-sample, 1 Hz, 1249-second (20.8 min) window** on
  guerrilla yielded **862 build-idle draws and ZERO clearing 2200** — idle MemAvailable min/mean/max
  **1343.77 / 1865.40 / 1948.13 MiB**, a hard ceiling **251.87 MiB below the floor at every single
  sample**, longest contiguous clearing run **0 s** (there is no clearing draw to start one). Four
  further independent live reads the same morning: **1857.92, 1707.36, 1897, 1903 MiB**, all
  build-idle, all short. The recomputed full-dataset OLS (**slope −1.013, r −0.982, n=214**) confirms
  D246's mechanism but the live points sit **280–520 MiB BELOW what either model predicts** — the
  curve does not extrapolate out of its own window. **RULING: the expected outcome of this wave's arm
  is a STAND-DOWN, and a committed refusal dataset IS the deliverable, not a consolation prize.**
  Three consequences, each binding: **(a)** the draw budget goes UP — `MAX_DRAWS=2160` at
  `INTERVAL=10` (a six-hour window, vs. the one-hour default), because standing down costs nothing
  and a longer refusal is a RICHER dataset; **(b) the floor NEVER moves** — not by a flag, not by a
  numerator, not "just for this run" (D232); **(c)** the fire slice's success condition is *the child
  is armed and the turn ended*, never *the climb fired*. **This does not weaken the plan, because
  D245's other half stands untouched: cond_b is a GATE, NOT A WATCHDOG.** MemAvailable is read ONCE
  before the export and never re-read (D218), so a closing window **cannot fail the harness** — and
  the failed-precondition `return 1` sits ABOVE the spend increment, so **a closed gate costs ZERO
  attempts and arming is free.** Also newly measured and binding on the window: **leg B closes
  independently of memory** — a probe caught `bp-site-build-*` running while memory read 1365 MiB,
  six minutes after the same box read 1881 MiB with zero build units. The draw budget must span at
  least one full site-build cycle, and a stand-down dataset that does not break out **per-leg**
  refusal counts repeats an ambiguity no prior wave's data can resolve.

- **PDS-D251 — RUNG 4 FIRES FULL-STRENGTH OR NOT AT ALL, AND THE FIX IS TWO ENV LINES, NOT A SCRIPT.**
  The single highest-value finding of the wave, and exactly the "silent misfire in the handoff" the
  direction's second attack predicted. The original crown brief's **W5-E amendment (PDS-D79/D80/D102)
  requires `PDS_CONTROL_PG` EXPORTED and `PDS_AMMO_FILE` UNSET**, and **nobody carried it into the
  detached-launcher era**: `grep -nE 'CONTROL_PG|AMMO'` over `pds-crown-launch.sh` returns NOTHING,
  `pds-climb-preflight.sh` and `pds-crown-stamp.sh` likewise, and neither appears in
  `pds-w14-crown-fire`'s eight criteria. The degradation is silent by construction —
  `pds-pull-proof.sh:1730` gates the control on `[ -n "${PDS_CONTROL_PG:-}" ]` and the else-branch at
  `:1743` prints **`instrument control: NOT RUN`** at INFO level with **no `return`**, so step 4
  reaches a terminal PASS anyway. The practice died with the operator: `crown-transcript.txt:758` and
  `-w8.txt:705` both carry `instrument control: PASSED`; the w10 transcript carries neither string.
  **RULING: this is NOT a launcher defect and needs NO code change, because the fork is already
  transparent** — proven by execution, `PDS_CONTROL_PG` and `PDS_AMMO_FILE` set in the ARMING shell
  arrived **verbatim** at the harness across `fork → setsid → execvp → bash -lc → exec bash child.sh`
  (the launcher exports its own five vars and **scrubs nothing**). The remedy is two lines in the same
  shell as `arm`: `export PDS_CONTROL_PG=postgres` and `unset PDS_AMMO_FILE`. **`PDS_CONTROL_PG` is a
  maintenance conninfo for a LOCAL Postgres the scan CREATEs and DROPs a throwaway database in — it
  points at NO Barkpark database, and aiming it at guerrilla is a category error** (`pds-secret-scan.sh:297`
  defaults it to the bare `postgres`; PDS-D31 RAM LAW: it spends ZERO guerrilla export). Verified on
  this host today: `pg_isready` green, PostgreSQL 17.9, `pds-secret-scan.sh control --pg postgres`
  → **exit 0** with all three legs (fires on the bundle, fires on the target DB, clean on the
  deny-shaped bundle) and `psql -l | grep -c pds_secret_scan_ctl` → **0** after, no residue.
  **THE PRICE IS NAMED AND ACCEPTED: exporting `PDS_CONTROL_PG` converts a silent INFO line into a
  HARD-FAIL LEG.** If the laptop's Homebrew Postgres dies or the machine sleeps during a six-hour
  poll, rung 4 does not degrade — it FAILS with *"every clean result above is therefore
  uninterpretable"*, after an attempt is spent. **The trade is correct — an asterisk is FOREVER, a
  failed rung can be re-armed for free** — and it is paid for with a precondition, not a hope: prove
  `pg_isready` AND a control rehearsal exit 0 **in the arming breath** (zero guerrilla export, zero
  attempts), and keep the host awake. The mirror hazard is live and this wave's own plan creates it:
  a **STALE or PARTIAL** ammo file is precisely the quiet vacuous shape D102 names (the absurd poison
  `bp-export-v1` REDDENS at exit 1 — D80's "three greens" was wrong), and Move 3 rehearses on
  fixtures before the arm. `unset PDS_AMMO_FILE` in the same shell, immediately before `arm`.
  Note the anchors have DRIFTED: W5-E cites L1648/L1591–1594; current origin/main is **:1730** and
  **:1659–1662**. Carry the current numbers or none.

- **PDS-D252 — THE COLLECTOR'S STAND-DOWN CARVE-OUT FALSE-POSITIVES ON A REAL CRASH, AND IT IS FIXED
  IN CODE, NOT LEFT TO A TIRED READER.** `pds-crown-launch.sh:573` greps **UNANCHORED**
  `grep -c 'STAND-DOWN'` — but the child's own per-draw line (`:355`) prints
  `verdict=STAND-DOWN:mem<floor` on **every** non-qualifying draw. Proven by fixture, with the
  boundary located exactly: a crash whose FIRE landed on **draw 1** (zero refused draws) classifies
  correctly; **ONE** refused draw ahead of the FIRE flips it, and a transcript that FIRED, ran the
  harness and died mid-rung then prints *"STAND-DOWN, not a crash. The poll loop exhausted its draws
  and the harness was NEVER INVOKED… A closed gate costs ZERO export attempts; re-arming is free"* —
  on a run where the harness WAS invoked and an attempt WAS spent. Given **0/862 clearance (D250)**, a
  draw-1 fire is the improbable case, so **this misreport is the DEFAULT for any real mid-rung
  crash.** It also **INVERTS** the risk the ledger braced for: the worry was a spurious harness-bug
  task filed against a legitimate stand-down; the live behaviour is worse — the lead is told a genuine
  crash was free and **re-arms, burning a second real attempt against a budget of 5 while believing it
  free.** **RULING: anchor the grep.** Two clean discriminators already exist in the bytes:
  the stamp line `^\[…\] STAND-DOWN — ` (1 on a true stand-down, 0 on a crash) and the FIRE stamp
  `^\[…\] FIRE — draw ` / `harness returned rc=` (0 / 1 respectively). This is a **one-line
  correctness fix to a merged file inside the `scripts/pds-*` fence — it is NOT a new script and the
  ZERO-NEW-SCRIPTS law does not reach it**; the selftest gains a `crash-after-standdown` fixture so
  the defect can never re-enter silently. `pds-bl-w14-standdown-token-ruling` is **RE-SCOPED**: its
  premise *"the launcher mitigates this — collect greps for STAND-DOWN and names which of the two it
  is"* is **REFUTED by fixture**, and the belt-and-braces hand-grep stays in the collect brief anyway,
  because the lead must never depend on the collector's prose alone.

- **PDS-D253 — THE PASSENGER RIDES UNRATIFIED, AND IT STANDS DOWN WITH THE CLIMB.** The direction's
  one new idea was to let `pds-idle-sampler.sh` ride the crown's own unscoped export so PDS-D211's
  owed derivation falls out at zero marginal attempts. **The arithmetic is right and the NAME is not
  available.** Mechanically the sampler's delta is byte-identical to the licensed quantity —
  max-across-set peak minus a strictly-pre-window one-shot `ps -o rss=`, kB/1024, `pgrep -o -x` per
  D135. But **D237 charters it as a paired idle CONTROL** ("BUILD THE LOCK-FREE… SO A PAIRED IDLE
  CONTROL CAN RIDE BESIDE A LIVE CLIMB"), the instrument says so in its own voice — *"This is a
  CONTROL, not a demand… never subtract it from one"* — and **no decision anywhere licenses reading
  it as the D211/D222 demand figure** (693 search hits, zero prior art naming it one). Worse, D237's
  own role for it is **unattainable concurrently**: a window taken during a ~2.2 GiB export is not
  idle, so ridden beside a live climb it is **neither a valid control nor a licensed demand**, and
  D216 ("THE PAIRED IDLE CONTROL IS A PREREQUISITE… NOT A NICE-TO-HAVE") is unsatisfied because a
  control cannot be taken at the same time — that would be a second demand read. **RULING: run it,
  publish it as an UNRATIFIED OBSERVATION, and let a later wave promote it.** The committed record
  must carry the relabelling **adjacent to the number, never in a Paper the grep never reaches**,
  because the instrument's own labels are false in this context: the banner says
  `IDLE CONTROL WINDOW (… ZERO requests issued)` (`:309`), the machine line hardcodes
  `acquisition=none` (`:441`), and **every payload field is named `idle_*`** — a later wave grepping
  `idle_delta_mib` across this epic gets a demand figure back and reads it as drift. **That is the
  retraction, pre-loaded.** Three promotion conditions to record now and check later: `beam_slots`
  MUST be 1 and `beam_primary_pid` MUST be the exporting slot (the delta subtracts a PRIMARY-only
  baseline from a MAX-ACROSS-SET peak — on a blue/green box those are different processes; **dormant
  today, one deploy from live**); `idle_window_s` MUST be reconciled against the transcript's own
  `t1−t0` (the **130 s default is a WAVE-7 figure for the RETIRED in-memory engine**, and three
  unreconciled durations exist — 130 / ~150 / 193 s — while `pds-bl-w13-export-duration-unmeasured`
  is open at 0/5); and D221's 1048.16 MiB threshold applies to the **MemAvailable RANGE leg only**,
  never the RSS delta (D220b). **And the passenger is CONTINGENT: per D250 the climb probably never
  fires, in which case there is no export to ride and the sampler output is DISCARDED and the
  derivation returns to backlog. D237 verbatim — IT MUST NEVER GATE OR DELAY THE FIRE.** Not ready,
  not understood, or refusing → the climb fires without it. The floor does not move on this number:
  per D222 a floor is `measured demand delta + 798.81 MiB`, and this delta is not yet a measured
  demand.

- **PDS-D254 — THE FIRE RECORD IS THE HANDOFF, AND IT CARRIES WHAT `ps -p` CANNOT PROVE.**
  Five waves died before firing; this wave's NEW risk is dying AFTER, so the fire slice COMMITS a
  record naming pid, transcript path, RUN_TAG, budget, deployed sha and armed-at time — so **ANY**
  later actor, not only the one who armed it, can collect. Three fields are added because
  verification found gaps `ps -p` cannot close. **(a) `MAX_DRAWS` and `INTERVAL` actually in force**,
  with the resulting wall-clock window — the launcher prints both at arm and the auto-written `meta`
  file does NOT carry them, and per D250 the honest outcome is a stand-down the collector must be
  able to size. **(b) A PROCESS-IDENTITY FINGERPRINT — `ps -p <pid> -o comm=,lstart=` recorded at arm
  time.** `pid_live()` is `ps -p` and **nothing else**: no comm check, no start-time check, no
  cross-reference to anything the arm recorded, and the same unguarded call gates BOTH collect's
  STILL-RUNNING branch (`:512`) and arm's own stacking guard (`:427`). This host's pid space was
  observed **wrapping inside this very investigation** (top pid 96696, then fresh forks landing at
  81972–82479 ~15–20 min later) against a collect cadence deliberately measured in HOURS — so a
  recycled pid makes both call sites agree a dead climb is alive, collect says *"do NOT re-arm"*, and
  arm refuses too. **The escape hatch exists but is undiscoverable by the obedient**: `arm --force` is
  named only in the die message of the very action collect told the lead not to take. The fingerprint
  turns an unfalsifiable STILL-RUNNING into a two-command check. **(c) W5-E state** —
  `pds_control_pg_exported: yes|no` and `pds_ammo_file_state: unset|<path>` — recorded, never
  silently accepted as "no" (D251). Two hard rules on the record's contents: **NEVER dump `env`** —
  the child's real environment carries `BARKPARK_TOKEN=bp_admin_…` and `HETZNER_API_TOKEN=…`, and any
  "environment provenance" instinct leaks two live credentials into the repo; an allowlist of NAMED
  vars only (the launcher's own transcript prints exactly seven and is credential-safe as-is). And
  **arm from a stable path** — the child inherits the arming shell's cwd, and behaviour is untested if
  that directory is deleted while the child lives.

- **PDS-D255 — THE COMMITTED TRANSCRIPT IS OPERATOR-AUTHORED, AND THE `RAW RUN OUTPUT` MARKER IS
  CONDITIONAL.** The bare `transcript.log` is **unattributable on the likely outcome**:
  `grep -c run_id transcript.log` = **0** — the child stamps `run_tag=` only, the run id lives in
  `$STATE_DIR/<tag>/meta` under `/tmp` and is never committed, and on a FIRE the harness's banner
  (`:485`) and SUMMARY (`:2448`) self-attribute while **on a STAND-DOWN there is no banner, no
  SUMMARY, and therefore NO run identifier anywhere in the committed bytes.** Crown criterion 11 and
  PDS-D233 both key on a run id. Two things are called `run_id` and they DIFFER (`meta` says
  `20260721T065504Z-92007`; the harness's `RUN_ID` is the 8-hex `run_tag`, because `fire_detached`
  does `export PDS_RUN_ID="$run_tag"`) — **the citable one is the run_tag**, and the preamble must say
  so. **RULING: a preamble ALWAYS; the `RAW RUN OUTPUT` marker ONLY when harness bytes exist.** That
  string is emitted by the harness **zero** times — it is a hand-typed operator convention present in
  w7 (×2) and w8 (×1) and **absent from w10, which is the epic's STAND-DOWN precedent** (its §7 is
  "THE SENTINEL LOG IN FULL — 61 DRAWS"). On a stand-down the marker would name a section that does
  not exist. Size argues the same way: a 2160-draw stand-down is **~322 KB of DRAW lines** (149 B
  each, measured) — a dataset, not a scrap, and a dataset with no header is exactly the "did someone
  truncate this" doubt. The file is `scripts/pds-pull-proof.crown-transcript-w15.txt`. **One hazard
  the charter already paid for: wave 9's arithmetic slice inserted 12 lines into a preamble and then
  cited the raw region by its PRE-shift line numbers — three citations landed on unrelated text.
  Write the preamble FIRST and freeze it, or cite by grep anchor, never by line number.**
  Consequence for the ledger: `pds-w14-crown-collect-stamp`'s criteria 2 and 3 (which mandate the
  marker, unedited harness bytes, and matching banner/SUMMARY run-ids) are **STRUCTURALLY
  UNSATISFIABLE on a stand-down** and are amended to branch on the collect state.

- **PDS-D256 — THE CROWN IS UNCLAIMED, AND THE FIRST STAMP HARD-FAILS ON A REASON NOBODY DOCUMENTED.**
  `pds-w1-crown-proof` reads `execution_class: executable | lifecycle: open | claim.worker: None`
  (epoch 15, released `2026-07-20T04:47:25Z` by `reopen-prober`). Proven on a scratch task: stamping
  an unclaimed/open task is rejected **`bp: not_in_progress:open`** — and that reason string appears
  **nowhere** in `pds-crown-stamp.sh`, `pds-crown-stamp-recipe.md`, or `pds-w14-crown-collect-stamp`.
  The script's rejection block names only `fenced_off`/stale epoch ("THE LIKELY ONE") and
  `criteria_mismatch`, so a tired lead reads *"re-read the CURRENT epoch and pass that"*, runs the
  printed one-liner against an unclaimed task, gets `15`, re-stamps, fails identically, **and chases
  epochs forever** — the exact "dying AFTER the shot" failure Move 3 exists to prevent. **RULING:
  `bp task claim pds-w1-crown-proof <worker>` FIRST, then read the epoch from THAT claim.** No D139
  catch-22 applies (`claim.worker` is already null, `execution_class` is `executable`). The lead must
  also be told that **claiming is what re-arms the cmux Stop-hook auto-close** D140 describes: once
  the twelfth criterion flips, the hook closes the task with nobody typing it. Adjacent findings that
  ride with it: the stamp path is otherwise SOUND (fetch-to-file proven against a backtick-bearing
  criterion, stale-epoch rejected LOUDLY at bp exit 6 / script exit 2 with nothing written, read-back
  CONFIRMED); `pds-bl-stamp-silent-noop` **did not reproduce in 20 stamps across two race regimes** —
  6 exit-0 stamps all flipped `met`, 4 failures were all loud `fenced_off`, zero silent no-ops — so
  it is belt-and-braces, **not** grounds to close that backlog row and **never** grounds to bypass the
  script's mandatory read-back; and **one load-bearing case remains UNTESTED — re-stamping an ALREADY
  `met:true` criterion with new evidence**, which criterion 0 requires (its stored evidence is
  stale-in-substance). If that silently no-ops, the transcript's attribution is broken. One cheap
  scratch probe answers it, and it belongs BEFORE the fire.

**WAVE 15 PLAN.** Round 1 builds three in-fence corrections and one rehearsal, all dependency-free:
**(1)** anchor the collector's STAND-DOWN discriminator + a `crash-after-standdown` selftest fixture
(D252); **(2)** route BOTH runbooks to `arm|collect` and delete the refuted "~87% of the time" line
(`pds-crown-runbook.md:118`) — the launcher landed in ONE 958-line commit with **zero** documentation
and `grep -rln pds-crown-launch .` returns exactly one file, itself; **(3)** fold `not_in_progress`,
the met→met re-stamp measurement and stray-control-DB cleanup into `pds-crown-stamp-recipe.md`
(D256). Round 2 is `pds-w14-crown-fire` — **AFTER the collector fix merges**, so the transcript and
the collector that reads it agree. Round 3 is `pds-w14-crown-collect-stamp`, LEAD-ONLY, after the
fire lands. **The charter debt this wave inherited is ALREADY CLOSED**: PR #5247 is MERGED and
D242–D249 are on origin/main — no slice is filed for it.

### Wave 16 — DISPATCH THE FIRE (decided 2026-07-21, PDS-D257–PDS-D264, paper `pds-wave-16-2026-07-21`)

**WHAT LANDED FIRST.** Wave 15's four slices all merged between 09:21Z and 09:26Z on 2026-07-21:
#5381 (collector anchor), #5382 (both runbooks routed), #5383 (stamp recipe), #5366 (charter
D250–D256). `origin/main` now carries the anchored discriminator (`sd_stamp`/`fire_stamp`/`pw_stamp`
at `pds-crown-launch.sh:597-599`), `selftest` reports **40 ok · 0 FAIL**, and D250–D256 are readable
by any cold agent. The fire task's literal precondition — "AFTER `pds-w15-collect-anchor-fix` MERGES.
Do not start before it is on origin/main" — is therefore **SATISFIED, not overridden**. No written
override is needed and none is granted; the level-skip the digest warned about is moot.

- **PDS-D257 — THE 2400 TIGHTENING IS REFUTED BY MEASUREMENT. ARM AT THE UNTOUCHED 2200.** The
  direction's signature move was to tighten the LAUNCHER's own gate to `PDS_LAUNCH_MEM_FLOOR_MIB=2400`
  to cover D185's 2235.43 MiB demand. Four independent datasets kill it: **0 of 780** gapless 1 Hz
  samples clear 2400 (max **2276.42 MiB**, 123.58 MiB short), **0 of 31** paired live draws (max
  2267.71), **0 of 42** in D245's own steady-state slice (max **2395** — five MiB short of the floor),
  **0 of 1200** in D250. Zero clearances across >2000 samples in four regimes. On the D246 line
  (`MemAvailable ≈ 2973 − 1.178 × beam_RSS`, reproduced live to ±36 MiB over a 230 MiB RSS span) a
  2400 floor requires **beam RSS ≤ 486 MiB**, which on this box occurs only in the first ~15–20 minutes
  after a beam restart — precisely the post-restart transient **D93 REFUTES AND FORBIDS** and that D246
  warns the poller already structurally prefers. Setting 2400 would convert that preference into a
  requirement, so over `MAX_DRAWS=2160` the launcher could only ever fire on a forbidden draw. And the
  safety it was meant to buy does not exist: 2235.43 MiB is the **RETIRED in-memory engine's** demand,
  while D230/D217 put the deployed spill engine's worst single COPY chunk at **19.71 MiB** — 0.9% of
  the floor. The 08:13Z read that motivated the tightening (MemAvailable 2435, RSS 451.9) was not a
  second regime; it lies ON the D246 line (2435 + 1.178×451.9 = 2967.4) and was this line caught eight
  minutes after the 08:04:40Z restart that followed the api/** merge 515f14fdd. `sar` shows monotone
  decay 2679 (08:10) → 2410 (08:20) → 2280 (08:30) → 2161 (09:20); the 2400 window closed at roughly
  **08:22–08:28Z**, an hour before Decide. At 09:29Z the live read was **2007.7 MiB** — below even
  2200, with beam RSS 826.3 MiB on a 1h24m slot. **RULING:** leave `PDS_LAUNCH_MEM_FLOOR_MIB` UNSET.
  The launcher's own 2200 default governs, `PDS_FULL_EXPORT_MIN_MEM_MB` stays unset, and the
  transcript carries no asterisk (D232/D244/D245/D250(b): the floor never moves, "not by a flag, not
  by a numerator, not just for this run"). The 35.43 MiB pre-spill shortfall is **RECORDED in the fire
  record as an accepted risk**, not silently dropped and not hedged with a floor that cannot fire.

- **PDS-D258 — A FRESH WORKTREE CANNOT ARM. THE PRE-WARM IS PAID BEFORE THE ARM, NEVER INSIDE THE
  WINDOW.** Two independent verifiers live-proved the same kill: `arm` from a `git worktree add
  origin/main` with the DEFAULT pre-warm prints the full `ARMED — the climb now outlives this turn`
  banner and returns 0 in under a second, while the child dies seconds later on `** (Mix) Can't
  continue due to errors on dependencies` → `prewarm: FAILED rc=1 — NOT firing` → `EXIT: 1`, **ZERO
  draws taken**. A fresh worktree has neither `api/deps` nor `api/_build` (both gitignored). This is
  exactly the fire task's own mandated shape, and it would have spent the six-hour window on nothing,
  discovered only at collect. Nothing warns: `grep -nE 'deps\.get|prewarm|_build|mix '` over
  `pds-climb-preflight.sh` and BOTH crown runbooks returns **zero** matches in all three files. Nor can
  it be dodged by firing from the one deps-warm checkout — `spill-janitor-wt` sits on
  `fix/spill-engine-test-raciness` @ `ac1fb3beb` and `git merge-base --is-ancestor 515f14fdd
  ac1fb3beb` FAILS, so rung 0b (`pds-pull-proof.sh:660`) would abort. A fresh origin/main worktree is
  at exact sha parity with the deployed box and passes. **RULING:** the fire worktree runs `mix
  deps.get && MIX_ENV=dev mix compile && CC=/usr/bin/clang MIX_ENV=prod mix compile` to completion
  BEFORE arming, and then arms with **`--prewarm-now`** — which compiles synchronously in the arming
  shell and `die`s rather than arming (`pds-crown-launch.sh:441-444`), converting a silent
  window-killer into a loud arm-time refusal. The default pre-warm is FORBIDDEN for a fresh worktree.

- **PDS-D259 — SETTING `PDS_LAUNCH_HARNESS` IS THE FAILURE MODE; OMITTING IT IS CORRECT.** Wave 15's
  vacuous `rc=0` is fully explained and it is not a script bug. `pds-crown-launch.sh:109` reads
  `HARNESS="${PDS_LAUNCH_HARNESS:-$SCRIPT_DIR/pds-pull-proof.sh}"` with `SCRIPT_DIR` derived from `$0`
  via `cd -P`, so from ANY fresh worktree the default IS the real harness — proven by a rehearsal arm
  whose `child.sh` line 7 read `HARNESS=/private/tmp/pdsw16-rehearse/scripts/pds-pull-proof.sh`.
  `git grep PDS_LAUNCH_HARNESS origin/main` returns exactly ONE hit, line 109's own default; no shell
  rc file mentions it. The two surviving wave-15 forensics both carry line 7 `HARNESS=/tmp/
  pds-probe-harness.sh` beside `API_DIR=/private/tmp/pds-v1-wt/api`, a since-deleted rehearsal
  worktree — **a leaked interactive `export`, never persisted anywhere.** **RULING:** `unset
  PDS_LAUNCH_HARNESS` in the arming shell, assert `traps_set=0` before arming, and prove the result
  after: `sed -n '7p' child.sh | grep -qxF "HARNESS=<fire-worktree>/scripts/pds-pull-proof.sh"`. That
  one grep is the check that would have caught wave 15 inside its own turn instead of a wave later.

- **PDS-D260 — THE FORK IS TRANSPARENT, SO THE TWO W5-E ENV LINES ARE SUFFICIENT AND THE AMMO HAZARD
  IS THE STALE FILE, NOT THE EMPTY ONE.** Proven by execution against the real origin/main launcher: a
  stub harness's own env dump, written by the detached child, listed `PDS_CONTROL_PG=postgres` and
  `PDS_AMMO_FILE=/tmp/pdsw16-fake-ammo` alongside all five launcher-exported vars. The launcher forks
  via `os.execvp` (not `execve`), inheriting the whole environ with no allowlist; `bash -lc` profile
  sourcing strips no `PDS_*`. Neither variable appears anywhere in `pds-crown-launch.sh` or
  `pds-climb-preflight.sh` — nothing enforces or scrubs either. D251's prescription therefore needs no
  launcher change. **Correction to the survey's severity claim:** an EMPTY leaked ammo file fails
  LOUDLY (`pds-secret-scan.sh:265` dies "a scan with no ammo is not a scan", exit 2 → `fail 4`), and
  wrong-but-nonempty ammo is caught by the (c) positive control at `:1802` — but only AFTER an export
  is spent. The genuinely silent shape is a STALE ammo file whose values still live in the full bundle:
  dev CLEAN, target CLEAN, full FIRES, **three greens proving nothing about the current webhook secret
  set** — D102's exact shape. **RULING:** `export PDS_CONTROL_PG=postgres` and `unset PDS_AMMO_FILE` in
  the SAME shell as the arm, and assert the transcript carries the SSH-provenance line ("N webhook
  secret(s) pulled read-only from the source DB this run"), never merely the absence of a complaint.

- **PDS-D261 — `full_meta_ok` PASSES BY DEFAULT ON A NON-TAR BODY. THE FROZEN HARNESS IS NOT EDITED
  BEFORE THE SHOT; COLLECT CROSS-CHECKS INSTEAD.** The harness's only structural check on a downloaded
  bundle is permissive: `manifest_field()` (`:819-829`) returns EMPTY on extract failure *by design*,
  and `full_meta_ok` (`:1232-1240`) treats empty as the legacy-engine ACCEPT branch. Live-executed: a
  3041-byte HTML document placed at `$FULL_TAR` yields `manifest_field profile = []` and **`full_meta_ok
  rc=0` — ACCEPTED as a valid full bundle.** A Caddy 502 page, an auth-redirect body or a download
  truncated past 1 KiB all pass; `acquire_full_bundle` then returns 0, writes a `.meta` stamping the
  body with the run's pinned sha, and rungs 3/4 consume it as the differential control. **The transcript
  would read GREEN off a proxy error page** — and a six-hour climb against a memory-pressured live API
  is exactly where a 200-with-error-body is realistic. The check discriminates the tidy fake
  (`profile: dev` → correctly refused) and misses the messy one. **RULING:** the frozen blob
  `e219e97ccf7f33797c86a2b84d998d599b6bda31` is NOT edited before the shot — the climb must run against
  the instrument the criteria cite, and a mid-wave harness edit is the recession five waves died of.
  Instead **COLLECT gains a mandatory pre-stamp cross-check**: `file -b "$FULL_TAR"`, `tar -tf
  "$FULL_TAR" | head`, and the manifest's own `profile` field. **No criterion is stamped until that
  reads as a POSIX tar carrying `"profile": "full"`.** The defect is filed (`task-71ac606545fd2260`,
  priority 2) and fixed in a later wave, never mid-proof (standing law: every red sorts HARNESS BUG or
  ENGINE FAIL, both FILED, neither fixed mid-proof).

- **PDS-D262 — THE LAUNCHER IS ONE-SHOT, SO A MARGINAL FIRE THE HARNESS THEN REFUSES IS A THIRD
  OUTCOME.** On a FIRE verdict `pds-crown-launch.sh:362-366` runs `"$HARNESS" --all; rc=$?; sentinel
  "$rc"; exit "$rc"` — no re-arm, no loop continue. The harness then re-reads MemAvailable ONCE for
  `cond_b` (`pds-pull-proof.sh:1359-1361`), seconds to tens of seconds after the launcher's own probe,
  and the paired series shows consecutive 20-second draws swinging up to **~100 MiB** (2205.9 → 2163.6
  → 2225.9 → 2124.4). So a fire at ~2201 is roughly a coin flip to be refused immediately. That
  refusal costs **ZERO attempts** (the `return 1` at `:1363` sits above the spend at `:1365-1371`) but
  **burns the entire six-hour window**, because the launcher exits on the harness rc regardless. No
  prior decision named this. **RULING:** the fire record states THREE possible outcomes, not two —
  (a) FIRE and climb, (b) draws-exhausted STAND-DOWN, (c) FIRE then an immediate `cond_b` refusal at
  zero attempt cost with the window spent. All three are honest; only "never armed" is not. Do NOT
  add a re-arm loop — a self-re-arming rig is a NEW MECHANISM in a wave whose premise is that no new
  mechanism is needed.

- **PDS-D263 — THE PASSENGER RIDES ON THE PROVEN DETACH FORM, WITH THE FULL WINDOW, AND STILL NEVER
  GATES.** `pds-idle-sampler.sh` was live-proven to take no mutex, issue zero HTTP requests, write
  nothing on guerrilla, and survive `& disown` past a turn end (reparented to ppid 1) — and it ran
  CLEAN this morning at exit 0, 780/780 samples both legs, `idle_drift_sign=ok`,
  `threshold_applied=none`. But two hazards are now measured. **(a)** `& disown` is precisely the form
  D243 already proved DIES to `kill -TERM -<pgid>` — a closing tmux pane reaps it — so the sampler is
  launched with the SAME `python3` fork+setsid+execvp form `cmd_arm` uses (an already-merged, audited
  technique; no new script). **(b)** On any early termination the `trap cleanup EXIT INT TERM` `rm
  -rf`s `WORK_DIR` **before** the script's own peak logic reads it, so a killed run with 34 real
  samples self-reported "**ZERO samples … almost certainly lost its ssh session**" — the failure is
  total, not partial, and its own diagnostic misleads. **(c)** The `--window` default of 130 s is
  calibrated to the RETIRED engine and would truncate beside a six-hour climb; pass `--window 21600`
  (2160 × 10) explicitly. **RULING UNCHANGED FROM D237/D253:** the sampler is launched AFTER the arm
  returns and MUST NOT GATE OR DELAY THE FIRE. Not ready, not understood, or refusing → the climb
  fires without it and the record says `sampler_launched: no`. `sampler_launched: yes` is never
  load-bearing for the crown.

- **PDS-D264 — THE FIRE RECORD IS `scripts/pds-w15-fire-record.md`; THE CRITERIA ARE THE GATE.** The
  fire task contradicted itself in three places: `content.files` and the legacy `brief.blocks`
  definition-of-done both said `pds-w14-fire-record.md`, while `acceptance_criteria[7]` and the
  description (both amended 2026-07-21T07:21:57Z) said `pds-w15-fire-record.md`. **RULING:** the
  criteria are the gate and the filename is NOT renumbered mid-flight — `content.files` is patched to
  `scripts/pds-w15-fire-record.md` and the contradiction is closed rather than adjudicated twice.
  Renaming to a wave-16 form would force a criterion-text edit for a purely cosmetic gain, and every
  criterion-text edit is a new `criteria_mismatch` surface (D226).

**WAVE 16 PLAN.** Round 1 is two dependency-free slices. **(1) `pds-w14-crown-fire` — THE SHOT**
(scripts/pds-w15-fire-record.md): claim the already-perfected task, cut a FRESH worktree at
origin/main, pay `deps.get` + both compiles, re-verify the five preconditions in the same breath as
the arm, `unset PDS_LAUNCH_HARNESS PDS_AMMO_FILE PDS_FULL_EXPORT_MIN_MEM_MB PDS_LAUNCH_MEM_FLOOR_MIB`,
`export PDS_CONTROL_PG=postgres`, arm `--prewarm-now --max-draws 2160 --interval 10`, prove `child.sh`
line 7, confirm the child ONCE with `ps -p`, launch the passenger, commit the record, push, open the
PR, END THE TURN. No polling. **(2) `pds-w16-cold-worktree-trap`** (scripts/pds-climb-preflight.sh +
both crown runbooks): teach the preflight to REFUSE a cold tree and route both runbooks through
`deps.get` + `--prewarm-now`, proven by mutation in a genuinely cold worktree — file-disjoint from the
shot, which touches no `.sh` at all (its criterion 11 demands an empty `git diff --stat`). Round 2 is
`pds-w14-crown-collect-stamp`, **LEAD-ONLY, never the agent that fired**, dispatched after the fire
merges: six named states, `ps -p` never `pgrep`, D248 stranded-lock recovery, the D261 bundle
cross-check BEFORE any stamp, criterion text fetched to a file and passed by `"$(cat f)"`, evidence
terse against the ~9–11 KB request-line ceiling, 0–9 from the one transcript, 10 on merge, 11 LAST
and ALONE. **ZERO NEW SCRIPTS** and the frozen harness blob is untouched.

### Wave 18 — BOOT THE SCRATCH TARGET AND RE-FIRE THE CROWN (decided 2026-07-21, PDS-D265–PDS-D267, paper `pds-wave-18-2026-07-21`)

**WHAT LANDED / WHAT MOVED.** Wave 16 pulled the trigger for real (run `1b515ee5`, run_id
`20260721T095512Z-60807`, the REAL frozen harness): DRAW 1 mem 2578 ≥ 2200 → FIRE, a genuine 1.4 GB
full export was taken (`/tmp/pds-full-export/full-default.tar`, 1,405,095,424 bytes, attempts 3→4),
result **5 PASS · 6 ABORT · 0 FAIL rc=2** — the transcript's own words: "This is the honest partial
artifact … it is NOT a green." The **sole** blocker was `env:scratch-target-not-booted`, not an
engine failure. Wave 17 died at Digest under the spend limit with no slices built. Wave 18 is a FRESH
wave that removes that one blocker and re-fires. Three premises the lead built wave 18 on were
re-measured this turn and TWO of them moved.

- **PDS-D265 — THE FREE RE-FIRE IS DEAD; WAVE 18 PAYS ONE FRESH FULL EXPORT AT BUDGET spent+2.**
  Wave 16 fired against served_sha `8eeaf688…` which WAS the live deployed sha at 09:55Z (the lead's
  own p0 recorded the match — correct at the time). Guerrilla has since auto-deployed: live HEAD read
  fresh over SSH this turn is **`e16869ac06e2861f91b4359599d7f8311e035f6f`** (`.instance-deploy-last`
  matches, deployed 2026-07-21T16:12:13Z). The parked `full-default.tar.meta` still reads
  `8eeaf688…` (v0.2.25.1494) — a **MISMATCH**, so `acquire_full_bundle`'s PDS-D20/D223 provenance gate
  REFUSES the parked bundle and rungs 3/4 must take a **fresh export, spending one attempt**. Local
  `/tmp/pds-full-export/attempts` reads **4** (host-authoritative, D156). CRITICAL: `FULL_BUDGET`
  defaults to **1**, so gate (c) `spent < budget` is ALREADY FAILING (4 ≥ 1) unless the budget is set —
  `fire_detached` computes `PDS_FULL_EXPORT_BUDGET=spent+2` in one contiguous shell at fire time (=6
  now, D224/D249), never a literal; the slice **re-cats `attempts` at fire time** and asserts
  `budget > attempts`. The brief's quoted "069c6e98 / v1505 live" is ITSELF already stale — never quote
  a cached sha; re-ssh at fire time. **The economics revert from wave 16:** the expensive, dangerous
  export is NOT pre-paid, so **HEADROOM is now the gating risk**, not the attempt count.

- **PDS-D266 — THE BOOT PRECEDES THE ARM AT THE RUN_TAG-DERIVED HOME; THAT AGREEMENT IS
  OPERATOR-ENFORCED THIS WAVE.** Wave 16's one blocker is fully diagnosed and live-reproduced:
  `cmd_arm` **neither boots the scratch target nor asserts `scratch.env` exists**. It unconditionally
  exports `BARKPARK_HOME=/tmp/pds-w14.$run_tag` where `run_tag = $(printf '%s' "$PDS_RUN_ID" | cksum |
  awk '{printf "%x",$1}')`, and if `PDS_RUN_ID` is unset it invents a `date+$$` run_tag that no
  pre-boot could ever target; the harness reads `$BARKPARK_HOME/scratch.env` and **ABORTS if absent**
  (it never boots). That is exactly why rungs 0c/1/2/5/6 aborted in wave 16 and burned attempt 3→4.
  **RULING:** the fire slice (a) PINS `PDS_RUN_ID`, (b) derives `run_tag` by the identical cksum
  recipe, (c) pre-boots with `BARKPARK_HOME=/tmp/pds-w14.$run_tag
  PDS_SCRATCH_POINTER=/tmp/pds-scratch.pds-w14.$run_tag.last scripts/pds-scratch-target.sh up
  --verify`, (d) **ASSERTS `test -f /tmp/pds-w14.$run_tag/scratch.env` BEFORE arming**, (e) arms with
  the SAME `PDS_RUN_ID`. If `scratch.env` is absent → **HONEST ABORT, do not arm** (zero attempts).
  The boot is PROVEN GREEN on a fresh origin/main worktree this turn: `up --verify` → exit 0, a valid
  9-export `scratch.env` (quoted `PDS_SCRATCH_DB` conninfo, w6 trap held), the negative control fires
  (`env -u BARKPARK_MEDIA_DIR` resolves to the running tree's `api/uploads`), no OOM, **~188 s fully
  cold** (deps absent + both compiles) — pre-warm OFF the clock per D258. Teaching `cmd_arm` to assert
  `scratch.env` at its derived home is the durable class-fix but is **BACKLOG**
  (`pds-bl-launcher-assert-scratch-env`), not built this wave: a launcher edit makes the fire round 2
  and delays the seal, against ZERO-NEW-SCRIPTS and the finish mandate.

- **PDS-D267 — HEADROOM IS MARGINAL BUT 2200 STAYS; DO NOT TIGHTEN.** The "phantom headroom" framing
  did not survive a real window. A 30-sample / 6-minute live sampling this turn read **min 2037.8 /
  mean 2145.0 / max 2238.7 MiB, only 3/30 (10%) clearing 2200** — yet within ~2 minutes MemAvailable
  recovered to ~2950 MiB and kept climbing (the box swings 900+ MiB in minutes; a single point sample
  in EITHER direction is the D92/D112 trough trap). The 2200 floor is nonetheless hugely conservative:
  the deployed **spill** engine's real peak from wave-16's own fire is **~477 MiB** (parked `.meta`
  `rss_peak_kb 488564 / rss_baseline_kb 388044`, +98 MiB incremental — apples-to-apples with the
  RETIRED in-memory engine's 2235.43 MiB via the same 1 Hz `ps` sampler). **RULING (reaffirms D257):**
  leave `PDS_LAUNCH_MEM_FLOOR_MIB` and `PDS_FULL_EXPORT_MIN_MEM_MB` UNSET — the floor is tighten-only
  and RAISING it above 2200 only shrinks an already-thin window for zero real safety (engine needs
  ~477). The arm polls up to `--max-draws 2160 --interval 10` (6 h) and either FIRES on a
  high-regime draw or STANDS DOWN honestly (exit 5, ZERO attempts). Per D262 there are THREE honest
  outcomes — FIRE-and-climb, draws-exhausted STAND-DOWN, or FIRE-then-immediate-`cond_b`-refusal
  (zero attempts, window spent). A NAMED ABORT that never opens a safe window is a WIN, not a failure;
  the crown stays honestly at 9/12 with the scratch target proven bootable for the next attempt.

**WAVE 18 PLAN.** One round-1 slice; one round-2 LEAD-only seal (returned as a deferral, NOT built
this run). **Round 1 — `pds-w18-crown-fire` — THE RE-FIRE** (`scripts/pds-w18-fire-record.md`): cut
a FRESH **persistent** worktree at origin/main (it must OUTLIVE the turn for the detached child — not
an ephemeral builder tree), pay `deps.get` + both compiles off the clock, PIN `PDS_RUN_ID`, pre-boot
scratch at `/tmp/pds-w14.$run_tag` with `up --verify`, **assert `scratch.env` exists**, re-cat
`attempts` and re-ssh guerrilla HEAD in the same breath as the arm to confirm reuse-dead and set the
budget, `unset PDS_LAUNCH_HARNESS PDS_AMMO_FILE PDS_FULL_EXPORT_MIN_MEM_MB PDS_LAUNCH_MEM_FLOOR_MIB`,
`export PDS_CONTROL_PG=postgres`, arm `--prewarm-now --max-draws 2160 --interval 10` with `PDS_RUN_ID`
set, prove `child.sh` line 7 = the fire worktree's `pds-pull-proof.sh` (D259), confirm the child ONCE
with `ps -p`, record run_id + run_tag + pid + transcript path + scratch home + budget + floor in the
fire record, push, open the PR, END THE TURN — **no polling**. builder: opus. **Round 2 (deferred,
LEAD dispatches after the fire merges) — `pds-w18-crown-collect-and-seal`**: LEAD-ONLY, never the
agent that fired. Collect via six named states (`ps -p` never `pgrep`), D248 stranded-lock recovery,
the D261 bundle cross-check (`file` / `tar -tf` / manifest `profile == full`) BEFORE any stamp,
criterion text fetched to a file and passed by `"$(cat f)"`, evidence terse. Re-stamp **ALL of 0–9**
(not just the unmet rows — the currently-met criteria carry NO shared run_id, so criterion 11's
byte-identical check fails unless every one is re-stamped) with the ONE wave-18 run_id, **10 on merge
with the merge SHA recorded**, **11 LAST and ALONE** (disarms the cmux Stop-hook false-close). If any
rung refused: stamp NOTHING, record the refusal in the paper, file the successor. **ZERO NEW SCRIPTS**
and the frozen harness blob is untouched.

---

## WAVE 19 — ARM CLEAN, FIRE ONCE (2026-07-21)

Wave 18 armed a re-fire and it FIRED, ran the full ladder, and FAILED honestly at rung 0b/8: the lead
was merging PRs during the ~90 s climb, so guerrilla's deployed sha kept advancing AHEAD of the fixed
fire worktree, voiding the deploy-provenance ancestry check. Not an engine defect — a moving source.
The lead has now **FROZEN all merges**. Everything is aligned at L1 (re-measured at decide time):
scratch c7528814 ALIVE (`curl 37576` → 200), guerrilla `34b9b25d` an ANCESTOR of frozen origin/main
`58862f62`, memory window open (thin), `attempts`=4. The honest outcome this wave is a FIRED climb.

- **PDS-D268 — ARM CLEAN, FIRE ONCE; ZERO NEW SCRIPTS.** Reuse the LIVE c7528814 scratch (do NOT
  re-boot unless `curl 37576` ≠ 200 proves it dead), cut a FRESH persistent worktree at current
  origin/main, arm the detached climb, return. One round-1 arm slice + one round-2 LEAD-only seal.
  Rivals rejected on measured grounds: (B) harden `cmd_arm` first delays the seal against the finish
  mandate and forecloses nothing (the class-fix `pds-bl-launcher-assert-scratch-env` lands AFTER the
  crown); (C) boot a fresh scratch pays a ~188 s cold boot whose memory contention competes with the
  export and abandons the alignment — and its ONLY advantage (schema coherence) is dissolved by D271.
  Everything aligned NOW ⇒ every hour of hardening/rebooting is an hour the merge-freeze holds the
  whole repo hostage and the window can close. A fired climb is minutes from a high-regime draw.

- **PDS-D269 — THE STATE-DIR TRANSCRIPT COLLISION: ARCHIVE THE STALE RUN DIR BEFORE ARMING.** THE ONE
  hazard no prior PDS-D covered (5 surveyors + a deep verify converged). Reusing
  `PDS_RUN_ID=pdsw18-crown` reuses `run_tag=c7528814`, which reuses BOTH `BARKPARK_HOME` (intended)
  AND the launcher's own STATE_DIR run dir `/tmp/pds-crown-launch/c7528814/` (unintended). That dir
  ALREADY holds wave-18's COMPLETE FAILED transcript (554 lines, terminal `RESULT: FAIL` / `EXIT: 1`).
  `fire_detached` opens `transcript.log` with `os.O_APPEND` (NEVER truncates), and `classify()` /
  `collect` grep the WHOLE file for `^EXIT:` / `^RESULT:` — so `collect` reads FINISHED off the stale
  wave-18 lines while wave-19 is mid-climb, and the seal can scrape wave-18's FAIL. That is exactly
  the criterion-11 single-run fence violation. **RULING:** before arming, ARCHIVE the whole run dir
  aside — `mv /tmp/pds-crown-launch/c7528814 /tmp/pds-crown-launch/c7528814.wave18-<UTC>`. This yields
  a clean transcript at the same path, PRESERVES `BARKPARK_HOME=/tmp/pds-w14.c7528814` (derived purely
  from `run_tag`, code-DISJOINT from STATE_DIR) and `PDS_SCRATCH_POINTER`, AND keeps the anti-stack
  guard FUNCTIONAL. Prefer archive-in-place over a `PDS_LAUNCH_STATE_DIR` override: the override BLINDS
  the anti-stack guard (a fresh STATE_DIR cannot see a prior live climb), which matters given live
  concurrent survey-fleet activity on the box. wave-18 child pid 83700 is DEAD (`ps -p` gone) so no
  live-stack today, but archive-in-place is the safe default. Durable class-fix (run-scoped fresh
  transcript on re-arm) is BACKLOG `pds-bl-launcher-statedir-fresh-transcript`, not built this wave.

- **PDS-D270 — 0b's TREE COMES FROM `$0`, NOT PDS_SCRATCH_TREE: INVOKE BY PATH.** Correction to any
  "re-point PDS_SCRATCH_TREE" framing. rung 0b's `worktree_sha` = `git -C "$REPO_ROOT" rev-parse HEAD`
  where `REPO_ROOT` derives purely from `$0` (`pds-pull-proof.sh:88-89`). `PDS_SCRATCH_TREE` (stale at
  `barkpark-w18-fire` in `scratch.env`) is INERT for 0b — it only feeds the target reboot machinery.
  So there is NO env fix and NO re-point: the ONLY lever is invoking `scripts/pds-crown-launch.sh`
  **BY PATH from inside the fresh worktree** so `$0`'s dir → `REPO_ROOT` → the fresh HEAD. Wave-18's 0b
  failure was `DEPLOYED_SHA` (live SSH) advancing past the fixed fire worktree as merges moved
  guerrilla — the freeze fixes that root cause directly, zero code/env change.

- **PDS-D271 — THE COPY HAZARD DISSOLVES BY MIGRATIONS-SUBTREE IDENTITY, NOT ANCESTRY.** Correction:
  "guerrilla `34b9b25d` is an ancestor of the scratch's origin sha `6782db5d`" is FALSE — they are
  UNMERGED SIBLINGS (`6782db5d` lives only on `origin/pds/w18-fire`, never merged to main;
  `merge-base --is-ancestor` fails both directions). PDS-D32's COPY-fails-on-CHECK/enum-widening
  hazard nonetheless does NOT bite: `git diff --stat 6782db5d 34b9b25d -- api/priv/repo/migrations` is
  EMPTY and both shas `ls-tree` to the identical 182 migration files. rung-1's COPY of guerrilla data
  is safe because the `migrations/` subtree is BYTE-IDENTICAL between the scratch's origin sha and
  guerrilla's deployed sha, **regardless of branch topology**. Cite migrations-subtree-identity, not
  ancestry.

- **PDS-D272 — PDS_LAUNCH_HARNESS STAYS UNSET; THE BY-PATH DEFAULT IS CORRECT (reaffirms D259).**
  Correction: do NOT `export PDS_LAUNCH_HARNESS` — setting it is the D259 failure mode (wave-15's
  silent vacuous pass). `HARNESS="${PDS_LAUNCH_HARNESS:-$SCRIPT_DIR/pds-pull-proof.sh}"`; invoking the
  launcher by path from the fresh worktree makes the DEFAULT resolve to that worktree's own frozen
  `pds-pull-proof.sh` (blob `e219e97c…`). `child.sh` line 7 = `HARNESS=…` is the proof; the arm UNSETS
  `PDS_LAUNCH_HARNESS` explicitly alongside `PDS_AMMO_FILE PDS_FULL_EXPORT_MIN_MEM_MB
  PDS_LAUNCH_MEM_FLOOR_MIB`, and SETS only `PDS_CONTROL_PG=postgres` + `PDS_RUN_ID=pdsw18-crown`.

- **PDS-D273 — NO PGDATA RESET; THE FRESH FULL PULL OVERWRITES ALL WAVE-18 RESIDUE.** The scratch DB
  is dirty (wave-18 dev-profile merge pull + 34 clobbered guarded rows + empty `pull_provenance`), but
  `up` does not reset pgdata (`mkdir -p` on the existing home; only teardown `rm -rf`) and this wave
  reuses the live target without `up` anyway. rung-1's fresh full-profile `--merge` pull overwrites
  every residue class: `merge_upsert` (ON CONFLICT PK DO UPDATE) converges docs + restores the 8
  guarded columns; `stamp_provenance` re-writes a fresh non-empty `pull_provenance` AFTER import.
  rung-2 asserts bundle⊆target (robust to residue extras); rung-6 sentinels/measures against wave-19's
  OWN fresh pull, never the stale empty stamp. No wipe step needed.

- **PDS-D274 — BUDGET spent+2=6 IS WIRED INTO THE FORKED SHELL; DO NOT SET PDS_FULL_EXPORT_DIR.**
  `fire_detached` reads `spent` from `/tmp/pds-full-export/attempts` (=4) and
  `export PDS_FULL_EXPORT_BUDGET=$((spent+2))` INLINE, one shell, before the `os.fork()`/`execvp` (no
  env dict → child inherits it); its selftest seeds attempts=7 and asserts the child reads 9, failing
  loud on the silent default of 1. `cond_c` reads the identical `FULL_ATTEMPTS_FILE` default
  (`/tmp/pds-full-export/attempts`) and `FULL_BUDGET` from that same var. The launcher never sets
  `PDS_FULL_EXPORT_DIR`; the arm must NOT export it either (it would break the launcher↔harness
  attempts-file identity). Re-read `attempts` at fire time (D224), never a literal. Parked bundle stale
  (served_sha `8eeaf688` ≠ guerrilla `34b9b25d`) → provenance gate refuses reuse → a fresh export is
  attempt **5 of 6**.

- **PDS-D275 — THE FREEZE IS VERBAL; RE-RUN 0b IN THE SAME BREATH AS THE ARM.** 0b holds at decide
  time (guerrilla `34b9b25d` an ancestor of origin/main `58862f62`, re-measured this turn). But the
  freeze is a coordination convention, NOT a machine gate — 6 open+mergeable `api/**|cloud/**` PRs
  (#5482, #5480, #5479, #5478, #5473, #5472; NONE with auto-merge) could reproduce the wave-18 deploy
  storm if merged. **RULING:** the arm slice re-runs
  `git merge-base --is-ancestor <guerrilla-HEAD> <fresh-worktree-HEAD>` in the same breath as the arm
  and fires ONLY if it exits 0; else HONEST ABORT (do not arm, zero attempts). The detached climb's own
  rung 0b re-checks live at fire time, so a mid-window merge still fails honestly rather than
  fabricating. Memory window is thinner than the strategize headline (~2200–2270 measured, not
  ~2380–2420): outcome-C (FIRE-then-`cond_b`-refusal, zero attempts, window spent) is real but
  non-blocking — the detached child waits up to 6 h for a high-regime draw. Never lower the 2200 floor.

**WAVE 19 PLAN.** One round-1 slice; one round-2 LEAD-only seal (returned as a deferral, NOT built this
run). **Round 1 — `pds-w19-crown-fire` — THE ARM** (`scripts/pds-w19-fire-record.md`, builder: fable):
confirm scratch alive (`curl 37576` = 200; boot only if dead); **ARCHIVE the stale state dir** (D269);
cut a FRESH **persistent** worktree at current origin/main (must OUTLIVE the turn for the detached
child); pay `deps.get` + both compiles off the clock; re-cat `attempts` and re-ssh guerrilla HEAD and
re-run the 0b `merge-base --is-ancestor` in the SAME breath as the arm (D275) — abort honestly if it
fails; `unset PDS_LAUNCH_HARNESS PDS_AMMO_FILE PDS_FULL_EXPORT_MIN_MEM_MB PDS_LAUNCH_MEM_FLOOR_MIB`,
`export PDS_CONTROL_PG=postgres PDS_RUN_ID=pdsw18-crown`; invoke the launcher BY PATH from the fresh
worktree (D270/D272) `--prewarm-now --max-draws 2160 --interval 10` DETACHED; prove `child.sh` line 7 =
the fire worktree's `pds-pull-proof.sh` (D259); confirm the child ONCE with `ps -p`; record run_id +
run_tag + pid + transcript path + scratch home + budget + floor in the fire record; push; open the PR;
END THE TURN — **no polling**. **Round 2 (deferred, LEAD dispatches after the CLIMB completes) —
`pds-w19-crown-collect-and-seal`**: LEAD-ONLY, never the agent that fired. Collect via six named states
(`ps -p` never `pgrep`), D248 stranded-lock recovery, the D261 bundle cross-check (`file` / `tar -tf` /
manifest `profile == full`) BEFORE any stamp, criterion text fetched to a file and passed by
`"$(cat f)"`, evidence terse. Re-stamp **ALL of 0–9** (the currently-met rows carry NO shared run_id)
with the ONE wave-19 run_id, **10 on merge with the merge SHA recorded**, **11 LAST and ALONE**. If any
rung refused: stamp NOTHING, record the named refusal in the paper, sort each red HARNESS-BUG vs
ENGINE-FAIL and file the successor (never fix mid-proof). **ZERO NEW SCRIPTS**; frozen blob untouched.

### Wave 20 — DERIVE THE REAL FLOOR, THEN FIRE

- **PDS-D276 — THE FLOOR IS DERIVED AT 897 MiB; D232 AND D244 ARE SUPERSEDED ON THEIR NUMERIC RULINGS.**
  Wave 19 measured the wall directly: over 618 draws (run `c7528814`, 16:56–18:44Z) `MemAvailable`
  ranged **1796–2012 MiB, cleared 2200 in 0 of 618**. The box's regime does not reach the fossil floor;
  a climb gated at 2200 never fires here. The 2200 default is the RETIRED in-RAM engine's scarcity
  figure; the DEPLOYED engine is the streaming spill engine (#5083, `Ecto.Adapters.SQL.stream` at the
  Postgrex 500-row default, chunk-bounded RAM), an ancestor of live guerrilla `34b9b25d`.
  **THE NUMBER:** `FLOOR = measured_demand_delta + margin = 98.16 + 798.81 = 896.97 → 897 MiB`.
  **THE UNIT, STATED HONESTLY (this is the crux D232/D244 lacked):** the demand term `98.16 MiB` is the
  **BEAM RSS peak-minus-baseline DELTA**, `(488564 kB − 388044 kB)/1024`, measured by the frozen
  harness's own rung-3 1 Hz `ps` sampler during wave-16's real 1.4 GB full export (run `1b515ee5`) — the
  **same peak-minus-baseline delta class** as the retired engine's canonical `2235.43 = (2483304−194228)/
  1024`, and the exact quantity **PDS-D267 itself names** ("+98 MiB incremental — apples-to-apples … via
  the same 1 Hz `ps` sampler"). It is **NOT** the `477.11 MiB` absolute RSS peak (`488564/1024`), which
  adds back the `388044 kB` resident baseline that `MemAvailable` **already excludes** — using it re-commits
  the exact double-count **PDS-D222(i)** forbids verbatim ("adding the baseline back would DOUBLE-COUNT and
  over-set the gate"); that is why the strategize "~1276" (`477 + margin`) is REJECTED here. It is **NOT**
  the `19.71 MiB` wire-byte COPY-chunk figure D232 correctly refused as unit-mixed. It is **NOT** the
  ~647 MiB wave-16 `MemAvailable` drawdown, a margin-class quantity already absorbed by the 798.81 margin.
  **What D232/D244 keep:** D232's unit-discipline principle (never mix a wire-byte figure into an RSS-delta
  slot) and D222's delta convention are UNTOUCHED — 897 obeys both. **What is superseded:** D232's "fire at
  2200, the derivation is not payable" and D244's "the floor stays at the unmodified 2200, PDS_FULL_EXPORT_
  MIN_MEM_MB left UNSET" — both rested on evidence they lacked (D232 had only D217's wire-byte figure; D244
  had only a SCOPED, drift-dominated, −7.55 MiB non-signal). Wave-16's UNSCOPED real export is the licensed
  demand figure neither had. **D211 floor-law holds:** `897 ≫ 98.16` (the deployed engine's measured
  demand), so the floor never sits below real demand. **SAFETY:** 897 sits BELOW the box's lowest observed
  idle `MemAvailable` (1343.77, D250), so `cond_b` passes at essentially every draw (the intent — fire
  in-regime); the real protection is the trivially-small true demand (~98 MiB RSS delta) + the 798.81
  margin (MAX of three drawdowns, > the 461 MiB build depression of D227 and the 647 wave-16 fire
  drawdown), with **zero dmesg OOM** ever recorded (worst-ever build storm 1571.52 MiB, D230). **ONE
  HONESTY CAVEAT recorded, not glossed:** the 388044 baseline is the harness's own strictly-pre-window
  rung-3 baseline, a *within-process* peak-minus-baseline — cleaner than a cross-process paired subtraction
  (no blue/green baseline mismatch) but NOT the formal D104 paired idle control D211's wording names; the
  floor's safety rests on `floor ≫ peak`, not on a perfect control. Derivation record committed to
  `scripts/pds-w20-floor-derivation.md` + ledger row `grip-…-pds-w20-floor-value.json`.

- **PDS-D277 — THE LAUNCHER HAS THREE FLOOR KNOBS, NOT TWO; ALL THREE MOVE TO 897, AND THE ARM RECORDS
  THEM.** Lowering only `MEM_FLOOR_LAW` (`:125`) and exporting `PDS_FULL_EXPORT_MIN_MEM_MB` is **INERT**:
  the value that actually gates the detached child's FIRE-vs-STAND-DOWN poll predicate (`:348`) is
  `MEM_FLOOR_MIB`, set at `:124` to `${PDS_LAUNCH_MEM_FLOOR_MIB:-2200}`. With `MEM_FLOOR_LAW` lowered but
  `MEM_FLOOR_MIB` still 2200, the arm guard (`:411-414`) passes silently and the child polls forever at
  2200 — wave-19's 0/618 reproduced under a green edit. **RULING — a surgical edit to
  `scripts/pds-crown-launch.sh` (a wave-14-built, NON-frozen script; the frozen harness blob
  `e219e97c` stays untouched — this extends D211's derive-only/frozen-blob-untouched spirit to the second
  instrument, which did not exist when D211 was ruled):** (1) `:125` `MEM_FLOOR_LAW=2200 → 897` (removes
  the arm-refusal guard); (2) `:124` default `…:-2200 → …:-897` (BAKES the poll predicate to 897 in
  source, so the fire does not depend on an operator remembering `PDS_LAUNCH_MEM_FLOOR_MIB` — dodges the
  forgotten-export silent-revert hazard); (3) inside `fire_detached`'s D249 contiguous env-export block,
  `export PDS_FULL_EXPORT_MIN_MEM_MB=897` (reverses D244's UNSET so the harness's own `cond_b` gate (b)
  matches). **AND close the two recording bugs in the same edit** (`pds-bl-w16-arm-never-records-its-own-
  floor` + `pds-bl-floor-env-silent-revert`): `run_dir/meta` and the arm summary record BOTH effective
  knobs distinctly — `mem_floor_mib=897` (gate A, poll predicate) AND `full_export_min_mem_mb=897` (gate
  B) — never the hardcoded D244 string; and the selftest gains a MUTATION-PROVABLE assertion (arm with a
  tightened floor, assert it appears in both summary and meta). The five stale D244 citations
  (header `:27-28`, comment `:189`, child stamp `:248`, banner `:477`, selftest assertion `:809`) all
  update to the new ruling; the banner `:477` is the SAME line `pds-bl-w16-arm-never-records-its-own-floor`
  targets, so both fixes land together to avoid a line-clobber. Selftest MUST pass (`bash
  scripts/pds-crown-launch.sh selftest` exit 0) as the slice gate.

- **PDS-D278 — THE RIDE-ALONG IS DISCARDED, NOT RATIFIED; THE HARNESS RUNG-3 RSS IS THE LICENSED DEMAND
  AND THE FIRE SELF-CONFIRMS IT.** The strategize framing — "the ride-along sampler measures the
  authoritative peak … that peak RATIFIES the floor" — CONFLATES two instruments. The `98.16/477` figure
  is the FROZEN HARNESS rung-3 RSS (`pds-pull-proof.sh`'s own instrumentation of the real export), a
  LICENSED demand instrument (D267). The ratify task's subject is a DIFFERENT instrument,
  `pds-idle-sampler.sh` — "the PAIRED IDLE CONTROL, ALONE (PDS-D237)", `acquisition=none`, every field
  `idle_*` — which in wave 16 ran only a rehearsal (780/780, `threshold_applied=none`, no MiB demand) and
  has NEVER ridden a real export. A CONCURRENT ride can never license the demand: 3 of D253's 4
  substantive conditions are structurally unsatisfiable — `idle_window_s=21600` (6 h, D263) cannot
  reconcile against a ~150 s export t1−t0; D221's 1048.16 MiB range void auto-trips on a box that swings
  900+ MiB in minutes plus the export's own ~477 drawdown; and the paired idle CONTROL cannot be taken
  at the same time as the demand read (D216 prerequisite unsatisfiable concurrently). **RULING: DROP the
  passenger this wave (as waves 18/19 did). CLOSE `pds-bl-ratify-or-discard-ridealong-demand` as
  DISCARDED** — a numbered ruling that the concurrent ridealong can never be the licensed demand, and that
  the licensed demand/floor is instead ratified by the harness rung-3 RSS (D267, same instrument as the
  2235.43). **The fire self-confirms via the SAME instrument:** the frozen harness's own rung-3 1 Hz
  sampler runs during THIS fire's full export and produces a fresh peak-minus-baseline delta. Named-failure
  condition (built-in, a WIN when it fires): if that delta **exceeds `floor − margin = 98.19 MiB`** (i.e.
  this fire's real demand exceeds the 98.16 basis the floor was derived from), it is a NAMED failure —
  filed, floor re-derived upward, re-armed at zero attempt cost. Wave-16's evidence makes a FIRED, GREEN
  climb the expected outcome.

**WAVE 20 PLAN.** One round-1 build slice; one round-2 arm (deferred, LEAD dispatches after slice 1
merges); one round-2 LEAD-only seal. **Round 1 — `pds-w20-launcher-floor-arm` — THE EDIT + DERIVATION
RECORD** (`scripts/pds-crown-launch.sh`, `scripts/pds-w20-floor-derivation.md`; builder: opus, the
subtle-correctness slice): apply D277's three-knob edit to 897, the meta/summary recording, the
mutation-provable selftest assertion, and all five stale-D244-citation updates; write the derivation
record carrying D276's exact unit sentence; gate `bash scripts/pds-crown-launch.sh selftest` exits 0.
**Round 2 (deferred; AFTER slice 1 merges) — `pds-w20-crown-fire` — THE ARM** (`scripts/pds-w20-fire-
record.md`; builder: fable): from the fresh persistent worktree pulled to the merged launcher, confirm
scratch `c7528814` alive (`curl 37576` = 200); **ARCHIVE the stale wave-19 run dir** `mv
/tmp/pds-crown-launch/c7528814 …/c7528814.wave19-<UTC>` (D269, archive NOT `PDS_LAUNCH_STATE_DIR`
override — the override blinds the anti-stack guard on a 90+-worktree box); pay `deps.get` + both
compiles off the clock (`CC=/usr/bin/clang`); re-cat `attempts` (budget = spent+2) and re-run the 0b
`merge-base --is-ancestor <guerrilla-HEAD> <worktree-HEAD>` in the SAME breath as the arm (D275) — abort
honestly if it fails; `unset PDS_LAUNCH_HARNESS PDS_AMMO_FILE` (leave the FLOOR knobs to the baked
source defaults), `export PDS_CONTROL_PG=postgres PDS_RUN_ID=pdsw18-crown`; invoke the launcher BY PATH
`--prewarm-now --max-draws 2160 --interval 10` DETACHED; **NO passenger** (D278); prove `child.sh` line 7
= the fire worktree's `pds-pull-proof.sh` (D259) and that meta records `mem_floor_mib=897`; confirm the
child ONCE with `ps -p`; record run_id/run_tag/pid/floor/budget/transcript in the fire record; push; open
the PR; END THE TURN — **no polling**. **Round 2 (deferred, LEAD dispatches after the CLIMB completes) —
`pds-w20-crown-collect-and-seal`**: LEAD-ONLY. Collect via six named states (`ps -p` never `pgrep`), D248
stranded-lock recovery, the D261 bundle cross-check BEFORE any stamp; confirm the harness rung-3 RSS
delta ≤ 98.19 (D278 self-confirm); criterion text fetched to a file and passed by `"$(cat f)"`. Re-stamp
ALL of 0–9 with the ONE wave-20 run_id, **10 on merge with the merge SHA recorded**, **11 LAST and
ALONE**. Any refusal: stamp NOTHING, record the named refusal, sort HARNESS-BUG vs ENGINE-FAIL, file the
successor. **ZERO NEW SCRIPTS; scripts/pds-* ONLY; frozen blob untouched.**

### Wave 2026-07-21 (20) — DERIVE THE REAL FLOOR — round 1 built + reviewed, grade A (paper `pds-wave-20-2026-07-21`)

**What landed.** One round-1 slice, `pds-w20-launcher-floor-arm` (branch
`loop-epic/arm-the-launcher-at-the-derived-897-floo-0-r`, PR opened): `scripts/pds-crown-launch.sh`
armed at the PDS-D276/D277 derived **897 MiB** floor and the derivation record
`scripts/pds-w20-floor-derivation.md` written. The 2200 fossil (retired in-RAM engine's 2235 demand)
is retired against the deployed streaming spill engine whose real peak-minus-baseline demand is
**98.16 MiB** = (488564−388044)/1024 (wave-16 harness rung-3); FLOOR = 98.16 + 798.81 (D222 max
drawdown) = 896.97 → 897. All **three** floor knobs move together (editing fewer is inert — the poll
predicate silently defaults to 2200 and the child stands down forever): (1) `MEM_FLOOR_MIB` default
`:-2200`→`:-897` (the poll predicate baked into source), (2) `MEM_FLOOR_LAW` 2200→897 (the tighten-only
arm-refusal guard), (3) `export PDS_FULL_EXPORT_MIN_MEM_MB=897` inside `fire_detached`'s D249 contiguous
block (reverses D244's UNSET so the frozen harness cond_b (b) matches). One shared producer
(`arm_floor_record`/`arm_floor_summary`/extracted `write_run_meta`) records BOTH effective knobs
distinctly in `run_dir/meta` and the arm banner — closing `pds-bl-w16-arm-never-records-its-own-floor`
and `pds-bl-floor-env-silent-revert` (both merge-gated on the LEAD's close). Frozen harness blob
`e219e97c` UNTOUCHED. Selftest 46 ok · 0 FAIL (baseline 40), exit 0, mutation-proven in review: reverting
the export knob → 4 distinct FAIL (`full_export_min_mem_mb` reads UNSET); reverting the poll/law knobs →
3 FAIL. Derivation arithmetic re-checked green; the §2 honesty caveat (the 388044 baseline is the
harness's within-process rung-3 baseline, NOT a formal D104 paired control D211 demands) is recorded.

**Review verdict — grade A.** Correct, doctrine-clean, disciplined. The three-knob coupling is the whole
game and all three are set + individually mutation-proven; the two synthetic collect fixtures at
`mem_mib=1800/floor=2200` are correctly LEFT (897 would flip their STAND-DOWN verdict to FIRE and make
them internally inconsistent). Reviewer changed nothing in the slice — it was already right. Two honest
notes, neither blocking: (a) the slice's stamped evidence for criterion 4 claims "reverting knob 3 → 15
FAIL / knob 2 → 14 FAIL"; review measured 4 and 3 — the *substance* (distinct check per knob,
mutation-provable) holds, the counts are overstated; (b) D276–D278 live in the wave Paper and in charter
PR **#5514** (`pds/w20-decide`, open) but not yet in this charter body — a cold agent reading only the
charter still sees D275's "never lower the 2200 floor" until #5514 merges.

**What stalled / deferred (BY DESIGN, sequenced rounds).** `pds-w20-crown-fire` (round 2) and
`pds-w20-crown-collect-and-seal` (round 3) were NOT built this run. `pds-w20-crown-fire` fires the
detached climb at the baked 897 floor in the box's real 1796–2012 MiB regime — it MUST wait for
`pds-w20-launcher-floor-arm` to MERGE (it invokes the merged launcher by path). `pds-w20-crown-collect-and-seal`
is LEAD-only, after the climb completes.

**Next wave takes:** merge round-1 (`pds-w20-launcher-floor-arm` -r) and charter PR #5514 first (the fire
reads the baked 897 default from the MERGED launcher); then dispatch `pds-w20-crown-fire` (archive the
stale wave-19 run dir per D269, same-breath 0b per D275, arm BY PATH `--prewarm-now --max-draws 2160
--interval 10` detached, NO passenger per D278, prove `run_dir/meta` records `mem_floor_mib=897`, return —
no polling); then, after the climb completes, the LEAD runs `pds-w20-crown-collect-and-seal` (D261 bundle
cross-check, D278 self-confirm rung-3 delta ≤ 98.19, re-stamp 0–9 to one run_id, 10 on merge, 11 last-and-alone).

### Wave 2026-07-21 (21) — READ THE ABORT, THEN FIRE — DECIDE (paper `pds-wave-21-2026-07-21`)

Wave 20 finally FIRED at the derived 897 floor (fossil 2200 gone) and got **6 PASS · 4 ABORT · 1 FAIL**:
rung 1 (the import) 500'd with a Postgres **25P02**. One crown attempt remains (**5/6**). This wave spends
its whole budget on DIAGNOSIS (zero crown attempts) to sort two hypotheses BEFORE the last shot — then
fires clean or refuses with a name. **VERDICT: (a) DIRTY-SCRATCH — PROCEED TO FIRE.** Proven, not guessed.

- **PDS-D279 — THE RUNG-1 25P02 IS (a) DIRTY-SCRATCH, PROVEN FOUR WAYS — NOT (b) A HANDLER BUG.** The
  visible 25P02 on `SET session_replication_role = DEFAULT` is the after-block CLEANUP mask; the true
  first-failing statement (Postgres logs it by default, `log_min_error_statement=error`, request_id
  `GMRmnzN-yl-UNAkAAABk`) is **ERROR 23505** duplicate key on `content_edges_from_to_kind_uniq`, tuple
  `(from,to,kind)=(98650f3b…, b63e6a30…, parent_id)`, inside the merge `INSERT … ON CONFLICT ("id") DO
  UPDATE`. MECHANISM (code-verified): `merge_upsert`'s ON CONFLICT arbiter is ALWAYS the PK
  (`order_columns`), never the secondary unique `(from_id,to_id,kind)`. The scratch pre-held that tuple
  under id `7bd32bce` (wave-18's 15:29:50 pull); the bundle carries the SAME tuple under a DIFFERENT id
  `0003051d`, so the bundle row misses the PK arbiter, tries to INSERT, and hits the secondary unique the
  pre-existing row occupies → unabsorbed → tx abort. PROOFS: (1) bundle has **0** intra-tuple dups across
  5109 rows (cannot self-collide); (2) LEG A — bundle `content_edges.copy` into a FRESH EMPTY table w/ the
  real unique index = `COPY 5109`, zero violations; (3) LEG B — plant the foreign-id row + replay the exact
  captured INSERT = identical 23505 w/ identical DETAIL. **The only variable that flips pass↔fail is TARGET
  EMPTINESS** — nothing in the bundle or the handler. `merge_import` is NOT broken; there is NO api bug that
  blocks the crown. `pds-backlog-import-savepoint-honesty` stays open as honest error-surfacing polish (the
  app should show the 23505, not the 25P02 mask) — it is NOT a crown blocker.

- **PDS-D280 — MOVE 1 WAS FREE; MOVE 2 (APP-PATH ISOLATION) IS THE BELT-AND-SUSPENDERS BEFORE ATTEMPT 6.**
  The root was already on disk (no re-run, no config, zero attempts). A1's LEG A/B is a DB-layer isolation
  (real bundle bytes + real constraint + real captured SQL) but did NOT boot the full app path (worktree
  COLD). RULING: because the wish FORBIDS guessing the last attempt away, the fire slice runs the EXACT
  `export --profile dev --dataset production --with-blobs | import default --yes --merge --with-blobs`
  against a GUARANTEED-FRESH scratch **in isolation (no crown, zero attempts)** as the final app-path gate.
  Clean exit 0 = (a) confirmed end-to-end → arm. Same 25P02 = (b) after all → do NOT spend attempt 6, file
  the api successor, record a NAMED REFUSAL (a win). The crown's own rung 1 is the same command into a fresh
  empty target, so an isolation pass predicts the crown rung-1 pass exactly.

- **PDS-D281 — HYPOTHESIS (c) SCHEMA-SKEW IS REFUTED; THE SORT COLLAPSED TO (a) vs (b), LANDS ON (a).**
  Migration diff `8b32a1e67..f76367999` is EMPTY (34 intervening commits, zero migration files); guerrilla's
  boot/fire shas (`e16869ac`, `34b9b25d`) are ancestors of origin/main. A fresh boot from origin/main applies
  an identical, already-maximal migration set (the D32 lifecycle-check widening predates the boot sha).
  Booting fresh fixes (a) even though (c) was never present.

- **PDS-D282 — THE FRESH-SCRATCH FIX IS A *NEW* `PDS_RUN_ID`, NOT reused `pdsw18-crown`.** `run_tag =
  cksum(PDS_RUN_ID)`; reusing `pdsw18-crown` → run_tag `c7528814` → the SAME dirty `BARKPARK_HOME`
  (`/private/tmp/pds-w14.c7528814`) that carries wave-18's pull (5083 content_edges, 34 clobbered rows,
  empty pull_provenance). The root fix for (a) is a NEW `PDS_RUN_ID` (never initdb'd) → fresh
  `BARKPARK_HOME` → guaranteed-EMPTY target. New run_tag makes D269 archive automatic (fresh `STATE_DIR`)
  and the launcher's `O_APPEND` transcript collision moot. Boot it explicitly (`pds-scratch-target.sh up
  --verify`, D34/D54 traps: `CC=/usr/bin/clang`, `mix deps.get` first, `BARKPARK_HOME` <85 chars, redirect
  not pipe, ~3.5 min cold, budget an OOM without chasing it) BEFORE arming — the launcher only LOADS a
  scratch, never boots one. Isolation and crown need SEPARATE fresh scratches (the isolation populates its
  target; the crown rung-1 must import into a still-empty one).

- **PDS-D283 — THE "CHECKOUT LAUNCHER FROM BRANCH" STEP IS A NO-OP; NEVER DIRECTORY-CHECKOUT.** The
  897-floor launcher merged to origin/main (PR #5522, `c305a1a6e`, ancestor of `f76367999`); `git diff
  origin/main c4569f98e -- scripts/pds-crown-launch.sh` is EMPTY, and all three floor knobs read 897 on
  origin/main (lines 136/137/207). A worktree cut fresh at origin/main ALREADY carries the armed launcher —
  skip the checkout step. If it is ever performed for provenance, it MUST be a single explicit pathspec
  (`checkout c4569f98e -- scripts/pds-crown-launch.sh`, identical bytes) and NEVER `checkout <branch> -- .`
  (that branch tip is based on the older `58862f62`; ~40 stale files would regress the worktree).

- **PDS-D284 — RE-FREEZE THE WINDOW `worktree-cut → arm`, HOLDING #2907 + #5525.** The lead LIFTED the
  freeze after wave-20's climb died (to drain PRs). The protected window is fire-worktree-cut → arm; once
  armed, the detached child's own rung 0b re-checks live at fire time (D275), so post-arm merges self-defend
  — the risk is entirely PRE-arm. `deploy.yml` redeploys guerrilla on any push touching
  `api/**|cloud/**|internal/**|deploy/**|templates/**|connectors/**`; the INSTANCE job (the one that moves
  guerrilla's sha) narrows to `^(api|internal|deploy|connectors)/` (deploy.yml:72). Currently exactly TWO
  open PRs touch that set: **#2907** and **#5525** (both `api/**`; both `CONFLICTING` now, but one rebase
  from mergeable). Docs/tooling PRs #5514/#5458 are safe. The lead RE-FREEZES (holds #2907 + #5525)
  immediately before `git worktree add` and holds through the arm returning — the exact wave-18 failure
  (guerrilla redeployed mid-climb, voiding 0b's ancestry) this window prevents. Coordinate via the paper +
  SendMessage(main); re-verify with `bash scripts/pds-climb-preflight.sh` CHECK 4 immediately before cutting.

- **PDS-D285 — BUDGET = spent+2 = 7; RE-READ `attempts` AT FIRE TIME (D224).** `attempts`=5 now (5/6 spent,
  one remains). The fire re-cats `/tmp/pds-full-export/attempts` in the SAME shell as the arm and exports
  `PDS_FULL_EXPORT_BUDGET=$((spent+2))`=7 INLINE before the fork (never a survey literal — the store is
  machine-global per D156, a sibling could move it). Do NOT set `PDS_FULL_EXPORT_DIR` (D274). The parked tar
  is one deploy stale (`served_sha 34b9b25d` ≠ live `f76367999`) → the fire PULLS FRESH, never reuses the
  cached tar (D275 same-breath).

- **PDS-D286 — RUNG 1 PASSING UNBLOCKS NO CROWN CRITERION BY ITSELF; the crown stays 9/12 (6,10,11 open).**
  Rung 1 is a precondition for rung 6 (which ABORTs naming step 1 if no pull ran) and one step of the ONE
  serial climb criterion 11 demands — but a fire is only a SEAL if rungs 3&4 pass WITH controls firing off
  the one full bundle AND rungs 1/2/5/6 pass against the real booted target, all under ONE run_id (D84/D122).
  10 is merge-gated (LEAD), 11 is last-and-alone (LEAD). Wave-20's fire moved the stamped count by ZERO.

**WAVE 21 PLAN.** Two slices. **Round 1 — `pds-w21-diagnose-and-fire` (opus, `scripts/pds-w21-fire-record.md`):**
(A) MOVE-2 app-path isolation — boot a guaranteed-fresh scratch (NEW `PDS_RUN_ID`), run the exact
export|import (reuse the 76 MB artifact for the import leg), record the exit. SORT: exit 0 → (a) confirmed
→ go to (B); same 25P02 → (b) → file the api successor, record the NAMED REFUSAL, do NOT arm, STOP (a win).
(B) FIRE — SendMessage(main) to RE-FREEZE (#2907/#5525) and confirm the freeze is declared; cut a FRESH
persistent worktree at origin/main `f76367999` (launcher already armed there, D283); pay `deps.get` + both
compiles off-clock; boot a fresh CROWN scratch (a SECOND new `PDS_RUN_ID`); re-cat `attempts` + export
`PDS_FULL_EXPORT_BUDGET=7` inline; re-run the same-breath 0b (`merge-base --is-ancestor <guerrilla-HEAD>
<fire-worktree-HEAD>`, abort honestly if non-0); arm the launcher BY PATH `--prewarm-now --max-draws 2160
--interval 10` DETACHED; confirm the child ONCE (`ps -p`); record run_id/run_tag/pid/transcript/scratch-home/
budget/floor; push; open the PR; END THE TURN — NO polling. Gates (from the fresh fire worktree):
`bash scripts/pds-crown-launch.sh selftest` (N ok · 0 FAIL) and `bash scripts/pds-climb-preflight.sh` (no
CHECK FAIL). **Round 2 (deferred, LEAD dispatches after the CLIMB completes) — `pds-w21-crown-collect-and-seal`
(fable, LEAD-only):** collect via six named states (`ps -p`, never `pgrep`), D248 stranded-lock recovery,
the D261 bundle cross-check BEFORE any stamp, criterion text fetched to a file. If RESULT: PASS with rungs
3/4/6 green off the ONE full bundle, controls firing — re-stamp crown **0–9** to the ONE wave-21 run_id, **10
on merge** with the merge SHA recorded, **11 LAST and ALONE**, sealing the crown 12/12. If any rung refused:
stamp NOTHING, record the named refusal, sort each red HARNESS-BUG vs ENGINE-FAIL, file the successor. **ZERO
NEW SCRIPTS; `scripts/pds-*` fence ONLY** (the (b) fix, if ever, is FILED for an api/felix wave). Frozen blob
`e219e97c` UNTOUCHED. Crown 9/12; unmet 6,10,11.

### Wave 2026-07-21 (21) — READ THE ABORT, THEN FIRE — last attempt FIRED and PASSED 11/11, CROWN SEALED 12/12, grade A− (paper `pds-wave-21-2026-07-21`)

**THE EPIC PAYOFF LANDED.** One round-1 slice, `pds-w21-diagnose-and-fire` (opus). **PART A — app-path
isolation (D280)** proved verdict **(a) DIRTY-SCRATCH** to ground truth: a guaranteed-fresh scratch under
`PDS_RUN_ID=pdsw21-iso` took the EXACT rung-1 import that 500'd with **25P02** against the dirty wave-18
target and imported it **CLEAN** (exit 0, `content_edges=5109 / total_rows=15915 / 34 blobs 0 failed`),
ZERO crown attempts spent — confirming **PDS-D279** (the 25P02 masked a 23505 on
`content_edges_from_to_kind_uniq` from a pre-existing wave-18 row; `merge_upsert`'s ON CONFLICT arbiter is
PK-only; `merge_import` is **not** broken). **PART B — THE FIRE — armed and the whole crown ladder PASSED.**

**The last crown attempt fired clean and PASSED — RESULT: PASS, 11 PASS · 0 ABORT · 0 FAIL** (run_id
`pdsw21-crown`, run_tag `5abf6afd`, armed 2026-07-21T21:29:57Z, done 21:35:29Z, EXIT 0, 1 draw). Every rung
green (0a/0b/0c/1/2/3/4/5/6/7/8) at floor **897** MiB, **attempt 6 of 7**. **RUNG 1 — the wave-20 killer —
is GREEN**: export --profile dev --dataset production --with-blobs then import --yes --merge --with-blobs,
exit 0 in 9s, `content_edges=5117 documents=3612 total_rows=15933`, PDS-D9 adoption fired. Fired at
**d633786** (= origin/main = guerrilla live HEAD), NOT the brief's pin `f76367999` — the pin went STALE
mid-wave (origin/main + guerrilla advanced with #5535–#5538); rung 0b PASS confirms d633786, and the
launcher-897 + `merge_import` are byte-identical `f76367999..d633786`.

**CROWN SEALED 12/12.** The LEAD merged fire-record PR **#5547** (`scripts/pds-w21-fire-record.md`, merge
`59818468e`) and stamped `pds-w1-crown-proof` criteria **0–11** all to run_id `5abf6afd` — criterion 10
[MERGE-GATED] on the real merge, criterion 11 last-and-alone after the single-run-id fence check.
`pds-w1-crown-proof` is **lifecycle done, 12/12**. The 15-wave crown proof is COMPLETE.

**Review verdict — grade A−.** The wave achieved the epic's terminal goal: the last attempt fired clean, the
full ladder held, rung 1 (the wave-20 blocker) is green, and the crown sealed 12/12 on an honest merge-gate.
Two deductions keep it off A: (1) a **duplicate-builder race** — two instances ran the slice under the SAME
worker id; one stood down (correctly, to avoid a double-arm = two full exports = OOM the live content API,
PDS-D31), the other armed and drove the PASS. Exactly one clean arm happened, but by coordination luck, not
design. (2) The arming instance ended without committing the fire-record or stamping — the crown-proof PASS
was briefly **stranded in ephemeral `/tmp`**; the LEAD (via #5547) and the reviewer independently recovered
it. Ledger corrected in review (now-line + criterion 2 re-stamped to ARM+PASS; the LEAD stamped 3/4/5).

**Next wave takes:** the crown is CLOSED — no further fire (attempt 7 is the only one left and is not needed).
Remaining housekeeping only: prune the orphaned fire worktree at `/Volumes/SATECHI/github/barkpark-w21-fire`
(d633786 detached, not in `git worktree list`); close the now-satisfied slice `pds-w21-diagnose-and-fire`
(its criterion 6 merge-gate is met by #5547's merge — LEAD closes) and the `pds-w21-crown-collect-and-seal`
task the seal already fulfilled. The next epic direction is a fresh wish, not another crown fire.

### Wave 2026-07-27 (22) — SUCCESS MUST BE OBSERVABLE — DECIDE (paper `pds-wave-22-2026-07-27`)

The crown is CLOSED and this is the fresh wish, not another fire. The crown proved the dev loop CAN fire
cleanly ONCE, under a lead's supervision, on a hand-armed ladder. It did not prove the product is trustworthy
in an owner's hands UNATTENDED. This wave closes that gap on the defect class the wish names: verbs that
**REPORT SUCCESS WHILE BEING WRONG** — the exact class a supervising lead re-derives by hand and an
unattended owner cannot. **NO CROWN RE-FIRE.** Fences: OFF `.github/workflows/**`, `hg-*`, `tooling/grip/**`
(concurrent Honest Gates + Truth-Grip waves own those).

- **PDS-D287 — THE ONE LAW: NO VERB REPORTS SUCCESS ON AN EXIT CODE ALONE.** Every success claim must be
  backed by a post-condition READ of the state it claims to have produced, and any claim it cannot back must
  say so in the same breath. This is the repo's own agent doctrine (distrust vacuous green; verify STATE not
  exit codes; truth-authority L1 = the running system) made EXECUTABLE IN THE PRODUCT instead of practised
  only by agents. Two reference implementations already exist IN-TREE and the charter names them as the
  template: `scripts/pds-scratch-target.sh` (every `PASS` gated on a live read; teardown re-stats after
  `rm -rf` rather than trusting its exit code) and `scripts/pds-pull-proof.sh` ("`SENTINELS OK` measured
  against the wrong database is worse than an ABORT"). Wave 22 ports that discipline from `scripts/` into the
  product verbs. Nothing new is invented; four or five existing surfaces stop lying.

- **PDS-D288 — THE CLOSE HOLDER GATE IS A LOUD RECORDED OVERRIDE, NEVER A REFUSAL — AND IT IS AN HONESTY
  GATE, NOT AUTHORIZATION.** MEASURED on the live ledger: of 2,064 recorded closes, 36 have a live
  `claim.worker` ≠ `closed_by` and 40 more were closed over a TTL-reaped lease by a non-`previous_worker` —
  union **76 rows, 3.7%** — and EVERY foreign closer is a LEAD (`oc-lead` 29, `cc-showcase` 13; no CI, no UI).
  A default-refuse gate would break the epic-cycle seal ritual documented in four charters INCLUDING THIS ONE
  ("PR merged to main (LEAD closes this criterion on merge)"). Predicate — three allow-arms, then the
  override: (1) no claim map → allow (never-claimed root/container closes, which `check_fencing`'s bare
  `_ -> :ok` permits today); (2) `claim.worker == worker_id` → allow; (3) `claim.worker == nil` AND
  (`previous_worker` OR `released_by`) `== worker_id` → allow (self-resume). Arm 3 needs BOTH keys: a TTL reap
  writes `previous_worker` (`ttl_sweeper.ex:355,366`) while a VOLUNTARY release writes `released_by`
  (`release.ex`), so a fallback keyed on only one silently refuses the other path — and verbatim reuse of
  `Internal.check_holder/2` (`internal.ex:27-32`, which fails on nil) would refuse all 44 self-resume closes
  AND every container close. Anything else REQUIRES an explicit recorded override writing actor + held_by +
  reason into the close event. **`worker_id` is a client-supplied body param (`tasks_controller.ex:473`),
  never derived from the api_token** — sell this as a RECORDED honesty gate that stops ACCIDENT and makes
  deliberate foreign closes AUDITABLE for the first time. Never sell it as authorization.

- **PDS-D289 — THE CRITERIA GATE SITS BESIDE `check_fencing/2` ON THE DOC AS READ; ANYWHERE DOWNSTREAM IS
  DECORATIVE BY CONSTRUCTION.** PROVEN BY RUN: `apply_close_update/7` calls `autostamp_merge_gate` (close.ex
  :417) then `merge_criteria` (:419) then the rev-CAS `update_all` (:420-425) in ONE write, so a closer that
  flips its own criteria in the closing command yields `unmet BEFORE close (doc as read) = 2; unmet AFTER
  merge_criteria = 0; lifecycle=done`. The SHIPPED advisory warning is already on the wrong side of that line:
  `close_response/3` (`tasks_controller.ex:576-594`) computes progress from the doc RETURNED BY the close, so
  the self-flipping closer receives no warning at all. SEAT: `do_close_txn/9`'s `with` chain (close.ex:257),
  evaluating the `doc` read at :236 under the per-task advisory lock taken at :233 — the only place where the
  pre-merge state is visible, the read is serialized, and a refusal aborts before any content is written.
  SCOPE: `done` ONLY. `cancelled` (20 PDS rows, all retrofitted self-true tombstones) and `blocked` (1 row at
  0/3) are EXEMPT **BY NAME IN THE CODE**. No "unmeasurable by design" state exists anywhere in `schema.ex`'s
  criterion composite (`criterion`/`met`/`evidence`), so the gate ships as accept-unmet-with-a-recorded-reason
  — it does NOT grow a third criterion state. Today 0 of 77 done PDS rows read unmet, but that 0% is a
  POST-REPAIR artifact (`pds-w1-crown-proof` was closed at 6-and-10 `met:false` per D138 and now reads 12/12):
  **measure before gate**, and prove the override fires, or you cannot tell "the gate works" from "it never ran".

- **PDS-D290 — REJECT SENTINEL WORKER IDS AT THE ENGINE.** 21 recorded closes carry the literal string
  `"None"` as `closed_by` (4 confirmed on a single live page: `scaffy-w6-prereg-paper`, `scaffy-w6-mining-repro`,
  `wsc-bl-real-fixtures`, `tlv-bl-js-vocab-drift-gate`). `Params.fetch_string/2` accepts any non-empty binary
  and nothing repo-wide validates the shape. `scripts/pr-task-gate.sh:199-201` passes a `done` task on
  `closed_by` merely being PRESENT, so `"None"` satisfies a gate written to catch hand-flipped dones. Refuse
  empty-after-trim and the literals `None|null|nil|-` at the engine. The pr-task-gate half is FENCED to the
  concurrent Honest Gates wave — FILED, not built here.

- **PDS-D291 — THE DEPLOY DEFECT IS OBSERVABILITY, NOT A STUCK BOX; AND `.slots/<slot>.sha` IS STAMPED BEFORE
  THE THING IT CLAIMS.** Re-measured live 2026-07-27 ~18:13Z: ALL SIX records agree on `717c7734ecac…` —
  `.instance-deploy-last`, `.slots/blue.sha`, the Caddy upstream (`localhost:4000` = blue), `systemctl
  is-active` (blue active / green inactive), `/status.json` (`0.2.25.1879`), and the running BEAM's own
  `BuildInfo.commit` (`717c7734e`). origin/main was ONE commit ahead and that commit is docs-only, so
  `deploy.yml`'s **workflow-level** `on.push.paths` filter created NO deploy run at all — not a stall, not a
  coalesce, not a job skip. THREE direction premises are REFUTED: the five-commit gap was transient; exit 23
  fires only for rollback modes (a real deploy queues then exits 15); and every flip failure restores the
  Caddyfile, disables the new slot, resets the checkout and exits 14. The script's failure typing is GOOD.
  THE NEW DEFECT: `instance-deploy.sh:684` writes `.slots/$TARGET.sha` BEFORE `deps.get`/`deps.compile`/
  `compile`/`ecto.migrate` (:694-699), and NONE of the exit-12/13 paths reverts it — so a failed deploy poisons
  `--rollback`'s target (read at :178) with a sha that slot never successfully built. `$STATE` (:1053) is
  correct by contrast: written only after the health gate and the flip. Fix = stamp after the health gate,
  revert on the failure paths. Box-side only; `.github/workflows/**` stays untouched.

- **PDS-D292 — THE DEPLOY HARNESS CANNOT FAIL ON ADVANCE, AND THAT IS FIXED FIRST.** `deploy/
  instance-deploy_test.sh:64` — the ONLY `rev-parse` handler in 753 lines — echoes a per-run CONSTANT
  `${FAKE_SHA:-deadbeef}`, so an "advance" run and a "stall" run are byte-identical: `exit 0` PASS, `HEALTHY`
  PASS, state-file PASS, and the law's own assert `[ current != target ]` **FAILS IN BOTH**. Proven by a probe
  reusing the harness's first 231 lines verbatim against the REAL `instance-deploy.sh`. A stateful fake
  (~20 lines in `make_fakes`: `fetch` writes `fetch_head` from `$REMOTE_SHA`; `reset --hard FETCH_HEAD` copies
  it to `head.sha`; `reset --hard <sha>` writes `<sha>`; `rev-parse` cats `head.sha`; `merge-base` exits 0)
  restores discrimination — honest ADVANCE 4/4 PASS, honest STALL passes A1-A3 and FAILS the advance assert.
  Default `REMOTE_SHA` to `$FAKE_SHA` so all 215 existing asserts stay green by construction; truncate for
  `--short`. `cp-deploy_test.sh` CANNOT be copied (66 lines, zero occurrences of the string `git`), so the
  stateful-HEAD idiom must be invented here. **The harness fix SEQUENCES BEFORE any deploy-advance assert** —
  a harness that would police the wave's law must first be able to fail.

- **PDS-D293 — THE RUNNING COMMIT BECOMES PUBLIC ON `/status.json`; THE CLI READ-BACK IS ROUND 2.** Of the six
  deploy records, only `Barkpark.BuildInfo.commit/0` is L1 — produced by the RUNNING code itself; the others
  are files a script promised to write. It is double-gated away: `capabilities.ex:295-297` requires BOTH
  `?build=1` AND `caller_tier != "none"` (proven live — anonymous `?build=1` returns `build: null`, the admin
  bearer returns `commit: "717c7734e"`), so **no anonymous observer, including an owner's own uptime monitor,
  can read the deployed sha anywhere on the box**. `/status.json` publishes `version` only, and
  `0.2.25.1879` is `git rev-list --count v0.2.25..HEAD` — a DISTANCE, not an identity, so a slice that merely
  surfaces `version` more prominently is vacuous green and must be rejected. Add a sha-bearing `commit` field
  to the public `/status.json` (`status.ex:40`, `status_controller.ex`). `bp cloud deploy`'s `✓ deployed`
  (`cloud_deploy_cmd.go:216`, printed on an ssh exit code alone while the box already prints its live sha as
  unparsed log text) then READS IT BACK and compares to the ref it asked for — **round 2**, after the read
  path is on main.

- **PDS-D294 — THE IMPORT RECEIPT IS *ALWAYS* A DOUBLE EM-DASH, AND RELAXING THE ERROR GUARD WOULD FABRICATE A
  ZERO.** Two surveyors disagreed; the one with a run proof wins. Against the real server body:
  `importCounts -> tables=-1 rows=-1`, human line `Imported workspace X — — rows across — tables`, exit 0,
  while the raw decode shows `err=json: cannot unmarshal object into Go struct field .tables of type int` with
  **`TotalRows=13` decoded correctly** and `TablesNil=false`. The server sends `tables` as a MAP
  (`workspace_bundle.ex:182` typespec; `workspace_controller.ex:330-332` and :348-350 on both arms); the
  client declares `Tables *int` (`cloud_workspace_cmd.go:503`); the `if err == nil` guard throws away the half
  that worked. FIX = RETYPE to `map[string]int` + `len()` and assign each field INDEPENDENTLY of `err`.
  **Do NOT simply drop the guard**: `encoding/json` allocates the `*int` before failing, so `*r.Tables == 0`
  and the honest em-dash would become a fabricated `0 tables`. Fix the `pluralize` comment with the code — it
  now describes a shape ("a receipt that omitted the field") the server never sends. `importCounts`,
  `fetchOneBlob` and `putOneBlob` have ZERO test coverage; the slice ships their first test.

- **PDS-D295 — THE BLOB SIDECAR BYTE-VERIFY IS CLI-ONLY ON BOTH LEGS, AND IT MUST SAY "RECEIVED", NOT
  "STORED".** UPLOAD: `media_controller.ex:247-251` already answers 200 with `%{written, bytes}`; `putOneBlob`
  READS that body and consults it only on non-2xx, then returns the LOCAL `fi.Size()` it already had — the
  echo exists and is discarded. DOWNLOAD: `media_files.size` is a real non-generated `:integer` column, so it
  rides in the manifest member's declared `columns` (`Catalog.non_generated_columns`) even though the member
  map has no `size` KEY, and the existing `manifestColumnIndex` + `copyColumnValues` helpers resolve it with
  no new parsing. Two honesty limits the slice must PRINT rather than hide: (a) the echoed count is bytes
  RECEIVED — `byte_size(body)` is measured BEFORE `Blobstore.put_bytes/3`, which returns bare `:ok` with no
  stat read-back, so a stored-bytes assertion is a separate FILED Elixir row; (b) `size` is NULLABLE
  (populated only by `Media.upload/3`; `Media.put_blob/2` writes bytes and creates NO `media_files` row), so an
  absent declared size prints "declared size absent" and does NOT count as a pass — otherwise the verify
  becomes exactly the vacuous green it was built to kill. Bonus in scope: `putOneBlob`'s "a 400MB video never
  lands in RAM" comment is false at the server (`read_full_body` and `endpoint.ex:124` both cap at 100 MB →
  413). Fix the comment beside the code.

- **PDS-D296 — PDS-D100 IS INERT; THE HARNESS FREEZE IS CLIMB-SCOPED AND THE CROWN IS CLOSED.** D100 verbatim:
  "Every harness change lands in PREFLIGHT, before attempt 1. **From attempt 1 onward** the harness is FROZEN
  and each red sorts into exactly one bucket BEFORE anything is touched," with the rationale "the freeze is
  what makes the transcript trustworthy — it removes the climber's ability to edit a red away." Its subject is
  the harness DURING an active climb; with no attempt running the rationale has no referent. **With the crown
  CLOSED, D100 forbids wave 22 nothing.** But ONE RULING DOES NOT DISPOSE OF THE FAMILY. The harness-only set
  is **47 rows**, not the digest's ~58 (text lens over `files` ∪ path tokens mined from description/criteria/
  purpose; a `files`-only lens sees just 22 because **88 of the 129 blocking rows carry no `files` field at
  all**, so any files-based lens is blind to 68% of the set). It splits at least three ways, each needing a
  DIFFERENT verdict: genuinely frozen harness bugs (the charter roster at :2510-2513 — of which
  `pds-bl-harness-pgrep-wrong-process` is FIXED by `58d1bd3a5` and `pds-bl-templates-deploy-noop` by
  `b2a92e3bc`, so the roster is really 4); **~8 rows blocked on a crown fire this wave forbids**, which the
  ruling does NOT unblock and which PARK with "reopen when a crown fire is licensed" — a disposition DISTINCT
  from OPEN; and rows that are not harness work despite `scripts/` paths (`pds-backlog-bp-dev-pull-verb`,
  `pds-w9-stale-2231-in-papers`, `pds-bl-charter-slot-durability`). Budget the ruling as **"saves ~39
  permission arguments"**, never as "disposes 58 rows".

- **PDS-D297 — THE BLOCKING SET IS 129 ON-RAIL + 7 ORPHANED = 136, SAMPLED AT AN INSTANT THAT MUST BE NAMED.**
  Two-lens count at **`2026-07-27T18:19:26Z`** (ledger 3,327 tasks): LENS A, the transitive `parent_id`
  closure from `task-2ac1f95237c4a8e5` with the root excluded = 230 descendants (done 73, **open 129**,
  cancelled 24, considering 3, blocked 1). LENS B, the offset-walked ready pool = 811. INTERSECTION = **129**,
  and the lenses agree perfectly (`open desc NOT in ready = 0`; `ready desc NOT open = 0`). The survey's "133
  open" is WRONG rather than stale — zero descendants carry an `updated_at` on 2026-07-27, so the ledger did
  not move — and its "82 direct children" is wrong too: the server itself reports `child_count: 136`. The
  id-prefix lens **OVERCOUNTS by net +2** (131), the OPPOSITE direction from the digest's assumption: it
  misses 6 non-`pds-`-prefixed descendants and falsely adds 8, of which **7 hang under
  `pds-w10-climb-in-the-post-deploy-window` — an ORPHANED open subtree root (`parent_id: None`, 12
  descendants) invisible to the closure lens**. RULING: the orphan is IN SCOPE — the honest before-count is
  **136**, and the triage re-parents that subtree under the epic root so the lens stops lying. Three of its
  ready rows (`pds-bl-large-task-write-500`, `pds-bl-charter-line-refs-stale`, `pds-w11-d193-leg-tension`) are
  ordinary defects with nothing crown-specific about them; silence here would flatter the wave by 7 rows. Any
  after-count is re-derived at its OWN named instant, never diffed against a differently-sampled before.

- **PDS-D298 — EVERY DISPOSITION IS VERIFIED BY RE-READING THE FIELD IT CLAIMS TO HAVE WRITTEN.** Truth-Grip
  wave 10 disposed 86 rows and CLAIMED all 45 parks carried a row-specific reason plus a named REACTIVATE
  trigger. Re-derived at review: **0 of 46 `considering` rows had a non-empty `content.engagement.note`** —
  44 of 45 adjudications evaporated. The mechanism worked; it was never used. So wave 22's triage carries the
  wave's OWN LAW applied to its own bookkeeping: **N disposed rows → N rows RE-READ from the server → N
  non-empty reason fields, with the counting command pasted into the criterion evidence.** Guerrilla writes
  are 15-33s degraded under concurrent waves — re-read AFTER settle, and NEVER conclude a write failed from an
  exit code. (This decision's *ruling* on wave 10's 45 parks — "the mechanism worked; it was never used" — is
  REFUTED AND SUPERSEDED by PDS-D309: our own `TtlSweeper` was the deleter. The re-read law below stands; the
  verdict on those 45 rows does not.)

  **VOCABULARY (three classes, each with a real write) — REWRITTEN in wave 24, post-D306 and post-S4.** The
  recipe this decision used to prescribe is now WRONG TWICE: it routed a park's reason to
  `content.engagement.note`, which D306 overturned (the engagement map is an EPHEMERAL lease the `TtlSweeper`
  deletes wholesale after ~900 s; the durable key is `content.disposition_reason`), and it told operators to
  hand-patch `content.disposition`, which the API now REFUSES — wave 24 slice S4 gave that field its first
  code writer and fenced the raw door (`Mutations.ensure_disposition_via_verb/4`, all four `apply_mutations`
  clauses, 422 `invalid_task_content` naming the verb). Use:

  - **CLOSED** → `bp task close <id> <worker> <epoch> done "<reason>"` → `content.close_reason`, which must
    name the fixing commit / charter line / live probe that makes the row moot.
  - **PARKED** → `bp task stage <id> considering --object research --worker <w> --disposition parked
    --note '<why it is parked>' --reopen-trigger '<what would make it worth reconsidering>' --yes` → writes
    `content.disposition` (normalised), `content.disposition_reason` and `content.reopen_trigger` in ONE
    atomic CAS write. **A park with no reopen trigger is REFUSED** (`missing_reopen_trigger`) — a deferral
    that cannot say what would bring the row back has decided nothing. A trigger already on the row satisfies
    a re-park.
  - **OPEN** → the same verb with `--disposition open --note '<why it stays open>'`, plus
    `content.disposition_owner` (a named owner) patched and re-published. `disposition_owner` is NOT fenced;
    `disposition` is.

  **THE ONE THING THIS RECIPE CANNOT YET DO, STATED RATHER THAN IMPLIED.** S4's fence and verb landed in
  `content/mutations.ex` + `tasks/stage.ex` only — its slice fence excluded `tasks_controller.ex` and the
  capability manifest in `plugins/tasks.ex`, both of which are hot in this wave. So `Barkpark.Tasks.stage/3`
  accepts `:disposition` / `:reopen_trigger` TODAY, but the controller does not yet forward those params and
  the manifest does not yet advertise the flags — meaning `bp task stage --disposition` and
  `POST /v1/tasks/:id/stage {"disposition": …}` are INERT until the wiring slice
  (`pds-w24-stage-disposition-wiring`) merges. **Do not merge S4's refusal ahead of that wiring**: the 422
  would name a retry instruction no operator can execute. Until then the only working writer is the Elixir
  seam.

  The term is trimmed and downcased by the verb, which is what closes the measured `OPEN` 57 / `open` 47
  two-case split at the source. NEVER patch `content.disposition` through `/v1/data/mutate` — the 422 names
  this recipe as the retry instruction. Erasing `content.reopen_trigger` raw while a row is parked is refused
  too; ADDING one raw is still allowed, and is the sanctioned remediation for rows parked hollow before this
  fence. RESIDUE, STATED: a `createOrReplace` on a BRAND-NEW id can still birth a hollow park — the
  fresh-create exemption is structural and inherited (see the guard's own "RESIDUAL HARM, MEASURED
  (disposition)" comment); closing it needs an attribution requirement on task BIRTHS. A CLAIMED row cannot
  be parked (`illegal_transition in_progress → considering`); a parent with open children is NOT closed
  (D71 shape).

- **PDS-D299 — ADJUDICATE BY CONTENT; CITED LINE NUMBERS ARE UNTRUSTWORTHY, AND EVERY `git log -S` CARRIES
  `--full-history`.** `pds-bl-close-holder-and-criteria-gate` cites `close.ex:157-161`, where main holds
  `compose_reconcile_evidence`/`merge_gate_synthetics`; `check_fencing/2` is at :308-316. PDS-D107's own
  anchors are stale by ~80 lines (:131/:139-147/:268/:533 vs the live :213/:249-260/:381/:650). And
  `origin/main` has **TWO root commits**: `b5299fcb6` is one of them and it re-adds
  `scripts/pds-pull-proof.sh` as a fresh 2,611-line file, so default pathspec history-simplification
  terminates the walk at that graft — `git log --oneline -S'pgrep -o -x beam.smp' origin/main --
  scripts/pds-pull-proof.sh` returns ONLY that docs commit and HIDES the real fix `58d1bd3a5`. Any `-S`
  without `--full-history` in this wave produces a confidently wrong answer.

- **PDS-D300 — ALL THREE CHARTER HOUSEKEEPING ITEMS ARE ALREADY DONE; THEY CLOSE ON EVIDENCE, NOT ON WORK.**
  `pds-w21-diagnose-and-fire` = done 7/7 (criterion 6's merge gate independently re-derived: `git merge-base
  --is-ancestor 59818468e origin/main` exits 0, and that commit is the #5547 fire record);
  `pds-w21-crown-collect-and-seal` = done 6/6. **Both are SELF closes** (`closed_by == claim.worker`, closed 7
  minutes and 4 seconds after their respective claims) — the digest's "flipped by a batch reconciler 36h after
  `closed_at`" story is REFUTED and must NOT be quoted as the override-not-refusal argument; the 76-row lead
  census (D288) is that argument. The worktree `/Volumes/SATECHI/github/barkpark-w21-fire` is absent from disk
  AND from all 1,464 registered worktrees. **`git worktree prune` is FORBIDDEN, forever** — live worktrees on
  this host hold uncommitted work.

- **PDS-D301 — PDS-D214 IS AN EXPIRED DEFERRAL, NOT A STANDING LICENCE; AND `archive.ex` MIS-CITES PDS-D207.**
  D214's out-of-scope call survives, in its own words, only because "the scratch target runs on the LOCAL
  16 GB Mac, never on guerrilla, with no concurrent live traffic and no lock-free public route" — four
  conditions an unattended owner's box negates. MEASURED (OTP 28 locally, with `extract1/4`'s
  `do_read(Reader0, Size)` source-verified IDENTICAL on the pinned OTP-27.3.4 tag): `:erl_tar.extract(path,
  [{:cwd, dir}])` is bounded by the **LARGEST SINGLE MEMBER at ~1.0x** — a 600 MB archive costs +400 MB with
  3×200 MB members, +20 MB with 60×10 MB members, +600 MB with one 600 MB member — while today's
  `{:binary, bundle}, [:memory]` mode (`archive.ex:255`) costs **3.0x BEAM / 3.4x RSS**, on top of an import
  body read (`workspace_controller.ex:589-595`) whose `length: 100_000_000` is a per-call chunk hint inside a
  `:more` loop with NO cumulative cap. erl_tar's `{chunks,N}` is an ADD option only — there is no chunked
  EXTRACT API, which is exactly why packing is constant-memory and unpacking is not. Live guerrilla is now
  `pg_database_size = 2,012,650,519 B` (was 942 MB at D41); `mutation_events` alone is `1,310,211,957 B` of
  COPY text, entirely on ONE workspace — so the current full bundle is **≈2.6 GB** and today's import would
  need ~7.8 GB of BEAM on a 3,819 MB box. Say **"1x largest member", NEVER "constant memory"**: after the
  medium fix the peak is still 1.31 GB today. And `archive.ex`'s own moduledoc credits **D207** for
  constant-memory packing, which D207 does not rule on (that is **D199 + D204**) — cite D199/D204 for delivery
  shape and D207 only for the identity gate. FILED, NOT BUILT this wave.

- **PDS-D302 — `:writes` FAILS OPEN AT THE SERVER, AND 16 MUTATORS ARE ADVERTISED READ-ONLY TO MCP CLIENTS
  TODAY.** `capabilities.ex:2561` defaults `"writes" => Keyword.get(opts, :writes, false)` across **111
  `core_cmd/8` call sites, 60 of which omit `:writes` and NONE of which passes `false`**. On the LIVE manifest
  (149 commands) exactly **16 non-GET commands carry `writes: false`** — 9 `auth.*` (register, login,
  verify-email, request-reset, reset, logout[DELETE], mfa-enroll, mfa-verify, mfa-disable) and 7 `chat.*`
  (create_session, update_session[PATCH], send_message, interrupt, approve, archive, unarchive). The omission
  was deliberate ("these are auth exchanges, not content mutations", :1866 and :2390) but the CONSUMER
  disagrees: `internal/cli/mcp_bridge.go:174-179` derives `ReadOnlyHint: true` straight from that bit, calling
  it "the one honest signal the bridge already sees" — so an MCP client is told `chat.send_message`,
  `chat.archive` and `auth.mfa-disable` are safe read-only calls. RULING: `writes` means "has side effects",
  the manifest is the thing that must be fixed, and the field name settles it. `core_commands/0` is a runtime
  `defp` (:681), NOT a module attribute, so a bare `Keyword.fetch!` does **not** crash at boot — it raises
  `KeyError` on the FIRST `/v1/capabilities` request, i.e. a TOTAL CLI OUTAGE behind a green boot, a green
  `systemctl status` and a green compile: the wave's own law violated by the wave's own fix. **The 60
  stampings and the `fetch!` LAND IN ONE COMMIT**, plus a guard test asserting every non-GET core command has
  `writes == true` — the `fetch!` alone only prevents future omissions and never catches a wrong `false`.

- **PDS-D303 — `GET /v1/data/counts/:dataset` REFUSES AN UNKNOWN `?perspective` RATHER THAN HONOURING IT.**
  LIVE: `?perspective=raw` and `?perspective=zzzbogus` both return HTTP 200 with a **byte-identical** published
  body (`diff` exit 0), both labelled `"perspective":"published"` — the endpoint accepts any string and
  silently normalises. `query_controller.ex:179` head-matches only `%{"dataset" => dataset}`, and the
  moduledoc declares the response shape FROZEN and the perspective deliberately fixed, so implementing `raw`
  would change a frozen query shape and need a fresh auth review (raw counts across all types are the exact
  existence leak the current design guards). The honest move is therefore the REJECT branch: accept
  `?perspective=published` as 200, **400 with a named code on anything else**. Blast radius is nil — exactly
  ONE HTTP caller exists repo-wide (`internal/cli/noarg.go:285`), it sends no query string, and
  `cli.go:544-548` drops the counts line entirely on any non-200; the LIVE manifest declares `data.counts`
  with `"flags": []`, so no perspective flag was ever advertised; and anonymous callers already 404. Live
  magnitude RE-DERIVED: `production/task` is **3214 published vs 3326 raw = 112 hidden draft rows** — the
  row's filed 213/164 are 2026-07-19 vintage and must never be quoted; any test asserts `raw > published`,
  never a literal delta. `docs/api-v1.md` does not document this endpoint at all, so its criterion is an ADD.

- **PDS-D304 — BUILDERS BASELINE ON THEIR OWN FILES, NEVER THE LOCAL FULL SUITE, AND NEVER HEAL MAIN'S
  STANDING FORMAT RED.** CI's `Test (Elixir 1.18.1 / OTP 27.0)` is GREEN on origin/main
  (`27 doctests, 12797 tests, 0 failures`) — "main is red" is FALSE. The LOCAL full suite shows **53 failures**
  on byte-identical content: 16 from a **SHALLOW clone** (`git rev-parse --is-shallow-repository` → true;
  `git describe --tags --match 'v[0-9]*'` exits 128, so `BuildInfo.version()` compiles to `"unknown"` and
  fails BuildInfo/SelfUpdate/update-banner tests — CI pins `fetch-depth: 0` precisely for this), 27 from a
  Tickets/OTP-28 divergence (`P0001 revision snapshot does not exactly match its document`, local Elixir
  1.19.5/OTP 28 vs CI 1.18.1/OTP 27.0), 10 undiagnosed. **None is in any wave-22 lane file** — all 13 targeted
  lane files run 276 tests / 0 failures. `mix format --check-formatted` fails on main with 88 files, THREE of
  them wave-22 surfaces: `status_controller.ex`, `status_controller_test.exs`, `tasks_controller_test.exs`
  (the break entered at `c79b0ddff` / #5826; its parent `19e2fb96b` is clean). A builder who runs `mix format`
  in those files ships a 10-line unrelated reformat — **format ONLY your own hunks**. Format and Sobelow are
  the concurrent Honest Gates wave's standing reds, not yours; read your PR's own Elixir Test gate instead.
  If a slice touches BuildInfo/SelfUpdate/the update banner, run `git fetch --unshallow --tags` first or the
  baseline is red before you start. (Note: main's `elixir` run reports run-level SUCCESS while its Format job
  is a FAILURE — the wave's law broken in the repo's own CI, one directory outside our fence. Flagged to
  Honest Gates, not built here.)

**THE WAVE — 8 slices, 7 in round 1, 1 deferred to round 2.** Two build tracks and one triage track, chosen so
no two slices touch the same region of a file. **LEDGER TRACK:** R1 `pds-w22-close-holder-criteria-honesty`
(opus; close.ex + internal.ex + tests; HIGH-FLIP-RISK — the holder-gate semantics and the honesty-vs-authorization
claim). **DEPLOY TRACK:** R1 `pds-w22-deploy-stamp-and-harness` (opus; `deploy/instance-deploy.sh` +
`instance-deploy_test.sh` — the stateful fake FIRST, then the stamp ordering) and R1
`pds-w22-status-commit-read-path` (opus; `status.ex` + `status_controller.ex` + test), with R2
`pds-w22-deploy-readback` (opus; `internal/cli/cloud_deploy_cmd.go`) deferred until the read path MERGES.
**RECEIPT TRACK:** R1 `pds-w22-receipt-and-sidecar-honesty` (opus; `internal/cli/cloud_workspace_cmd.go` +
test) and R1 `pds-w22-manifest-and-counts-honesty` (opus; `capabilities.ex` + `query_controller.ex` +
`docs/api-v1.md` + tests). **TRIAGE TRACK, ledger-only, no repo files:** R1
`pds-w22-triage-harness-and-crown-family` (opus; the D296 ruling applied to the 47-row harness family + the 8
crown-blocked rows + the D300 housekeeping evidence) and R1 `pds-w22-triage-remaining-rows` (opus; the
remaining ~82 rows adjudicated one at a time by content, plus the D297 orphan re-parent). The two triage
slices partition the 136 rows disjointly and both close under D298's re-read proof. **NO CROWN RE-FIRE. NO
FABLE ANYWHERE** (monthly spend limit — every slice is opus at medium).

### Wave 2026-07-27 (22) — SUCCESS MUST BE OBSERVABLE — round 1 built + reviewed, grade B+ (paper `pds-wave-22-2026-07-27`)

**WHAT LANDED — 7 slices, all gate-green on their final branch, all pushed, PRs #6420–#6426 open (the lead merges).**

| slice | final branch | PR |
|---|---|---|
| `pds-w22-close-holder-criteria-honesty` | `…closer-held-the-0-r` | #6420 |
| `pds-w22-deploy-stamp-and-harness` | `…fail-on-advance-a-1` | #6421 |
| `pds-w22-status-commit-read-path` | `…read-the-runni-2` | #6422 |
| `pds-w22-receipt-and-sidecar-honesty` | `…the-rows-it-mo-3` | #6423 |
| `pds-w22-triage-harness-and-crown-family` | `…and-the-crown--4` | #6424 |
| `pds-w22-triage-remaining-rows` | `…is-adjudica-5` | #6425 |
| `pds-w22-manifest-and-counts-honesty` | `…stops-advertis-6-r` | #6426 |

Five product verbs stopped lying: the close ledger (holder + criteria + sentinel gates), the deploy slot
stamp (written only after the health gate) and its harness (a stateful fake HEAD, so ADVANCE and STALL are
finally distinguishable), the public running-commit read path, the import receipt and blob byte-verify, and
the capabilities `writes` bit (16 mutators were advertised read-only to MCP clients) + a counts perspective
that was silently discarded. Every one was proven by mutation, not by reading.

- **PDS-D305 — MERGING #6420 CHANGES HOW EVERY SEAL CLOSE WORKS, INCLUDING THIS WAVE'S OWN.** `api/**`
  auto-deploys on merge, so the moment #6420 lands, guerrilla enforces the holder gate. Every wave-22 slice
  row's last holder is its BUILDER, so a lead sealing them is a foreign close: `409 not_holder:<builder>`
  unless the close carries `--set holder_override="<why>"`. A close over a still-unmet criterion needs
  `--set criteria_override="<why>"`. Both ride the ordinary close body (`bp task close … --set`); the
  reviewer wired them through `tasks_controller` close/2 because the builder's slice left the gates
  REFUSE-ONLY over the wire — a lead could not have sealed anything and nobody could have closed over an
  honest unmet criterion at all. **Merge #6420 LAST, or seal the other six rows before it deploys.**
- **PDS-D306 — `content.engagement.note` IS NOT A DURABLE FIELD; `content.disposition_reason` IS.** The
  reviewer's independent census over the whole epic scope (265 rows) measured **engagement.note survival 0
  of 31** parked rows and **disposition_reason survival 12 of 12**. The harness/crown slice's 8 parks all
  survived because it wrote BOTH; the remaining-rows slice's 23 parks were written with `bp task stage
  --note` alone and **19 lost their reason within hours**. All 31 rows carry a `content.github` key,
  consistent with a reconciler rebuilding `content` wholesale. The reviewer re-parked all 19 into
  `disposition_reason` (19/19 re-read and confirmed), but their ORIGINAL adjudication text is
  unrecoverable — Truth-Grip wave 10's failure reproduced INSIDE the wave that wrote D298 against it.
  Ruling: **every park reason is written to `content.disposition_reason`. `bp task stage --note` alone is
  never a disposition.** `pds-bl-stage-note-evaporates` was closed as a duplicate into
  `pds-bl-park-note-evaporates`, which now carries the census.
- **PDS-D307 — THE BLOCKING SET SHRANK 145 → ~124 OPEN, AND ONLY 5 OF THAT IS A FIX.** 137 rows were
  adjudicated by content (101 OPEN-with-a-named-owner, 31 PARKED, 5 CLOSED). That is an honest triage, not
  a burn-down: 31 are parks carrying reactivation triggers and the closes are dedup/already-fixed. The
  D300 housekeeping closed on evidence (both w21 rows already done 7/7 and 6/6, both SELF closes; the
  `barkpark-w21-fire` worktree absent from disk AND from all 1,466 registered worktrees).
  **`git worktree prune` was NOT run and stays forbidden.**
- **PDS-D308 — THE LARGE-TASK WRITE CEILING IS LIVE AND BIT THE REVIEWER TOO.** A ~1 KB
  `disposition_reason` patch onto `pds-w22-triage-harness-and-crown-family` published `422
  validation_failed`; the same field at ~260 B published first try. `pds-bl-large-task-write-500` is real,
  reproducible, and now has two independent witnesses.

**WHAT DID NOT LAND.** `pds-w22-deploy-readback` (round 2 by design — it reads the `/status.json` field
#6422 adds, so it dispatches only after #6422 merges). The deploy verb still exits 0 and logs HEALTHY on a
stall: wave 22 made that VISIBLE to the harness, it did not make the verb refuse. And the four named
starting points are 2 of 4 done — `deploy-success-without-advance` is half-closed (observable, not refused),
`close-holder-and-criteria-gate` is BUILT, `streaming-workspace-export` was re-scoped to its import half
(`pds-bl-bounded-import-unpack`), and **`pds-bl-scratch-pointer-concurrency` was taken by NO slice** — its
defect 2 was stamped already-fixed and defect 1 is still open.

**WHAT THE NEXT WAVE SHOULD TAKE.** (1) Dispatch `pds-w22-deploy-readback` the moment #6422 merges. (2) Fix
the evaporation defect (`pds-bl-park-note-evaporates`) — the ledger is this epic's spine and 19 lost
adjudications is the wave's own failure class. (3) Take the correctness rows the triage named as the
strongest build candidates: `pds-bl-scratch-pointer-concurrency` (defect 1), `pds-bl-w16-full-meta-permissive-default`,
`pds-bl-w16-failed-refetch-destroys-parked-bundle`, `pds-bl-bounded-import-unpack` — all report-success-while-wrong
shapes, all mutation-provable without any fire. (4) Decide whether D289's doc-as-read criteria gate is wider
than the defect it closes; that judgment is flagged HIGH-FLIP-RISK and an independent second reviewer is owed.

---

## WAVE 23 — THE LAW GETS TEETH (2026-07-28)

Wave 22 proved the law five times by hand. Wave 23 makes the repo enforce it on the surface where an
honest gate is buildable, pays the eight measured debts, and fixes the ledger defect that ate wave 22's
own adjudications. Wave Paper: `pds-wave-23-2026-07-28`. Fence: `api/**`, `internal/**`, `deploy/**`,
`bin/**`, `scripts/pds-*`, `docs/**`, the `pds-*` namespace. **`cloud/**` and `.github/workflows/**` are
OUT** (see PDS-D312). Fable unavailable — all 8 slices are Opus.

### The verify round's headline: three briefed premises REFUTED, one charter decision REFUTED

- **PDS-D309 — THE LEDGER'S DELETER IS OUR OWN `TtlSweeper`, NOT A GITHUB RECONCILER, AND PDS-D298 IS
  REFUTED.** Proven at runtime against guerrilla's own Postgres: `pds-bl-bp-search-false-negative` was
  staged at 20:02:00.455593 (event 124105) and lapsed at 20:17:01.430503 (event 124308) — **15m00.97s**.
  `ttl_sweeper.ex:540` is `Map.delete("engagement")` against `@default_engagement_ttl_seconds 900`
  (:144), swept every minute; guerrilla sets no `BARKPARK_TASK_ENGAGEMENT_TTL_SECONDS`, so 900s is live.
  The GitHub hypothesis is dead — there is no content merge in `plugins/github/`, and `content.github`
  sits on **90/90** open rows, a base-rate confound with zero discriminating power. `disposition_reason`
  survives *structurally*, because the sweeper deletes exactly one key by name.
  **The defect is a CATEGORY ERROR**: a DURABLE adjudication reason piggy-backed onto an EPHEMERAL 900s
  ownership lease, with `bp task stage --note` returning `ok:true` on a field with a 15-minute half-life
  and saying nothing. That is this epic's own law violated on the ledger the epic is audited on.
  **PDS-D298 IS REFUTED AND SUPERSEDED**: it ruled Truth-Grip wave 10's 45 parks "never used" by
  re-reading the ROW. Exactly **45** `tgw*` rows carry a recoverable staged note and **all 45** contain a
  `REACTIVATE:` trigger. Wave 10 DID write them; the sweeper ate them 15 minutes later. D298's verdict was
  itself rendered on a read that structurally could not see the state it judged. D298's *proof standard*
  (re-read and COUNT after every disposition write) STANDS and is reaffirmed; only its factual verdict on
  wave 10 is withdrawn.
  **The notes are RECOVERABLE** — both the `task.staged` payload (`stage.ex:230`) and the
  `task.engagement_lapsed` payload (`ttl_sweeper.ex:598`) carry them verbatim; 158 rows have a recoverable
  note and **0** still carry `content.engagement`. But `bp task events` structurally CANNOT reach them:
  `events.ex:90-96` projects `%{id,event,doc_id,rev,at}` and drops the payload by design. Recovery
  therefore needs DB access or a new endpoint — **filed, NOT built this wave** (`pds-bl-recover-lost-park-notes`).
- **PDS-D310 — `put_bytes` IS A WRITE-ACK, NOT AN EXIT CODE, AND THE CHEAP FIX IS A PROVEN FAKE GREEN.**
  S3 gates on HTTP 2xx (`s3.ex:190`), Local on `File.write`'s syscall (`local.ex:33`) — writing "reports
  success on an exit code" is refutable in one grep and must not be written. The honest claim is
  **RECEIVED vs STORED with no post-condition read**. Proven by running against a black-hole bucket (200
  on PUT, stores nothing): `File.stat(Media.file_path(rel))` returns `{:ok, %File.Stat{size: 11}}` — it
  PASSES — because `S3.put_file/3` warm-caches the SOURCE to that exact path (`s3.ex:70`). Worse,
  `S3.ensure_local/1` short-circuits on `File.regular?` (`s3.ex:117`) and returns `{:ok, path}` with ZERO
  bucket requests, so "read it back through the abstraction" is a SECOND fake green. The bucket is
  provably empty: drop the cache copy and `ensure_local` = `{:error, :not_found}`.
- **PDS-D311 — THE TICKETS "OTP-28 DIVERGENCE" IS REFUTED; AN AMENDED-IN-PLACE MIGRATION IS THE CAUSE, AND
  `mix ecto.migrations` IS ITSELF A SUCCESS-LIE.** A virgin partitioned DB, migrated fresh, ran the
  tickets suite **161 tests, 0 failures** on Elixir 1.19.5 / **OTP 28** / PostgreSQL 17.9 — green on the
  toolchain the row blames. Root cause found by content: `2e0ca88c7` (2026-07-19 02:19) shipped
  `barkpark_bind_document_revision()` with the exact-equality predicate `document.doc_id = NEW.doc_id`;
  **`a0357fff3` (06:11, four hours later) EDITED THAT SAME ALREADY-SHIPPED MIGRATION FILE** to add
  `drafts.`-prefix stripping. Both are ancestors of origin/main. Migrations never re-run, so any database
  created in that window keeps the broken trigger forever and raises `P0001 revision snapshot does not
  exactly match its document` on every draft revision. A 242-database sweep inverts the briefed premise:
  the md5 treated as canonical (`5a285095…`) exists in **exactly one** DB — `barkpark_test`, the one the
  prior investigation hand-replaced — while 31 carry the real migration output `7ce03b36…` and 210 predate
  the migration. The two texts differ only in leading whitespace (`diff -w` exits 0), so the surviving
  "drift" is inert.
  **The generalisable finding outranks the row**: `mix ecto.migrations` reporting zero pending is a
  success claim backed by a version-number bookkeeping row, never by a read of the object the migration
  claims to have produced — and it lied here. In-place amendment of a shipped migration is a silent,
  permanent divergence class, and prod auto-deploys on `api/**`, so the window was live. Charter
  PDS-D304's "27 from a Tickets/OTP-28 divergence" attribution is **CORRECTED** by this entry.
- **PDS-D312 — THE FENCE HOLDS OFF `.github/workflows/**`, BUT ALL THREE SURFACES ALREADY HAVE A FREE
  RIDE, SO GATE-VS-DOCUMENT IS RULED PER SURFACE, NOT PER TRACK.** `go-tests.yml` fires on `**/*.go` for
  push AND pull_request — a Go test under `internal/cli/` rides free, in fence, mutation-provable.
  `elixir.yml` carries NO workflow-level `paths:` **by design** (D18/D31 skip-shim), so an ExUnit test
  rides free too — the digest's "the Elixir surface has no free ride" is REFUTED.
  `deploy-harnesses.yml` already enumerates `deploy/instance-deploy_test.sh`, so assertions added INSIDE
  it ride free — **PR-only, no push-to-main leg, and any slice claiming that coverage must say so.**
  What is genuinely out of fence is a NEW standalone harness wired by a new `run:` step:
  `shell-harnesses.yml` is path-pinned to `doctor.sh`/`doctor.test.sh` alone. **`scripts/pds-*` has ZERO
  CI coverage today** (`grep -rln 'pds-' .github/workflows/` is EMPTY), so the two harness fixes are
  LOCAL-HARNESS slices and the wave must not imply a gate.

### The rulings that shape the build

- **PDS-D313 — "RESPONSE-BACKED" IS NOT ONE CLASS. IT IS THREE, AND THE AXIS IS THE MEASUREMENT POINT.**
  Not response-vs-second-read, and not record-vs-running-box. The charter already reasons this way:
  PDS-D295 ruled the blob count must say "received" **because `byte_size(body)` is measured BEFORE
  `Blobstore.put_bytes/3`**. Generalised:
  - **A1 RELAYED POST-CONDITION — SATISFIES THE LAW, no second read required.** The response field was
    measured by the server AFTER the state change, FROM the state itself. `bp cloud site rollback`'s "is
    now serving deployment %s" (`cloud_site_cmd.go:542`) is A1: `Sites.Deploy.rollback/2`
    (`deploy.ex:714`) BLOCKS until the box confirms the flip and resolves the id from the sha the BOX
    reported about itself. A CLI-side second read here buys nothing and would INTRODUCE a flip race.
  - **A2 PERSISTED-RECORD ECHO — satisfies the law for claims about THE RECORD.** `autoupdate pin`
    printing `policy.PinnedRelease`: the response IS the record; a second GET reads the same row.
  - **A3 VERB-DERIVED / REQUEST ECHO — VIOLATES THE LAW even though a response exists.** `autoupdateReceipt`
    (`cloud_autoupdate_cmd.go:142-154`) takes `policy` and, for `unpin`/`pause`/`resume`/`default`, reads
    **nothing from it** — `✓ <ref> autoupdate paused` prints unchanged if the server returned
    `paused:false`. Re-derived on origin/main this run. This is D295's "the echo exists and is discarded",
    and NO test pins those strings today.
  **THE MECHANICAL REVIEWER TEST, and it is the deliverable rather than the taxonomy:** *would the printed
  sentence change if the server's response said the opposite?* No → unbacked, regardless of round trips.
  Yes → ask what the field measured. This is mechanically assertable — feed a contradicting response into
  the render function and assert the printed line changes — and **that is the guard's shape.**
- **PDS-D314 — THE GUARD IS A BEHAVIORAL REGISTRY TEST, NOT A CHECKMARK RATCHET, AND SHELL + ELIXIR SHIP A
  CENSUS DOCUMENT WITH NO GATE.** Measured: the shell surface carries **12** `✓` glyphs and every one is
  inside a `site-spawner-*-proof.sh` harness — `TOTAL_NONPROOF` is literally **0**, so a shell guard would
  green vacuously, which is the exact failure this epic names. `api/lib` carries **47** glyphs and **ZERO**
  in `IO.puts`/`IO.write` — all LiveView chrome, so a glyph-keyed Elixir guard yields 47 false positives.
  Go: 94 glyphs = 13 noise + 81 real (56 in a remote-calling function, 17 DECOUPLED emitters, 8 genuinely
  local). A function-scoped ratchet is blind to the 17 emitters AND its evasion is a two-line refactor.
  **Ruling: the Go gate is a table-driven test over an enrolled registry of receipt-RENDER functions,
  keyed on the claim, never the glyph** — which inverts the emitter problem, since a decoupled emitter is
  precisely a render function and is the EASIEST thing to enroll. A registry entry cannot be satisfied by
  a non-empty classification string. Shell and Elixir get a census document with per-site evidence, NO
  gate, and a plain statement that the law is unenforced there. **Refusing to ship a fake green is the
  successful outcome for those surfaces.**
- **PDS-D315 — THE DEPLOY READ-BACK NEEDS AN EXPECTED SHA; BEFORE/AFTER ALONE CANNOT PRODUCE THREE OF THE
  FOUR OUTCOMES.** A coalesce exits 0 early with no rebuild (`instance-deploy.sh:311-315`), byte-identical
  to a STALL from the CLI's vantage, and MISMATCH is underivable without an expectation. `git ls-remote`
  works fully unauthenticated (proven with `GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null HOME=/nonexistent
  -c credential.helper=`; the repo is public) for `refs/heads/<b>` AND `refs/pull/N/head`. Four traps, all
  run-proven, each of which ships a mirror-image lie if missed:
  1. `git ls-remote <url> main` returns **TWO** lines (the pattern is suffix-matched against a tag path
     ending `/main`). Query `refs/heads/<branch>`, never the bare name.
  2. `git ls-remote origin refs/heads/no-such-branch` **EXITS 0 WITH EMPTY OUTPUT** — gating on `err != nil`
     is itself a success-claim on an exit code, inside the anti-success-lie slice. Empty stdout routes to
     UNPERFORMABLE(unknown ref), never to a comparison against `""`.
  3. Short-sha length is **ADAPTIVE**: 7 chars in a real `--depth 1` clone, 9 on guerrilla, 40 from
     ls-remote, for the same commit (`core.abbrev` unset). `==` manufactures a false MISMATCH. Compare the
     SERVED short sha as a PREFIX of the EXPECTED full sha, never the reverse.
  4. UNPERFORMABLE has **FOUR** live shapes needing four distinct messages: key ABSENT (a pre-`c73f22a0b`
     build — `status.ex:98-107` guarantees a post-dependency build renders `"unknown"` rather than
     omitting, so ABSENT *proves* a stale build and must say exactly that), route ABSENT (404), host
     UNRESOLVABLE (000), and the legal string `"unknown"`. Collapsing them to one string is itself a mild
     information-lie.
  **The AFTER-read race is REFUTED and the window is NEGATIVE**: `instance-deploy.sh` health-gates the new
  slot on its own port for up to 40×5s (:739-743), reloads Caddy (:784), then runs ~290 more lines before
  `exit 0` (:1075); there is `set -uo pipefail` with NO `-e` and ZERO non-zero exits after :790, and the
  served `commit` is a COMPILE-TIME module attribute (`build_info.ex:100`) so it cannot advance off a
  `git reset --hard`. No caching anywhere (`max-age=0, private, must-revalidate`, no `age`/`x-cache`/`etag`,
  three reads = three origin hits). A 3×5s retry is free insurance and is required anyway. **PDS-D304's
  shallow-clone hazard does NOT reach `commit`** — `rev-parse` survives a shallow clone, `describe` does
  not: read `commit`, never `version`.
  **Field reality the acceptance criteria must state or a reviewer reads correct output as a broken
  feature:** there is NO default target (`resolveDeployHost` errors out); `staging` and `prod` resolve to
  NOTHING (no fleet row, no DNS) so the wish's own `bp cloud deploy staging` example is a phantom; and
  **3 of the 4 real fleet boxes serve `/status.json` with `commit` ABSENT**, so the first live run against
  anything but guerrilla is correctly UNPERFORMABLE. The slice is self-healing — deploy a stale box once
  and the read-back works from then on. All four rows have `autoupdate_enabled:true`, so **re-derive the
  commit-key census immediately before stamping evidence, never from this charter.**
  Last trap: `--host` INVENTS the health FQDN (`deriveHealthHost`) and the on-box gate curls with
  `--resolve HOST:443:127.0.0.1`, bypassing public DNS — the box's own gate and a CLI read-back do not
  resolve the same name, so the `--host` path must declare UNPERFORMABLE loudly rather than borrow the
  script's confidence. `gyldendal`'s health host is `gyldendal-506f035e.barkpark.cloud`, NOT
  `gyldendal.barkpark.cloud`.
- **PDS-D316 — BOUNDED IMPORT KEEPS ITS BODY HALF, AND THE REAL HAZARD IS 20 TRIPWIRES NOBODY NAMED.**
  The row that the body half would be deferred into — `pds-backlog-streamed-bundle-channel` — is `done`
  with **0/4** criteria met, closed by wave 22; deferring would strand it permanently. Its AC #1 already
  IS the 413, and `read_full_body/2` (`workspace_controller.ex:590-594`) loops on `:more` with `length:`
  as a per-CALL chunk hint and no cumulative cap, so the whole ~2.6 GB body materialises BEFORE
  `Archive.unpack/1` is reached: shipping disk-backed extract alone would report "bounded import" with the
  single largest allocation untouched.
  **The hazard**: `dumps` is consumed at 42 sites and **20 of them are `refute dumps[...] =~ "<marker>"`**
  cross-tenant isolation tripwires. Proven by running — under a path-valued `dumps`,
  `dumps["documents"] =~ "B-ONLY-CIPHERTEXT-xyz"` is **false** while the bytes on disk DO contain it. The
  loud md5 assert reds; **all 20 refutes pass VACUOUSLY**, silently disarming the epic's tenancy-leak
  suite. **Ruling: `unpack/1` KEEPS its binary contract at the test boundary; the engine gets a new
  `unpack_to_dir/2`.** One production caller changes (`workspace_bundle.ex:298`), not 42 tests, and the 20
  refutes stay real. Do NOT accept `:crypto.hash(:md5, File.read!(path))` as the incremental rewrite — it
  passes AND re-materialises the 1.31 GB member.
  Say **"1× the LARGEST MEMBER"**, never "constant memory": measured 1.00× for one 600 MB member vs 3.0×
  for today's `[:memory]` shape. Peak transient disk is **~5.2 GB** (body spill + extracted members held
  together), not 3.9; guerrilla has 12.09 GiB free on ONE filesystem carrying `/`, `/tmp` AND
  `/opt/barkpark`, while running at 2176 MB available with **1468 of 2047 MB swap already consumed**. There
  is **ZERO free-space precondition anywhere in the bundle path**, so the slice ships one or it trades a
  diagnosable OOM for an undiagnosable ENOSPC. The janitor sweeps two FILE prefixes and would not collect
  an import scratch DIRECTORY. This slice does **NOT** unblock the crown (that is the EXPORT's 2235 MiB
  peak) — reporting it as crown progress would itself be a success-lie.
- **PDS-D317 — HARNESS ARM-TIME LIVENESS IS SETTLE-THEN-CLASSIFY, AND THE CHECK MUST BE AN EXTRACTED
  FUNCTION.** A bare `pid_live` at t+0 is a **COIN FLIP**, measured: armed with a payload that is literally
  `exit 0`, run 1 returned rc=0 (LIVE) while `classify` microseconds later on the same line already said
  KILLED; three consecutive re-runs returned rc=1. A t+0 check would print green over a dead climb roughly
  half the time. The honest shape uses pieces already in the file: the generated child's FIRST action is
  `stamp "child up — pid=…"`, so after a short settle the launcher READS THE TRANSCRIPT for a marker the
  child itself produced, then runs `classify` (KILLED at t+1s and t+3s, 4/4). **The banner must say "child
  is UP as of <t>", never "the climb will complete"** — a green read at t+N is necessary, not sufficient.
  The check MUST be extracted (e.g. `assert_child_up`) because the selftest reaches `fire_detached`
  directly and never `cmd_arm`; inlined, it ships untested by the harness that exists. The failure was
  PREDICTED in-repo — `pds-climb-preflight.sh:397` (PDS-D258) describes it verbatim and shipped a WARNING
  instead of a read.
- **PDS-D318 — THE SCRATCH POINTER IS ONE DEFECT WEARING THREE ROWS, AND TEARDOWN'S PASS IS SCOPE-TRUE
  BUT READ AS INSTRUMENT-CLEAN.** Reproduced offline end-to-end: a second `up` clobbers the single global
  `POINTER_FILE` (`:124`, written unconditionally at `:381`); `teardown` then destroys the WRONG root,
  prints `---- teardown: PASS`, clears the pointer, and ALL FOUR verbs die with `no scratch target known`
  while root A still stands. Teardown's clear is ALREADY guarded to fire only when the pointer names the
  root it removed — the strand comes from the CLOBBER, not a careless clear, so fixing either half alone
  leaves it intact (`resolve_home` has exactly TWO sources: `$BARKPARK_HOME` or the pointer). Ruling: ONE
  registry directory (one file per live root; `up` adds, `teardown` removes only its own, `resolve_home`
  refuses-with-a-list when more than one survives), retiring `pds-bl-scratch-pointer-concurrency`,
  `pds-bl-scratch-teardown-strands-the-survivor` and `pds-bl-scratch-pointer-explicit-default` — whose own
  reason already reads "MERGE CANDIDATE, not independent work". There is no scratch test file anywhere in
  the repo; `deploy/instance-deploy_test.sh` is the pattern to copy. The crown launcher already practises
  the fix (`fire_detached` exports a per-run `PDS_SCRATCH_POINTER`).
- **PDS-D319 — TWO UNFILED SUCCESS-LIES ARE INVISIBLE TO A GLYPH CENSUS, AND `bp export` IS ALSO 100%
  BROKEN.** `barkpark status` decides liveness from a bare `kill -0` on a pidfile (`bin/barkpark:139-141`)
  while `listener_pid()` — `lsof -tiTCP:$PORT -sTCP:LISTEN` — sits FOUR LINES above and is already used by
  both `start_server` and `stop_server`. Both directions observed: a pidfile pointing at a `sleep`
  reported "server running … http://localhost:4000" exit 0; and with ZERO setup this box reported "server
  stopped" exit 0 while `beam.smp` pid 8004 held :4000 and `/api/schemas` returned 200. `bp export` — the
  documented BACKUP verb — emits no document count and exits 0 by explicit design
  (`export_cmd.go:61`) on a Ctrl-C-truncated file. Neither carries a `✓`, so a glyph-keyed census finds
  neither.
  **AND THE SEQUENCING RULING:** `bp export` cannot succeed against ANY server today — the client
  hardcodes `Accept: application/x-ndjson` (`apiclient/export.go:47`) while `:scoped_api` is
  `plug(:accepts, ["json"])` (`router.ex:143`), so Phoenix 406s before auth and the operator sees only
  `export: unknown error`. Proven on guerrilla (`ndjson=406` vs `json=401`, same URL) and locally (the
  body names `Phoenix.NotAcceptableError`). `bp export > backup.ndjson` writes an EMPTY FILE today.
  **The Accept fix lands FIRST**, or a truncation test greens a path no operator can reach — the exact
  vacuous green this epic distrusts. Server-side adjacent: `export_controller.ex:22` is
  `{:ok, acc} = chunk(acc, line)`, a MatchError on `{:error, :closed}` inside a `Repo.transaction`.
- **PDS-D320 — ONE ROW CLOSES FOR FREE; THREE DO NOT, AND THE ONE THAT LOOKS FIXED FROM THE COMMIT LOG IS
  NOT.** `pds-bl-blob-sidecar-byte-verify` is CLOSE-ELIGIBLE **verified by content, not by a PR subject
  line**: both legs verify (`putOneBlob` fails by name on a missing echo AND on a mismatch;
  `fetchOneBlob` fails on `n != ref.size` and reports `verified=false` when the size is NULL), the wording
  stays RECEIVED-not-STORED, and three tests pass including `TestBlobFetchSizeMismatchIsANamedFailure`
  which serves `TRUNCATED` against a declared 9999. **Record the honest deviation when closing**: AC #1
  says "both legs compare against the bundle's `media_files.size`" and the PUSH leg cannot — on import
  there is no bundle-declared size, so it compares the local stat against the target's echo, which is the
  stronger available comparison.
  **DO NOT CLOSE**: `pds-bl-manifest-writes-fails-open` — #6426 shipped D302's SERVER half
  (`Keyword.fetch!(opts, :writes)` + the non-GET guard test) but the row's OWN criteria 1-2 are the Go
  tri-state, and `manifest.go` still declares a plain `Writes bool` while `usage.go:309` infers on the
  zero value; worse, `normalize_command/1` (`capabilities.ex:438-444`) applies NO writes default, so
  plugin commands STILL fail open (`plugin.ex:536`'s `required(:writes)` is a TYPESPEC, dialyzer-only).
  `pds-bl-close-audit-gaps` — both holes stand: `apply_close_update/8`'s fallthrough writes only
  `lifecycle_status`, and `board_live.ex:459` passes no `caller_token_id` though `close.ex:77` accepts it;
  60 close tests pass and cover NEITHER, which is itself the finding.
  `pds-bl-deploy-success-without-advance` — closes only when the read-back lands.
- **PDS-D321 — THE OWNER-WALK SEED RUNS UNDER PROD, AND IT IS A FOUR-ROW CLUSTER WITH A CRASH IN IT.**
  Proven: with cmd_up's post-`load_env` environment, `mix run --no-start` printed
  `PROD_RUNTIME_OK ensure_loaded=true seed1=true` — `cmd_up` ALREADY runs `mix ecto.migrate` under the
  same exported `MIX_ENV=prod`, and the `MIX_ENV=dev` carve-out is scoped to `ensure_secrets` alone
  (which runs before the env file exists). Ordering is load-bearing: seed strictly AFTER `ensure_secrets`.
  Booting for the seed does NOT bind PORT (`server: true` only under `PHX_SERVER`).
  **Two things the row does not say.** (1) `admin_token_present?/1` requires `is_nil(revoked_at)`, so an
  unconditional up-seed RE-MINTS after a revoke — which directly contradicts
  `pds-bl-admin-token-mint-path` AC #3 ("cannot mint another admin token after the bootstrap gate
  closes"). (2) `api_tokens.token_hash` is unique-indexed and `mint_admin_token!` hard-matches
  `{:ok, _token}`, so a FIXED `BARKPARK_SEED_ADMIN_TOKEN` that is later revoked makes the next `up`
  MatchError and die under `set -euo pipefail` — a boot verb bricked by a revoke.
  Cluster: `pds-bl-owner-walk-reaches-the-mint` is the survivor; `pds-bl-admin-token-mint-path` is
  superseded (**migrate its AC #3 before parking it — it is the only security requirement in the
  cluster**); `pds-bl-personal-local-doc-staleness` and `task-5c4f2673778d5ff0` are the doc half, and that
  premise is **2/3 already fixed on main** (`personal-local.md:88-89` already carries `BARKPARK_MEDIA_DIR`
  and `BARKPARK_ALLOW_BUNDLE_IMPORT`; only KEK is missing from the Overrides TABLE). **FILED, NOT BUILT
  this wave** — the wave is already at 8 slices.
- **PDS-D322 — THE LEDGER'S PARKS ARE HOLLOW: WAVE 23's OWN STANDARD IS MET BY ZERO ROWS.** All 8 direct
  children carrying `disposition=parked` hold a `disposition_reason` of **exactly 644 bytes, MD5-identical
  across all 8** — the reviewer's generic evaporation notice, not a row-specific reason, and **0 of 8**
  carries a reopen trigger. 12 further rows carry NO `disposition` key at all (never adjudicated),
  including two the wish names as measured debts. D307's "31 PARKED" is not observable in the direct-child
  set. The write ceiling (PDS-D308) tracks **TOTAL DOCUMENT SIZE, not field length**: a 902 B reason
  landed on a 32,659 B doc while the row that 422'd at ~1 KB is 36,804 B, the largest in the set. Longest
  reason that has ever landed is **969 B** across 163 rows. **Operating bound: ≤900 B, and check the
  target doc's size first; on docs >35 KB split the write.**
- **PDS-D323 — SCHEDULING RACE, NOT A FILE CONFLICT: HONEST GATES S8 WOULD KILL THIS PHASE.** An Honest
  Gates wave is mid-flight (round 1 merged 04:18-04:22 UTC today, #6500-#6503; rounds 2-3 unbuilt). Its S8
  enables branch protection with `enforce_admins:true`, and its own D39 is L1-measured that protection
  REJECTS a direct `git push` — naming `bp-epic-cycle.workflow.js:726-727`, the Decide phase that commits
  the charter and grip ledger rows straight to main. Verified NOT yet on (`branches/main/protection` →
  404, `rulesets` → `[]`), so today it works. **Decide publishes EARLY.** Also: no open PR touches
  `internal/cli/`, `deploy/` or `scripts/pds-*`; `origin/loop-epic/r3b-trusted-proxies-deploy` is
  squash-landed and now BEHIND main — **merging or cherry-picking from it would DELETE wave 22's own D291
  slot-sha fix** (1 insertion / 21 deletions against main). Exactly ONE live foreign claim exists ledger-
  wide (`mob-rt-s7-stable-emitter`), outside the fence. `bp task ls --status` DOES NOT EXIST — use
  `bp task prime`, and never derive live claims from `claim.expired_at` (stamped by the REAP, so the
  filter returns ZERO across all 3,415 rows).

### The wave — 8 slices, 7 in round 1

| # | Task | Surface | Round |
|---|---|---|---|
| 1 | `pds-w22-deploy-readback` | `internal/cli/cloud_deploy_cmd.go` | 1 |
| 2 | `pds-w23-success-claim-registry` | `internal/cli/` + census doc | 1 |
| 3 | `pds-bl-park-note-evaporates` | `api/lib/barkpark/tasks/` | 1 |
| 4 | `pds-bl-bounded-import-unpack` | `api/lib/barkpark/tenancy/workspace_bundle/` | 1 |
| 5 | `pds-bl-blob-storage-readback` | `api/lib/barkpark/media/blobstore/` | 1 |
| 6 | `pds-w23-harness-liveness-and-registry` | `scripts/pds-*.sh` | 1 |
| 7 | `pds-w23-cold-owner-verb-honesty` | `bin/barkpark`, `internal/cli/export_cmd.go`, router | 1 |
| 8 | `pds-w23-triage-round` | ledger only — AFTER #3 merges | 2 |

Slice 8 is round 2 **by necessity, not caution**: PDS-D309 means any disposition written before the
evaporation fix merges is lost within 15 minutes — exactly wave 22's failure, repeated.
HIGH-FLIP-RISK (an independent second reviewer is owed before merge): **#1** (the UNPERFORMABLE
classification — four shapes, three of them not "unreachable"), **#2** (the guard is the wave's own
candidate success-lie), **#5** (the File.stat fake green is proven and the obvious fix is the trap).

### Wave 2026-07-28 (23) — FINISH WHAT 22 STARTED — round 1 built + reviewed, grade A− (paper `pds-wave-23-2026-07-28`)

**SEVEN OF SEVEN ROUND-1 SLICES BUILT, GATED, REVIEWED, PUSHED AND PR'd — #6548–#6554.** That last
clause is the one that has been missing from six previous waves; this wave did not end with work on
local-only branches in a shared checkout. Round 2 (`pds-w23-triage-round`) is deferred BY DESIGN and
must wait for #6550.

| Slice | Final branch | PR | Verdict |
|---|---|---|---|
| `pds-w22-deploy-readback` | `…bp-cloud-deploy-proves-the-box-advanced--0` | #6548 | four named outcomes; live-fixture proven, no real ssh deploy (honest miss) |
| `pds-w23-success-claim-registry` | `…success-claims-prove-themselves-a-behavi-1` | #6549 | behavioral gate, mutation re-proven by the reviewer; census corrects the brief's own numbers |
| `pds-bl-park-note-evaporates` | `…the-ledger-stops-eating-its-own-adjudica-2-r` | #6550 | key split shipped; reviewer fixed the manifest that still described `engagement.note` |
| `pds-bl-bounded-import-unpack` | `…bounded-import-spill-the-body-extract-to-3-r` | #6551 | both halves; reviewer named the two 500-shaped failure paths |
| `pds-bl-blob-storage-readback` | `…the-blob-receipt-stops-claiming-stored-a-4-r` | #6552 | the warm-cache trap is pinned as a test; reviewer proved the 502 over HTTP |
| `pds-w23-harness-liveness-and-registry` | `…the-pds-harnesses-stop-lying-armed-prove-5` | #6553 | ARMED reads a marker the child wrote; registry replaces the single pointer |
| `pds-w23-cold-owner-verb-honesty` | `…the-two-verbs-a-cold-owner-types-first-s-6` | #6554 | `bp export` WORKS now (it 406'd against every server); status reads the port |

- **PDS-D324 — THE LAW GENERALISED, AND IT FOUND LIES NOBODY HAD FILED.** Wave 22's direction predicted
  "the success-claim census will surface lies nobody has filed" and it did, twice over, both invisible
  to any glyph census because neither printed one: `bp export` could not reach ANY server (a bare
  `Accept: application/x-ndjson` against `plug(:accepts, ["json"])` → 406 BEFORE auth; `bp export >
  backup.ndjson` wrote an EMPTY FILE and said "unknown error"), and `barkpark status` decided liveness
  from a `kill -0` on a pidfile while `listener_pid()` sat four lines above. Both directions were
  observed on a real box. The generalisation is the finding: **the checkmark is not the lie — the
  unread post-condition is**, and the verbs a cold owner types first carried the worst ones.
- **PDS-D325 — A BEHAVIORAL REGISTRY BEATS A CLASSIFICATION LINT, AND ITS OWN WEAKNESS IS NAMED.** The
  gate asks one mechanical question per enrolled receipt — *would the printed sentence change if the
  response said the opposite?* — and `TestSuccessClaimRegistryCarriesNoProse` reflects over the entry
  struct so a "classification" field cannot be added. Mutation re-proven by the reviewer, not quoted.
  **What it does NOT prove**: that the response was itself a post-condition read. The A1/A2/A3 class
  judgment still lives in prose in `docs/decisions/success-claim-census.md`, and several enrolled rows
  (`hzDone`, `emitDeviceLoginSuccess`) differ only by an identifier, so they guard "the render reads
  its argument", not the law. The registry is a FLOOR that can only grow, and it should be read as one.
- **PDS-D326 — THE CENSUS CORRECTED THE BRIEF THAT COMMISSIONED IT.** The wave brief asserted shell
  non-proof checkmarks = 0 and `api/lib` `IO.puts` checkmarks = 0 and told the builder to write those
  denominators down. Re-measurement says 2 and 1. The builder shipped the corrected numbers with the
  correction stated, because writing a number measured to be false would have been the slice's own
  success-lie. **The conclusion the brief wanted — no gate on shell or Elixir — survives the correction
  and is argued from the corrected figures.** Re-derive, never quote, applies to the brief too.
- **PDS-D327 — THE 1× BOUND, NOT THE BEST SAMPLE.** The disk-backed import measured 0.01×–1.01× of the
  largest member across runs (OTP 28's extract path sometimes chunks) against 2.01× for the binary
  shape. The claim shipped is **1× the largest member**, never "constant memory" and never the best
  sample, because `:erl_tar` exposes no chunked EXTRACT API and whether a given member is held whole is
  an implementation detail. The number that actually binds on guerrilla is now the ~5.2 GB peak
  TRANSIENT DISK, not the memory figure — which is why the 507 free-space precondition shipped with it.
- **PDS-D328 — EXTRACTION-TO-DISK BUYS A NEW FAILURE CLASS AND IT MUST BE NAMED.** The trade swaps a
  diagnosable BEAM OOM for an ENOSPC. The builder shipped the free-space precondition; the reviewer
  found that the spill loop still crashed on the two shapes that actually happen — a client disconnect
  (`read_body` → `{:error, _}` → FunctionClauseError) and a mid-spill ENOSPC (`:ok = IO.binwrite` →
  MatchError) — both surfacing as an opaque 500. **An opaque 500 is a failure claim as uninformative as
  a false success.** Now `400 import_body_read_failed` and `507 import_spill_write_failed`, each naming
  the reason and the byte count reached. Neither is test-covered (Plug.Test cannot answer `{:error,_}`
  to `read_body`, and the suite does not fill a filesystem) and the commit says so.
- **PDS-D329 — THE OBVIOUS BLOB READ-BACK IS A PROVEN FAKE GREEN, AND THE TEST SUITE NOW HOLDS THE
  TRAP.** Against a black-hole bucket (200 on PUT, stores nothing), `File.stat(Media.file_path(rel))`
  returns the EXACT expected byte count — because `put_file` warm-caches the SOURCE there — and
  `ensure_local/1` also passes with ZERO bucket requests. Both traps are now pinned as assertions in
  one test, and bucket emptiness is re-proven by dropping the cache copy. The honest read is a NEW
  per-backend `stat_blob/1` callback (presigned HEAD for S3). Cost stated: 2 requests per blob, not 1.
- **PDS-D330 — THE EPIC'S OWN EVIDENCE CHAIN HAS AN UNEXPLAINED HOLE.** A `bp task stamp` returned
  ok:true at 5/6 and a later re-read showed that criterion back at `met:false` with EMPTY evidence; a
  second stamp plus a settle held. This is a DIFFERENT clobber from the engagement-lease evaporation
  wave 23 fixed. It was caught ONLY because the builder re-read and COUNTED — which is exactly why that
  proof standard exists. Filed P2 as `pds-bl-stamp-writeback-reverts-a-stamped-criterion`; until it is
  understood, **every "stamped" claim in this epic rests on a write that can silently revert.**

**WHAT THE NEXT WAVE TAKES.** (1) `pds-w23-triage-round`, the moment #6550 merges — it is round 2 by
necessity, not caution. (2) The ~116 open rows on the same standard, and D330 first among them, because
it undermines the standard itself. (3) The three HIGH-FLIP-RISK slices (#6548, #6549, #6552) are owed an
INDEPENDENT second reviewer before merge — this workflow spawns exactly one, so that dispatch is a
manual lead step.

### Wave 24 2026-07-30 — "The Backlog Stops Lying"

Wave 23's debrief named this wave itself: *"`pds-w23-triage-round` is unblocked the moment #6550
merges."* #6550 merged as `a190984df`. So wave 24 IS round 2 — the triage round — but taken as a SPINE
rather than a chore: the epic's no-success-on-an-exit-code law turned one level up, onto the LEDGER the
epic is audited on. Nine verifiers ran; three of the direction's own premises were refuted by
measurement, and one of them was refuted by four independent surveyors against the strategist's own
smoke.

- **PDS-D331 — THE BOARD IS 168 LIVE ROWS IN A 285-NODE CLOSURE, AND THE ONE-LEVEL LENS UNDERCOUNTS BY
  34% WHILE EXITING 0.** Re-derived at 2026-07-30T14:48Z from a PAGED corpus of 4,111 `type:task` docs:
  285 descendants (`open 136 · done 91 · considering 31 · cancelled 26 · blocked 1`), **168 LIVE**, depth
  bottoming at 2. `bp task get … | .children` returns 179 — a ONE-LEVEL read — and 57 live rows hang
  under parents whose own lifecycle is `done` or `cancelled`, invisible to it. The wish's "~135" is the
  OPEN count and is CORRECT; the direction's 110 was the level-1 slice. `blocked` appears in the closure
  and NOWHERE at level 1, so a status enumeration built from `.children` does not know it is a legal
  value. **A census that reads `.children` once scores 63% of the board and greens** — the exact vacuous
  green wave 23 refused to ship.
- **PDS-D332 — PDS-D322 STANDS; THE DIGEST INVERTED IT, AND ACTING ON THE INVERSION WOULD HAVE DEGRADED
  THE BEST ROWS IN THE EPIC.** Three independent verifiers plus this phase's own re-derivation agree: of
  27 live `parked` rows, **19 carry md5 `4f556ba7…` at exactly 644 B, and 8 of those 19 are ALL of the
  direct children.** Every one of the 8 row-specific parks (343–543 B, 8 distinct hashes, each with a
  REACTIVATE) is a BURIED level-2 row. The digest read four buried grandchildren, concluded the direct
  children were "the best rows on the board", and would have pointed builders at repairing the
  exemplars. No descendant was written between the two readings, so this was a MEASUREMENT disagreement,
  not a repair-in-between. **The repair set is the 19 boilerplate rows (8 direct + 11 buried); the 8
  buried row-specific parks are the TEMPLATE and must not be touched.**
- **PDS-D333 — THE BOILERPLATE ASSERTS A FALSEHOOD ABOUT ITSELF, ON 19 OF 19 ROWS, AND RECOVERY NEEDS
  NEITHER psql NOR A NEW ENDPOINT.** Its own text reads *"the original adjudication text is NOT
  recoverable."* Every one of the 19 has exactly one recoverable `content.engagement.note` in the
  DOCUMENT REVISION ARCHIVE, reachable today through `bp doc history` + `bp doc revision`: 120–1058 B,
  16 of 19 already carrying a REACTIVATE, 18 of 19 within the ≤900 B bound, and 16 of them written
  2026-07-27T21:04–21:28Z — roughly one hour BEFORE the boilerplate overwrote them at 22:2x. The epic's
  ledger therefore carries nineteen rows each stating, in a durable field, a thing that is false about
  that same row. **Recovery precedes invention: a restored reason with a revision id beats a fluent new
  one.** Two bounds: `Tasks.Stage` writes via `Repo.update_all` and creates NO Revision, so the "158
  recoverable" figure (measured on `mutation_events`) MUST NOT be quoted through the revision route; and
  `ttl_sweeper`'s promote-only-when-blank rule recovers ZERO here, because the boilerplate already
  occupies the field — the repair must overwrite exactly the `4f556ba7` hash and nothing else.
- **PDS-D334 — THE "PROPAGATION LAG" IS A DRAFT/PUBLISHED ASYMMETRY, NOT EVENTUAL CONSISTENCY, AND THE
  PROOF STANDARD IS SAFE ONLY WITH A NAMED RECIPE.** `bp doc patch` writes the DRAFT row (`_id:
  drafts.<id>`, `_draft: true`). A bare patch then serves the PRE-WRITE value on the published route,
  on `?perspective=drafts` against the BARE id, on `/v1/data/query` and on `bp task get` for a VARIABLE
  5–40 s window (measured 5.5 s in one round, still stale at 30.3 s in another) before a background
  collapse flips them together — so **no fixed sleep is a fix; only publishing is.** Patch THEN publish
  is read-your-write on every perspective at t+1.6 s (1.44 s combined write). The raw read on
  `drafts.<id>` is immediate but 404s once the draft collapses, making it a write-confirmation tool and
  a TRAP as a census primitive. **LAW: publish after every patch, then re-read and COUNT.**
- **PDS-D335 — THE CENSUS RECIPE IS LAW, AND EVERY CLAUSE OF IT WAS EARNED BY A SILENT UNDERCOUNT.**
  (1) PAGE: `/v1/data/query/production/task` silently caps `limit` at 1000 while reporting `total`
  4,111 — one unpaginated read builds a 127-descendant closure and exits 0, a 54% undercount with no
  error. (2) WALK THE TRANSITIVE CLOSURE from `parent_id`, never `.children` (D331). (3) SCORE ON HTTP
  STATUS, never an envelope key: `/v1/data/*` returns `error.code`, `/v1/tasks/*` returns `reason` — a
  census keyed on `error.code` reads every tasks-API failure as a success, and the 429 body
  `{"ok":false,"error":{"code":"rate_limited"}}` is VALID JSON, so a `json.load` success test reads a
  rate-limit as data. (4) SERIAL WITH BACKOFF: a 10-way parallel walk returned 191 of 285 nodes and
  exited 0, caching five rate-limited responses AS DOCUMENTS; `bp` re-fetches `/v1/capabilities` on
  every invocation and 429s against the same budget, surfacing as a config-shaped `BARKPARK_MANIFEST`
  error. (5) NAME THE INSTANT and assert coherence. **A number that exists only in a Paper is a number
  nobody can re-derive: the census is a COMMITTED SCRIPT under `scripts/pds-*` or it did not happen.**
- **PDS-D336 — THE REOPEN-TRIGGER BAR IS "NAMED AND CHECKABLE", NOT "SCRIPT-EVALUABLE", AND THE STRICT
  BAR WOULD HAVE FORCED THE WAVE TO DEGRADE ITS OWN EXEMPLARS.** No trigger anywhere on this board is
  machine-evaluable — the 8 template parks all end *"REACTIVATE: reopen when a crown fire is licensed"*,
  a human licence. The direction's finished-experience bar ("a reopen trigger a script could evaluate")
  fails all 27 parked rows INCLUDING the best 8. Two corollaries. (a) A SHARED FAMILY TRIGGER IS
  LEGITIMATE when the rows share one real blocker — the 8 exemplars carry ONE trigger across EIGHT
  distinct reason hashes, and one licence event then evaluates eight rows at once. **Hash the REASON;
  allow a shared trigger.** (b) A census keyed on the literal string `REACTIVATE` greens on all 27 and
  measures NOTHING, because the boilerplate contains it too. The template that survives is four-part:
  provenance (wave + charter D) / row-specific BLOCKER / **the explicit negative naming what would NOT
  unblock it** / one named REACTIVATE condition. The third part is the non-obvious one.
- **PDS-D337 — PDS-D298's VOCABULARY CLAUSE IS AMENDED: IT IS THE HOLLOWING MECHANISM, AND IT IS THE
  SOLE PRODUCER OF AN UNGOVERNED FIELD.** D298's PARKED clause routes the reason to
  `content.engagement.note`, which **PDS-D306 already overturned** (the engagement lease is swept at 900 s;
  the durable key is `content.disposition_reason`) — D298 has been stale on main since D306 landed. Its
  OPEN clause (*"patch `content.disposition` … and re-publish"*) is worse: `git grep` finds **ZERO code
  writers of `content.disposition` repo-wide**, so the field exists solely because the charter told
  agents to hand-patch it. That is the mechanical explanation for `OPEN 57 / open 47 / parked 27 /
  ABSENT 37` — a vocabulary with no writer has no normaliser by construction, and this is an authoring
  RECIPE defect, not an authoring lapse a guard could ever have caught. **AMENDED: PARKED and OPEN both
  land through a VERB that owns the triple `disposition` + `disposition_reason` + `reopen_trigger`
  atomically; the raw-patch recipe is retired, and the raw door refuses.**
- **PDS-D338 — THE REFUSAL NEEDS TWO INSERTION POINTS, PROVEN BY A PROBE THAT REDS 3 OF 4 ON MAIN.**
  `mutations.ex` already runs its task guards as a PAIR at exactly four clauses (`:177/:178`, `:268/:269`,
  `:312/:313`, `:341/:342`) and a third sibling slots in with no new plumbing, reusing the
  `close_bypass_error/1` 422 template whose message names the sanctioned verb. But the file's own comment
  at `:507` states *"`api/lib/barkpark/tasks/` contains ZERO references to `Content.apply_mutations`"* —
  `Tasks.Stage` persists with a bare `Repo.update_all` inside its own advisory lock. A mutations-only
  guard therefore leaves the SOLE sanctioned reason-writer unguarded, while a stage-only guard cannot
  even SEE a parked disposition: a live probe proved Stage's persisted content keys after a stage are
  `["description","disposition_reason","engagement","kind","lifecycle_status","tags"]` — **no
  `disposition` key at all.** A third bound, inherited and unclosable at this seam: `ensure_*("task",
  nil, …), do: :ok` exempts fresh creates at `:430`/`:542` and the plain `create` clause at `:155` calls
  no guard, so a `createOrReplace` of a hollow park is ACCEPTED today and will stay accepted — that
  residue must be NAMED in the guard's own comment with a pinning test, exactly as `:406-429` already
  does for its sibling. `content.reopen_trigger` exists on ZERO rows and in ZERO files: greenfield in
  both halves.
- **PDS-D339 — `bp task create` IS AN OWNER-FACING LIE, AND IT IS ALSO AN OPERATIONAL CONSTRAINT ON THIS
  WAVE.** Same server, same minute: a **20 MB** generic doc write returns 200 in 0.33 s, while an
  **EMPTY** task create costs 10.3 s and a **2 KB** description 500s. The chain is code-anchored:
  `writer.ex:139` runs `Tasks.Dedup.check_new_task/5` on every task birth → `dedup.ex:136-151` selects
  FULL `content` JSONB for every `type:task` row (`limit 5000`, no draft filter, so drafts and published
  twins both count) over a 4,111-row corpus → `similarity.ex:118-124` recomputes `tokens(new_task)`
  INSIDE the per-candidate loop, making it O(N × |new description|). The request loses a race against a
  15 s DB checkout budget and the owner is handed `{"code":"internal_error","message":"unknown error"}`
  — the catch-all at `errors.ex:578`. Worse, the CLI's 30 s budget ABANDONS requests the server keeps
  executing for up to 61 s. Cost tracks DISTINCT TOKENS, not bytes (realistic prose at 2 KB succeeds
  where nonsense at 2 KB fails). **Until fixed: file rows TERSE (<1 KB), then patch, then publish — a
  patch skips dedup entirely at 0.42 s.**
- **PDS-D340 — THE PIDFILE SHORT-CIRCUIT IS FULLY UNPAID, AND THE STRATEGIST'S OWN PREMISE SMOKE WAS
  WRONG.** The direction recorded *"`start_server` at :151 already calls `listener_pid`, so this may be
  partly paid by #6554."* Four surveyors independently refuted it: `server_running()` is a bare pidfile
  + `kill -0`; `start_server` returns 0 on it at `:147-150`; the `listener_pid` call at `:151` is the
  ELSE branch — the port-conflict guard, reached only AFTER the pidfile check already failed. `git log
  -S` traces the block to `248b94f6e`; #6554 never touched it. So `barkpark up` prints "server already
  running" and exits 0 whenever the pidfile names ANY live pid. **The cheapest fix anchor in the epic is
  fifteen lines below it:** the same file's `status` verb explicitly refuses to trust the pidfile and
  documents this exact failure mode in prose. A file that argues with itself is a fix, not a design.
- **PDS-D341 — `criteria_progress` IS A POISONED HONESTY KEY, AND THE FAKE-DONE HUNT CAME BACK EMPTY.**
  All five wave-22 rows resolve to five DISTINCT merged PRs whose merge commits are ancestors of
  origin/main (#6420/#6421/#6422/#6423/#6426) — ZERO fake-dones. And the five `done` rows at `met==0`
  are the epic's BEST closes: each carries a 615–977 B `close_reason` naming supersession or a fixing
  commit, three of which re-derive by content today. **So a census keyed on `met == 0` manufactures five
  false findings and a census keyed on `met < total` manufactures five more.** The honest predicate is
  `done AND close_reason empty-or-boilerplate`, never criteria arithmetic. Note the field asymmetry a
  census must handle: closed rows carry their adjudication in `close_reason` with `disposition` ABSENT,
  while live rows carry it in `disposition_reason` — two fields, one question.
- **PDS-D342 — THE MERGE GATE IS SPLIT ACROSS TWO VOCABULARIES THAT CANNOT SEE EACH OTHER, WHICH IS WHY
  FIVE SHIPPED CRITERIA ARE STILL UNSTAMPED.** A TEXT convention `"[MERGE-GATED] …"` inside the criterion
  string is read ONLY by the Go CLI, as a REFUSAL tripwire (`tasks_stamp_cmd.go:128`
  `strings.Contains(u,"MERGE-GATED")`). A STRUCTURED marker `"merge_gate" => true` on the criterion map is
  the ONLY thing the Elixir bridge acts on (`close.ex:201`). All five wave-22 rows carry the TEXT and not
  the KEY, and `content.landed` is null on 5/5 — so the CLI refuses to stamp them AND the server can never
  autostamp them. **A classification string standing in for a machine-evaluable marker is exactly what
  wave 23 refused on the Go CLI, found one level up on the ledger.** Fixing the five stamps without
  closing the split guarantees wave 25 re-accumulates them.
- **PDS-D343 — WHAT THE CENSUS FREED FOR NOTHING, AND WHAT IT DID NOT.** Adjudicated BY CONTENT against
  origin/main: `6f4ca7904` (#6553) pays FIVE rows at once — `pds-w23-harness-liveness-and-registry` plus
  the four it names — and the payment is MUTATION-PROVEN, not asserted: `pds-scratch-target_test.sh`
  exits 0 with 32 PASS on main and exits 1 with 21 FAIL against `6f4ca7904^`, naming the exact strand.
  `pds-bl-spill-dir-path-drift` is paid (the only surviving `/tmp/bp-ws-` hits are two docs saying the
  path is NOT `/tmp`); `pds-w20-crown-fire` is MOOT (it arms a crown sealed 12/12);
  `pds-bl-bp-search-false-negative`'s premise is REFUTED (a bare `bp search <noun>` self-routes to
  `query` and returns hits). Two wave-23 carrier rows are stale-open evidence-closes:
  `pds-w23-success-claim-registry` (merged `3885e572a`) and `pds-w23-cold-owner-verb-honesty` at 5/6 with
  only its merge gate unmet (merged `0bff57e4f`). NOT paid, checked and standing:
  `pds-bl-w16-full-meta-permissive-default` (a non-tar body still yields `p=""` and is ACCEPTED, on the
  crown's own greening path), `pds-bl-pid-live-identity-blind`, `pds-bl-deployed-sha-override-unimplemented`
  (`pds-climb-preflight.sh:208` HONOURS `PDS_DEPLOYED_SHA`; `pds-pull-proof.sh` only ADVERTISES it —
  one script implements, the other lies), `pds-bl-scripts-md-budgets-unenforced` (17 `scripts/*.md`
  declare a budget; `check-doc-budgets.sh` has ZERO `scripts/` entries), and
  `pds-bl-bandit-request-line-ceiling` (documented in 6 places, configured in zero Elixir files).
- **PDS-D344 — THE GO SUCCESS-CLAIM REGISTRY IS UNDER-BOUND, PROVEN BY MUTATION, AND ITS WEAKNESS IS A
  LIVE LIE ON SIX VERBS.** The reviewer's published note on #6549 ("`hzDone`, `emitDeviceLoginSuccess`,
  `hzResDone` … are floor, not proof") is now measured. Patch `hzDone` to throw its post-condition
  `extra` away entirely and **both enrolled rows still PASS**; reduce the header to the verb alone and
  they RED. The rows bind `srv.Name`/`srv.ID` and ONLY those — they test the request echo. And that is
  not academic: `runHetznerServerAction` passes `extra = nil` with a PRE-action server that is never
  re-read, so `bp cloud hetzner server reboot web-1` prints the identical receipt whether the machine
  came up or stayed down — **six verbs, class A3, on a product whose promise is fearless reset.** Exactly
  one caller (`create`, `hetzner_cmd.go:827`) passes a genuinely measured status, fifteen hundred lines
  away. Two structural bounds for whoever pays this: `readPackageSources` does `os.ReadDir(".")` and skips
  directories, so **anything under `internal/cli/cloud/` is UNENROLLABLE**; and a `ClaimedField string` is
  illegal by construction (`TestSuccessClaimRegistryCarriesNoProse` permits exactly one string field).
- **PDS-D345 — COVERAGE, HONESTLY.** Every dispatched surveyor and verifier reported; there is no
  coverage deficit. But four verifiers hit a host ENOSPC that killed the Bash tool mid-run, leaving named
  gaps this wave inherits rather than hides: `#6551`'s trim was DESIGNED and PARTIALLY MEASURED, never
  proven green; the untruncated cross-branch collision union was never computed (the fence is a LOWER
  BOUND); `mutation_events` was never probed, so the "158 recoverable" figure is neither confirmed nor
  refuted, only shown not to hold through the revision route. **A gate that cannot run reads as silence,
  not as red** — which is this epic's own founding lie appearing in the wave's own tooling.

**THE WAVE 24 PLAN (8 slices).** Round 1 lands what is built and arms the instrument BEFORE any
adjudication: **S1** ships #6551 (a ≥267 B `docs/api-v1.md` trim — the spine has 3 bytes of headroom and
every owner card is at cap, so relocation is unavailable — plus the two inline `sobelow_skip`
annotations its own `archive.ex:229-231` already models). **S2** commits the census instrument under
`scripts/pds-*` with a MUTATION selftest that reds on a rate-limited fetch, on an unpaginated read and on
a `.children` lens. **S4** ships the two-door refusal + the D337 vocabulary amendment (HIGH-FLIP-RISK).
**S5** renders `disposition_reason` on the Go TUI detail strip — a durable field nothing shows is
write-only, and a write-only adjudication is indistinguishable from none. **S6/S7/S8** are the
owner-facing lies that are simultaneously ledger closes: the pidfile short-circuit, the export residue
(the `chunk/2` MatchError and the missing ndjson Accept branch, both on the BACKUP verb), and the
`bp task create` dedup scan. **S3 is round 2** — the round itself, recovery-then-adjudication over 168
rows, dispatched only after S2's instrument is on main, because a round run on an uncalibrated
instrument is precisely the failure the debate's sharpest attack predicts.

**WHAT THE NEXT WAVE TAKES.** (1) D344's registry rebind and the six-verb `hzDone` re-read — proven RED
today, unfiled until this wave. (2) D342's split merge-gate vocabulary, and the five wave-22 stamps it
strands. (3) D330's stamp write-back revert, still unexplained and still undermining the standard. (4) The
`writes` fail-open (two defects in three rows, latent-zero blast radius — 39/39 in-tree plugin commands
declare the bit, so a widened guard needs a FIXTURE plugin or it greens vacuously). (5) A second
INDEPENDENT reviewer is owed on S4 before merge; this workflow spawns exactly one, so that dispatch is a
manual lead step.

### Wave 24 2026-07-30 — "The Backlog Stops Lying" — REVIEWED. Grade B+ (paper `pds-wave-24-2026-07-30`)

**WHAT LANDED: seven slices, all built, all gate-green on their final branch, ALL PUSHED WITH PRs OPEN.**
That last clause is the one this epic has failed six waves running, and it is stated first on purpose.
`#8130` S1 (docs/api-v1.md wins 275 B back, #6551 unblocked) · `#8131` S2 (the ledger census instrument,
38 mutation fixtures) · `#8132` S4 (hollowness unwritable at both doors + the D298 amendment) · `#8133`
S5 (the Go TUI renders the durable adjudication) · `#8134` S6 (`bin/barkpark` stops trusting the
pidfile) · `#8135` S7 (the backup verb survives a disconnect; x-ndjson stops 406ing pre-auth) · `#8136`
S8 (`bp task create` stops paying a full-backlog dedup scan). Every PR head is the `-r` review branch.

**THE WAVE'S OWN LAW CAUGHT THE WAVE, TWICE, AND BOTH CATCHES WERE CROSS-SLICE.** Neither was visible
from inside a single slice, which is the argument for reviewing the wave rather than the diffs.

1. **The census canon was unreachable by the only door that could write it.** S2 shipped
   `CANONICAL_OPEN = "OPEN"` because the wave brief said so. The brief predates the SAME wave's D337
   verb: `Tasks.Stage` normalises the term with `String.trim/1 + String.downcase/1` against
   `~w(open parked closed)` and, once the raw door refuses, is the ONLY sanctioned writer. So every
   governed row would have counted OFF-VOCABULARY and `--assert-round-done` could never have passed on
   any board, ever — and that predicate IS the gate on round 2 (`pds-w23-triage-round`). Shipping both
   slices as built would have handed wave 25 a gate that cannot go green by construction: the exact
   vacuous green this epic legislates against, one level up. **The writer is the normaliser, so the
   census follows the writer.** Mutation-proven load-bearing (restoring `OPEN` reds 2 of 38).
2. **A dedup OUTAGE was wearing the dedup VETO's tag.** S8 correctly turned dedup's silent fail-OPEN
   into a loud refusal, and spelled it `{:error, {:halted, msg}}` — the plugin-veto tag.
   `Plugins.Github.Intake` already branches on that tag and branches the WRONG way: it logs "lifecycle
   gate refused" and returns a clean 2xx, on the correct reasoning that "GitHub redelivery would only
   hit the same veto forever." That holds for a deterministic veto and INVERTS for a transient DB
   hiccup — so a momentary outage during issue intake would be answered 2xx, GitHub would never
   redeliver, and the issue would be **dropped permanently, logged as a policy refusal that never
   happened, on an unattended path.** Fixed with a distinct internal tag plus an Intake clause that
   5xxs so GitHub redelivers, and a `refute match?({:error, {:halted, _}}, result)` tripwire.

**A THIRD FIX CLOSED A LIE INSIDE THE FIX FOR LIES.** S4's 422 named `bp task stage … --disposition …
--reopen-trigger …` as its retry instruction, and that command did not work: the slice's FILES fence
excluded `tasks_controller.ex` and the `task.stage` manifest entry. Merging the refusal alone would have
shipped a verb lying about its own remedy. Re-derived at review that no other wave-24 slice touches
either file, so the fence's reason had lapsed; the wiring, two real error branches (replacing an
unactionable catch-all 409) and both manifest flags landed on the S4 branch, mutation-proven failable.
`pds-w24-stage-disposition-wiring` is CLOSED with that fixing commit rather than carried.

**WHAT THE REVIEW DECLINED TO DO, ON THE RECORD.** The honest wire answer for a dedup outage is a 503
`dedup_unavailable`. It was built and then backed out: a new public code enters `known_codes/0`, which
`errors_doc_coverage_test` then requires in `docs/api-v1.md` §9 — the file S1 had just rescued to **8
bytes** of headroom (measured: the coverage test failed naming `dedup_unavailable`). Paying for it means
a second branch editing §9 while S1 edits §9. So the wire keeps `halted`/409 exactly as before this
wave — no contract drift, no budget risk — and the upgrade is named for wave 25 rather than smuggled in.
**`docs/api-v1.md` now has 8 B of headroom and no remaining cheap in-place dedup. The next additive
`/v1` error code re-fires this crisis, and that is a standing constraint, not a one-off.**

**WHAT STALLED, honestly.** Nothing stalled on the merits — the one deferred slice, `pds-w23-triage-round`
(the round itself, 168 rows), was NOT built BY DESIGN under the sequenced-rounds law, because a round run
on an uncalibrated instrument is precisely the failure the debate's sharpest attack predicts. It is now
unblocked the moment `#8131` merges. Genuinely unpaid: **no adjudication was written this wave.** The
board still reads `OPEN` 67 / `open` 44 / `parked` 27, and the ~135-row backlog is not one row smaller.
This wave built the instrument, the writer, the refusal and the display; wave 25 owes the adjudication.

**A SLICE-LEVEL GATE WORTH COPYING.** S6's `barkpark-boot-selftest.sh` runs every fixture against BOTH
the working tree and a PINNED pre-fix blob (`0bff57e4f` — not a moving `origin/main`, which would make
every fixture pass on both sides the moment it merges), and FAILS a fixture that passes on both as
non-discriminating. The builder's first harness passed everything, including pre-fix; only the
differential structure exposed it. That is the shape a gate should take when the claim is "this fixes X".

**WHAT THE NEXT WAVE TAKES.** (1) `pds-w23-triage-round` the moment `#8131` merges — the round, with the
census's lowercase canon; expect it to rewrite 67 `OPEN` rows, and note the epic's OWN slice rows still
carry `disposition: "OPEN"` and are in that 67. (2) The 503 `dedup_unavailable` upgrade, WITH the
`docs/api-v1.md` §9 bytes it costs — that byte budget is now the epic's tightest constraint and deserves
a slice of its own (relocation, not compression). (3) D344's registry rebind and the six-verb `hzDone`
re-read, proven RED and still unfiled. (4) D342's split merge-gate vocabulary and the five wave-22 stamps
it strands. (5) The export disconnect signal is still only a LOG LINE — on an unattended personal
instance nobody reads logs, so the owner-facing fix is a client-verifiable document count. (6) **S4 is
owed a genuinely INDEPENDENT second reviewer before merge.** This workflow spawns exactly one; that
dispatch is a manual lead step. The reviewer DID re-derive the two-insertion-point judgment from
`origin/main` source (zero `apply_mutations` under `tasks/`; pre-fix `Stage` persists no `disposition`
key) and both doors are load-bearing — but a re-derivation by the same agent that reviewed the diff is
not independence.

---

## WAVE 25 — THE ROUND ITSELF (decided 2026-07-30)

Wave 24 built the apparatus and wrote ZERO adjudications. Wave 25's spine is `pds-w23-triage-round`:
the round, run against a census that has been taught to measure COVERAGE first. One artifact, and it is
not a PR — `bash scripts/pds-ledger-census.sh --assert-round-done` exits 0.

**BOARD RE-DERIVED AT DECIDE, 2026-07-30T18:19:34Z→18:20:06Z** (`bash scripts/pds-ledger-census.sh
--assert-round-done`, exit 1): corpus 3,821 rows, closure **291**, live **164**; disposition `<unset>`
146 closure / **34 live**, `OPEN` 67, `open` 44, `parked` 27, `in-flight` 7; reasons non-empty 145
collapsing to **127** hashes; off-vocabulary **74**. Two independent verifier walks reproduced this to
the row, and a third measured **ZERO drift** across a 12-minute window (291 closure constant, no row
changed `_rev`/`_updatedAt`). **The "board is moving" premise is REFUTED for the round's write window:**
the last closure write was `lead-merge` at 16:55:00Z sealing wave 24, not a live foreign wave.

- **PDS-D346 — THE CENSUS IS BLIND TO SILENCE, AND CLAUSE 4 SHIPS BEFORE THE ROUND STARTS.** Proven in
  code and by mutation, not inferred: `census()` computes `live` at `:446` and discards it to `len()` at
  `:495`; all four counting loops iterate the WHOLE closure; `--assert-round-done` reads exactly three
  scalars (`:636-639`) and **none is falsified by a row that says nothing** — a blank `disposition`
  contributes to a `<unset>` bucket the predicate never reads, a blank reason is skipped at `:456`, and
  an unset disposition is skipped at `:466`. THE DECISIVE PROOF: a verifier built the fixtures and ran
  them against the UNMODIFIED origin/main census — **five clause-4 red fixtures ALL EXIT 0**, i.e. a
  board where 34 live rows are silent genuinely passes `--assert-round-done` on main today. Separately a
  fixture built from the REAL corpus (uniquify all 145 reasons, normalise all 74 off-vocabulary terms,
  touch nothing else) printed **`VERDICT: ROUND DONE`, exit 0**, with 34 silent live rows and 0/27
  triggers. Running the round to today's instrument would ship the exact vacuous green the instrument
  was built to prevent, INSIDE the instrument built to prevent it. Clause 4 is therefore a WAVE-25
  PREREQUISITE, red on today's board at **34 + 27**, with seven fixtures.
- **PDS-D347 — CLAUSE 4 IS LIVE-SCOPED, STRUCTURED-ONLY, AND ADDED BESIDE CLAUSES 1-3, NEVER RESCOPING
  THEM.** Clauses 1-3 are DISTINCTNESS and VOCABULARY clauses and are correctly closure-scoped —
  boilerplate on a `done` row is still boilerplate. Clause 4 is a COVERAGE clause and is the only one
  whose scope must be live, or it demands adjudicating 127 terminal rows nobody will read. Three
  sub-lines, each able to say no independently: live rows with no disposition; live adjudicated rows
  with no reason; live parked rows with no STRUCTURED `reopen_trigger`. **THE TRIGGER TEST READS
  `row["reopen_trigger"]` ALONE and must NOT inherit `:458`'s `REOPEN_TRIGGER_RE.search(reason) or …`
  OR** — that OR is exactly what PDS-D336(b) condemns, and on the live board it reports **0 structured
  vs 40 prose-only**, i.e. 40 is the size of the lie the single number tells. Scope boundary is PINNED
  by fixture: `TERMBARE`/`TERMPARK` exit 0 (clause 4 never converts terminal rows into work) while
  `TERMDUP` still exits 1 (clauses 1-3 were NOT silently rescoped). `SHAREDTRIG` pins PDS-D336(a): two
  live parks sharing one trigger verbatim over distinct reasons exit 0, so no future wave can "tighten"
  clause 4 into a trigger-distinctness check that would break the board's best eight rows.
  **KEY-PATH SETTLED, FAVOURABLY:** `/v1/data/query` FLATTENS `content.*` to the document top level, so
  the census's top-level read is CORRECT and the 0/27 is a REAL absence — verified two ways (the one
  corpus row carrying a structured trigger returns it top-level with no `content` key; a corpus-wide
  scan of 3,810 rows found 15 reopen-ish keys, all `reopen_note`, zero `reopen_trigger` in the closure).
  `bp task get` is the ONE read path that nests (`.doc.content.<field>`) — the Strategize false negative.
- **PDS-D348 — THE TERMINAL DEAD END IS REAL, IT IS 15 ROWS NOT 14, AND THE FIX IS ONE LINE IN
  `@stageable`.** Both doors proven shut LIVE on a throwaway row: raw `/v1/data/mutate` refuses even a
  pure `OPEN`→`open` case fix (422, guard is `now_term != was_term` at `mutations.ex:707` with no
  rev/case/terminal exemption), and `bp task stage <done-row> done --disposition closed` returns 422
  `illegal_transition` — because `Transitions.legal?("done","done")` is TRUE (same→same) and the AND
  with `@stageable ~w(considering researching open)` at `stage.ex:337` is the ENTIRE refusal. Off-
  vocabulary therefore floors at 15 and `--assert-round-done` is PERMANENTLY UNREACHABLE unless
  something widens that check. **THE WIDENING IS `if (to in @stageable or from == to) and
  Transitions.legal?(from, to)` AND IT BREAKS NOTHING** — mutation-proven both directions (`REFUSED
  {:error, {:illegal_transition, "done", "done"}}` without it; `OK lifecycle="done"
  disposition="closed" claim.closed_by="probe-worker"` with it), with `test/barkpark/tasks/` at 471
  tests 0 failures before AND after, the manifest/gate/controller trio at 147/0 before and after, and
  the FULL suite at 27 doctests / 13,159 tests / **2 failures identical on both sides** (both
  pre-existing: `ProjectorWorkerEnqueueTest`, `Studio.ChatRenderGoldenTest`). The three refusal fixtures
  at `stage_test.exs:254/:269/:278` are all `from="open"` and ALL survive — a non-done row can still
  never reach `done`. `do_stage` never touches `content.claim`, so close attribution is preserved.
  **THE STOPGAP IS REFUSED ON THE RECORD:** `stage <done-row> open --disposition closed` works (live
  200, 7/8 fields, claim intact) but flips 15 finished rows into `live` and into `bp task ready`, and
  produces rows saying `open` while carrying `claim.closed_by` — trading an off-vocabulary lie for a
  LIFECYCLE lie, the top of this wish's build list. A census EXEMPTION for terminal rows is refused too:
  it reaches exit 0 by not looking.
- **PDS-D349 — TRUTH-IN-REFUSAL RIDES WITH THE WIDENING OR THE GUARD STARTS LYING ABOUT ITSELF.**
  `tasks_controller.ex:658` tells every refused caller "stage moves only between
  considering|researching|open", which becomes FALSE the moment the widening lands, and the capability
  manifest enumerates the reopen edges but not the terminal same→same adjudication edge. In an epic
  about verbs that lie, shipping the widening without both text fixes ships a new lie. Constraint:
  `stage_test.exs:255` asserts the literal substring `considering|researching|open`, so a message
  rewrite must preserve it or update the assertion in the SAME commit. The widening needs the API
  deploy ONLY — no `bp` rebuild (proven: `bp task stage <id> done` reached the server and returned the
  server's 422, so the CLI does not client-side validate the state enum).
- **PDS-D350 — PDS-D336 GOVERNS THE TRIGGER BAR; THE WISH'S "SCRIPT-EVALUABLE" PHRASING IS OVERTURNED BY
  NAME, AND THE 8 EXEMPLARS ARE MADE COMPLIANT ADDITIVELY, NOT REWRITTEN.** D336 already ruled the bar
  is "NAMED AND CHECKABLE, NOT script-evaluable" and recorded that the strict bar fails all 27 parked
  rows INCLUDING the best 8. Clause 4 implements D336 exactly: it checks the trigger is NAMED IN A
  DEDICATED FIELD and never inspects its text. **This dissolves a self-contradiction inside
  `pds-w23-triage-round` itself** — its criterion 8 demands every parked row carry a trigger while its
  criterion 5 demands the 8 exemplars be shown UNCHANGED, and `stage.ex:380-391` accepts a carried
  trigger only from `content.reopen_trigger` (an in-reason `REACTIVATE:` does NOT satisfy it) while
  `do_stage` writes the triple in ONE CAS. THE ESCAPE HATCH IS LEGAL AND MUST BE NAMED IN THE BRIEF:
  `mutations.ex:713` refuses only `trigger_erased?`, so ADDING `content.reopen_trigger` through the raw
  door is permitted, and D298 already calls it "the sanctioned remediation for rows parked hollow before
  this fence". The 8 exemplars get their EXISTING `REACTIVATE:` clause copied VERBATIM into
  `reopen_trigger`; "do not touch" is defined as **`md5(disposition_reason)` identical before and after,
  proven per row**. D332's "343-543 B" is CHARACTERS; in BYTES the family is 345-549 B (em-dashes) —
  any length bound must name its unit.
- **PDS-D351 — RECOVERY IS 16 RESTORATIONS + 3 ENRICHMENTS, AND THE BOILERPLATE'S OWN TEXT IS THE
  NINETEENTH LIE.** All 19 rows sharing md5 `4f556ba7` have a recoverable, row-specific
  `content.engagement.note` in the revision archive via `bp doc history` + `bp doc revision` — 19/19
  distinct by md5, no psql. TWO INHERITED PREMISES CORRECTED: (a) the boilerplate lives in
  `disposition_reason` at **646 B** and the live rows carry NO `engagement` field at all, so the write
  is CROSS-FIELD (archived `engagement.note` → live `disposition_reason`), and a builder hunting a live
  `engagement.note` to overwrite will find nothing; (b) the yield is TWO STRATA — 16 rich notes
  (485-1062 B, all 2026-07-27 19:40-21:28Z, all carrying `REACTIVATE`, 15/16 carrying an explicit
  negative) and 3 pre-template stubs (120-137 B, 2026-07-22) that need enrichment on top of recovery.
  Strategize's "822 B at 8f7ca193" is **828 B**. **THE BOILERPLATE ASSERTS "the original adjudication
  text is NOT recoverable" — FALSE 19 OF 19, an owner-facing lie on nineteen ledger rows.** The 19 are
  fully disjoint from the 15 terminal rows (zero terminal members) and from the 8 exemplars.
  OPERATIONAL: `/v1/data/revision` rate-limits hard — a 6×8 fan-out produced 66×429 + 39×500 out of
  ~600 fetches while serial-with-0.15s-sleep produced zero errors, and **a missed note reads exactly
  like "no note in the archive"**, so the recovery script must fail LOUDLY on 429, never skip.
- **PDS-D352 — DISJOINTNESS IS A PLAN-TIME PINNED MANIFEST OR IT IS NOTHING, AND THE PACING IS 0.75
  WRITES/SEC.** `Tasks.Stage` takes a BLOCKING `pg_advisory_xact_lock` and re-reads `observed_rev`
  INSIDE the lock (`stage.ex:289/:405/:422`), so the CAS can essentially never lose: two builders both
  get **200** and the second SILENTLY OVERWRITES the first — corroborated by 20 same→same stages
  against one row, every one 200. The controller accepts no `observed_rev`/`If-Match` (contrast `stamp`,
  which requires `observed_epoch`). There is nothing to catch at write time. The round therefore flies
  off `tooling/grip/ledger/pds-w25-board-manifest-2026-07-30.tsv` — 179 rows, `class<TAB>doc_id`,
  pairwise-disjoint (`cut -f2 | sort | uniq -d` → 0 lines), union of the three live classes == the live
  set exactly (164 == 164). **No shard may re-derive its own row set from a live query.** PACING,
  MEASURED not assumed: the write bucket is capacity 60 / refill 1.0 per second keyed
  `token:<hash>:<class>:<dataset||"global">`, an 80-way burst returned exactly 63×200 / 17×429, and
  `/v1/tasks/:id/stage` carries NO `:dataset` param so it bills the **"global"** bucket, disjoint from
  `/v1/data/mutate/production` (proven live: 5 stage POSTs routed while a 150-way production burst was
  returning 135×429). One `bp task stage` = 2 HTTP requests (a 304 capabilities GET + the POST); pinning
  `BARKPARK_MANIFEST` collapses it to ONE and raises throughput from 0.46 to 3.23 writes/s. **RULE: pin
  the manifest, at most 3 concurrent shards, `sleep 4` after every stage call → 0.75 w/s aggregate,
  ~240s for 165 rows, the 60-token reserve never touched and 0.25 w/s left for foreign workers who share
  this same admin token.** A 429 on `/v1/capabilities` is rendered by `bp` as "acquire manifest …
  unexpected status 429" — it reads exactly like a broken install and MUST be treated as backpressure.
  Also: `--note` rides the QUERY STRING; 9,000 B is 200, 10,000 B is 414, and `bp` renders the failure
  as an opaque `stream error: … INTERNAL_ERROR`.
- **PDS-D353 — THE RE-READ LAW IS NECESSARY BUT HISTORICALLY INSUFFICIENT, AND THE FREE CLOSES ARE
  EIGHT, NOT THREE.** Wave 22 lost **2 rows AFTER they had been individually verified present** (the
  `TtlSweeper` ate wave 10's notes at a measured 15m00.97s; PDS-D309 refutes PDS-D298's factual verdict
  while reaffirming its proof standard). The split shipped, so today's target keys are unswept — but a
  sampled DELAYED re-read is owed on top of the immediate one. Separately, the `Retires:` trailer
  convention is **exactly ONE commit repo-wide** (`6f4ca7904`) and is not a mine to work: free closes
  come from SLUG GREP + CONTENT, and a sweep of the 34 bare rows yielded **8 CLOSED verified by content
  on origin/main**, 5-6 PARKS whose reason is already written in code or in the row, and 16 OPEN whose
  fix is demonstrably absent. **THE SHARPEST FINDING IS OUTSIDE THE BARE SET:**
  `pds-bl-scratch-pointer-concurrency` and `pds-bl-scratch-pointer-explicit-default` carry
  `disposition: open` with 570/560-byte reasons that `6f4ca7904` made FALSE three days ago — and a naive
  re-check of their own citation (`pds-scratch-target.sh:124`, where the legacy `POINTER_FILE` survives
  as a hint) would wrongly conclude "still broken". **So "carries a disposition" ≠ "carries a TRUE
  disposition": the open-normalise shard needs a CONTENT re-check clause, not just a case normaliser, or
  it launders stale reasons into freshly-normalised stale reasons.**
- **PDS-D354 — `disposition_owner` IS NOT AN EMPTY FIELD; 30 OF 103 OPEN ROWS ARE SELF-OWNED AND THE
  CENSUS READS THE FIELD ZERO TIMES.** 0 of 103 live-open rows have an unset owner, so S-open is not
  "invent semantics" — it is "adjudicate 30 owners that name nobody and unify four incompatible value
  shapes". The split maps exactly onto the case split: all **44** lowercase `open` rows carry a ROLE
  slug (the exemplar); the **59** uppercase `OPEN` rows split **30 SELF-OWNED (`disposition_owner` ==
  the row's own `_id`)**, 23 pointing at ANOTHER task id (a subsumption claim, not an owner), 6 role
  strings. A non-empty check greens on 30 rows that name nobody. `disposition_owner` has **ZERO code
  writers repo-wide** — `stage.ex` owns only `disposition`/`disposition_reason`/`reopen_trigger` — so
  there is no normaliser and `Wave 25`, `wave-25` and `truth-grip-epic lead (wave-10 steward)` are three
  different owners forever. **RATIFIED SHAPE: a lowercase kebab role slug — `pds-<thing>-maintainer
  |steward|owner`, `lead-pds`, or `wave-N`. OWNER == SELF IS BANNED. The 23 task-id pointers move to
  `disposition_reason` prose ("subsumed by <id>") and inherit the POINTED-AT row's owner**, which turns
  23 decisions into 23 lookups and leaves 30 genuine judgments.
- **PDS-D355 — D344 IS WRONG ABOUT ITS OWN COUNT (NINE VERBS, FIVE POST-CONDITION SHAPES) AND ITS
  REGISTRY ROW IS VACUOUSLY GREEN.** `grep -c runHetznerServerAction` on origin/main returns **9**, not
  six: `poweron poweroff reboot reset shutdown disable-rescue enable-backup disable-backup detach-iso`.
  A slice scoped to D344's number ships three unfixed lies, so **the verb list comes from the grep at
  build time, never from the charter prose**. THE MUTATION PROOF: deleting hzDone's `extra` handling
  ENTIRELY — so the receipt can carry no post-condition at all — leaves
  `TestSuccessClaimsChangeWhenTheResponseDoes/hzDone` **PASSING**, while five unrelated tests catch it.
  The row's pair differs only by `ID`/`Name` and hand-injects `extra={"status":"running"}` that **no
  action verb ever passes** (`runHetznerServerAction:892` passes `nil`). The registry must be repaired
  in the SAME commit — vary the pair on the POST-CONDITION holding identity fixed — or the ledger close
  is stamped by a check that structurally could not fail. FIVE SHAPES, not one predicate: (A) start →
  `running`, bounded poll; (B) hard stop → `off`, bounded poll; (C) **`reboot`/`reset` have NO
  DISCRIMINATOR** — `hcloud.Server` carries no boot-time/uptime field, pre-state and post-state are both
  `running`, so **the SENTENCE must be NARROWED ("the reboot action completed and the server is
  running"), never strengthened**; (D) **`shutdown` is ACPI and MANDATES a bounded poll** — the official
  Hetzner CLI polls to `off` against a 30s timeout and without `--wait` prints only "Sent shutdown
  signal", so a single `GetByID` would FALSE-RED a healthy shutdown; (E) metadata flips read
  `RescueEnabled`/`BackupWindow`/`ISO`. `runHetznerServerCreate:807-827` is the in-file precedent
  ("Actions done ≠ booted"), so this is a PORT, not an invention. HAZARD TO STATE OUT LOUD: every
  post-condition read is a NEW failure mode on a verb that previously could not fail there — a
  rate-limited `GetByID` after a successful reboot must not report the reboot as failed. **UNFILED
  SIBLING, LARGER THAN THE ONE BEING FIXED: `hzResDone` has 50 production callers, 13 passing
  `extra=nil`, and an identity-only registry row PINNED in `requiredEnrollments` — a second instance of
  this wave's theme, filed to the backlog rather than smuggled in.**
- **PDS-D356 — S7 IS "THE EXPORT ARTIFACT IS SELF-VERIFIABLE", NOT "BUILD A RECEIPT"; TRAILERS ARE
  IMPOSSIBLE AND A BODY RECEIPT LINE IS REFUSED.** `grep -rn trailer api/deps/plug/lib/` returns **0
  lines**; `Plug.Conn` exports zero trailer functions, `Plug.Conn.Adapter` declares zero trailer
  callbacks, `Bandit.Adapter` exports zero — Bandit mentions trailers only REQUEST-side, to discard
  them. The design space is FORCED. A terminal receipt LINE is refused because three line-oriented
  consumers break: `export_cmd.go:73-79` prints every line verbatim into `backup.ndjson` AND increments
  the count; `js/packages/core/src/export.ts` does a bare `JSON.parse(line) as BarkparkDocument` with no
  shape check, so a receipt object is yielded to callers AS A DOCUMENT; and three docs publish "one
  document per line". **The wish's premise is HALF WRONG and must not be re-litigated: `bp export`
  ALREADY ships an owner receipt — non-zero exit plus `"<path> is PARTIAL, do not restore from it"` plus
  a count — test-pinned by `TestRunExportTruncatedStreamIsPartialAndNonZero`.** The genuine holes are
  (a) the HTTP layer, where `send_chunked(200)` commits the status before byte one and the only signal
  is a `Logger.warning` that fires ONLY on client hangup, and (b) **artifact non-durability** — `bp
  export > backup.ndjson` puts the count on stderr, so a cron box keeps a partial file BYTE-
  INDISTINGUISHABLE from a complete one. S7 ships a SIDECAR (`FILE.meta` with
  `{documents,bytes,sha256,scope,completed_at}` written only on clean completion, plus `--verify`),
  copying `internal/backup/backup.go`'s proven pattern and `scripts/pds-pull-proof.sh:1232-1245`'s
  precedent — **and it must FAIL CLOSED on a missing sidecar**, unlike that precedent's
  `""|full) return 0`. Zero body-shape change, so every existing consumer keeps working.
- **PDS-D357 — D342's MERGE-GATE SPLIT HAS NO CHOKEPOINT AND IS CUT FROM WAVE 25.** The premise "one
  normaliser at one chokepoint" is REFUTED: **four** independent writers reach
  `content.acceptance_criteria` (`Writer.create_document`, `Writer.upsert_document`,
  `Stamp.apply_stamp_update` via `Repo.update_all`, and the `Close` body / `reconcile_merge_gate`), the
  last two bypassing `:before_save` entirely — and a `before_save` hook is CONTRACTUALLY NON-MUTATING
  ("no mutation (Q2)"; a non-`:ok` return is logged and treated as `:ok`), so the obvious home cannot
  host a normaliser. The blast radius is not ~5 rows: **562 tasks carry a MERGE-GATED criterion across
  563 gated rows and only 9 carry the machine key**, spanning every epic that used the convention, and
  `bp search` under-reports it (hard cap at 500). `merge_gate` is not even a declared schema field.
  24 `done` + 5 `cancelled` rows carry an unmet gated criterion (not 5), and **8 of the 24 carry a
  SECOND, NON-GATED unmet criterion — a builder told to "stamp the merge gate" fabricates eight dones**.
  `bp task stamp` is REFUSED on a `done` row (`not_in_progress:done`, `_rev` unchanged, proven live), so
  the backfill cannot be a stamp. Filed to the backlog with this finding attached, at its true size.
- **PDS-D358 — THE `docs/api-v1.md` RELOCATION IS REAL, IS 947 BYTES, AND CARRIES A HIDDEN CI BREAK BOTH
  DOC GATES ARE BLIND TO — SO IT IS NOT A DOCS-ONLY SLICE.** The inherited "it duplicates
  `docs/cli/error-exit-table.md`" premise is WRONG: the two backticked lists overlap on **4 of 39**
  codes and 35 endpoint-specific codes are documented NOWHERE ELSE, so deletion+pointer would destroy
  documentation — the honest move is RELOCATION, exactly as this charter already ruled. Measured:
  `docs/api-v1.md` is **13,998 B of 14,000** on origin/main (the charter's "8 bytes" is stale); moving
  line 171 (1,093 B) to a new capped `docs/api/error-codes.md` and leaving a 140 B markdown-LINK pointer
  frees **947 B** with both gates green, and the dedup row's two real doc lines measure **390 B** —
  covered with 559 B to spare. All four anti-laundering invariants proved BY MUTATION (cap reds at +100
  B; stripped G1 header reds; colliding `canonical-for` reds; a dangling pointer reds — and the pointer
  must be a markdown LINK, since §3c never resolves inline backticks). **THE BREAK:**
  `errors_doc_coverage_test.exs:25` pins the doc BY PATH and slices §9 BY HEADING; after the move
  **39 of 70 `known_codes/0` members vanish from §9 and the `known_codes` sentinel goes with the moved
  paragraph** — the slice ships GREEN on `check-doc-budgets.sh` and `docs-anchors-check.sh` and RED on
  the Elixir suite. The slice is relocation + the test amendment (read §9 ∪ the new doc) + the dedup
  row's lines, in ONE PR, Elixir-gated. Filed to the backlog, fully specified, for the next wave.

**THE WAVE-25 PLAN.** Round 1, eight slices, three of them LEDGER-ONLY (no repo files, no PR — the
`cch` wave-7 shape, with THE TREE WINS on any disagreement between a pre-written disposition and
origin/main): `pds-w25-census-clause-4` (the gate), `pds-w25-stage-terminal-widening` (the code
prerequisite for round 2), `pds-w25-round-parked` (19 recoveries + 8 additive triggers),
`pds-w25-round-open` (103 rows, case + owner + content re-check), `pds-w25-round-bare` (34 rows, 8 free
closes verified by content), `pds-w25-hetzner-nine-verb-receipt`, `pds-w25-export-sidecar`. Round 2:
`pds-w25-round-terminal` (15 rows) dispatches only AFTER the widening MERGES **and DEPLOYS** to
guerrilla — no `bp` rebuild needed, but the API deploy is a hard gate.

**COVERAGE HONESTY, ON THE RECORD.** Every dispatched surveyor and verifier reported; there is no
coverage deficit. What nobody did: no verifier opened any wave Paper; `js/` and `web/` were never
grepped for export consumers by the survey (the verify round closed that — zero source consumers, all
`web/` hits are `.next` build artefacts); `hzResDone` was sized only at verify and is filed, not fixed;
and the terminal-verb lane did NOT read this charter for a prior ruling on terminal adjudication (this
decision is that ruling). The wave-25 charter reaches main as a docs-only PR, so the WAVE PAPER
`pds-wave-25-2026-07-30` carries these decisions IN FULL for any builder flying before it merges.

### Wave 25 2026-07-30 — "The Round, and the Fixes Are the Round" — REVIEWED. Grade A− (paper `pds-wave-25-2026-07-30`)

**THE ROUND RAN. That is the headline, and it is the debt wave 24 left.** Wave 24 was graded B+ because
it built the apparatus for a triage round and wrote ZERO adjudications — "the backlog is exactly as long
and exactly as untruthful as at Strategize." Wave 25 was chartered to make the round itself the spine,
and the round is done. **The reviewer re-derived every shard independently from the pinned manifest off
the charter branch rather than trusting a single shard report**, and the numbers hold:

| Shard class | Pinned | Counted OK | Failing |
|---|---|---|---|
| `parked` | 27 | **27** | 0 |
| `open-normalise` | 103 | **103** | 0 |
| `bare` | 34 | **33** | 1 (the honestly-handed-off blocked row) |
| `terminal-with-disposition` | 15 | 0 | 15 — **deferred round 2, by design** |

The live census agrees: `--assert-round-done` now reads `live adjudicated rows carrying a reason
155/155 PASS` and `live parked rows carrying a reopen_trigger 29/29 PASS`, against 178 non-empty reasons
and **178 distinct reason hashes** — no two rows share a reason. At Strategize those same lines read
34 silent, 27 untriggered, 74 off-vocabulary.

**RECOVERY BEAT INVENTION, AND IT WAS MEASURED.** All 19 boilerplate parks had their row-specific
`engagement.note` mined out of the revision archive through `bp doc history` + `bp doc revision`, serial
and fail-loud on 429 — 19 of 19 recovered, 19 distinct by md5, zero 429s and zero 500s across the mine,
so no note was silently missed and read as "absent". 16 were pure restorations; 3 pre-template stubs were
enriched ON TOP of their archived sentence with a provenance line saying so outright. **The boilerplate's
own claim that "the original adjudication text is NOT recoverable" was FALSE 19 of 19 and now appears on
ZERO rows.** The 8 buried exemplar parks were left byte-identical — their `reopen_trigger` was added
ADDITIVELY through the raw `/v1/data/mutate` door precisely because `do_stage` rewrites the whole triple
in one CAS, and `md5(disposition_reason)` is proven identical before and after on all 8.

**THE 13 FREE CLOSES ARE THE PART THAT SHRANK THE BOARD, and they were earned by reading the tree, not
by replaying citations.** Two were traps pointing in opposite directions: the scratch-pointer pair's own
cited line still holds a legacy `POINTER_FILE` and reads "still broken" (a citation-follower would have
kept it open), while `pds-bl-close-holder-and-criteria-gate`'s cited `check_fencing` still has no worker
comparison — the fix is a SEPARATE `check_close_holder` guard in the same chain (a citation-follower
would have kept it open too). 103 open rows became 90 open + 13 closed.

**WHAT LANDED IN THE TREE (four slices, all gates re-run green by the reviewer, all file-disjoint):**

- `pds-w25-census-clause-4` → **PR #8217**, branch `…tha-0-r`. Clause 4 sits BESIDE the untouched
  closure-scoped clauses 1-3 and is the only LIVE-scoped one, with three independently-failing
  sub-lines. `structured_trigger(row)` reads `row['reopen_trigger']` and NOTHING else — the old
  `REOPEN_TRIGGER_RE … or …` is gone and the regex is quarantined to a DISPLAY counter that is split,
  never summed (`0 structured` beside `40 prose-only DECORATION` on the day's board; a summed counter
  would have read 40 and called it coverage). Selftest 38 → 54 checks. **Removes the `reopen_triggers`
  `--json` key** in favour of two split keys — a repo-wide grep finds no other consumer.
- `pds-w25-stage-terminal-widening` → **PR #8218**, branch `…withou-1-r`. One logic line:
  `(to in @stageable or from == to) and Transitions.legal?(from, to)`. **HIGH-FLIP-RISK, and the
  reviewer re-derived it independently rather than re-reading the builder's argument**: `from` comes
  from `current_status/1` reading the row fetched inside `pg_advisory_xact_lock`, no controller
  parameter reaches it, `legal?/2` requires `from in @statuses` on the same→same branch, and
  `do_stage/7`'s write set provably excludes `content.claim`. `any → done` and `any → in_progress`
  stay refused. **A genuinely independent SECOND reviewer is still owed before merge.**
- `pds-w25-hetzner-nine-verb-receipt` → **PR #8219**, branch `…claimi-5-r`. **The verb list was DERIVED
  and it is NINE, not the SIX in PDS-D344** — a slice scoped to the charter's number would have shipped
  three unfixed lies, and `hzActionVerbsFromSource` re-does that parse at test time so a tenth verb
  fails instead of shipping. Reviewer's independent mutation (revert to `hzDone(out, verb, srv, nil)`)
  turns **15 assertions RED across 7 tests**, including the literal *"reboot printed BYTE-IDENTICAL
  output whether the machine came up or stayed down"*. Shape C is honest mitigation, not a fix: reboot
  still cannot prove a restart, because nothing in the API can.
- `pds-w25-export-sidecar` → **PR #8220**, branch `…completenes-6-r`. `--out` writes `FILE.meta` only
  after a clean completion, and clears a stale sidecar BEFORE the first byte, so **absence is the
  truncation signal**. `--verify` fails closed on four shapes — reviewer's independent mutation into
  the permissive `scripts/pds-pull-proof.sh` shape reds `TestRunExportVerifyRefusesMissingSidecar`.
  Zero body-shape change.

**WHAT STALLED, HONESTLY.**

- **`pds-w25-round-bare` is 33 of 34, not 34.** `pds-w12-crown-climb-preconditions` is lifecycle
  `blocked` and has NO in-place door: the shard probed BOTH live and got `illegal_transition: cannot
  stage blocked -> blocked` from the verb and `validation_failed` from the raw door. `blocked → open`
  WAS available and was **deliberately refused** — that is the forbidden stopgap. It was handed to
  `pds-w25-round-terminal` with `disposition_owner` set and no fabricated term. This is the correct
  outcome and the task says so at 5/8 criteria.
- **`pds-w25-round-terminal` (15 rows) was not built — round 2, by design**, gated on the widening
  MERGING *and DEPLOYING*. Those 15 rows ARE the census's entire remaining off-vocabulary floor
  (8 × `OPEN`, 7 × `in-flight`), so the epic's done-condition cannot green until the deploy happens.
- **The wave's own three ledger shards cannot be adjudicated in place today.** They sit
  `in_progress`, and `in_progress → in_progress` is precisely the edge PR #8218 opens. The reviewer set
  their `disposition_owner` (unfenced) and left the disposition for after the deploy rather than
  resurrect them to `open`. **The wave demonstrated its own thesis on itself.**
- **Guerrilla was intermittently 500ing under wave load.** Two builders could not file follow-up tasks
  at all (7 attempts, `/v1/data/mutate` alternating 500 and client timeout, `/v1/capabilities` itself
  500ing) while `/v1/tasks` stamp+pulse kept working. Filed as `pds-bl-census-read-path-500-under-load`.
- **A stamp write of ~1.1 kB returned exit 0 with a normal envelope and DID NOT LAND** — read-back
  showed `met:false, evidence:""`. A shorter re-issue landed. **That is a verb saying it did something
  it did not do, inside the ledger writer itself** — the exact class this wave hunts, and it is
  UNFILED because the create path was 500ing. It is the single most on-theme finding of the wave.

**WHAT THE NEXT WAVE MUST TAKE.** (1) Merge #8218 and **watch it deploy to guerrilla**, then dispatch
`pds-w25-round-terminal` — it is fully specified and it is the last 15 rows under the off-vocabulary
clause. (2) File and fix the silent stamp non-land; a ledger writer that drops a write is worse than
any receipt this wave repaired. (3) **Clause 4(a) can never green while a wave files residue** — every
newly-filed row is born bare, and 19 of the 19 remaining bare rows are this wave's own residue. Either
the round's close must adjudicate its own residue, or 4(a) needs a birth-grace rule; deciding which is
a charter question, not a builder question. (4) `resize`, `attach-iso`, `rebuild` and `hzResDone` carry
the same receipt lie one function away from the fix that just landed.

### Wave 26 2026-07-31 — "The Verbs That Still Lie, and the Writer That Lies About Writing" — REVIEWED. Grade A− (paper `pds-wave-26-2026-07-30`)

**7 of 7 round-1 slices built, gated and PUSHED WITH PRs.** No stalls, no deferred slices, no
unpushed branches. Every slice's gate was re-run green on the branch the lead will merge.

| task | final branch | verdict |
|---|---|---|
| `pds-w26-stamp-readback` | `…store-say-0-r` | THE SPINE. `bp task stamp` now POSTs → GETs → renders the verdict from the store. Reviewer fixed the receipt's unit label (`chars` → `bytes`) and a comment claiming a perspective the route never sends. |
| `pds-w26-stamp-exit-taxonomy` | `…command-line-you--1` (unchanged) | 5/6 split shipped exactly as PDS-D371 ruled, compound-prefix `lookupExit` shared by all three lookup sites. Cleanest slice of the wave. |
| `pds-w26-publish-door-criteria-fence` | `…landed-s-2-r` | Criteria fence + the two `inserted_at` census pins. Reviewer re-derived the coverage independently and CORRECTED the shipped comment. |
| `pds-w26-hetzner-five-flag-verbs` | `…stop-reporti-3-r` | Four flag verbs read back. Reviewer flipped `poll:true` on rebuild and resize. |
| `pds-w26-census-anchor-4a` | `…the-round-i-4-r` | `--anchor-from-paper` + argv gate. Reviewer fixed 4(a)'s NUMERATOR. |
| `pds-w26-export-atomic-out` | `…the-backu-5` (unchanged) | `.partial` + ordered promote, `:161` moved in the same commit. |
| `pds-w26-workspace-export-declared-size` | `…verifies-t-6` (unchanged) | Declared-size check with the mandatory permanent `-1` branch. |

**THE ONE FINDING THAT IS NOT IN ANY SLICE.** `pds-w26-census-anchor-4a` shipped clause 4(a)'s
predicate line computing its numerator as `live - len(bare)`, where `bare` is the ANCHORED subset —
so **every residue row was counted as carrying a disposition.** On the live board that prints
`172/172 PASS` over 15 rows nobody adjudicated. **The epic's own certifying instrument was emitting
the exact class of success claim the epic exists to kill**, in the same wave that turned the law onto
the ledger writer. Fixed at review, mutation-proven (restoring the old numerator reds the selftest,
79 → 80 checks). The denominator is unchanged and still the whole live board. **Nobody should read
that as a builder failure — it is what a review is for, and it is the single best argument in this
epic's history for the reviewer phase existing at all.**

**THE COVERAGE CORRECTION ON THE PUBLISH DOOR.** The fence's shipped comment named
`Barkpark.Plugins.GitHub.Link.put/4` as an UNCOVERED automatic publisher. It is not. Link.put and
Adopt both thread `source: :github`, and the wholesale exemption keys on `:sync` ONLY — so both fall
through the gate and the criteria fence DOES apply to them. That is the right direction and it is
safe: `collapse_draft_twin/5` already logs a rejected collapse, leaves the draft twin and still
returns `{:ok, _}`, so a fence refusal defers bookkeeping rather than breaking the mirror job.
Independently re-derived at review and corrected in the shipped comment. `source: :sync` remains
genuinely uncovered and genuinely filed.

**CROSS-SLICE PROOF, not assumed.** Five of the seven slices land in `internal/cli`. All five were
merged onto one integration branch off `origin/main` and `CC=clang go test ./...` ran green across
every package — so the lead can merge them in any order without a compose surprise.

**HIGH-FLIP-RISK, A SECOND INDEPENDENT HUMAN REVIEWER IS STILL OWED** on both flagged slices.
For `pds-w26-census-anchor-4a` the residual is exact and unresolved: **the argv gate stops a raw
timestamp, but nothing binds the anchor SLUG to the round being certified** — `--anchor-from-paper
pds-wave-20-…` would defer three waves of rows and green. Binding the anchor to the epic task's own
`wave_paper` field rather than to argv is the obvious next ruling.

**WHAT THE NEXT WAVE SHOULD TAKE.** (1) `pds-w26-close-pulse-readback` — `bp task close` is the
SEAL and carries the identical exposure the stamp just closed; wave 26 fenced it away deliberately.
(2) `pds-w26-mcp-stamp-bypasses-readback` (filed at review) — `mcp_tasks.go` calls
`execManifestCommand` directly and never enters `runTaskStamp`, so an MCP-issued stamp gets NO
read-back; the caller class most likely to be an agent writing this epic's evidence is the one class
the new law does not reach. (3) Bind the census anchor to `wave_paper`. (4) `hzResDone` — PDS-D367's
51-caller class, still a wave-sized slice. (5) `pds-w25-round-terminal` the moment #8218 is DEPLOYED
(still not merged-equals-deployed; still the human's call).

## WAVE 26 — THE LAW TURNS INWARD (decided 2026-07-31)

**THE THESIS.** Twenty-five waves taught `bp` verbs to re-read the WORLD — a Hetzner box, a deployed
site, a written bundle. The class this epic had never audited is `bp` writing to its OWN LEDGER: the
writes every piece of this epic's evidence is made of. **A BARKPARK VERB MAY NOT CLAIM A WRITE IT
CANNOT SEE IN THE STORE.** The wave's spine survives the verify round; its stated premise does not.

- **PDS-D359 — THE STAMP "SILENT NON-LAND" HAS NO SIZE BOUNDARY AND NO SILENT REFUSAL. BOTH REPORTED
  MODES TRACE TO A MASKING SHELL PIPELINE, AND THE HYPOTHESIS "AN UNBOUNDED EVIDENCE FIELD MEETING AN
  UNDECLARED LIMIT" IS DEAD.** A live bisection on guerrilla persisted evidence BYTE-EXACT at
  100/500/900/1000/**1100**/1200/1500/2000/4000/8000/9000 bytes and failed HONESTLY (rc=1, named error)
  from 10000 up — a query-string transport ceiling, independently corroborated by `spd-b47`'s
  8900-OK / 9002-FAIL bisection filed two waves earlier. A non-holder stamp exits **2** with a named
  `not_holder`. Both "silences" are `bp … | tail; echo $?` — this repo's own recorded trap
  (`rotating-charter-slot-trap`). The limit exists, sits ~8× above the observed failure, and is loud.
  **The wave does not hunt a boundary; the boundary hunt was the finding.**
- **PDS-D360 — THE A2 BOUNDARY. PDS-D313's A2 JUSTIFICATION IS FALSIFIED FOR `type:task`, AND THE
  PRECISE STATEMENT IS THE GUARD BOUNDARY, NOT "A SECOND DOOR EXISTS".** D313 reads verbatim
  (origin/main:4603): *"A2 PERSISTED-RECORD ECHO — satisfies the law for claims about THE RECORD …
  the response IS the record; a second GET reads the same row."* Observed live this wave, not derived:
  `bp doc patch` mints a `drafts.` twin from the CURRENT published content; `bp task stamp` writes the
  **published** row directly (`Repo.update_all`) and never touches the twin, whose `_rev` does not move;
  a later `bp doc publish` replaces the published content **wholesale** from that frozen twin
  (`lifecycle.ex:139-176`, the only rev fence is `fenced_delete` on the DRAFT) and the landed
  `met:true` becomes `met:false, evidence:""` — **rc=0, normal envelope, no warning.** A second patch
  never rebases the twin, so erasure is SELECTIVE at the mint boundary: `TRACER-A` (stamped before the
  mint) survived, `TRACER-B` (stamped after) was erased. **AMENDMENT, ADOPTED:** *a persisted-record
  echo satisfies the law only where no second door can revert the record between the echo and the
  reader; for `type:task` that door is open exactly when the draft twin's `claim` matches the published
  row's.* A2 is not repealed — it is bounded.
- **PDS-D361 — THE HONESTY GOES CLIENT-SIDE, AND THAT IS A HARD CONSTRAINT, NOT A PREFERENCE.** An
  API-side fix does not take effect until guerrilla deploys, and that deploy is the same human gate
  already holding `pds-w25-round-terminal` (probed live: `bp task stage <done row> done` still returns
  422 `illegal_transition`, so `21ab0e50d` is merged and NOT deployed). A CLI fix is live the moment
  `make cli-build` runs. **The spine ships in `bp`.** Every server-side idea is additive.
- **PDS-D362 — THE PUBLISH DOOR GETS A CRITERIA FENCE, THE HOLE IS ONE GUARD NARROWER THAN THE SURVEY
  CLAIMED, AND THAT NARROWING IS WHAT MAKES IT SHIPPABLE.** `stale_claim?/2` (`lifecycle.ex:310-313`)
  compares only the `claim` map, and a stamp writes `acceptance_criteria + rev` and never `claim`.
  Proved both sides on scratch rows: a draft minted BEFORE the claim is REFUSED (rc=5
  `validation_failed`, stamp intact); a draft minted AFTER the claim is claim-identical, sails past the
  guard, and erases every criterion stamped since the mint. Population measured: 336 `drafts.` task
  twins store-wide, 20 with a published counterpart, 8 terminal/non-terminal pairs, 7 carrying real
  loss (10,401 bytes / 17 `met:true`) — **and all 7 are claim-divergent, so the door refuses them
  today.** The exposure is rows patched DURING an active claim, which is exactly what wave 25's own
  residue-filing pattern produces. The fence is merge-and-test-gated, never deploy-gated: shipping it
  means a pinned `api/test` proof, not a live probe. **NAMED AND NOT CLOSED:** `source: :sync` is
  exempted from the publish door wholesale (`lifecycle.ex:277-279`), and `Link.put`'s draft-twin
  collapse (`plugins/github/link.ex:193`, reached from `mirror_job.ex:560` via the DrainWorker poll and
  from `inbound_events.ex:172`) is an AUTOMATIC publisher — armed on guerrilla (the webhook route
  answers 401, not 404) and one config flip from a background erasure loop with zero audit trail.
- **PDS-D363 — THE SUCCESS-CLAIM REGISTRY'S PROVENANCE ARM CANNOT HOLD A LEDGER ROW, AND THE
  REPLACEMENT IS A STRUCTURAL PROPERTY, NOT A SECOND SOURCE SCAN.** Proved by mutation:
  `TestSiteClaimsAreProbedWithResponseTypes` gates on `pinned[base] || HasPrefix(base, "renderSite")`
  (`:596`) AND on `PkgPath` ending `internal/cloudclient` (`:608`); renaming an honest stamp probe to
  `renderSiteStampVerdict` made it FIRE and then REJECT the only real store type
  (`taskboard.CriterionItem, which internal/cloudclient never RETURNS`). Decisive: a request-echo render
  that ignores the store entirely passes the ENTIRE registry green once the pair is varied on the
  REQUEST — the main gate bites only when the pair varies on the RESPONSE, and nothing enforces that.
  A copied regex arm is unsound on `internal/apiclient` (`Doc` is BOTH returned and a request
  parameter) and vacuous on `internal/taskboard` (neither `CriterionItem` producer returns an error).
  **RULED:** for a LEDGER row the registry asserts structurally that `Backed`/`Contradicted` are the
  SAME Go type, that the type is the read-back type, and that the request fixture is a shared
  package-level var — the `siteCreateReq` pattern made MANDATORY rather than conventional.
- **PDS-D364 — CLAUSE 4(a) IS ANCHORED, THE ANCHOR IS DERIVED FROM THE WAVE PAPER, AND A
  CALLER-SUPPLIED ANCHOR IS FORBIDDEN IN A CERTIFYING RUN.** 4(a) is structurally unreachable by any
  wave that discovers work: a newly-filed row is born bare. Anchoring makes it finite. Proved live:
  `--anchor 2020-01-01T00:00:00Z` flips 4(a) from `157/172 FAIL` to `172/172 PASS` — **a round could
  seal itself by argv.** So the only supported form is `--anchor-from-paper <wave-slug>`, resolving the
  Paper's `_createdAt` (`GET …/paper/pds-wave-26-2026-07-30` → `2026-07-30T21:37:34.085701Z`), failing
  closed on non-200 or unreadable. **TERMINATION IS OBSERVED, NOT ARGUED:** anchored at wave 25's Paper
  the live board reports `residue 14`, anchored at wave 26's it reports `residue 0` — the same 14 rows
  are residue for round N and in-scope for round N+1, deferred by exactly one round, and adjudicating a
  row files no new rows. It is a DISCRIMINATOR, not an excuse machine: it isolates
  `pds-w12-crown-climb-preconditions` (born 2026-07-20) as the ONE genuinely-old bare row among 15,
  refining wave 25's "19 of 19 are this wave's residue" to 14 of 15. **CLAUSE 5 IS ORTHOGONAL AND MUST
  STAY SO:** its window is the census's own READ window (`started` at `:701`, 17.9–30.8 s wide live),
  not the round window; widening it to the round window would trip on every residue write by
  construction. Operational rule: **adjudicate → quiesce → certify.** A row whose `_createdAt` cannot
  be read FAILS CLOSED, exactly as clause 5 already does for `_updatedAt`.
- **PDS-D365 — THE ANCHOR HAS EXACTLY ONE EVASION PATH AND IT IS PROHIBITED DURING A ROUND.**
  `_createdAt` is `doc.inserted_at`, in `@projection_always` (`envelope.ex:64,:354`), absent from
  `Document.changeset`'s cast list and from `writer.ex` entirely — no request can set it, and republish
  preserves it (`lifecycle.ex:177` `Repo.update`). BUT `unpublish_document` `fenced_delete`s the
  published row (`:428`), so a later publish takes the `Repo.insert` branch (`:180`) and mints a FRESH
  birth: **a row unpublished and republished after the anchor is REBORN as residue.** `bp doc unpublish`
  is a shipped verb and `unpublish` is a first-class `/v1/data/mutate` op. Ruled: unpublish→republish of
  a `pds-*` row during a round is forbidden, and the preservation/reset pair is pinned by an
  `api/test` assertion (none exists today).
- **PDS-D366 — M2 IS FIVE VERBS NOT THREE, THE GATE IS THE DERIVATION AND NOT THE MAP, AND
  `create-image` IS NOT A SERVER POST-CONDITION AT ALL.** Derived from origin/main, `hzDone` has seven
  literal-verb call sites; five are post-action: `rebuild` (:1199), `resize` (:1231), `enable-rescue`
  (:1276), `create-image` (:1320), `attach-iso` (:1353). Wave 25's own residue note named only three —
  the undercount is inherited from a real ledger row, not invented. Adding a `resize` key REDS
  `TestHetznerActionVerbsAllDeclareAPostCondition` on the **stale-entry** arm (`:351-355`), because the
  verb list is DERIVED from `runHetznerServerAction(out` call sites and all five flag verbs bypass that
  executor. Proved end to end: the naive widening drags in `create` and `delete` (6 errors); widening +
  a declared exemption map for those two leaves EXACTLY the four unkeyed flag verbs red; adding all five
  keys goes GREEN with `./internal/cli` green at 22.4 s. **The error string at `:340` ("goes through
  runHetznerServerAction") becomes FALSE under the widening and must be reworded — a gate that lies
  about why it failed, on this epic, is not shippable.** `create-image` returns an `*hcloud.Image` and
  changes NO field on `hcloud.Server`: its honest post-condition is a `GET /images/<id>`, a different
  resource, and it takes a DECLARED EXEMPTION with its reason stated rather than a fabricated key.
  **A green map is not an honest receipt:** the proof obligation is behavioral (a fake API whose
  post-action GET disagrees, and the receipt differs), the shape of
  `TestHetznerServerMetadataFlipNotAppliedFails`.
- **PDS-D367 — `hzResDone` IS NOT A VERB AND IS CUT FROM WAVE 26.** It is a shared printer with 51
  non-test call sites across five files (lb 21, net 17, dns 6, storage 5, backup 2) and NO
  post-condition machinery. Its registry row is **vacuously green by mutation proof**: deleting the
  `extra` payload spread — and then ALL extra handling, sorted table lines and the orphaned `sort`
  import — left `TestSuccessClaimsChangeWhenTheResponseDoes/hzResDone` PASSING, because the row probes
  with a `nil` extra and varies only ID and Name, "the fields an action CANNOT change." It fires only
  when the identity echo itself is severed. This is the exact pre-repair shape PDS-D355 fixed for
  `hzDone` one entry above it. Fixing it means BUILDING the apparatus and then classifying 50 sites
  (13 destroy / 12 create / 23 request-echo / 1 measured-uncompared / 1 with no cheap post-read) —
  a wave-sized slice, filed, not smuggled into a receipt cleanup.
- **PDS-D368 — THE EXPORT RENAME AND THE PRE-FIRST-BYTE SIDECAR REMOVAL ARE ONE ATOMIC CHANGE;
  SHIPPING THE RENAME ALONE IS STRICTLY WORSE THAN MAIN TODAY.** `bp export --out` truncates via
  `os.Create` (`export_cmd.go:165`) and removes `<file>.meta` at `:161` before the first byte — correct
  under truncation, actively harmful under rename. Proved: with rename added and `:161` kept, a
  truncated nightly re-export leaves the GOOD backup intact (36 bytes preserved) while its sidecar is
  gone, and `--verify` on that intact backup exits 1 — **UNVERIFIED and, by design, unoverridable.** A
  data-destroying bug traded for an attestation-destroying one. Measured cost of the correct change:
  of #8220's 8 merged tests, 6 stay green untouched, `TestRunExportOutTruncatedLeavesNoSidecar` is a
  REWRITE (three independent path-bound assertions, the third hidden behind a `Fatalf`) and
  `TestRunExportOutClearsStaleSidecarBeforeWriting` INVERTS. Meta renames LAST so the only reachable
  interleaving is good-file/no-sidecar.
- **PDS-D369 — "COMPARE AGAINST WHAT WAS DECLARED" IS BUILDABLE FOR EXACTLY ONE SINK, AND THE `-1`
  GUARD IS MANDATORY THERE EVEN THOUGH THAT SINK NEVER TRIPS IT TODAY.** Probed live with the CLI's own
  `newTransferClient` transport: the workspace export returns `ContentLength=134884864`,
  `Uncompressed=false`, `copied==ContentLength` — because the controller ends in `send_file/2` and
  Bandit never compresses that path. On the SAME server with the SAME transport, `/api/schemas` returns
  `ContentLength=-1, Uncompressed=true, copied=109250, match=false` — Go added `Accept-Encoding: gzip`
  itself and stripped the length. A naive `n != resp.ContentLength` fails EVERY successful call on any
  compressible route, and PDS-D204 already moved this route `send_resp`→`send_file`, so a move back
  re-arms it. `-1` → `verified:false`, never a failure; copy the honest shape already in-tree at
  `cloud_workspace_cmd.go:660-668`. **The promise does not apply elsewhere:** `bp export --out` composes
  NDJSON with no declared size (its integrity mechanism is the sha256 sidecar),
  `hetzner_instance_transfer_cmd.go:229` is an SSH stream by construction, and
  `hetzner_storage_cmd.go:453` has nothing to compare against because
  `objstore.Client.GetObject` discards `GetObjectOutput.ContentLength` and the client has no `Head*`
  method. Also recorded: the export bundle is NOT byte-reproducible (134877184 / 134879744 / 134884864
  across three consecutive runs) — compare WITHIN one response, never against a cached expectation.
  There are SIX `os.Create` sinks under `internal/`, not the five previously named:
  `context_render.go:177` was unlisted.
- **PDS-D370 — THE RETROACTIVE-DAMAGE HALF OF THE SPINE IS ANSWERED AND CLOSED: THIS EPIC'S EVIDENCE IS
  NOT HOLLOW.** Re-derived with per-doc reads (no paginated walk in the count path) over all **299**
  `pds`-prefixed rows store-wide: 1448 acceptance criteria, 787 `met:true`, **0 with empty evidence, 0
  under 40 bytes**; shortest evidence string 45 bytes, median 531. Restricted to the 205-child epic rail
  it is 964/503/0. **A dropped stamp leaves `met:false`, not a fabricated `met:true`** — the exposure is
  UNDER-counted progress, never invented proof. Two structural corrections ride with it: the rail's
  "205 children" is 204 real rows plus one phantom `drafts.` pointer, and **102 `pds-*` rows live
  OUTSIDE the rail as grandchildren**, so a rail-scoped audit misses a third of the epic's evidence —
  quote the census's `closure_size` (310), never 205. Honest limit: this measured HOLLOWNESS, not
  semantic vacuity, and an erasure leaves `met:false` indistinguishable from never-attempted, so it
  cannot exculpate past erasures — only `mutation_events` could.
- **PDS-D371 — THE STAMP REFUSAL VOCABULARY SPLITS 5/6 BY RETRYABILITY, NOT ALL-TO-6.** Today
  `not_holder`, `not_in_progress:<s>`, `criteria_mismatch`, `criteria_index_out_of_range`,
  `criterion_text_required`, `note_required` and `illegal_transition` all exit **2** — the same code as
  `--met --miss`, so a retry wrapper cannot tell a recoverable lease loss from a bad command line.
  Blast radius measured at ZERO (whole-repo `go test ./...` green across 25 packages, doc gates PASS,
  no test pins exit 2 on a task refusal, no shell caller branches on a numeric bp exit for these).
  Two mechanical requirements: the server mints COMPOUND tokens (`not_holder:<worker>`,
  `not_in_progress:<status>`) that a literal map key misses, and `classifyError`'s ok-false branch does
  a SECOND literal lookup that defeats normalisation applied only inside `exitForCode` — so the fix is
  a shared `lookupExit` keyed on the reason PREFIX (never on the HTTP status, which `errors.go:20-22`
  forbids). **RULED:** exit 6 (conflict — re-claim and retry) for `not_holder` and `not_in_progress`;
  exit 5 (validation — fix the request, never retry) for the four criteria/note guards AND for
  `illegal_transition`, which is a 422 and is the one member of the list that is NEVER retryable —
  bucketing it 6 would contradict PDS-D52's own ruling that 422 is `exitValidation`. `doc_changed_since_claim`
  and `claimed_has_worker` are added too: the CLI already coaches them by name and still files them as
  "bad command line".

**WAVE 26 PLAN — 7 slices, all round 1, all disjoint by file.**

| task | surface | gate |
|---|---|---|
| `pds-w26-stamp-readback` | `bp task stamp` second read + registry ledger-row property | `CC=clang go test ./internal/cli/...` |
| `pds-w26-stamp-exit-taxonomy` | `codeExit` 5/6 split + compound-prefix `lookupExit` | `CC=clang go test ./internal/cli/...` |
| `pds-w26-publish-door-criteria-fence` | `gate_task_publish` criteria fence + `inserted_at` pin | `CC=clang mix test test/barkpark/content/lifecycle_test.exs` |
| `pds-w26-hetzner-five-flag-verbs` | widened derivation + 5 post-conditions + behavioral proof | `CC=clang go test ./internal/cli/...` |
| `pds-w26-census-anchor-4a` | `--anchor-from-paper` clause 4(a) | `bash scripts/pds-ledger-census_test.sh` |
| `pds-w26-export-atomic-out` | `bp export --out` temp+ordered-rename + `:161` move | `CC=clang go test -run TestRunExport ./internal/cli/` |
| `pds-w26-workspace-export-declared-size` | workspace export rename + declared-size verify + `-1` guard | `CC=clang go test ./internal/cli/...` |

**HIGH-FLIP-RISK, second independent reviewer owed before merge:**
`pds-w26-publish-door-criteria-fence` (does the widened fence refuse a legitimate publish? does it
close the `source: :sync` path or merely appear to?) and `pds-w26-census-anchor-4a` (can the anchored
predicate green a round that has not adjudicated its own work?).

**NOT PLANNED AROUND.** `pds-w25-round-terminal` is not dispatched, not worked around, not the spine —
it needs #8218 DEPLOYED, which is an operator action on a live paid instance and the human's call.
`api/mix.exs` and `api/mix.lock` are untouched (#8222 holds them).

---

## Wave 27 — the terminal round, and the reader (2026-07-31)

**Spine: THE ROUND AND THE READER.** Wave 26 audited the ledger WRITER and found it honest, so the
READER is the only half left. The round terminates something; the reader arm makes terminating it
mean something. `hzResDone` stays cut (PDS-D367).

- **PDS-D372 — A CLAIMABLE ROW CARRYING A TERMINAL ADJUDICATION IS A DEFECT, AND IT IS PDS-D298's
  RECIPE LEFT HALF-EXECUTED. THE CHARTER IS NOT SILENT.** The wave's own digest asserted no decision
  D1-D371 rules on adjudication-vs-lifecycle orthogonality. **REFUTED by reading D298 for coverage
  rather than citing it:** the rewritten VOCABULARY block binds each disposition class to a LIFECYCLE
  ACT — `closed` → `bp task close <id> <worker> <epoch> done "<reason>"`; `parked` →
  `stage <id> considering … --disposition parked`; `open` → stage plus a named `disposition_owner`.
  `validation.ex:19-31` holds `"OPEN MEANS READY" is held by construction — only open|blocked is
  claimable`. So `disposition ∈ {closed}` on `lifecycle ∈ {open, blocked}` is the recipe with its
  second half never run — a CONTRADICTION the round repairs, never an orthogonal axis.
  **IT IS INVISIBLE TO BOTH INSTRUMENTS:** `queue.ex` contains the string `disposition` ZERO times
  (it is not a readiness axis), and the census counts these rows in clause 4(a)'s numerator as
  SATISFIED — the instrument reads the contradiction as compliance while `bp task ready` hands the
  row to a worker.
  **THREE POPULATIONS, NOT A DISAGREEMENT — DO NOT CONFLATE THEM.** Closure-scoped: **13** (all
  `lifecycle=open`, `disposition=closed`, each read back individually). Store-wide `bp task ready`
  join: **16** (13 closed + 3 parked, one of which — `task-32ce52edfd7af367` — is a NEIGHBOUR EPIC's
  row and is out of bounds). The census can only ever see the closure, so a census clause reading 0
  does NOT imply `bp task ready` is clean, and a reader gate is a DIFFERENT instrument with a
  different number.
  **REPAIR, NOT FILTER.** The 13 are genuinely finished by content per D299 — every reason opens
  `CLOSED …` and all 8 distinct cited shas are ancestors of `origin/main`. They close via
  claim-then-`bp task close … done` with `:criteria_override` (and `:holder_override` where no claim
  ever existed), because all 13 carry `claim = null` and unmet criteria. **The override records are
  the point, not a workaround** — budget ~2 recorded overrides per row, not a one-liner.
  **A SILENT QUEUE FILTER IS REFUSED**, extending PDS-D348's "it reaches exit 0 by not looking" from
  the census to the reader: with the census already blind to this population, a silent filter would
  mean no instrument anywhere looks.
  **ANY RULE MATCHES ONLY THE NORMALISED VOCABULARY `{open, closed, parked}` AND TREATS AN
  UNRECOGNISED DISPOSITION AS LIVE.** Store-wide off-vocabulary is 41, of which 26 are `tgw*` rows
  carrying the literal `'open — demoted child of truth-grip-epic (charter D117)'`; a gate phrased
  `disposition IS NOT NULL AND != 'open'` would silently delete 26 rows from a neighbour's queue.

- **PDS-D373 — THE PARKED HALF OF THE CONTRADICTION CLAUSE IS REFUSED ON THE RECORD, BY MEASUREMENT.**
  A closed-only clause 6 costs NOTHING: implemented as ~12 lines beside clause 4, the UNMODIFIED
  80-check selftest still passes **80/80** — including `TERMDUP` (which pins that clauses 1-3 stay
  closure-scoped) and every anchor fixture — and on the live board every existing figure is
  byte-identical, the only `--json` delta being one additive key. Extending it to `parked` **FAILS 7
  of 80**, and the FIRST failure is the CONTROL: `build_healthy`'s `kid-c` is `blocked parked` and is
  inherited by all 34 fixture dirs. It also reds `SHAREDTRIG`, the fixture that exists precisely so
  "no future wave can tighten clause 4" (PDS-D336(a)). Live, all 29 parked closure rows carry a
  STRUCTURED `reopen_trigger` — the epic's own exemplary shape. **A live park awaiting its trigger is
  not a contradiction; it is a park.** Widening to parked is a doctrine reversal, not a clause, and
  needs its own D-number that says so out loud.
  The clause emits a ROW-ID LIST, never a bare count — a count nobody can turn back into rows is not
  a worklist. `blocked` is NOT a valid park destination (`@claimable_statuses ~w(open blocked)` leaves
  it in `bp task ready`); D298's `considering` is the only honest one.

- **PDS-D374 — THE ROUND IS 45, NOT 15, AND IT NEEDS ZERO LEAD ACTS TO REACH EXIT 0.** Re-derived
  live under a wave-27 anchor: clause 1 `183 == 183 PASS`, clause 3 `15 FAIL`, clause 4(a)
  `156/186 FAIL`, **RESIDUE 0**, 4(b) `156/156 PASS`, 4(c) `29/29 PASS`. So 15 off-vocabulary + 30
  bare = 45, and every one of the 30 is pre-anchor and IN SCOPE — D364's one-round deferral working
  as designed, not a leak. The wish's premise 2 was incomplete; it is corrected here, not worked
  around.
  **THE UNBLOCKING NOBODY HAD:** the census requires a **disposition**; it requires NEITHER a
  lifecycle move NOR a `met:true` criterion. No failure append in `--assert-round-done` reads
  `acceptance_criteria` or `lifecycle_status`. Therefore `pds-w25-round-open` (7/8),
  `pds-w25-round-parked` (7/8), `pds-w25-round-bare` and `pds-w25-independent-review-stage-widening`
  all reach clause 4(a) by being adjudicated **`open`** with an honest reason naming the outstanding
  `[MERGE-GATED]` lead act — which is TRUE, so it is a lie in neither direction. The lead acts gate
  CLOSING those rows. **They do not gate exit 0.** Do not close them; adjudicating `open` is both
  honest and sufficient.
  Corollary: `pds-w25-round-bare` criterion 4 enshrines `pds-w12-crown-climb-preconditions` as a
  "blocked, NON-STAGEABLE row". **That is now stale** — `transitions.ex:42` has `blocked` in
  `@statuses`, `legal?/2` returns `from in @statuses` when `from == to`, and `stage.ex` admits
  `(to in @stageable or from == to)`. `blocked → blocked` IS a legal adjudication door and pds-w12 is
  stageable in place. #8218 dissolves the contradiction between that row's criteria 3 and 6.

- **PDS-D375 — THE 30 BARE ROWS ARE NOT 30 TEMPLATE REASONS: FIVE STORED DEFECTS ARE STALE AND ONE IS
  REFUTED OUTRIGHT.** The digest's "21 clean `open`" measures as **15**. Clause 1 only checks
  md5-distinctness, so every stale row can be given a beautiful, unique, byte-distinct reason that is
  FALSE and the census will pass — the precise failure wave 25 caught going the other way. Named:
  (1) `pds-bl-cond-b-nonnumeric-floor-fail-direction` is **REFUTED BY EXPERIMENT** — the
  `pds-pull-proof.sh:1304-1310` shape under `set -euo pipefail` with a non-numeric floor prints
  `[: abc: integer expression expected` and lands `cond_b=FAILED ok=0`. **It fails CLOSED.** The row's
  entire premise does not exist; it adjudicates `closed`, and leaving it `open` is the wave-25 defect
  pointed the other way. (2) `pds-bl-github-linkput-auto-publish-erasure`'s headline defect was fixed
  by wave 26 and `lifecycle.ex:292-312` says so verbatim — the GitHub publishers thread
  `source: :github`, fall through to `gate_task_publish`, and only `:sync` is exempt. (3)
  `pds-bl-task-stamp-silent-nonland`'s priority-1 framing is stale — the CLI read-back shipped
  (`tasks_stamp_cmd.go:166-173`, `renderStampVerdict` returns `exitConflict`); the MCP bypass is
  already its own row. (4) `pds-bl-close-409-hint-promises-absent-fields` is **MIS-STATED** — the
  server 409 DOES carry `current_rev` and `changed_fields`, at the TOP LEVEL
  (`tasks_controller.ex:519-533`); the defect is CLIENT-side (`errors.go:153-160`'s `canon` struct),
  and the criterion as written would make the SERVER worse. (5)
  `pds-bl-publish-refusal-drops-teaching-text` is TRUE but MIS-LOCATED and shares (4)'s root cause —
  **these two rows are ONE CLI fix**. Four rows are runtime-only and get an honest thin reason naming
  the probe rather than an invented thick one. Two DUPLICATE PAIRS sit inside the 30 (create-image ×2;
  hzResDone ×2) — adjudicating both halves separately manufactures clause-1 variation without adding
  information.

- **PDS-D376 — ARM B IS A VIEW SELECTION, NOT A RENDERER GAP, AND THE TUI STRIP IS ALIVE.** The
  wave's opening premise — "`tasks_controller/params.ex` is the SOLE renderer and the string
  `disposition` does not occur in the file" — is true of the file and FALSE as a conclusion.
  `render_doc(:full)` ends `content: Map.delete(content, "claim")`, a whole-content passthrough, so
  the full view ALREADY carries the adjudication triple; `parse_view(_) → :full` is the server
  default; and the drop is client-side (`resolveView`: machine output + a manifest `views`
  declaration ⇒ brief; `bp task ready` has no `--view` flag). The TUI is NOT blind — it is the one
  surface that hydrates AND renders the triple (`fetch.go:451-453` → `detail_render.go:200/:204`),
  **mutation-proven**: deleting the disposition `emitStrip` line turns `TestDetailDispositionStrip`
  from PASS to FAIL. **The SDK arm is EMPTY** (no JS reader of `/v1/tasks` exists) and is cut.
  So the fix is a ~10-line conditional additive key copying `put_brief_engagement/2` line for line —
  the additive-key precedent already in the file — with zero contract renegotiation and zero test
  rewrites.
  **`disposition` ONLY, AND THAT IS A MEASURED BUDGET DECISION, NOT TASTE.** Both tripwires ran:
  realistic **11055 B / 15360** (4305 free), hostile **28640 B / 30720** (**2080 B free**). The
  charter's recorded 11,005/28,594 are STALE. Steady-state `,"disposition":"parked"` = 23 B ⇒
  50 × 23 = 1150 B, fits with 930 B to spare. **`reopen_trigger` CANNOT RIDE AT ANY GRAPHEME CAP:**
  the key with a ZERO-LENGTH value is `,"reopen_trigger":""` = 20 B ⇒ 1000 B on top of 1150 = 2150 B,
  overflowing 2080 B **before a single character of value** — the cap would have to be negative.
  `disposition_reason` averages 753 B (max 1612). Both already ride `bp task get`, which is the
  escape hatch AXI law 2 asks for.
  **AND THE SLICE IS VACUOUS UNLESS THE FIXTURE MOVES FIRST:** NEITHER byte tripwire fixture sets a
  `disposition` — nor an `engagement`. A conditional key leaves BOTH tests GREEN while measuring
  NOTHING; a builder ships ten lines, sees 113/113, and reports headroom proven. That is this epic's
  own law violated inside the test that enforces it. **The honest order is: add the field to the
  hostile fixture FIRST, watch the printed byte number MOVE, and only then write the renderer line.**
  The hostile fixture's value derives from the VOCABULARY (`parked`, the longest canonical term), never
  from the live corpus — which still holds a 71-byte prose disposition the round is retiring.
  Free consequence: `mcp_tasks.go` forces `view=brief` on both the list (:150) and prime (:561) reads,
  so fixing brief fixes the MCP agent surface too.

- **PDS-D377 — THE READER LIE IS BIGGER THAN A DROPPED FIELD: `--all` LAUNDERS EVERY HTTP-200 ANOMALY
  INTO AN EMPTY LIST AT EXIT 0.** Nine poisoned-transport fixtures — a proxy 502 HTML interstitial,
  `null`, `ok:false`, an unknown envelope key, zero bytes, `{"result":null}`, `{}`, a bare array,
  plaintext — every one served with HTTP 200, all produce `rc=0`, `{"documents":null}`, EMPTY stderr.
  **And the genuinely-empty control is BYTE-IDENTICAL**, proven by sha not by eye:
  `html502 rc=0 sha=73595a255a6a12a6` / `genuinelyempty rc=0 sha=73595a255a6a12a6`. A worker cannot
  distinguish "the queue is empty" from "the reverse proxy is down" by any means at the CLI surface.
  This is PDS-D287 violated in the reader every builder uses.
  **THE FALLBACK IS DELIBERATE AND HAS A COMMENT DEFENDING IT** (`run.go:1498-1502`: "Unknown envelope
  … fall back to the documents shape so nothing regresses"), fed by `extractListRows` returning
  `(nil, "")` silently on any unparseable body. It must be explicitly reversed, not quietly patched.
  **THE FIX IS PROVEN BOTH DIRECTIONS:** a ~12-line per-page refusal on the `key == ""` sentinel flips
  all nine to `rc=1` with a named `unreadable_list_page`; BOTH controls hold `rc=0` (empty stays
  byte-identical); the full CLI suite stays green (`22.302s`) with ZERO test rewrites; and all 7
  paginated verbs return `rc=0` against LIVE guerrilla. Safety is enumerated, not assumed:
  `paginated: true` occurs exactly 7 times in the API source and every one returns a key already in
  `listEnvelopeKeys`. One near-miss earns a companion guard — the LEGACY `media_controller.ex:46`
  returns `files:`, absent from `listEnvelopeKeys`; it is not the route `bp media ls` uses, so there
  is no live bug, but it is one rename from reddening an honest caller.
  **THE EXISTING TEST IS THE STAMPED-EVIDENCE FAILURE MODE IN THE FLESH:** `paginate_all_test.go:89`
  pins the `""` sentinel at the PURE level and its own comment DOCUMENTS THE LIE AS INTENDED. There is
  zero end-to-end assertion. That is why `origin/main`'s suite is green while the bug is live.
  Two residues are NAMED, not absorbed: `bp task next` prints `ok` at rc=0 on a null body
  (`renderMinimal`, a different function), and `--all` corrupts even the honest empty shape
  (`[]` → `null`, `count` silently dropped).

- **PDS-D378 — THE CERTIFYING INSTRUMENT'S OWN `--json` IS NOT JSON, AND IT IS POISONED EXACTLY WHEN
  IT CERTIFIES.** `--json --assert-round-done` writes the JSON object and then the human ROUND-DONE
  PREDICATE block to the SAME stdout; `jq -e .` exits 5. The script is careful everywhere else —
  `die()`, retry notices and the failure VERDICT all use `file=sys.stderr` — so this is ONE MISSED
  GUARD. **The GREEN path is poisoned too:** on the healthy fixture the run exits 0 AND jq still fails
  rc=5. And the payload carries **no verdict field at all**, so even a clean stream leaves a scripted
  consumer without a machine path. Fix is BOTH: fold `round_done` + `round_done_failures` into the
  report AND route the human block to stderr. No consumer blocks it — a repo-wide grep finds only the
  census, its selftest, charter prose and two ledger recipes quoting exit codes, and every selftest
  assertion captures `2>&1`, so the stderr move costs zero test rewrites (verified: 80/80 against a
  patched copy).
  **THE ANTI-PATTERN IS PROVEN AND MUST NOT BE SHIPPED:** do NOT defer the JSON emit until after the
  predicate. On `origin/main` the clause-5 incoherence path (exit 4) runs AFTER the emit and therefore
  STILL prints valid JSON (rc=4, 985 bytes, jq_rc=0); a deferred-emit draft turned that into rc=4,
  **0 bytes**, jq_rc=4 — a fresh honesty regression inside the honesty fix. The predicate is a pure
  function of `report`: hoist it, call it BEFORE the emit, stash `round_done`, print once.

- **PDS-D379 — THE PAGED READ HAS NO STABLE ORDER, AND THE FIX HAS TWO TRAPS ONE KEYSTROKE AWAY.**
  `census.sh:387` sends only `limit`+`offset`, so `query.ex:704`'s catch-all applies
  `desc: d.updated_at` — a MUTATING sort key paged by explicit offset. A concurrent write teleports
  its row to index 0; proven live in six requests (the probe row at index 3 was NEVER SERVED while
  offsets 0 and 1 both returned the same row).
  **THE "SILENT" HALF IS REFUTED FOR WRITES:** under `updated_at DESC` a write can only move a row
  TOWARD offset 0, so a skip and a duplicate are produced 1:1 by the same shift, and the corpus-wide
  duplicate detector kills the run with exit 4 (proven on a fixture: `SNAPSHOT INCOHERENT`). The
  genuinely silent variant is a concurrent DELETE, which shifts rows UP and produces no duplicate —
  argued, not run, and the residual hole a stable order also closes.
  **THE FIX IS `&order=_createdAt:asc`, AND IT IS PROVEN IMMUNE:** 3901 rows with ZERO `_createdAt`
  ties, globally sorted across four pages; the probe sat at index 3894 BEFORE and AFTER a stage write
  with byte-identical `_createdAt` and zero rows gained or lost, while the same write under the
  default order put that row at index 0.
  **TRAP (a):** `order=doc_id` (no direction) does NOT error — it fails
  `query_controller.ex:706`'s `<field>:(asc|desc)` regex and SILENTLY falls back to `updated_at DESC`
  at HTTP 200, byte-identical to sending nothing. A "fix" spelled that way is a green diff with zero
  behaviour change — this epic's own lie class, live in the order param.
  **TRAP (b):** `order=doc_id:asc` parses as a CONTENT field and sorts
  `jsonb_extract_path(content,'doc_id')`, NULL for every task row — an all-NULL sort key is an
  UNSPECIFIED order that can skip and duplicate with no concurrent write at all. **Strictly worse than
  the bug.** Only `_createdAt:asc` is correct; prove the spelling, never assume it.
  Also recorded: the clause-5 drift detector is CLOSURE-scoped (`rows = [corpus[i] for i in closure]`)
  and always was — it never examined the ~3570 rows outside the closure, which are exactly the rows
  the shift arithmetic runs on.

- **PDS-D380 — QUIESCE IS A CRITERION, ITS TAIL IS 43.90 s, AND ITS GATE IS CLOSURE-SCOPED.** The
  write-back tail is not the operator's writes: a stage landed at `01:07:28.372157Z` and the GitHub
  MirrorJob stamped the row back at `01:08:12.271620Z` with `github.synced_rev` pointing at that rev —
  **43.90 s**, exactly once (the mirror's own write is `source="github"`, which the outbox excludes),
  with 3900 of 3901 task rows carrying a synced link. 43.90 s **exceeds** clause 5's own read window
  (17.9-30.8 s), so a certifying run started sooner will exit 4 on closure rows.
  **THE GATE MUST BE CLOSURE-SCOPED, EXACTLY AS CLAUSE 5 IS.** A corpus-wide `moved == 0` gate is
  hostage to unrelated fleet traffic — three foreign `jarl-*` rows moved inside one 60 s idle window
  and the corpus grew twice in a single session — and would refuse runs clause 5 would pass.
  Closure-scoped `moved == 0` held in both measured windows. Operational rule stands: **adjudicate →
  quiesce → certify**, with certification the LAST act of the wave, `sleep 90` as a floor (2× the tail)
  and `moved == 0` over two reads as the verdict.
  **SECOND-ORDER TRAP:** clauses 1, 3, 4(b) and 4(c) are CLOSURE-scoped, not anchor-scoped — only
  4(a) defers residue. A row FILED during the wave carrying a disposition with a duplicate reason, an
  off-vocabulary value, no reason, or a park with no trigger will fail the certifying run even though
  it is residue. **Wave 27's slice and backlog rows were therefore filed BARE, deliberately.**

- **PDS-D381 — THE HETZNER RECEIPT GATE READS ONE FILE, AND WHAT IT CERTIFIES IS MAP MEMBERSHIP, NOT
  EXECUTION.** `hetzner_cmd_test.go:306` is `os.ReadFile(filepath.Join(".", "hetzner_cmd.go"))` — a
  single hard-coded filename — while `hetzner_instance_cmd.go` carries FOUR literal-verb receipts
  (`archive`:671, `resurrect`:1057, `adopt`:1164, `eject`:1232) structurally invisible to it. This is
  PDS-D366's failure reproduced one file over, at FILE granularity instead of CALL-SHAPE granularity.
  Widening to a glob is SELF-PROVING — it reds on clean `origin/main` with exactly those four, deriving
  20 verbs / 16 keyed-or-exempt / 4 bare, zero false positives.
  **THE DECISIVE FINDING:** `hzServerPostConditions` is consumed at exactly two sites
  (`runHetznerServerAction`, `hzFlagVerbDone`) and **the four instance verbs reach neither** — an awk
  over `runInstanceArchive`/`runInstanceEject` greps ZERO references to `hzReadBack` /
  `hzServerPostConditions` / `hzBoundPost`. **Proven by mutation:** four inert table entries turn the
  widened gate GREEN while `hetzner_instance_cmd.go` is untouched. PDS-D366 already wrote "the gate is
  the derivation and not the map"; the widening does not carry that obligation across the file
  boundary. **The behavioural half ships with the widening, or the wave has built a tripwire a builder
  disarms in four lines.**
  Per-verb: `archive` is a REAL LIE (its `srv` is the PRE-action server resolved before `instArchive`,
  which may STOP the machine; `image_id` is echoed off the create-action response and the image is
  never re-read) — plus an unnamed one: with `--stop`, a failed quiesce degrades to a crash-consistent
  snapshot via `out.info`, and `writer.info` writes to stderr ONLY WHEN VERBOSE, so a cleanly-quiesced
  and a crash-consistent snapshot of a live Postgres emit BYTE-IDENTICAL receipts; remedy is a
  non-optional `quiesced` key. `eject` is the sharpest: it discards the status `cpFleet.Deprovision`
  exists to return and then asserts "now standalone" IN PROSE on `err == nil` — a control plane that
  answers 200 with `deprovisioning` gets that sentence while a worker is en route to delete the clone
  eject just built; the existing test asserts the detach REQUEST was sent, never that the row is gone.
  **Decide's ruling:** eject is DESTRUCTIVE, so an unconfirmed detach takes the existing
  `hzPartial` / "confirmation unavailable" shape — not a silent exit 0 and not a new third shape.
  `resurrect` and `adopt` are exempt with TRUE stated reasons (their `srv` IS a post-action read-back),
  their echo residues filed separately — **an exemption whose stated reason is false is this epic's own
  sin.** Two refusal strings go stale under the widening and one becomes FALSE (`:383` claims "the
  server resolved BEFORE the action fired", untrue for three of the four); PDS-D366 fixed that exact
  class once, and the widening re-arms it.

- **PDS-D382 — EXIT 0 CERTIFIES THE ROUND. IT NEVER CERTIFIES THE EPIC.** The wish framed
  `--assert-round-done` as "the epic's own done-condition". It is not, and the charter says so
  everywhere except one line of wave-25 review prose. Every census clause is satisfied by a PARKED row,
  so a green is fully compatible with W2-W5 being entirely unbuilt — and they are: `bp dev` does not
  exist as a CLI namespace at all. The epic row carries W1-W5 all `met:false` while `pds-w1-crown-proof`
  sits `done` at 12/12 holding W1's proof.
  **AND THE EPIC ROW IS OUTSIDE THE PREDICATE'S POPULATION** — `build_closure` seeds its frontier with
  `kids[root]` and never appends root, so it is absent from `live_bare`. Exit 0 neither requires nor
  tempts adjudicating it; adjudicating it `closed` to reach a green would have been the largest
  instance of the lie this epic exists to prevent, and there is now not even a green-shaped excuse.
  **THE CERTIFICATE IS ALSO SILENT ABOUT 316 ORPHAN DRAFTS.** The census reads the PUBLISHED
  perspective (it sends no `?perspective`, and the default is published) while `bp task ready` serves
  **28 `drafts.` rows with NO published twin**. The cause is an OMISSION in `queue.ex`'s candidate
  filter — no publication predicate — and NOT a broken twin collapse, which is a CONDITIONAL
  SUPPRESSION firing only when a distinct published twin EXISTS. **Wave 27 takes ZERO code here:** that
  is `tgw10-bl-drafts-in-ready-pool`, an OPEN row at 0/5 on the TRUTH-GRIP epic, and building another
  epic's open row without claiming it is the false-done this epic exists to prevent. Its criterion 1 is
  DISCHARGED by wave 27's measurement and handed over. So: **exit 0 certifies the PUBLISHED round**, and
  that limit is stated in the certificate itself.

- **PDS-D383 — THE CERTIFYING COMMAND IS UNSAFE AS PEOPLE WRITE IT, AND THE INSTRUMENT EXECUTES
  ARBITRARY CODE FROM ITS WORKING DIRECTORY.** `bash census.sh --assert-round-done … | tail -20;
  echo RC=$?` prints the full FAIL block and then `RC=0` — tail's code. Measured this wave, over a
  census whose real code was 1. **The epic's own law, violated by the epic's own certifying command.**
  Every certifying invocation redirects to a file and captures `$?` directly.
  Separately: the census execs `python3 -`, so `sys.path[0]` is the CWD and `bisect` is a transitive
  stdlib import. A stray `bisect.py` in the working directory fails ALL 80 checks **and executes that
  file's top-level code** — reproduced accidentally when a real leftover script in a shared scratchpad
  issued live `bp` writes during a selftest run. That is arbitrary code execution inside a certifying
  run; it is filed, and until it is fixed every gate runs from a clean directory.

- **PDS-D384 — CORRECTIONS BY COUNTING, ON THIS CHARTER'S OWN NUMBERS.** Wave 26's lesson ("counting
  beats quoting") applied to wave 26's own charter, and it is wrong three times.
  (a) **`hzResDone` is 50 non-test call sites, not 51.** PDS-D367's headline says 51 and its OWN BODY
  says "classifying 50 sites" five lines later; the 51 counts the definition line at
  `hetzner_net_cmd.go:56`. The earlier ledger row `pds-w25-backlog-hzresdone-receipt` ("50 callers")
  was right. hzResDone stays CUT regardless.
  (b) **`os.Create` sinks under `internal/` are FIVE, not six.** PDS-D369's grep counted two comment
  lines (`export_cmd.go:29`, `cloud_workspace_cmd.go:211`) as sinks.
  (c) **And the sink POPULATION is the wrong population anyway:** three `os.OpenFile` writers are
  uncounted, two of them `O_TRUNC` — including `upgrade.go:297`, the path that writes the **bp binary
  itself**, truncating the destination before the body arrives and ignoring `resp.ContentLength`
  entirely. File sinks are **EIGHT**, seven of which truncate.
  (d) PDS-D348's fixture citations (`stage_test.exs:254/:269/:278`) and its `stage.ex:337` guard
  pointer have DRIFTED to `:245/:263/:272` and `:375`. Its conclusion (the widening breaks nothing)
  survives every mutation re-run; its causal story does not — widening `@stageable` to include `done`
  reds ZERO tests, and bypassing the allowlist entirely reds only the `cancelled` fixture, so the
  `done` and `in_progress` refusals are held by `Transitions.@legal_pairs`, not by the allowlist D348
  credits.
  (e) The AXI brief-card byte baselines (11,005 / 28,594 B, recorded 2026-07-19) are stale by 50 B and
  46 B — the pages grew without anyone noticing. Re-derive, never quote.

- **PDS-D385 — TWO OBLIGATIONS THIS WAVE FILED AS ROWS BECAUSE PROSE EVAPORATES.** Wave 26 wrote
  verbatim: "If a debrief says a review is owed before merge, FILE IT AS A ROW. Wave 25 did and the
  lead honoured it — because it was a row, not charter prose." Wave 26 then named a second reviewer
  owed on TWO high-flip-risk slices and filed none; a full ledger scan returns 11 `pds-w26-*` ids, none
  a review row. Wave 27 files it (`pds-w26-bl-independent-review-owed-on-two-slices`) — retrospectively,
  since both PRs are merged, and one of them is the census anchor wave 27 certifies with.
  Also filed: the anchor↔round binding (wave 26's own unpaid item 3 — nothing binds
  `--anchor-from-paper` to the round being certified, so a caller can pass an older Paper and reach a
  greener predicate by moving the boundary rather than by adjudicating).
  And a refutation carried OUT rather than closed over: `apply_engagement/5`'s catch-all deletes
  `content.engagement` for every non-thought target, so a same-state adjudication on a `blocked` or
  `in_progress` row **DESTROYS a live engagement lease** — mutation-proven, reachable (`claim.ex` never
  touches `engagement`), and constrained by NO shipped test.

**WAVE 27 PLAN — 8 slices. Seven round 1; the certifying run is round 2 by construction.**

| task | round | surface | gate |
|---|---|---|---|
| `pds-w27-round-terminal-15` | 1 | the 15 off-vocabulary terminal rows → canonical `closed` | census `--json`: `off_vocabulary_total == 0` |
| `pds-w27-round-bare-30` | 1 | the 30 bare live rows, 5 stale reasons rewritten, 1 refuted | census `--json`: `live_bare == []` |
| `pds-w27-round-contradiction-13` | 1 | 13 claimable-and-closed rows repaired with recorded overrides | post-repair `bp task ready` join == 0 |
| `pds-w27-reader-transport-honesty` | 1 | `runPaginatedAll` refuses the `key == ""` sentinel | `CC=clang go test ./internal/cli/...` |
| `pds-w27-census-self-honesty` | 1 | clause 6 + pipeable `--json` + `&order=_createdAt:asc` | `bash scripts/pds-ledger-census_test.sh` (clean dir) |
| `pds-w27-brief-card-disposition` | 1 | conditional `disposition` key + fixture made able to fail | `CC=clang MIX_ENV=test mix test test/barkpark_web/controllers/tasks_controller_test.exs` |
| `pds-w27-hetzner-gate-file-blindness` | 1 | glob the derivation + `archive`/`eject` + behavioural proof | `CC=clang go test ./internal/cli/...` |
| `pds-w27-certify-the-round` | **2** | quiesce, then certify once with `$?` captured directly | the certifying run itself |

**HIGH-FLIP-RISK, second independent reviewer owed:** `pds-w27-hetzner-gate-file-blindness` (the
`eject` repair changes behaviour on a DESTRUCTIVE verb — can the deprovision-status assertion red an
honest detach against the real control plane?) and `pds-w27-round-contradiction-13` (does closing 13
rows with recorded `criteria_override` + `holder_override` write a verdict the content does not
support?).

**NOT PLANNED AROUND.** `hzResDone` stays cut (PDS-D367). The orphan-drafts fix stays with truth-grip
(PDS-D382). `api/mix.exs` and `api/mix.lock` are untouched (#8222 holds them). `bp task ready`'s
store-wide 16-row contradiction population is NOT this wave's — the closure 13 is.

### Wave 27 2026-07-31 — "The Terminal Round, and the Reader" — REVIEWED. Grade A (paper `pds-wave-27-2026-07-31`)

**THE HEADLINE: `--assert-round-done` EXITS 0.** Re-run by the reviewer against the live board with
the wave's own census (clause 6 in the predicate): `REAL_RC=0`, `VERDICT: ROUND DONE`. Distinct reason
hashes 213 == 213 non-empty; off-vocabulary dispositions **0**; live rows carrying a disposition
**172/195 PASS** with 23 named post-anchor residue; live adjudicated carrying a reason 172/172; live
parked carrying a structured trigger 29/29; live rows not contradicted 195/195. Zero stderr bytes.
This is the first time in the epic's history the stated done-condition has been reachable, and it was
reached by paying the round, not by moving the bar. It certifies **THE ROUND, never the epic** —
`pds-w27-certify-the-round` (round 2) still owes the formal quiesced run against the MERGED census.

**WHAT LANDED — 7 of 7 round-1 slices green, all pushed, all with PRs open (#8407–#8413).**

| task | PR | verdict |
|---|---|---|
| `pds-w27-round-terminal-15` | #8407 | clause 3 15 → 0. Population COUNTED, not quoted — the census caps `off_vocabulary_samples` at 3/value, so its sample list was never evidence. The brief listed 8 in-flight rows; the true set is 7, and the extra belonged wholly to the contradiction slice, so the flagged coordination hazard never arose. |
| `pds-w27-round-bare-30` | #8408 | clause 4(a) 30 → 0, clause 1 held (+30 reasons raised BOTH counts by exactly 30 — that arithmetic IS the collision proof). All 30 verdicts re-derived by content, not inherited. |
| `pds-w27-round-contradiction-13` | #8409 | 14 rows (a 14th minted mid-run) lifted out of `@claimable_statuses`. Reviewer re-ran the gate twice AND with a reader-independent derivation over the paged 3993-row corpus: 0 both ways, store-wide. |
| `pds-w27-reader-transport-honesty` | #8410 | nine HTTP-200 poisons flip rc=0 → rc=1 with the named code `unreadable_list_page`; the fallback is DELETED, not guarded. |
| `pds-w27-census-self-honesty` | #8411 | clause 6 as a row-ID list, pipeable `--json`, `&order=_createdAt:asc`. Selftest 80 → 106 checks. |
| `pds-w27-brief-card-disposition` | #8412 | the adjudication term rides the brief card, and the hostile tripwire MOVED (28640 → 29790 B) before the renderer line was written. |
| `pds-w27-hetzner-gate-file-blindness` | #8413 | derivation globbed to 11 files / 20 sites; `archive` and `eject` now observe what they claim; the anti-DISARM gate refuses a keyed verb whose shape reads no table. |

**THE WAVE'S OWN LESSON, learned independently by three builders: DERIVE AT HEAD, NEVER QUOTE.** Every
slice that re-measured its brief found the brief wrong — `docs/api-v1.md` is **13884 B**, not the
brief's 13998 (reviewer re-measured: 13884); the 376-line gate test is under `api/test/barkpark/content/`,
not the path the brief gave; the `hzResDone` population is **50**, not the charter's 51; the Hetzner
receipt population is **20 sites across 11 files**, not one file; `close-409-hint` was MIS-STATED and
its criterion as written would have made the SERVER worse. This epic keeps re-discovering that quoted
byte counts and paths decay — including inside instructions written to fix decayed byte counts.

**WHAT THE REVIEWER FIXED IN PLACE.** Four follow-up commits, each mutation-proven: a rune-boundary cut
in the `unreadable_list_page` body preview (a localised proxy page is exactly the body that message
exists to identify, and a fixed byte cut rendered it as U+FFFD noise); the census human block routed
to stderr UNCONDITIONALLY, which fixed `--json` by splitting the DEFAULT render across two streams so
`census.sh --assert-round-done > report.txt` captured everything except the answer — plus a new
`expect_stdout_only_contains` helper, because every other selftest helper captures `2>&1` and is
structurally blind to which stream a line landed on; `decommission`'s receipt now states whether its
archive was CONFIRMED (it destroys the box and, unlike adopt/eject, nothing downstream boots from the
image to prove it works); and the anti-disarm gate's docstring, which claimed two consumer sites three
lines above a guard counting three.

**LEDGER.** `pds-w27-brief-card-disposition` was lifecycle `open` with 9/10 criteria stamped — finished
work still being advertised as claimable, this epic's own subject pointed at itself. Claimed and
pulsed by the reviewer; now `in_progress`. Every other slice left lifecycle truthful with merge-gated
criteria open for the lead. `pds-w27-certify-the-round` sits untouched at 0/9, correctly.

**TWO HONEST UNDER-REPORTS the lead must read, neither of them a failure of the work.**
`pds-w27-round-bare-30` criterion 6 could not be stamped: `stampMergeGateBlocked` is a bare substring
match over the whole criterion text, and the criterion merely QUOTES the marker. The reviewer verified
its substance live — all four lead-gated rows are `open`, never closed, reasons 913–1069 B, each
naming its outstanding lead act. The guard defect is filed. Its criterion 7 demands
`live_bare_residue == []`, unsatisfiable by construction under PDS-D364; its own parenthetical is met
and the builder refused to flip it. Refusing to move the bar is the correct act and the ledger now
under-reports proven work — which is the same lie pointed the other way, and worth the lead's eye.

**WHAT THE NEXT WAVE TAKES.** (1) Merge round 1 in the order the co-scoped rule demands, then dispatch
`pds-w27-certify-the-round` against the MERGED census with a real quiesce — a green obtained here does
not survive as evidence for a run that has not happened. (2) The READER half is one notch open, not
closed: this wave fenced `--all`; the single-page read path, `bp task next`'s bare `ok` on a null body,
`--all` corrupting the honest empty shape (`[]` → `null`), and the board/TUI surfaces are all
untouched, and NOTHING has yet checked what any reader does with a draft twin. (3) `eject` is
HIGH-FLIP-RISK and owes a genuinely independent second reviewer against the real control plane before
merge — this workflow spawns one reviewer, so that is a manual lead step. (4) The census still cannot
see a FALSE reason: clause 1 only checks md5-distinctness, so 45 verdicts now rest on committed
re-derivation recipes rather than on anything an instrument can re-check. That asymmetry is
structural, it is the round's largest remaining soft spot, and no wave has yet attacked it.

---

## Wave 28 2026-07-31 — "The reason must be able to be wrong" — DECIDED (paper `pds-wave-28-2026-07-31`)

**THE ROUND IS DONE IN FORM. THIS WAVE ASKS WHETHER IT IS TRUE IN SUBSTANCE.** Re-derived at
wave-28 start from an `origin/main` copy of the instrument, in an empty directory:
`pds-ledger-census.sh --assert-round-done --anchor-from-paper pds-wave-27-2026-07-31` → `RC=0`,
`VERDICT: ROUND DONE`, **zero stderr bytes**. live **190**, adjudicated 172, reasons **213 == 213**
distinct, off-vocabulary **{}**, `live_bare == []`, residue **18** (the brief said 19; the board
moved). Wave 27's own reviewer named the hole in the same breath: clause 1 asserts distinctness and
nothing more, so a STALE, INVENTED or PARTIAL reason passes exactly as well as a re-derived one.
That is this wave.

### The decisions

- **PDS-D386 — ADOPT `tooling/grip` READ-ONLY; NEVER COUPLE TO ITS SUITE OR ITS SEAL.** The
  instrument this wave set out to build is ~90% built one epic over. A verifier ran grip's SHIPPED
  `cli.mjs` over synthetic PDS rows with **zero grip changes** and got exactly the verdict line this
  wave wants: ADMITTED (re-derived at L2, 54 ms) / DEMOTED (prose-only, L6, demoted-never-rejected) /
  REJECTED:UNSAFE-RERUN. `disposition_reason` IS grip's `evidence` (L6 by construction — grip built a
  prose scanner FIRST and refuted it at precision 0.67); `disposition_rerun` IS grip's `rerun`. The
  adapter measured **11 lines**, not the ~30 budgeted.
  **BUT the truth-grip epic is NOT SEALED** — `bp task get truth-grip-epic` returns 136 children,
  **74 non-terminal** (34 open + 40 considering); its charter says in its own words "THE SEAL IS NOT
  ATTEMPTED" (:2772); `node tooling/grip/seal.mjs` exits **rc=2 INFRA-FAULT** with every clause
  UNKNOWN, twice, with two DIFFERENT faults; and three of its tests are RED at HEAD
  (`inloop-gate.test.mjs:324/:334` pin literal workflow strings that were re-worded — a guard that
  cannot fail for the right reason, this epic's own disease on another epic's gate).
  **THE RULING:** PDS may IMPORT grip's pure grammar (`level.mjs`, `screen.mjs`, `record.mjs`,
  `adjudicate.mjs`) read-only and MUST NOT modify `tooling/grip/**` — that keeps PDS-D-era fence
  (`charter:4142`) intact and inherits truth-grip D3/D26/D32/D47/D58 cleanly. PDS may NOT gate its
  round-done predicate on grip's suite or its seal. The foreign-adoption seam is UNRULED in BOTH
  charters; this decision rules it from the PDS side only.

- **PDS-D387 — THE FLOOR IS AN AUTHORED FIELD, NOT A SCRAPER. The direction's headline slice is
  REFUTED BY MEASUREMENT.** Run over all 213 reasons: a naive typed floor REDS 14 rows of which
  **1** is a real refutation (**precision 0.07**) and MISSES 2 of the 3 real defects
  (**recall 0.33**) — worse than the 0.67 at which this repo already threw a prose scanner away.
  All 6 MISSING-OBJECT hex tokens are non-git (a bp `_rev`, two md5 of `pg_get_functiondef`, a column
  digest, two 14-digit migration timestamps); 3 blob hashes are **exactly TRUE** and
  `merge-base --is-ancestor` reds all three; 13 of 16 PATH-GONE tokens are root-relative shorthand;
  **41 of 41** path:line citations are IN RANGE, so a line-plausibility floor catches literally
  nothing; and **0 of 73** hex tokens are COMMIT-NOT-ANCESTOR, so the direction's flagship ancestry
  predicate has NO YIELD on this corpus. Four independent extractors gave four prose-only counts over
  the same 172 strings — **64 / 69 / 76 / 118**. The class SIZE is not measurable by extraction.
  And **PDS-D299 is already law**: "ADJUDICATE BY CONTENT; CITED LINE NUMBERS ARE UNTRUSTWORTHY"
  (`charter:4349`). A scraped-line floor contradicts standing charter law and its loudest victims are
  the ledger's best citizens — `pds-w11-router-export-comment-drift` self-corrects to `:2547` (which
  is EXACT at HEAD) and a line floor would red it hardest.
  **THE RULING:** the burden moves to the AUTHOR. `content.disposition_rerun` is a stored field
  written by the `stage` verb. The scraper survives ONLY as a lead generator whose output a human
  types — never as a verdict.

- **PDS-D388 — THE RERUN IS A PREDICATE OR IT IS L6, AND THE SCREEN IS VARIANCE-SKIP, NOT
  STRICT POLARITY.** Over 484 real rerun commands in this repo's own ledger only **8 (1.65%)** are
  strictly-polarised predicates: a strict screen refuses **98.3%** of the repo's own honest reruns
  and honest authors would route around it into prose — the exact failure this wave exists to kill.
  The admissible rule is grip's LEVEL-SKIP rotated one axis: **the command's VARIANCE SET is a
  CEILING on the reason's CLAIM CLASS.** Refuse only over-claims — `VARIANCE-SKIP` (the reason
  claims CONTENT at `file:line` while `git show <ref>:<path>` varies only on EXISTENCE),
  `PIPE-MASKED-RC` (a fetch/format tail discards the rc of the segment that touches the claim), and
  `UNCOMPARED-COUNT` (`| wc -l` prints a quantity and asserts nothing). `UNKNOWN` is **DEMOTED,
  NEVER REJECTED** (truth-grip D3, git-shown at :58 and read for coverage). Measured on the real
  corpus: 283/484 = **58.5%** admitted for at least one claim class, **0** hard-blocked, **57**
  pipe-masked rows mechanically repairable, 144 bounded at L6.

- **PDS-D389 — ABSENCE CLAIMS ARE FIRST-CLASS, AND A NAIVE `rc == 0` SCREEN IS A FALSE-REFUTATION
  ENGINE.** Of 24 real rows with hand-authored reruns, **4 of the 5 FAILED verdicts are TRUE reasons
  whose rerun exits nonzero because the claim IS AN ABSENCE** (`git grep` matching nothing is the
  assertion). The harness MUST consume grip's shipped `admitsAbsenceClaim` (`rerun.mjs:842`), never
  `verdict == ADMITTED`. Measured: a naive `rc===0` screen answers **18/39**; grip's family dispatch
  answers **35/39** — a 43-point gap, and the single strongest argument for adopting grip rather than
  writing a predicate.

- **PDS-D390 — THE FORBIDDEN AND LEGAL RERUN SPELLINGS, MEASURED THROUGH BOTH GATES.**
  FORBIDDEN: `git merge-base --is-ancestor` (REFUSED — `screen.mjs:1299`'s `merge` alternation matches
  the PREFIX of `merge-base` because `-` closes a `\b`; the carve-out is a TWO-file change inside
  ANOTHER epic's shipped module and PDS will not make it); `test -f` (L6, refused, unknown head);
  `$( )` command substitution (refused as a metacharacter, which kills the obvious polarity repair);
  and **`git -C` in ANY spelling** — the same spelling is over-refused in one shape and is the vehicle
  of a LIVE over-permission hole (`git -C log push origin main` is ADMITTED `ok:true` today).
  LEGAL, all admitted and all PROVEN polarised: `git rev-list --count origin/main..<sha> | grep -qx 0`
  (0 iff ancestor, 1 if not, 128 if bogus — L3), `git cat-file -e origin/main:<path>` (0/128 — L3),
  `git grep -n <tok> origin/main -- <path>` (0/1 — L3, anchoring on TOKEN not line, which is what
  D299 demands anyway). NOT predicates despite looking like them: `git branch --contains <sha>` and
  `git rev-list --count <sha>..origin/main` BOTH exit 0 for ancestor and non-ancestor alike.
  `git show <ref>:<path> | sed -n Np` earns L2 but **exits 0 on a DELETED path** — 11.8% of the
  corpus is that shape and it is pipe-masked, not evidence.
  A REMOTE-REF `git grep` earns **L3, not L2** — so the direction's projected "L2 74 / L3 34" INVERTS.

- **PDS-D391 — CLAUSE 1 STAYS, NARROWED IN CLAIM AND NEVER IN SCOPE.** The feared near-duplicate
  cluster DOES NOT EXIST: single-linkage over all 213×213 reason pairs yields **213 singleton
  components at every threshold down to Jaccard ≥ 0.5**, corpus maximum pairwise Jaccard **0.487**,
  median max-similarity 0.195. Distinctness survives stripping every row-identifying token (own id,
  `pds-*` slugs, 7–40-hex, paths, integers): still **213/213**, collapse ZERO. Prefix boilerplate
  decays to zero by 300 chars. So "213/213 distinct" is NOT vacuous. It is also one of the very few
  predicate clauses PROVEN ABLE TO FAIL BY MUTATION (fixtures `BOILER` at `_test.sh:452` and
  `TERMDUP` at :564 — note the assignment's "DUPES" naming is one fixture off; DUPES is the clause-5
  served-twice/exit-4 case), and its one recorded catch was 19 rows sharing a boilerplate that
  ASSERTS A FALSEHOOD ABOUT ITSELF on 19 of 19. Retiring it trades a proven detector for one that has
  never run.
  TWO NARROWINGS, both of claim rather than scope: (a) the verdict line must READ as what it
  certifies — "no reason was MASS-APPLIED" — and must never be quoted as evidence that any reason is
  TRUE; (b) distinctness applies to PROSE ONLY and MUST NEVER be extended to `disposition_rerun` —
  a SHARED rerun over distinct rows is the honest shape, and PDS-D336(a) already ruled exactly this
  for triggers and pinned it with the `SHAREDTRIG` fixture. Also for the record: the hash is
  **sha256[:16]** over whitespace-normalised text (`census.sh:641`), not md5; stop propagating "md5".

- **PDS-D392 — D364 BOUNDS THE RESIDUE; IT DOES NOT RETIRE IT — AND THE BIRTH GATE DOES NOT MAKE IT
  ZERO. THE ANCHOR IS NOT RETIRED THIS WAVE.** D364's clauses are all true and its conclusion does
  not follow: adjudicating files no rows, but a WAVE does, for reasons unrelated to adjudication.
  Let f = rows filed during a round; D364 guarantees a ≥ residue_prev, so **residue_next = f**. The
  fixed point is f, never 0. Empirically measured: **16 of the 18 residue rows were filed by wave 27
  itself in a 79-minute window** while it adjudicated 45 — and TWO of them are wave-27 BUILD slices
  left bare, so the denominator is inflated by unfinished work as well as by discovery.
  The direction proposed retiring the anchor on the strength of a birth gate making residue 0 by
  construction. **That is FALSE as stated**: a task born outside the closure carries no `parent_id`;
  giving it one later is an UPDATE (`prev_doc` non-nil), so **adoption-by-reparent is invisible to
  every birth-scoped gate**, and catching it needs a SECOND fence on the update path. Retirement is
  otherwise cheap and is a STRICT TIGHTENING (priced by doing it: −181 lines in the instrument,
  −140 in the selftest, exactly 22 of 106 assertions anchor-dependent, 84/84 green after; and
  anchorless the census reds at clause 4(a) ONLY — 172/190 — with all six other clauses PASS). It
  also has an unpriced cost: `pds-w27-round-bare-30` criterion 7 CITES `live_bare_residue`, so
  retirement makes that criterion unevaluable rather than satisfiable.
  **THE RULING:** build BOTH fences this wave; retire the anchor no earlier than wave 29, and only
  after a round has run with both fences live. `pds-w27-round-bare-30` criterion 7 is
  **unsatisfiable by construction** and the wave-27 builder was right to refuse to flip it.

- **PDS-D393 — THE BIRTH FENCE'S SEAM IS A `Dedup.check_new_task/5` SIBLING, AND THE GITHUB BRIDGE IS
  BORN ADJUDICATED RATHER THAN EXEMPTED.** Three placements are REFUTED. (a) `Tasks.Validation` is
  pure, holds `content` only, has zero `disposition` awareness, and — decisively — `/v1/data/mutate`'s
  patch clauses (`mutations.ex:288`/`:324`) build `merged` and hand it to `upsert_document`, which
  calls `validate_task_kind` at `writer.ex:490`, so **merge happens BEFORE validation on every
  update**: a content-only rule is RETROACTIVE and would 422 every future patch. (b)
  `validate_task_kind/2` is arity 2 (never receives `opts`, so no `:source` carve-out) and runs at
  `:114`/`:490` BEFORE `prev_doc` is resolved, so it cannot express "birth". (c) A DB CHECK is
  stateless and can therefore require a disposition on ALL task rows or NONE, never "on births" —
  defence-in-depth at the DB tier does not exist for this fence, and no migration is forced
  (`20260528100000_w7a_task_schema.exs` constrains `lifecycle_status` VALUES only).
  **THE SEAM** is `writer.ex:138-139`, beside `Barkpark.Tasks.Dedup.check_new_task(type, attrs,
  dataset, prev_doc, opts)`: it already fires only when `prev_doc == nil`, already holds `opts` (so
  the `Keyword.get(opts, :source, :api) != :api -> :ok` carve-out at `mutations.ex:702` transfers
  verbatim), and already has the escape-hatch-rides-content-fields precedent. It also catches
  `bp task create`, which sends a plain `create` op with no `_id` — refuting prefix scoping.
  **THE BRIDGE IS NOT EXEMPTED**: an unmatched intake error becomes **HTTP 500**, not 422
  (`intake.ex:236` → `github_webhook_controller.ex:163-176`), which would turn every outsider issue
  into a permanent GitHub REDELIVERY STORM on a pipeline that carries NO token
  (`router.ex:659-662`). So `Intake.build_attrs/4` supplies `disposition: "intake"` plus a reason
  naming the issue — born adjudicated for real — and the `:source` carve-out is the fail-safe behind
  it. RESIDUAL NAMED, NOT CLOSED: `do_upsert_document` (`writer.ex:548`) can take an INSERT branch
  with NO `Dedup` call — a birth door with no birth gate. Filed.

- **PDS-D394 — `upgrade.go:297` IS THE CURE, NOT THE SIN, AND ITS SHAPE IS PINNED. THE WISH'S
  PREMISE IS REFUTED, AND THE COUNT HAS NOW BEEN WRONG FOUR TIMES.** `fetchToFile` has ONE non-test
  call site whose `dst` is `.bp.new.<pid>`; `performUpgrade` already downloads to a same-directory
  temp, re-opens it from disk, sha256s it against the release's published `checksums.txt`, refuses on
  mismatch, and `os.Rename`s. Mutating `tmp := exePath` REDS **exactly one** test in the whole
  package (`TestPerformUpgradeChecksumMismatch`) — a precise, on-invariant pin, and the opposite of
  the hzResDone registry row's vacuity. `bp upgrade` never EXECUTES the new binary, which is real
  optional hardening but NOT a law breach, because the sha256-vs-published-manifest comparison is a
  post-read against a declared truth. **DO NOT file it as a law slice.**
  The TRUE population is 3 real + 1 residual: `hetzner_storage_cmd.go:453` (the only sink where a
  declared size genuinely exists and is thrown away — `objstore.GetObject` discards
  `GetObjectOutput.ContentLength` and the client exposes no `Head*`); `cloud_workspace_cmd.go:747`
  (verifies bytes and NAMES the mismatch, but the caller does `rep.fail(...); continue` with **no
  `os.Remove(dest)`** — short bytes stay on disk under the FINAL name and the upload half then PUTs
  them back; **no acceptance criterion on the owning row covers this**);
  `hetzner_instance_transfer_cmd.go:229` (truncates a pre-existing `--out`, and its failure-path
  `os.Remove` then DELETES a file it did not create). `context_render.go:177` is cosmetic (no external
  declared truth). `export_cmd.go:180` is already cured. `openlog.go`/`setup/local.go` are logs.
  **THE FIX SHAPE IS `GetObjectSized`, AN ADDITIVE SIBLING WITH ZERO EXTRA ROUND-TRIP** — the
  declared length is already in the response this code makes today. Widening `GetObject`'s signature
  is materially worse than the owning row's "5 call sites + a fake": it cascades through a SECOND
  interface (`cloud.BundleStore.Get` → `FakeBundleStore` → `bundle.go`/`restore_driver.go` and ~20
  test construction sites).

- **PDS-D395 — `hzResDone` IS RULED, NOT BUILT; PDS-D367's SIZING HOLDS AND IS UNDERSTATED.** The
  population re-derived today is **50** non-test call sites (lb 21, net 16, dns 6, storage 5,
  backup 2); D367's 51 counts the DEFINITION line, and the file has not moved since 2026-07-03, so
  the 51→50 correction is a MISCOUNT, not drift. Zero of `hzDone`'s apparatus transfers: every
  `hzPost` field is typed on `*hcloud.Server`, `hzReadBack` hard-calls `hc.Server.GetByID`, the
  population spans **13 resource kinds** across five SDK clients (one of which, S3, has no `Head*` at
  all), and the existing anti-DISARM gate derives its verb list from `runHetznerServerAction` — a
  shared EXECUTOR that `hzResDone` does not have, so there is no seam to widen onto.
  **HONEST CORRECTION TO THE VACUITY CLAIM, RE-CONFIRMED BY MUTATION AT HEAD:** gutting the `extra`
  payload spread leaves `TestSuccessClaimsChangeWhenTheResponseDoes/hzResDone` **PASSING** — but the
  same mutation REDS **nine** ordinary per-verb tests. The true sentence is "it leaves the epic's own
  anti-vacuity gate green", **never** "it leaves the suite green".

- **PDS-D396 — THE READER'S DEFAULT SINGLE-PAGE PATH IS A BIGGER HOLE THAN THE ONE WAVE 27 CLOSED,
  AND NO ROW OWNED IT.** Wave 27's `unreadable_list_page` refusal is reachable ONLY behind
  `cmd.Paginated && g.all && !cmd.Writes` (`run.go:232-234`) — and `--all` is the RARE invocation.
  Measured: all nine wave-27 poisons × three output shapes = **27 runs, exit 0 in 27/27**, and
  **24 of 27 emit nothing on any channel**; `-o minimal` prints the literal word **`ok`** over a
  `null`, an unknown envelope and an empty object, and `not ok` at rc=0 for an error envelope; the
  `-o json` shape prints the ERROR ENVELOPE as a successful body. The sentinel is ALREADY COMPUTED
  on that path and discarded — `warnIfDefaultPageMayBeTruncated` (`run.go:337`) does
  `rows, _ := extractListRows(...)` and then returns silently because `0 < limit`.
  **PLACEMENT IS LOAD-BEARING**: the fence goes in `runCommand` beside that call, gated on
  `2xx && cmd.Paginated && !cmd.Writes`, and MUST NOT inherit the neighbour's `g.limitSet` skip. It
  must NOT go in `renderMinimal` — `extractListRows` returns `key == ""` for **5 of 7 real write
  receipts** (the mutate rev receipt, the `{ok,doc}` claim receipt, `{ok:false,reason}`, the
  workspace-create slug receipt, the publish `{rev,id}`), so a fence there reds every write verb.
  All seven paginated verbs were read LIVE and every honest key is in `listEnvelopeKeys` — measured
  regression on honest reads: **ZERO**.

- **PDS-D397 — THE MUST-RUN COMMAND SET CONTAINED THE VERY BUG THE WAVE IS HUNTING; A CERTIFYING RUN
  MUST MATERIALIZE `origin/main` OUT OF TREE.** `pds-bl-dedup-unavailable-error-code`'s reason says,
  verbatim, "BLOCKER, **re-measured today** rather than quoted: `docs/api-v1.md` is 13,998 bytes …
  2 bytes of headroom". At true `origin/main` the file is **13,884 B — 116 B of headroom**; commit
  `662697194` ("Keep API error guide within budget", ancestor of main) took 113 B out HOURS after the
  reason was written. Running the assignment's own `bash scripts/check-doc-budgets.sh` in the primary
  checkout prints `13997B` — the LOCAL tree, not main. And `git clone --shared` + `git checkout
  origin/main -- .` reproduces the same lie, because `origin/main` resolves to the CLONE's origin.
  **Only `git archive <sha> | tar -x` gave the true 13,884.** A reason that says "re-measured today"
  and is wrong five hours later is precisely the class weight 1 must make falsifiable — and it IS
  checkable, by one `git archive` plus one gate run. (The park SURVIVES in substance: 116 B < the
  390 B the row needs.)

- **PDS-D398 — AN ADJUDICATION NARRATIVE IS NOT AN ADJUDICATION. Three of the digest's four "false
  free closes" were themselves FALSE.** PR **#8412 is MERGED** (2026-07-31T04:44:56Z, merge commit
  `ac80af23e`, an ancestor of origin/main); `render_brief/2` DOES carry the disposition at
  origin/main (`render_doc(%Document{}, :brief)` pipes `put_brief_disposition(content)` at
  `params.ex:280`, defined at :370; the file has **7** `disposition` hits, not 0); and
  `pds-w27-brief-card-disposition` is **10/10, lifecycle done** — it was never in the live set, so
  there was never a close to fabricate. `pds-w27-certify-the-round` HOLDS (0/9, and its required
  certification record is genuinely ABSENT from `tooling/grip/ledger/` while five sibling wave-27
  recipes are present). `pds-w27-round-bare-30` holds in form at 8/10 with both artifacts committed,
  and its remaining criterion 7 is the D392 trap. **Whatever process produced that list read
  narrative rather than state.**

- **PDS-D399 — THE INSTRUMENT MUST NOT EXECUTE CODE IT FOUND IN THE WORKING DIRECTORY, AND THE FIX
  IS PROVEN BY MUTATION.** `pds-ledger-census.sh:291` is `exec python3 - "$@"`, so `sys.path[0]` is
  the CWD. Measured matrix on the UNMODIFIED 106-check selftest: clean CWD unpatched **PASS 106**;
  hostile CWD unpatched **FAILED 103 of 106 with 103 stray executions**; `exec python3 -I -` patched
  → **PASS 106 from BOTH directories, 0 stray executions**. The shadowable surface is **49 names**,
  not one — and **23 of the 49 execute the stray file's top-level code while still exiting 0**, so
  the dangerous case leaves EVERY exit code correct (`--help` rc=0, a usage error rc=3) and only a
  sentinel assertion can see it: this epic's own law, aimed at its own instrument. The selftest has
  **ZERO** isolation coverage today (`grep -ic 'shadow|sys.path|isolat|PYTHONPATH'` = **0**), so
  shipping `-I` alone would make this row's reason exactly the unfalsifiable claim wave 28 exists to
  kill. `-P` is 3.11+ and REFUSED on this host's 3.9.6 — do not propose it. The encoding worry is not
  merely absent but INVERTS: with `PYTHONIOENCODING` unset, `-I` changes stdout not at all
  (md5-identical in every locale); with it set to `ascii`/`latin-1`, the NO-FLAG run CRASHES on an
  em-dash and the `-I` run succeeds. The hazard is worse than the row states: the census is wired
  into **NO** CI workflow, and the standing recipe recorded across five ledger files is
  `cd /tmp && …` — the epic's own recipes prescribe running the certifying instrument from the most
  polluted directory on the host. Reproduced by accident THREE times, once inside this wave.

- **PDS-D400 — TWO NUMBERS THIS WAVE RETIRES FROM CIRCULATION.** The census hash is **sha256**, not
  md5 (`census.sh:641`). And PDS-D383's "a stray `bisect.py` fails ALL 80 checks" is stale in
  quantity — the selftest is **106 checks** today and the stray fails **103**; the same stale 80
  appears in the row's own description and in `tooling/grip/ledger/pds-w27-census-json-honesty-2026-07-31.md:63`.
  Three independent copies of one number that moved and no instrument noticed — a clean live specimen
  for the authored-rerun regime this wave installs.

### Wave 28 plan — 7 slices, all round 1

| task | round | surface | gate |
|---|---|---|---|
| `pds-w28-census-isolation` | 1 | `exec python3 -I -` + the FIRST isolation fixture (106 → 107) | `bash scripts/pds-ledger-census_test.sh` from an EMPTY dir AND from a shadowed one |
| `pds-w28-rerun-adjudicator` | 1 | `tooling/pds/` — grip read-only, variance-skip, absence claims, structured (never exit-code) verdict | `node tooling/pds/rerun-adjudicate.test.mjs` |
| `pds-w28-disposition-rerun-field` | 1 | `stage` gains the fourth durable key + its screen | `CC=clang mix test test/barkpark/tasks/stage_test.exs` |
| `pds-w28-reader-default-page-fence` | 1 | `runCommand` refuses `key == ""` on the DEFAULT read | `CC=/usr/bin/clang go test ./internal/cli/...` |
| `pds-w28-birth-fence` | 1 | `Dedup` sibling + reparent guard + intake born adjudicated | `CC=clang mix test test/barkpark/content/ test/barkpark/tasks*` |
| `pds-w28-oscreate-real-sinks` | 1 | `GetObjectSized` + the 3 real sinks | `CC=/usr/bin/clang go build ./... && go test ./internal/cli/... ./internal/hetzner/...` |
| `pds-w28-residue-18` | 1 | adjudicate the 18 residue rows by CONTENT | census `--json`: `live_bare_residue` shrinks to the named lead-gated remainder |

**HIGH-FLIP-RISK, a genuinely independent second reviewer owed before merge:**
`pds-w28-birth-fence` (reachability + tenancy — the weakest caller is an UNAUTHENTICATED GitHub
webhook, and a wrong verdict turns the inbound bridge into a 500 redelivery storm) and
`pds-w28-oscreate-real-sinks` (blast radius — `GetObject` sits behind a second interface and the
"5 call sites" estimate under-counts by the whole `BundleStore` chain).

**NOT PLANNED AROUND.** `hzResDone` stays cut (D395). The anchor is NOT retired (D392). Clause 1 is
NOT retired (D391). `upgrade.go` is NOT touched (D394). `tooling/grip/**` is NOT modified (D386).
`.github/**` is fenced. `api/mix.exs`/`api/mix.lock` are untouched.
