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

Wave 2 — THE HONEST CLONE (this wave; 6 slices; all builders `opus` per PDS-D38):

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

Wave 3 — lifecycle honest: `bp dev reset` over the Tenancy cascade; snapshot/restore round-trip
byte-identical; delete-reconciliation refresh; streamed bundle channel (task 24913529, unblocked
once wave 2 merges — PDS-D37).
Wave 4 — `bp dev` namespace + repo profiles (`bp dev up|pull|reset|promote`), single-verb pull.
Wave 5 — $29 dev tier via the existing billing gateway (Stripe wiring = human gate).
Wave 6 — agent-fleet sandbox proof: one destructive fleet wave against a PDS, zero writes to
guerrilla. G8 twin sync (secondary-unique identity reconciliation) rides behind W3/W4.

Backlog (filed as published child tasks of the epic): flat-verb `-w` honesty · streamed bundle
channel + import-body streaming · delete-reconciliation refresh · G8 secondary-unique identity
reconciliation · `bp dev pull` single verb · CI scratch-target HTTP round-trip job · per-member
savepoint import error honesty · **wave-2 additions:** Bootstrap S3 cross-tenant workspace theft on
nil-`dataset_id` rows · `/v1/data/counts` silently ignores `?perspective` (213 draft rows
invisible) · `docs/setup/personal-local.md` staleness (D34's five traps documented nowhere) ·
`plugin_doc_state` unreviewed `:copy` classification · pin the `webhook_deliveries` E2 INNER JOIN
as a security invariant · no admin-token mint path on a fresh `bin/barkpark up` box · `bp search`
verb absent from this CLI build.

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
