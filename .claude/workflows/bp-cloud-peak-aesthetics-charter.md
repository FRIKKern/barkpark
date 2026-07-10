# Barkpark Cloud Epic Charter — Peak Aesthetics, UX and DX

Wish: "Reach peak aesthetics, UX and DX for Barkpark."
Focus surface: the Cloud dashboard (`cloud/priv/static/` SPA + `cloud/lib/barkpark_cloud/` control plane) and the `bp cloud`/`bp cloud hetzner` CLI — the two operator surfaces, made provably one product.

**Binding law (user amendments, `.claude/workflows/bp-cloud-console-wish.md` — they outrank every decision below):**
- **Amendment 2 — coherence over accretion.** Stop adding panels until the whole feels designed; onboarding is priority #1; a written UI blueprint precedes the biggest rebuild slices; **LOOK AT IT** — screenshots or full-page DOM/HTML snapshots attached to verdicts, "I read the CSS" doesn't count; fewer things, better placed, quieter.
- **Amendment 3 — ease of mind first; the novice is the persona.** No jargon; one clear next action per screen; the golden journey (a Barkpark + a site, one guided flow) is the centerpiece; **zero broken promises** — anything offered must work end-to-end, every failure explained in human words and recoverable, never a dead end.

## Vision

Open the dashboard and it reads like Vercel operating hardware you own — and it is unmistakably Barkpark, not a shadcn demo. Every question in the operator's week has a live answer and every answer has an action. The IA is a strict grammar — 4 places (Overview/Fleet/Sites/Activity) + a Settings cluster, frozen forever; capability grows as LENSES and SUB-TABS, never a fifth tab. The instance detail is a sub-tabbed workspace whose Timeline merges agent events and audit entries chronologically, live off the closed SSE registry — the incident home, with the golden-path verify chips (API answers / Login responds / Studio renders) at the top and "Check now" one click away. Every prior successful deployment carries an instant "Roll back to this" one calm confirm away (the promote primitive already shipped server-side). An invited teammate clicks their link and joins — no curl. The design language is one machine-enforced contract with a real identity: evergreen primary, real mark, self-hosted type, dimensional scales, WCAG contrast as a merge gate, /styleguide.html as the living spec a human signs off on in thirty seconds. Status means one thing everywhere — the same semantic roles drive the fleet pill, the deploy pill, and the ANSI colors in `bp cloud status`, byte-proven by fixtures asserted from Node AND Go. The Hetzner estate becomes visible AND drivable through the catalog-driven proxy — the catalog is the allowlist, the audit choke point, and (via its `cli:` field) the proof that GUI and CLI are one product. Zero dead CSS, zero dead ends — checked, not hoped.

## Decisions (settled — build against these)

1. **Vanilla SPA stays; discipline is machine-enforced.** No framework rewrite. The node:vm `__bpTestHook` harness (`__app.test.mjs`, 104 tests) is the SPA's test spine — every new pure helper gets exported and tested. `__css_check.mjs` (dead classes, undefined tokens) gates every SPA slice. *Why: 5.2k lines of working, freshly-hardened code; a rewrite burns waves reproducing what exists.*
2. **SSE event-contract registry precedes any live panel.** `events.ex` closes the type set (`broadcast/3` raises on unregistered types in every env); `app.js` mirrors it in `TYPE_ACTIONS`; shared fixture `__fixtures__/event_types.json` asserted from both runtimes. New types register in the same PR that emits them. *(LANDED wave 1; 11 types in the registry today.)*
3. **Hetzner in the GUI goes through a control-plane proxy — never browser-direct.** `hetzner_catalog.ex` IS the allowlist — no prefix matching, no free-form passthrough. Read-only landed wave 1; mutations go through ONE generic route (decision 20), each writing an audit event.
4. **One JSON contract, two surfaces.** `bp cloud hetzner overview -o json` is the reference implementation; `/v1/hetzner/overview` emits the same envelope; golden fixture asserted byte-true from Go and deep-equal from ExUnit. Partial failure: failed kind rides as `null` + `counts.<kind>: 0` + `errors` map. *(LANDED wave 1 incl. reconciliation test.)*
5. **One destructive-op grammar, both surfaces, three tiers.** read = free; mutate = single confirm + consequence sentence; destroy = typed-resource-name + consequence list. CLI: `hzConfirmDestroy` (landed, 17 sites). SPA: one shared focus-trapped `confirmModal` component supporting both tiers (born in the rollback-UI slice, reused by every mutate/destroy flow after). Rollback/redeploy is MUTATE tier (it mints a new deployment, reversible by promoting again).
6. **IA reshape:** Overview home, 4-place nav + Settings cluster, `legacyRoute` pure remap. *(LANDED.)*
7. **Rollback/redeploy are control-plane primitives.** `POST /v1/sites/:id/deployments/:dep_id/promote` (router.ex:3445) — promote-by-NEW-deployment, never a pointer flip; promoting the current artifact IS redeploy, an older artifact IS rollback. *(LANDED server-side + `deployment.promoted` audit row. UI is this wave.)*
8. **Palette + copy-as-CLI chips come from ONE action registry, after panels exist.** The catalog `cli:` field (decision 20) seeds the CLI-equivalence data; the SPA-side registry + ⌘K UI is a later wave.
9. **Design-language scope: cloud SPA is the reference implementation; Studio/web adoption deferred.** *Why: unifying four styling islands in one epic is where design systems die.*
10. **Timeline is the incident home.** Instance events (`GET /v1/barkparks/:id/events`, router.ex:4161, newest-first) merged chronologically with instance-scoped audit entries (`GET /v1/audit?target_type=barkpark&target_id=`, router.ex:1013, team-admin-only), live-ticking, console lines expandable inline.
11–15. *(IA-reshape cycle: 14 = `bp cloud open` mints only the LEGACY-STABLE hash set; 15 = fleet attention/inflight/healthy buckets as `#fleet/<bucket>` — the single attention-order spec, `__fixtures__/attention_order.json`, pins SPA classifyBp AND Go statusRole.)*
16. **Tree is truth; charter resynced whenever strategists and code disagree — grep settles it.**
17. **The nav is frozen at 4 places + Settings — forever.** Everything new is a Fleet lens or an instance sub-tab (`#instance/<id>/<tab>`). A sub-tab ships only WITH its content — no dead-end shells. Instance tabs today: Overview | Webhooks; this wave adds Timeline. *Why: place-count stability keeps the operator's mental map valid.*
18. **One row component, two scopes.** The timeline row renderer serves the instance Timeline now and the global Activity view later; `mergeTimeline(events, audits)` is pure and harness-tested. Timeline degrades to events-only when `/v1/audit` 403s (non-admin members). *Why: learning one view is learning both; honesty over blank panels.*
19. **`confirmModal` (SPA) is born with the rollback UI** as THE shared focus-trapped modal for every mutate (single confirm + consequence) and destroy (typed-name + consequence list) flow. *Why: one grammar, one component, one test.*
20. **DRIVE lands server-first, one generic route — after the coherence waves.** `POST /v1/hetzner/actions/:resource/:verb`: exact catalog lookup, param whitelist (extras = 400), tier gate (destroy = 403 tripwire), vault decrypt server-side, audit, forward. Catalog v2 adds `cli:` + param specs + ~9 curated mutate verbs; ActionWatcher (Hetzner Action polling → `hetzner.action.*` SSE, types registered same PR) and the DRIVE UI follow. *Why deferred: the novice never reboots a box in week one; coherence before capability.*
21. **Destroy tier stays unrouted until an explicit future amendment.** *Why: real anti-orphan need, but it deserves its own slice and its own scrutiny.*
22. **Design tokens become a cross-surface golden fixture** (with the statusMeta sweep wave, AFTER identity settles the hues). `__css_check.mjs --emit` parses the app.css token blocks into committed `__fixtures__/design_tokens.json` (semantic roles, resolved light+dark values, role→ANSI map); a Go test asserts `statusRole`/ANSI painting against it. *Why: the proven two-runtime-fixture pattern, applied to the design system itself.*
23. **Telemetry returns the series it already stores — additive, no monitoring product.** Sparklines in a Metrics sub-tab later.
24. **statusMeta + state-grammar sweep is a SOLO-SPA wave.** One `statusMeta` renderer absorbing status-pill AND dep-pill (still live, app.css:910 — verified 2026-07-04), old CSS DELETED so the dead-class checker is the tripwire; skeletons/empty/error-with-action swept across ALL views in ONE pass; the mechanical px→scale migration; **row anatomy folds in here too** (one rowHtml grammar: identity, one fact, one pill, one action slot — strategist-2's proposal, absorbed rather than a standalone slice). *Why: a whole-file sweep cannot share app.js with panel work; half-migrated vocabulary is worse than either extreme.*
25. **Errors carry their next action.** The `ERRORS`/`friendly()` map upgrades to `{message, action, href}` during the state-grammar sweep. Seeded NOW: every failure state the rollback + invite + timeline slices introduce ships with exactly one recovery action.
26. **Zero broken promises is a wave-blocking bug class.** The server mints invitation accept URLs the SPA cannot route (verified still true 2026-07-04: `accept_url` minted at router.ex ~2180, no `#invitations/accept` route in app.js) — an invited teammate cannot join via GUI. The accept flow ships this wave; the full members panel stays wave-scheduled. *Why: amendment 3.4 verbatim.*
27. **Barkpark gets a real identity NOW, gated by eyes.** Deep park-evergreen primary + one warm amber accent (replacing verbatim shadcn-zinc `hsl(240 5.9% 10%)` at app.css:13 and the generic blue dark-theme primary at app.css:72), a real inline-SVG mark (≤400 bytes, currentColor, replacing the `.wordmark-mark` box at app.css:134), self-hosted Inter woff2 (the fonts.googleapis.com links at index.html:8–11 die; the control plane must render with the network cable pulled). Hue change is token-block-only so the rebrand is one reviewable diff; **human sign-off on mark + hue happens on /styleguide.html before merge.** *Why: identity is the one thing no validator can generate; every polish wave until then compounds a language that isn't ours.*
28. **Aesthetics become merge gates.** `__css_check.mjs` grows: a WCAG contrast engine over a DECLARED pair manifest (~25 fg/bg token pairs, both themes, 4.5:1 text / 3:1 UI), raw-color-literals promoted to error (conscious allowlist), a no-external-host lint (index.html, styleguide.html, app.css), a report for raw px font-sizes. Every new check mutation-probed (degrade, watch it fail). *Why: fifty future agent slices will touch app.css; a gate is the only way dark-theme legibility survives them.*
29. **Dimensional tokens are DEFINED this wave, swept next.** Type scale, 4px-grid space scale, motion tokens + prefers-reduced-motion collapse, elevation ladder, z-index ladder (today magic 19/20/30/50/60). Only shared primitives (body, buttons, cards, modal, toast) migrate now; the whole-file migration rides the decision-24 solo sweep.
30. **LOOK AT IT has tooling: the `__preview__` harness.** *(LANDED 2026-07-04 as `cloud/priv/static/__preview__/` — mock.js + scenarios.mjs + serve.mjs + shoot.sh + smoke.mjs, PR #1064. Satisfies the render-rig role; new SPA slices ADD SCENARIOS for their new states and perfecters attach renders.)*
31. **The verify gate went continuous — on demand, server half LANDED** (PR #1035, D53): `POST /v1/barkparks/:id/verify` (router.ex:1197), synchronous probe envelope `{ok, reachable, verified_at, probes}`, unreachable = 200 with `reachable:false` (never 502), 409 not_live while (de)provisioning, admin token never leaves `Verify.run/1`.
32. **Resync 2026-07-04 — a parallel console loop (D45–D66/A,C slices) landed half of wave 3.** In tree now: instance sub-tabs (Overview|Webhooks) + webhooks panel (#1037) + `bp cloud webhook` twin (#1036), on-demand verify (#1035), provisioning timeline one-renderer-three-mounts (#1004), `__preview__` harness (#1064), `cloud/DESIGN.md` blueprint (#1063), onboarding narrative (#1066), FailureCopy (#1065), usage endpoint (#1034), unified CLI error seam (#1077). Roadmap below renumbered from this reality; `cloud/DESIGN.md` is the ratifiable blueprint amendment 2.3 demanded — this charter defers to it on screen purpose.
33. **Verify results ride EXISTING contracts — no verify SSE type, ever.** D53 settled it in code: every run persists as a `verify` instance event (`Registry.record_event(bp,"verify",result)`) and nudges the existing `fleet` type. Chips and Timeline consume instance events; decision 31's earlier "register a type with its consumer" clause is void. *Why: the registry stays closed; the dashboard already refetches on fleet.*
34. **The Timeline slice absorbs the verify chips.** One builder owns the whole instance region; the incident home ships whole — "what changed?" (merged feed) + "is it healthy now?" (three probe chips) + "check again" (Check now) in one slice, zero Elixir edits. *Why: two builders in one app.js region is a merge failure waiting; the two answers are one screen.*
35. **The capability freeze holds until the decision-24 sweep lands.** Explicitly deferred despite strategist advocacy: cross-fleet `/v1/deployments` + Overview shipping lane, topbar ops beacon, ⌘K jump navigator, log spine/Logs sub-tab, Backups GUI, verify-history availability strip, staging clone, DRIVE mutations, attention-rows-carry-fix. All recorded in the roadmap; none ship before the product feels designed (amendment 2.1). The log spine is acknowledged as the biggest parity hole and gets its own wave + scrutiny (bounded snapshot vs. streaming decided then).
36. **CLI symmetry debt is wave-eligible when zero-collision.** `POST /v1/barkparks/:id/verify` shipped without its CLI twin; `bp cloud verify <instance>` ships this wave as a Go-only slice (statusRole-painted probe table, `-o json` envelope passthrough, probe names asserted against `__fixtures__/verify_probes.json` — the two-runtime pattern). *Why: "one product, two surfaces" decays one missing twin at a time; deployment_failed notifications already exist (`notifications.ex` @chat_default_on), so no producer work is owed there.*

Corrections to strategist claims (verified against tree 2026-07-04): instance sub-tabs EXIST (`INSTANCE_TABS` app.js:1086 = overview|webhooks) — the Timeline tab does not. On-demand verify EXISTS server-side; there is NO verify SSE type and none is needed (decision 33). The render rig EXISTS as `__preview__` — do not build `__render_rig.mjs`. `deployment_failed` notifications already exist. Webhook panels + CLI twin already exist — strategist webhook proposals are done. The invite accept URL is still unroutable (broken promise open). app.css primary is still verbatim shadcn-zinc; Inter still loads from Google; dep-pill still coexists with status-pill. The promote route exists with zero UI handles. `bp cloud status` already paints statusRole ANSI from `attention_order.json`.

## UI Blueprint

`cloud/DESIGN.md` (landed #1063) is the ratifiable blueprint; /styleguide.html (this wave) is its living enforcement. Rules (enforced, not aspirational): status renders through ONE mechanism after the decision-24 sweep; spacing on the 4px grid tokens; 6-step type scale; every screen has exactly one primary action; copy voice calm, second person, zero jargon; every terminal state carries exactly one recovery action; progressive disclosure — power behind deliberate seams, never confronting the novice.

## Roadmap (integration order; ✅ = landed in tree)

### Wave 1 — spine + contracts ✅
1. ✅ SSE event-contract registry (M)
2. ✅ Design-token contract + `__css_check.mjs` (M)
3. ✅ `bp cloud hetzner overview` + golden fixture (M)
4. ✅ CLI destructive-confirm sweep `hzConfirmDestroy` (M)
5. ✅ Hetzner catalog + read-only proxy (L)

### Wave 2 — operator's home ✅
6. ✅ IA reshape: Overview home, 4-place nav + Settings, legacyRoute, fleet buckets (L)
7. ✅ Rollback/redeploy control-plane primitive (promote route + audit) (L, server side)
8. ✅ Go↔Elixir overview-fixture reconciliation (S)

### Wave 3 — landed via the parallel console loop ✅
9a. ✅ Instance workspace sub-tabs + webhooks panel + `bp cloud webhook` (L)
12. ✅ LOOK-AT-IT tooling: `__preview__` harness (M) · `cloud/DESIGN.md` blueprint
13. ✅ Continuous verify, server half (M) — POST /v1/barkparks/:id/verify

### Wave 4 — keep every promise; become Barkpark (CURRENT — cut 2026-07-04)
9b. **Instance Timeline sub-tab + verify chips — the incident home** (L) — decisions 10/18/33/34; pure-SPA.
10. **Zero broken promises: Rollback/Redeploy UI + shared confirmModal + invitation accept** (L) — decisions 5/7/19/25/26.
11. **Identity + dimensional tokens + aesthetic merge gates + /styleguide.html** (L) — decisions 27/28/29; human sign-off; no app.js edits.
11b. **`bp cloud verify <instance>` CLI twin** (S) — decision 36; Go-only.

### Wave 5 — the sweep + the cross-runtime token proof
14. statusMeta + dep-pill absorption + state grammar + errors-carry-action + px→scale + row anatomy — SOLO SPA sweep (L) (decision 24)
15. design_tokens.json cross-runtime fixture + CLI glyph/role painting (decision 22) (M)
16. Attention rows carry their fix (rowAction map: exactly one recovery action per row; post-sweep so it rides the row grammar) (M)
17. Telemetry `series` (decision 23, server) (S)

### Wave 6 — DRIVE server + estate SEE
18. Catalog v2 (`cli:` field, param specs, curated mutate verbs) + generic mutation proxy + destroy-403 tripwire (L)
19. ActionWatcher: Hetzner Action polling → `hetzner.action.*` SSE (types registered same PR) (M)
20. Infrastructure lens `#fleet/infra` + per-instance Infra sub-tab; provider.label-null fallback; estate drift strip (read-only, copy-as-CLI remediation chips) (L)

### Wave 7 — DRIVE UI + trust panels
21. DRIVE UI: catalog-generated action menus, tiered confirm, live progress pills (L)
22. Env vars + custom domains/TLS panels (instance sub-tabs) (M)
23. Team members + invitations management panel (accept flow already live) (M)
24. Metrics sub-tab: sparklines from the telemetry series (M)
25. Log spine — bounded, redacted service-log snapshot (NOT streaming, NOT a log product; snapshot-vs-ring-buffer decided in its own amendment) + Logs/`bp cloud logs` twins — the SSH dead-end killer (L)
26. Destroy tier, blast-radius-ordered, server-verified name echo — standalone amendment, droppable (M)

### Wave 8 — signature DX
27. Action registry (SPA) + ⌘K palette + copy-as-CLI chips everywhere (L)
28. CLI reciprocity: post-mutation dashboard deep-links, `bp cloud open` sub-tab targets (decision-14 amendment), `bp cloud status --watch` (M)
29. Verify-history availability strip (persisted runs → 90-day golden-path strip — OUR uptime, not a monitor) + topbar ops beacon (M)
30. "Own your exit" panel: bootstrap bundle, credentials, transfer/eject with chips (M)
31. Security panel (2FA enroll/recovery) + webhook console polish (M)

**Non-goals (conceded rows in the parity table):** web-vitals/request analytics, edge functions, deployment comments, per-branch env UI, background verify scheduler, GUI deletion of servers/networks/dns-zones, staging clone (revisit only after the golden journey is proven calm).

## Wave log

### Wave 2026-07-03 (wave 1 — spine + contracts)

**Landed (5/5 green, perfecter-verified):** SSE event contract (73fc11cb) · token contract + `__css_check.mjs` (7e90591e) · `bp cloud hetzner overview` (c80584d2) · `hzConfirmDestroy` (ae94889f) · catalog + read-only proxy (4d54766b).

**Debt status:** fixture reconciliation — PAID. Catalog destroy-tier — SETTLED as data. provider.label-null fallback — owed (wave 6, item 20). `broadcast/3` raise — standing reminder for item 19. Live smokes — superseded by `__preview__` + styleguide.

### Wave 2026-07-03 resync + wave-3 cut (architect)

Tree audit found wave-2 work already landed; decisions 16–31 recorded; amendments 2+3 restored into the cut (brand pulled forward, invite-accept promoted, DRIVE deferred).

### Wave 2026-07-04 resync + wave-4 cut (architect)

A parallel console loop (D45–D66) landed half of the wave-3 cut between charter snapshots: sub-tabs+webhooks, on-demand verify, `__preview__`, DESIGN.md, onboarding narrative, FailureCopy, usage endpoint. Decisions 32–36 recorded; verify SSE clause voided (33 — verify rides instance events + `fleet`); render-rig slice cancelled (satisfied by `__preview__`); dep-pill confirmed still alive → decision-24 sweep scope widened; row-grammar strategist proposal absorbed into the sweep (24); capability freeze re-affirmed against five strategists' expansion pressure (35); log spine acknowledged as the top parity hole and scheduled with its own scrutiny (wave 7). **Wave 4 cut: items 9b, 10, 11, 11b.** app.js contention: item 9b owns the instance region + TYPE_ACTIONS wiring; item 10 owns the site-detail region + a new invite view + routes; both append-only to app.css end / `__app.test.mjs` / `__bpTestHook` exports (textual conflicts, merge sequentially: 11 → 10 → 9b → 11b). Item 11 owns app.css token blocks + index.html + styleguide.html + `__css_check.mjs` and must not edit app.js. Item 11b is Go-only. Every SPA slice adds `__preview__` scenarios for its new states; perfecters attach renders (amendment 2.4).

### Wave 2026-07-04 (wave 4 — keep every promise; become Barkpark)

**Landed (4/4 green, all perfecter-approved "merge the -p branch"):**
- **11 Identity drop** (424913bc + perfecter polish): evergreen/sage mirror-pair primary + amber accent, 149-byte inline-SVG mark, genuinely self-hosted Inter (offline-render proven), dimensional token ladders defined (primitives-only migration per decision 29), E5 WCAG contrast engine (29-pair manifest × 2 themes = 58 checks), E6 raw-literal error + allowlist, E7 no-external-host lint, R4 px backlog report (132 lines), /styleguide.html sign-off page. All 10 gate mutations probed. Perfecter caught a REAL ratification-surface bug (scoped `[data-theme]` var-substitution rendered light colors in the styleguide's dark panes) — fixed + gated as E8.
- **10 Zero broken promises** (58100d00): confirmModal born (pure reducer, mutate + destroy tiers, trapTarget refactor, D25 one-recovery-action contract), Rollback/Redeploy UI on the promote route (Current chip, consequence copy, promoteFailure map), invitation accept flow end-to-end (legacyRoute for the minted shape, token parked in sessionStorage + URL scrubbed, preview banner, designed terminals incl. wrong-account resume). Decision-26 broken promise CLOSED.
- **9b Timeline + verify chips** (7ca5a94a): incident home whole per decision 34 — pure mergeTimeline (order/dedup/403-degrade harness-pinned), inline expansion surviving SSE remounts, verify chips byte-pinned to `__fixtures__/verify_probes.json`, Check-now with honest unreachable rendering, 409/404 each one recovery action. Zero Elixir. Repaired the pre-existing stale `__preview__` 'empty' expectation.
- **11b `bp cloud verify`** : verdict line + probe table through statusRole/joinColsPainted, `-o json` verbatim, exit ladder via useError, fixture tripwire now spanning Go CLI + Go provisioner + Elixir. Dispatch registered in hetzner_cmd.go (runCloud lives there, NOT cloud_cmd.go — FILES list was wrong, builder correct).

**Wave verdict:** the strongest wave yet against the wish — identity (aesthetics), zero-broken-promises + incident home (UX), CLI twin + merge gates (DX). No drift into micro-repair; the freeze held.

**BLOCKING before/at integration:** (1) decision-27 human ratification of /styleguide.html — serve the **-p branch's** page (dark panes differ from the builder's original); nothing merges before it since 11 heads the merge train. (2) Merge order 11 → 10 → 9b → 11b, sequential — known textual conflicts: app.css tail, `__app.test.mjs`, ALLOW_PREFIXES, `__preview__` EXPECTATIONS, runCloud switch/help. (3) Full cloud Elixir suite at integration (builder ran only the touched allowlist test in-worktree). (4) macOS Go gate needs CC=clang (environmental).

**Owed post-merge (file as tasks):** real-browser light/dark eyeball of Timeline/verify-chip/rollback/invite screens (profile lock blocked it two waves running — pixel debt is accumulating); one real `bp cloud verify` + curl smoke on guerrilla (envelope parity rests on handwritten test envelopes); loadInstanceSites re-query race (A's sites can paint into B's slot); invite already-member detection only sees the current team + session not switched after join (server contract question for the wave-7 members panel); first destroy-tier consumer must browser-click the typed-echo input once; consider promoting `__preview__/smoke.mjs` into a gate (it's green and it caught the IA-reshape drift).

**Feeds wave 5:** status hues visibly retinted in BOTH themes (forced by the AA gate) — the decision-22 `design_tokens.json` cross-runtime fixture is now UNBLOCKED and urgent (CLI ANSI must derive from the NEW values, do it early); --dur-3 defined-unconsumed + 132-px R4 backlog are explicit sweep fodder for decision 24 — if the sweep slips, these rot into permanent debt.
