# Barkpark Cloud Research Epic — Charter

Epic task: `bp-cloud-research-epic` · Wave paper: `perfect-plan-research-wave-2026-07-12`

## Vision

A research-and-testing epic with ZERO product code whose deliverable is an evidence-grade
paper stack on guerrilla that turns the standing cloud-strategy trio (one-shot-onboarding,
barkpark-estate, shared-cells) from claims into measured facts. Each of the 8 open questions
gets one paper ending in a verdict block (SETTLED / SETTLED-WITH-CAVEATS / REFUTED) with
inline evidence — terminal transcripts, wall-clock timings, file:line seam maps — capped by
a "Perfect Plan readiness ledger" that rolls verdicts into the build sequence for the next
epic. Keystone bet: the per-workspace export/import bundle (5 consumers: rebalance,
graduation, backup, eject, abuse isolation) gets the deepest paper — a provably complete
walk of the tenancy tree.

## Decisions

- **D1 Authoring law (live-proven 2026-07-12).** Never PATCH a published paper (500s reproducibly — Preview.extensions crash on weighted-tag objects, preview.ex:290/345); every edit is a full `createOrReplace` + `publish` (one-batch mutate is safe — same validation pipeline, not the crash class). Document fields (`title`, `description`, `tags`, `style`, `blocks`) are TOP-LEVEL sibling keys in the mutation payload — nesting them under a `content` wrapper hides them from the label-spine validator and publish fails. `style=article` mandatory. Wall: description ≥20 chars; 1–12 weighted tags, distinct strengths, rationale ≥20 chars, tags REGISTERED — re-check `./dist/bp doc ls tag -o json` immediately before publishing (registry drifts mid-wave: 16→17 during verification). *Why: every rule here was proven by run output on guerrilla this wave.*
- **D2 Mermaid label law — lead note REFUTED.** Labels containing structural characters (parens, slashes, colons) MUST be double-quoted (`A["Start (quoted)"]`); the same label unquoted fails to parse (mermaid@11.16.0, the live CDN pin: `Expecting 'SQE'... got 'PS'`). encode_mermaid deliberately passes quotes through raw. *Why: headless parse harness proof beats the prior "no quotes" note.*
- **D3 Hollow papers bounce.** Every wave paper ends in a verdict block and carries ≥1 `terminal` block with actually-run command output. The slice gate enforces this mechanically. *Why: a pass is meaningless unless the right thing produced it.*
- **D4 Probe targets.** Read/measure probes hit guerrilla; destructive/infra probes hit fresh scratch instances (`bp cloud instance create --provider hetzner`, torn down after); NEVER prod 89.167.28.206. All guerrilla measurements diff by workspace_id/entity id, never raw table counts (background traffic proven: +12 audit/+18 mutation rows per 90 s). *Why: guerrilla is live and shared; raw-count diffs misattribute noise.*
- **D5 Keystone design constraints ratified.** 19 tables carry workspace_id (not 18 — `roles` is the 19th); a complete workspace bundle needs THREE enumerations: workspace_id column scan + FK walk + string-keyed tables (authoring_exemptions [1165 live rows], shares, search_surface_config, sync_*, github_sync_conflicts, data_keys, preview_token_jti) resolved via slug↔uuid map. Exporter keys on `workspace_id` — never iterates dataset strings (proven loss vector: NULL dataset_id + drifted dataset string is invisible to per-dataset export yet inside the tenant). Completeness proof method = information_schema + pg_constraint diff and `count(export) == count(WHERE workspace_id)`, never grep. *Why: the surveyed walk would lose real data today (authoring_exemptions).*
- **D6 NULL-dataset premise refuted.** Content.export_stream does NOT silently drop NULL-dataset_id rows (NULL-tolerant OR rescues via the NOT NULL dataset string); api/CLAUDE.md:44's "NO NULL-fallback" line is imprecise; docs/contracts/tenancy.md:77's NILIFY_ALL claim is stale (live schema: all 17 FK-constrained workspace tables CASCADE). *Why: live probe with 3-row fixture, mechanism isolated in raw SQL.*
- **D7 Quota/suspend seam settled.** The ONLY seam covering content AND media writes is a router plug after ResolveWorkspace (Content.apply_mutations misses ALL media writes — media_controller calls Barkpark.Media directly); the `[:barkpark,:content,:mutate]` telemetry span is a free content-metering hook; registry.ex's suspended/suspended_reason/suspended_at + reconcile_plan_limit is the pattern to copy at workspace grain (zero code shareable — different schema). *Why: proven by exhaustive grep + controller read; context-hook approach is disqualified.*
- **D8 Edge-cache verdict direction: REFUTED as stated.** No CDN fronts guerrilla (via: 1.1 Caddy only, direct A records), no Cache-Control on query/search reads (deliberately private), ETag computed AFTER the DB query, webhook sync_tags purge the CONSUMER Next.js cache, media CDN purge is :noop (MEDIA_CDN_* unset). Media binaries are the one genuinely cacheable family. *Why: live header + env + DNS proof on both boxes.*
- **D9 Live-migrate probe = dump/restore cutover wall-clock.** Zero replication config exists repo-wide; single-node local PG per box; the honest metric is pg_dump + restore + migrate + restart + health-gate downtime, not replication lag. *Why: measuring a mechanism that doesn't exist would be fiction.*
- **D10 Caddy probe self-provisions.** NO live box runs on_demand_tls (both live Caddyfiles are static single-FQDN); the /v1/tls/ask gate IS live on the control plane; the probe stands up its own barkpark-runtime/caddyfile.go rendering on a scratch box. check_origin's boot-time static list is the named landmine for host-based tenancy. *Why: fleet-wide SSH inspection settled it.*
- **D11 Playground facts locked.** Empty workspace = exactly 4 rows / 81 ms / ~397 B logical, zero audit/mutation/webhook side-effects, delete cascades to zero orphans across all 19 tables — but NO HTTP DELETE route exists for workspaces (Tenancy.delete_workspace is context-only), and every abuse control (TTL, anonymous token, rate limit, quota) is absent. €0.12/tenant can only be amortized VM cost, never marginal storage. *Why: two live create/delete probes with scoped psql sweeps.*
- **D12 Telemetry: no per-workspace dimension exists anywhere.** api/ Prometheus tags only :route/:op/:event/:module; cloud/ meters are per-instance. felix-findings-telemetry is DISJOINT (Phoenix observability — zero mention of db_size/per-workspace) and does not cover the inventory paper. db_size sentinel contradiction RESOLVED: fix is live on main as f5554231 (PR #2648); retire the 30f59a6c pin. *Why: full paper read + git ancestry proof.*
- **D13 Tooling law.** After `make cli-build` invoke `./dist/bp` directly — the PATH bp has no commit stamp and doctor SKIPS its staleness check; `./dist/bp search query '<terms>'` is the working prior-art search. Task-ledger sweeps use `label=` filters — GET /v1/tasks IGNORES offset (silent truncation, ~6-day reachable window). *Why: cmp-proven binary divergence explains the half-fleet search failures.*
- **D14 Cross-link law.** Every paper links into the trio claim(s) it settles and the trio links back; the keystone/tenancy paper MUST link felix-findings-security-tenancy (Finding 3, complementary); "elasticity compass" is shared-cells' own sentence — cite it, never hunt for an external paper. *Why: the shelf must read as one argument; a fruitless search was already observed.*
- **D15 Capstone at Review.** The Perfect Plan readiness ledger is authored by the Review phase after the 8 verdict papers land (filed as backlog child now). *Why: it rolls up verdicts that don't exist yet.*
- **D16 "bp hello" does not exist.** The onboarding paper measures the six REAL routes; `bp whoami`/`bp version` is the timing stop-marker; device-link is headless-scriptable via direct POST /v1/auth/device/approve. *Why: repo-wide grep + route inventory.*

## Roadmap

Wave 1 (this wave — 8 paper slices, all research/probes, no product code):

1. `ppr-keystone-workspace-bundle` — keystone export/import bundle paper (fable, large)
2. `ppr-quota-suspend-seams` — quota/meter/suspend seam paper (opus, medium)
3. `ppr-host-tenancy-caddy-probe` — host-based tenancy + live on_demand_tls probe paper (fable, large)
4. `ppr-playground-cost` — playground tenancy + measured cost paper (opus, medium)
5. `ppr-live-migrate-cutover` — dump/restore cutover timing paper (opus, large)
6. `ppr-edge-cache-verdict` — edge-cache share refutation paper (opus, medium)
7. `ppr-telemetry-inventory` — telemetry inventory paper (opus, medium)
8. `ppr-onboarding-wallclock` — onboarding route wall-clock paper (opus, large)

Wave 2+ (Review + follow-ups): capstone readiness ledger (`bl-capstone-readiness-ledger`),
then the NEXT epic builds from the ledger's sequence.

Backlog (filed as published children, not this wave): tasks-offset bug, deleted-paper-200,
cli-install target + loud doctor, tenancy doc corrections, workspace DELETE route,
audit-tables FK orphan risk, Preview weighted-tags crash fix (root cause now known).

## Wave log

### Wave 2026-07-12 — 8 verdict papers landed, grade A-

**Landed (all 8 gates green on final state, all readers 200):** workspace-bundle-keystone (35 blk, REFUTED-as-surveyed/SETTLED-as-corrected three-enumeration walk), quota-suspend-seams (29, plug SETTLED / context-hook REFUTED), host-tenancy-caddy-probe (37, ask-gate loop SETTLED live on a scratch box), playground-tenancy-cost (29, mechanism SETTLED / readiness REFUTED), live-migrate-cutover-timing (62, live-migration REFUTED / ~60 s dump-restore freeze SETTLED — slice report was lost by the workflow but paper+branch+ledger were intact), edge-cache-share (31, REFUTED as stated), telemetry-inventory (24, SETTLED, per-workspace greenfield), onboarding-wallclock (47, SETTLED overall / R1 default curl|sh REFUTED — it 404s today). Zero product code; both scratch boxes torn down; prod untouched.

**Review fixes (remote papers, no -r branches):** tone="warn" → "warning" on edge-cache + live-migrate verdict callouts (unregistered tone rendered info-blue); live-migrate's missing and edge-cache's prose-only shared-cells forward links made real action links; D14 mesh completed — shared-cells +4 backlinks, barkpark-estate +1 (quota), one-shot-onboarding +1 (onboarding-wallclock). Ledger: ppr-playground-cost 0-index stamp off-by-one fixed (evidence re-seated 0-2, LEAD gate un-flipped) — second builder to hit the 0-indexed `--criterion` footgun; consider a CLI guard.

**Stalled:** nothing. **Open for the lead:** merge the 7 marker branches and close each slice's criterion 3 (ppr-edge-cache-verdict has no branch — close on the debrief).

**Next wave:** author the capstone `bl-capstone-readiness-ledger` (charter D15) rolling the 8 verdicts into the next epic's build sequence; ship the two user-facing reds early (install-cli.sh default 404s — the QUICKSTART front door is broken today; Preview weighted-tags PATCH crash, root cause known). Wave paper: `perfect-plan-research-wave-2026-07-12` (debrief appended).
