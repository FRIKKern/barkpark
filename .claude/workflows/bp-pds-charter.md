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

Wave 3 — THE CROWN PROOF (THIS WAVE; 6 slices; PROOF-FIRST per D39; every builder opus
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
- R2 `pds-w3-full-fidelity-shares-gap` (opus, M; after crown-proof establishes the baseline):
  close D45 — bare-slug E3 rows under a cross-tenant-shared slug are silently dropped from a
  "byte-identical" backup.

Wave 4 — lifecycle honest: `bp dev reset` over the Tenancy cascade; snapshot/restore round-trip
byte-identical; delete-reconciliation refresh; streamed bundle channel (task 24913529, unblocked
once wave 2 merges — PDS-D37).
Wave 5 — `bp dev` namespace + repo profiles (`bp dev up|pull|reset|promote`), single-verb pull.
Wave 6 — $29 dev tier via the existing billing gateway (Stripe wiring = human gate).
Wave 7 — agent-fleet sandbox proof: one destructive fleet wave against a PDS, zero writes to
guerrilla. G8 twin sync (secondary-unique identity reconciliation) rides behind W4/W5.

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

## Wave log

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
