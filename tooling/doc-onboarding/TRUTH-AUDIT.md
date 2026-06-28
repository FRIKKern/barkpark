<!-- doc-tier: human | canonical-for: doc-truth-audit-report | budget: 9000tok -->

# Documentation TRUTH-AUDIT

A claim-by-claim verification sweep across the repo's Markdown/MDX surface. Every issue below was **confirmed against source** (code line, config, git history, or a live tool run) before being recorded — nothing here is a guess. Auto-fixable docs were edited in place; governance docs (CLAUDE.md / AGENTS.md / SKILL) were left untouched and are flagged for human sign-off.

## 1. Headline

| Metric | Count |
|---|---|
| Files audited (had ≥1 confirmed issue) | **102** |
| Confirmed false / stale / misleading / unverifiable claims | **250** |
| Auto-fixed in place | **234** |
| Report-only (NOT auto-edited, need human sign-off) | **16** (across 7 governance files) |

Note on "claims checked": this dataset enumerates only the **confirmed** defects. The audit read far more claims than 250 to surface these; the broader denominator (claims that verified clean) is not captured row-by-row in this report. Treat 250 as the confirmed-defect count, not the total inspected.

Kind breakdown of the 250: `false` (claim contradicts source), `stale` (was true, code moved on), `misleading` (technically defensible but the reader is led wrong), `unverifiable` (no source path could confirm or refute — softened to a note, never asserted-true).

The 16 report-only issues are all left unedited by design: they live in `CLAUDE.md`, `AGENTS.md`, `api/CLAUDE.md`, `js/CLAUDE.md`, `web/CLAUDE.md`, `web/AGENTS.md`, and `.claude/skills/codebase-quality/SKILL.md` — files that steer agents and humans, where an unreviewed edit is itself a risk. See §3.

## 2. Confirmed issues, grouped by file (auto-fixed)

All rows in this section were applied to disk (`fixed: yes`). Claim and "what's true" are abbreviated; the doc edits carry the full corrected text.

### api/assets/paper-editor/EMBED-CONTRACT.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `bp-slash-insert` shape `{type,afterId,fieldName?}` | misleading | med | Callout shorthand path also emits `tone`/`collapsible`/`collapsed`; split into two rows |

### api/priv/onix/onix-3.0/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| Header comment block is lines 1–60 | misleading | low | Comment runs to line 286; revision history spans 59–284 |
| WI8 fixture is the Phase-7 *input* artefact | misleading | low | It is the committed *output* (regression guard from `full-book.json`) |

### api/priv/plugins/media/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| registers `media_file` document type | false | high | Registers `mediaAsset` + `mediaCollection`; `media_files` is a storage table |

### apps/hundesteder/BRIEF.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| 12 dog-breed themes | false | med | Exactly 10 named themes in `pawtrails-palettes.css` |

### cloud/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `runtime.exs` raises without `WORKER_TOKEN` + Stripe keys | false | high | `WORKER_TOKEN` optional at boot (fails closed via 401); only DB_URL/REGISTRY_KEY/STRIPE_SECRET raise |
| **Sites** is a standalone context | misleading | med | No `Sites` module; sites/deployments live in `Registry` |

### deploy/systemd/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| timer fires 03:00 **UTC** | misleading | low | `OnCalendar=Mon 03:00:00` has no TZ; resolves to local time |

### deploy/uptime-kuma/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| Replace `$ADMIN_TOKEN`… | misleading | med | No monitor uses a token; instruction is orphaned |
| Monitor 2 covers DB+schema as distinct check | misleading | med | Byte-for-byte duplicate of Monitor 1 |

### docs-site/ops/adding-a-domain.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| Stub kept; studio-nav-bug cites this path | false | low | That doc cites `docs/ops/…`; zero refs to the docs-site stub |

### docs-site/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| Regenerated on every push to main | false | med | Path-filtered trigger (`js/packages/**`, `tooling/typedoc/**`) |
| Track A Fumadocs reads it at build | unverifiable | med | No wiring; `js/docs` reads `content/docs/` only — softened to aspirational |

### docs/api-v1.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| CORS open `*` on all `/v1` | false | high | Per-dataset allow-list, fail-closed, never wildcards |
| rev mismatch → 409 `rev_mismatch` | false | high | Returns 412 `precondition_failed`; 409 path is dead code |
| Mutation frame has 7 fields | misleading | med | Always carries `syncTags` too |
| `previousRev` populated for updates | misleading | low | Always `null` in live events; populated only on replay |

### docs/api/error-envelope-migration.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| Plug wired into 6 pipelines | stale | med | Wired into 10 (4 omitted) |

### docs/auth.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `write` perm covers `POST /media/upload` | misleading | med | Media upload needs token validity only, not `write` |

### docs/cards/cli.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| 14-case builtins switch | stale | high | ~29 cases; doc lists ~50% subset |
| `func hint` anchor | misleading | low | It's a method `(apiError).hint`, not a func |
| 8-code exit ladder | misleading | low | 9 codes (0–8) |

### docs/cards/js-sdk.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| web/ deliberately NOT wired to `@barkpark/nextjs` | false | med | It's an explicit dep, wired+gated via `<BarkparkLive/>` |

### docs/cards/onix-bokbasen.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| 3-stage validation | false | med | Single `validate_xsd/2` (xmllint) |
| Oban concurrency=1 | false | high | `bokbasen: 4` in config.exs |

### docs/cards/plugins.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| listed in `registry.ex` | false | high | Auto-discovered via `priv/plugins/<name>/plugin.json` disk walk |

### docs/cards/search-media.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `media_retriever.ex` rides the search seam | false | med | File doesn't exist; media retriever is a separate Delivery module |

### docs/cards/studio.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| File is ~4,800 lines, don't read whole | stale | high | Shell is 291 lines (decomposed into ~25 files) |
| core Studio rides `:admin_studio` | false | high | StudioLive rides `:scoped_studio`; admin_studio mounts only Settings |

### docs/cards/tui.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `structure.go` desk `/v1/structure` | misleading | low | Route requires `/:dataset` segment |
| A4-portrait column | unverifiable | low | Width-capped column (max 100 chars); no A4 — softened |

### docs/cheatsheets/bp.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `--set`/`--file -` are globals | false | med | Body flags resolved post-verb, not global |
| 8 exit codes listed | false | low | Code 1 (generic/network) omitted; 9 total |

### docs/cheatsheets/papers.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `{body_html}` publish form | false | med | Requires `slug` too |
| `--theme dark\|light` | misleading | low | `auto` is the default third value |
| `--perspective drafts\|raw` | misleading | low | `published` is the default third value |

### docs/cheatsheets/tasks.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| Create via mutate (admin) | misleading | med | `write` OR `admin` suffices |
| 6 task.* SSE events | misleading | low | `task.compacted`/`compaction_restored` also emitted |

### docs/cheatsheets/tui.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| edits autosave to `drafts.<id>` | false | high | No autosave; only `ctrl+s` saves, else discarded |
| `bp setup --target connect` connects once | misleading | med | Needs `--server <url>` for first-time users |

### docs/cli/error-exit-table.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `already_claimed` is a 409 server reason | misleading | med | CLI-only mapping; API never emits it |

### docs/cli/HANDBOOK.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| cross-compiles 4 binaries | false | med | 6 binaries (darwin/linux/windows × arch) |
| 6 task verbs | false | high | 7 verbs — `prime` omitted |
| no `context use`, not persisted | false | high | `bp use <name>` implemented + persisted |

### docs/cli/m0-decisions.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| schema-hash from `/v1/meta` surfaced | false | med | Parsed but never output by `runWhoami` |
| 4 bundled plugins | stale | med | 6 (adds `sheets`, `tasks`) |

### docs/contracts/bokbasen.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `signed_off` override unless caller passes false | false | med | `derive_signed_off/1` always wins; no override |
| emits Blocks 1+2+3+4 | false | med | Emits blocks 0–12 by default |

### docs/contracts/onix-field-map.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| Header has MessageNumber + DefaultLanguageOfText | false | high | Emits Sender/SentDateTime/MessageNote only |
| opts `:sender`/`:default_language`/`:message_number` | false | high | Only `:dataset`/`:sent_at`/`:dataset_host` exist |
| `bcp47_to_iso6392b/1` entry fn | misleading | med | It's `defp` (private) |
| `build_unpriced` entry fn | misleading | low | Private helper; public entry is `build/2` |

### docs/contracts/schema-v2.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| seeds.exs lines 609–654 | false | high | seeds.exs is 6 lines; real code in `seeds/demo.ex` |
| fallbackChain default `[nob,eng,first-non-empty]` | false | med | Defaults to `[]` |
| `"any"` is an alias | false | med | Only `first-non-empty` sentinel exists |
| cross-field evaluator live in Phase 0 | stale | med | Inert in Phase 0; eval deferred to Phase 3 |

### docs/contracts/tenancy.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `Content.scope_to_dataset/3` | false | med | Lives on `WriteScope`; `Content.` call raises |
| `dataset` column list (exhaustive) | misleading | low | Omits `mutation_events` |

### docs/contracts/webhook-realtime.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| 5 events invalidate tags | false | med | 6 dispatched (+`discardDraft`); `patch` valid in model |
| handler rebuilds `_all` only when sync_tags missing | misleading | low | Always additive (Set-deduped) |

### docs/decisions/0001-sdk-envelope.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| Fixtures fail PRs breaking `result`-unwrap | false | med | Fixtures are flat; `result`-nested path has zero coverage |
| `client.ts` envelope read path | misleading | low | Unwrap is in `doc.ts`/`docs.ts`; client delegates |

### docs/decisions/0003-sync-tags.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| ADR-0001 governs no-store/next.tags rule | false | med | It's ADR-004 (JS-side) |
| sync_tags "falls back" to field tags | misleading | low | Always-additive, deduped |
| dispatcher_test pins the list | misleading | low | Membership assertions, not full-list pin |

### docs/decisions/deferred.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| error envelope v2 still deferred | stale | med | Shipped + wired in 10 pipelines |

### docs/framework-guides/nextjs/draft-mode.mdx
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| reissuePreviewToken = same as previousSecret | misleading | low | One is async callback, other a static string |

### docs/framework-guides/nextjs/image-loader.mdx
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| import `ImageAssetRef` from `@barkpark/react` | false | high | Not re-exported; internal type |
| warns once in dev via `onMissingBaseUrl` | misleading | med | Warns all envs; callback is an override hook |

### docs/framework-guides/nextjs/index.mdx
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| hydrates previews without a refresh | false | med | Calls debounced `router.refresh()` per SSE event |
| fans out canonical flat tags | misleading | med | Scoped `bp:ws:…:p:…` form when ws+project set |

### docs/framework-guides/nextjs/portable-text.mdx
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| works identically in Server+Client | misleading | med | `'use client'` at source — always a client boundary |

### docs/framework-guides/nextjs/preload-pattern.mdx
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| module is server-only | false | low | No `server-only` guard |
| per-request, module-scope safe | misleading | med | In-flight Map caches across requests; unsafe for draft no-store |

### docs/framework-guides/nextjs/revalidation.mdx
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `revalidateBarkpark('p1')` revalidates a doc | false | high | Bare string is a silent no-op |
| `{_id,_type}` / `{ids,types}` examples work | false | high | No-op without `dataset` |
| delivery carries `_id`/`_type` → 2 tags | false | high | Canonical is `type`/`doc_id` → 3 tags (incl `_all`) |
| tag table (flat only) | misleading | med | Scoped shape used when ws+project set |
| onMutation cast to `{_id,_type}` | misleading | high | Cast matches nothing; pass full payload |

### docs/framework-guides/nextjs/server-actions.mdx
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| codegen schemas have `.parse()` | false | high | codegen emits interfaces (erased at runtime), no validator |
| fans out canonical flat tags | misleading | med | Scoped shape when ws+project configured |

### docs/framework-guides/nextjs/server-components.mdx
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| only auto tag is dataset-wide | misleading | med | Also auto-adds type + doc tags |

### docs/framework-guides/nextjs/setup.mdx
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| destructure `BarkparkLive`/Provider from server | false | high | Server returns `{barkparkFetch, defineLive}` only; import Live from `/client` |

### docs/INDEX.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| Contracts list | misleading | med | Omits `contracts/tenancy.md` (actively routed) |
| Runbooks list | misleading | low | Omits `ops/vercel-dns-connect.md` |
| Setup list | stale | low | `CLOUD-QUICKSTART.md` added post-snapshot (noted) |
| no docs/api/ listing | stale | low | `error-envelope-migration.md` uncategorized (noted) |

### docs/learn/plugins-catalog.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| sheets import/export xlsx·csv·tsv·md·html | misleading | med | md/html are export-only |
| frt = Godot demo/example | misleading | low | Production content model (25 schemas) |

### docs/learn/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| two perspectives | misleading | low | Three: published/drafts/raw |

### docs/ops/barkpark-cloud-go-live.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| provisioner builds `--type cax11` | false | high | Default is `cx23` (cax out of stock) |
| won't boot without WORKER_TOKEN | false | med | Optional at boot (fails closed) |
| `bp ssh/logs/rebuild/backup` operate it | unverifiable | low | Not found as builtins — softened |

### docs/ops/bokbasen-go-live.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| flow `draft→queued→…` | false | high | `pending→staging→staged→polling→accepted`; no draft/queued |
| `Status.write(doc,…)` after get_document | false | high | Needs `{:ok, doc} =` destructure (else FunctionClauseError) |
| Bokbasen rate limit 1 req/s | misleading | med | Bokbasen publishes none; configurable floor, off by default |

### docs/ops/merge-gates.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| mix-test is advisory (continue-on-error) | stale | high | Blocking since 2026-06-10 |
| PR #43 SHA `be53a98` | false | low | Actual `966fcd98` |
| only `*.md` triggers doc-gates | misleading | low | Also `.ex/.exs/.go/.ts/.tsx` |

### docs/ops/npm-rollback-playbook.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| retag.yml on main only | false | high | No branch filter; any branch |
| guard refuses preview/next | misleading | med | Skips with warning, exits 0 (succeeds) |
| see `docs/adr/0002-…-publish.md` | stale | low | Canonical at `docs/decisions/0002-npm-dist-tag.md` |

### docs/ops/PROD_OPS.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `git checkout -- bin/barkpark go.mod` | stale | med | Dirty file is `go.sum`, not `go.mod` |

### docs/ops/realtime-webhook-setup.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| dispatcher/handler wire-incompatible (401) | stale | high | Reconciled; combined header shipped |
| 5 events | misleading | low | +`discardDraft`/`patch` |
| route re-exports `createWebhookHandler` | misleading | low | Calls it, exports returned `{POST,GET}` |

### docs/ops/studio-nav-bug-2026-04-19.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| deploy.sh:118 writes PHX_HOST | false | low | Line 115 (118 is heredoc delimiter) |
| deploy.sh:123–128 preserve logic | misleading | low | Else branch is 119–124 |
| caddy-api-tls.md:196 | stale | med | Moved to `_attic/…:197` |
| runtime.exs:56 host fallback | stale | med | Pre-fix; now raises (lines 288–312) — noted |
| runtime.exs:61 url tuple | stale | med | Now line 356 + explicit check_origin — noted |
| handlers present at studio_live.ex:189–509 | stale | low | Pre-refactor; now 291 lines — noted |
| belt-and-braces not applied | stale | med | Applied in expanded form (347–356) — noted |

### docs/ops/vercel-dns-connect.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `BARKPARK_API_TOKEN` | false | high | Real var is `BARKPARK_READ_TOKEN` |
| `@barkpark/nextjs/webhook` verifies | false | med | Inline `node:crypto`, no SDK import |
| `BARKPARK_DATASET=production` | stale | med | Defaults to `docs`; must match webhook |
| `NEXT_PUBLIC_SITE_URL` | false | med | Read nowhere in web/ — row deleted |

### docs/PHILOSOPHY.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `bp go-live` → pay once | false | high | Subscription model; `bp subscribe` required first |
| basic backup scripts (OSS) | unverifiable | med | No backup script in repo — softened |
| docs cover Mac mini + manual Ubuntu | misleading | low | No such dedicated guides — reworded |

### docs/plugins/codelists-byo.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| exit-1 if `seed_bundled/0` unwired | misleading | med | Exit-1 fires purely on absence of 3 BYO sources |

### docs/search/INTELLIGENCE.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `Barkpark.Media.SearchIntelligence` | false | high | Module is `Barkpark.Search.MediaIntelligence` |
| media insights lacks synonymCandidates | false | med | Both surfaces return it |

### docs/search/ROADMAP.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| crystal-backed recent/popular/nohits | misleading | low | `recent` is raw events (actor-scoped), not crystal |

### docs/setup/SETUP.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| paper registered 3× | misleading | med | 2× on fresh install |
| Studio at `/studio`; `/` redirects there | misleading | low | Both redirect to scoped `/w/…/studio` |
| no `/health`; use `/api/schemas` | misleading | low | `/api/schemas` is deprecated (Sunset 2026-12-31) |

### docs/setup/TASK-SYSTEM.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| 6 task verbs | false | med | 7 (+`prime`) |
| 6 task.* events | false | med | +`compacted`/`compaction_restored` |
| mutate needs admin token | false | med | write OR admin |

### docs/setup/WINDOWS.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `ImageBackend` shells out to magick | misleading | med | The `.Magick` submodule does; parent is behaviour |
| scoop installs 3 packages | false | med | 4 (+imagemagick) |
| Tested OTP28/Elixir1.20/PG18 | unverifiable | low | No version pins in repo — kept as intent note |

### docs/snippets/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| Type-checked in docs CI | false | high | No CI covers `docs/snippets/` |
| included in MDX via Fumadocs include | false | med | No include directive exists |
| `pnpm typecheck` covers docs | misleading | high | `docs/snippets/` not in js pnpm workspace |
| `BARKPARK_PREVIEW_SECRET` row | false | low | Used by zero snippets — row deleted |

### docs/spec/bokbasen-api-contract.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| emits Blocks 1+2+3+4 (×2) | false | high | Blocks 1,2,4,6 |
| via `Export.export/2` | false | med | Worker calls `to_iodata/1` (XSD-gated) |
| queue `:bokbasen_publish` conc=1 | false | med | `:bokbasen` conc=4 |
| credential table (audience/env) | stale | med | 5 real vars incl `BOKBASEN_CLIENT_ROLE`; no audience/env |
| §8.3 fixture tree | stale | low | Flat layout shipped instead — noted |

### docs/studio/user-guide.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| Studio at `/studio/<dataset>` | misleading | low | Scoped mount; flat form 302-redirects |
| doc_id from RecordReference (1 fallback) | misleading | low | Third fallback: random `imported-<n>` |
| both cross-validations are errors | misleading | low | `price_currency_required` is a warning |

### docs/studio/web-components.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| hook defined in studio_live.ex | false | high | Defined in `root.html.heex:3419` |
| script BEFORE phoenix_live_view.js | misleading | low | Heading/body name different files (both true, inconsistent) |

### js/.github/pull_request_template.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| no node: imports (hard gate) | misleading | med | Check is advisory (continue-on-error) |
| `pnpm size` no >2% regression | false | med | Absolute KB caps, no percentage |

### js/CONTRIBUTING.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `changeset-check` job | false | low | Job id is `changesets` |
| CI fails on >2% regression | false | med | Absolute KB limits |
| `check-no-node-imports.sh` enforced | false | high | Advisory (continue-on-error, ADR-002) |

### js/docs/content/docs/concepts.mdx
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| unauth read → 404 `schema_unknown` | false | high | Returns `not_found`; `schema_unknown` never emitted |
| create-draft conflict "unless ifRevisionID matches" | misleading | med | No success path; ifRevisionID → 412, still fails |

### js/docs/content/docs/getting-started.mdx
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `git clone …/frikkb/barkpark.git` | false | high | Org is `FRIKKern` |
| Elixir 1.17+ | false | med | mix.exs floor is `~> 1.15` |
| `?perspective=drafts` (no token) | false | high | Anonymous pinned to published; needs Bearer |
| envelope `rev` | false | low | Key is `_rev` |

### js/docs/content/docs/reference/errors.mdx
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `cors_forbidden`/`forbidden_origin` raised | false | high | CORS plug passes through / 204; never raises envelope |
| `"*"` in cors_origins allows all | false | med | `*` matches no valid origin (fail-closed) |
| empty union allows all origins | misleading | med | Only 3 platform defaults pass |
| `schema_unknown` raised | false | high | Never emitted; returns `not_found` |

### js/packages/codegen/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| see `docs/adr/` | false | low | No ADR dir in js/ — sentence deleted |

### js/packages/create-barkpark-app/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `barkpark codegen` | false | high | Subcommand is `generate`; codegen doesn't exist |
| `barkpark demo eject` | false | high | No demo/eject subcommand |

### js/packages/create-barkpark-app/templates/blog-starter/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| default token `barkpark-dev-token` | false | high | `.env.example` ships `changeme-barkpark-dev-token` |
| flat tag shape | misleading | med | Scoped shape on default (ws+project=default) |
| see local `docs/auth.md` | misleading | low | Only in upstream repo, not generated project |

### js/packages/create-barkpark-app/templates/website-starter/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `{{pmCommand}} codegen` | false | high | `barkpark codegen` doesn't exist; codegen not in deps |
| token `barkpark-dev-token` | misleading | med | `.env.example` ships `changeme-` prefix |
| see `docs/auth.md` | unverifiable | low | No docs/ in generated project — note |
| see `docs/contracts/webhook-realtime.md` | unverifiable | low | Same — note |

### js/packages/nextjs/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `./client` → BarkparkLive only | misleading | low | Also Provider, startLiveSubscription |
| `./server` → createBarkparkServer, defineLive | misleading | low | Also standalone `barkparkFetch` — noted |

### js/packages/react/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| all three server-component friendly | false | high | `BarkparkReference` is client-only (createContext) |

### js/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| 5 packages GA | misleading | med | All at `1.0.0-preview.x` |
| `cd js && pnpm install` | misleading | med | Needs `&& pnpm build` |

### js/SECURITY.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| see `api/docs/adr/` | stale | med | That's a cold stub; live ADRs in `docs/decisions/` |
| @next supported, @preview testing-only | misleading | med | `pre.json` tag=preview is the active channel — noted |

### packages/client/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| pin to v0.0.83 | false | med | Package only ever at v0.0.1 |

### README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| Cody scorecard 83/100 | stale | high | Live report: 81; Hotspots/Modularity/Bloat/Aesthetics all lower |
| Lowest: Hotspots 60, Reliability 65 | stale | med | Hotspots 64; Modularity 66 also bottom |
| 5 bundled plugins | misleading | med | Sheets omitted (full plugin) |
| 3300+ tests | stale | low | Actual ~4198 — noted |

### templates/DEPLOYING.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| vercel = spec for future subcommand | stale | med | `bp vercel quick-setup` already shipped |
| read-token should become an endpoint | stale | med | Endpoint exists + used |
| read-token runs server-side via ssh | stale | med | Minted over HTTPS now |
| `runVercel(out,g,tail[1:])` | false | low | Variable is `rest`, not `tail` |

### templates/place-directory/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `git checkout claude/relaxed-tesla-i52bsm` | stale | high | Branch doesn't exist (local or remote) |
| install.sh writes seed-places.json | misleading | low | Reads pre-existing file, doesn't generate |

### tooling/blast-radius/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| verdict-cache.json is committed | misleading | low | File doesn't exist / never committed |

### tooling/cody/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `$ cody preflight` | unverifiable | low | No `cody` binary; run `node cody.mjs` — note |

### tooling/concept-map/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| 3 bands | false | med | 4 (+CLEAN-NONPLUGIN) |
| 3 verdicts | false | med | 5 (+clean-lib, improvable) |
| fallback under 3 exemplars | false | med | Under 2 |
| built on `what-breaks` | misleading | low | No such dependency in concept-map |
| media Ca 28 | stale | low | Live value Ca 29 — noted |

### tooling/doc-onboarding/ASSESSMENT.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| every gap since fixed (93/100) | misleading | med | ≥4 DOC-6/INDEX items still open |
| `git log cloud/README.md` = 1 commit | false | med | 2 commits (this PR added the 2nd) |
| README grade table = 24 cells | misleading | low | 26 data cells — noted |

### tooling/doc-onboarding/KNOWN-ISSUES.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| INDEX added barkpark-cloud-go-live | false | high | String absent from INDEX.md |
| DOC-2 done (linked from INDEX) | false | med | CLOUD-QUICKSTART absent from INDEX |
| sdk/README wrong-door remaining | stale | low | Already fixed (header at line 1) |
| web/README contradiction remaining | stale | low | Already explained at line 6 |

### tooling/doc-onboarding/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| destructiveGuards detect bare `--yes`/`drop` | misleading | med | Needs `ecto.reset/drop`/`rm -rf` or `--target local --yes` |
| provisionalFraming catches bare `(wizard)` | misleading | med | Only in ship-marker context |
| cliCoverageRatio (all bp cmds) | misleading | med | Cloud-only 7 cmds; var is `cloudCoverageRatio` |
| stepsToFirstWin verbs | misleading | low | Also matches `task next`, `capabilities` |
| cap is 9 root rows | misleading | low | No declared cap; wiring adds a 10th |

### tooling/doc-truth/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| 19/19 rows resolved | stale | low | Now 20/20 |
| candidate set 335 files | stale | med | 394 (live JSON) |
| 34 under-documented, tenancy top | stale | med | 36; top is `repo.ex` (reach 329) |
| 41→41 facts | stale | med | Now 36→36 |

### tooling/quality/GRADE-CRITIQUE.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| Aesthetics formula | stale | med | Missing `deliberate`/`typedef` split + spotlight term |
| surfaced in quality.mjs:77 | false | low | SAFETY_TAG at 87–98 |
| Bloat note at quality.mjs:225 | false | low | Line 229 (225 is Dependencies) |
| 4 wire seams, 32 tests | stale | low | 36 tests — noted |
| govulncheck skipped | misleading | low | Runs when on PATH |
| delete-modal undercounts (open) | stale | low | Fixed in #240 — noted |
| "9 critics" heading | stale | low | 13 dimensions |

### tooling/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| hold-out AUC ≈0.86 | false | high | Hold-out (CV) ≈0.74; 0.86 is full in-sample |
| 9-dimension scorecard | stale | med | 13 dimensions |
| single all-arcs entry point | misleading | med | RELATE arc not surfaced in status board |

### tooling/SIGNALS.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| co-change added in Phase 3 | stale | med | Already built + integrated |
| fit/ + composites not built (Phase 4) | stale | med | Built; Hotspot+Priority composites live |

### tooling/twoslash-mocks/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `shiki-twoslash` | stale | med | `@shikijs/twoslash` (shiki v1.x) |
| self-skips, zero CI cost | misleading | low | Standalone tsc check always runs |
| verify `tsc --strict <file>` | false | med | CI uses `--project …/tsconfig.json` |

### tooling/typedoc/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| consumed by apps/docs at build | false | high | `apps/docs` not scaffolded; artifact uploaded only |
| six JS packages | stale | low | 7 exist; 6 entryPoints (create-barkpark-app excluded) — noted |

### web/README.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `<BarkparkLive/>` in root layout | false | med | Layout renders `<LiveBridge/>` wrapper |
| flat published-posts list | misleading | low | It's a document finder + graph browser — noted |

## 3. Needs human sign-off (REPORT_ONLY — NOT auto-edited)

These 16 issues live in agent/human steering files (`CLAUDE.md`, `AGENTS.md`, `SKILL.md`). They were **confirmed** the same way as everything above, but deliberately **not** edited — these files govern behavior, and the Golden-Rules / Past-Mistakes / routing content is owner-sign-off-gated by the repo's own doc contract. Apply each proposed fix only after an owner confirms.

### .claude/skills/codebase-quality/SKILL.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| "eight canonical roots" | stale | med | SIGNALS.md has 9 (filebase added) |
| "9-dimension quality scorecard" | stale | med | quality.mjs has 13 (Contract, Dependencies, Bloat, Aesthetics omitted) |
| dense module graph "~286 files" | stale | low | 316 forward entries / 428 source files now |

### AGENTS.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `rm -rf api/_build/prod` sole exception is `make rebuild` | misleading | low | Also in `make deploy` (post-merge hook) and `make precheck` |

### api/CLAUDE.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| `Barkpark.Sheets` (snapshot synthesis) | false | med | Module is `Barkpark.Plugins.Sheets.Core` |
| `{:sheets_op, %{rev,tab,changed}}` | misleading | low | Payload also carries `sheet_id` |
| hydration in `content.ex` | false | low | In `content/sheets.ex` (called from `content/writer.ex`) |

### CLAUDE.md (repo root)
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| 5 plugins use `Barkpark.Plugin` | misleading | med | 6 (Sheets omitted) |
| `make dev` (Phoenix + TUI) | false | low | Also a CC pane (CC + TUI + Phoenix) |
| doc-gates triggers `.ex/.go/.exs/.ts` | misleading | low | Also `.tsx` |

### js/CLAUDE.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| nextjs subpaths (omits actions) | false | med | `./actions` subpath has full impl |
| ADRs at `js/docs/adr/` | false | med | Path doesn't exist; ADRs at `docs/decisions/` |
| test projects: node, core-workerd, react-browser | misleading | low | Also `server`, `client` (5 total) |
| repo-root `sdk/` = ingest SDK | misleading | low | It's the authoring SDK (`@barkpark/bulldocs-sdk`) |

### web/AGENTS.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| "raw fetch vs `@barkpark/nextjs`" in js-sdk.md | misleading | med | Card documents `@barkpark/core` primary, not raw fetch |

### web/CLAUDE.md
| Claim | Kind | Sev | What's true |
|---|---|---|---|
| "raw fetch vs `@barkpark/nextjs`" in js-sdk.md | misleading | med | Same; raw-fetch rollback is in web/README.md |

## 4. Honest limits

- **Denominator not captured.** This report lists 250 confirmed defects. It does not record how many claims verified clean, so a "defect rate" cannot be computed from it. The 250 is a floor, not a census — a claim that no source could reach was marked `unverifiable` and softened, never counted as either true or false.
- **`unverifiable` rows are judgment calls.** ~10 issues (e.g. WINDOWS.md tested-versions, PHILOSOPHY.md backup scripts, `bp ssh/logs/rebuild/backup`, tooling/cody invocation) had no source to confirm or refute. They were reworded to stop *asserting* an unprovable fact, not because the claim was proven wrong. An owner who knows the ground truth may prefer the original wording.
- **Point-in-time against a moving tree.** Several `stale` findings (Cody scores 81 vs 83, candidate-set 394, AUC, test counts) are live-computed numbers that drift every commit. The fixes pin a snapshot that will itself go stale; the durable fix is to stop hard-coding live metrics into prose.
- **Auto-fixes applied but not re-verified end-to-end here.** Each edit matches its proposed-fix text, but this report does not re-run the docs build, link-check, or Mermaid validation over the edited files. The PostToolUse validation hook covers HTML, not these Markdown/MDX edits.
- **Governance files left to humans by design.** The 16 §3 issues are real and confirmed, but editing CLAUDE/AGENTS/SKILL without owner review would violate the repo's own sign-off rule. They remain open.
- **Single-pass, single-auditor.** No second reviewer cross-checked these 250 findings. Evidence is quoted with file+line for each (in the source dataset), so each is independently checkable, but the set as a whole has not been adversarially re-graded.
