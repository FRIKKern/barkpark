# Attic Manifest — docs-refactor 2026-06

Wave 0 freeze. One row per attic candidate. Checked box = rescue committed to new home.
Gate: no file may move while its row is unchecked.

**Frozen-path note (A1):** `docs/spec/bokbasen-api-contract.md` and `docs/ops/studio-nav-bug-2026-04-19.md` are PATH-FROZEN (cited by code: client.ex:5, auth.ex §2.2, e2e_test, elixir.yml, Makefile, deploy.sh, runtime.exs, dataset_cors.ex) — removed from attic-21 list; kept at current paths.

**Freeze rationale (A7):** `docs/cli/fixtures/*.json` (`core-manifest-anon.json`, `core-manifest.json`, `full-manifest.json`) are load-bearing for Go tests (`manifest_test.go`, `cli_test.go`) — NOT attic candidates; must never move.

---

## MD attic candidates (19)

| Old path | Irreplaceable facts (copy-exact literals) | Designated new home | Done |
|---|---|---|---|
| `docs/SETUP-WITH-PAPERFLOW.md` | 7-check gate, 6-phase flip, rollback guarantee | `docs/setup/paperflow-cutover.md` | [ ] |
| `docs/dev/bokbasen-local-setup.md` | env-first-then-DB order, secrets/-placement rationale, no-secret-scanner gap | `docs/contracts/bokbasen.md` (creds section) | [ ] |
| `docs/cli/M0-signoff.md` | nine-nouns→eight error (fix before attic); exit-codes-6/7/8 decision already in error-exit-table | `docs/cli/error-exit-table.md` (already there) | [ ] |
| `docs/cli/cli-commands-callback.md` | scoped_admin no-blanket-hide; content-addressed tier-projected ETag rules; two contract rules; existence-hiding projection rules | `docs/cli/m0-decisions.md` | [ ] |
| `docs/plugins/HIGHWAY.md` | MUST/MUST-NOT list; forbidden-surfaces rationale; fresh-install invariant; route buckets (:token_root/:ingest/:public_root); App. B .beam gotcha (compile-cache); App. A history → attic only | `api/lib/barkpark/plugin.ex` @moduledoc + `docs/cards/plugins.md` | [ ] |
| `docs/plugins/ARCHITECTURE.md` | schema-metadata column table; UI/CSS/route bans | `api/lib/barkpark/plugin.ex` @moduledoc | [ ] |
| `docs/plugins/GUIDE.md` | callback decision table; additive-vs-resolver pattern | `docs/cards/plugins.md` (digest) + `api/lib/barkpark/plugin.ex` @moduledoc | [ ] |
| `docs/plugins/RECIPE.md` | rides-OnixEdit-schema constraint note; prod verify curl; tasks.ex as living example replaces RECIPE | `docs/cards/plugins.md`; prod verify curl → `docs/ops/PROD_OPS.md` | [ ] |
| `docs/plugins/INSTALL.md` | no-deletion-in-v1; late-registration console note; never-reintroduce-mix-run rule | `docs/cards/plugins.md` | [ ] |
| `docs/plugins/INTEGRATION_LESSONS.md` | codelistId 93 errata; Adapter.resolve_plugin bug; anti-patterns digest; deleted-LOC table | `docs/contracts/onix-field-map.md` (codelistId 93) + `docs/cards/plugins.md` (anti-patterns digest, 2 lines) | [ ] |
| `docs/plugins/SCHEMA_V2.md` | Decisions 7/20/21; flat_mode permanence; Phase 0/1+ boundary | `docs/contracts/schema-v2.md` | [ ] |
| `docs/plugins/BULLDOCS-MIGRATION.md` | paper-noun decision; alias-drop gate (/v1/paperflow alias-drop externally gated on paperflow event-on-save.sh repointing) | `api/CLAUDE.md` + `docs/decisions/deferred.md` | [ ] |
| `docs/spec/bokbasen-onix-pre-flight.md` | T3/T5-T8, F9/F10; partner-PDF source table | `docs/contracts/bokbasen.md` | [ ] |
| `docs/spec/onix-export-mapping.md` | nob/NO/NOK rationale; RecordReference global-uniqueness rule; codelistId 162→86 erratum; Q1–Q5 log | `docs/contracts/onix-field-map.md` | [ ] |
| `docs/spec/onixedit-masterplan-summary.md` | D12/D21/Q1; sentinel http_status:200; :cancelled reasoning; concurrent-write re-fetch; Task #12 deploy gate | `docs/contracts/bokbasen.md` | [ ] |
| `proof/onixedit-full-demo.md` | credential-redaction rule (refute ~r/bokbasen\.no/i, test_* prefixes) | `docs/contracts/bokbasen.md` | [ ] |
| `docs/ops/npm-retag-runbook.md` | Boss-approval P0 gate; split-state rollback; 404-is-intentional; ADR-divergence note | `docs/ops/npm-rollback-playbook.md` | [ ] |
| `docs/ops/caddy-api-tls.md` | pitfalls list; Caddy-over-Phoenix rationale | `docs/ops/adding-a-domain.md` | [ ] |
| `docs/ops/research/realtime-gap-analysis.md` | option-1-over-2/3 rationale; four-point trace | `docs/decisions/0003-sync-tags.md` | [ ] |
| `docs/search/PLAN-PHASES-6-10.md` | design-principle constraints; skip rationale; P9/P10 triggers | `docs/search/INTELLIGENCE.md` + `docs/search/ROADMAP.md` | [ ] |
| `docs/ops/shakedown/w4-api-studio.md` | perspective baselines (delete-requires-type resolution to be recorded in api-v1.md first) | attic only | [ ] |

---

## Non-MD residue (A7)

| Old path | Notes | Designated new home | Done |
|---|---|---|---|
| `proof/onix-sample.xml` | ONIX XML sample used in demos; attic with parent `proof/onixedit-full-demo.md` | `_attic/docs-2026-06/` | [ ] |
| `proof/task-38/` (4 files: `allow_with_flag.txt`, `block_no_flag.txt`, `syntax.txt`, `unsafe_still_blocked.txt`) | smoke-test outputs; attic with parent shakedown docs | `_attic/docs-2026-06/` | [ ] |
| `docs/ops/shakedown/remediation-b-smoke/` (3 files: `build.log`, `dev.log`, `install.log`) | remediation smoke logs; attic with parent `docs/ops/shakedown/w4-api-studio.md` | `_attic/docs-2026-06/` | [ ] |
