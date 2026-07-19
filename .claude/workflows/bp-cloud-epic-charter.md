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

## Roadmap

Wave 1 — data plane honest (this wave; 8 slices; ROUNDS ARE LAW):

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

Wave 2 — lifecycle honest: `bp dev reset` over the Tenancy cascade; snapshot/restore round-trip
byte-identical; delete-reconciliation refresh; streamed bundle channel.
Wave 3 — `bp dev` namespace + repo profiles (`bp dev up|pull|reset|promote`), single-verb pull.
Wave 4 — $29 dev tier via the existing billing gateway (Stripe wiring = human gate).
Wave 5 — agent-fleet sandbox proof: one destructive fleet wave against a PDS, zero writes to
guerrilla. G8 twin sync (secondary-unique identity reconciliation) rides behind W2/W3.

Backlog (filed as published child tasks of the epic): flat-verb `-w` honesty · streamed bundle
channel + import-body streaming · delete-reconciliation refresh · G8 secondary-unique identity
reconciliation · `bp dev pull` single verb · CI scratch-target HTTP round-trip job · per-member
savepoint import error honesty.

## Wave log

(empty — Review appends per-wave entries here)
