# API Content & Render-Engine Correctness Audit — Epic Charter

Epic task: `api-content-render-correctness-audit` · Wave 1 Paper: `api-content-render-correctness-wave-2026-08-18`

## Vision

A Felix-style Phoenix/Ecto **correctness** audit (non-security, improvement-only, evidence-based) of the two hottest engines in the product: the document write/publish/dedup/revision pipeline (`api/lib/barkpark/content`) and the PortableDoc render tree (`api/lib/barkpark/portable_doc`). The deliverable is an honest **per-class robustness verdict** across four classes — Ecto efficiency/correctness, render-tree robustness, publish/dedup correctness, error handling — where each class is either a confirmed bug fixed fail-safe and mutation-proven, or filed with a concrete failing scenario, or a cited SAFE verdict naming why the pattern already holds. The denominator is the deliverable: zero confirmed in a swept-and-cited class is an A-grade, and **nothing is manufactured**. Fence: `api/lib/barkpark/content` + `api/lib/barkpark/portable_doc` and their `api/test` trees ONLY — disjoint from the cloud correctness wave (`cloud/`) and the Studio LiveView wave (`api/lib/barkpark_web/live`).

## Decisions

- **The wave is deliberately LEAN — one built fix, two filed findings, six classes cited SAFE.** Why: twelve surveyors + five verifiers swept both trees on today's origin/main and the mature-codebase premise held. Felix + the cloud/security waves already closed most of this surface; manufacturing more slices would violate the wish's explicit "do not manufacture a finding."

- **BUILD the render-children degrade guard as fail-safe hardening of a PUBLIC entry, NOT as a today-500 fix.** Why: verifier A1 refuted the reader-crash crown as reachable — every content reader composes-first (`render_blocks`/`render_block`/`render_document`), which coerces author `"children":null` to `[]`, so no reader route raises. BUT the raise is structurally real on the PUBLIC `Render.render_html/2` and `Walk.render_body/3`: `render_children/3` and `paragraph_inner/3` (walk.ex:1599/1609) do `children |> Enum.map(...)` with no `is_list` guard, and `Map.get(n,"children",[])`'s default fires only on an ABSENT key — a present `"children":null` flows in as `nil` and `Enum.map(nil)` raises `Protocol.UndefinedError`. This violates the module's own stated `# DEGRADE, never raise` invariant (walk.ex:160-175). The fix mirrors that invariant, is offline-mutation-provable, and cannot regress (it only changes behavior on inputs that currently RAISE). It is correctness-adjacent robustness, not tree-tidiness.

- **FILE the dedup TOCTOU — do not build it.** Why: verifier A2 confirmed the CHECK (`AuthoringWall.enforce`, lifecycle.ex:145) runs outside/before the publish `Repo.transaction` (lifecycle.ex:173) with no serializing lock, and the paper-birth path (block_ops.ex) shares the same cross-doc_id race despite a per-slug advisory lock. HONEST severity is a **quality-gate bypass** (a valid duplicate PAIR of published rows, cross-doc_id only) — NOT the "durable/schema corruption" the direction framed; the persisted rows are valid. The fix is a design change (a scope-keyed `pg_advisory_xact_lock` serializing publishes) with no offline-mutation-provable slice (needs a concurrent-transaction race harness). HIGH-FLIP write path → independent second review before any future build. Distinct from the already-closed dedup fail-open (#8406).

- **FILE the publish-atomicity gap — do not build it — and note it BROADENS beyond publish.** Why: verifier A3 confirmed `save_revision`/`save_event` (broadcast.ex:337/310, Repo.insert / Repo.insert!) run POST-COMMIT, outside the publish txn (called at lifecycle.ex:202), and the same gap is present on the writer single-write path (`upsert_document`/`create_document`) reached by ~20 direct callers including the request-reachable `POST /api/documents/:type` (legacy_controller.ex:115). The broadcast.ex invariant comments claiming txn-atomicity are TRUE only for the `apply_mutations` batch path, FALSE for publish/single-write. Bounded blast (derived rows: revision + mutation_event/SSE, not the published row), low reachability (needs a fault between commit and the derived inserts). A mutation-proof needs DB fault injection, not a unit test. HIGH-FLIP → independent review; a naive txn-wrap must keep `save_revision` non-fatal (savepoint) while making `save_event`'s raise roll back. The task also carries the correction of the misleading invariant comments.

- **DROP the recursion class — measured DEAD, no task.** Why: verifier A4 ran the walkers at 3M depth (both complete <1s; BEAM grows the stack on the heap) and proved Jason itself is uncapped (decodes 1M-deep/30MB as `:ok`), so max achievable depth (~3.3M within the 100MB byte cap) is fail-safe. The survey's "Jason gates first" assumption was refuted, but the safety verdict holds by a different mechanism (BEAM absorbs it). No fileable finding.

- **Six classes swept SAFE-and-cited, zero confirmed, no tasks:** revision-chain (append-only immutability trigger + `ON DELETE SET NULL`), N+1 (render tree zero Repo calls; `expand` batched #5471; `task_resolver` memoizes), uuid-cast-guard (both request-reachable binary_id reads guarded via `Repo.uuid_or_nil` / CastError rescue), changeset-gaps (`validate_required` matches NOT-NULL cols; unique_constraint name matches live index), with-chain error handling (closed dispatch, terminal `{:error,:malformed}`), rescue-swallow (25 sites narrow/logged/reraise; the 2 candidates are dead on the production path). Why record them: the per-class denominator IS the A-grade artifact — a swept-and-cited SAFE class is a result, not a gap.

## Roadmap

**Wave 1 (this run) — build 1, file 2, cite 6.**

- `acrc-w1-render-children-nil-guard` — BUILD, round 1, opus, small. Guard `render_children/3` + `paragraph_inner/3` in walk.ex with `when not is_list(children) -> ""`; extend `render_tolerance_test.exs` with raw-Pd-tree `children:null` + scalar-children cases for every children-bearing kind (the harness currently exercises only the compose-first `render_blocks` path — the raw-tree entry was the rig's blind spot). Gate: `cd api && CC=/usr/bin/clang mix test test/barkpark/portable_doc/render/render_tolerance_test.exs`.

**Filed for a future write-path-atomicity wave (design + independent review, not offline-buildable):**

- `acrc-dedup-toctou-serialize` — scope-keyed advisory lock serializing publishes across (type, workspace/dataset); race harness to demonstrate the double-insert. HIGH-FLIP.
- `acrc-publish-atomicity-txn-boundary` — move `save_revision`/`save_event` inside the write txn (savepoint-protect the non-fatal revision insert; let `save_event`'s raise roll back), correct the false invariant comments; DB-fault-injection regression. HIGH-FLIP. Covers the writer single-write path, not just publish.

**Coverage gaps carried forward (no deficit this wave):** every survey + verify agent reported. One corner named but out of fence — `MutateController` status-mapping (`barkpark_web`) — belongs to a barkpark_web audit, not this correctness fence.

## Wave log

- (empty)
