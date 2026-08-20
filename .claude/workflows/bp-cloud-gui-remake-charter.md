# Cloud GUI Remake — Epic Charter

Epic task: `task-47bc4168392dec17` · Wave Paper (current): `cloud-gui-remake-wave-2026-07-20-seal-r2` (round 5: `cloud-gui-remake-wave-2026-07-20-seal`; round 4: `cloud-gui-remake-wave-2026-07-19-p5r4` (round 3: `cloud-gui-remake-wave-2026-07-19-p5r3`; round 2: `-p5r2`; round 1: `cloud-gui-remake-wave-2026-07-19-p5` (wave 4: `cloud-gui-remake-wave-2026-07-19-p4`; wave 3: `cloud-gui-remake-wave-2026-07-19-p3`; wave 2: `cloud-gui-remake-wave-2026-07-19`; wave 1 debrief: `cloud-gui-remake-wave-2026-07-18`) · Founded 2026-07-19 (design phase closed 2026-07-18, 4 ratifications: iris 5th identity, trial CTA, mint dark primary, IBM Plex Mono).

Decision namespace: **GR** (GUI Remake). Never cite bare D-numbers from other charters without the charter name — D48/D49/D51 in the console-charter lineage are proven dangling pointers (defined nowhere in that lineage) and are NOT law here.

## Vision

The same console URL opens into the designer's v4 shell: sidebar (workspace switcher + plan chip, Find/⌘K, the 4 nav places + Settings, role-gated Operator entry, account) + topbar (instance-scope dropdown, live pulse, theme controls). Entering an instance/site context-morphs the sidebar (layer 1 collapses to '←', the thing's sections appear). Light/dark × 5 accent identities (evergreen mint, ember, fjord, charple, iris) switch in the designer's exact values with the existing inline pre-paint (no FOUC). Inter + IBM Plex Mono self-hosted latin subsets. Every old screen stays reachable at its hash anchor, retinted through the new ladder before its per-screen restyle. styleguide.html is the ported agency spec machine-bound to design/tokens.json. Drift gate green everywhere — and for the first time actually CI-enforced.

Phase 1 (this epic's first waves) = tokens+gate → styleguide+contrast gate → fonts → shell A-01..A-04. Phases 2–4 = per-screen restyles, alias retirement, Operator console (H-01..H-03), email-fleet mapping.

## Decisions

- **GR1 — In-place strangler, no parallel app.** The shell is rebuilt inside index.html + app.js; the console's plumbing (auth/session, SSE, api(), ~51 views in one 615KB app.js) cannot be duplicated without split-brain, and the 5 stable hash anchors can't point at two apps.
- **GR2 — Shell vocabulary is ONE identity-invariant passthrough family (`color.cloudChrome`).** Proven: the v4 prototype's applyTheme() only ever moves the 5 accent vars; bg-side/card/card2/modal/toast/fg1–5/spark-dim/line-rgb/backdrop/red-strong/on-red/blue/identity-marks never vary per identity. Only the 5-tuple accent ramps ride the theme axis. Designer hexes land VERBATIM in the passthrough family.
- **GR3 — iris derives on the neutral spine.** iris.json = evergreen's neutral bg/ink + iris accent only (0 overrides, 160/160 native, AA-clean — proven). The designer's per-identity bg/ink (#f4f5f7/#0b0e13) belong to the cloudChrome passthrough family, not the derive spine.
- **GR4 — All 4 existing ramps restyle to designer values; the retint of ~16 emitted surfaces is INTENDED.** Includes Studio's accent-hue-tinted rungs (studioChrome.surface-raised/border-subtle follow the mint hue — accepted). Evergreen restyle is atomic (tokens.json + themes/evergreen.json in one diff, exactly 15 slots — seam guard throws otherwise); a new `design/sync-evergreen.mjs` writer makes the sync mechanical. OVERRIDE_COUNT_FROZEN gains `iris: 0`; ramp pin counts do NOT move on accent-only restyles (proven). Base-role HSL triplets are non-integer but byte-faithful (hslToHex round-trips exactly) — correct, not noise.
- **GR5 — `__css_check.mjs` detector fix is a PREREQUISITE, and its E5 fanout is the honest gate.** Pre-fix it silently contrast-checked evergreen only (88 false E6; E5 saw 2 of 10 theme states). Post-fix truth: 340 contrast evaluations across 10 theme states; the 23 newly-visible E5 fails are REAL WCAG failures in today's ramps (charple-dark 2.34:1; warn-strong universal) and are cured by the designer restyle + tuned values (GR6), not waived. `__css_check.mjs` gets wired into console-harness.yml once tokens land (target: exit 0).
- **GR6 — Contrast rulings (machine-decided, 164-eval matrix):** `--dim`→fg3 (fg4 fails 4.5:1 at 3.96/3.41 — fg4 is a NET-NEW meta-only token, duty-capped ≥3:1 per the designer's own spec line). `--muted-text`→fg2. `--text`→fg. `--accent` STAYS decorative amber (1 consumer, doctrine "warm highlight never brand"); the designer ramp *called* accent maps to `--primary`. Green = the accent primary (no standalone green); add `--ok-strong` = accent.hover per-identity for text-on-tint. Tuned light values: `--danger` #b23636, `--warn-strong` #7d5500, azure identity light #2f7fce. Soft-tint alphas frozen at light 0.15 / dark 0.20 — changing them requires re-running the matrix.
- **GR7 — Alias bridge retints the 123KB hand CSS at once.** ~83 defined legacy vars map role-for-role onto the new ladder inside the generated block; `--primary-hover` is dead (0 consumers) and retires; `--console-*` stay theme-invariant terminal tokens; `--success`/`--destructive` keep the re-declaration alias pattern (E8). Aliases retire screen-by-screen in phases 2–4.
- **GR8 — Fonts are hand-authored CSS, not emitter output.** @font-face lives in app.css's preamble (before the GENERATED marker — the emitter has zero font code, by design). Latin subsets committed as binaries (repo precedent): Inter-var ~40.6KB + Plex Mono 400/500/600 ~41KB ≈ 80KB total (measured; beats EXIT.md's ~140KB estimate). OFL files take api/'s prefixed convention (`Inter-OFL.txt`, `IBMPlexMono-OFL.txt`). cloud router.ex's fonts cache-control code is fixed to match its own comment (long-lived immutable for /fonts/, no-cache for the rest). tokens.json font.mono gains self-hosted metadata (data-only, non-binding).
- **GR9 — Operator gate ships as the DECLARED interim principal.** `/v1/me` grows `platform_operator: boolean` sourced from the existing `PLATFORM_ADMIN_EMAILS` allowlist (Notifications.platform_admin_emails/0 made public; fail-closed on unset). The sidebar Operator entry renders only when true. This is deliberately the fourth-surface answer the self-update charter warned about, so it is DECLARED: `isu-backlog-operator-principal` inherits and reconciles this boolean when the real principal lands; the require_worker fleet routes stay untouched and out of scope. Never gate on team role (owner/admin is a different axis — Authz law).
- **GR10 — The router is untouched.** parseHash/legacyRoute/applyRoute preserved verbatim; the D14 5-anchor set (#fleet #sites #activity #instance/<id> #site/<id>) stays literal and test-pinned; /new and /activate stay OUTSIDE the shell; unknown-degrades-never-404 preserved. The sidebar is presentation over the unchanged IA.
- **GR11 — Freeze-by-generation SUPERSEDES freeze-by-convention.** bp-cloud-console-charter.md:7's freeze on app.css token blocks / index.html / styleguide.html was scope-discipline for THAT epic, generalized from a single-wave carve-out. This epic owns those files now; protection moves from convention to machinery (machine-owned emitted blocks; hand edits red the drift gate). Carried forward verbatim: OC9 append-only-tails sequential merge train (`__bpTestHook` exports, `__app.test.mjs`, app.css tail, `__preview__/scenarios.mjs`); parent D2 (closed SSE registry), D17 (nav frozen at 4 places + Settings; no dead-end shells), D25 (one recovery action per terminal state). DROPPED: the dangling D48/D49/D51 pointers. AMENDED: parent D35's freeze is formally noted as superseded for ⌘K (shipped OC17) and the liveness chip (shipped OC6); its other deferrals stay frozen. NAMED OPEN LIABILITY: parent D24's statusMeta/dep-pill SOLO-SPA sweep never landed (git-proven) — it remains a filed backlog task, NOT silently absorbed; any slice touching app.css component rules stays out of dep-pill/status-pill families.
- **GR12 — Theme lists become generated.** BP_THEMES + the picker options are today hand-lists that already drifted (charple emitted but unreachable — live proof). emit.mjs emits the theme-id list the SPA consumes; the pre-paint inline script (index.html:13) is EXTENDED, not reinvented (no Golden-Rule-4 conflict: tiny inline attribute-setter, zero network).
- **GR13 — Regression bar is 438/438 app tests + 28/28 smoke scenarios (both green as-run; the console charter's "2 known reds" note is STALE).** The shell slice may update smoke EXPECTATIONS + the ~6 structural DOM pins (auth-screen/login-card/auth-invite/instance-body/instance-tabpanel/auth-activate + the 5 shell ids) — deliberately, never silently. The reset-route `__bpTestHook` export + 2 tests (verified green at 440/440) land with the shell slice; a DOM-level reset smoke scenario is backlog.
- **GR14 — The designer handover is archived IN-REPO.** `.wave-handover-ui-review-9/` (59 files, sha256-verified copy of scratchpad ui-review-9) is committed to `design/handover/ui-review-9/`. EXIT.md is authoritative over file existence: P1-4 email fleet is NOT designed (despite Email Fleet.dc.html existing — its palette is off-ladder and its template roster non-enumerable); P1-4, P2-1/2/4/5 stay out of phase 1. The role vocabulary (owner/supporter/operator/admin/member) has no canonical source yet — backlog, don't invent.
- **GR15 — Priority order: tokens+gate → styleguide+contrast gate → fonts → shell.** Done = v4 shell live on the existing console, all screens reachable at their anchors, gates green and CI-wired. Elixir-touching PRs wait for the Elixir Test gate (repo law) and for the current runner outage (task-c76ee13a44b9231c) to clear before merge.
- **GR16 — Phase 2 (money path) is journey-cut along the app.js region seams, states-complete per slice.** Four slices, not nine outline numbers: FRONT DOOR (AUTH ~1810-2131 + OAUTH ~8106-8172 regions + index.html auth markup), PLAN & DUNNING (BILLING ~7350-7657 + SUBSCRIPTION + CHECKOUT-RETURN regions), LAUNCH THEATER (/new DEPLOY FLOW + C3 PROVISION TIMELINE + provider-picker CSS), HOME TRIAGE (OVERVIEW ~2628-2716, composed last — round 2 after Plan & Dunning merges). C-01..C-04 are STATES of two regions, not four screens. Verified ground truth inverts the risk model: the backend is AHEAD of the SPA on the whole money path — POST /v1/billing/portal + /v1/billing/cancel live and tested (91/0) while SPA copy denies they exist; /v1/onboarding 3-step self-healing runway complete (17/0 route tests, folded into /v1/me; GET member-readable, POST owner/admin-gated — asymmetry is deliberate); /v1/subscription already carries trial_days_remaining/current_period_end/past_due/cancel_at_period_end (no read-seam needed); openStudio 60s single-use ticket shared. Phase 2 is wiring + restyle, never backend feature-building.
- **GR17 — Copy law verdicts, ratified verbatim.** Dunning: DROP "We'll retry twice more" (zero code backing — `grep retry|twice|attempt billing.ex` empty; Stripe Smart Retries is a dashboard fact behind the billing human gate; a count-free "We'll try your card again before then." may return only as a post-gate amendment). Dates are data-driven, never hardcoded: {suspend_date}=subscription.current_period_end (grace anchor now+3d, @grace_days 3), {failed_date}/{since_date} derive from it. Ratified strings — topbar chip: "Payment failed · fix billing"; overview banner: "Your payment failed on {failed_date}" / "Your instances keep running until {suspend_date}, then they're suspended — not deleted." / btn "Update payment method"; billing-page banner adds "…and come right back the moment payment succeeds."; suspended instance-card: "Suspended {since_date} — payment failed" / "The server is stopped, not destroyed. Everything comes back exactly as it was the moment payment succeeds." (btn unified to "Update payment method"). Every dunning CTA → POST /v1/billing/portal; the "contact support"/"no billing portal" denial copy dies. "warn 3 days and 1 day before" is TRIAL-ONLY (dunning emails exactly once, at the active→past_due transition) — never in dunning copy. "suspended — not deleted" NEVER appears on trial expiry (trial end is real teardown, not suspend). Trial CTA comes from the RATIFICATION RECORD (task-2ed0ea068f37345d): "Pick a plan below to keep it. No card needed." — the v4 prototype still carries a superseded "…until then." draft; copy is always sourced from ratification records, never the prototype. The stale matrix past_due PNGs (21 July / 5-day) are NOT a copy source; the corrected source is the prototype text (19 July / 3-day).
- **GR18 — Theater honesty: conditional rail, real telemetry, snap-fail.** The step rail renders ONLY steps the server emits — SERVER_STEP_OPTIONAL (freshen/content) stay hidden until first reported; never hardcode the render's static 7 rows (screens/09 over-promises; the code's conditional model wins). `verify` IS live server telemetry today (registry.ex C8/D53, one discrete row per probe) — the stale app.js "server does not emit it yet" comment gets fixed in the slice. Price-before-charge: the REAL server-catalog price (formatMonthlyPrice — real Hetzner figures, nil-safe) renders above the rail per screens/09; plan-price digits (GR19) never appear as the theater price. Failure branch is NEW design ported from the deploy-ladder law: failed step snaps 0ms (never eased), remaining steps flip to skipped, one honest failCopy sentence sourced from provision_error/FailureCopy stating what broke + actual resource state. Console stays open-by-default (matches render + code); redaction is proven worker-side (internal/provisioner/console.go redacts BEFORE POST — tests pass) so no client scrubbing and no invented on-screen "redacted" label. ONE theater component serves /new and the in-shell provision fold (already the code's shape — readyHeroHtml/provisionSteps stay single-source). Instance provisioning is poll-primary (4s) with SSE as nudge; site deploys are push-primary — the component must not assume one telemetry model for both.
- **GR19 — Pricing/quota honesty under the placeholder gate.** Stripe price ids are literal placeholders behind the open human gate (cloud-console-billing-live-gate, not agent-buildable); no verification can make digits true this wave. Stance: keep USD (backend @currency "usd") and the standing $0/$69/$499 placeholders — the prototype's €12/€29 are equally fiction and NOT adopted — centralized in ONE PLAN_CATALOG constant whose comment names the human gate. "Unlimited managed instances" is a live FALSE claim and dies: plan cards state the real enforced ceilings (free 1 / supporter 3 / support++ 10 — matches backend @default_limits AND the prototype's quota text; the Overview fleet strip already renders the real quota, so keeping the lie ships a same-page self-contradiction). ERRORS map gains `limit_reached` + `billing_not_configured` entries and friendly()'s fallback-precedence bug (truthy error slug always beats the designed fallback) is fixed — owned by the PLAN & DUNNING slice as its one declared cross-region touch.
- **GR20 — Shell chrome slots: four slots, one signal each.** Sidebar plan pill (#ws-plan, plan NAME only), topbar billing chip (trial countdown "Trial · N days left" / past-due "Payment failed · fix billing", mutually exclusive, click→#billing), page-header fleet chips (attention/in-flight/healthy + slots meter), page-body banner/runway cards. Ruling on the charter-silent topbar question: the `.topbar-right` billing chip is granted to PLAN & DUNNING alone as a declared narrow exception to one-region (single injected element ahead of the SSE liveness chip — the OC6 precedent), because both its states are billing states. HOME TRIAGE owns the page-header chips + body cards and never touches topbar. The sidebar activePlan() bug (past_due team shows the free tier name) is fixed by PLAN & DUNNING.
- **GR21 — Front Door is a from-scratch composition mandate.** B-01..B-03 have ZERO design mocks (proven three ways: prototype grep, render inventory, EXIT.md — auth was never commissioned; the only auth-adjacent renders are post-login 2FA ENROLLMENT, a different surface). The slice composes login/signup/reset/2FA-challenge from the styleguide component vocabulary (card/btn/form-input/check-row/form-error/motion+responsive contracts) with explicit design judgment at the Kinsta/Vercel bar. Decoupling ruling: the shared 2FA card drops its imported `.new-title`/`.new-desc` theater classes for auth-scoped `.auth-title`/`.auth-desc` so FRONT DOOR and LAUNCH THEATER never contend; the shared primitives (.auth-tabs/.form-input/.field/.label/.btn-block/.oauth-*) are restyled ONCE here and /new + /activate inherit (LAUNCH THEATER must not restyle them). TFA_RATE_WAIT_S bumps 30→60 (the real limiter is a fixed 60s window; a server retry_after seam is backlog, not this wave).
- **GR22 — Proof-harness discipline for every phase-2 slice.** Each slice adds its states as scenarios.mjs fixtures + SCENARIOS entries + smoke EXPECTATIONS — APPENDED AT THE TAIL of each table (OC9; the verify probe's mid-file insertion is the anti-pattern). Per-slice screenshot proof = targeted single-scenario headless-Chrome shots (backgrounded/long-timeout — a fresh-profile shot costs 30-60s on this host); the full ~136-shot matrix is a Review/lead concern, never inline in a build. The GR13 bar floats upward — currently 481/481 app tests + 46/46 smoke as-run (2026-07-19, deliberate update; the 445/33 figure was stale) — pins update deliberately, never silently, and every slice cites its own live run, not this frozen number. Alias-retirement expectations are census-true: exactly ONE var (--primary-soft) retires from phase 2 (LAUNCH THEATER); slices do their app.css section rewrites without promising alias-count wins; the 16 zero-consumer vars are a separate backlog task (NOT --elev-* — those are the GR7 rename target).

- **GR23 — Wave 3 = THE DAILY DRIVER; Settings is deliberately NEXT wave.** Scope: D-01 fleet+archives, D-02..D-07 instance workspace, E-01..E-03 sites, I-01 activity, plus one hygiene slice (css_check parse-completeness guard + dead-var retirement + mock.js accent axis). Settings G-01..G-06 carries the phase's real design-needed greenfield (capability matrix, routing matrix, abilities picker, team env-vars page; providers/members have ZERO CSS today) and gets its own design-attentive wave — never a caboose seat. 8 slices, 2 rounds.
- **GR24 — D-02+D-03 are ONE slice; the one-region law bends to the call graph.** Proven at 5cac4ffe: `wireInstanceActions`(3602) calls `wireUpdatePanel`(def 4107) and `instanceOverviewHtml`(3529) calls `updatePanelHtml`(def 4058) — INSTANCE DETAIL (3289–3897) and UPDATE PANEL (3898–4491) are one journey in two adjacent sections. Amendment: a slice may own two adjacent sections when the code's own call graph entangles them; NO function relocation this wave (edits in place only). Boundary ruling: the verify cluster (`latestVerifyOf`…`runVerifyNow`, ~5625–5684, physically inside the TIMELINE section) is OWNED by the workspace slice; the timeline slice owns `mergeTimeline`…`refreshInstanceTimeline` and never touches `verify*` — exact function lists live in the two task briefs.
- **GR25 — GR11's pill quarantine forbids EDITING, not CONSUMING.** All four pill families (status-pill, dep-pill, tlv-badge, badge/fresh-badge) already sit on v4 tokens (--ok tracks accent.primary). Slices render the existing classes freely; nobody edits the dep-pill/status-pill CSS rule blocks. Only E-02 emits `.dep-pill` (app.js 6240/7037), as a consumer. The D24 statusMeta sweep stays backlog — its SOLO-SPA constraint is incompatible with a parallel wave by definition.
- **GR26 — The coalescing grammar is greenfield and becomes THE standard.** grep 0 in shipped code; the design precedent (v4.dc.html 2477–2488) is a narrow same-type example, not a component. D-04 builds a pure `coalesceEntries(entries, groupKeyFn)` + shipped `tlv-coalesce` classes (never literal `sg-*` imports — the `.notice`/`.sg-banner` precedent) satisfying styleguide §07 (worst-verdict summary; "Health report ×10 · every ~1m … · Show all 10"). Group key is PARAMETERIZED (type+target_id) because I-01's team-wide feed would otherwise fold unrelated targets. I-01 regrows on the merged grammar (round 2), rides GET /v1/audit (there is no /v1/activity); server filters today are target_type/target_id only — actor/verb-class filtering is client-side this wave (server params = backlog).
- **GR27 — Backend-truth rulings; ZERO new Elixir this wave.** Verify = exactly 3 probes (api/login/studio). Updates card = one PATCH /v1/barkparks/:id/autoupdate {autoupdate_enabled, autoupdate_paused, pinned_release} + separate POST …/rollback (re-pins to instance-reported sha). ≤2 domains per instance (custom_host is scalar). Usage = 13 meters (USAGE_METERS already 13-for-13 wired); design shows 12 — the 13th card follows the standard card pattern; LINEAR bars + sparklines, NO quota arcs (never designed anywhere). Metrics renders ALL 4 backend vitals (cpu/mem/disk/load — ratified over the design's 2) + honest "Not yet metered" stubs for req/s / p95 / api-requests; the live/stale/absent trichotomy stays (no fourth state). Deploy-ladder provenance ceiling = `trigger` (manual|content-auto), NEVER a named human — the actor exists only on audit events (site.deploy_requested), and the ladder stays trigger-only this wave. Env = ONE write-only full-blob replace (POST /v1/sites/:id/env, tested); no read-back (reveal_site_env has zero route callers as of 5cac4ffe), no production/preview scopes (wave-2 fiction). `scale_mode` has NO post-create writer (settings_changeset casts only theme/doc_type) — read-only display, the toggle dies.
- **GR28 — Dishonest-string kill list (preventive; live code is CLEAN — these are prototype/mock fictions that must not cross into the build):** (1) Marketing/Docs/Blank site-kind labels AND the New-site template picker AND the `siteMarketing`/`siteDocs` fixture ids — render real fields (framework/status/instance). (2) The Always-on/Scale-to-zero interactive toggle (keep the read-only `railRow("Scale", …)`). (3) The Metrics "warming up"/"14h / 24h collected" banner. (4) E-03's pre-filled env textarea — write-only truth means it starts BLANK. (5) "deployed by <human>" copy on the deploy ladder. E-03's button claims "…and redeploy" ONLY if the env route provably queues one — builder verifies in cloud/lib router.ex before shipping that word.
- **GR29 — Dead-var truth supersedes every stored census.** R2's live 16 = 11 generated `--cc-*` (retire at the SOURCE: delete role from CC_ROLES in design/emit.mjs + key from tokens.json cloudChrome, then `node design/emit.mjs --write` — never hand-edit app.css 45–256) + 5 hand-authored, of which ONLY --space-1/7/8 are deletable. **--elev-0/--elev-3 ARE R2-dead and stay anyway** — reserved decision-29 elevation-ladder rungs (--elev-1/2 live via --shadow aliases); a builder re-deriving from R2 must not "correct" this. gr-backlog-dead-vars' own var list is STALE (--primary-hover already retired; --leading-*/--text-* alive) — do not follow it. The css_check CSSOM parse-completeness guard (task-7836903b7ea83111, the #4251 star-slash postmortem) lands BEFORE/WITH the deletions in the same hygiene slice, proven by a #4251 regression fixture. Alias retirement this wave: sections rewrite onto tokens directly with no count promises; exactly ONE named retirement — `--accent` (sole consumer app.css:1402, inside E-02's scope).
- **GR30 — Proof bar + accent proof mechanics.** Decision-time live bar: 481/481 app tests + 46/46 smoke (re-run at merge, never quote frozen numbers). `panel-overview` and `metrics` are the exactly-2 scenarios missing smoke EXPECTATIONS — the workspace and usage-metrics slices add them at the tail. E-01 and I-01 have ZERO fixtures (no #sites/#activity deepLink anywhere) — built from scratch. Accent proof: mock.js has NO ?accent= param today, so non-evergreen shots are impossible; the hygiene slice adds it (mirror the ?theme= block: seed `bp_theme` localStorage + `data-bp-theme` pre-paint). Builders ship evergreen light+dark shots inline; the one non-evergreen LOOK-AT-IT pass per screen happens at Review AFTER hygiene merges (rotate identities; iris — zero per-screen proof anywhere — goes first). No .gitattributes union driver exists: the lead walks the 5 OC9 seams per merge as in phase 2; the hygiene slice merges FIRST in the train (it touches app.css broadly), then the app.js slices.
- **GR31 — GR13 pin clarifications (verified, not corrected — both pins are live).** `instance-body` is a STATIC shell id (index.html:409, never re-emitted by app.js — builders don't relocate it). `instance-tabpanel` is the dynamically-built child (app.js:3420) the workspace slice may move deliberately, updating the pin + tests. The "5 shell ids" = app-shell, nav-layer-root, nav-layer-instance, nav-layer-site, nav-operator (reconstructed from #4238's diff + regression note). The dead `fleetStripHtml` family in the C10 block is NOT D-01's target (live fleet = `fleetRow`, FLEET section) — its removal is a filed backlog task, untouched this wave.

- **GR32 — Phase 4 = THE SETTINGS WAVE (G-01..G-06), 7 slices, 2 rounds; the anatomy is a WRITTEN contract, not a serialized code slice.** Journey-cut per page; round 1 = hygiene (gr-p4-hygiene, merges FIRST — it lands the shared `.set-*` primitives) + the decoupled Elixir route PR (gr-p4-deliveries-route, first in the train); round 2 = the five page slices in parallel AFTER hygiene merges (they emit `.set-*` classes whose rules land with hygiene; an unruled emitted class hard-fails css_check E2 — proven). Prod-truth corrections, so no surveyor re-trips: barkpark.cloud IS live (prod app.js byte-identical to main's bundle — diff-proven); HEAD requests 404 on EVERY path by design (raw Plug.Router `get` macro serves GET only; `curl -sI` is the wrong probe) and `/login`/`/console` are client-side hash routes, never server paths — only `/`, `/dashboard`, `/new`, `/activate` serve the shell. Proof bar as-run at decision time: **544/544 app tests + 58/58 smoke + css_check 0 errors (748 classes/516 pairs) + emit 19/19 + design/check PASS** — GR30's 481/46 figure is stale; every slice cites its own live run.
- **GR33 — The settings-page anatomy contract (ratified concrete, billing is the named reference composition).** Five existing settings pages share only `.view-head`; their body grammars diverged five ways — prose underdetermines, so the primitives are code: `.set-section` (surface card: `--surface`/`--border`/`--radius-lg`/`--shadow-sm`/`--space-5` pad) SUPERSEDES `.notif-card` as THE settings card — no seventh card family; `.set-h` section heading; `.set-purpose` muted purpose line; `.set-save-row` (flex-end, top hairline). Save law: each independently-PERSISTED form section owns its OWN `.set-save-row` at its card's foot (sections POST to different endpoints — one page-bottom button would lie about atomicity); ACTION sections (billing, provider connect/disconnect, token list) get action rows + typed-confirm, never a save-row; provider connect is the hybrid (verify+save in a save-row, disconnect typed-confirm). PLAIN-MEMBER LAW (states-complete now includes it): a read-only section renders WITHOUT its save-row/affordances — never a disabled ghost, never a silent-403 button; every admin-gated page ships an explicit plain-member scenario. CONTRAST LAW: css_check E5 resolves only the declared CONTRAST_PAIRS manifest (proven: +4 greenfield classes left the pair count at 516) — any new fg/bg pairing MUST add its manifest entry or contrast ships silently unenforced; an unlisted pairing is a defect, not a green pass.
- **GR34 — Exactly TWO check grammars in settings; G-05's "checkboxes vs presets" is CLOSED.** `.set-check` = the `.token-ability` idiom generalized (bordered card row, bold name + MANDATORY consequence sub-line, client-side exclusivity mirror where the server enforces one) — for consequential choices: the abilities picker, consequential channel toggles. `.set-toggle` = `.notif-toggle`/`.check-row`/`.wh-event-opt` collapsed to one compact row, no sub-line — for dense self-evident grids: the G-04 event×channel matrix cells. v4 pill-chips are REJECTED as a checkbox grammar (they cannot carry the consequence line); `pill()` stays the single-select segmented control for transport/role choices. Settings-scoped supersede, not a global delete (webhook modal/create-site consumers keep their classes until their own restyle). The abilities picker is BUILT (app.js:1607-1725 — checkboxes + consequence sub-lines + root/deploy exclusivity mirroring server `normalize_abilities`); presets are REJECTED: the flags are non-hierarchical (write⊅read; root = universal gate-check bypass; root and deploy each mint-time exclusive), so a preset ladder would lie. G-05's real work = restyle onto `.set-check` + close the plain-member gap (a member may mint read-only per `pat_abilities_allowed?` — the picker renders that truth up-front, never via a post-click 403 toast).
- **GR35 — The wave's SINGLE sanctioned Elixir touch: `GET /v1/notifications/deliveries`.** Own tiny PR, FIRST in the train, decoupled so the Elixir gate can never strand the SPA train. `Auth.require_team_admin` (precedent: every other /v1/notifications/* mutation is admin-gated; deliveries carry recipient emails — audit-trail-adjacent). Pure exposure: `Notifications.list_deliveries/2` exists and is context-tested (5 call sites); `delivery_json/1` mirrors `audit_json/1`; `?limit` only via existing `parse_int` (no `?before` — that would touch the context; keyset + channel/status filters = backlog `gr-backlog-deliveries-filters`). Tests append a describe block to `router_notifications_test.exs` (401 / member-403 / empty-200 / newest-first / limit). No OpenAPI risk: the drift gate is api/-job-only, proven unable to fire on cloud/ routes. G-04's SPA renders the delivery log states-complete on fixtures and degrades to an honest error state when the route isn't live — it never blocks on this PR. Webhook test-send (task-050074a198b116c4) and TFA retry_after stay backlog.
- **GR36 — Per-page rulings (decided here so builders never re-decide):**
  - **G-01 Billing** — composition: PLAN_CATALOG re-mounts (launch theater step-2 forward-consumes it — the constant's shape is FROZEN). Billing writes are OWNER-only (`require_primary_team_owner`, stricter than every other settings gate); the client signal exists TODAY: `meCache.role === "owner"` (3-role vocab). Non-owners get honest copy ("Only the team owner can manage billing.") with no rendered CTA; the ERRORS map gains a `forbidden` entry (absorbs gr-backlog-portal-retry-sentence). In-app cancel SHIPS: "Cancel plan…" in the danger grammar riding the LIVE `POST /v1/billing/cancel` (owner + password-reconfirm — the confirm modal carries the password field, server truth; grace default; success renders "Access until {current_period_end}"). Invoice-less honesty: no invoice table ever exists server-side; the shipped "…in the secure Stripe billing portal" line stays the copy.
  - **G-02 Providers** — roster rows carry ONLY kind+label+connected-at (no health/verified field exists — never imply live validity). Verify-failure remediation copy is generic BY NECESSITY: the server collapses wrong-creds/provider-down/timeout into one `provider_unverified` + per-kind `FailureCopy.connect_remediation` — copy must not promise to distinguish causes. Connectable kinds = hetzner/azure/cloudflare ONLY (cloudflare has no catalog → no provisioning menu). The backend is silently ADDITIVE on duplicate connect (no unique index, no 409): the client renders an already-connected kind as "Connected — disconnect to replace" and offers no second connect (replace semantics = backend backlog `gr-backlog-provider-reconnect`). Disconnect = typed-confirm (it deletes ALL rows of that kind). Member view: read-only roster, zero connect/disconnect affordances.
  - **G-03 Capability matrix** — rendered from the LIVE `GET /v1/providers/capabilities`; the server emits `{providers:{kind:{tier,capabilities,gaps}}}` and NEVER `default_gap` (the wish's citation is half-wrong; the dead client fallback read dies). 9 verbs; dev-tier rows (`fake`) are filtered from the settings matrix; a false cell = dash + the server-owned gap reason (the v4 "a dash means we won't pretend" grammar transfers; its fictional data does not). GET is member-readable — no admin gating on the matrix. The Elixir contract test byte-pins the fixture to the Go CLI copy: any fixture edit must be a straight `cp` from `internal/cli/cloud/providers_capabilities.json`.
  - **G-04 Notifications (the crown)** — channels roster = ChannelConfig's 5 (discord/slack/telegram/pushover/webhook) + email; chat credentials are NEVER echoed (only `configured:bool`) — the UI renders configured/enabled honestly, no masked placeholder for chat creds (email secrets alone get "********"). Routing matrix = `chat_events` (9 + test) × 6 channels on `.set-toggle` cells riding the LIVE `PUT /v1/notifications/events`, with `chat_default_on` (the 4 failure events) rendered truthfully as the un-customized default. Delivery log rides GR35's route: newest-first, limit 50, NO server-side filters yet — the UI says so rather than faking filter affordances. `sendTestNotification` physically lives in the TOKENS span today: G-04 MOVES it into the notifications region (the wave's one sanctioned cross-region function move); G-05 must not touch it.
  - **G-05 Tokens** — per GR34. Plaintext-once reveal designed like it matters: input-affix + copy + the amber "only time you'll see this" banner; `pat_json` has no prefix/preview field — the list never fakes one.
  - **G-06 Members + env-vars** — THREE roles only (owner/admin/member; the 5-role list is design fiction per GR14 — rendering "operator"/"supporter" as team roles is the invention gr-backlog-role-vocabulary forbids). Remove-member = typed-confirm destroy tier (existing `openConfirmModal` primitive); revoke-invite = standard confirm (re-sendable, lower stakes). Invite truth in copy: accept_url plaintext shown ONCE + emailed fail-soft, 7-day validity, single-use. The env-vars page is NOT the site blob editor: row-based (`/v1/env-vars`), key visible, value sealed FOREVER (no reveal route exists — architecturally unreachable over HTTP), write-once → 409 surfaced as an honest per-row state, is_secret/is_shown_once/comment/scope team|barkpark. ACCESS MODEL: member-read / admin-write — E-03's any-member-write does NOT transfer. Shell touch = the dry-run-PROVEN 6-touch recipe (VIEWS + SETTINGS_VIEWS + applyRoute dispatch line + PAL_SETTINGS_LABEL + index.html nav link + `<section id="view-env">`): palette + router self-derive, zero test edits, 544/544 stayed green. legacyRoute's MAP gains NO env entry (env has no legacy hash; MAP is foreign non-GR lineage — see GR38).
- **GR37 — Hygiene slice contents (gr-p4-hygiene, merges FIRST).** (1) Dark `--btn-bg` RULING: identity-aware — `[data-theme=dark] --btn-bg` follows the identity primary exactly as light mode already does (fixes green CTAs on 4 of 5 identities; absorbs task-396a2fa055f92c51); `authButton` stays deliberately identity-invariant (pre-login there is no identity); the `--btn-bg`/`--btn-fg` CONTRAST_PAIRS row must hold across all 10 theme states. (2) FINISH GR29's cloudChrome retirement atomically in the THREE places — tokens.json (11 keys) + validate.mjs (CC_HEX_ROLES 22→13 + drop the backdrop/github checks) + emit.mjs (already reduced, untouched): the wave-3 revert happened because validate.mjs was never in any proof bar; `node design/validate.mjs` is now MANDATORY in every slice touching design/tokens.json, and tokens.json is diffed against origin/main immediately before union-integration (the union-drop tripwire). (3) `git rm cloud/priv/static/__app.test.mjs.orig` (the last tracked .orig, 395KB — #4275 removed the other two). (4) Land the `.set-*` primitive library (GR33 skeleton + `.set-check`/`.set-toggle`) — defined-but-unemitted CSS is gate-free (proven: 748→752 classes, 0 errors). (5) Harness role seam: `me()` gains an optional role param (default "owner") + document the `auditDenied`-style per-endpoint denied-flag pattern, so every page slice can ship plain-member scenarios. (6) `operatorVisible` path fix: read `meCache.user.platform_operator` (the GR9 gate is provably dead in prod — proven false-negative by vm-run; fix + nested-shape test fixture).
- **GR38 — GR7 census reframed: the honest closing report is ZERO named alias retirements.** The wish's "bridge near-empty after this wave" is unreachable by this charter's own design: GR7's aliases are permanent role-for-role translation under freeze-by-generation (GR11) — 9 live named aliases, 463 consumers file-wide, only 4 of which sit in settings-precursor CSS. Per GR22/GR29 law, settings sections rewrite onto ladder tokens directly (`--bg`/`--surface`/`--text`/`--border`) with no count promises; new pages never ADD alias consumers. The wave-close report states the residual as the 10-name census with live consumer counts. `legacyRoute`'s 5-entry MAP is NOT the GR7 bridge (it's hash-remapping under a foreign, non-GR citation) — a census that counts it is conflating two mechanisms. *(Counts corrected post-p4 by GR43: the census is NINE names, settings CSS consumes 7 of 9, and "never ADD consumers" was wrong as a literal claim — growth of the permanent names is by design.)*

- **GR39 — Operator console auth seam: NET-NEW session-gated `/v1/operator/*`; require_worker stays untouched.** New `Auth.require_platform_operator/2` reads the SAME allowlist as /v1/me's boolean (`Notifications.platform_admin_emails/0`, fail-closed) — ONE source of operator-ness; `isu-backlog-operator-principal` inherits BOTH reads when the real principal lands. GR9 held under verification: every fleet route is `require_worker`; a session token is 401-dead against it (test-pinned router_autoupdate_test.exs:196) and the Go CLI is EQUALLY dead (sends the bp-login session token — client.go:230/config.go:70; "browser parity" is refuted). Net-new routes, all thin proxies over existing functions, zero new business logic: `GET /v1/operator/autoupdate` + `POST …/halt|/resume` (Registry.autoupdate_halted?/set_autoupdate_halted), `GET /v1/operator/fleet` (per-instance channel/update_state/autoupdate_triggered_at + staging_gate_open? — the canary read that never existed), `GET /v1/operator/deliveries` via NEW `Notifications.list_fleet_deliveries/1` (`is_nil(team_id) and event=="fleet_digest"` — fleet_digest rows are recorded team_id=nil at notifications.ex:363 and are INVISIBLE to the team-scoped query at :514), `GET /v1/operator/warm-pool` (count_ready_warm_servers only). The SPA's loadFleetRollout (silently 401-dead in prod) repoints onto /v1/operator/autoupdate — THAT is what turns the dead console live. Never re-gate /v1/admin/autoupdate*.
- **GR40 — Operator render honesty rulings.** "Send one now" is CUT: no HTTP route calls deliver_fleet_digest (cron-only, daily_digest_worker.ex:30) — per GR28, no button without a route (POST /v1/operator/digest/send is filed as an explicit successor, gr-backlog-operator-digest-send). Settle copy = **20 minutes** (`@settle_grace_seconds 20*60` — the design's "30m" is wrong). Canary copy matches the worker verbatim: serial cohort-of-1, halt = advance-nothing brake, staging-blocks-prod gate. Warm pool renders ONE honest ready-count (only count_ready_warm_servers/0 exists; real statuses are 4 not the design's 3) with an honest near-zero caption — the off-box provisioner is not deployed, honest-zero is designed-for, not a bug. The operator view must not consume any fleetStrip* helper (GR42 kills them). No instance-lifecycle admin verbs (EXIT.md:13 rules those out of the GUI).
- **GR41 — Account 2FA lives in the ACCOUNT MODAL; the confirm grammar gains a danger-no-echo tier first.** The canonical renders (screens2/01-fixed, 02-fixed) caption the surface "Your account" — extend openAccountModal (app.js:501), never a #settings/account page (GR33 .set-* anatomy does not apply). There is NO password-reconfirm anywhere in the 2FA flow (every Accounts fn takes only current_user — verified; the live session is the gate). `meCache.user.two_factor_enabled` is served today and read NOWHERE — first read, zero new fetch. Two states are drawn (enroll QR+secret, recovery-codes plaintext-once); the undrawn states build to existing grammar: confirm-error inline (#pw-error pattern), On-row with Disable via openConfirmModal danger tier, Regenerate recovery codes modeled on 02-fixed, not_enrolled 422 → generic error. No external QR lib: manual secret entry + copyable otpauth:// URI are first-class; a dependency-free inline QR is optional polish, never a dependency. GRAMMAR HALF (merges BEFORE 2FA — shared openAccountModal region): openConfirmModal grows a **danger-no-echo tier** (btn-danger, no typed echo) + a rich-body slot, ADDITIVELY (existing confirmModal tests survive); both hand-rolled rollback confirms (confirmRollbackInstance app.js:4746, confirmSiteRollback :8112) fold onto it with inline failure per decision-25 (their close-modal+toast-on-failure dies); the 5 markup-pinning tests (__app.test.mjs 5794/5799/5810/2111/2126) are REWRITTEN, the pure copy mappers (rollbackConflictCopy, siteRollbackFailure/Result/FlashView/Path) stay green; the two bare-string dead toasts (app.js:7383/:7387 — toast() drops strings silently) are fixed WITH a toast-shape test; styleguide §16 documents the real modal families (form/account/cmdk/mutate/destroy/danger).
- **GR42 — Deletions sanctioned; D24 stays backlog (the charter was RIGHT, the digest wrong).** `gr-backlog-d24-statusmeta-sweep` EXISTS in the ledger (open, wave-1-filed, correctly scoped) — file NOTHING new, build NOTHING this wave: GR11/GR25's solo-SPA law is incompatible with the epic's widest wave by definition. fleetStrip* (app.js:12957-13066) + its 9 pinning tests (__app.test.mjs:3914-4057, 19 assertions) + hook exports ARE deleted this wave — this decision explicitly SUPERSEDES app.js:13068-13073's "stay pinned" comment; the suite count drops below 578 by design ("delete code + tests, suite green at N<578" is the criterion, never "keep 578").
- **GR43 — Census corrections (the closing report's honest sentence).** The GR7/GR38 bridge is **NINE names** — --bg/--surface/--muted-surface/--text/--muted-text/--dim/--border (shell vocabulary) + --shadow/--shadow-sm (elevation); the wave-log's "10-name census" was the stray error, now corrected. --step is D24 lineage (app.css's own comment: "until the decision-24 sweep retires it") — counting it conflates two mechanisms, exactly what GR38 warns about for legacyRoute. Settings CSS consumes 7 of 9 (all but --bg/--shadow) — GR38's "4" was accurate only through round 1. Consumer counts are re-run LIVE at close (463/505/516 are three point-in-time measurements with different methodologies; freeze none — the GR22/GR30 test-pin discipline applies). The ratified closing sentence: growth of the 9 permanent names is BY DESIGN; the retired names (--primary-hover, --accent) stayed dead; no page reintroduced a retiring var. `gr-backlog-alias-retirement` closes SUPERSEDED BY GR38/GR43: its "alias block empty" criterion is unreachable by law, and its mechanism was genuinely demonstrated 4 times (--primary-soft, 11 --cc-* + --space-1/7/8, --accent, cloudChrome 3-place).
- **GR44 — Provider reconnect = upsert-replace + defensive migration; prod DB truth.** Duplicate same-kind connect becomes impossible at the DB layer: the migration deletes duplicates keep-newest THEN creates `unique_index(:providers, [:team_id, :kind])` — prod verified 2026-07-19 to hold exactly 1 row / 0 duplicate pairs, so the delete is pure insurance against drift between now and deploy (connect_provider has no on_conflict until this lands). Semantics: connect_provider becomes an UPSERT that replaces encrypted_token+label (reconnect-updates-credentials); G-02's "Connected — disconnect to replace" copy relaxes to allow re-connect in place. Prod DB access truth: the control plane is dockerized postgres on **178.105.92.191** (`cd /opt/barkpark/cloud && docker compose exec -T db psql -U barkpark_cloud -d barkpark_cloud_prod`) — NEVER the CLAUDE.md legacy box (89.167.28.206), never `sudo -u postgres psql`.
- **GR45 — Webhook test-send spans TWO gates; two decoupled PRs; always say "webhook test-send".** api/'s elixir.yml fires on EVERY PR (no paths filter; jobs working-directory api; it alone owns the OpenAPI drift check) while cloud.yml is cloud/**-path-scoped — separate apps, separate gates, both run on a mixed PR. The api leg ships FIRST as its own PR (drift-check blast radius): `POST /v1/webhooks/:dataset/:id/test-send` — add "test" to Delivery @source_kinds (changeset-validated string list, NO migration), `create_test_delivery/1` mirroring create_media_delivery/1, synchronous single-attempt HMAC-signed send à la Dispatcher.deliver_media. The cloud proxy passthrough (9th route after cloud router.ex:2687, new `:"webhook.test_send"` InstanceApiCatalog entry) and the SPA "Send test" button follow separately. Notifications' transactional email test-send is an UNRELATED same-phrase feature — every brief and PR says "**webhook** test-send".
- **GR46 — Ledger integrity + doc-only closers.** The sha-by-sha stamp manifest is VERIFIED (22 unstamped-but-true criteria across 21 done children, every one bound to a real merged ancestor sha of origin/main; ZERO false-dones found) and the lead executes it this wave, including close_reason backfill for the 4 empty gr-p3 rows (all #4271 / 09735e96b). Supersession-close convention: lifecycle done + close_reason "SUPERSEDED by GRnn — …" + criteria left honestly unmet with the citation in evidence. Close-now set: task-396a2fa055f92c51 (fixed live, app.css:338, GR37), gr-backlog-settings-wave (GR32-38 + #4304), gr-backlog-dead-vars (GR29), gr-backlog-portal-retry-sentence (GR36 — ERRORS.forbidden absorbs it), gr-backlog-alias-retirement (GR43); drafts.gr-backlog-branch-exhaust is a stranded create artifact — discard (gr-backlog-wave-exhaust is the real task). Email fleet: ZERO HTML emails exist by documented YAGNI (16 plain-text kinds, not 14; transactional.ex:111 + digest_email.ex:24) and 11 of the mockup's 22 hexes have no token equivalent — gr-backlog-email-fleet-mapping closes as DECISION+ENUMERATION (keep plain-text; no restyle; no invented palette). Role vocabulary is DOC-ONLY (code already correct 3-role): one two-axis paragraph into docs/contracts/tenancy.md — team role (owner/admin/member) vs platform principal (platform_operator boolean, GR9); "supporter" is a billing plan, never a role. shoot.sh gets the PROVEN fix (SCEN scenario filter + ACCENT axis riding mock.js's existing ?accent= seam + background+PNG-poll+force-kill wrapper — macOS has no timeout(1) and Chrome reliably hangs AFTER writing each PNG; measured 89s→17s per 4-shot batch, 3.6s single shot) so Review's accent pass is one command; this lands gr-backlog-shoot-matrix-budget with before/after evidence.

- **GR47 — The p5r2 fact base: round 1 fully landed; the console harness on main is RED from a FOREIGN cycle.** All three round-1 PRs are merged ancestors of origin/main — #4390 `12a14a88b` (grammar pass, 17:01:23Z), #4391 `7a43e5847` (webhook test-send api leg + ops closers, 17:01:41Z), #4389 `567bf6e39` (the `/v1/operator` seam, 17:09:13Z, Cloud control-plane test SUCCESS, **and prod-deployed** — `Deploy (production)` green on that sha). The moduledoc `warm` → `warm-pool` typo was already fixed in-branch (`cc5c9d47a`) before merge; nothing gates the crowns. **BUT** `node --test cloud/priv/static/__app.test.mjs` on origin/main is **583 pass / 1 FAIL**: `coherence: the embedded TUI fixtures are byte-identical to the committed goldens`. Cause is the TLV epic (#4393 `aeefae415`) regenerating `internal/taskboard/testdata/styleguide_lifecycle.txt` (608 → 716 bytes) while `cloud/priv/static/__preview__/coherence.html` still embeds the old copy; `console-harness.yml` is path-filtered to `cloud/priv/static/**` so #4393 never ran it. **THE HONEST BASELINE EVERY SLICE CITES IS 584 tests / 583 pass / 1 pre-existing foreign failure · 77/77 smoke · 803 classes / 0 css_check errors · emit 19/19 · design/check PASS.** Never cite "584/584" and never cite the stale 578/77/799. A re-embed fix is proven to take the suite to 584/0; it ships as this round's FIRST slice and widens the workflow's path filter so the two goldens can never silently re-break it. Second gate truth: the cloud Elixir suite is **2106 tests / 0 failures at `--seed 0`** but has an ORDER-DEPENDENT FLAKE PAIR at random seeds (`router_sites_test.exs:857` `Sites.Deploy.run` → `{:ok, :failed}`, plus `cloudflare_standalone_degrade_test.exs`); both pass in isolation. A red on those two files is not the builder's bug.
- **GR48 — Wire the operator console against REAL BYTES, not the design mock.** Probe-verified JSON from live authenticated operator requests: `/v1/operator/deliveries` → `{"deliveries":[{id,status,kind,inserted_at,event,channel,recipient,attempts,last_error,http_status}]}` (`last_error`/`http_status` null on success); `/v1/operator/fleet` → `{"barkparks":[{id,name,update_state,channel,autoupdate_triggered_at}],"staging_gate_open":bool}` — **`staging_gate_open` is TOP-LEVEL, a sibling of `barkparks`, never a per-row field**; `/v1/operator/warm-pool` → `{"ready":n}`, a bare integer under one key. Both timestamps are `:utc_datetime_usec` → ISO-8601 UTC with six microsecond digits and a literal `Z` (`"2026-07-19T17:16:16.932308Z"`), safe for `new Date(s)`; **`autoupdate_triggered_at` is null for a freshly-registered box and MUST be null-guarded**, `inserted_at` never is. Render BOTH enum vocabularies completely: `update_state ∈ {unknown, current, behind, disabled}` — FOUR values, and `unknown` is the common freshly-registered case, not an edge; `channel ∈ {prod, staging}`. Any new route added anywhere in `cloud/.../web/router.ex` MUST add its `@moduledoc` route-table row in the SAME commit — `router_moduledoc_table_test.exs` is a DB-free source-text regex parser that fails in both directions (this is exactly what reddened #4389).
- **GR49 — The brake has ONE derivation, ONE action, ONE control; Fleet goes read-only.** There is no "working halt/resume banner" to deduplicate: `GET /v1/admin/autoupdate` is `require_worker` and the SPA sends only the session bearer, so `loadFleetRollout` has 401-died silently for every human since it shipped. Ruling: the pure `fleetRolloutBanner(state)` derivation stays byte-unchanged (its two node pins survive); the operator console renders a SECOND presentation of the SAME model and must never restate its copy strings; `fleetRolloutAction` is parameterized off the Fleet container so the console can refresh its own card; the route literal `/v1/operator/autoupdate` is defined ONCE. `#fleet` is TEAM-scoped, so a fleet-wide brake button there is a scope mix — Fleet keeps only a READ-ONLY, halted-only banner linking to `#operator`, and the console is the sole emitter of the action attribute. Anti-drift guards are four cheap node assertions: `/v1/admin/autoupdate` occurs **0** times in `app.js` (it is exactly 3 today — one comment, two calls) and the operator literal exactly once; the console card contains the shared banner's `.title` and `.actionLabel`; exactly one emitter of `data-fleet-au`. **The operator route gate must be a separately-exported PURE predicate** (e.g. `operatorRouteAllowed(me)`) node-pinned in `__app.test.mjs` — `applyRoute` is NOT hook-exported and cannot be pinned; and once `"operator"` joins `VIEWS`, `init()`'s validator accepts a deep-linked `#operator` for ANYONE, so the view must fail-closed BOUNCE a non-operator to `#overview` (`applyOperatorGate` today gates only the sidebar link). Operator stays OUT of the Cmd+K palette this wave — `paletteNavItems()` is a static argument-free registry that cannot see `meCache` (filed as a successor).
- **GR50 — Honest operator copy, ratified verbatim.** Warm pool: **no bar, no percentage, ONE number** — `count_ready_warm_servers/0` merges `ready + refreshing` out of FOUR real statuses, and the target size lives in the off-box provisioner's env (`WARM_POOL_SIZE`), which the control plane never receives, so there is no denominator to draw. Caption: *"Counts boxes that are ready to claim plus boxes mid-refresh — both are pool members. Boxes being claimed or retired are already on their way out and aren't counted. The pool's target size is set on the provisioner, not here, so there's no total to compare against."* Zero state: *"The pool is empty right now. Launches still work — they provision a cold box instead of claiming a warm one."* Unreadable state: *"Warm pool unavailable — the count didn't answer. That says nothing about the pool itself; this card just couldn't read it."* **Correction to GR40's premise: the pool is NOT dead** — prod runs `barkpark-provisioner` active with `WARM_POOL_SIZE=2` and `warm_servers` holds 2 ready rows; "reads ~zero until the provisioner ships" would itself be fiction. Canary: *"Gates: SETTLE 20m → health GATE → ADVANCE. An instance that hasn't reported itself current within 20 minutes is paused, not retried."* Staging gate renders THREE states, and prod is in the third today (zero staging boxes registered → `staging_gate_open?` returns true through its empty-list FAIL-OPEN branch): open-and-vouched / **open-because-nothing-is-ahead-of-it** / closed. Fleet digest: prod has 38 delivery rows and **zero** `fleet_digest` rows, so the honest state is empty — *"No fleet digest has been sent yet. The digest goes out daily at 06:00 UTC to the platform-operator addresses."* No Send-now button (GR40 stands).
- **GR51 — `fleetStrip*` is NOT one atomic family; a blind delete breaks the LIVE Overview.** Proven by running: deleting everything matching `/fleetStrip/` throws `ReferenceError: fleetHeadlineSpec is not defined` from `instanceCardStats`/`instanceCardHtml`, the live v4 Overview instance-card renderers. Ruling — **DELETE five**: `FLEET_STRIP_METERS`, `fleetStripWorst`, `fleetStripModel`, `fleetStripCellHtml`, `fleetStripHtml`, plus their four `__bpTestHook` exports and the 9 pinning tests. **RELOCATE, never delete, two**: `fleetStripSpecFor` and `fleetHeadlineSpec` move next to `instanceCardStats`/`OVERVIEW_CARD_STATS`, their one real caller (renaming off the `fleetStrip` prefix is encouraged — they were never strip-exclusive). Proven-green result: 574/575 (the one remainder being GR47's foreign coherence failure, which slice 1 removes), css_check 0 errors, 793 classes / 81 allowlisted. Same slice sweeps the gate-invisible residue: 17 orphaned `.fleet-usage-*` rule blocks in `app.css` and the two now-stale `ALLOW_PREFIXES` entries (`fleet-usage-cell`, `fleet-usage-metric-v`) — `__css_check.mjs` has no unused-rule or stale-prefix detector, so nothing else would ever catch them. GR42 stands, corrected in scope.
- **GR52 — Two honesty corrections, one new ops gate, one seal ruling.** (a) **The role-vocabulary premise was false**: `docs/contracts/tenancy.md` has no "two-axis paragraph" to fix and already states the correct 3-role model at line 44 (`Two role axes (GR46)`, landed via #4391). `gr-backlog-role-vocabulary` closes as a NO-DIFF resolution once cross-linked to `isu-backlog-operator-principal` — it is not a slice. (b) **`POST /v1/account/two-factor/confirm` has no rate limiter** (proven: eleven wrong codes → eleven `422 invalid_otp`, no 429, no lockout, correct code still accepted after). It is NOT a security gap and is NOT filed as one: the route is `require_user`-gated, the "secret" being guessed was just handed to that same session in plaintext by `enroll`, and that session can already `DELETE /v1/account/two-factor` with no reconfirm. Consequence that DOES bind: **the 2FA confirm surface has NO 429 state** — draw `422 invalid_otp` and `422 not_enrolled` only; inventing a rate-limited/try-again-in-Ns state would violate GR28 in the same wave that codifies it. Any future hardening needs its OWN key namespace (reusing `TwoFactorRateLimiter` keyed on user id would let an enrollment fat-finger lock the user out of LOGIN). (c) **NEW BLOCKING OPS GATE**: `PLATFORM_ADMIN_EMAILS` is ABSENT from the live control plane (`/opt/barkpark/cloud/.env` and `control_plane_blue`'s environment both), so `platform_admin_emails/0` returns `[]`, `/v1/me` reports `platform_operator: false` for EVERY user, the sidebar link stays hidden, all six `/v1/operator/*` routes 403 for everyone, and `deliver_fleet_digest` short-circuits `{:ok, :no_admins}`. **The operator console cannot be live-proven until an operator sets it and restarts** (`gr-ops-platform-admin-emails`). Slices build and gate against fixtures regardless; only the live-proof criterion waits. (d) **Seal ruling**: `gr-backlog-console-redaction-allowlist` is the epic's ONE true orphan — Go `internal/provisioner` + `internal/builder/console.go` work, outside this epic's `cloud/` boundary. It is hereby a NAMED POST-SEAL SUCCESSOR (listed below), which is what makes the seal honest rather than silent.
- **GR53 — The p5r3 fact base: act one landed WITHOUT us, and every inherited line number is stale.** All four round-2 PRs are merged ancestors of `origin/main`: #4432 `c2dc2e0f5` (coherence fixture), #4433 `301e035d8` (backend honesty batch 1), #4430 `6bc7646ff` (cloud-flake), and the crown #4434 `93fd1e2d8` (the operator console) — merged with its reviewer fix in the sha (`index.html:215` carries `data-view="operator"`). `cloud/**` has not moved since. **THE ONE TRUE BASELINE, re-run in a clean worktree at `origin/main` and cited by every slice: `node --check app.js` OK · `node --test __app.test.mjs` 600 tests / 600 pass / 0 fail · `node __css_check.mjs` 810 classes / 90 tokens / 516 contrast pairs / 85 allowlisted / 9 known gaps (R3) / 0 errors · `node __preview__/smoke.mjs` 81/81.** GR47's "584/583/1 foreign failure" is DEAD — #4432 fixed it and the crown added the 16th test. Never cite 584/803/77 again. Post-crown anchors (true at `93fd1e2d8`, RE-GREP at every slot handoff — the crown moved everything by 300+ lines): `app.js` 15774 lines, `MARK:zone-console-helpers` :15345, `MARK:zone-console-hook-map` :15648, `openAccountModal` :523; `__app.test.mjs` 8336 lines, `MARK:zone-console-tests` :85 (a **HEAD** anchor — new groups go BELOW line 85, never at EOF); `scenarios.mjs` `SCENARIOS` 1052→2477; `smoke.mjs` `EXPECTATIONS` 223→1507; `app.css` EOF 4334; `index.html` 552, static `aria-labelledby="modal-title"` :544. The cloud router is `cloud/lib/barkpark_cloud/web/router.ex` — `control_plane_web/router.ex` does not exist and a builder grepping it gets ENOENT. **The primary checkout is 6 ahead / 35 behind `origin/main` with 26 dirty FOREIGN files: every slice branches from `origin/main` explicitly or silently loses the entire round-2 train including the crown.**
- **GR54 — GR41 AMENDED: the account modal is RECOMPOSED IN PLACE, not extended.** GR41 forbade a `#settings/account` page; it did not, and does not, forbid composing the modal body fresh. That prohibition stands unchanged — the surface remains `openAccountModal`. What changes: `01-fixed.png`/`02-fixed.png` are a different COMPOSITION from the shipped body (identity row, "Change password" as progressive-disclosure link, "Sign out everywhere else" inline-right IN the Sessions header, a 2FA header with a right-aligned state badge), and bolting a v4 block onto a legacy body ships a two-language modal in the wave that seals a coherence epic. **The recomposition is COMPOSITION-ONLY and is PROVEN safe, not argued safe**: a probe extracted `accountModalHtml(session)` as a pure hook-export, added 8 structural pins, and MUTATION-PROVED every one (six mutations, each reddening exactly its own test) — harness 600 → 608, css_check unchanged 810/0, smoke unchanged 81/81. Binding constraints: `submitPasswordChange`, `loadSessions`, the revoke-all listener and `#modal-logout` keep their element-id contracts and behaviour byte-for-byte; the recomposed `<h2>` MUST keep `id="modal-title"` (index.html:544 binds `aria-labelledby` STATICALLY on the shared `.modal-card`, so dropping it strips the accessible name from EVERY modal); palette id `act-account` is law (`__app.test.mjs:5689`) while its LABEL is free; `.session-revoke` and `.badge-current` are named in `__css_check.mjs` :128/:219. **The pins land as the PR's FIRST commit** so the recomposition is written against a live net. One earlier guard was VACUOUS (a source-regex matched its own commented-out line) — behavioural tests only, never source-regex, for anything that can lock a user out. Keep the Close/Log-out footer: both renders crop mid-scroll and an unverified subtraction is not a design fact.
- **GR55 — THE QR SHIPS, and circular verification is BANNED.** A dependency-free byte-mode encoder was written and PROVEN in a spike, not estimated: 302 lines, zero imports, byte-identical to an out-of-repo reference encoder on 276/276 randomized otpauth URIs (versions 5–10, EC L/M/Q/H, ZERO structural mismatches, RS syndromes zero on every block) and decoded by an independent reader on 198/200 production-shape URIs. The 2 misses are an OpenCV mask-2 weakness, PROVEN not an encoder defect — the reference encoder's own matrices for the same URIs at the same forced mask fail identically (41/43 both). Dependency-freedom is structural: `cloud/priv/static` has no `package.json` and none may be added. **Hand the builder the artifacts, never a rewrite brief**: `~/.claude/gr-p5r3-qr-spike/{qr.mjs,decode.mjs,qr-fixture.json,mkfixture.mjs}` — re-verified reproducing byte-identical at Decide (`v7/mask4`, `v6/mask4`, `v2/mask6`, all MATCH true). The spike caught FOUR bugs invisible to code review (transposed format-info layout, reversed generator polynomial, alignment patterns dropped on the timing row at v7+ — exactly our production version, and a penalty-rule-3 edge miss); a from-scratch rewrite re-introduces some subset of them. **A self-written decoder verifying a self-written encoder is CIRCULAR and gave a confident green on a matrix with a transposed format block AND a broken generator — the ONLY sanctioned gate is a byte-match against the committed fixture.** Required builder lines: commit `qr-fixture.json` + the byte-match test; wrap `qrMatrix` in try/catch (it throws at 214 URI bytes / local-part ≥113) and on throw render the manual-entry panel ALONE, never a broken box; delete the dead `REMAINDER` const and the test-only `forceMask`. Manual secret entry stays first-class per GR41 — that is what makes the residual scanner risk non-fatal.
- **GR56 — The recovery-code sheet is one-shot, so HARDEN ITS EXITS — and the × is a trap.** Eight codes, 8-char lowercase base32, SHA-256 at rest, plaintext once, never re-servable (`two_factor.ex` :96-110, :145): losing the sheet is unrecoverable. Copy all AND Download `.txt` (Blob URL, zero deps). "I saved them" is the only exit. **`.modal-x` carries `data-close` (index.html:544), so it rides the SAME delegated handler as the backdrop — pinning deadens it, and a visible dead × is strictly worse than no ×: HIDE `.modal-x` while pinned.** The pin is `modalDismissAllowed(pinned, via)`, a pure 3-line hook-exported predicate over four `via` values (`escape`/`backdrop`/`close-x` refuse when pinned; `explicit` ALWAYS passes), consulted ONLY inside `wireModal`. `closeModal()` stays completely ungated and `openModal` CLEARS the pin on every open (fail-open) — a stale pin would otherwise lock the NEXT modal (launch, env-editor, confirm) shut with no explanation. Both facts are behaviourally tested, and a careless global patch to `wireModal` regresses Escape on every other modal.
- **GR57 — Fixed-blue is `--info`/`--cc-blue`; the modal widens by SCOPE, never at the base.** `.btn-link` colors itself `var(--primary)` (app.css:2631-2635), which IS the user-selectable accent — `--primary` is redefined in 10 blocks across the 5 identities, so the design's fixed-blue links ("Change password", "Copy", "Copy all") would render orange under Ember and purple under Charple in the very wave that seals a coherence epic. `--info` = `--cc-blue` (app.css :59/:69/:96/:106) is declared ONLY in `:root` and `[data-theme="dark"]`; grepping all ten `[data-bp-theme=…]` blocks for an override returns zero hits — it is the correct accent-independent token. Ship a scoped variant, never repurpose `--primary`. Width: the design measures ~518-520px against `.modal-card { max-width: 420px }` (app.css:982), which is the SHARED base for 15+ modal bodies — widening it fattens the env editor, token creation and provider picker, none of which were designed at 520px. **Follow the live `:has()` precedent** (`.modal-root:has(.cmdk) .modal-card { max-width: 600px }`, app.css:3526): add a second scoped rule keyed off a class unique to the recomposed account body. Green filled "I saved them" stays on the accent-independent `--success`/`--ok`, exactly as `.badge-current` already does.
- **GR58 — GR30's accent proof WAS NEVER EXECUTED: `shoot.sh` silently drops the accent for 89% of scenarios.** `shoot.sh:122` builds `?scen=$scen&theme=$theme$deep$accent_q` — `$accent_q` lands AFTER the deep-link hash, and `mock.js:32` reads accent from `location.search` only, which excludes everything past `#`. 72 of 81 scenarios carry a non-empty `deepLink`, so every accent-suffixed filename for them is a LIE: the shot renders evergreen regardless of `ACCENT=`. Proven both ways — `operator-visible` at `ACCENT=ember` rendered plain evergreen with "Evergreen" in the picker; the identical scenario re-shot with accent ordered BEFORE the hash rendered true Ember throughout. Every non-evergreen "proof" this epic has ever cited for a deep-linked screen is void. **Fix is one line — `…&theme=$theme$accent_q$deep` — and it ships THIS wave, before any accent claim is made again.** Second harness truth: `mock.js` has NO modal auto-open seam (`grep openModal|autoOpen` returns nothing) and scenarios reach screens by `deepLink` only, so the account modal — the last unremade screen — is structurally INVISIBLE to the accent×theme matrix. `serve.mjs:41-43` injects `mock.js` immediately before `app.js`, so a `?modal=account` seam capturing `__bpTestHook` is ~6 lines; `mock.js` is not one of the five tail zones and is collision-free. Without it the recomposition ships eyes-off.
- **GR59 — A real shipped layout defect at the harness's own tablet width.** `.fleet-row` reflows to a column only `@media (max-width: 720px)` (app.css:1881) and `.attention-row` gains `flex-wrap` only `@media (max-width: 620px)` (app.css:2673), but `shoot.sh`'s `WIDTHS=(1440 768)` tests **768px** — wider than both, and too narrow for the un-reflowed row. Result, reproduced in both themes on two components: Fleet's `.fleet-meta` dot-joined tokens wrap one-per-line and collide with the badge cluster; Overview's `.attention-row` instance name is partly hidden behind the action buttons. This is NOT residue of the crown's unclosed-`@media` fix (different selectors) — it is pre-existing, and 768px (added in #4391, the same commit as the ACCENT axis) is the first pass ever wide enough to expose it. `__css_check.mjs` is a static class linter and structurally cannot catch it. Fix belongs to the SPA-finishers slot, which already owns `app.css`.
- **GR60 — The ops gate is THREE ordered steps, not one `.env` edit; a bare `.env` edit is a FALSE GREEN.** `PLATFORM_ADMIN_EMAILS` is absent from `cloud/docker-compose.yml`'s `x-control-plane` `environment:` passthrough list (25 entries, 16 bare vars, this one not among them), from `cloud/.env.example`, and from every runbook — and compose passes nothing it does not bare-list (the file documents its own rule at :16-19). So setting it on the box alone leaves the container BLIND while the var reads as "set". The task's own ACTION text is therefore the false-green recipe, and its "NOT AGENT-BUILDABLE" framing is far too pessimistic. Ordered: **(1)** a merged PR adding one bare `- PLATFORM_ADMIN_EMAILS` line to the compose environment block, the `.env.example` stanza that stops the omission recurring, and an env→config→resolver→gate test — agent-buildable, and `cloud/**` auto-deploys it with the var still unset, still `[]`, still fail-closed, zero user-visible change; **(2)** a human appends the address line to `/opt/barkpark/cloud/.env` — the ONE genuinely human decision, because no doc, charter, runbook or `.env.example` names the operator addresses anywhere, and each must ALREADY be a registered account (`platform_admin_emails/0` silently drops unregistered entries with no log, no boot warning, no `/v1/me` signal); **(3)** re-run `deploy/cp-deploy.sh` on the box — the only path a `.env` edit reaches the container, zero-downtime, but it ALTERNATES the blue/green slot each run and always pulls current `origin/main`, so it is a real deploy, not a config edit. **Stamping the operator console's live-proof criterion on anything less than `docker exec … env | grep PLATFORM_ADMIN_EMAILS` from the ACTIVE slot plus a 200 from `/v1/operator/warm-pool` is the fabricated seal this ruling exists to prevent.**
- **GR61 — Seal ruling, corrected against a fresh ledger read.** The epic has **70 children: 44 done / 26 open — ZERO `in_progress`.** The four round-2 children are `done` with one unmet MERGE criterion each: that is stamp-lag, not fabrication, and it is a criterion-level delta, not a lifecycle transition. **Exactly one false-done exists: `gr-p5-cloud-flake`** — `done` at 3/5 with an EMPTY `close_reason` and a criterion 0 that is structurally unmeetable, because its own attempts note refutes it ("no seed reproduces reliably… the SAME seed gave 1 failure then 0 failures"; the defect is a concurrency race, not a seed-ordering artifact). Ruling: **REWORD criterion 0** to what was actually achieved and is actually decisive — a DETERMINISTIC reproducer by narrowing to the colliding module pair — then stamp it with that evidence. Rewording beats an unmeetable-close because the root-cause and after criteria already stand on that same repro. Three open backlog rows were made true by #4433 and must be stamped, not re-built: `gr-backlog-deliveries-filters` c0 (close-now), `gr-backlog-tfa-retry-after` c0 and `gr-backlog-audit-filter-params` c0 (both stay OPEN — their SPA legs are provably unbuilt: `app.js:2738` still calls the retry_after seam backlog, and `actor_user_id`/`action_prefix` appear zero times in `app.js`). Two corrections to the seal's residue list: **`cloud-console-billing-live-gate` is NOT a child of this epic** (its parent is the already-`done` `cloud-console-goal`, so it is an orphan under a sealed epic and re-parenting this epic's children will never reach it — it must be moved BY NAME or it vanishes); and `task-050074a198b116c4` IS absorbed by spa-finishers and is not a survivor. `gr-backlog-role-vocabulary` is already `done 3/3` — drop it from every slice brief as a phantom. **The seal is a REVIEW-phase act, not a Decide-phase one**: this wave's slices must merge first. Zero UNNAMED residue is the bar, not zero residue — the survivors go to ONE named successor epic, filed NOW so it is never silent.

- **GR62 — The four PRs did not land this wave; they landed BEFORE it, and they are LIVE.** #4480 `815cd4d99` (20:41:40Z), #4481 `382f23540` (20:41:53Z), #4482 `09f229d5d` (20:42:04Z), #4483 `d220c53e0` (20:42:16Z) are all MERGED ancestors of `origin/main`. Five deploy runs were collapsed by the `deploy-production` concurrency group (`cancel-in-progress: false`); the ONE survivor, run `29703009543` for `d220c53e0`, is `completed/success` at 20:51:12Z with all three jobs green (control-plane 20:48:59Z). **Live is byte-identical to `origin/main`**: `app.js` 850,199 bytes sha256 `870c1f78…04cd44`, `app.css` sha `128d5c3fad01`, `index.html` sha `702d8ddd06c7`, `diff -q` silent on all three; `/favicon.ico` 200 and byte-identical (15,086 B, sha `71321afd…`); `HEAD == GET` on 8/8 shell paths, which proves the merged **Elixir** side is running, not just the assets. The seal's factual base is live pixels, not a MERGED badge. Byte-identity is point-in-time: whoever writes the seal RE-RUNS the sha comparison at stamp time rather than citing this line.
- **GR63 — THE CROWN SCREEN IS BROKEN IN PRODUCTION, and no fixture could ever have seen it.** Logged in as a real account (19 live sessions), the account modal renders **1655.5px tall inside a 900px viewport with no scroll path anywhere**: `.modal-root` (app.css:976) is `position:fixed; display:grid; place-items:center` with **no `overflow-y`**, and `.modal-card` (app.css:978) has **no `max-height`** — GR57 widened the account modal to 520px and never bounded its HEIGHT. Every scroll avenue was exhausted (`modal-root`/`modal-card`/`window`/`body`/`documentElement` scrollTop, `focus()` + `scrollIntoView({block:'center'})`) — all stayed 0. **11 of 28 controls (39%) are permanently unreachable**, including "Set up two-factor authentication" (y=1574.5 — this account CANNOT enable 2FA) and **"Log out" (y=1623), which is the application's ONLY logout affordance** (73 buttons/links outside the modal, zero matching log out / sign out). Measured threshold: base chrome 287.5px + 72px session-row pitch ⇒ **8 sessions fit, 9 break it**; harness fixtures carry a handful, which is exactly why five waves of green fixtures never saw it. The fix was validated in-browser (`overflow-y:auto` + `align-items:start` on `#modal-root`, `margin:auto 0` on `.modal-card` so short modals stay centred): scrollTop reached 791.5/1704 and both blocked controls became reachable. Under the seal law's "zero known user-facing defect" this is **BLOCKING** — it ships as the FIRST commit of `gr-p5r4-spa-a`. It lives in the SHARED modal primitive, so a `:has(.am-modal)`-scoped fix is REFUSED: every tall modal inherits the bug, and the fix must be re-checked against a SHORT modal so centring does not regress.
- **GR64 — `gr-p5-spa-finishers` splits into TWO SEQUENTIAL slices in the same train slot, not one, and not two parallel ones.** Part A was not estimated, it was EXECUTED against `origin/main` `d220c53e0`: the GR51 recipe applied clean in one pass at **+16 / −404 across exactly the 4 briefed files**, landing 617 tests / 832 classes / 83 allowlisted / 84 smoke / 0 css_check errors — **−9 / −10 / −2 / unchanged, the brief's prediction to the unit**, with the GR42/GR51 operator-console guard test still green (the independent proof the relocation worked). A slice whose largest act is reproducible by a 20-line script must not sit in the same PR as authoring six CSS families from no design spec. **`gr-p5r4-spa-a` (round 1)** = the GR63 blocker + the focus-ring gap + GR51's deletion/relocation + GR59-widened + the JS-only cap-payload guard: all measured, all mechanical, and it carries BOTH blocking user-facing defects so they cannot slip behind judgment work. **`gr-p5r4-spa-b` (round 2, AFTER spa-a merges)** = the six CSS families, the four backend wire-ups, and the operator zero-staging fixture — the judgment half, and the natural home for the matrix's findings. The rebase cost is three small windows (`__css_check.mjs` ~65 lines, the `__bpTestHook` tail ~5 lines, `app.css`/`__app.test.mjs` disjoint). **The corrected post-merge baseline every slice cites is 626 tests / 842 classes / 90 tokens / 516 contrast pairs / 85 allowlisted / 84 smoke / 0 errors** — GR53's 600/810/81 is two rounds stale, and the brief's 600/810/81 must never be quoted again.
- **GR65 — GR59 is WIDER than its own ruling names, and the fix must target the BLOCK, not the two selectors.** `.detail-grid` collapses to one column only inside the SAME `@media (max-width: 720px)` block as `.fleet-row` (app.css:1890), so at the harness's 768px it stays two-column and the right-hand column clips at the viewport edge — reproduced in **two** consumers that share the class: `panel-overview` (`.detail-grid--instance`, app.js:4985 — "Host production-5b2c1e.barkpark.cl[oud]" cut) and `rollback` (bare `.detail-grid`, app.js:8358 — Site ID / Framework / Repository / Current / Created all right-truncated). A fix that patches only `.fleet-row` and `.attention-row` re-ships the same symptom class eyes-off. Ruling: `gr-p5r4-spa-a` addresses the whole `@media (max-width: 720px)` block's threshold against the 768px the harness actually tests, and proves it with before/after 768 shots in BOTH themes. Separately, `.btn-link` has no `:focus-visible` rule and is absent from app.css's own shared house-ring allowlist (app.css:441-456, whose comment says "New panels: add your class here rather than re-rolling the ring") — `openModal` autofocuses `#am-pw-toggle` (`class="btn-link am-link"`, app.js:680), so the account modal paints a **UA-default blue rectangle** in evergreen, iris AND ember while every other `--ring-soft` target changes colour per accent. Accent-independent, both themes, 1440 — user-facing by the wave's own triage rule; one line at app.css:445. Honest scope: `:focus-visible` is a keyboard-path defect, not "every user sees a blue box".
- **GR66 — The matrix instrument LIES about 13 of 84 scenarios, and the fix has a booby trap inside it.** `shoot.sh` reads only `s.deepLink` and always requests pathname `/`, while `app.js` gates `isNewFlow` (:12436) and `isActivateFlow` (:14912) on exact pathname. Proven with pixels, not code reading: `activate-entry` shot the **logged-out Log in / Sign up card** (the correct URL renders "Approve a device sign-in"); `account-modal` shot the **plain Overview with no modal** (`&modal=account` renders the full "Your account" dialog). Twelve scenarios land on a completely wrong screen (5 `/activate`, 4 `/new`, 3 `account-modal` — the last three carry `deepLink:""` and are structurally unreachable); the 13th, `billing-portal-return`, renders the right screen but silently loses its portal-return state (app.js:11574 never fires). At 5 accents × 2 themes × 2 widths that is **240 mislabeled PNGs out of 1680**, and folding them in unexamined would recreate — in the wave that exists to end false greens — exactly what #4483 was filed to kill on another axis. The fix reads `pathname`/`search` and derives the modal flag from the `account-modal` name prefix, and it **MUST join/split its scenario TSV on `\x1f` (US), never TAB**: tab is IFS whitespace, so bash collapses empty fields, `deep` becomes `/`, the URL becomes unloadable, and Chrome screenshots its **New Tab Page under an `ok` filename** — a third false-green class born inside the fix for the second, reproduced then eliminated. The patch touches ONLY `shoot.sh` — none of the six SPA tail anchors — so it rides its own micro-slice in round 1 at zero sequencing cost.
- **GR67 — The matrix is a REVIEW act with its triage rule fixed BEFORE the shots, and Decide does not run it.** Measured cost on this host, not estimated: 3.0–4.0 s/shot strictly serial (no parallelism in `shoot.sh`), so the full 5-accent × 84-scenario × 2-theme × 2-width sweep is **1680 shots = 84–112 minutes**, one accent is 336 shots ≈ 20 min, and **nobody has ever run it whole** — a partial pass this session reached 14/72 scenarios before time-boxing. Review runs it after the seam fix lands, on the STATIC harness only (a dev server is barred — the local API OOMs), at an EXPLICIT non-default `PORT=`/`OUT=` (port 4180 was held by a concurrent session shooting the UNPATCHED matrix), and **asserts the 1680 PNG count before drawing any conclusion** — a typo in `SCEN` emits nothing and still prints `>> Done.` Triage, fixed now so "is this blocking?" is a lookup and not a negotiation: reproducible in ANY shipped identity at 1440 ⇒ user-facing ⇒ `gr-p5r4-spa-b` (which owns app.css); 768-only AND of GR59's class (collision or hidden content) ⇒ same slice; 768-only tightness, or anything else ⇒ a NAMED child of the successor epic, filed before the seal. Two findings already pre-satisfy the rule and are folded in without waiting: the GR65 focus ring (1440, every identity) and the `.detail-grid` 768 clip. One corroboration that bounds the risk: `__css_check.mjs`'s E5 engine already proves 516 contrast pairs across all five identities × both themes with 0 errors (tightest iris-light 4.58:1 vs 4.5 minimum), so the matrix is hunting layout, not colour.
- **GR68 — The ops gate: the one-touch window is GONE, and the recipe now carries THREE proven false greens.** `deploy/cp-deploy.sh` pulls at :44 and sources `cloud/.env` at :50 **after** the pull, then boots the idle slot as a brand-new container — and #4482's own deploy already recreated the control-plane container at 20:48:59Z with the var unset. Lighting the crown therefore costs a **SECOND container recreation**, not a merge we were already making. The false greens, cumulative: **(1)** `.env`-only — caught by GR60, and its remedy is now LIVE (`docker-compose.yml:67` carries the bare `- PLATFORM_ADMIN_EMAILS`, so GR60 step 1 is DONE); **(2)** `docker restart` — NEW, never named before: a container's environment is fixed at CREATION, so a restart re-executes the same env block and the var stays `nil`, which makes the filed task's own ACTION text ("set … and restart the control plane") wrong; **(3)** `docker exec … env | grep` as the proof bar — insufficient, because `platform_admin_emails/0` maps every configured address through `Accounts.get_user_by_email/1` and `Enum.reject(&is_nil/1)` (notifications.ex:389-397) with **no log, no boot warning and no `/v1/me` signal**, so an unregistered address passes env-grep, container-env and config-parse and still returns `[]`. **The ONLY sanctioned proof is the release `rpc` returning a NON-EMPTY list** — `rpc` attaches to the live node, `eval` boots a fresh non-connected VM and cannot see it. Census, taken live on the running node: prod has exactly **18 users**; `kalle@jarl.no` is **NOT** among them; the only real human addresses are `frikk@jarl.no` (owner), `frikk.jarl@gyldendal.no` (owner) and `frikk@guerrilla.no` (owner+admin, last token today) — the recommended address, but the human picks, and getting it wrong costs a second prod touch. **Two disclosures GR52c/GR60 never made and the ask must carry**: a non-empty allowlist also un-short-circuits `deliver_fleet_digest`, so that address begins receiving a **06:00 UTC fleet digest daily, indefinitely, with no in-app opt-out** (removing the var + another slot flip is the only off switch; there is no send-now path, asserted as a shipped property at `__app.test.mjs:772`), and `cp-deploy.sh` has **no OLD==NEW gate**, so step 2 deploys whatever is on `origin/main` at that moment — re-measure the live bundle AFTER it, never before. **No ruling may name a slot literally**: the active slot was proven green and then blue within one hour. The gate is structurally decoupled from the build — every slice gates on fixtures regardless, exactly as GR52c already ruled — so it can only change what the debrief's first line says, never whether the wave lands.
- **GR69 — Two live-only defects that no fixture layer can structurally see; both are NAMED successors, and one is a live security-control degradation.** **(a)** All 19 live sessions record IP `172.18.0.1` — the Docker bridge gateway — across Chrome/Windows, Safari/macOS and bp CLI rows spanning 17 days. `trust_forwarded_ip/2` (router.ex:366-372) honours `X-Forwarded-For` only when `loopback_peer?/1` is true, and that predicate accepts ONLY 127.0.0.0/8 and ::1 (router.ex:377-379); the control plane is now containerized, so Caddy's hop arrives from the bridge, not loopback, and the guard falls through. The code's own comment predicts this verbatim (router.ex:243-245: "without this every remote client shares one global rate bucket and every session records 127.0.0.1"). **BOTH** consumers degrade: the sessions security panel (useless for spotting a foreign login, router.ex:9817) and the device-auth `start:<ip>` rate bucket (router.ex:606) — **all users currently share one global rate-limit bucket**. Tests pass because they use a loopback peer. Not this epic's slice: it is a security-sensitive router change that must trust the specific container-network gateway (or configure RemoteIp proxies), never `X-Forwarded-For` unconditionally. **(b)** `GET /v1/auth/oauth/:provider/callback` (router.ex:898-921) creates a user and mints a session, and `Plug.Head` (router.ex:284) now rewrites HEAD→GET before matching, so a HEAD replay of a still-valid `?code=&state=` runs the identical handler and silently mints with no body to show for it. A parse of all GET blocks by do/end boundary found **exactly one** side-effecting GET out of **56** — and the count is 56, not the "~130" a prior debrief guessed.
- **GR70 — The GR46 stamp delta is EMPTY, and the seal's executor was chasing a list that was stale the hour it was written.** Every manifest item is executed and evidenced — the close-now set carries `SUPERSEDED by GRnn` reasons citing GR46 by name, the `close_reason` backfill covered 8 rows spanning gr-p3 AND gr-p4 and **self-corrected GR46's own miscount** ("GR46 named 'the 4 empty gr-p3 rows' but the true empty set spanned gr-p3 AND gr-p4"), the GR61 cloud-flake reword is verbatim in place at 5/5, and all three #4433 rows are stamped exactly as GR61 ruled. **"Stamp what remains" resolves to "nothing remains"; re-running it is pure waste.** Separately, `gr-p5r3-successor-epic`'s frozen 12-item survivor list was written at 19:34:20Z and **five real children were filed after it** (19:35:56Z–20:16:57Z) and appear in none of its enumeration: `gr-backlog-tablet-width-audit`, `gr-backlog-accent-matrix-rereview`, `gr-backlog-qr-live-scan-proof`, `gr-p5-session-provenance`, `gr-backlog-compose-env-passthrough-audit`. The epic now has **78 children**, not GR61's 70. Binding on the successor slice: re-derive survivors FRESH from the server at execution time (never from any brief), move `cloud-console-billing-live-gate` **BY NAME** (its parent `cloud-console-goal` is top-level and `done`, so inheritance provably cannot reach it), classify `gr-backlog-qr-live-scan-proof` and `cloud-console-billing-live-gate` as **PERMANENT HUMAN GATES** in the successor's own description, and CORRECT `gr-ops-platform-admin-emails`'s ACTION text on both axes (restart→recreate, env-grep→`rpc`) plus scrub its literal `control_plane_blue` — carrying it forward verbatim is the path of least resistance and is exactly the failure to prevent.
- **GR71 — Four backlog rows are STAMP acts, not BUILD acts, and no slice touches `.ex` this wave.** `gr-backlog-favicon` and `gr-backlog-head-requests` both shipped in #4481 (`382f235407b6`, whose message reads "the shell stops lying about favicon and HEAD") and are LIVE-proven; `gr-backlog-reset-route-smoke` shipped in #4254 (`401e250c7`) and `smoke.mjs:611`'s own `what:` string literally reads "(absorbs gr-backlog-reset-route-smoke)"; `gr-backlog-provider-reconnect`'s server leg shipped in #4481. **The wish's own scope line for the SPA slice — "favicon + HEAD-404 in ONE router.ex block" — is STALE**: that block exists at router.ex:275-290 and verifies against prod, so a builder following it would re-open the router for nothing and drag a pure-SPA slice into the Elixir Test gate. `gr-backlog-role-vocabulary` is `done 3/3` and remains a phantom. Part E stays JS-only for the same reason: `router_providers_capabilities_test.exs` already pins the transformed shape in 7 tests, and the only genuine remainders (assert `default_gap` ABSENT; derive `CAP_PAYLOAD` from the committed `__fixtures__/providers_capabilities.json`) are both achievable in JS.
- **GR72 — The primary checkout is QUARANTINED for this wave; reconciliation is a named successor, not a step.** It is **ahead 8 / behind 48** (not the 7/43 anyone assumed) with **27 dirty FOREIGN files = 1095 insertions of another session's uncommitted work**, of which **four collide with incoming commits** (`api/lib/barkpark/tasks/schema.ex`, `validation.ex`, `tasks_controller.ex`, `tasks_controller_test.exs` ← `f08c48ec7`, `76a4d4238`), so `git pull --rebase` refuses outright and `--autostash` conflicts into an **18-deep shared stash stack that already holds 4 `MISPOP-RECOVERY` entries**. `reset --hard origin/main` — the documented steward recipe — would DESTROY that work and **does not apply while the tree is dirty**. Of the 8 unpushed commits, two are stale charter duplicates whose residue is dead in both branches (`42b31b4bd` is a strict subset bar one line that origin carries reworded; `f2058f68f`'s 10 unique lines are 9/10 already gone from local main's OWN tip); the other six, including the uncounted 8th (`b5945f8a0`, AXI), are keepers belonging to THREE other live epics. **Every phase of this wave reads code and charter via `git show origin/main:…` or a detached worktree, never the working tree** — the on-disk charter tops out at GR46 while origin is at GR61, and three surveyors already read it stale. Reconciliation is blocked on the TLV session committing its own tree and is filed as a named child; it must not be attempted at seal time.
- **GR73 — THE CROWN FIX NEVER APPLIED IN A BROWSER: `app.css:986` opens a prose paragraph as raw CSS and the parser eats `.modal-root` whole.** Line 985 closes the preceding comment with `*/`; line 986 then begins `   REVIEW ADDENDUM: making the root a scroll container…` with **no `/*`**. Everything from there is parsed as CSS, and the error-recovery rule ("discard tokens until the next `{…}` block") consumes the garbage run **plus the selector that follows it** — the `{…}` it recovers on IS `.modal-root`'s own block, so `.modal-root { position: fixed; inset: 0; z-index; display: grid; align-items: start; overflow-y: auto; overscroll-behavior: contain; padding }` never reaches the CSSOM. Proven four independent ways, all re-run at Decide: a comment-state scan says `inComment == false` at the standalone `.modal-root` (last delimiter is line 985's `*/`); stripping balanced comments leaves the prose in the source and the garbage run terminates at exactly `".modal-root"`; CDP reports `getComputedStyle('#modal-root').position === "static"` with the rule absent from all 1175 parsed rules while `.modal-backdrop` (the NEXT rule) is present; and `--force-prefers-reduced-motion` does not fix it, killing the animation hypothesis. **`git blame` puts the broken addendum AND the rule it swallows in the same commit `7f8a0dd7f` — #4592, "the crown screen stops being broken in production identities".** The crown fix voided itself in its own diff. `openModal()` (app.js:279) is a single shared primitive over `#modal-root` with 15+ call sites, so **every modal in the console** — confirm sheets, resurrect, token reveal, launch, cmdk, account — currently renders unpositioned and in-flow under a fixed scrim. It is LIVE: `https://barkpark.cloud/app.css` is byte-identical to `origin/main` (181,150 B, sha256 `8fa5ba9e…5f5964`). A full CSSOM-vs-source diff bounds the damage to **exactly one rule** — the other five apparent misses are CSSOM selector normalisation (comma-group flattening, `> *:nth-last-child` → `> :nth-last-child`). **The fix is one character.** Under the seal law's "zero known user-facing defect" this is BLOCKING, and it makes the wave's own headline landed claim false until repaired.
- **GR74 — THREE GREEN GATES CERTIFY DEAD CSS, and that — not the typo — is the durable finding.** All three were re-run at Decide against the broken bytes: **(1)** `__app.test.mjs` test 26, "GR63: the SHARED modal root can scroll" — #4592's OWN protective test, the one its commit describes as mutation-proved — passes **621/0**, because it regex-extracts declarations from `app.css` as TEXT and therefore sees a rule the browser discards. **(2)** `__css_check.mjs` E9 "parse-completeness", added for exactly this bug family in #4251, reports **0 errors**: it is scoped to `--x:` custom properties inside three token blocks and structurally cannot see a swallowed component rule. **(3)** Both print byte-identical numbers before AND after the one-character fix (`621 pass / 0 fail`; `832 classes / 90 tokens / 516 pairs / 83 allowlisted / 9 gaps / 0 errors`), which is the proof that neither can distinguish live CSS from dead CSS. **A source-text assertion cannot prove a browser applies anything.** `gr-backlog-tall-modal-scenario` predicted this class in its own words before the wave began — *"the stylesheet arm asserts on CSS TEXT. It cannot catch a geometry regression introduced by some OTHER rule"* — and the other rule turned out to be the rule itself. Ruling: the repair ships **with** a detector, in the same PR, and the detector is mutation-proved against the pre-fix bytes rather than asserted.
- **GR75 — The detector is E10 "orphan comment terminator", it is browser-free, and it was prototyped and mutation-tested at Decide before being briefed.** The precise signal is not "prose looks like prose" — a prelude heuristic false-positives on descendant selectors ending in ` a` and on keyframe `50%` stops (15 false hits on a clean file, measured). The zero-ambiguity signal is an **orphan `*/` encountered in code position**: a comment terminator with no opener means every line above it was parsed as raw CSS. Walk `app.css` once tracking comment state; a `*/` seen while `inComment == false` is a hard error, as is EOF reached while `inComment == true`. Measured result: **FAIL on `origin/main` (`line 990: orphan '*/'`), PASS on the fixed file, zero false positives across all 4,406 lines.** This is the only check in the suite that would have caught GR73, it costs ~15 lines, and it belongs in this wave — not the successor epic — because without it the same class recurs on the next prose-in-CSS edit. E9 stays as-is; E10 is a sibling, not a replacement.
- **GR76 — There was never a capture race; the camera was HONEST and three readers misread a product bug as an instrument bug.** The digest's CORRECTION 2 ("shoot.sh commits before the modal's late paint") is REFUTED at the DOM level: at the same 5000 ms virtual-time budget that yields the "blank" PNG, `--dump-dom` already contains `role="dialog"`, `.modal-card`, `#modal-logout` and "Your account" — **one each**. The DOM injection wins its race comfortably. `mock.js:133-148` drives the real `openAccountModal` on window `load` plus a 50 ms poll capped at 40 tries (2000 ms), well inside the budget. Doubling the budget 5000→9000 ms produced a byte-identical PNG, which looked like proof of a stubborn race and was actually proof of a **deterministic rendering defect**. The bare-dimmed-backdrop shots are a faithful photograph of GR73. Consequences, all binding: `shoot.sh` needs **no hardening — not one line**; the 60 modal-family PNGs across the five accents are neither "instrument failures" nor "non-evidence" but **correct captures of a live defect**; and folding in the tall-modal scenario is **unblocked and cheap**, because `shoot.sh:161`'s `account-modal*` prefix match auto-covers a new `account-modal-tall` with zero harness change (shot clean at Verify: 4/4 PNGs, all 9 session rows, 2FA control, Close and Log out visible). With the CSS fixed, GR63's design is proven sound in a 700 px viewport by CDP: `position:fixed`, `overflow-y:auto`, `overscroll-behavior:contain`, `align-items:start`, `scrollHeight 1009 > clientHeight 700`, and after scrolling `#modal-logout` sits at top 619 / bottom 651, in-viewport AND the top hit-test element. **GR63 was right all along; it simply never executed in a browser.**
- **GR77 — The matrix FLEW and is DISCHARGED, not deferred — and it found exactly one new accent defect in ~1,585 shots.** GR67's amendment held: the sweep ran at Verify, parallelised by accent on the static harness at explicit non-default `PORT`/`OUT`, and four of five lanes asserted a full **336/336** (iris, ember, fjord, charple; evergreen reached 241/336 under host load 27–48 plus a complete targeted 12-shot modal run). Instrument honesty was corroborated, not assumed: **40/40 PNGs re-shot strictly serially are SHA256-identical to their concurrent counterparts** (`diff` exit 0), and fjord vs charple for the identical scenario/theme/width are NOT byte-identical, so the accent axis genuinely differentiates. **The one finding: `.vf-chip--pass` / `.vf-chip--fail` (app.css:3241-3242) collide under ember.** Both chips take their background from `--ok-soft` / `--danger-soft`; `--ok-hsl` is mapped 1:1 to `--primary-hsl` for every identity, and ember's primary sits at hue **19.33° (light) / 19.01° (dark)** against `--danger-hsl`'s fixed hue **0** — every other identity is 150°+ away (evergreen 151.96°, fjord 191.6°, iris 248.75°, charple 282.56°). Sampled, not eyeballed: pass `#F4E5DD` vs fail `#F4DEDE`, **Euclidean RGB distance ≈ 7**. The chip label is uncoloured, so under ember "3 checks, 1 failing" is legible almost entirely from a small ✓/× glyph. Reproduces at 1440 AND 768, both themes — **user-facing at 1440 in a shipped identity, so GR67's own rule routes it to the app.css slice**, not the successor. `__css_check`'s 516-pair engine structurally cannot catch this: it checks text-vs-background WCAG contrast, never background-vs-background semantic distinguishability between a pass state and a fail state. Everything else sampled across five accents — panel-overview, rollback 768, fleet-usage 768, mixed-fleet 768, billing, webhooks, notif-deliveries, operator-console, theater, site-states — was clean, and GR59/GR65's 768 fixes hold in every identity.
- **GR78 — Because the whole matrix photographed a broken modal, the seal needs a RE-SHOOT, and it is 60 shots, not 1,680.** Every modal-bearing scenario in all five lanes captured GR73's unpositioned shape, so those frames prove the defect and cannot also prove its absence. The re-shoot is scoped to the account-modal family plus the new tall scenario across all five accents × 2 themes × 2 widths, runs only AFTER the one-character fix is on `origin/main`, and asserts its PNG count before any conclusion exactly as GR67 requires. It is a proof act with no source edit. Two guardrails from the sweep carry into it: **a live PID is not proof of progress** (one lane's Chrome sat 28+ minutes on 0.39 s of CPU and only an external kill unstuck it, because `shoot.sh:228-232`'s `kill; wait; kill -9` reap has no timeout), so the operator watches the count CLIMB, not merely exist; and **byte-identity is not a sufficient liveness check** — two equally-broken shots of the same scenario hashed differently across accent/theme, so "no two PNGs identical" would have passed the broken matrix.
- **GR79 — The delivery-log filters ARE live; the contradiction was one surveyor reading a tree 61 commits behind, and GR35 is now a stale clause sitting unmarked beside its own reversal.** Both surveyors quoted real code from different trees. At `origin/main`, `list_deliveries(team, opts \\ [])` (notifications.ex:530-548) applies `channel`/`status`/`event` via `maybe_delivery_eq` and `before` via `maybe_delivery_before`, with an integer-arity back-compat clause; `router.ex:3593-3610` builds the opts from query params and clamps `limit` at 200. `git log -S 'maybe_delivery_eq'` returns exactly one commit — `301e035d8`, #4433 — whose CI passed (Cloud control-plane 1m15s, Elixir 10m20s), and `router_notifications_test.exs` carries **10 `filtered(token, …)` assertions** covering single filters, a combined triple, `status=bogus ⇒ []`, empty-string-is-no-filter, and a `?before` cursor walking page1→page2. The stale local tree has the pre-filter signature and **zero** such assertions — an independent second signature of which tree is which. Rulings: **the SPA panel is a SERVER round-trip with cursor pagination, not an in-memory filter** (filters run inside the Ecto query, so "show me the failures" is a real page of failures rather than the failures that happen to fall in the newest 50, and client-side code cannot paginate `?before` at all); **charter GR35 is SUPERSEDED by GR61 + #4433** and must never be re-cited — it still reads "keyset + channel/status filters = backlog" at line 51 while its own reversal sits at line 85, and a reader grepping "deliveries filters" hits the stale clause first; and `app.js:2695` calls the route with **zero query params**, so the leg is live server-side and entirely unconsumed.
- **GR80 — Line numbers are now actively hostile; string anchors are the only lawful anchor, and the charter's own GR61 is already drifted.** `app.js` is **16,468 lines at `origin/main`** and 14,026 in the stale local tree — the 2,442-line delta is precisely the disagreement two surveyors could not reconcile. Drift is NON-UNIFORM even within one file: `app.css` anchors moved **+17…+48**, `app.js` anchors below ~8,000 moved **+7…+30** while anchors past ~14,000 moved **−120…−123**, and `newStepsHtml` moved **+18/+30** in the same pass in which `__css_check.mjs`'s anchors did not move at all. GR61's own cited `app.js:2738` for the `retry_after` seam is wrong by **+458** (2738 is channel-row credential collection; the real anchor is the comment at :3196). Two corrections ride with this: `retry_after` **is already consumed** at app.js:2803 for the notification test-send toast, so "the retry_after leg is unbuilt" is true ONLY of the **two-factor** leg and a brief that omits that qualifier will make a builder duplicate working code; and the session-IP probe's cited test at `__app.test.mjs:3207-3222` is really at **:4106-4120**. Every brief this wave cites strings and re-greps; no builder may trust a number carried in from any prior document, including this charter.
- **GR81 — The SPA draws a verified-false fact on two security surfaces, and suppression is the honest render.** `peer_ip(conn)` (router.ex:9822-9825) reads `conn.remote_ip`, and `trust_forwarded_ip/2` (router.ex:366-379) honours `X-Forwarded-For` only from a loopback peer — containerized, Caddy's hop arrives from the bridge gateway, so every session records `172.18.0.1` (GR69a). Two render sites consume it: the sessions panel (`esc(x.ip_address || "unknown IP")`, whose fallback can never fire because the server always returns a non-empty string) and the higher-stakes device-auth **"Approve this sign-in?"** confirm screen. The value is not merely uninformative, it is **uniform garbage** — identical for every client — so it can never distinguish "my usual login" from "a stranger", which is the only reason an IP appears on an approval screen at all. No heuristic is lawful here: an RFC1918 test would flag genuine corporate/VPN users and would silently stop firing the day the router is fixed, with nothing telling the SPA that happened. Ruling: **suppress the IP row on BOTH surfaces**, as a stopgap carrying an in-code pointer to `gr-bl-peer-ip-container`, to be REVERTED once real per-client IPs land. Cost measured at Verify, not estimated: exactly **one** test breaks (`__app.test.mjs:4106`, `assert.ok(html.includes("203.0.113.7"), "shows the requesting IP")`) — a test that encodes today's dishonest behaviour as the expected behaviour — and its companion at :4123-4129 ("no IP row when the server sent none") is the exact template for its rewrite. `sessionRowHtml` has **zero** IP assertions anywhere, including the 9-session GR63 test, so the panel edit is free. The router fix stays a named successor; the SPA does not get to seal by calling a lie someone else's problem when it is the one drawing it.
- **GR82 — The "stranded dom-rung fix" is a MYTH, refuted by four independent verifiers, and must not be re-litigated.** The digest recorded commit `3d80a58bf` (local branch `gr-p5r4-review-integration`) as an unlanded, seal-blocking `.dom-rung` fix with "no PR and no task". All three clauses are false. `gh api .../pulls/4592/commits` lists `3d80a58bf` verbatim as one of #4592's three commits; #4592 merged 22:53:25Z; `origin/main`'s `app.css` carries the exact patch (`.dom-rung { max-width: 100%; min-width: 0 }`, `.dom-rung-code { white-space: normal; overflow-wrap: anywhere }`) with its GR65-REVIEW comment and matching 1533→1440 / 797→768 numbers; a live CDP render of `panel-overview` with the long-hostname failed rung measures `scrollWidth == clientWidth` at 1440 light, 1440 dark and 768; and the task `gr-backlog-768-residue` already stamps criterion 0 `met:true` citing that commit. `git merge-base --is-ancestor` returns false **only because #4592 squash-merged** — a git mechanic, not evidence of non-landing, and the specific trap that manufactured this ghost. **Provenance is proved by CONTENT, never by SHA ancestry, whenever the repo squash-merges.** The single genuine remainder is `gr-backlog-768-residue` criterion 1 — the stacked `.attention-row` centring its pill and buttons while name and reason stay left-aligned — which is 768-only cosmetic tightness and therefore a successor child by GR67's own rule, not slice work.
- **GR83 — One MUST-RUN command in circulation is a silent no-op, and the OTHER accusation was itself a stale read — corrected at Decide by running it.** The successor-roster recipe `bp task get <id> -o json | … c['children']` **raises `KeyError: 'children'`** on this CLI build, and because it is usually written with a `|| echo "none"` fallback it reports an empty roster as a clean confirmation. The lawful enumeration is the direct HTTP query over `/v1/data/query/production/task` filtered on `parent_id`, and it must enumerate **literal doc_ids** rather than prefix-grep: a naive `gr-backlog-` grep misses **17 of 42** open children (40%), including all nine `gr-blk-*`, `gr-bl-peer-ip-container`, and `gr-ops-platform-admin-emails` itself. **But the companion charge — that `SCEN=<name> ./shoot.sh` "does not filter anything" — is REFUTED for `origin/main`.** That verifier grepped a `shoot.sh` with three `SCEN` hits, all `SCEN_TSV`; the shipped script has eight, documents both axes in its own header, and implements the filter at `WANT_SCEN=" ${SCEN//,/ } "` with a padded-substring membership test (bash 3.2 safe — no associative arrays). Because commas are rewritten to spaces, **comma-separated AND space-separated lists both work**, and `ACCENT` is a comma-list too, so ONE invocation sweeps several identities. Run at Decide rather than reasoned about: `PORT=4641 OUT=$D ACCENT=iris,ember SCEN=account-modal,account-modal-2fa-on ./shoot.sh` printed `>> Done. 16 PNGs` and an independent `ls | wc -l` confirmed **16** = 2 scenarios × 2 accents × 2 themes × 2 widths. An unknown scenario name simply never matches, so a typo is visible as a MISSING PNG — which is exactly why GR67's count assertion is the guardrail and the `>> Done.` line is not. The general lesson stands and is the one to carry: **a MUST-RUN line in a brief is a claim, and a claim about a tool is settled by running the tool** — the same discipline that turned GR73 from "the camera is lying" into "the product is broken".
- **GR84 — The seal is REVIEW's act, it is CONTINGENT, and this wave's job is to make it TRUE rather than to declare it.** GR73 is a live user-facing defect in every console modal, so the epic **cannot** seal in the state it entered this wave. The seal fires only when: the one-character fix and E10 are on `origin/main`; the GR78 re-shoot proves the modal family renders correctly across all five accents; the app.css slice has closed the six zero-rule families, the three detector artifacts and the GR77 ember chip; the SPA slice has landed the four backend wire-ups and the GR81 suppression; the successor epic exists with a roster re-derived FRESH per GR83; and the four SPA gates are quoted live from `origin/main` at stamp time. Three prose-only findings surfaced across waves 3 and 5 have **no forwarding address anywhere in the 2,152-task ledger** and are therefore seal-blocking under "zero UNNAMED residue" until filed: the click-inert smoke shim, the Archives "How archives work" link pointing at the bare repo root (still live at app.js:1612, raised independently by two waves), and the js/ SDK + Go TUI role-label leakage. **Named residue behind one forwarding address is allowed; unnamed residue is not, and "the matrix will catch it" is not a forwarding address.** The live baseline every slice quotes is **621 tests / 832 classes / 90 tokens / 516 contrast pairs / 83 allowlisted / 9 known gaps / 0 errors / 84 scenarios** — re-run at Decide against `origin/main`; GR64's 626/842/85 is superseded (it was #4592's OWN pre-merge citation, and #4592's commit message already documents the drop) and must never be re-quoted. The `516` decomposes as **12 theme-states × 43 pairs** (base light+dark plus 5 identities × 2), not "10 sections × 43"; `__css_check.mjs`'s own comment still says "four identities" and is one identity stale.

- **GR85 — SLICE ZERO IS EMPTY: all three prerequisite PRs are on `origin/main`, and every roster written about them was stale within the hour.** `#4684` (E10 parse-completeness guard, `25c5bac33`), `#4685` (the SPA consuming its four live server legs, `67e1996b4`) and `#4634` (the GR73–GR84 amendment, `88ede6a51`, now the tip) are each proven ANCESTOR of `origin/main` by `git merge-base --is-ancestor`, and the merged charter is byte-identical to the PR head (`157abc967`, 158,575 B). Strategize's "mergeable UNKNOWN" for `#4634` was wrong — it was `MERGEABLE`/`UNSTABLE` throughout with the Prod compile gate already PASSED. The verified live bytes go further than the merge log: `curl https://barkpark.cloud/app.css` is byte-identical to `origin/main` (181,153 B, sha256 `d059d53d…851671`), the `/*` opener is present at 986, `.modal-root` parses (4 occurrences), and the **verbatim E10 algorithm run against the LIVE bytes returns zero errors** — there is no second orphan lurking. **The wave therefore builds on a proven-fixed primitive, not an assumed one.** No landing slice is cut.

- **GR86 — `pr-task-gate` is a LIVE ledger read, the epic's claim is released between waves, and that re-arms the same failure for every slice PR.** `#4634` sat stranded ~1.5h not for a body-format defect — its body always carried a correct `Task: task-47bc4168392dec17` line, extracted cleanly — but because the gate read the ledger and found `lifecycle_status=open`: `pr-task-gate: FAIL: task 'task-47bc4168392dec17' is 'open', not 'in_progress'`. A bare re-run **with no push** flipped it to `PASS` in 12s once claimed. Then the claim was RELEASED nine seconds after the merge (epoch 20, `released_at 02:12:22Z`), so the epic is unclaimed again. Because the check is a live read, a docs re-run is not a fix — it is a reprieve. **LAW: every slice PR carries `Task: <its OWN slice task id>` in the body, and the builder CLAIMS that slice task before opening the PR.** Citing the epic borrows a claim nobody is holding. Corollary measured at Decide: `main` has **zero branch protection and zero rulesets** (`branches/main/protection` → 404, `rulesets` → `[]`), so nothing is mechanically required-by-name; required-vs-advisory is convention in `merge-gates.md`, which even ships the PATCH command that has never been executed.

- **GR87 — GR78's "60 shots" headline is arithmetically wrong; the binding number is 80, and a builder obeying the headline passes while missing a quarter of the sweep.** GR78's own scope prose in the same sentence reads "the account-modal family plus the new tall scenario across all five accents × 2 themes × 2 widths" = 4 × 5 × 2 × 2 = **80**. All four scenarios are confirmed present on `origin/main` (`account-modal`, `account-modal-tall` — added by #4685 — `account-modal-2fa-badcode`, `account-modal-2fa-on`). **GR78's headline is AMENDED to 80.** This is the exact GR74 shape — a confident number certifying an incomplete truth — committed inside the rule written to prevent it.

- **GR88 — `shoot.sh`'s `SCEN` filter is an EXACT-NAME padded-substring test, so `SCEN=account-modal` shoots 20 PNGs, not 80, and still prints a cheerful ">> Done".** The filter is `WANT_SCEN=" ${SCEN//,/ } "` tested `*" $scen "*`: `account-modal-tall`, `-2fa-on` and `-2fa-badcode` are all silently skipped. Proven by running it — `SCEN=account-modal ACCENT=iris` emitted exactly 4 PNGs (4 distinct sha256, 250–302 KB, count observed climbing 0→2→3→4). Compounding it, the ">> Done" line runs `find "$OUT" -name '*.png' | wc -l` over the WHOLE directory, not this run's output. **LAW for the re-shoot: enumerate all four scenario names explicitly (or leave `SCEN` unset), assert the count yourself with `ls -1 "$OUT"/*.png | wc -l` into a FRESH `$OUT`, and never quote shoot.sh's own Done line as evidence.** This is the single highest-probability path to a third generation of false greens in this wave.

- **GR89 — The css-families brief named the WRONG KNOWN_GAPS survivor and missed the third `var cls` site; settled by running the checker four times, not by reading it.** Baseline on `origin/main`: `exit 0`, 832 classes, **9 gaps** (7 E2 + 2 E3). The eight that die are the six family E2s, the `"notice-"` E2 (killed by the `fleetRolloutBannerHtml` rewrite), and the **single E3 `head:""`** entry. The SOLE SURVIVOR is the E3 `head:"bp-lc-"` entry protecting `coherenceFixtureToHtml`'s `'bp-lc-' + word` concat. Deleting it is a RED gate — proven: `FAIL E3 app.js:16118 dynamic class composition with head "bp-lc-" is not in ALLOW_PREFIXES` — **because E3 is an ALLOW_PREFIXES membership question, not a rule-existence question**, so authoring `.bp-lc-*` CSS clears the `bp-lc-hex` E2 and leaves the E3 firing. Second correction: there are **THREE** `head:""` sites, not the two the checker's own comment asserts — `notifMatrixCellHtml` (~2591), `freshnessBadge` (~8446) and **`usageMeterHtml`'s `quotaCls`** (~14145), which no brief ever named; rewriting only the named ones and deleting the entry also reds (`FAIL E3 app.js:14148 … head ""`). And `newStepsHtml` — the site the brief says to leave untouched — is not a KNOWN_GAPS entry at all: its head `"new-step "` is already allowlisted and prints as `allow` on every baseline run. The 9→1 path is proven green (834 classes, 1 gap, 0 errors); a 9→0 path is also legal if `"bp-lc-"` is added to ALLOW_PREFIXES in the same commit and stated in the PR. **The class-count RISE comes from the rewrites, not from the CSS authoring** — author the families without the rewrites and the count does not move.

- **GR90 — The `.vf-chip` defect is BACKGROUND-ONLY and STRUCTURAL, and the brief's cited sibling precedent for `fleet-infra` does not exist.** `verifyChipHtml` already renders a distinct glyph per role (`&#10003;` / `&#10007;`), the visible label, and an aria-label suffix ("— passed" / "— failed"), and `.vf-chip--pass .vf-chip-glyph` / `--fail .vf-chip-glyph` already carry `--ok` / `--danger`. Live-rendered proof, not source reasoning. So "pass/fail chips are indistinguishable" is FALSE; the real, narrow defect is that both backgrounds derive from `--ok-soft` / `--danger-soft` while `--ok-hsl` is mapped 1:1 to `--primary-hsl` for EVERY identity and `--danger-hsl` is pinned at hue 0 — ember sits ~19° away where the other four sit 150°+, making it a 2.5–6× outlier in both themes (light: ember 7 vs evergreen 28.4 / charple 19.5 / fjord 31.2 / iris 30.8). Census of every `--ok`/`--danger` PAIRED consumer found **no other genuinely colour-only case**: `status-pill`, `wh-del-status`, `tlv-badge` and `dom-rung` all carry text or a glyph, and `.instance-card--ok/--danger` (border-left-color only, and NOT part of the `--*-soft` family) is always co-rendered with a text-bearing `statusPill` in the same card head. Separately, the brief's "`axes` line idiom" precedent for `fleet-infra` **is not a selector anywhere** (`grep -i axes app.css` → 0); the code-confirmed sibling is `.fleet-meta` / `fleetMetaHtml`, whose own comment names `fleetInfraLine` as its denser twin.

- **GR91 — GR84's "no forwarding address anywhere in the 2,152-task ledger" is FALSE, and a literal execution of successor-seal PART 3 manufactures residue at the moment of sealing.** All three named items already exist as PUBLISHED, OPEN children of `task-47bc4168392dec17`: `gr-blk-smoke-click-inert`, `gr-blk-archives-doc-link`, `gr-blk-sdk-tui-role-labels`. GR84 committed exactly the prefix-grep error GR83 warns against two paragraphs earlier in the same amendment. **PART 3's verb changes from FILE to RE-PARENT**, and its criterion changes from "each exist as published tasks under the successor epic" (satisfiable by duplication) to "each is RE-PARENTED, never re-created, with zero net new tasks created by this criterion." The underlying defects are real and current — `archives-docs-link` still points at the bare repo root on `origin/main`. Narrowing on the same slice: only `cloud-console-billing-live-gate` needs the BY-NAME move (parent `cloud-console-goal`, top-level and done); `gr-backlog-qr-live-scan-proof` is ALREADY a direct child and needs the human-gate LABEL only; `isu-backlog-operator-principal` belongs to `self-update-epic` and must not move.

- **GR92 — `lifecycle_status` is the authoritative state field; `claim.closed_at` is claim metadata, and trusting it undercounts closure by ~12%.** One snapshot reproduces both contested numbers: 106 children, `lifecycle` `{done: 53, open: 53}`, `closed_at` set on **40**. `docs/setup/TASK-SYSTEM.md` defines readiness purely off `lifecycle_status`, so 53/53 is the roster. The 13-item gap is `done` with `closed_at` null — real evidence in `claim.now` (branches, SHAs, gate counts) written by a second, silent path that bypasses the CAS close; 7 of the 13 also carry a stale MORNING `claim.worker` against an AFTERNOON lifecycle flip. **Zero OPEN children carry a live claim.** Every frozen roster in this epic — GR70's 78, Decide's 93/51/42, "12 close-now candidates" (unlocatable in any artifact) — was wrong by the hour it was written; the successor roster is re-derived at execution time or it is wrong again.

- **GR93 — The CSSOM oracle SHIPS as a fourth slice, mutation-proven against the exact production bytes, unwired from CI, and it NEVER gates the seal.** Sealing an epic whose defining lesson is "static gates lie" while filing the anti-lying gate as residue is a legal seal and a hollow one — the general form already has a named open task, `gr-blk-cssom-parity-gate`. Feasibility is not speculation: a zero-dependency Node 22 CDP driver (native `fetch` + `WebSocket`) asserted 8 modal states in ~16s, 5/5 clean runs, teardown 110–121 ms, zero orphaned Chrome. The mutation proof is stronger than asked for — removing the `/*` opener reproduces a file of **181,150 B, sha256 `8fa5ba9e…285f5964`**, byte-for-byte GR73's live-broken file, and the oracle goes `exit 0 → exit 1 (8/8 states, naming the mechanism) → exit 0`. **Two hard-won constraints are LAW.** First, the proof found TWO false greens in the oracle itself: a substring CSSOM check counts 4→**3**, never 0 (the three compound `.modal-root:has(…)` variants parse fine), so the assertion must key on `selectorText === ".modal-root"`; and a typo'd scenario (`account-modal-taII`) PASSED with `exit 0`, measuring the right CSS on the wrong screen, so a roster guard importing `scenarios.mjs` must abort before Chrome boots. Second, **two of its four assertion classes are proven INSENSITIVE to #4592** and must not be credited: the hit-test-above-backdrop and button-reachability checks both still PASSED under the mutation, because `.modal-card` carries `position:relative; z-index:1` and page-level scroll substitutes for the root's. What actually caught it: the CSSOM base-rule check, computed `position`/`overflow-y`, and the tall-card scroll assertion. It must NOT copy shoot.sh's unbounded `kill; wait; kill -9` reap — a foreign `shoot.sh` was measured wedged **7h18m** on this host during Verify, so the stall is a live condition, not an anecdote.

- **GR94 — The instrument tells the truth (PROCEED), and the ops gate's proof bar is `rpc`, never `eval` — whose `[]` today proves nothing.** The abandon-or-proceed call resolves to proceed on measurement: `activate-entry`, one of the 13 GR66 names, renders H1 "Approve a device sign-in" at `/activate` and the logged-out login card at flat `/` — the lie is real, the cure is real, and the cure is what `origin/main` ships. On the ops side every layer is proven empty against the ACTIVE control-plane slot (derived generically from Caddy's upstream, exactly one matching container): `platform_admin_emails()` → `[]`, `Application.get_env` → `[]`, container env absent, `.env` absent — while `docker-compose.yml:67` DOES carry the passthrough, so **GR60 step 1 is done on the box and the human's one `.env` line really is sufficient**. All four `/v1/operator/*` routes return **403** for a real authenticated owner and **401** unauthenticated, so the 403 half of the bar is already in hand as the permanent non-listed control. **NEW false green, never named: `eval` and `rpc` are INDISTINGUISHABLE while the var is unset** — `eval` returned `[]` cleanly because an empty list never touches the Repo, so rehearsing the command shape with `eval` now and reusing it after the human acts gives a Repo-less crash at the exact moment it matters. And the address is a PROOF-BAR decision, not merely a correctness one: `frikk@jarl.no` (the wish) and `frikk@guerrilla.no` (GR68's own live census) are BOTH registered — `kalle@jarl.no` is correctly ruled out, it is not among prod's 18 users — but **only `frikk@guerrilla.no` has a session token on this host**, so choosing `jarl` makes the 403→200 half unexecutable by this wave and degrades the AFTER proof to the rpc list alone. **Surface both to the human; never resolve it silently.**
- **GR95 — Act zero completed BEFORE this round ran; both rescued PRs are on `origin/main` and nothing in round 6 rebuilds them.** `#4732` merged 2026-07-20T04:56:19Z; `#4733` merged as squash `22c42b219`. The relocation was authored at `55d61ab4c` inside another agent's live worktree and pushed before Verify began — so the wave's central open question ("does ONE relocation turn BOTH gates green?") was answered by measurement, not by the fix being written here. It is PROVEN three independent ways: the two reds were mutually exclusive (at `5665dd779` drift FAILS / css_check PASSES; at `1d928b3bf` drift PASSES / css_check FAILS `E2 app.js:16135 class "bp-lc-hex" is emitted but has no rule in app.css`), the net diff is a pure move (added and removed line sets differ by exactly one blank line), and an independent re-application to state A produced `DRIFT_AFTER=0` / `CSSCHECK_AFTER=0`. Live on a clean `origin/main` export at Decide: `834 classes checked, 91 tokens checked, 516 contrast pairs, 86 allowlisted, 1 known gap(s) demoted (R3), 0 error(s)` — **GR89's pre-registered post-fix prediction, to the digit**. `.bp-lc-info` now sits at `app.css:242`, below `/* END GENERATED: tokens */` at `:232`. E10 survives the move (mutation at `app.css:1029` fires and names the mechanism, exit 1; restore → exit 0), but it lives at `__css_check.mjs:356`/`:883`, **not** the 345/872 this charter's own direction stated — a drift worth not repeating.
- **GR96 — `account-modal-tall` EXISTS; the "fictional 80" is REFUTED and GR84's baseline is restamped from 84 scenarios to 86.** `scenarios.mjs:2565` defines it, labelled "the NINE-session shape (the one that broke on live)", against a dedicated `accountSessionsTall = Array.from({ length: 9 }, …)` fixture at `:533`, with a full `smoke.mjs:258` EXPECTATIONS entry (9 rows / 8 revoke / no IP / `modal-logout` below the last row) and automatic `shoot.sh:161` `account-modal*` prefix coverage. It landed in `#4685` (`67e1996b4`) and was already shot clean at GR76. **GR87's 80 is binding; GR78's 60 is dead.** The error source is identified and is this charter's own standing warning, confirmed a THIRD time inside one survey: the on-disk checkout is 93 commits behind, its `scenarios.mjs` has zero hits for the scenario and its `shoot.sh` is the 116-line pre-SCEN original against `origin/main`'s 256. **BINDING: every reshoot act runs from a clean `git archive origin/main` export, never the working tree.** A corollary correction: `gr-backlog-tall-modal-scenario` is a **fake-OPEN** task — its criterion 1 is satisfied on main today — so the residue inventory must audit both directions, not only for fake-done.
- **GR97 — THE COUNT ASSERTION IS ITSELF A VACUOUS GREEN: 20 of the 80 PNGs are byte-identical duplicates filed under a name whose state they do not show.** Reproduced at Decide on a 2-scenario × 1-accent run: **8 PNGs, 8 `ok` lines, 4 distinct hashes** — every `account-modal-2fa-badcode` shot is byte-identical to its plain `account-modal` twin. Mechanism: the badcode scenario's only distinguishing datum is `twoFactorConfirm: {status: 422}` (`scenarios.mjs:2589`, served at `:2717`), and that route only fires on a FORM SUBMISSION, while `mock.js:142-143` only calls `openAccountModal()`. Nothing ever submits, so the 422 arm is unreachable from a static shot; the opened PNG shows "Two-factor authentication / Off" with no error and no `#pw-error`, while its label promises "enrollment rejected: 422 invalid_otp". This is **GR66's exact defect class — "filed under names their PNGs did not show" — STILL LIVE**, and the wish's own mandated `ls -1 "$OUT"/*.png | wc -l` guard passes cleanly against it. `account-modal-2fa-on` is genuinely distinct (verified 4/4 pairs) because `two_factor_enabled` is read straight off `/v1/me` with no interaction. **RULING: the reshoot gate is CONTENT-AWARE — a distinct-hash floor, an explicit no-badcode-twin assertion, and `ok`-lines == file-count — never a bare count.** Honest yield today is 80 files / 60 distinct looks / 20 lying filenames.
- **GR98 — two further shoot.sh false-green classes, both proven, both defeating a count guard.** (a) **Full-count corruption:** `shoot.sh:235` prints `ok` on `png_size > 0` alone and readiness is checked exactly once at `:129`, never again — so a mid-run server death yields the FULL expected count of Chrome `ERR_CONNECTION_REFUSED` pages. This is distinct from GR88, which covers undercount; this one delivers the right number of uniformly wrong images. (b) **Concurrent-writer inflation:** two runs sharing one `$OUT` interleave silently — 49 files against 44 `ok` lines, one count, two writers. **BINDING: fresh `$OUT` per accent, explicit non-default `PORT`, and `ok`-lines == file-count asserted alongside the content checks.**
- **GR99 — shoot.sh's reap has no timeout, it is the four-time wedge, and the fix is an EXTERNAL watchdog that kills the process TREE.** Root cause is measured, not inferred: `sample` on the live wedged process shows **2395 of ~2400 stack samples in `__wait4`** — blocked in `wait "$cpid"` at `shoot.sh:231`, PAST the SIGTERM at `:230`, which means TERM was sent and ignored and the "guaranteed" `kill -9` at `:232` is unreachable code until `wait` returns. bash `wait` has no timeout primitive. A manual SIGTERM to the Chrome pid killed it in ~8s and the script immediately resumed, proving `wait` was the sole blocker and an external kill is sufficient. Durations across waves: GR78 ~28min, GR93 7h18m, a prior digest 7h46m, Verify **10h30m+ and still climbing** — never once patched, only avoided by newer code. `pkill -9 -P` is NOT optional: a single-pid watchdog demonstrably left an orphan. Note the wedge is CONDITIONAL — a clean-room two-accent run completed in ~20s with zero leak — so "my test run was clean" is not evidence the risk is closed.
- **GR100 — the CSSOM parity widening is GO, and its BUILD SHAPE changes: symmetric normalisation and a brace-tracking parser, never an enumerated rule list.** Measured live on today's FIXED `app.css`: **1189 CSSOM style rules == 1189 authored rule heads**, 1158 flattened selectors either side, **0 true misses and 0 false positives**. GR73's figures (1175 rules, 1 real miss, 5 normalisation false misses) are superseded — they were taken on the BROKEN file. GR73's two normalisation rules are **INCOMPLETE**: a third, undocumented class exists — Chrome strips whitespace inside the An+B microsyntax, serialising `.set-matrix-grid > *:nth-last-child(-n + 2)` as `> :nth-last-child(-n+2)` — and applying GR73's rules literally leaves a residual mismatch. The probe survived only because it pushed BOTH sides through the SAME normaliser, whose combinator regex incidentally canonicalised the `+` in `-n + 2`. **An enumerated allowlist is provably incomplete (a third class was found in a file with exactly ONE affected selector); symmetric normalisation is robust to unknown serialisation classes.** The extractor must be a brace-tracking parser, not the grep the earlier brief specified: `app.css` holds 16 opaque at-rule blocks containing 21 percent-stop heads with no `selectorText` plus 40 multi-line comma continuations, so a grep manufactures ~37 spurious misses and a gate that cries wolf on a clean file is disabled within a wave. Size is **60–80 lines, not GR73's optimistic 15**. Mutation-proven at TWO locations 2000 lines apart — `app.css:986` names `.modal-root`, `app.css:3005` names `.wh-secret` — so it is **file-wide, not modal-local**, which IS the argument for promoting it over more photographs. It ships UNWIRED from CI per GR93(b) and never gates the seal; wiring is the successor's first task, and the failure message must special-case a miss containing `*/` as "orphan-comment swallow", cross-referencing E10, or a cold reader misreads it as a bug in the gate.
- **GR101 — the ledger audit RAN, found ZERO fabrication, and its honest number is 7 — not 13; the guard is FILED, never built.** All 13 sampled code-claims verified true against `origin/main`. `close.ex:218-231` deliberately does NOT stamp a nil claim ("A never-claimed root/container task has no claim — close it without inventing one"), so **6 of the 13 are innocent BY DESIGN**; filing on 13 would misidentify the mechanism for 46% of its own evidence, which is worse than filing nothing. The remaining 7 carry a claim MAP with null stamps, a shape `Close.close/2` cannot produce (its `is_map(claim)` branch stamps `closed_by` and `closed_at` unconditionally), and all 7 hold live unreaped claims with `work_digest`s, eliminating the TTL sweeper (which forces `lifecycle_status` back to `open` and stamps `expired_at`/`previous_worker`). They cluster in two seconds-wide bursts against morning claim times — a batch-write signature. The bypass path is proven OPEN **today**, by live probe on a throwaway task created and deleted: a CAS-free `/v1/data/mutate` patch flipped `lifecycle_status` to `done` with no claim, no epoch, no worker and no `if_rev`, because `mutations.ex:272` protects only `title status _id _type _rev` and contains zero occurrences of "task". Its history records a generic `update`+`publish` with `actor_user_id: null` and **no `task.closed` event** — that absence is the reliable after-the-fact audit signature. **The seal does NOT build the guard**: it is an Elixir repair with a named blast radius (`sync/applier.ex` is a second `apply_mutations` caller needing an internal opt-out), in a round scoped to `cloud/`, and GR93's law is instruments-not-repairs. **The sharpest attack on this round's direction is hereby empirically dead**: the audit reopened nothing, converted an unknown into named residue, and made the seal more honest without making it less achievable. State the attribution as "the only reachable known mechanism", never as "observed" — `mutation_events` remains unreachable.
- **GR102 — the seal-blocking clause is "zero known USER-FACING defect", and four open children are exactly that.** Sealing the modal primitive while `gr-blk-modal-survives-route` sits open — a modal that survives a hash route change, on the very primitive this round exists to certify — is precisely the unknowing seal Rival B was chosen to prevent. The same holds for a `favicon.ico` that ships on `origin/main` while `index.html` carries **zero** `rel="icon"` references to point at it, a "How archives work" link resolving to the bare repo root (`app.js:1623`), and two failure-shaped invite states sharing ICO_WARN's glyph because `app.css:3187-3189` defines only `--ok/--info/--warn`. These are FINISHING, not net-new capability, and they are the cheapest items standing between this epic and an honest seal-law assertion. The modal auto-close carries real coupling and must be briefed as such: the `#launch` deep link and the `?modal=account` harness seam both open modals via the hash, so a naive "close on any hashchange" would break the instrument this same round depends on.
- **GR103 — the ops bar is `rpc`, the address is a live human CHOICE, and the disclosure is harsher than the wish states.** `cp-deploy.sh:50` runs `set -a; . cloud/.env; set +a` before BOTH `compose build` and `compose up -d --no-build control_plane_$TARGET`, and the service config-hash provably changes with the variable — `b5036deb…` unset (byte-matching the running container's own label) versus `b19e78cd…` set — which is exactly what makes `docker compose up` RECREATE rather than reuse. **So one human line genuinely suffices and no extra step is needed**; GR60 step 1 is confirmed done on the box (`docker-compose.yml:67` passthrough byte-identical to `origin/main`, `.env` carrying 15 keys and no admin entry, container env empty). `eval` and `rpc` both return `[]` while unset and are INDISTINGUISHABLE precisely because an empty list never touches the Repo — rehearsing with `eval` and reusing it after the human acts yields a Repo-less crash at the exact moment it matters. **Address:** `frikk@guerrilla.no` holds ~20 valid tokens with real IPs and user-agents, last used 2026-07-20T05:01:56; `frikk@jarl.no` holds 2 tokens, both with null `ip_address` and null `user_agent`, one never used — registered but sessionless, so choosing it makes the 403→200 half **unexecutable**, and minting a token to satisfy the bar would be a circular proof. `kalle@jarl.no` is correctly ruled out (absent from prod's 18 users). **Disclosure:** there is NO mute, opt-out or unsubscribe anywhere in the tree; the only off switch is editing `.env` and restarting, and because `platform_admin_emails` is ONE allowlist with exactly TWO consumers, that same edit also revokes `platform_operator` and the warm-pool bypass — **digest-off and operator-off are one switch, not two**. Named residual: the script's own documented `docker start` rollback recipe does NOT refresh env, so a dormant slot resumed that way serves stale config. Correction to the wish's operational note: the DB read is `docker compose exec -T db psql …` on the control plane at `178.105.92.191`, per GR44.
- **GR104 — main is green, and the one red was NOT the named flake.** `0027ed383` is an ancestor of `origin/main` and every blocking gate passes at HEAD. The single failure this session, at `e9dde14c9`, was `BarkparkWeb.Studio.StudioLiveSheetPresenceTest` "a presence frame on a 500-row rendered sheet re-renders within budget" — `assert frame_ms < 10`, got `10.424`, a 4% overshoot — a SIBLING wall-clock-fragile budget test that predates `0027ed383`, is governed by no flake doctrine, and self-cleared on the very next run. **It is not `Sheets EnginePerfTest`, and filing it under "the known flake, already fixed" would repeat the explained-away pattern this epic exists to end.** `Format` is contractually advisory (`elixir.yml:53 continue-on-error: true`) and the two Vercel reds are systemic infrastructure breakage, not branch defects — proven by an unrelated Studio PR (`#2907`) failing identically and by `#4732` MERGING while carrying the identical three reds. Neither appears anywhere in `docs/ops/merge-gates.md`.

- **GR105 — ROUND 6 WAS BUILT, NOT UNBUILT; four finished branches sat UNPUSHED on this host and the wave's first act is to LAND them, never to rebuild them.** The survey's "round 6 produced no code" is true only of `origin` — `git branch -r` genuinely shows no slice branches. It is FALSE of the host. Five local branches exist, four of them code: `d8c751dc0` (cssom-parity, +572), `f719c5f4d` (shoot.sh, +163/−10), `c59f55e01` (mock.js, +37), `6ed100cad` (the four finishers, +271/−22), plus `a3ffbb4a2` (a wave log). All four code branches share merge-base `8503835ad` (#4757), a clean ancestor of `origin/main`; the four intervening commits are PDS/Studio work touching no file any of them touches, so every rebase is a no-op. Their four bp tasks carry **8/9, 9/10, 7/8 and 8/9 criteria met with pasted evidence, and on every one the sole unmet criterion is "PR merged", which the LEAD closes.** The provenance question is settled and it is not "foreign residue": the branches are held by worktrees `wf_30132e16-787-32/-33/-31/-34`, the SAME workflow run id as this cycle's own verifiers, and `wf_30132e16-787.json` records `status: completed, agentCount: 35, phases: [… Build, Review]` — **this run already executed a full seven-phase cycle at 06:50Z and was then rewound into Strategize, and the survey re-discovered its own Build output and mis-read it as a stranger's.** The `surveyor@local` signature that made it look foreign is the repo-wide git identity, identical in the main checkout and in every verifier worktree — it carries ZERO information about authorship. **BINDING: assigning a fresh builder to any of these four would be the most expensive mistake available to this wave.** They are one `git worktree prune` from being lost, so landing them is also the wave's most urgent act, not merely its cheapest.
- **GR106 — the four branches survive INDEPENDENT re-execution, so they land on measurement and not on their own ledger text.** Every "met: true" cited for them was originally quoted FROM THE LEDGER by read-only surveyors — in a wave premised on "a symptom explained away is data discarded", trusting that would be the same error wearing a different hat. So the proofs were re-run by hand on fresh `origin/main` worktrees, by verifiers who did not write the code. **cssom-parity:** calibration reproduces to the digit — `authored rule heads 1200 | CSSOM style rules 1200 | 1169 / 1169 flattened | MISSES 0`, PARITY PASS, identical across 3 runs; both mutation proofs fire (`✗ app.css:1035 .modal-root ← SWALLOWED`, and `.wh-secret` 2043 lines away), `app.css` restored bit-identical (sha `bdb9caf943cc`) after every mutation, zero orphaned Chrome, zero leftover profile dirs. **shoot.sh:** clean `origin/main` WEDGES on shot #1 against a SIGTERM-ignoring Chrome (still running at 46s, `0` ok lines, parent AND child alive); patched completes in 14s, 4/4 ok, and all four parents *and all four children* reap — `pkill -9 -P` is doing real work and a single-pid watchdog would have left four orphans. The mid-run-server-death false green reproduces on main as a cheerful `>> Done. 12 PNGs, exit 0, all 12 byte-identical` and the patch aborts naming the first bad shot with exit 1. **Finishers:** 640/640 unit tests, `__css_check` `0 error(s)`, smoke `all 86 scenarios rendered`, `design/check.mjs PASS` — all four verbatim string matches — and three mutation proofs reproduced by hand-mutating the checked-out code rather than trusting its own harness (force close-always → 3 red; force close-never → 1 red; revert `ICO_DEAD`→`ICO_WARN` → reds a unit test AND a smoke scenario).
- **GR107 — the duplicate-PNG defect is REAL, it is a scenario-drive coverage gap, and `c59f55e01` FIXES it — proven at Decide by measurement, not by its commit message.** GR97 ruled the count assertion a vacuous green because 20 of 80 PNGs were byte-identical twins. The mechanism is now fully nailed: `account-modal-2fa-badcode`'s only differentiator is a 422 consumed by a POST that fires only after two user clicks the static harness never performs, so at capture it sits at `phase='off'` with the base scenario's 2-session fixture — DOM-identical, hence exactly 5 accents × 2 themes × 2 widths = 20. `c59f55e01` drives the REAL flow through the REAL handlers (`#a2f-start` → POST enroll → `#a2f-otp` → `#a2f-confirm` → POST confirm → 422) and lets `app.js` paint its own `#a2f-error`; nothing is faked into the DOM and each step gates on an element the app actually painted (`whenPresent`), never on a timer — a fixed sleep would race the mocked fetch and trade one silent lie for another. **Re-proven at Decide on a 2-scenario × iris run: on `origin/main` the pair shares sha `b3962224…`; with the fix, plain STAYS `b3962224…` and badcode becomes `4c5aa29b…` — 8 of 8 distinct.** The twin assertion reds on today's main by construction. Residue is NAMED, never swallowed: the drive is keyed on the scenario NAME, a second convention beside `shoot.sh`'s modal prefix, filed as `gr-backlog-scenario-drive-field`. **Corollary: `account-modal-tall` is NOT a second duplicate flavour** — it differs from `account-modal` at every combination shot, so the `loadSessions` async-race hypothesis is refuted and there is no second duplicate class.
- **GR108 — there IS a fifth user-facing defect, it is net-new, and it makes the seal law's own clause false until fixed.** At 768, `button#theme-toggle` is the ONLY page-level overflow offender across all 10 states swept, and it appears on exactly the two past-due screens: `right=775` light (over by 7.0px) and `right=776.7` dark (over by 8.7px), with `document.scrollWidth` 775/777 against a 768 viewport — **so the whole page gains a horizontal scrollbar at tablet width, a genuinely user-visible symptom and not merely clipped geometry.** Root cause is one-line-fixable and fully diagnosed: past-due injects `<a#billing-chip class="billing-chip--past_due">` into `.topbar-right`, widening it 234.2px → 373.9px; the chip carries `white-space: nowrap` so it cannot shrink; `.topbar` overflows (clientW=521, scrollW=543) and children spill past their own parent. **The `@media (max-width: 768px)` block never tightens `.topbar` at all** — only the `@media (max-width: 720px)` block does, and 768 falls in the gap. Prior art: none — `bp search query` returns no matching task, GR59/GR65 audited `.fleet-row`/`.attention-row`/`.detail-grid` and never the topbar, and GR20 granted the billing chip its topbar slot without ever measuring its width cost. It is not among GR102's four. **BINDING: the seal law cannot honestly assert "zero known user-facing defect" while this stands unnamed, so it is FIXED this wave.**
- **GR109 — GR82 is OVERTURNED on new evidence: the attention-row fix was already WRITTEN and is DEAD CODE, which is this epic's own thesis wearing a stylesheet.** GR82 ruled the stacked `.attention-row` centring "768-only cosmetic tightness… not slice work" and deferred it to the successor. That judgment was made without knowing the fix exists. `app.css:1968`, inside `@media (max-width:768px)`, already writes `align-items: flex-start`. The base `.attention-row { align-items: center }` at `app.css:2659-2660` comes **LATER at identical specificity (0,0,1,0)** — media queries add no specificity — so source order wins and the authored fix is silently discarded; `flex-direction: column` survives only because the base rule declares no competitor. Mutation-proven: neutralising `app.css:2660` flips computed `center → flex-start` and snaps all three children to `left=275` (pill 318.5→275, acts 441.3→275), exactly the intended GR65 layout. **A fix we believe shipped and did not is precisely the class of defect this epic exists to end, and the remedy is one line of reordering.** It ships beside GR108 in the same slice.
- **GR110 — `.set-matrix` at 768 is CLEAN, and the prior audit's premise was wrong.** The cited `#notif-matrix right=797` reproduces on all six notif states, but that is the GRID's unclipped border-box and the WRAPPER does its job: `.set-matrix` carries `overflow-x: auto` (`app.css:1843`) with `clientWidth=431 / scrollWidth=520`, `document.scrollWidth = 753 < 768` (zero page-level offenders on all six states), and a reachability test moves the last column ("Webhook") from `right=519` to `right=430` — `REACHABLE: true` on all three scenarios. It is a scroll-affordance question, not a correctness one. **NAMED, not absorbed, and not seal-blocking** — the honest caveat is that at rest the last column is not visible and headless Chrome runs `--hide-scrollbars`, so the real-world affordance was not assessed; that judgment is recorded rather than hidden.
- **GR111 — the done-set audit is BOUNDED BEFORE IT READS, and GR46's manifest does not exist, so the sizing input changes.** The assigned reconciliation is UNEXECUTABLE as specified: GR46 records only the summary "22 unstamped-but-true criteria across 21 done children" and **the 21 names appear nowhere** — not in `origin/main`, not on disk, not in any of 9 worktree copies, and `git log -S'22 unstamped'` across all refs returns only the charter amendments. The manifest was a Decide-phase working artifact never committed, so "is it nearer 19 or 37?" cannot be answered and both figures are wrong regardless. **Substitute a mechanical stratification that sums exactly to 56:** S1 Class-A 10 (sole unmet criterion is "PR merged — LEAD CLOSES"), S2 supersession 3 (all criteria unmet, each carrying `SUPERSEDED by GRnn`), S3 genuine bypass 7, S4 no-claim-other 3, S5 clean CAS 33. **13 of 56 carry an unmet criterion and every one is fully explained by those two documented mechanisms — zero unexplained residue** — which matters enormously, because a naive "unmet criterion = suspicious" alarm would trip on 13/56 and blow the wave open on pure ledger hygiene. Zero done children have a `met:true` criterion with empty evidence. **Scope: full census of S1+S2+S3+S4 (23 children, 13 of them mechanical) plus a random sample of 12 of the 33 S5 children, one user-visible criterion each — 35 touched, ~15 requiring judgment, ONE slice.** 54 of 56 cite a PR or SHA somewhere so "confirm the artifact, spot-check the diff" works for 96%; only `gr-p5r4-shoot-seam` (evidenced, zero citation — its `github.issue: 4510` is a bp→GitHub ISSUE mirror, not a PR, so its "uncitable" status was a scan artifact) and `gr-backlog-email-fleet-mapping` (legitimately code-less) need another method.
- **GR112 — GR101 answered a DIFFERENT question from the one the seal rests on, and the triage rule is FIXED HERE, before any evidence is read.** GR101 verified citation AUTHENTICITY and the bypass MECHANISM — its own words are "code real, ledger sloppy… it protects an audit trail, it does not catch liars" — and it narrowed 13 to 7 honestly. It never asked whether the cited commit DOES WHAT THE CRITERION CLAIMS. On the seal's actual question the honestly-audited count is ~13 (GR101's code-claims) + 3 (audited at Verify) = **16, leaving ~40 unaudited** — worse than both 19 and 37. Three end-to-end audits ran at Verify and all three PASSED, including the two weakest-attribution shapes (`gr-p3-usage-metrics` from the bypass cohort: cited sha `09735e96b` is an ancestor and USAGE_METERS is 13-for-13 in the exact claimed order; `gr-p5r4-spa-a`: all four user-visible claims true; `gr-p5r4-shoot-seam`: its gate re-ran to 20 ok / 20 PNGs / 20 distinct hashes / exit 0). **"Material failure" is frozen now: the cited artifact does not exist on `origin/main`, OR the criterion's user-visible claim is false at `origin/main` today. NOT material: line-number drift, an unmet "PR merged" whose work is demonstrably on main, a supersession close carrying its `GRnn`.** Threshold: 0 → SEAL CLEAN; 1–2 → SEAL with a named re-verification successor carrying the specific failures plus a full census of the affected stratum; **≥3, OR any 1 in the S3 bypass cohort → SEAL DEGRADED** (the epic still seals; the successor's first task is a full 56-child semantic re-audit). **The invariant that does the actual bounding: a finding becomes a successor task, NEVER a mid-wave reopen and never a wave expansion.** Do not let "3/3 clean" become a reason to skip the audit — n=3 on a 56-member set justifies sizing at one builder, never skipping. Honest residue to be stated in the seal, not glossed: ~21 of the 33 clean-CAS children will still be sealed on evidence nobody read.
- **GR113 — three carried-forward "laws" are STALE and are corrected here, and the correction pattern is itself the finding.** (a) **GR83 is RETIRED as universal law:** `bp task get`'s `children` key does NOT KeyError on this CLI build — it returns all 123 children cleanly, and the server-side handler does an unbounded `Repo.all()` with no pagination cap. The HTTP `filter[parent_id]` query remains the roster mechanism of record (and the bare `?parent_id=` trap is REAL — it silently returns 500 rows across 34 parents), but a builder must not route around `bp task get` on the assumption it will fail; the defensive check is `child_count == len(children)`. (b) **`bp search` EXISTS** — the verb is `bp search query`, and `bp search docs`/`bp search <term>` error `unknown command`, which is why five surveyors concluded it was absent and fell back to grep. `bp search query "attention-row centring"` returns `gr-backlog-768-residue` as hit #1. The doctrine "search Barkpark before grepping" is executable, and its silent unavailability plausibly explains why four finished branches went unnoticed until Verify. (c) **The Operator console is NOT a dead link:** six `/v1/operator/*` routes are mounted, `require_platform_operator`-gated and wired to real reads, and `operatorPageHtml()` paints four live cards against them. Only the "Send one now" button is cut (GR40, already `gr-backlog-operator-digest-send`). **The honest ops disclosure is that the allowlist reveals a WORKING four-card console minus a send-now button** — the prior text was wrong in fact, not merely stale, and it was produced in this same wave, which is exactly why "settled, not re-asked" is a status no fact keeps for free. Two further measured corrections: GR100's own line anchors **have already drifted** (`.modal-root` 986→1034, `.wh-secret` 3005→3077) hours after being written — GR80 demonstrating itself inside its own successor entry, and a builder trusting those numbers would have mutated unrelated rules — and the twice-authored top-level selector census is **6, not 8** (`body` is authored exactly once).
- **GR114 — the ops line is unchanged in substance and sharper in its disclosure; the "live wedge" is INTERMITTENT and must not be inherited as a number.** The human line stays one append (`PLATFORM_ADMIN_EMAILS=frikk@guerrilla.no` >> `/opt/barkpark/cloud/.env`), the passthrough is confirmed on `origin/main` (`docker-compose.yml:67` bare passthrough, `runtime.exs:314-318`, `cp-deploy.sh:50` sourcing `.env` after pull and before `compose up`), and the proof bar is `rpc` against `Notifications.platform_admin_emails/0` — **never `eval`, and never `Application.get_env`**, because that function maps every address through `Accounts.get_user_by_email/1` and DROPS unregistered ones silently, so an env-grep passes for an address that will never receive anything. The address stays a CHOICE surfaced and never resolved: `frikk@guerrilla.no` is the only registered address holding a session token on this host (live-proven at Verify: `/v1/me` → 200, `platform_operator:false`), and no `frikk@jarl.no` credential exists anywhere on this host, so choosing jarl.no makes the 403→200 half unexecutable by this wave. `kalle@jarl.no` stays ruled out. The jarl.no registration figures are INHERITED from GR68/GR94/GR103 and were not re-derived — verifying them needs either a box query (forbidden this wave) or a real side effect against a live address — and that is flagged rather than presented as freshly proved. **On the wedge: it did NOT reproduce for three of four verifiers** (zero `--remote-debugging-port` processes) while a fourth found and reaped five genuine orphans (4 headless Chrome + a `serve.mjs`, all PPID=1, 4h04m–4h11m elapsed), two of which had written their PNGs at 07:21 and then ran three more hours. **BINDING: the wedge is conditional, so every shooting act carries its OWN external watchdog and asserts progress CLIMBING; "my run was clean" is not evidence the risk is closed, and neither is "a verifier found nothing".** One disclosed incident to carry: a verifier killed a concurrent sibling's live `serve.mjs` during a diligence sweep without first checking it against the wedge signature, and that sibling's harness visibly retried on a new port — a reap must match on PPID=1 AND elapsed time, never on name alone.

## Roadmap

### Wave 5 round 7 — THE SEAL, LANDED (2026-07-20 — 8 slices, 2 rounds — IN FLIGHT)

Wave Paper: `cloud-gui-remake-wave-2026-07-20-seal-r3`. Law: GR73–GR114. Builder model is **opus on every slice** (Fable is spend-limited this cycle). Every builder branches from `origin/main` in a detached worktree and reads this charter via `git show origin/main:…` (GR96), anchors on STRINGS and never on the line numbers printed here (GR80, re-proven by GR113's drift measurement), claims its own task before opening its PR and carries `Task: <slice id>` in the body (GR86).

**Act zero is NOT empty, and that is this round's headline (GR105).** Round 6 was decided AND built; its four code branches sit unpushed on this host, independently re-verified at Verify (GR106), one `worktree prune` from being lost. So round 7's first and most urgent act is to LAND them — rebase, re-run their gates, PR, merge — never to rebuild them. Four of the eight slices below are landings, and their tasks already carry 7–9 stamped criteria whose sole unmet entry is the merge criterion the LEAD closes.

What remains genuinely NEW is what round 6 could not reach: the fifth user-facing defect the seal law forbids sealing over (GR108) together with the dead-code fix GR82 deferred without knowing it had been written (GR109), the done-set audit bounded before it reads (GR111/GR112), and the successor epic whose roster is a function of what lands.

The seal is a GATE, its artifact is the DONE-SET, and this epic's whole durable finding is about gates that cannot parse their artifacts. That is why the audit is the crown and not a footnote, and why the photographs — kept at full 80-PNG scope — are no longer terminal evidence.

Round 1 (dependency-free, parallel — disjoint file sets):
1. **gr-blk-cssom-parity-gate** (small, opus) — LAND `d8c751dc0`. ONE new file under `__preview__/`. Ships UNWIRED from CI per GR93(b) and never gates the seal.
2. **gr-blk-shootsh-reap-timeout** (small, opus) — LAND `f719c5f4d`. Owns `shoot.sh` ENTIRELY and absorbs `gr-blk-shootsh-scen-guard`, which the LEAD closes as absorbed on merge.
3. **gr-p5r6-seal-finishers** (small, opus) — LAND `6ed100cad`. The GR102 four. Owns `app.js`/`app.css`/`index.html`/`__app.test.mjs`/`smoke.mjs`.
4. **gr-p5r5-modal-reshoot** (small, opus) — LAND `c59f55e01`. Owns `mock.js` only; the badcode honesty fix of GR107.
5. **gr-p5r7-doneset-audit** (large, opus) — the crown. Ledger-only, touches no code. Triage rule and threshold are FROZEN in GR111/GR112 and are pasted into the brief VERBATIM; if the builder re-derives them after seeing a failure they are not a rule and the bounded-outcome property is lost.

Round 2 (dispatched after their named deps MERGE — never beside them):
6. **gr-p5r7-tablet-overflow** (medium, opus) — AFTER slice 3, which owns the same region of `app.css`. The GR108 topbar overflow and the GR109 dead-rule reorder.
7. **gr-p5r7-reshoot-verify** (medium, opus) — AFTER slices 2 and 4, because it is the first run of the reshoot with the hardened `shoot.sh` and the fixed `mock.js` both on main. Full 80 PNGs, SCEN enumerated EXPLICITLY, iris first, fresh `$OUT` per accent at explicit non-default `PORT`, content-aware gate per GR97/GR98, ABANDON as an honest outcome.
8. **gr-p5r5-successor-seal** (large, opus) — AFTER 1–5, because the roster is a function of what landed.

The seal itself is REVIEW's act and is contingent (GR84). The GR46 stamp delta is NOT re-run — GR70 ruled it empty. `a3ffbb4a2` (round 6's own wave log) is DISCARDED rather than landed: this amendment folds its substance in, and landing two wave logs for one body of work would put contradicting accounts in one file.

### Wave 5 round 6 — THE SEAL, EARNED (2026-07-20 — 5 slices, 2 rounds — BUILT BUT UNPUSHED; slices 1–4 landed by round 7, see GR105)

Wave Paper: `cloud-gui-remake-wave-2026-07-20-seal-r2`. Law: GR73–GR104. Builder model is **opus on every slice** (Fable is spend-limited this cycle). Every builder branches from `origin/main` in a detached worktree and reads the charter via `git show origin/main:…` — GR96 confirmed the on-disk copy 93 commits stale for the THIRD time in a single survey, and it is the direct cause of the "fictional 80" error this round had to reverse. Per GR86 every slice PR carries `Task: <its own slice task id>` and the builder claims that task before opening the PR.

**Act zero is empty (GR95).** Both rescued PRs landed before this round ran; `origin/main` measures `834 classes / 1 known gap / 0 errors` and 86 scenarios. That freed the round to spend its budget on the two things the previous round's evidence could not reach: an instrument whose scope matches the defect class, and the user-facing residue that the seal law's own text forbids sealing over.

The round refuses the seal on the SHAPE of its evidence and then earns it. The previous plan would have produced 80 photographs of one modal family and certified a 31-call-site shared primitive with 4 scenarios — and GR97 then proved 20 of those 80 photographs are byte-identical duplicates under names whose state they do not show, so even the count guard the wish mandated is a vacuous green. Two widenings answer that, both instruments and never repairs (GR93): a CSSOM parity check that certifies every authored rule reaches the browser at once (GR100), and a ledger audit that has already run and whose deliverable is a NAMED task rather than a pile of reopened children (GR101).

Round 1 (dependency-free, parallel — disjoint file sets):
1. **gr-p5r5-modal-reshoot** (medium, opus) — the GR87 reshoot at **80** PNGs from a clean `origin/main` export, gated CONTENT-AWARE per GR97/GR98 (distinct-hash floor, no-badcode-twin, `ok`-lines == file-count, fresh `$OUT` per accent), wrapped in the GR99 external watchdog. Owns `mock.js` and the badcode honesty call; writes no `app.js`/`app.css`.
2. **gr-blk-cssom-parity-gate** (medium, opus) — the GR100 whole-stylesheet parity instrument: symmetric normalisation, brace-tracking parser, mutation-proven at two distant locations, ONE new file under `__preview__/`, unwired from CI.
3. **gr-blk-shootsh-reap-timeout** (medium, opus) — owns `shoot.sh` ENTIRELY and absorbs `gr-blk-shootsh-scen-guard`: the GR99 watchdog, the GR98 `ok`-count and fresh-`$OUT` guards, SCEN validation, and the stale "72 of 81" census refreshed against the live 86.
4. **gr-p5r6-seal-finishers** (medium, opus) — the GR102 user-facing residue: modal survives route, `rel="icon"`, archives doc link, invite danger variant. Owns `app.js`/`app.css`/`index.html`. Pure finishing; it is what makes the seal law's "zero known user-facing defect" clause honestly assertable.

Round 2 (dispatched after round 1 MERGES):
5. **gr-p5r5-successor-seal** (large, opus) — AFTER 1–4 merge, because the roster is a function of what landed. Roster re-derived FRESH per GR83/GR92 via the HTTP `parent_id` query, `cloud-console-billing-live-gate` moved BY NAME, both permanent human gates labelled, `gr-ops-platform-admin-emails` corrected per GR103, PART 3 executed as a RE-PARENT per GR91, and the GR96 fake-OPEN children closed on evidence.

The seal itself is REVIEW's act and is contingent (GR84). The GR46 stamp delta is NOT re-run — GR70 ruled it empty. The ops gate (`PLATFORM_ADMIN_EMAILS`) is the user's call, executed by no agent, handed over on day one so the human clock runs in parallel; if it is still unset when the round ends, that is the first line of the debrief.

### Wave 5 round 5 — THE SEAL WAVE (2026-07-20 — 4 slices, 2 rounds — LANDED; act zero closed by #4732 + #4733, see GR95)

Wave Paper: `cloud-gui-remake-wave-2026-07-20-seal`. Law: GR73–GR94. Builder model is **opus on every slice** (Fable is spend-limited this cycle). Every builder branches from `origin/main` in a detached worktree and reads the charter via `git show origin/main:…` — GR72's quarantine has WORSENED (ahead 10 / behind 77, 29 dirty foreign files, none under `cloud/`), and the primary checkout's own charter copy is **38 rules stale at GR46**. Per GR86 every slice PR carries `Task: <its own slice task id>` and the builder claims that task before opening the PR.

The wave's premise moved twice and is now settled by measurement (GR85): the crown fix is LIVE and byte-verified in production, `#4684`/`#4685`/`#4634` are all on `origin/main`, and Slice Zero is EMPTY. What remains is to make the seal true rather than declared — and to do it without repeating GR74, whose real finding is that the broken component was never the camera but the reader between the pixels and the verdict. So the terminal evidence is not "a reader looked at 80 pictures and pronounced them good"; a committed measurement instrument ships beside the photographs.

Round 1 (dependency-free, parallel — disjoint file sets):
1. **gr-p5r5-css-families** (medium, opus) — the six zero-rule CSS families, the three detector-artifact rewrites *plus the fourth site GR89 exposes*, and the GR90-narrowed ember `.vf-chip` background collision. Owns `app.css`, `__css_check.mjs` and the class-string edits in `app.js`. Criterion 3 is re-authored per GR89: the survivor is the `head:"bp-lc-"` E3.
2. **gr-p5r5-modal-reshoot** (small, opus) — the GR78/GR87 re-shoot at **80** PNGs, `SCEN` enumerated explicitly per GR88, count asserted independently, progress observed climbing. **Writes no source at all.**
3. **gr-p5r5-modal-cssom-oracle** (medium, opus) — the mutation-proven CDP oracle of GR93, one new file under `__preview__/`. Ships unwired from CI; it never gates the seal.

Round 2 (dispatched after round 1 MERGES):
4. **gr-p5r5-successor-seal** (medium, opus) — AFTER 1, 2 and 3 merge, because the roster is a function of what landed. Roster re-derived FRESH per GR83/GR92, `cloud-console-billing-live-gate` moved BY NAME, both permanent human gates labelled, `gr-ops-platform-admin-emails` corrected on four axes per GR94, and PART 3 executed as a RE-PARENT per GR91.

The seal itself is REVIEW's act and is contingent (GR84). The GR46 stamp delta is NOT re-run — GR70 already ruled it empty. The ops gate (`PLATFORM_ADMIN_EMAILS`) is the user's call, executed by no agent, handed over on day one so the human clock runs in parallel; if it is still unset when the wave ends, that is the first line of the debrief.

### Wave 1 (2026-07-18/19 — 8 slices, 3 rounds — COMPLETE, all merged #4230–#4238)

Round 1 (dependency-free, parallel):
1. **gr-w1-css-check-detector** (small, opus) — __css_check.mjs recognizes `html[data-bp-theme]` blocks (E6 88→0), E5 fans to 10 theme states, @property E1 false-positive fixed, ALLOW_PREFIXES omissions added. NOT CI-wired yet.
2. **gr-w1-token-ramps** (large, fable) — designer accent ramps ×4 + iris.json + tuned status/contrast values + `--ok-strong` + sync-evergreen.mjs + ratchet/golden updates across JS + Go.
3. **gr-w1-fonts** (medium, opus) — Plex Mono + Inter latin subsets, @font-face, OFL renames, router fonts-immutable cache fix.
4. **gr-w1-operator-me-flag** (small, opus) — `/v1/me` platform_operator boolean.
5. **gr-w1-handover-archive** (small, opus) — commit design/handover/ui-review-9/ + pointer amendment in bp-cloud-console-charter.md.

Round 2 (after gr-w1-token-ramps merges):
6. **gr-w1-cloudchrome-bridge** (large, fable) — color.cloudChrome passthrough family + legacy alias bridge in the generated block + validate.mjs/Part-G/Part-H list extensions.

Round 3 (after cloudchrome-bridge + detector + operator merge):
7. **gr-w1-styleguide-port** (medium, fable) — Styleguide.dc.html → styleguide.html port, emitter swatch byte-splice consuming data-sg hooks, E5 designer pairs, __css_check wired into console-harness.yml, exit 0.
8. **gr-w1-shell** (large, fable) — A-01..A-04: sidebar + topbar + context-morph + 5-identity switcher UI + generated BP_THEMES + Operator entry + reset-route tests.

### Wave 2 (2026-07-19 — phase 2 THE MONEY PATH, 4 slices, 2 rounds; Paper `cloud-gui-remake-wave-2026-07-19`)

Phase 1 is COMPLETE on main (#4230–#4238, grade A-). Wave 2 cuts the journey per GR16:

Round 1 (dependency-free, parallel builds, sequential OC9 merge train):
1. **gr-p2-front-door** (large, fable) — B-01..B-03: login/signup/reset/2FA-challenge composed fresh per GR21; shared primitives restyled once; 2FA card decoupled to .auth-title/.auth-desc; TFA_RATE_WAIT_S→60; signup/reset/2FA scenarios + smoke (absorbs gr-backlog-reset-route-smoke).
2. **gr-p2-plan-dunning** (large, fable) — C-03 trial state (ratified CTA, countdown chip) + C-04 dunning (GR17 copy, portal wiring, ?billing=portal return handler) + GR19 quota-honest plan grid + GR20 topbar billing chip + activePlan() fix + ERRORS map entries; past_due/trial-billing scenarios + smoke.
3. **gr-p2-launch-theater** (large, fable) — D-08/E-05: /new journey + theater in v4 language per GR18 (conditional rail, real verify, catalog price line, snap-fail branch, open console, restyled readyHeroHtml); retires --primary-soft; /new + theater scenarios + smoke.

Round 2 (AFTER gr-p2-plan-dunning merges):
4. **gr-p2-home-triage** (large, fable) — C-01 triage headline + chips + attention queue + instance cards + recent activity, C-02 self-healing runway bound to /v1/me onboarding fold (GET/POST role asymmetry honored), overview past-due banner + suspended instance-card banner reusing the GR17 component; loadOverview splits empty/trial/active/past-due states; overview state scenarios + smoke.

### Wave 3 (2026-07-19 — phase 3 THE DAILY DRIVER, 8 slices, 2 rounds; Paper `cloud-gui-remake-wave-2026-07-19-p3`)

Phase 2 is COMPLETE on main (#4254/#4256 + train). Wave 3 restyles where operating customers live, per GR23–GR31. All region line numbers pinned at origin/main 5cac4ffe (app.js 13,062 lines).

Round 1 (dependency-free parallel builds; sequential OC9 merge train, hygiene FIRST):
1. **gr-p3-hygiene-guard** (medium, opus) — css_check CSSOM parse-completeness guard (E9, #4251 fixture) + GR29 dead-var retirement (11 --cc-* via tokens.json/emit, --space-1/7/8 by hand, --elev untouched) + mock.js ?accent= axis. Absorbs task-7836903b7ea83111 + gr-backlog-dead-vars.
2. **gr-p3-fleet-archives** (medium, opus) — D-01: fleet density rows + NEW update chip + Archives panel restyle + storage-unconfigured state. Resurrect journey (D-10) is BUILT — untouched.
3. **gr-p3-instance-workspace** (large, fable) — D-02+D-03 merged per GR24: header (compound status, lifecycle, bp CLI card) + Overview in one composed pass (verify, updates, identity/runtime, sites, domains). Owns the verify cluster; adds panel-overview EXPECTATIONS.
4. **gr-p3-timeline-grammar** (medium, fable) — D-04: coalesceEntries + tlv-coalesce, the ratified standard grammar (GR26); timeline tab restyle. Never touches verify*.
5. **gr-p3-webhooks** (medium, opus) — D-05: CRUD + test send + deliveries/replay per the designed card; cliChipHtml consumers stay unbroken.
6. **gr-p3-usage-metrics** (large, opus) — D-06+D-07: 13 honest meters (no arcs), all 4 vitals + honest stubs, warmup banner killed; adds metrics EXPECTATIONS; fleetStrip dead code untouched.
7. **gr-p3-site-detail** (large, fable) — E-02: deploy ladder (trigger-only provenance), failure copy, live console, rollback, GitHub connect + DOMAIN CHECKLIST component restyle wired into site detail; retires --accent; kills the scale toggle.

Round 2 (AFTER gr-p3-timeline-grammar AND gr-p3-site-detail merge):
8. **gr-p3-small-surfaces** (medium, opus) — E-01 sites list (invented kind labels die, GR28) + E-03 env editor greenfield (write-only, blank-start, backend-verified button copy) + I-01 activity regrown on the merged grammar with filters. Builds the #sites/#activity fixtures from scratch.

### Wave 4 (2026-07-19 — phase 4 THE SETTINGS WAVE, 7 slices, 2 rounds; Paper `cloud-gui-remake-wave-2026-07-19-p4`)

Phase 3 is COMPLETE and LIVE (#4271/#4274/#4275; prod bundle diff-proven byte-identical). Wave 4 cuts per GR32–GR38; all facts verified at origin/main 37304602f..fbd25ff93.

Round 1 (dependency-free, parallel; hygiene merges FIRST in the train, route PR rides its own Elixir gate):
1. **gr-p4-hygiene** (medium, opus) — GR37 verbatim: dark --btn-bg identity-aware + GR29 retirement finished 3-place + last .orig removed + .set-* library + me() role seam + operatorVisible fix.
2. **gr-p4-deliveries-route** (small, opus) — GR35: GET /v1/notifications/deliveries, admin-gated, ~90-140 lines, tests appended to router_notifications_test.exs.

Round 2 (AFTER gr-p4-hygiene merges; gr-p4-notifications also wants gr-p4-deliveries-route merged for live-route truth but renders on fixtures regardless):
3. **gr-p4-billing** (medium, opus) — G-01 per GR36: reference composition on the .set-* anatomy; owner-only gating + forbidden copy; in-app Cancel plan… (password-reconfirm danger modal); portal/return states kept.
4. **gr-p4-providers-matrix** (large, fable) — G-02+G-03 per GR36: connect/verify remediation restyle + typed-confirm disconnect + already-connected guard + the 9-verb honest capability matrix (dev-tier filtered, server-owned gap reasons).
5. **gr-p4-notifications** (large, fable) — G-04 per GR36: channels roster + transports restyle, event×channel routing matrix on .set-toggle, delivery log (fixtures + honest error degrade), sendTestNotification moves home.
6. **gr-p4-tokens** (medium, opus) — G-05 per GR34: .set-check restyle of the built picker, plain-member truth up-front, plaintext-once reveal designed, grammar convergence (retire .token-ability naming into .set-check).
7. **gr-p4-members-env** (large, opus) — G-06 per GR36: members roster/invitations restyle (3 roles, typed-confirm remove) + greenfield #settings/env page on the proven 6-touch shell recipe (member-read/admin-write, write-once 409, sealed values).

Phase-3 residue rides THIS wave's Review: accent LOOK-AT-IT pass (post-hygiene ?accent=) now covering the six settings pages, matrix-shot budget (gr-backlog-shoot-matrix-budget), live proof re-run over settings, GR38 census report.

### Wave 5 (2026-07-19 — phase 5 THE FINISH LINE, 8 slices, 4 rounds; Paper `cloud-gui-remake-wave-2026-07-19-p5`)

Phase 4 is COMPLETE and LIVE (#4304 = 444f07317; prod bundle byte-identical; all six settings pages live-proven with a real owner session; the two "held" claims closed 6/6 ~90s post-merge). Wave 5 takes the epic from "settings landed" to SEALED per GR39–GR46. **All builders branch from origin/main (444f07317 or later)** — the primary checkout's local main is diverged with foreign charter commits and a foreign dirty diff; pull in your worktree, never trust this checkout's working tree.

Round 1 (parallel, disjoint file sets):
1. **gr-p5-operator-routes** (medium, opus) — GR39 verbatim: `require_platform_operator` + the 5 `/v1/operator/*` routes + `list_fleet_deliveries/1`; new `router_operator_test.exs` (non-operator session 403 / operator 200 / worker-token routes byte-untouched, existing 42 autoupdate+builder tests stay green).
2. **gr-p5-grammar-pass** (medium, fable) — GR41's grammar half: danger-no-echo tier + rich body, both rollback folds, dead-toast fixes + shape test, styleguide modal-family docs.
3. **gr-p5-flotilla-closers** (medium, opus) — GR45 api leg (webhook test-send, own PR) + GR46 closers: shoot.sh fix (SCEN/ACCENT/kill-wrapper), tenancy.md two-axis role paragraph, email-fleet enumeration close, branch exhaust (gh-verified deletes, absorbs gr-backlog-wave-exhaust).

Round 2 (after named deps MERGE):
4. **gr-p5-operator-console** (large, fable; AFTER 1+2) — GR39/GR40: the #operator view (VIEWS/parseHash/nav), 4 honest cards (brake, canary 20m, warm-pool honest-zero, digest last-delivery; NO Send-now), loadFleetRollout repointed; states-complete + scenarios + smoke; never consumes fleetStrip*.
5. **gr-p5-honesty-batch-1** (medium, opus; AFTER 1 — router.ex/notifications.ex freed) — 4 small own-gate PRs: TFA retry_after seam; audit filter params (actor_user_id + action-prefix); deliveries filters (channel/status/event + ?before keyset, router-capped); webhook test-send cloud proxy passthrough (GR45 leg 2). Elixir-only: NO app.js edits (SPA wire-ups ride slice 8).

Round 3:
6. **gr-p5-account-2fa** (medium, fable; AFTER 4) — GR41's account half: 2FA section in openAccountModal, 7 states (2 drawn + 5 composed), new pure helpers hook-exported + node-pinned; login-challenge 2FA surface untouched.
7. **gr-p5-honesty-batch-2** (medium, opus; AFTER 5) — provider reconnect per GR44 (defensive migration + upsert + route tests) as one PR; favicon + HEAD handling in the one shared static block (cloud router.ex:266-294) as a second PR.

Round 4:
8. **gr-p5-spa-finishers** (large, opus; AFTER 5+6+7) — deletions + wire-ups LAST: fleetStrip* + its 9 tests die (GR42); css_check missing-classes closure (re-census the 9 demoted items); reset-route smoke scenario; cap-payload drift guard (refute top-level default_gap + derive CAP_PAYLOAD from the fixture); archives "How archives work" links a real doc target or dies; TFA retry_after SPA wire (TFA_RATE_WAIT_S seam); audit UI switches to server-side filters; provider re-connect client guard relax; webhook "Send test" button.

Close-out rides this wave's Review: accent LOOK-AT-IT over the six settings pages via the fixed shoot.sh (iris first, GR30), GR43 census closing report (live re-count), live proof re-run on barkpark.cloud, GR46 stamp-manifest execution + close-now set, and every remaining epic child closed-with-evidence or re-parented to a NAMED successor — then the epic task itself closes.

### Later waves (post-seal residue — the named successors)
- D24 statusMeta/dep-pill sweep — `gr-backlog-d24-statusmeta-sweep` (EXISTS, open; SOLO-SPA by law, needs a wave with nothing else in app.js/app.css — GR42).
- Operator digest send-now route — `gr-backlog-operator-digest-send` (GR40's cut button, if ever wanted).
- Deploy-ladder actor cross-ref decision — `gr-backlog-e02-deploy-actor`.
- Operator principal reconciliation — `isu-backlog-operator-principal` (foreign epic; GR39's plug + /v1/me boolean both inherit it).
- Billing live gate — `cloud-console-billing-live-gate` (human gate, not agent-buildable; GR19).
- Console redaction allowlist — `gr-backlog-console-redaction-allowlist` (GR52d: Go `internal/provisioner` + `internal/builder/console.go`, outside this epic's `cloud/` boundary — named here so the seal is honest).
- Operator entry in the Cmd+K palette — `gr-backlog-operator-palette-entry` (GR49: `paletteNavItems()` is a static argument-free registry; adding a role-gated entry needs a signature change + test rewrite).
- Durable coherence-fixture binding — `gr-backlog-coherence-fixture-durable` (GR47: make `coherence.html` READ the goldens instead of embedding them, so a foreign cycle can never red the console harness again).
- Cloud-suite order-dependent flake — `gr-backlog-cloud-suite-seed-flake` if the round-1 slice cannot root-cause it (GR47).
- Webhook test-send HTTP-level contract test — `gr-backlog-webhook-testsend-http-test` (GR45: the route is live and reachable but has ZERO controller-level coverage; `api/test/` has no `test_send` reference at all).
- Account-2FA confirm throttle (defense-in-depth only) — `gr-backlog-tfa-confirm-throttle` (GR52b: needs its own key namespace).
- Everything else formerly listed here is TAKEN or CLOSED by wave 5 (GR46 close-now set + the slices' absorptions).

### Wave 5 round 2 (2026-07-19 — phase 5 THE FINISH LINE, 7 slices, 3 rounds; Paper `cloud-gui-remake-wave-2026-07-19-p5r2`)

Round 1 landed whole (GR47). This round builds the two crowns and everything that finishes the epic. **Every slice runs on `builder_model: opus`** — Fable is spend-limited this session, so the briefs carry the rigor the model would otherwise supply. **All builders branch from origin/main (`567bf6e39` or later) in their own worktree; `cloud/deps` may need `mix deps.get` before any Elixir gate.**

Round 1 (parallel, disjoint file sets):
1. **gr-p5-coherence-fixture** (small) — GR47: re-embed `internal/taskboard/testdata/styleguide_lifecycle.txt` verbatim into `coherence.html`'s `co-fixture-lifecycle` block (584/0) and widen `console-harness.yml`'s path filters so a golden change re-runs the harness. Ships FIRST — every SPA builder otherwise opens red on someone else's break.
2. **gr-p5-operator-console** (large) — THE CROWN. GR39/GR40/GR48/GR49/GR50: the `#operator` view, four honest cards wired to the real byte shapes, fail-closed route bounce, Fleet demoted read-only.
3. **gr-p5-honesty-batch-1** (medium) — Elixir-only, four small own-gate PRs: TFA retry_after; audit filters; deliveries filters; the webhook test-send CLOUD proxy (GR45 leg 2 — its api leg is on main as of #4391).
4. **gr-p5-cloud-flake** (small) — GR47: root-cause and fix the order-dependent cloud-suite flake pair so the required gate stops lying.

Round 2 (after named deps MERGE):
5. **gr-p5-account-2fa** (medium; AFTER 2) — THE SECOND CROWN. GR41/GR52b: the 2FA section in `openAccountModal`, seven states, **no 429 state**.
6. **gr-p5-honesty-batch-2** (medium; AFTER 3) — provider reconnect (GR44) + favicon/HEAD in the one shared static block.

Round 3:
7. **gr-p5-spa-finishers** (medium; AFTER 5+6) — GR51's corrected deletion (five die, two relocate) + orphaned `.fleet-usage-*` CSS + stale ALLOW_PREFIXES + css_check gap closure + reset-route smoke + cap-payload guard + the SPA wire-ups for batches 1 and 2.

Not a slice, ruled instead: role vocabulary (GR52a, no-diff close), the 2FA confirm throttle (GR52b, not a security gap), `gr-backlog-d24-statusmeta-sweep` (GR42, solo-SPA by law).

Ops gate, not agent-buildable: `gr-ops-platform-admin-emails` (GR52c) — the operator console's LIVE proof waits on it; the build does not.

**The seal is EARNED, not declared.** The epic closes only when every one of its children is closed-with-evidence or re-parented to a NAMED successor (the list above). If any of the seven slices slips, the honest handoff names `gr-p5-spa-finishers` as the successor and the epic stays open.

### Wave 5 round 3 (2026-07-19 — phase 5 THE SEAL WAVE, 6 slices, 2 rounds; Paper `cloud-gui-remake-wave-2026-07-19-p5r3`)

Act one required no act: all four round-2 PRs merged before Decide (#4432 `c2dc2e0f5`, #4433 `301e035d8`, #4430 `6bc7646ff`, crown #4434 `93fd1e2d8`). Baseline is GR53's 600/600 · 810/0 · 81/81.

Round 1 (dependency-free, parallel — file-disjoint by construction):

1. **gr-p5-account-2fa** (large, THE SECOND CROWN) — recompose `openAccountModal` in place to `01/02-fixed` and finish 2FA over the five password-free routes. GR54 (pins first, composition-only), GR55 (the QR ships from the proven spike), GR56 (one-shot sheet, hide the ×), GR57 (`--info` links, `:has()` width), GR58 (the `?modal=account` seam). Owns all five SPA tail zones this round.
2. **gr-p5-honesty-batch-2** (medium) — provider reconnect dedup migration + `(team_id,kind)` upsert (GR44, live-reproven: prod has 1 row / 0 duplicate pairs) plus favicon.ico and HEAD-on-shell-paths in one router block.
3. **gr-p5r3-ops-passthrough** (small) — GR60 step 1: the compose passthrough line, the `.env.example` stanza, and the env→config→resolver→gate test. Steps 2 and 3 stay a named human gate.
4. **gr-p5r3-shoot-accent-fix** (small) — GR58's one-line ordering fix so the accent axis stops lying, plus a re-shot proof that a deep-linked scenario actually changes identity.

Round 2 (AFTER round 1 MERGES):

5. **gr-p5-spa-finishers** (large; AFTER 1) — GR51's corrected deletion (five die, two relocate, recipe proven +19/−430 to a green 591/800/81), the 18 orphaned `.fleet-usage-*` blocks and 2 stale ALLOW_PREFIXES, GR59's 768px breakpoint fix, css_check gap closure, reset-route smoke, cap-payload guard, and the SPA wire-ups for batches 1 and 2 — including the delivery-log filter affordance, which no other slice owns.
6. **gr-p5r3-successor-epic** (small; AFTER 1+5) — file the NAMED successor epic and re-parent every true survivor into it, `cloud-console-billing-live-gate` BY NAME (GR61: it is not this epic's child and inheritance will never reach it).

Not a slice, ruled instead: the GR46 stamp delta and the GR61 cloud-flake reword (Decide-phase ledger acts, executed at Decide); `gr-backlog-role-vocabulary` (already `done 3/3`, a phantom in the wish); `gr-backlog-d24-statusmeta-sweep` (GR42, solo-SPA by law).

**The seal is a REVIEW act.** The epic closes only after round 2 merges and every child evidence-closes or is re-parented to the named successor. If any slice slips, the honest handoff names its task and the epic stays open — never a silent unfinished scope.

### Wave 5 round 4 (2026-07-19 — phase 5 THE LIGHTS GO ON, 4 slices, 3 rounds; Paper `cloud-gui-remake-wave-2026-07-19-p5r4`)

Act one required no act again, and more than that: all four round-3 PRs merged BEFORE Decide and the union deploy is LIVE (GR62). Baseline is **626 / 842 / 85 / 84 / 0**, not GR53's 600/810/81.

This wave's job is not a checklist — it is to stop proving and start LOOKING, then write the seal on top of pixels. **Every slice runs on `builder_model: opus`** (Fable is spend-limited). All builders branch from `origin/main` in their own worktree; the primary checkout is quarantined (GR72).

Round 1 (dependency-free, parallel — file-disjoint by construction):

1. **gr-p5r4-spa-a** (large) — the measured half. GR63's modal-overflow BLOCKER first (the crown screen is broken in prod), GR65's focus ring and the GR59-widened 768px block fix, GR51's proven deletion (+16/−404), the 18 orphaned `.fleet-usage-*` blocks and 2 stale ALLOW_PREFIXES, and the JS-only cap-payload guard. Owns the SPA tail zones this round.
2. **gr-p5r4-shoot-seam** (small) — GR66: `shoot.sh` learns `pathname`/`search`/`?modal=account`, joined on `\x1f` and never TAB. Touches ONLY `shoot.sh`; zero collision with slice 1.

Round 2 (AFTER 1 MERGES — same train slot, never beside it):

3. **gr-p5r4-spa-b** (large; AFTER `gr-p5r4-spa-a`) — the judgment half. The six zero-rule CSS families off their proven siblings, the four backend wire-ups (retry_after, audit filter axes, the delivery-log filter panel that no other slice owns, webhook Send-test), the operator zero-staging-boxes fixture, and whatever the GR67 matrix triages as user-facing.

Round 3 (AFTER 1+3 MERGE):

4. **gr-p5r4-successor-epic** (small; AFTER `gr-p5r4-spa-a` + `gr-p5r4-spa-b`) — GR70: file the NAMED successor epic, re-derive survivors FRESH from the server, move `cloud-console-billing-live-gate` by name, flag both permanent human gates, and correct the ops task's ACTION text rather than copy it.

Not a slice, ruled instead: the GR46 stamp delta (GR70 — **empty**, do not re-run); the accent × theme × width matrix (GR67 — a REVIEW act with its triage rule already fixed); the ops `.env` edit (GR68 — a human decision, put to the user with the exact commands and the daily-digest disclosure); the `peer_ip` container fix and the OAuth-HEAD guard (GR69 — named successors, outside a pure-SPA wave); the primary-checkout reconciliation (GR72 — blocked on another session).

**The seal is a REVIEW act.** It does NOT mean zero residue; it means zero UNNAMED residue and zero known user-facing defect — and as of Decide there are TWO known user-facing defects (GR63, GR65), both owned by round 1. If they do not land, the epic stays open and says so.

**Wave-log debt, named so it stops being invisible:** the wave log below ends at round 1. Rounds 2 and 3 (both grade A) exist only in their Papers `cloud-gui-remake-wave-2026-07-19-p5r2` and `-p5r3` — the DECISIONS made it into this charter via #4400 and #4448, the STORY never did. Review folds rounds 2, 3 and 4 in together, or the seal ships on a charter that cannot say the crown was ever built.

## Wave log

### Wave 2026-07-19 — round 1 built + reviewed, grade A-

Round 1 (4/4 slices green, reviewed, fixed in place; Paper cloud-gui-remake-wave-2026-07-18 holds the debrief):

- **gr-w1-css-check-detector** → `loop-epic/css-check-sees-the-multi-identity-machin-0-r` — E6 88→0, E5 fans to every identity×mode state, E1 @property fixed, 11 verified ALLOW_PREFIXES. Review fix: identity ramps are now DISCOVERED from the CSS (`html[data-bp-theme]` scan), not a hardcoded 4-list — iris joins the fanout automatically (integrated: 12 states, 408 pairs).
- **gr-w1-token-ramps** → `loop-epic/designer-accent-ramps-in-the-canonical-t-1-r` — 4 ramps restyled to designer seeds + iris 5th (160/160 native, 0 overrides), sync-evergreen.mjs atomic writer, 16 surfaces re-emitted, Part H 270 AA checks green. Review fixes: theme_resolve_test.exs theme-list pin gains `:iris` (would have red the blocking Elixir Test gate); coherence.html's embedded pdrender golden re-embedded (accent row moved; `__app.test.mjs` pins the bytes — was red, invisible to the slice gate). **Merge waits on Elixir Test CI** (6 .ex/.heex files re-emitted).
- **gr-w1-fonts** → `loop-epic/self-hosted-ibm-plex-mono-400-500-600-la-2` (no fixes) — 4 woff2 = 81,668 B (≤120KB), Inter keeps its wght 100–900 axis post-subset, Plex Mono 400/500/600 verified genuine, OFL files prefixed, `--mono` leads with Plex in the hand `:root` (outside the generated block).
- **gr-w1-operator-me-flag** → `loop-epic/v1-me-grows-fail-closed-platform-operato-3` (no fixes) — `/v1/me` platform_operator fail-closed off `:platform_admin_emails` (never team role), `platform_admin_emails/0` public + GR9-documented, /fonts split-plug immutable cache, 158/158 router tests. **Merge waits on Elixir Test CI.**

Cross-slice: all four branches octopus-merge clean off origin/main; integrated state re-proven (design/check.mjs PASS, css_check E6=0/E1=0, E5 23→20 — restyle cured 3, rest is round 2's target, `__app.test.mjs` 438/438).

Stalled/debt: charter (c9ac492dc) + 59-file handover archive + console-charter supersession note (5d76ec445) sit on the PRIMARY checkout's local main, diverged 2/2 from origin — filed `gr-w1-charter-archive-pr` (the GR11 reconciliation is invisible to concurrent sessions until it lands). This branch (`loop-epic/gr-w1-charter-wave-log`) carries the charter+wave-log off origin/main for that PR.

Next wave dispatch order (sequenced-rounds law): (1) merge round 1 — Node/asset slices on their gates, the two Elixir-touching slices ONLY after the Elixir Test gate is green; (2) land `gr-w1-charter-archive-pr`; (3) round 2 `gr-w1-cloudchrome-bridge` (needs token-ramps merged; targets E5=0/E6=0); (4) round 3 `gr-w1-styleguide-port` (needs bridge + detector) and `gr-w1-shell` (needs bridge + operator) — sequential on the OC9 append-only tails.

### Wave 2026-07-19 (2) — phase 2 round 1 (THE MONEY PATH) built + reviewed, grade A-

Round 1 (3/3 slices green, reviewed, fixed in place; Paper `cloud-gui-remake-wave-2026-07-19` holds the debrief):

- **gr-p2-front-door** → `loop-epic/front-door-login-signup-reset-2fa-challe-0` (no fixes needed) — B-01..B-03 composed fresh per GR21: identity welcome glow, cc-card auth card, segmented tabs, mono "or" divider, .auth-title/.auth-desc decoupling (all 3 2FA mount sites test-pinned), TFA_RATE_WAIT_S 30→60 deliberately pinned, #signup deep link via pure authModeFromHash (router untouched, GR10), 10 light+dark evidence shots committed. Its builder found the P0 star-slash `--btn-bg` swallow on main; the lead hotfixed it as #4251 and the duplicate was dropped from this branch — clean merge with origin/main verified.
- **gr-p2-plan-dunning** → `loop-epic/plan-dunning-trial-state-with-the-ratifi-1-r` — C-03 ratified CTA verbatim over an always-open quota-honest grid, C-04 GR17 banner data-driven (−3d grace math test-pinned), every billing CTA POSTs the live /v1/billing/portal, ?billing=portal return handler (scrub + re-poll + neutral ack), GR19 ONE PLAN_CATALOG + friendly() precedence fix, GR20 topbar chip XOR + planFromSub past_due fix. Review fixes on -r: reconciled its GR7-comment respell with #4251's wording (was a guaranteed conflict), and the trial team's Free tier card sheds its doomed `plan=free` checkout button (server 422s plan_invalid) for an honest inert label + pin.
- **gr-p2-launch-theater** → `loop-epic/launch-theater-new-journey-provisioning--2-r` — D-08/E-05 per GR18: conditional rail (5/7 unit-pinned), verify-is-live comment truth, price-before-charge from the real per-kind catalog on BOTH mounts, snap-fail ladder (0ms failed flip + dashed `skipped` rows, no plan hints), v4 theater layout (centred head, 320px rail beside the open console, phone stacking + reduced-motion), GR22 --primary-soft retired (sole consumer → --ok-soft, byte-identical). Review fixes on -r: reconciled its GR7-comment respell with #4251. Reviewer re-proved all theater states headless (failed light+dark, mid-flight dark, 390px phone: 0 overflowing elements at true viewport).

Cross-slice: sequential OC9 merge train verified END-TO-END on `wave-integration-test` (origin/main + all three in train order): the tails collide exactly as designed — resolve with git's UNION driver then restore the 5 eaten common closers (`});` / `},` at each seam; the branch holds the exact resolution). Union state green: __app.test.mjs 466/466, smoke 43/43, css_check 0 errors, design/check.mjs PASS, docs-anchors PASS.

Stalled/debt: the GR16-GR22 charter amendment (ec590db14) was committed to an orphaned local commit on NO branch — rescued by cherry-pick onto this branch (`loop-epic/gr-p2-charter-wave-log`); land it with the train. Theater evidence PNGs live in reviewer scratchpad, not committed (builder handoff raced the host). fmtDay renders dunning dates in host locale (accepted — user-local dates). Billing chip absent on a cold boot straight into #activity until any subscription-loading view runs (accepted, minor).

Next wave dispatch order (sequenced-rounds law): (1) merge round 1 sequentially — front-door first (clean), then plan-dunning `-r`, then launch-theater `-r`, resolving the tail-append conflicts per the union recipe above (or merge `wave-integration-test` wholesale after per-slice review sign-off); the lead closes each task's merge-gated criterion 5 on merge; (2) land `loop-epic/gr-p2-charter-wave-log` (GR16-GR22 + this entry); (3) round 2 `gr-p2-home-triage` — dispatch ONLY after gr-p2-plan-dunning is on main (it reuses the GR17 banner component + GR20 chip states); (4) phase-2 close-out: full-matrix shots, live proof on barkpark.cloud.

### Wave 2026-07-19 (3) — phase 3 round 1 (THE DAILY DRIVER) built + reviewed, grade A-

Round 1 (7/7 slices green, reviewed; ZERO code fixes needed — first wave where every slice passed adversarial review as-built; Paper `cloud-gui-remake-wave-2026-07-19-p3` holds the debrief):

- **gr-p3-hygiene-guard** → `loop-epic/hygiene-css-check-swallowed-declaration--0` — E9 parse-completeness guard (flat token scan vs `;`-delimited browser parse; #4251 fixture FIRES exit 1, real pre-fix app.css fires at --btn-bg:285), GR29 dead-vars 16→2 (11 --cc-* retired at SOURCE via CC_ROLES+tokens.json then emit --write; --space-1/7/8 hand-deleted; --elev-0/-3 reserved), mock.js ?accent= pre-paint axis (5 ids, iris proven headless). Reviewer verified 0 consumers of every retired var across ALL SIX sibling branches' additions. Found+filed: dark --btn-bg hardcoded green breaks non-evergreen CTAs (task-396a2fa055f92c51).
- **gr-p3-fleet-archives** → `loop-epic/d-01-fleet-archives-in-v4-density-rows-n-1` — D-01: leading lifecycle-pill column, backend-true mono meta line (region·size·version·channel·autoupdate, blank-tolerant), NEW orthogonal update chip (behind→"vX available", in-flight outranks; per-row withoutUpdateState keeps the shared classifyBp spine untouched), archives storage-unconfigured as a DISTINCT amber state matched on the verbatim router.ex :not_configured copy (reviewer verified the string at router.ex:6401), --destructive→--danger in fleet-url.failed. 492/492 + 48/48.
- **gr-p3-instance-workspace** → `loop-epic/d-02-d-03-instance-workspace-v4-header-c-2` — GR24 D-02+D-03: two-axis compound pill header (statusPill consumed, GR25 held), mono address + copy, suspended box sheds the dead Open Studio, bp CLI disclosure surviving SSE repaints (instanceCliOpen), lifecycle row → v4 CLI card with the SERVER-OWNED pause gap sentence + typed-confirm Decommission…, Overview composed (verify card w/ verdict subtitle → updates → Sites; Identity/Runtime/Platform/Activity card rail with real S6 fields), panel-overview got its FIRST smoke EXPECTATIONS (GR30). Zero structural pin moves. 491/491 + 47/47.
- **gr-p3-timeline-grammar** → `loop-epic/d-04-timeline-coalesceentries-tlv-coales-3` — D-04: pure coalesceEntries between mergeTimeline and render — consecutive same-key folds, PARAMETERIZED key (tlvCoalesceKey type+actor / tlvCoalesceKeyByTarget for I-01; mergeTimeline now carries audit target), worst-verdict stated outright ("all reporting health: down" / "k of N"), honest cadence from real stamps, group identity anchored on the OLDEST member so SSE prepends grow open groups, worst-member badge tone, tlv-coalesce CSS family. 17 new tests incl. total-over-junk. 496/496 + 47/47.
- **gr-p3-webhooks** → `loop-epic/d-05-webhooks-tab-in-v4-crud-test-send-d-4` — D-05: "Recent deliveries" card (mono event id + toned "200 OK"/"HTTP 500" pill + attempts·latency·when + Replay), replay toast names the REAL proxied delivery (reviewer verified the r.data.data.delivery envelope against BOTH router.ex `data: decode_instance_body` and the instance's `json(conn, %{delivery: …})`), auto-disabled banner count-free + card streak-count suppressed while it shows. COPY-LAW BEND flagged to lead: the designed per-endpoint "Send test" has NO backend endpoint — bent to the real Replay, not faked. 485/485 + 47/47.
- **gr-p3-usage-metrics** → `loop-epic/d-06-d-07-usage-metrics-in-v4-13-honest--5` — D-06 confirmed already-states-complete (13 meters, bars+sparklines, no arcs); D-07 added dashed Not-yet-metered stubs (req/s, p95, API requests) for live/stale only, GR28 warmup fiction pinned OUT by unit+smoke, first metrics EXPECTATIONS ×3 (GR30), mountMetricsTab defensive re-acquire. fleetStrip*+sparklineSvg byte-untouched (git-proven). 484/484 + 49/49.
- **gr-p3-site-detail** → `loop-epic/e-02-site-detail-in-v4-deploy-ladder-tri-6` — E-02: one-card hairline deploy ladder (mono ref · dep-pill · env · trigger · duration · when), GR27 trigger-only provenance (reviewer verified `@triggers ~w(manual content-auto)` in registry/deployment.ex — the impossible "GitHub push"/"CLI" re-maps died), pure deployDuration (two server stamps, in-flight→null), shared deployFailHtml (red box + danger dot, blocked stays amber, snap), domains rungs on site detail via loadSiteDomains vs GET /v1/sites/:id/domain-status with the NEW `proxied` settled role (fixes CF poll-forever), .vf-chip→.dom-* component restyle (instance rail consumes unchanged), mono repo-name GitHub button, --accent RETIRED end-to-end (repo grep = 0, coherence pair repointed). 491/491 + 47/47 + emit 19-in-sync + design/check PASS.

Cross-slice: full sequential OC9 train verified END-TO-END on `wave-p3-integration-test` (5cac4ffed + all seven in train order). The union driver alone is NOT enough at this width — with 4+ same-anchor tail appends it interleaves scenario bodies, not just eats closers. Proven recipe on the branch: (1) union-merge app.js/app.css (safe — disjoint mid-file regions, only the hook tail seam needs its closers back); (2) for __app.test.mjs reconstruct = base + each branch's appended block in train order (pure tail-appends); (3) for scenarios.mjs/smoke.mjs take OURS then `patch --fuzz=3` the incoming branch's base-diff (entries are order-independent). Integrated state green: __app.test.mjs 534/534, smoke 55/55, css_check 0 errors (741 classes, 90 tokens — --accent gone), emit --check 19 in sync, design/check.mjs PASS.

Stalled/debt: guerrilla flapped 500/503 through the build session (task-c76ee13a44b9231c) — two builders could not stamp criterion 4 despite committed evidence; reviewer stamped on recovery (fleet-archives, usage-metrics, site-detail) and normalized lapsed-claim lifecycles to in_progress. The GR23-GR31 charter amendment (3d4a478cd) was committed to the PRIMARY checkout's local main again — rescued by cherry-pick onto this branch (`loop-epic/gr-p3-charter-wave-log`); land it with the train. Instance-workspace's bp CLI disclosure click is statically+unit proven but never machine-driven (smoke shim is click-inert — same standing gap as every wire in this harness). Archives "How archives work" links the repo root (no archives doc page exists — honest but unspecific).

Next wave dispatch order (sequenced-rounds law): (1) merge round 1 sequentially — hygiene FIRST (broad app.css), then fleet-archives, instance-workspace, timeline-grammar, webhooks, usage-metrics, site-detail — per the three-part recipe above (or merge `wave-p3-integration-test` wholesale after sign-off; it holds the exact resolution); the lead closes each task's merge-gated criterion 5 on merge; (2) land `loop-epic/gr-p3-charter-wave-log` (GR23-GR31 + this entry); (3) round 2 `gr-p3-small-surfaces` (E-01 sites list + E-03 env editor + I-01 activity) — dispatch ONLY after timeline-grammar AND site-detail are on main (it regrows Activity on the merged coalesceEntries + builds on the rewritten site detail); (4) phase-3 close-out: accent LOOK-AT-IT pass per screen (the new ?accent= axis), full-matrix shots, live proof; then phase 4 (Settings cluster G-01..G-06 as its own design-attentive wave, GR23).

### Wave 2026-07-19 (4) — phase 4 round 1 (THE SETTINGS WAVE) built + reviewed, grade A-

Round 1 (2/2 slices green, reviewed; one hardening fix; Paper `cloud-gui-remake-wave-2026-07-19-p4` holds the debrief). Charter GR32–GR38 ride PR #4277 (`loop-epic/gr-p4-charter-settings`, open+mergeable) — this wave's law lives there until it lands.

- **gr-p4-hygiene** → `loop-epic/hygiene-first-gr29-retirement-finished-3-0` (no fixes needed) — GR29 cloudChrome retirement finished ATOMICALLY in three places (tokens.json 25→14 keys, validate.mjs CC_HEX_ROLES 22→13 + dangling backdrop/github checks dropped, emit.mjs already 14 — reviewer re-proved 0 consumers of all 11 retired roles repo-wide and 13+line-rgb lockstep across all three lists; `node design/validate.mjs` now sits in the slice gate, closing the efaa37478 revert hole). GR37 dark `--btn-bg`/`--btn-fg` → `var(--primary)`/`var(--primary-fg)` — identity-aware CTAs on all 5 dark identities (reviewer verified the on-primary inversion: dark primaries 53–77% L paired with same-hue 8% L fg; E5 holds across all 10 states); the required exemptions.json 35→33 ratchet drop is a declared same-diff deviation, correct by construction. `.set-*` anatomy library landed defined-unemitted tokens-only (12 rules; grep-proven unemitted in app.js). Last tracked `.orig` gone. `me()` role seam + auditDenied denied-flag pattern documented. `operatorVisible` nested-path fix verified against router.ex me/2 (flag IS under `user`; `meCache = r.data` holds the envelope — the flat read was a real prod false-negative) with a flat-shape regression assert. As-run at review: 544/544 app tests, 58/58 smoke, css_check 0 errors (748 classes/516 pairs), emit 19/19, design/check PASS (270 AA).
- **gr-p4-deliveries-route** → `loop-epic/get-v1-notifications-deliveries-the-wave-1-r` — GR35: GET /v1/notifications/deliveries admin-gated, team-scoped, newest-first (desc inserted_at + desc id tiebreak), `delivery_json/1` mirrors audit_json/1, list_deliveries/2 UNCHANGED, diff exactly the two sanctioned files. Tests protective (401/member-403/empty/newest-first-full-fields/limit/cross-team no-leak). Reviewer verified no credential leak: chat rows record `recipient=type` (never webhook URLs); last_error is `"http NNN"`/inspect of transport reasons. Review fix on -r: `?limit` hard-capped at 200 in the ROUTER (list_audit_events caps in the context; list_deliveries rides unchanged per brief, so the router owns the clamp) + a 205-row protective test proving the cap. Gate re-run green: 14 tests, 0 failures. **Merge waits on the Elixir Test gate; first PR in the train, decoupled from the SPA train.**

Cross-slice: file sets fully disjoint (design/JS/CSS vs Elixir router+test) — no seam. The two slices are the two halves of the round-2 contract: `.set-*` primitives + the delivery-log route that G-04 renders.

Ledger audit: CLEAN, zero fixes — both builders stamped honest evidence mid-claim, left lifecycles in_progress with only the merge-gated criterion open; the 5 round-2 tasks sit open/unclaimed with correct paper links; epic wave_status was live throughout.

Next wave dispatch order (sequenced-rounds law): (1) merge round 1 — `gr-p4-deliveries-route-…-1-r` as its own PR once the Elixir Test gate is green (never blocks the SPA train); `gr-p4-hygiene` merges FIRST in the OC9 SPA train (broad app.css + design/); the lead closes each task's merge-gated criterion on merge, and per GR37 diffs design/tokens.json against origin/main immediately before any union-integration (the wave-3 union DROPPED the 11-key retirement once already); (2) land PR #4277 (GR32–GR38) and `loop-epic/gr-p4-charter-wave-log` (this entry); (3) round 2 — dispatch ALL FIVE page slices in parallel AFTER hygiene is on main (they emit `.set-*` classes whose rules land with hygiene): gr-p4-billing (G-01, reference composition), gr-p4-providers-matrix (G-02+G-03), gr-p4-notifications (G-04 — wants deliveries-route merged for live truth but renders on fixtures + honest degrade regardless), gr-p4-tokens (G-05), gr-p4-members-env (G-06 + #settings/env); their tails collide on the OC9 seams → sequential merge train per the wave-3 three-part recipe; (4) phase-4 close-out rides that round's Review: accent LOOK-AT-IT over the six settings pages (post-hygiene ?accent=, iris first), GR38 alias census report (expect ZERO named retirements — the honest residual is the 9-name census with live consumer counts; "10-name" was a stray error, corrected by GR43), live proof re-run over settings.

### Wave 2026-07-19 (5) — phase 5 round 1 (THE FINISH LINE) built + reviewed, grade A-

Round 1 (3/3 slices green, reviewed, fixed in place; Paper `cloud-gui-remake-wave-2026-07-19-p5` holds the debrief):

- **gr-p5-operator-routes** → `loop-epic/session-gated-v1-operator-seam-turns-the-0-r` — GR39: `Auth.require_platform_operator/2` fail-closed off the ONE allowlist (`platform_admin_emails/0`, same expression as /v1/me:1018), six thin session-gated proxies (autoupdate trio + fleet + deliveries + warm-pool), NEW `list_fleet_deliveries/1` with the load-bearing `event=="fleet_digest"` filter (nil-team identity emails proven excluded by the no-leak test), ?limit router-clamped ≤200 (parse_int already rejects ≤0). require_worker routes byte-untouched; 42 existing tests unmodified. **Review fix on -r**: the six routes + an `operator` legend entry added to the router's hand-maintained moduledoc route table — `router_moduledoc_table_test.exs` parses both and FAILS on mismatch (proven red pre-fix), so the builder's branch would have red the Elixir Test gate on CI. Gate 53/0 incl. the table test. **Merge waits on Elixir Test CI.**
- **gr-p5-grammar-pass** → `loop-epic/confirm-modal-grammar-unified-danger-no--1` (no fixes needed) — GR41 grammar half: danger-no-echo third tier (btn-danger, armed from the start, no typed echo) + trusted rich-body slot ADDITIVE on confirmModalInit/Html; both rollback confirms folded onto the shared modal with decision-25 inline failure (`ctl.fail` via setText — injection-proof) + terminal/transient recovery split (rollbackRefusalTerminal / siteRollbackRefusalTerminal, unknown codes deliberately retryable); bare-string dead toasts fixed + `toastShape` coercion; styleguide §16 rebuilt as the six modal families with the danger inline-failure state demoed. Zero stale `rollback-go`/`*ConfirmHtml` references (grep-proven), zero remaining bare-string toast calls. 584/584 app tests, css_check 0 errors, 516 pairs unchanged (`.cm-body b` = --text on the existing modal surface — no new pairing, correct per GR33 contrast law).
- **gr-p5-flotilla-closers** → `loop-epic/webhook-test-send-api-leg-ops-closers-sh-2-r` — GR45 api leg: POST /v1/webhooks/:dataset/:id/test-send, source_kind "test" with NULL endpoint_id as the safety crux (mark_delivered/mark_giveup no-op streak accounting on nil — a failing test can never auto-disable a real endpoint), single-shot `deliver_test/3` sharing `record_single_attempt` with replay, PayloadRebuild :gone clause ahead of the catch-all (nil event_id would crash the sweeper), capabilities `webhook.test-send` entry; 127/0 api webhook tests, mix format clean. GR46 closers: tenancy.md two-axis role paragraph (8298/8300B — 2 bytes headroom, fragile), email-fleet CLOSED as decision (16 plain-text kinds), branch exhaust executed (0 gr-w2/w3 remotes remain, wave-p4-integration preserved). **Review fix on -r**: shoot.sh's ACCENT param was appended AFTER the #deep-link fragment — accent landed INSIDE the hash, so every accent shot of a deep-linked scenario silently rendered the WRONG page (hash degraded to #overview) in the WRONG colors (mock.js never saw ?accent=); proven visually pre-fix (iris shot = evergreen Overview) and post-fix (Billing in true iris); param now precedes the fragment. **api PR reds OpenAPI drift until CI regenerates the manifest (cannot regen locally, OOM) — regen via the CI artifact.**

Cross-slice: file sets fully disjoint (cloud Elixir / cloud static SPA / api+tooling+docs) — no seam. Round 2's consumers get both halves they need: the operator routes AND the danger-no-echo tier are on their branches.

Ledger audit: one fix — gr-p5-operator-routes sat `open` on a lapsed claim despite 4/5 criteria honestly stamped; normalized to in_progress. grammar-pass + flotilla-closers were textbook (honest mid-claim stamps, merge-gated criterion open for the lead). Absorbed backlog: email-fleet-mapping + wave-exhaust closed with evidence; shoot-matrix-budget + role-vocabulary honestly in_progress until merge. The 5 round≥2 tasks sit open/unclaimed. The p4 held claims (gr-p4-notifications/tokens) were closed 6/6 at Decide, per the wish.

Stalled/debt: the GR39-GR46 amendment (42b31b4bd) was committed to the PRIMARY checkout's local main AGAIN (the standing epic-cycle trap) — rescued by cherry-pick onto this branch (`loop-epic/gr-p5-charter-wave-log`); land it with the train. Local main also strands 4 FOREIGN charter commits (tlv/pds/spd/axi epics, 598de010d lineage) — steward must rescue those + reset primary main to origin/main. tenancy.md at 2-byte budget headroom will bust on the next word — next editor trims first.

Next wave dispatch order (sequenced-rounds law): (1) merge round 1 — `gr-p5-operator-routes-…-0-r` and the flotilla api leg as their own PRs once the Elixir Test gate is green (api leg ALSO needs the OpenAPI manifest regenerated via CI artifact); `gr-p5-grammar-pass` merges FIRST among SPA slices (it owns the confirm grammar every later slice consumes); flotilla's shoot.sh/tenancy/docs commits ride normal gates; the lead closes each task's merge-gated criterion on merge. (2) Land `loop-epic/gr-p5-charter-wave-log` (GR39-GR46 + this entry). (3) Round 2 — dispatch `gr-p5-operator-console` ONLY after operator-routes AND grammar-pass are on main; `gr-p5-honesty-batch-1` after operator-routes merges (router regions freed). (4) Round 3 — `gr-p5-account-2fa` after operator-console; `gr-p5-honesty-batch-2` after honesty-batch-1. (5) Round 4 — `gr-p5-spa-finishers` after account-2fa + both honesty batches (deletions + wire-ups LAST). (6) Close-out rides that round's Review: accent LOOK-AT-IT over the six settings pages via the FIXED shoot.sh (iris first — now actually reaching deep-linked pages), GR43 census closing report (live re-count), live proof on barkpark.cloud, GR46 stamp-manifest execution, every remaining epic child closed-with-evidence or re-parented — then the epic task itself closes.

### Wave 2026-07-20 (seal r3) — the done-set audit: the seal's own gate learns to parse its artifact

**Verdict: SEAL CLEAN. Material failures 0. S3 genuine-bypass cohort 0 of 7.** Coverage 35 of 56 done children (62.5%). Slice `gr-p5r7-doneset-audit`, ledger-and-`origin/main`-reads only, zero code touched.

**The rules were frozen before any evidence was read.** GR112's material-failure definition, its 0 / 1–2 / ≥3-or-any-S3 threshold and the successor-not-reopen invariant were written to disk at 12:10:33, before the roster query ran and before a single child's evidence was opened. This is the property that makes the outcome bounded rather than negotiable: a rule re-derived after seeing a failure is not a rule. Independent corroboration that nothing was bent to fit — a mechanical re-stratification computed only from `claim.closed_at`/`closed_by`/criteria reproduced GR111's S1–S5 = **10/3/7/3/33 = 56 exactly**.

**The question asked, which is not the question GR46 or GR101 asked.** GR46 verified citation *existence*; GR101 verified citation *authenticity* and the bypass *mechanism* ("code real, ledger sloppy… it protects an audit trail, it does not catch liars"). Neither ever asked **whether the cited commit does what the criterion claims**. That, and only that, was this audit's question.

- **Roster** — `curl -G /v1/data/query/production/task --data-urlencode 'filter[parent_id]=task-47bc4168392dec17' --data-urlencode 'limit=500'` → 130 rows, **all** under one parent (so the bare-`?parent_id=` 500-row/34-parent trap is excluded), `Counter({'open': 69, 'done': 56, 'in_progress': 5})`. `lifecycle_status` only; `claim.closed_at` never used as a done predicate (GR92).
- **S3 genuine bypass (7/7 clean), audited first and deepest** — the cohort where a single failure alone would have forced SEAL DEGRADED. Behavioural claims were verified by reading function *bodies*, not grep counts: `fleetUpdateChip` returns `null` absent `update_state`/`autoupdate_triggered_at` (backend-true-only is literally true); `deployTriggerLabel` is `manual→Manual`, `content-auto→Content update`, with no actor slot; `USAGE_METERS` is 13-for-13 in the exact claimed order; `color.cloudChrome` is 14 roles + `_note` with all 11 dead keys retired and `CC_HEX_ROLES` at 13; `--accent` genuinely gone (`var(--accent)` = 0 *and* `--accent:` = 0).
- **S1 (10/10)** — every "PR merged" is unmet by design and every one's work is demonstrably on main. `favicon.ico` is byte-exact 15086; `KNOWN_GAPS` shrank to exactly **1** (`bp-lc-` survivor); all six class families have authored rules **and sit below `END GENERATED: tokens` (line 232)**, so #4733's idempotency fix holds. Note: several cited SHAs (`4312db64a`, `5f95b436c`, `8ec8961a2`, `3f1f81788`, `0c43518b8`) exist but are **not** ancestors of `origin/main` — they are pre-squash branch tips, so **ancestry is the wrong test**; each was verified instead by its user-visible claim being true on main today.
- **S2 (3/3)** — supersession substance verified, not merely the presence of a `GRnn` tag: `--space-1/7/8` and `--primary-hover` all absent, `ERRORS.forbidden` present verbatim.
- **`gr-p5r4-shoot-seam`** — `gh pr view 4510` → "Could not resolve to a PullRequest"; 4510 is an **issue mirror**, so citation was impossible and **the gate was re-run**: 20 ok / 20 PNGs (asserted with `ls -1 "$OUT"/*.png | wc -l`, not the `>> Done` banner) / 20 distinct sha256 / 0 byte-identical pairs, on a non-default port to avoid the concurrent reshoot slice, with progress observed **climbing** 8→11→15→20.
- **S5 sample (12/12)** — `random.Random('task-47bc4168392dec17').sample(sorted(S5), 12)` over the sorted 33-member population, drawn before any of its evidence was read, so it is exactly reproducible. `gr-w1-fonts` verified byte-exact (13532+13280+14212+40644 = **81668**, all four carrying `wOF2` magic).

**Four apparent failures were run down and all proved benign** — an audit that manufactures false findings fails the same way as one that misses real ones. The `Marketing|Blank` and `reveal_site_env` hits were *comments documenting the retirements* (and the real claim, zero **route** callers, was verified independently against `router.ex`); the two `<circle>` hits were an eye icon and a sparkline single-point dot, not arc gauges; and one "failure" was **my own regex** spanning past the `METRIC_SPECS` array terminator. A wrong path guess (`cloud/priv/static/design/tokens.json` vs the real `design/tokens.json`) was resolved with `git ls-tree` rather than reported as a missing artifact.

**GR80 re-proven a fifth time.** `gr-p4-hygiene` cites `--btn-bg`/`--btn-fg` at "`:root` light 251-252"; those lines today hold `font-family`/`font-size`, while the real definitions sit at 285-286 (dark pair at 372-373). A line-number-anchored audit would have manufactured a false failure **on a claim that is true**. Every check here anchors on selectors and identifiers.

**Honest residue, stated numerically and not glossed: 21 of 56 done children remain sealed on evidence nobody read** — all in S5, the strongest-attribution stratum. Coverage 62.5%; observed material-failure rate on the audited 35 is 0/35 and the weakest cohort was 7/7 clean, which is the basis for calling the residue low-risk — but it is 21 children read by nobody, and the seal rests on that being visible rather than absent. Forwarding address: **`gr-p5r7-doneset-residue-21`** (published, open, under the epic). Zero mid-wave reopens, zero wave expansion.

---

## Wave 2026-07-20 (seal r4) — round 8: the seal predicate, frozen and inverted-then-repaired

Paper: `cloud-gui-remake-wave-2026-07-20-seal-r4`. Epic task `task-47bc4168392dec17`.
Charter path correction, binding on every downstream phase: this epic's law is **THIS file**
(`bp-cloud-gui-remake-charter.md`). `.claude/workflows/bp-cloud-epic-charter.md` is the ROTATING
epic-cycle slot and currently holds the **Studio Space-Priority Desk** epic — writing this epic's
rulings there would corrupt a live foreign charter. The lead brief named the rotating slot and the
epic id `cloud-gui-remake-epic` (which does not resolve); both were followed to the evidence instead.

- **GR115 — the second dead rule is real, is the same class as GR109, and is FOLDED, not forwarded.**
  `app.css:2409` (`max-height:40vh`) and `:2413` (`font-size:13px`) name both console families in one
  declaration list, inside the 720px block. `.new-console-*`'s base sits at `:2387` — BEFORE the block,
  so it applies. `.bp-console-*`'s bases sit at `:2494`/`:2518` — AFTER, at identical (0,0,1,0)
  specificity, so both declarations are discarded. **The control is decisive: one declaration, both
  families, opposite computed outcomes, varying only source position** — 320px/13px vs 260px/12px,
  measured in a real browser at 700x800, mutation-flipped and restored. Severity splits and the filed
  task was wrong in BOTH directions: the `max-height` half is *conditional* (harmful only below ~650px
  viewport height, and only at >=14 console lines — the normal production state, since narration is
  server-capped at 300 lines), while the `font-size` half is *unconditional* and falsifies the authored
  comment at `:2404-2406` — "no theater text falls below 13px" — on every screen <=720px. A written
  legibility contract that is false is not cosmetic. Same file, same region, same fix shape as GR109, so
  a separate slice would collide on the cascade: it is folded into `gr-p5r7-tablet-overflow`.

- **GR116 — GR108's charter-recorded ROOT CAUSE IS WRONG, and the fix it implies fails.**
  GR108 (line 144) says the 768px block "never tightens `.topbar`" and calls it "one-line-fixable".
  Measured: **`.topbar`'s right edge is 753 — inside the client area. It does not overflow.** Its
  *children* escape to 775-780 because they are flex items at the default `min-width:auto`, floored at
  min-content: content needs ~416px, only 373.92px is available. The charter's implied fix was built
  and swept — **candidate B (raise the 720 `.topbar` padding/gap to 768) still overflows 14 of 16
  checks**; tighten+fold still fails 5/16. Worse, **the broken band reaches ~782, ABOVE the breakpoint**
  (769px still measures 775.22/776.92), so *no* `max-width:768px` rule can close it, and the band's
  upper edge moves with chip text and locale. The fix that works is breakpoint-free and two
  declarations — `.topbar-right > * { min-width: 0 }` plus ellipsizing `.billing-chip` — measured
  **0 of 44 overflowing** across 721/750/768/769/775/780/785/800/900/1024/1440 x 2 themes x 2 scenarios.
  Its one cost is that the past-due billing chip ellipsizes in the 721-782 band; three cosmetic
  declarations in the existing 768 block buy the full 169.78px back. **The two halves ship together**:
  the unconditional pair is correctness, the in-block trio prevents trading a scrollbar for a truncated
  money message. `!important` remains forbidden (GR110); `.set-matrix` stays untouched.

- **GR117 — GR109 is HALF dead, not dead, and the distinction changes the fix.**
  `flex-direction: column` **survives** (no later rule contests it) — the row does stack. Only
  `align-items` is killed, so the row stacks and stays *centred* (`actsLeft=441.28`). The symptom is
  centring, never failure-to-stack. Specificity repair `.attention-card .attention-row { align-items:
  flex-start }` at (0,0,2,0) snaps acts to 275, matching GR65's intent, with no `!important`. It carries
  one coupling worth naming: it assumes `.attention-row` is always inside `.attention-card`, verified on
  `overview-past-due` only — if any surface renders the row outside that card the repair silently does
  nothing there, which is the very dead-code class it fixes. A reorder-based fix avoids the coupling; the
  builder picks, and proves whichever it picks by measurement.

- **GR118 — THE FROZEN PREDICATE WAS EXACTLY INVERTED ON ITS OWN CROWN DEFECT. This is the round's
  most important finding.** The draft asserted GR108 as "does a `.topbar` rule exist inside the 768
  block" — the charter's *theory of the cause* rather than the *symptom*. Dry-run at Decide, both
  directions, before freezing: against the **correct** fix (0/44 overflow) it printed **DEFECT**; against
  the **broken** fix (14/16 still overflowing) it printed **CLEAN**. Its GR109 assertion likewise reported
  DEFECT against the recommended specificity repair, because a correct fix legitimately leaves the later
  base rule reading `align-items:center`. The sharpest attack on this wave's direction — *"you will have
  automated a false green, and it will look more authoritative than the prose it replaced"* — was not
  hypothetical. It was already latent in the instrument built to prevent it, and only mutation-testing the
  predicate against a real candidate fix exposed it. **Ruling: a source regex tests a story about the
  pixels; only a browser tests the pixels.** Clause (b) now shells out to a committed browser guard and
  asserts only that it exists, runs, and exits 0. **A missing guard is NO SEAL, never a pass** — unmeasured
  is not cleared. This is the epic's signature sin (a gate that cannot parse the artifact it certifies)
  caught one step before it was committed as law.

- **GR119 — the predicate is FROZEN AND COMMITTED at Decide**, at
  `cloud/priv/static/__preview__/seal-predicate.mjs`, before any builder flew. Mutation-proven in five
  directions from green, each a real exit code, restoring green after: orphan a child -> `UNNAMED
  RESIDUE: 1`, exit 1; un-land a defect commit -> `not an ancestor of origin/main`, exit 1; vanish a
  hardcoded human gate -> exit 1; guard runs and FAILS -> exit 1; guard ABSENT -> exit 1. Live run today
  is **NO SEAL, exit 1** — 69 unnamed rows, 3 unlanded defects — which is the correct and honest answer at
  this instant and proves the predicate falsifiable by construction. Three draft defects were fixed
  before freezing: the roster is read at run time (it drifted 132->133 *during* this wave), the scope
  sentence counts gates from `PERMANENT_HUMAN_GATES` rather than roster membership (the draft printed
  "1 permanent human gates" — undercounting by excluding the very billing gate whose invisibility is the
  point, and ungrammatically), and the sweep envelope is stated numerically.

- **GR120 — GR112 does NOT conflict with a binary exit code, and needs no new ruling.** The apparent
  nine-laws contradiction resolves mechanically rather than by fiat: GR112's `SEAL DEGRADED` branch fires
  only at ">=3 material failures, OR any 1 in S3", and this charter at line 458 already records
  **`Verdict: SEAL CLEAN. Material failures 0. S3 genuine-bypass cohort 0 of 7.`** The branch condition
  evaluated to 0 and returned the clean branch, so the degraded path never activates. Decide does not
  choose which law supersedes; it observes that GR112's own threshold already answered. Round-4's
  two-clause form (line 374) — "zero UNNAMED residue and zero known user-facing defect" — is the seal's
  substantive law; GR112 is the separate evidence-integrity gate it already froze; GR61 and the round-2/3
  single-clause forms are SUPERSEDED as earlier, narrower articulations of the same intent.

- **GR121 — there are THREE permanent human gates and one is INVISIBLE to every roster query.**
  `cloud-console-billing-live-gate`'s parent is `cloud-console-goal`, NOT this epic — proven both
  directions in one breath: the epic-scoped query returns 133 ids with `billing gate in roster: False`,
  while `filter[_id]` resolves it `open`. No `filter[parent_id]` query rooted here can ever reach it, so
  it is carried by **hardcoded doc_id**, and inheritance is not a forwarding address. The bucket also
  **tripwires on disappearance**: a gate that silently vanishes is a gate that stopped being disclosed,
  and that is NO SEAL rather than a clean sheet. `gr-ops-platform-admin-emails` and
  `gr-backlog-qr-live-scan-proof` join it. **The crown is DARK**: `PLATFORM_ADMIN_EMAILS` is unset on
  prod, so the operator console — this epic's headline feature — shipped fully built and unreachable.
  **"Seal" here means CODE seal. It has never meant "this feature is live for any human," and the
  predicate's green says so in its own words.**

- **GR122 — E10 does NOT subsume the brace tripwire; the two are near-DISJOINT, and deleting the
  tripwire would open a coverage gap at the round meant to close gaps.** Proven by mutation, both
  directions: a bare unclosed `{` and a bare stray `}` (no comment involved) both leave `__css_check.mjs`
  at **exit 0, "0 error(s)"** while `__app.test.mjs`'s brace-depth walk goes RED; an orphan `*/` inverts
  it — E10 reds correctly at `app.css:4519` while the brace walk stays green. E10 (`orphanCommentErrors`,
  `__css_check.mjs:356-405`) is a comment-nesting state machine that **never inspects a brace character**;
  its function body contains zero references to `{` or `}`. It covers 1 of the 3 classes
  `gr-backlog-css-brace-detector` names, and no fixture proving it reds on the other two exists anywhere
  (`__css_check.fixture.css` is E9-only). GR75 itself only ever scoped E10 to comment terminators — the
  task's acceptance criteria overreached what the charter chartered. **The interim tripwire at
  `__app.test.mjs:633-656` STAYS.** The task is re-scoped, not closed.

- **GR123 — the residue-21 tripwire DID NOT FIRE; NAME-AND-FORWARD holds.** Four of the 21 were
  spot-checked against `origin/main` on their exact user-visible claim, anchored on function names not
  line numbers (GR80), and **4/4 passed**: `webhookBannerHtml` contains no `consecutive_failures` token;
  `readOnlyPlanCardHtml` emits zero `<button>` elements and `renderBillingManage(false)` short-circuits to
  the honest copy; `operatorVisible` is `!!(me && me.user && me.user.platform_operator === true)` —
  fail-closed by construction; `Auth.require_platform_operator/2` is a literal 401-then-403 shape. The
  derivation independently reproduced GR111's S1=10/S5=33 split exactly. Observed rate stays **0 material
  failures across 39 checks**. The audit does not become seal-blocking. Criteria 2-3 forward to the
  successor. **The 21, enumerated BY NAME — because "the 33-member S5 minus these 12" is a subtraction a
  cold reader cannot act on, and that is precisely what "zero UNNAMED residue" forbids:**
  `gr-backlog-email-fleet-mapping`, `gr-backlog-role-vocabulary`, `gr-backlog-shoot-matrix-budget`,
  `gr-backlog-wave-exhaust`, `gr-p2-home-triage`, `gr-p2-launch-theater`, `gr-p3-hygiene-guard`,
  `gr-p3-timeline-grammar`, `gr-p3-webhooks`, `gr-p4-billing`, `gr-p4-members-env`,
  `gr-p5-honesty-batch-1`, `gr-p5-operator-routes`, `gr-w1-charter-archive-pr`,
  `gr-w1-cloudchrome-bridge`, `gr-w1-css-check-detector`, `gr-w1-operator-me-flag`, `gr-w1-shell`,
  `gr-w1-styleguide-port`, `gr-w1-token-ramps`, `task-7836903b7ea83111`. One wrinkle stated rather than
  smoothed: `gr-backlog-email-fleet-mapping` is structurally S5 (all criteria met, clean CAS) yet the
  audit's criterion-6 evidence mentions handling it — a bonus look outside its declared bookkeeping, not a
  stratification error.

- **GR124 — cssom-parity's non-wiring is an EXISTING ruling, not a new gap; do not re-litigate it.**
  It is GREEN on the tip (1200/1200 rules, 1169/1169 selectors, **MISSES 0**, run twice) and referenced by
  zero workflow or Makefile — but GR93(b) already ruled it "ships UNWIRED on purpose… wiring is the
  successor's first task… it never gates the seal." That stands. Wiring cost is captured for the successor
  so it need not be re-derived: **no new CI trigger is needed** (`cloud/priv/static/app.css` is already a
  doc-gates trigger path), ~15-30s added runtime, and one unverified assumption — that hosted runners ship
  an ambient Chrome, where `js-tests.yml` instead installs a pinned chromium. **It is also structurally
  blind to the GR109/GR115 class**: it collects `selectorText` and asks whether a selector REACHED the
  CSSOM. A cascade-dead rule is present in the CSSOM — it just loses. It was GREEN with GR115 live.
  `__app.test.mjs` contains **zero** `getComputedStyle` calls and cannot assert a computed value either.
  So the dead-rule class had NO guard coverage from any instrument in this epic; the overflow guard closes
  that, which is why it is a measurement and not a regex.

- **GR125 — evidence hygiene proven live this round, carried as law.** (a) **Port squatting is a false
  green**: a preview server from a *foreign worktree* served `187302 B` — the primary checkout's
  `origin/main` bytes — while the probe's own tree held `189086 B`, making a patched run print output
  byte-identical to baseline. With 20 live worktrees on this checkout, any `serve.mjs`-based gate needs a
  served-bytes-vs-disk-bytes assertion; it was mutation-proven (squat the port -> `!! STALE SERVER on
  :4199`). (b) **Chrome memory-caches `app.css` across same-URL navigations** — without
  `Network.setCacheDisabled` a mutation phase measures the ORIGINAL stylesheet. (c) `.new-console-body`
  and `.bp-console-body` are **byte-identical declaration blocks**, so a plain string `.replace()` patches
  the wrong twin and reports a false "did not flip" — mutations must be selector-anchored inside braces.
  (d) **`design/emit.mjs --write` silently overwrites everything between `BEGIN/END GENERATED: tokens`
  (`app.css:45-232`) with no diff and no log line, and `design/check.mjs` prints PASS and exits 0 over the
  deletion** — re-proven this round by injecting a sentinel inside the marker, running `--write`, and
  watching check.mjs go green on the loss. This already ate 33 hand-written `.bp-lc-*` lines in
  `1d928b3bf`. `__css_check.mjs`'s E2 catches it only if the lost class is referenced by live markup, so an
  orphaned selector's deletion is invisible to BOTH gates. **Fence: author every rule strictly below line
  232, and never run `emit.mjs --write` in a slice that changes no token.**

- **GR126 — the ledger is LIVE and MUTATED under a reader mid-seal.** A `tmp-reparent-probe` row was
  present in one enumeration and gone from three samples minutes later; a concurrent session was
  rehearsing the re-parent. Roster drifted 132->133 during this wave (`gr-p5r8-bpconsole-dead-rule`, filed
  11:42:35). **A seal verdict is valid only at an instant.** The predicate must be run LAST, by the same
  agent that files the successor, in one atomic pass, with its roster count and ISO timestamp recorded
  verbatim — which is also why residue-21's enumeration is FOLDED into the successor slice rather than
  dispatched beside it: two builders writing the ledger concurrently can green a predicate over a
  half-moved roster.

- **GR127 — #4834 is BYTE-EMPTY and the tip's cloud gates never ran on the tip.** `git diff --stat
  24fae1b9f 8fbef852c` is empty: only 4 of round 7's 5 PRs carry unique diffs. `gh run list` shows
  `8fbef852c` ran **only** `elixir`; `console-harness`, `cloud` and `Deploy` last succeeded on `24fae1b9f`.
  This is benign *because* the diff is empty — but **nobody may call it a tip green without that diff in
  hand**. All four harness gates were re-run directly at the tip and are genuinely green: `node --check`
  clean, `__app.test.mjs` **640/640**, `__css_check.mjs` 0 errors (1 demoted R3 gap), `smoke.mjs` all 86
  scenarios. `smoke.mjs` is confirmed unwired from CI, same posture as cssom-parity.

- **GR128 — the reshoot budget, measured rather than asserted.** 32 shots across two runs from a clean
  `git archive origin/main` export under real load (avg 16-41): **0 wedges, 0 watchdog firings, 32/32
  distinct hashes**, median 5.0s/shot (worst 6.0) — ~30-40% slower than GR67's 3.0-4.0s clean room. The
  real slice is 80 PNGs (4 scenarios x 5 accents x 2 themes x 2 widths), extrapolating to ~7min.
  **Budget 10 minutes; ABANDON at 20 minutes wall-clock with no climbing file count.** The reap watchdog
  (`shoot.sh:340-367`) caps any single wedged shot at 15s poll + 10s `REAP_BUDGET` = 25s, so even 8 wedges
  add only ~3.5min. **The brief's "25% transient-failure rate in an 8-shot spot check" could not be traced
  to any source** — the only documented figure is GR114's 1-of-4-*runs*, pre-dating the watchdog; a
  separate observation of 2 wedges in 8 shots today is the likely origin. It is carried as an unverified
  number, not as measured fact. GR114 still binds: "my run was clean is not evidence the risk is closed."

- **GR129 — the #4833 mock fix is REAL, proven by independent hash rather than by commit message.**
  `account-modal-dark-1440-iris` and `account-modal-2fa-badcode-dark-1440-iris` now hash `1cf3548c…` and
  `f7898562…` — distinct from each other and both distinct from the pre-fix shared
  `b3962224…`, with file sizes 309195 vs 337845. The reshoot rests on a sound primitive.

**The round-8 wave (3 build slices, 2 rounds).**
Round 1, file-disjoint, dispatching now: **`gr-p5r7-tablet-overflow`** (fable) owns `app.css`,
`__app.test.mjs` and the new `overflow-guard.mjs` — fixes GR116 at its cause, revives GR117, folds GR115,
and commits the browser guard clause (b) delegates to; **`gr-p5r7-reshoot-verify`** (opus) writes no
source and is explicitly NON-BLOCKING with ABANDON pre-authorized — it may not delay the seal in either
direction. Round 2, after tablet-overflow MERGES: **`gr-p5r5-successor-seal`** (fable) files the successor,
re-parents survivors, moves the billing gate by hardcoded name, labels all three human gates, enumerates
the 21, closes `gr-p5r7-doneset-residue-21`, and runs the frozen predicate LAST as one atomic act.

**The seal is the predicate's exit code, and NO SEAL is a fully acceptable, pre-committed outcome.**
Five rounds died of a prose verdict whose bar moved with the reader. This one cannot: the bar was written
to disk and mutation-proven before a builder flew, and the first thing that proof did was catch the
predicate blessing a broken fix. If it exits non-zero, the successor is the honest handoff and the epic
says so on the ledger.

### Wave 2026-07-20 — phase-5 seal round 8, round 1 built + reviewed, grade A−

**THE SEAL DID NOT LAND, AND THIS ENTRY DOES NOT PRETEND IT DID.** The frozen predicate was run
live at review (`2026-07-20T12:46:47.300Z`, live ledger, roster **139** children
`{in_progress:2, open:74, done:63}`) and returned **VERDICT: NO SEAL, real exit 1** — 74 live rows
with no forwarding address (clause a) and 3 defects registered `commit: null` (clause b). That is the
pre-committed acceptable outcome, reported as returned, not negotiated. Round 1 paid two of the three
named slices; the third is fenced by the sequenced-rounds law, not by a stall.

Round 1 (2/2 slices green, reviewed, fixed in place; Paper `cloud-gui-remake-wave-2026-07-20-seal-r4`
holds the debrief):

- **gr-p5r7-tablet-overflow** → `loop-epic/the-tablet-topbar-stops-overflowing-at-i-0-r` — GR108 fixed at
  its REAL cause with the breakpoint-free pair (`.topbar-right > * { min-width: 0 }` + a clipping
  `.billing-chip`), measured **0/44** across 721–1440 × 2 themes × 2 past-due scenarios; GR109 revived by
  REORDER (the tablet stack now sits after the `.attention-row` base — column/flex-start, acts left 275 ==
  main left 275 at 768, still a row at 900, no `!important`); GR115 folded by lifting the `.bp-console-*`
  bases above the theater 720 block (320px/13px/13px at 700×800, `is-collapsed` twin control re-verified).
  The cosmetic trio shipped WITH the correctness pair, so the past-due money message renders its full
  169.78px at 768 instead of clipping to ~154.61px. **`overflow-guard.mjs` is the wave's real deliverable**:
  a zero-dep CDP headless-Chrome guard that renders the real SPA through `serve.mjs`, sweeps 769/775/780/785
  ABOVE the breakpoint, asserts served-bytes == disk-bytes (it refused a squatted port serving foreign bytes,
  exit 1), and disables the network cache per GR125b. It is the instrument clause (b) delegates to, and the
  first one in this epic that can parse the artifact it certifies.
  Review re-proved the guard's failure power INDEPENDENTLY, three directions, standalone real exit codes:
  removing only `min-width: 0` → **exit 0**; removing only the chip's `overflow: hidden` → **exit 0**
  (a BROADER redundancy than the builder disclosed); removing the whole pair → **exit 1, 12 findings,
  failing at 769/775/780** — above the breakpoint, exactly the class no media-scoped fix can reach.
  `app.css` restored byte-identical after each. Two review fixes: the GR115 `is-collapsed` border control
  used `&&` (it only fired when BOTH readings were wrong — a control that could not fail, in the wave whose
  whole subject is controls that cannot fail) → `||`; and `.billing-chip`'s `text-overflow: ellipsis` is
  INERT on a flex container, so the 769–782 band CLIPS rather than ellipsizing — documented in place rather
  than sold as polish it does not deliver.
- **gr-p5r7-reshoot-verify** → **no branch, no PR, by design** (`cloud/.gitignore:29` ignores
  `__shots__/`; the ledger is the deliverable). 80/80 PNGs, **80 distinct sha256, zero duplicates** — the
  prior matrix's 20 byte-identical duplicates are gone, so the vacuous count check was replaced by one that
  can actually fail. The lying pair was re-proven distinct as the first act. Five accents opened and
  pixel-sampled (evergreen mint / ember terracotta / fjord pale-cyan / charple orchid / iris indigo-violet).
  Its builder nearly reported a defect that GR57 documents as deliberate, caught itself by reading the CSS,
  and retracted it on the ledger — the symmetric failure to dismissing harness output, named honestly.
  Two findings filed as published children: `gr-p5r7-ring-soft-accent-invariant` (unruled, not confirmed)
  and `gr-p5r7-badcode-shot-nondeterministic`.

**Deferred by the sequenced-rounds law, NOT stalled:** `gr-p5r5-successor-seal` (round 2) — it cannot run
before `gr-p5r7-tablet-overflow` merges, because clause (b) reads `origin/main`.

**Ledger fix — the seal's missing owner.** Running the predicate live exposed that **nothing in the ledger
owned filling `KNOWN_DEFECTS[].commit`**. All three rows are `commit: null` ("unlanded at freeze"), so clause
(b) is structurally unsatisfiable and a FLAWLESS `gr-p5r5-successor-seal` run would still return NO SEAL.
Filed as **`gr-p5r8-register-defect-commits`** (priority 0, published). This is not a freeze violation: the
freeze protects the BAR (clauses, thresholds, guard delegation); `commit` is the freeze's own designated
input. Everything else audited honest — both slices `in_progress` with per-criterion evidence stamped as
they worked, merge-gated criteria correctly left open for the lead, `gr-p5r8-bpconsole-dead-rule` already
self-disclosing "FOLDED INTO gr-p5r7-tablet-overflow", and the seal-predicate criterion honestly recording
that its clause-(a)/(c) run used the `--ledger` fixture channel while the three guard executions were real.

**Next wave dispatch order:** (1) merge `gr-p5r7-tablet-overflow` (`…-i-0-r`) and close its criterion 10;
(2) close `gr-p5r7-reshoot-verify` criterion 8 as *no PR by design*, NOT as abandoned; (3) **`gr-p5r8-register-defect-commits`
— before any successor work**; (4) then and only then `gr-p5r5-successor-seal`, running the predicate LAST
in its own claim. Skipping (3) burns the round-2 builder on a structurally impossible green.

---

## Wave 2026-07-20 — phase-5 seal round 9, DECIDE: the seal is a disclosure, not a rename

The epic has attempted to seal SIX times. Round 8 built the thing that ends that — an executable predicate,
frozen and committed BEFORE any builder flew. Round 9 executes it and takes the verdict without negotiation
and without building a seventh instrument. But **the exit code is not the deliverable.** The predicate can
only measure a mechanical property. A successor with no charter, no triage and no priorities passes clause
(a) identically to a great one. What survives this epic is not the exit code; it is whether the next person
can READ the ending. Eight verifiers ran against the round-8 plan. They confirmed the direction and
contradicted the brief in nine places. The corrections are law.

**GR130 — CITE MERGE SHAs, NEVER BRANCH SHAs. This epic's most expensive unforced error.**
`origin/main` is a **linear squash chain** — `git log --format=%p` shows a single parent for every commit —
so `git merge-base --is-ancestor <branch-head> origin/main` can **NEVER** pass and **always false-negatives**.
Control, run both ways on the same landed fix: PR #4909's branch head `e4bb4bfae` reads **NOT ancestor**
while its merge SHA `0261ace15` reads **IS ancestor**. Round 8's digest cited the MERGE sha for #4909 and the
BRANCH sha for #4832 and drew opposite conclusions from that choice alone — declaring four landed user-facing
fixes unlanded and calling it "the finding that most threatens a readable ending". It threatened nothing; it
was a measurement error. Correct test: `gh pr view <n> --json mergeCommit`, or `git log -S'<string>' origin/main`.
Root cause: **the charter records landing PLANS but never the merge SHA the landing produced** (`grep -c
'7a5aff656'` on this file returned 0). That omission is what let branch SHAs become the citation of record.
From here, a landing is recorded by its merge SHA, at landing time.

**GR131 — CLAUSE (a)'S IMPLEMENTATION, READ FOR THE FIRST TIME BY ANYONE. It is weaker than every ruling assumed.**
It reads exactly three fields from a task document: `_id`, `lifecycle_status`, `parent_id`. `close_reason`,
`acceptance_criteria`, `evidence`, `assignee`, `tags`, `priority` — **zero hits each**. There is no
forwarding-address field and no label field; "gate label" and "evidence-closure" exist only inside prose
output strings. A row passes if its status is anything other than `open`/`in_progress` (**including arbitrary
values** — a fixture with `lifecycle_status:'banana'` SEALS), **or** if it leaves the epic's direct children.
A permanent human gate is not a field-borne disposition — it is a hardcoded `_id` match against three literals,
so the charter's own repeated instruction to "label the human gates" has **zero mechanical effect**. Do it
anyway, as disclosure; never count it as satisfying anything. Consequence: **the 74 re-parents cannot produce
"a green that is still NO SEAL"** — no builder can be burned on an impossible clause-(a) green. The risk has
moved from mechanical to narrative.

**GR132 — `fwd` IS DEAD CODE IN LIVE MODE, AND THE BANNER WILL UNDER-REPORT THE TRIAGE.**
`children` is the epic's direct children; `forwarded` is the successor's. A task has ONE `parent_id`, so a row
**cannot be in both** — the moment it is re-parented it leaves `children` entirely and the `forwarded` branch
can only ever fire under `--ledger` fixtures. Clause (a) therefore passes by **ABSENCE, not by naming**, and
`--successor` has **zero effect on the live clause-(a) verdict**: a typo'd id and an omitted flag produce
identical output. Two things follow. First, **ruling 3's stated premise is REFUTED** — a row routed honestly to
another epic does NOT orphan and does NOT fail clause (a), so re-parenting everything under one successor buys
**zero mechanical safety**. It remains the right choice, but as a pure DISCLOSURE choice, made with open eyes.
Second, after a PERFECT triage the SEAL banner reads `Sealed N children: M evidence-closed, 0 forwarded by
name to <successor>`. **The `0 forwarded` is structural.** The terminal run MUST pass `--successor
cloud-console-hardening-epic` (without it the banner prints the literal word `null`), and the charter MUST
record the **roster delta and the per-row disposition census alongside** the verbatim stdout, because the
stdout alone cannot express what this epic did. Editing the banner is NOT the permitted edit and voids the wave.

**GR133 — ABSENCE OF A `VERDICT:` LINE IS A CRASH, NEVER A VERDICT.** Both `fetchRoster` calls are unwrapped, so
any transport failure throws before any output. A crash and a substantive NO SEAL **both exit 1**; the
discriminator is stdout — a crash produces **zero bytes and no `=== SEAL PREDICATE ===` banner**. Recording a
crash as NO SEAL would fabricate an ending. Capture stdout, stderr AND the exit code.

**GR134 — BUCKET (c) IS A FALSE-NO-SEAL HAZARD IN EXACTLY THE WINDOW THE RE-PARENT CREATES.** `fetchById` is
`try { … } catch { return null }`, so a gate that fails to resolve for ANY reason — one 429 from the shared
60/min write bucket, a transient 500, a blip — reports `resolved:false` and forces NO SEAL with clause (a)
perfectly clean. A throttled 74-row re-parent immediately followed by the atomic run sits in the worst window.
**Settle, confirm all three gates resolve with a standalone `filter[_id]` query, then run.** A bucket-(c)
failure with clause (a) clean is almost certainly mechanical and is the legitimate use of the one-repair rule.

**GR135 — THE WRONG CWD MANUFACTURES A FALSE NO SEAL.** `REPO` defaults to `process.cwd()`. From anywhere but
the repository root the predicate emits `guard … is NOT COMMITTED` three times and exits 1 **with a full
banner** — textually identical to a real clause-(b) failure, and invisible to the GR133 crash test. Run from
the repo root or pass `--repo`.

**GR136 — THE SUCCESSOR ID IS UNVALIDATED, SO DECIDE FILES THE SUCCESSOR ITSELF.** The predicate never checks
that the successor resolves: a typo yields `forwarded: 0 / orphans: 74` with no error, indistinguishable from
"the re-parent never ran". No successor existed anywhere (2000-row ledger scan, 1921-doc search index,
140-child roster, charter — all negative), and BOTH `gr-p5r3-successor-epic` and `gr-p5r5-successor-seal` sat
open at 0/7 and 0/11 with every evidence field empty. Round 9's Decide therefore **filed the successor itself**:
**`cloud-console-hardening-epic`**, published, top-level, carrying a six-band inheritance charter. The slug is
fixed HERE. `gr-p5r5-successor-seal` VERIFIES it; it must never re-file it.

**GR137 — THE FOUR SEAL-FINISHER DEFECTS LANDED. There is no false-done; there were four FALSE-OPENS.**
PR #4832 squash-merged as **`7a5aff656`** at 2026-07-20T10:58:44Z, and `git diff 7a5aff656 f992663b4 --
cloud/` is EMPTY for every defect file. All four are fixed on `origin/main`, proven by source inspection, not
ancestry: `index-icon-link` (`<link rel="icon">` at index.html:15, favicon.ico ships at 15,086 bytes, pinned at
`__app.test.mjs:1329`); `modal-survives-route` (GR105 `hashChangeEffects` at app.js:16097, keyed on
`legacyRoute` so `#launch` stays route-identical, four pinning tests); `invite-ico-danger-variant`
(`.invite-ico--danger` at app.css:3245, distinct `✕` glyph via `ICO_DEAD`); and `archives-doc-link` — **whose
fix is a REMOVAL**, so every grep-for-presence reads like the defect (`grep -c 'archives-docs-link'` returns
**0**; the ruling is written in-source at app.js:1621). 640 pass / 0 fail on a clean `origin/main` extraction.
`gr-p5r6-seal-finishers` is honestly done at 7/8; its one unmet criterion is the lead's own un-stamped close-out.
**These four are evidence-CLOSED, not forwarded** — forwarding them would tell the next reader the epic left
four user-facing defects unfixed when it fixed all four.

**GR138 — `cloud-console-billing-live-gate` STAYS UNDER `cloud-console-goal`.** Round 8's criterion demanded it
be moved BY NAME into the successor. Refuted as necessary and rejected as correct: bucket (c) is
**parent-independent** — it resolves by hardcoded id and reports `parent=cloud-console-goal
in-epic-roster=false` with a checkmark. Its true owner is the billing epic. It is NAMED in the successor's
charter so it is never lost, and OWNED where it is. Moving it would be taxonomy vandalism in reverse.

**GR139 — THE FIRST ACT IS AMENDED: DO NOT RESET LOCAL MAIN.** The round-8 plan opened with `git reset --hard
origin/main`. At Decide the primary checkout was **dirty with a concurrent session's uncommitted work** — 249
lines across five `internal/taskboard/` files — which a hard reset destroys silently. The reset's *purpose*
(measuring against `origin/main`, since `overflow-guard.mjs` does not exist in the un-reset tree and running
there manufactures a false `guard is NOT COMMITTED` NO SEAL) is served strictly better by a **detached worktree
at `origin/main`**, which is what round 9 used. The primary checkout stays on `main` and is never reset while
other sessions share it. This charter section was authored and committed from that worktree on a branch.

**GR140 — THE DISCLOSURE CENSUS: named, forwarded, NOT widened.** Clause (b) certifies the word KNOWN over only
three hand-registered defects. At least eight live rows self-describe a user-facing defect outside those three
(`gr-backlog-768-residue`, `gr-blk-modal-survives-route`, `gr-blk-index-icon-link`, `gr-backlog-favicon`,
`gr-blk-archives-doc-link`, `gr-blk-invite-ico-danger-variant`, `gr-backlog-setmatrix-scroll-affordance`,
`gr-blk-ok-danger-hue-separation`) — four of which GR137 now closes as landed. Separately, **the guard is
ROUTE-BLIND**: it contains zero occurrences of `deepLink` or `location.hash` while its sibling `smoke.mjs`
navigates with `hash: scen.deepLink || "#overview"`, so every instance-detail panel is structurally unreachable
by it, and GR109's check samples **one of the four** scenarios that render `.attention-row`. A round-9 census
measured all 86 scenarios at 768 with deepLinks applied and found **0 DIRTY** — so "GR109 clean" generalises
BY MEASUREMENT, and the scope gap is real and **empty**. Both facts are recorded and forwarded
(`gr-bl-overflow-guard-route-blind`). Neither widens KNOWN_DEFECTS. **Re-deriving the bar after seeing the
roster is precisely what the freeze forbids, and it is how an epic never closes.**

**GR141 — TWO PREMISES ABOUT THE RUN ENVIRONMENT WERE WRONG.** "Absent `BP_TOKEN`" is **not** a mechanical
failure mode: the roster route serves unauthenticated, and the authenticated and unauthenticated runs are
byte-identical apart from the timestamp — so the repair budget was reserved for a failure that cannot happen.
And the guard is **healthy at the tip**: `overflow-guard.mjs` exits 0 and prints PASS for GR108, GR109 and
GR115 individually and combined, with the served-bytes == disk-bytes anti-squat assertion firing every run,
and refuses an unknown `--defect` id with exit 2 (no vacuous pass). **The browser half of clause (b) is not the
blocker.** With the one permitted edit applied, clause (b) goes fully green live and **clause (a) becomes the
sole remaining blocker** — the entire seal rests on the disposition.

### Ledger disposition — what Decide decided, and what it did itself

The live ledger drifted through the cycle: **139** at round 8's run → **140 {open:77, done:63}** at digest →
**140 {done:64, open:76}** across verify, with the orphan count reading **74 in both runs** — a coincidence,
not a frozen ledger. **GR126 holds: a verdict is valid only at an instant**, and the ~10-second run window is
the only atomicity there is. Decide therefore plans against the disposition RULE, never a frozen count.

Decide **filed the chartered successor itself** (GR136) rather than delegating it, killing both the typo hazard
and the duplication hazard, and because ruling 2 — *the successor ships with a charter, its inheritance triaged
into named bands* — is judgment work, not builder work. `cloud-console-hardening-epic` carries six bands.
The security band ships with a **gradient**, because naming all five rows equally would overstate the residue:
**2 live-and-real** (`gr-bl-peer-ip-container` — the container's Caddy hop arrives from the bridge gateway so
the loopback-only trust silently no-ops, making session IPs uniformly blind AND collapsing the device-auth rate
bucket to ONE global bucket; `gr-blk-sse-token-in-query` — the full-privilege session bearer travels in a URL
query param at router.ex:9707), **1 real but narrower than written** (`gr-blk-oauth-head-mint` — the state
nonce is consumed atomically, so this is a first-use RACE against `Plug.Head` from unfurlers and prefetchers,
not a replay), **1 explicitly ruled clean** (`gr-backlog-tfa-confirm-throttle` — strictly weaker than what the
session already holds), and **1 prospective and out-of-boundary** (`gr-backlog-console-redaction-allowlist` —
today's allowlist covers every live secret; the gap is a future env var, in Go, outside `cloud/`).

Band 2 records a finding the direction did not anticipate: of the five off-epic rows, **exactly one has a real
home** (`gr-blk-studio-presence-perf-flake` → Felix pristine `task-96a908af98698118`). The other four have **no
owning epic in bp at all** — repo-git hygiene, CI/merge-gate governance and Cloud test-infra currently live as
unparented root tasks, `task-openapi-drift-chronic` (`parent_id:null`) being the same class. **That absence IS
the finding.** The successor's charter says so plainly rather than inventing a destination, and preserves
`gr-blk-primary-checkout-reconcile`'s own breakdown naming AXI/PDS/TLV/SPD as the true owners of its commits.

### The wave — three slices, two rounds, no new instrument

Round 1 dispatches two dependency-free slices with **disjoint file sets**; round 2 is the terminal act.

- **`gr-p5r8-register-defect-commits`** (round 1, opus, `cloud/priv/static/__preview__/seal-predicate.mjs`) —
  the ONE permitted edit: `commit: null` → `0261ace15`, registered against all three defects. Sound because
  the SHA was proven **by diff, per defect** (GR108 = `.topbar-right > * { min-width: 0; }` at app.css:787,
  breakpoint-free because children floor at `min-width:auto` and overflow at ~782px ABOVE the 768 breakpoint;
  GR109 = the `.attention-row` tablet-stack block relocated to sit AFTER its base rule; GR115 = the
  `.bp-console-*` block relocated BEFORE the shared media block) — three non-overlapping hunks with in-place
  GR comments. Gate: `node --check` + the three clause-(b) checkmarks from a repo-root run.
- **`gr-p5r9-disposition-pass`** (round 1, opus, **no files** — pure ledger) — executes an 18-row disposition
  table Decide decided and verification proved: 11 closes on diff-verified merge SHAs, 3 merge-gated criteria
  the lead closes (round 8's inherited steps 1 and 2), 4 honest ruling-closes that must SAY they are
  ruling-closes. Two SHAs are explicitly forbidden as evidence — `fcafc0d82` (`task-050074a198b116c4`, cite
  `301e035d8`) and `3d80a58bf` (`gr-backlog-768-residue`, cite the content proof) — because neither resolves
  on `origin/main` and citing them would reproduce the sin one layer up.
- **`gr-p5r5-successor-seal`** (round 2, opus, `after: [gr-p5r8-register-defect-commits, gr-p5r9-disposition-pass]`)
  — re-parents survivors into `cloud-console-hardening-epic` and runs the predicate **LAST, once, atomically**,
  from the repo root, with `--successor`, after sweeping the merge loops and confirming all three gates resolve.

**Round 1 is deliberately thin, and that is the point.** Every act in this wave is disclosure, bookkeeping, or
verification of an EXISTING artifact. Rounds 3–7 each discovered its evidence was thinner than its claim and
spawned a new instrument; every instrument was excellent, and the seal receded by exactly one instrument per
round. **A seventh widening is not rigor — it is how an epic never closes.**

**NO SEAL is pre-authorised and terminal.** One repair attempt is allowed for a MECHANICAL failure (crash per
GR133, wrong cwd per GR135, a bucket-(c) blip per GR134, an unresolvable successor per GR136). A **substantive**
failure IS the verdict: it is recorded verbatim and the named successor is the ending. Whichever way it exits,
the predicate's stdout, stderr, exit code, ISO stamp and roster count become this epic's terminal artifact —
recorded here **alongside** the roster delta and the disposition census, because GR132 guarantees the banner
cannot tell that story by itself.

**Re-parent mechanics, measured for the first time.** `bp task move` is real, CAS-guarded, epoch-fencing and
single-row (`batch:false`) — 74 rows means 74 sequential POSTs. The write bucket is **60/min, keyed global,
SHARED** with every other write on the token; a 429 carries `retry-after: 1` and recovers in ~1s. Two traps:
a same-parent no-op is **not free** (it still emits a `task.reparented` event and still burns a slot, so a
blind catch-up pass costs real budget), and a **bare `?parent_id=` query is silently ignored**, returning an
unfiltered page of up to 100 rows — a false confirmation, not an error. Bracket-encoded `filter[parent_id]`
always.

## Wave 2026-07-20 — phase-5 seal round 10: THE DISPOSITION CENSUS

*(Belongs after round 10's Decide section. Authored by `gr-p5r10-census`. This section is DISCLOSURE, not a
bar — the seal predicate reads exactly three fields per row (`_id`, `lifecycle_status`, `parent_id`, GR131)
and cannot read prose. It cannot pass on this census and it cannot fail on it.)*

**Why this section exists.** GR132 proved `forwarded` is dead code in live mode: a task has ONE `parent_id`, so
a re-parented row leaves `children` entirely and the `forwarded` branch can only fire under `--ledger` fixtures.
After a PERFECT triage the SEAL banner still reads `… 0 forwarded by name to cloud-console-hardening-epic`.
The banner is structurally incapable of saying what this epic did with its survivors. **This census is that
disclosure**, and it is the only artifact in which every live row is disposed BY NAME.

**Roster, re-derived at authoring time** (GR126 — a verdict is valid only at an instant), via
`GET /v1/data/query/production/task?filter[parent_id]=task-47bc4168392dec17&limit=500`:

> **140 children — `{done: 80, open: 60}`.** 60 live = **34 band-named** + **2 self-orphans** + **24 previously
> unnamed**, all 26 of the latter disposed below for the first time.

**GR149 trap (i), restated because it produces a FALSE CONFIRMATION rather than an error.** `GET /v1/tasks`
**silently ignores** `filter[parent_id]` in BOTH encodings and returns an unfiltered page spanning eleven
parents. A roster read that "looks about right" from that route is not a roster. Read the census roster only
via `/v1/data/query/production/task` with the bracket-encoded filter, or via `bp task get <parent>`'s `.children`.

**Citation discipline (GR130).** Every SHA below is a **merge** SHA on the linear squash chain, confirmed with
`git merge-base --is-ancestor <sha> origin/main` → **exit 0**: `3f16c9f43` ✔, `24fae1b9f` ✔, `0261ace15` ✔,
`7a5aff656` ✔. No branch SHA appears as evidence anywhere in this census.

### Closed by name

- **`gr-backlog-bp-search-verb-discoverability`** — **CLOSED** on merge SHA **`3f16c9f43`** (#4725;
  `internal/cli/cli.go:540-576`). `bp search` now answers the shapes five surveyors proved read as an absent
  command. **Honest caveat, recorded rather than smoothed:** its criterion 3 asks for a doctrine sentence that
  lives OUTSIDE this repository, so the criterion is satisfied **in substance, not in letter**. Its PDS twin
  `pds-bl-bp-search-verb-missing` is cross-linked here as **REFUTED by this landing** — that row belongs to the
  PDS epic and is **never touched from this one** (GR148).
- **`gr-p5r7-badcode-shot-nondeterministic`** *(already `done`; its line is carried anyway because its own
  close is under-cited)* — landed as merge SHA **`24fae1b9f`**. Its close text cites only a PR number, which is
  precisely the citation form GR130 outlaws. A **citation-form defect, disclosed here and never reopened**
  (GR147): the work is real, the receipt was written in the wrong currency.

### Forwarded by name — Band 1, security-shaped, with a gradient

- **`gr-bl-peer-ip-container`** — Band 1, **live and real**: the Caddy hop arrives from the bridge gateway
  (172.18.0.1), so `trust_forwarded_ip` trusts loopback only and silently no-ops — session IPs are uniformly
  blind and the device-auth `start:<ip>` bucket collapses to ONE global bucket.
- **`gr-blk-sse-token-in-query`** — Band 1, **live and real**: the full-privilege session bearer authenticates
  `GET /v1/events` via a URL query param (`router.ex:9707`), landing in access logs, proxy logs and history.
- **`gr-blk-oauth-head-mint`** — Band 1, **real but narrower than written**: the state nonce is consumed
  atomically, so this is a first-use RACE against `Plug.Head` from unfurlers and prefetchers, not a replay.
- **`gr-backlog-tfa-confirm-throttle`** — Band 1, **ruled clean, kept for disclosure**: strictly weaker than
  what the session already holds. Do not let a future reader count it as an open security gap.
- **`gr-backlog-console-redaction-allowlist`** — Band 1, **prospective and out of boundary**: today's allowlist
  covers every live secret; the gap is a future env var, in Go, outside `cloud/`.

### Forwarded by name — Band 2, not Cloud GUI at all, in transit

Band 2 exists because the predicate reads ONE forwarding address, not because these belong to a console epic.
Three ownerless classes were already named. **This census names a FOURTH.**

- **`gr-blk-studio-presence-perf-flake`** — **NOT the successor.** Forwarded to **Felix pristine
  `task-96a908af98698118`**, which is its real home: a second wall-clock-fragile perf test in the Studio/Sheets
  family. It is the only Band 2 row with a true owner.
- **`gr-blk-worktree-registry-bloat`** — Band 2, ownerless class *repo-git hygiene*: 1028 registered worktrees.
- **`gr-backlog-stale-w2-branch`** — Band 2, same ownerless class *repo-git hygiene*: delete the superseded
  `loop-epic/gr-w2-cloudchrome-bridge` branch and the stale phase-1 worktrees, after a full unmerged-diff check.
- **`gr-blk-primary-checkout-reconcile`** — Band 2, ownerless class *repo-git hygiene*: ahead 8 / behind 48
  with 1095 lines of foreign uncommitted work. **Its own body names AXI, PDS, TLV and SPD as the true owners of
  its unpushed commits — that breakdown must survive the re-parent.**
- **`gr-blk-vercel-checks-ungoverned`** — Band 2, ownerless class *CI / merge-gate governance*: Vercel checks
  fail on every PR repo-wide and are governed by no document.
- **`task-04054d483ae95bd1`** — Band 2, ownerless class *Cloud test-infrastructure*: 7 remaining `async: true`
  Cloud test modules that swap node-global Application env.
- **`gr-blk-ledger-close-bypass-audit`** — Band 2, **a NAMED FOURTH ownerless class: `bp task-system /
  platform`**. Elixir in `api/lib/barkpark/tasks/` and `api/lib/barkpark/content/mutations.ex` — outside
  `cloud/` entirely, and a member of none of Band 2's three existing classes. **This is the highest-severity
  row in Band 2 and it must not read as hygiene.** A live probe proved `/v1/data/mutate` accepts
  `lifecycle_status:"done"` with **no claim, no epoch, no worker and no `if_rev`** — that is the **only
  reachable KNOWN mechanism** by which a task can be closed outside the CAS path. It is stated as *known*, never
  as *observed*: the audit that ran found **zero** fabrication, and the honest number was 7, not 13. The finding
  is that the door is open, not that anyone walked through it.
- **`gr-p5r9-seal-finishers-crit7-unstampable`** — Band 2, same fourth class `bp task-system / platform`: the
  server refuses stamps on `done` tasks, so `gr-p5r6-seal-finishers` criterion 7 reads unmet on a row whose
  work is factually complete (#4832 merged as `7a5aff656`). A ledger-mechanics defect, not a console defect.
  *(Also a self-orphan — see below.)*

### Forwarded by name — Band 3, harness hardening

- **`gr-blk-cssom-parity-ci-wiring`** — Band 3, and the successor's **named first task**: the parity gate exists
  and is not wired into CI.
- **`gr-blk-cssom-parity-harden`** — Band 3: promote COUNT SKEW to fatal and widen past `app.css`.
- **`gr-backlog-cssom-parity-count-skew`** — Band 3: decide whether count skew is fatal and correct the
  duplicate-selector census.
- **`gr-blk-serve-stale-guard`** — Band 3: `serve.mjs`'s port-collision hole lets a foreign worktree's server
  silently serve the wrong bytes — the exact failure class the anti-squat assertion exists to prevent.
- **`gr-blk-emit-marker-fence`** — Band 3: `design/emit.mjs --write` deletes hand-written CSS while
  `design/check.mjs` exits 0. A live instance of *verify state, not exit codes*.
- **`gr-blk-shootsh-scen-guard`** — Band 3: `shoot.sh` must fail loudly on an unknown SCEN and count the whole
  output, not its own run.
- **`gr-blk-shootsh-guard-regression`** — Band 3: `shoot.sh`'s four new guards have no automated coverage.
- **`gr-backlog-css-brace-detector`** — Band 3, **RE-SCOPED, NOT CLOSED**: E10 does not subsume the brace
  tripwire, and the interim tripwire at `__app.test.mjs:633-656` must not be deleted.
- **`gr-blk-oracle-modal-callsite-coverage`** — Band 3: the CSSOM oracle certifies ONE consumer of `openModal`;
  the shared primitive has 15+ other call sites and #4592 killed it for all of them at once.
- **`gr-blk-revoke-harness-gap`** — Band 3: `scenarios.mjs` has no handler for either revoke route, so the mock
  **fakes success** — "0 session(s) revoked" instead of an honest failure. A harness that lies is worse than
  a harness that is absent.
- **`gr-backlog-scenario-drive-field`** — Band 3: two name-prefix conventions now drive the account-modal shots;
  promote them to a real `scenarios.mjs` field so the contract stops living in a header comment.
- **`gr-backlog-coherence-fixture-durable`** — Band 3: `coherence.html` EMBEDS a byte-copy of the TUI goldens,
  so any foreign cycle that legitimately regenerates a golden reds this epic's harness. Make it READ them.
- **`gr-backlog-orphan-reap-signature`** — Band 3: a reap matching on process name alone killed a sibling
  worktree's live `serve.mjs`. Match on PPID and elapsed time. Filed from a disclosed incident.
- **`gr-backlog-compose-env-passthrough-audit`** — Band 3: `gr-p5r3-ops-passthrough` fixed ONE variable and
  added a tripwire for that ONE variable; **22 `runtime.exs` env names remain absent** from
  `x-control-plane`. The instrument landed narrower than the failure class it was built for.
- **`gr-blk-cp-deploy-rollback-stale-env`** — Band 3: the automated deploy path is verified safe, but
  `cp-deploy.sh`'s **documented `docker start` rollback recipe** serves stale env from the dormant slot. The
  defect is in the instrument's documentation, which is where a rollback is read from under pressure.

### Forwarded by name — Band 4, backend wire-ups whose SPA or test leg did not land

- **`gr-backlog-tfa-retry-after`** — Band 4: the 2FA 429 needs `retry_after` so the client can render honest
  wait math.
- **`gr-backlog-audit-filter-params`** — Band 4: `GET /v1/audit` needs server-side actor and verb-class filters.
- **`gr-backlog-webhook-testsend-http-test`** — Band 4: the test-send route is live with ZERO controller-level
  coverage.
- **`gr-backlog-provider-reconnect`** — Band 4: reconnect-replace semantics need a unique `(team_id, kind)`
  index and an upsert.
- **`gr-backlog-head-requests`** — Band 4: the cloud router answers HEAD with 404 on every path.
- **`gr-bl-cli-test-send`** — Band 4: `bp cloud webhook test-send` is the CLI verb the SPA's Send-test button
  has no chip for.
- **`gr-bl-delivery-keyset-tiebreak`** — Band 4: delivery-log and activity cursors page on `inserted_at` alone
  while the server orders on a compound key.
- **`gr-backlog-e02-deploy-actor`** — Band 4: the audit log already captures the human
  (`site.deploy_requested`, `router.ex ~5062`); either land the join for a backend-true "requested by
  \<email\>" or **ratify trigger-only permanently**. A decision, not a defect.
- **`gr-backlog-operator-digest-send`** — Band 4: GR40 cut the Send-one-now button because NO route calls
  `Notifications.deliver_fleet_digest` (cron-only). The button returns when `POST /v1/operator/digest/send`
  exists behind `require_platform_operator` — GR28 forbids the reverse order.
- **`gr-bl-actor-chip-cache-stale`** — Band 4: `ensureActivityActors()` sets its tried-flag BEFORE the read, so
  a failed members read is never retried and a team switch never refreshes the actor axis.
- **`gr-p5-session-provenance`** — Band 4: `GET /v1/account/sessions` has no origin column, so the design's
  "approved 2d ago via device link" has no backing field. Needs a server-side `origin` column first.
- **`gr-blk-console-refetch-storm`** — Band 4, as **OVER-consumption of the server↔SPA seam, explicitly NOT
  Band 5.** It is the **only row in this entire roster carrying a live production measurement**: on
  authenticated `barkpark.cloud`, five endpoints (`/v1/barkparks`, `/v1/audit?limit=5`, `/v1/usage/summary`,
  `/v1/subscription`, `/v1/onboarding`) were each requested **EIGHT times in one page load — 40 requests where
  5 would do**, in seven evenly-spaced repeats consistent with one full reload per SSE event. **Zero 4xx, zero
  5xx, zero console errors** — so nothing surfaces it, no gate reds on it, and it scales with SSE chatter.
- **`gr-p5r4-spa-b`** — Band 4, and it is forwarded as **A WAVE SLICE, NOT A DEFECT.** Read plainly, its title
  overstates the residue: **five of its six workstreams are ALREADY forwarded as their own rows and MUST NOT be
  counted twice** — `gr-backlog-tfa-retry-after`, `gr-backlog-audit-filter-params`,
  `gr-backlog-webhook-testsend-http-test` and `gr-bl-delivery-keyset-tiebreak` in Band 4, plus
  `gr-backlog-css-check-missing-classes` and `gr-backlog-setmatrix-scroll-affordance` in Band 5. It stays open
  for **ONE payload carried by no other row: section (E)** — a `scenarios.mjs` fixture reproducing the operator
  console's **real production state**, `staging_gate_open: true` with **ZERO `channel:"staging"` rows**. That is
  the crown's most likely live render state and it is **unmeasured**. Section (E) is named here explicitly
  because if the row is ever read as "the five already-forwarded things", (E) is silently lost.

### Forwarded by name — Band 5, QA, matrix and UI residue

- **`gr-backlog-tablet-width-audit`** — Band 5: console-wide 768px audit; other components may share the
  unguarded-breakpoint pattern.
- **`gr-backlog-accent-matrix-rereview`** — Band 5: actually review the full accent matrix rather than assert it.
- **`gr-blk-accent-scenario-sweep`** — Band 5: 74 scenarios never measured under the four non-default accents.
- **`gr-p5r7-ring-soft-accent-invariant`** — Band 5: `--ring-soft` is declared twice and is green-hued and
  accent-invariant across all five identities. Found by opening shots, not by reading code.
- **`gr-blk-ok-danger-hue-separation`** — Band 5: `--ok-hsl` tracks `--primary-hsl` per identity while
  `--danger-hsl` is pinned at hue 0, so semantic separation drifts per accent.
- **`gr-backlog-setmatrix-scroll-affordance`** — Band 5: the notifications matrix scrolls without announcing it;
  the last channel column is invisible. *(Also a spa-b workstream — counted here, once.)*
- **`gr-backlog-css-check-missing-classes`** — Band 5: 6 class families emitted with no CSS rule, plus 2
  unclassifiable var-then-concat sites. *(Also a spa-b workstream — counted here, once.)*
- **`gr-backlog-tall-modal-scenario`** — Band 5: the 9-session account modal — **the exact shape that broke
  prod** — is still invisible to the screenshot harness.
- **`gr-blk-smoke-click-inert`** — Band 5: the smoke shim is click-inert, so every wire in the console is proven
  statically and never actually clicked.
- **`gr-blk-a2fwire-coverage`** — Band 5: `a2fWire()`'s click → api → repaint chain has zero unit coverage;
  `grep -c a2fWire __app.test.mjs` returns 0.
- **`gr-blk-hashchange-listener-wiring-proof`** — Band 5: `hashChangeEffects` is pinned as a pure function, but
  nothing pins that the LISTENER consults it, or that `closeModal()` runs BEFORE `applyRoute`. Proven at the
  decision, never at the wiring.
- **`gr-backlog-reset-route-smoke`** — Band 5: the password-reset route renders correctly under a vm probe and
  has ZERO DOM-level smoke signal.
- **`gr-backlog-operator-palette-entry`** — Band 5: `paletteNavItems()` is a static argument-free registry, so
  Cmd+K structurally cannot role-gate an Operator entry.
- **`gr-backlog-d24-statusmeta-sweep`** — Band 5: parent decision 24's `statusMeta` grammar never landed —
  git-proven, no commit ever touched `statusMeta` — and `.dep-pill` / `.status-pill` remain two rule families.
- **`gr-blk-sdk-tui-role-labels`** — Band 5, with an honest boundary note: the row lives in `js/` and the Go TUI,
  **outside `cloud/`**, but the rule it may violate is the console's own role vocabulary
  (`owner`/`admin`/`member` user-facing, `platform_operator` internal and never a role). It is banded here
  rather than opening a fifth ownerless Band 2 class for a single row; the successor may re-route it.

### Forwarded by name — Band 6, permanent human gates (in-roster)

- **`gr-ops-platform-admin-emails`** — Band 6, human gate: `PLATFORM_ADMIN_EMAILS` is unset on the live control
  plane. **THE CROWN IS DARK** — the operator console ships and cannot be seen in production until a human sets
  the env and recreates. Disclosed by name every time; its disappearance is itself the tripwire.
- **`gr-backlog-qr-live-scan-proof`** — Band 6, human gate: a human must scan a real 2FA QR with real phone
  authenticator apps. Byte-identity is not a phone.

**`cloud-console-billing-live-gate` is deliberately absent from this census.** It is parented at
`cloud-console-goal` by design (GR138), is therefore **not among the 60**, and bucket (c) resolves it by
hardcoded id independent of parent. Naming it as a move would be false, and a same-parent no-op still burns a
write slot.

### The self-orphans

Two live rows are parts of the seal machinery itself, parented under the epic they were built to end. They
cannot be forwarded as residue without misdescribing them.

- **`gr-p5r5-successor-seal`** — the **terminal act**, not a survivor. It verifies (never re-files) the
  chartered successor, re-parents the survivors named above, and runs the predicate LAST, once, atomically,
  from the repo root, with `--successor cloud-console-hardening-epic`. It is disposed by **running**, and its
  own row closes on the verdict it produces — whichever way that verdict goes.
- **`gr-p5r9-seal-finishers-crit7-unstampable`** — a self-orphan **and** a Band 2 row; forwarded to the fourth
  ownerless class `bp task-system / platform`, as recorded above. It is listed twice here on purpose: it is
  one row, and both facts about it are true.

*(The two other self-orphans of the round-9 pass, `gr-p5r8-register-defect-commits` and
`gr-p5r9-disposition-pass`, are `done` and are outside the live 60.)*

### What this census asserts, and what it does not

It asserts that at authoring time **every one of the 60 live rows under `task-47bc4168392dec17` is disposed by
name**, and that **ZERO rows sit in an unnamed remainder**. It does **not** assert that the predicate agrees —
the predicate cannot read this section (GR131), and it is not a bar (GR146). It does not widen `KNOWN_DEFECTS`,
the clauses or the thresholds. Every finding surfaced while writing it was **named and forwarded, never built**
— **no seventh instrument** was created to accommodate any row above.

**The census is the contract on the successor's intake.** `cloud-console-hardening-epic`'s charter is amended
in the same breath to say what follows from that: **its band lists are CLOSED.** A row that arrives in the
successor without a line in this census **arrived by accident** — re-triage it, do not absorb it. That sentence
is the only thing standing between a triage and a bulk sweep, because the predicate cannot tell them apart.
### Wave 2026-07-20 (round 10) — the census is the deliverable, the exit code is the signature — DECIDE

Wave Paper `cloud-gui-remake-wave-2026-07-20-seal-r10`. Laws GR142–GR152. **This round plans no new
measurement.** Round 9's three-slice plan is executed exactly as chartered; the wave's entire surplus goes into
ONE artifact the predicate provably cannot produce — a complete disposition census in which every live row is
named. **Round 9's wave partly flew, and three of Decide's own premises were wrong.** They are corrected below.

**GR142 — CLAUSE (b) IS FLAKY, AND GR141'S CONCLUSION IS REFUTED.** GR141 measured `overflow-guard.mjs`
standalone, found it healthy, and generalised to the predicate's spawn pattern: *"the browser half of clause (b)
is not the blocker … clause (a) becomes the sole remaining blocker."* **The generalisation does not hold.**
Two independent verifiers induced the post-round-1 world and ran it four times each: one saw
`✗ GR108-tablet-topbar-overflow / guard exited 1`, the other `✗ GR115-bpconsole-dead-rule / guard exited 1` —
**two failures in eight runs, on different defects, from a guard that passes all three standalone and under a
replica of the predicate's exact `spawnSync` sequence.** The indicated mechanism is fixed-port contention:
the guard binds `4199` (overflow-guard.mjs:84) with an 8 s server-wait cap and the predicate spawns it three
times back-to-back (seal-predicate.mjs:175) on a loaded multi-agent host. **The terminal run therefore carries
a material chance of signing a false substantive failure**, and the banner cannot tell you: the predicate
captures the guard's stderr and reads only `r.status`, so a mechanical squatter and a real measured defect
print byte-identical lines with zero stderr.

**GR143 — THE MITIGATION AND THE ONE PRE-AUTHORISED REPAIR.** Measured this round: `OVERFLOW_GUARD_PORT` **is**
honoured (`OVERFLOW_GUARD_PORT=4231` → `>> serve :4231 — served bytes == disk bytes`, exit 0, all three defects
PASS, 0 bytes stderr). The terminal run therefore MUST: (1) export `OVERFLOW_GUARD_PORT` to a verified-free
port, removing the squatter class entirely; (2) run the guard standalone **immediately before** the predicate,
capturing stdout, stderr and exit separately — a second *invocation* of an existing instrument, not a seventh
instrument; (3) capture the predicate's three streams separately, because a GR133 crash is detectable only by
zero-byte stdout. **Pre-authorised as MECHANICAL, spending the single repair:** clause (b) reporting
`guard exited 1` for a defect whose standalone guard passed at the same tip, minutes earlier. Everything else
substantive-shaped is the verdict.

**GR144 — GR135 IS REFUTED IN A WAY THAT HELPS.** GR135 called the wrong-cwd signature *"textually identical to
a real clause-(b) failure."* It is not. Wrong cwd emits `guard … is NOT COMMITTED — the fix is unmeasured, and
unmeasured is not cleared`, a string no genuine failure can produce (genuine says `guard exited N`); post-
landing it additionally emits `commit 0261ace15 is not an ancestor of origin/main` per defect. **One grep for
`NOT COMMITTED` classifies it.** Guard exit **2** is likewise always mechanical — it fires in argument parsing
or before Chrome, so it can never mean a measured defect. **The only genuinely ambiguous row is `guard exited
1`**, and GR143 disambiguates it out of band.

**GR145 — THE MOVE-SET IS 60 ORPHANS, NOT 25, BECAUSE THE SUCCESSOR'S INHERITANCE IS PROSE.** The baseline run
nobody had ever executed reads: `roster: 142 children {"open":62,"done":80}` · `forwarded under successor : 0` ·
`permanent human gate : 2` · `UNNAMED RESIDUE (orphans) : 60`. `cloud-console-hardening-epic` names 34 rows
across six bands and **not one has been re-parented** — its three children are all `gr-bl-*` backlog rows.
Clause (a) reads `parent_id` and nothing else (GR131), so **"named in a band" is worth exactly zero.** Settled
arithmetic, re-derived at Decide: **62 live = 34 band-named + 4 self-orphans + 24 unnamed** (the 24-vs-25
disagreement between verifiers was labelling — `gr-p5r9-seal-finishers-crit7-unstampable` is a fourth
self-orphan, not a 25th unnamed row; the sets are identical). 60 orphans = 62 live − 2 in-roster human gates.

**GR146 — THE CENSUS IS A DISCLOSURE, NOT A BAR, SO IT IS NOT A SEVENTH INSTRUMENT.** Widening the census from
round 9's 18 rows to all 62 is not the widening GR140 forbids. GR140 forbids widening **what the predicate
MEASURES** — `KNOWN_DEFECTS`, the clauses, the thresholds. The predicate does not read the census, cannot fail
on it, and its exit code is byte-identical with or without it. A disposition line is a sentence, not a
measurement. **HARD STOP, pre-committed here so it cannot be renegotiated under time pressure: if census work
threatens the terminal run, THE RUN WINS** — the census is recorded as far as it got and the uncovered rows are
named AS UNCOVERED. An honest partial census beats a delayed seal.

**GR147 — THE 12-ROW DELTA IS RETIRED, WITH PROOF, AND ZERO FALSE-DONES EXIST.** Decide's own premise —
"twelve rows closed since round 9 by agents outside this wave" — is wrong twice. It was **16** rows, and they
were **round 9's own builder** executing its frozen table in one window (15:11:34Z–15:25:14Z). Proven by
fetching all 80 done rows individually: exactly 16 carry `updated_at` inside that window, **set equality with
the 18-row table is True**, and **zero** done rows were updated after it. Every positively-cited SHA is an
ancestor of `origin/main`; both forbidden branch SHAs (`3d80a58bf`, `fcafc0d82`) appear **only inside their own
refusal sentences**, exactly as GR130 demanded. The roster is quiescent, so the census can be built against a
stable target. **One citation-form defect is disclosed, not reopened:** `gr-p5r7-badcode-shot-nondeterministic`
closes asserting merge-SHA discipline while citing only PR #4833 — substantively sound (its merge commit
`24fae1b9f` IS an ancestor), so the census names the SHA rather than the row being re-audited.

**GR148 — A ROW WHOSE FIX LANDED IS CLOSED, NOT FORWARDED, EVEN WHEN NOBODY NOTICED.**
`gr-backlog-bp-search-verb-discoverability` is fixed and landed: `bp search "…"` runs the query and prints its
note to **stderr** (so JSON piping survives); an unknown noun and an unknown verb now produce visibly different
errors. Merge SHA **`3f16c9f43`** (#4725), is-ancestor exit 0, implementation `internal/cli/cli.go:540-576`.
Honest caveat recorded in the close: the doctrine sentence itself lives outside the repo, so criterion 3 is
satisfied in substance, not in letter. **The roster therefore moves 62 → 61 live before a single re-parent.**
Its twin `pds-bl-bp-search-verb-missing` belongs to PDS and is **cross-linked as refuted, never touched** —
a foreign epic's row is not ours to close.

**GR149 — THE THREE MECHANICAL TRAPS THAT WOULD MAKE A CORRECT PLAN PRODUCE A WRONG ROSTER.**
(i) **`GET /v1/tasks` silently ignores `filter[parent_id]`** — bracket-encoded *and* bare, returning an
unfiltered page spanning eleven parents. This defeats GR126's own prescribed remedy and is a **false
confirmation, not an error**: a builder sourcing its work-list here would re-parent ~140 foreign rows and it
would look like success. The only correct reads are `/v1/data/query/production/task?filter[parent_id]=…` and
`bp task get <parent> -o json` → `.children`. (ii) **The rate-limit detector must be status-based.** Round 9's
driver matched response TEXT for `429`/`rate_limited` and burned 12 spurious claim epochs; measured on today's
roster, **8 of 62 live rows would return a 200 SUCCESS body containing "429"** and 4 also contain
`rate_limited` — some in prose (this epic's own 2FA-throttle backlog), some in `_rev` digests and microsecond
timestamps, which are **re-rolled on every write**, so whitelisting known-bad rows is unsound. Use `bp` exit
**7** (uniquely `exitRateLimit`, regression-pinned), or HTTP status, or `jq -e '.error.code == "rate_limited"'`.
A real 429 was induced at request 66 of a 75-request burst; `retry-after: 1`; pacing at `sleep 1.1` is proven
safe and `1.0` leaves only network RTT as margin. (iii) **`bp task move` blocks on an interactive prod
confirmation without `--yes`**, takes no epoch, and charges a full write token for a same-parent no-op —
so `cloud-console-billing-live-gate` (GR138) is **skipped entirely**, never no-op-moved.

**GR150 — SELF-ORPHANS TRAVEL AS CHILDREN, AND THE WAVE'S OWN SLICES MUST NOT SIGN A CLERICAL NO SEAL.** All
four wave-adjacent rows sit under the epic root today and would each count as an orphan at run time — a
self-inflicted failure unrelated to the epic's substance. Dispositions: `gr-p5r8-register-defect-commits` and
`gr-p5r9-disposition-pass` become **children of `gr-p5r5-successor-seal`** (they are its sub-slices, and a
child of a child is not a child — clause (a) reads direct children only) and are then closed on evidence;
`gr-p5r9-seal-finishers-crit7-unstampable` **forwards to the successor**; `gr-p5r5-successor-seal`
**re-parents itself into `cloud-console-hardening-epic` as its LAST move before the run**, while still
in progress. This is tree structure, not a rename — the sub-slices genuinely belong to the seal.

**GR151 — ROUND 9's WAVE PARTLY FLEW; THE RISK INVERTS FROM "TOO LITTLE TIME" TO "RE-DERIVING FINISHED WORK."**
`gr-p5r9-disposition-pass` is substantively **done** — all 18 table rows read `done`, task at 6/8. Its two
unmet criteria are **not one**, as the digest claimed: criterion 7 is the lead-close, and criterion 2 is a
recorded **honest miss** (1 of 3 merge-gated stamps actioned, 2 declined for good reasons — one would have
replaced true evidence with false, the other is structurally unstampable). **A lead closing it believing only
criterion 7 is open will mis-stamp or 409.** `gr-p5r8-register-defect-commits` is **built and gated** at
`18ab484aa`, its diff proven to be exactly three `commit:` lines (`diff` of both files with `commit:` lines
removed exits 0 — every other byte identical), applying cleanly to today's tip. **But the branch was never
pushed and no PR was ever opened** (`git branch -r --contains` empty, `gh pr list --head` empty). Round 1 is
therefore *push → PR → gates → merge*, not a merge button — and `cloud.yml` fires on `cloud/**` with no
sub-path filter, so a three-line `.mjs` edit drags the full cloud Elixir suite onto the critical path.

**GR152 — THE CHARTER IS UNGATED, SO CENSUS LENGTH IS FREE.** Proven by mutation, not by reading: appending 200
census-shaped rows (20,801 B) to this file leaves `check-doc-budgets.sh` at PASS/exit 0 and
`docs-anchors-check.sh` at PASS/exit 0, neither script even naming the file — `.claude` is absent from the
budget allowlist by omission and **pruned by name** from every anchors walk. The control proves the gate is
live rather than inert: appending 200,000 B to `docs/INDEX.md` reds it immediately (`cap is 1200B`, exit 1).
**The census may be as long as honesty requires.** The live schedule risk is elsewhere: PR #5046 adds a
repo-wide **blocking, paths-filter-free** format-drift-ceiling job and is **currently red on its own PR** from
drift introduced by three concurrently-merged Studio PRs — the exact collision shape it could inflict on this
wave's unrelated three-line PR. Main carries no branch protection (404, rulesets `[]`), so enforcement is
convention; the honest response is to check #5046's state before pushing round 1, not to build around it.

### Ledger disposition — the census this wave ships

`cloud-console-hardening-epic` is **verified, never re-filed**: published, top-level, `open`, six bands intact,
three children. The second-successor hazard is closed — `gr-p5r3-successor-epic` reads `done`. **There is
exactly one forwarding address.** Band 5's closing clause *"and the rest of the forwarded roster"* is deleted
this wave and replaced by a closed list plus the sentence that a row arriving without a census line **arrived
by accident: re-triage it, do not absorb it.** That clause is the only thing standing between a triage and a
bulk sweep, because the predicate cannot tell them apart.

Three findings this wave surfaced are **named and forwarded, never built** (GR146): the `/v1/tasks` filter
false-confirmation, the CAS-free ledger-close bypass, and Band 4's need to own **both** directions of the
server↔SPA seam — `gr-blk-console-refetch-storm` is the only row in the entire roster carrying a **live
production measurement** (five endpoints requested eight times each in one authenticated page load, 40
requests where 5 would do, no error surfacing it) and it is filed as over-consumption of the same seam Band 4
already owns, not buried under UI residue.

### The wave — three slices, two rounds, no new instrument

- **`gr-p5r10-land-defect-commits`** (round 1, opus, `cloud/priv/static/__preview__/seal-predicate.mjs`) —
  push `18ab484aa`, open the PR, carry it green through the full cloud suite, merge. **The diff must remain
  exactly three `commit:` lines; one byte more voids the wave.** Unblocks clause (b) — the critical path,
  because the predicate tests `git merge-base --is-ancestor <commit> origin/main` and a merge is not atomic
  with anything.
- **`gr-p5r10-census`** (round 1, opus, `.claude/workflows/bp-cloud-gui-remake-charter.md`) — author the
  62-row disposition census and amend the successor's Band 5 to delete the remainder clause. Zero rows in an
  unnamed remainder. Disjoint file set from round 1's other slice.
- **`gr-p5r10-terminal-run`** (round 2, opus, `after: [gr-p5r10-land-defect-commits, gr-p5r10-census]`) —
  execute the census's moves and closes, then run the predicate **LAST, once, atomically**, and record its
  verbatim stdout, stderr, exit code, ISO stamp and roster count beneath the census, whichever way it exits.

**Why the exit code is the signature and not the deliverable.** GR131 read clause (a) for the first time: it
reads exactly three fields. GR132 proved `forwarded` is dead code in live mode, so **after a perfect triage the
banner still reads "0 forwarded by name."** The predicate is structurally incapable of expressing what this
epic did. The census exists because of that, not despite it. **THE CROWN IS DARK** — re-proven live today
(`/v1/me` → `platform_operator:false`; `/v1/operator/warm-pool` → 403 against an anonymous 401): the operator
console shipped fully built and remains unreachable because `PLATFORM_ADMIN_EMAILS` is still unset on the
control plane. **"Seal" means CODE seal only, and the ending must say so in plain words.**

### Wave 2026-07-21 (round 12) — THE ACT RAN. VERDICT: SEAL. Grade A.

Wave Paper `cloud-gui-remake-wave-2026-07-21-r12`. One slice, one agent, one instant. After seven attempts and
a round 11 that wrote a perfect runbook and executed **none** of it, round 12 did the two mechanical acts and
took the verdict.

**WHAT LANDED.** `gr-p5r12-terminal-act`, final branch
`loop-epic/the-terminal-act-executed-move-the-58-cl-0-r`. One close
(`gr-backlog-bp-search-verb-discoverability` → done 3/3 on merge SHA `3f16c9f43`, first attempt, no fallback).
**Fifty-nine re-parentings** — 58 successor-bound (57 banded + `gr-p5r5-successor-seal` self-orphaned LAST) and
1 to `task-96a908af98698118`. Rosters verified live by the reviewer, independently of the builder's report:
epic `task-47bc4168392dec17` **140 children / 60 live → 81 / 0 live**, successor `cloud-console-hardening-epic`
**10 → 68**, `task-96a908af98698118` **46 → 47**. The frozen predicate ran **once**, from a pristine worktree,
`--successor cloud-console-hardening-epic`, no `--ledger`, no `--guard-cmd`: **VERDICT: SEAL, exit 0, stderr 0
bytes.** 211 lines of terminal artifact appended to this charter. **No eighth instrument** — both `.mjs` files
byte-identical to `origin/main`, the charter the only file in the commit.

**WHAT THE REVIEW ADDED.** The seal was **independently reproduced twice** from a second worktree at the branch
tip (the actual merge candidate), on different ports, after a fresh `git fetch` — banner identical line for
line. Clause (b) was **mutation-proved**: forcing `.topbar-right > *` to `min-width:400px` made the guard FAIL
with 44 real findings under Chrome 150 serving disk bytes, so the green is a live measurement, not a rubber
stamp. One prose defect fixed: the artifact's "Fifty-eight moves" heading undercounted by one against its own
(correct) roster-delta table.

**WHAT DID NOT GET SOLVED, and is not pretended otherwise.** The seal is a **CODE seal**. The crown is still
DARK (`gr-ops-platform-admin-emails` is a human shell act; no commit can set an unset prod env var). The
done-set was never fully audited — 81 rows carry a close record, which is not 81 rows verified; one named
false-done (`gr-blk-shootsh-scen-suggester`) is a **FLOOR, not a ceiling**, and
`gr-bl-doneset-merge-sha-reaudit` stays OPEN. The 58 forwarded rows are **moved, not solved**: the successor now
carries 68 open children and no plan. Two rows filed at review under the successor:
`gr-bl-gr108-fix-overdetermined` (the GR108 fix turns out to be over-determined — removing it does not
reproduce the overflow, so the charter's causal story is not the whole mechanism) and the builder's
`bl-task-move-stdin-refusal`.

**NEXT.** Nothing, for this epic — it ends here, there is no round 13. The work continues under
`cloud-console-hardening-epic`, whose first job is to plan its 68 inherited rows and whose highest-value early
row is the done-set re-audit.

---

## Wave 2026-07-21 — phase-5 seal round 11: THE TERMINAL WAVE (execute and disclose, then END)

**This wave does not plan. It executes a plan that is already merged, runs the frozen predicate once, and
writes down whatever it says.** There is no round 12. Whichever way the exit code lands, the epic ends here:
exit 0 seals it as a CODE seal, exit 1 hands it to the named successor. Both endings were pre-authorised at
round 10 and neither is a failure. **No seventh instrument is built, and no instrument is widened.**

### GR153 — the wave's own premise was WRONG, and the way it was wrong is the finding

Strategize asserted, as a ground-truth correction, that *"the 62-row census (#5079) is NOT yet a written
artifact — the charter carries only the census PLAN."* **That is false.** Five surveyors refuted it with
`file:line` + `gh` evidence and Decide re-verified at L2: `git merge-base --is-ancestor 0f72dfd76 origin/main`
exits 0 against `origin/main = bc64d869a`. PR #5079 merged 2026-07-20T20:46:50Z and appended the complete
per-row census at charter lines ~967–1173.

**Why the error happened matters more than the correction.** The two surveyors who agreed with the false
premise both read `gr-p5r10-census`'s stale `claim.now` note — *"committed 0bf8fe29e … Not pushed."*
`0bf8fe29e` is **not** an ancestor of `origin/main`; the squash-merge `0f72dfd76` is. This is **GR130's
branch-SHA-vs-merge-SHA trap recurring at the level of the wave's own premise** — the exact error that made
round 9 believe four landed defects were unfixed. A `claim.now` note is a worker's assertion about a local
branch. `--is-ancestor` is the running system. **The rule stands: no disposition is ever written from a claim
note; every SHA in this epic is ancestor-verified or it is not cited.**

### GR154 — the move-set, re-derived at Decide against a fresh roster: 60/60, exact, zero remainder

Live roster at Decide: **140 children, `{done: 80, open: 60}`, `in_progress: 0`.** (Strategize's `{80, 59, 1}`
was already stale within hours — GR126 proving itself on this wave's own numbers.) The 60 live ids were
diffed both directions against the census: **`comm -23` empty, `comm -13` empty — an exact 60/60 cover.**
All census-named ids resolve; the one apparent `NOT_FOUND`, `gr-w2-cloudchrome-bridge`, is a **git branch
name** quoted inside another row's prose, not a task. The feared `gr-blk-`/`gr-bl-` id slip **does not exist
in the charter** — the census writes `gr-bl-peer-ip-container` and it resolves.

The 60 decompose exactly: **57 move to `cloud-console-hardening-epic` · 1 CLOSES · 1 moves elsewhere ·
1 is the seal itself, disposed by running.**

- **The one CLOSE — `gr-backlog-bp-search-verb-discoverability`.** The census declared it CLOSED on
  `3f16c9f43`; **the ledger action was never executed.** It reads `open 0/3`, unclaimed, still under the epic.
  The SHA is a genuine ancestor and the fix is genuinely live (`soleReadVerb` on `origin/main`;
  `bp search "seal predicate successor"` runs the query and returns hits). **CLOSE it — both CLOSE and MOVE
  clear clause (a), only CLOSE is honest.** Pre-authorised fallback: if the claim/close does not land in two
  attempts, MOVE it and **disclose in the artifact that the census's CLOSE was executed as a forward.**
- **The one row that does NOT go to the successor — `gr-blk-studio-presence-perf-flake`** → `task-96a908af98698118`,
  its real home, exactly as the census says in bold. **A blind 60-row sweep against the successor would
  silently violate the census it is executing.** This is the sharpest mis-routing hazard in the set, and it is
  not the billing gate.
- **`cloud-console-billing-live-gate` is NOT MOVED.** It resolves `open` under `cloud-console-goal`, its true
  owner, and the predicate reaches it by hardcoded id via a parent-independent `filter[_id]`. **Any move line
  naming it is a defect.**
- **The two in-roster human gates DO move** (`gr-ops-platform-admin-emails`, `gr-backlog-qr-live-scan-proof`).
  The predicate does not require it — `PERMANENT_HUMAN_GATES` is checked **before** the forwarded set, so a
  live gate under the epic lands in `gatedLive`, never `orphans`. They move because the census forwards them
  to Band 6 and **a forwarding address that does not actually hold the row is prose, not a handoff.**
  Expected visible effect: bucket (c) prints `in-epic-roster=false` on **all three** gate lines. **That is the
  correct output, not a defect.**

### GR155 — GR148's "honest caveat" is itself wrong, in the row's favour, and is corrected here

The census records that `gr-backlog-bp-search-verb-discoverability`'s criterion 3 *"asks for a doctrine
sentence that lives OUTSIDE this repository, so the criterion is satisfied in substance, not in letter."*
**Refuted at source.** `git grep -n "before grepping" origin/main` returns
`origin/main:.claude/agents/felix.md:61` — a tracked, agent-facing doc carrying exactly
`- **bp search first**: before grepping the tree, \`bp search <concept>\``. That line cites `bp search <concept>`
**without** the word `query` — meaning `3f16c9f43` made a **pre-existing doctrine sentence true** rather than
the doc being edited to match the CLI. `docs/cheatsheets/bp.md:21` is a second in-repo anchor.
**Criterion 3 is met IN LETTER, at `.claude/agents/felix.md:61`.** The close must say so, and the terminal
artifact must not repeat the retired caveat. *(Note the recursion: GR113 once recorded that `bp search <term>`
errors `unknown command`. It did, then. This epic's own fix made its own charter line stale.)*

### GR156 — the banner will understate the wave, and the charter pre-empts it rather than widening the tool

`fwd` counts only forwarded rows **still in the epic roster**. A row that has been moved is gone from
`children` and never reaches the forwarded check — GR132's dead-code finding, now landing on the exact line
the seal is signed on. **After a perfect triage the SEAL banner reads
`Sealed 81 children: 81 evidence-closed, 0 forwarded by name`.** Read alone it says nothing was forwarded.

**Therefore the roster delta is part of the terminal artifact, in plain words, beside the verbatim stdout:**

| | before | after (expected) |
|---|---|---|
| epic `task-47bc4168392dec17` | 140 children, 60 live | **81 children, 0 live, all `done`** |
| successor `cloud-console-hardening-epic` | **10 children** | **68 children** (10 + 57 + the seal) |
| `task-96a908af98698118` | 46 children | 47 (studio-presence) |

**The successor's "before" is 10, not the 7 that Verify measured** — Decide filed three inherited backlog rows
under it (GR158's false-done, and two instrument defects found while proving the preconditions). Read the
successor's count live before the moves rather than trusting either number; **the invariant that matters is
`after − before = 58`, not any absolute.** If the CLOSE was executed as a forward instead, the shape is
**80 children / 0 live** and successor **69** — record whichever actually happened. **Any live row remaining after the moves is an orphan: catch it in the
re-read, not from the exit code.**

### GR157 — the four SCOPE caveats print on the SEAL branch ONLY, so the charter carries them itself

The predicate's entire `SCOPE —` block, including all four *"NOT asserted by this green"* points, sits inside
`if (ok)`. **A NO SEAL run emits none of it** and ends four lines after the verdict. A NO SEAL ending would
otherwise lose this epic's whole honesty disclosure. So it is recorded here, **independent of verdict**:

1. **Defect coverage is bounded by what was REGISTERED.** Clause (b) certifies the word *known* over three
   hand-registered defects. A defect nobody looked for is invisible to it.
2. **The overflow sweep covered 86/86 scenarios × 2 themes at 768px (default accent), plus 12/86 × 5 accents.**
   NOT swept: 74 of 86 scenarios under the four non-default accents; widths outside 721–1440 were measured on
   the two past-due screens only.
3. **21 clean-CAS children are sealed on evidence nobody read.** 0 of 39 checked failed, bounding the true
   material-failure rate at ~8% upper-95% — so **up to ~2 of the 21 may carry one.** They are enumerated by
   name in this charter, never described as a subtraction.
4. **THE CROWN IS DARK, and structurally so.** `PLATFORM_ADMIN_EMAILS` resolves to `[]` at every layer; the
   real value lives in a gitignored `.env`; **zero deploy scripts reference it, so no commit can set it.**
   Because the allowlist is empty, every *authenticated* user gets 403 — the console is dark for everyone, not
   selectively lit. *(Correction to round 10's wording: the anonymous probe returns **401**, not 403, because
   `require_user` precedes the allowlist check. The artifact must state the MECHANISM — empty allowlist,
   un-settable by commit — never claim an observed `platform_operator:false` body.)* **"Seal" here means CODE
   seal, never "this feature is live for any human."**

### GR158 — one named false-done in the done-set, DISCLOSED and forwarded, never reopened

`gr-blk-shootsh-scen-suggester` is a genuine false-done. Its sole evidence is
*"Fixed in review on loop-epic/land-the-shoot-sh-watchdog-bound-the-rea-1-r (8a1545bd7)"*. Re-verified at
Decide: `8a1545bd7` is a real local object, `git branch -r --contains` is **empty**, `--is-ancestor` exits
**1**, and `origin/main`'s `shoot.sh` has **zero** occurrences of the described near-match ladder
(`did you mean` / `resembles`) — it still carries the older bare `Closest by prefix:` mechanism. Its sibling
on the same branch family (`gr-blk-shootsh-reap-timeout`, PR #4834) **did** land, which is exactly why the
false-done is easy to miss: one twin shipped, the other sat on an unpushed review branch and was marked done
anyway.

**It is NOT reopened.** Reopening it would create a new live row under the epic — a clause-(a) orphan and a
clerical NO SEAL — and re-auditing the done-set to prevent a green **is the seventh instrument in miniature**.
It is named here, and filed as a fresh row **under the successor**, where clause (a) cannot see it and a human
can. **The done-set honesty claim is therefore: one named false-done, not "no false-dones found."** The
20 named PR-only rows were separately resolved — all 17 distinct PRs merged, all 17 merge commits
ancestor-verified, zero failures; `gr-backlog-email-fleet-mapping`'s apparent `#14181` is the hex literal
`#14181f`, a regex artifact.

### GR159 — the mechanical preconditions, each measured, none re-litigated

- **Clause (b) is satisfiable now.** `#5060` (`b47e1ecc1`) registered `0261ace15` in all three
  `KNOWN_DEFECTS`; both are ancestors of `origin/main`. `gr-p5r8-register-defect-commits` is **lead-closed 5/5**
  at Decide, and `gr-p5r10-census` **lead-closed 8/8** on `0f72dfd76`.
- **The guard is healthy and the port is the whole story.** `OVERFLOW_GUARD_PORT=4231`: **20/20 clean** —
  5 runs in the literal shape plus **15 in the predicate's true per-defect `spawnSync` shape**, every one
  exit 0 with **0 bytes of stderr** and all three defects PASS. Port **4199 is squatted right now** (node pid
  92003), confirming GR142 was contention and GR143 is the cure. **Probe with `lsof`, never a zsh `/dev/tcp`
  test — the latter reported 4199 free while `lsof` showed the listener.** Fallbacks: 4233, 4241.
- **A clause-(b)-only NO SEAL is MECHANICAL until proven otherwise.** The predicate reads only the guard's
  `.status` and **never reads `r.stderr`**, so a guard that exits 2 because it could not bind a port prints,
  verbatim, `guard exited 2 — the defect is still measurable at origin/main` — **a false statement about
  pixels**, with the predicate's own stderr at 0 bytes. The **one** pre-authorised repair is to re-run the
  guard **standalone with stderr captured**. Guard green standalone + predicate red on (b) ⇒ clerical, repair
  and re-run once. Guard genuinely red ⇒ **that is the verdict.**
- **The predicate must run from the repo root with `origin/main` freshly fetched** — `--repo` defaults to
  `process.cwd()` and clause (b) is `git -C REPO merge-base --is-ancestor`.
- **`--successor cloud-console-hardening-epic` is mandatory.** Omit it and the header still reads
  `(none filed)` while the SCOPE line interpolates bare: **`to null`** — and the run still **exits 0**. A
  forgotten flag yields a SEAL whose own disclosure says the epic was forwarded *to null*. **That is worse
  than a red.** *(A third rendering exists that GR132 did not name: a fixture omitting the key prints
  `to undefined`.)*
- **`--guard-cmd` MUST NOT appear in the terminal run.** It is a mutation-proof flag; stubbing it turns the
  epic's only pixel-level assertion into a tautology.
- **Write budget: measured, not assumed.** `bp` ignores `BARKPARK_TOKEN` entirely and always reads the single
  host `~/.config/barkpark/config.json` — **every sibling agent on this host shares one token and one global
  60/min write bucket** (`refill = 1.0/sec`, no per-verb component). A live 15-write probe at 1.1s pacing
  under concurrent sibling load: **15/15 exit 0, zero throttled**, effective ~0.52 writes/sec. Pace ≥1.1s.
  **Detect throttling by `bp`'s exit code 7 — never by text-matching "429" in a body**, which is precisely how
  round 9 burned 12 spurious epochs (the substring occurs in ordinary 200 payloads).
- **Re-parent mechanics, corrected.** Round 10 recorded that a same-parent no-op move *"still emits a
  `task.reparented` event and still burns a slot."* **The event half is false**: `Move.move/3` returns
  `{:noop, doc}` with *"no write, no event"* and never reaches `insert_mutation_event!`. **The slot half is
  true**: the rate-limit Plug bills by HTTP method before the controller runs. Moot in practice — the
  successor's 7 children have **zero overlap** with the 60, so no move in this set is a no-op.
- **`bp task move <doc_id> <new_parent_id>` takes no epoch** and needs `--yes` (a non-TTY session is refused,
  not prompted). Moving an `in_progress` row auto-bumps its `claim.epoch`; irrelevant here — `in_progress` is 0.
- **Doc gates cannot block this charter.** `check-doc-budgets.sh` contains **zero** occurrences of `.claude`;
  `docs-anchors-check.sh` prunes `.claude` by name. The blocking drift-ceiling job PR #5046 is **CLOSED and
  unmerged**, and main's only format job is advisory. **The census may be as long as honesty requires.**

### GR160 — GR150 is mechanically sound, and the self-orphan is the last thing that moves

`seal-predicate.mjs` reads `children = fetchRoster(EPIC)` = `filter[parent_id]` = **direct children only**.
The seal's sub-slices are **children of a child** and are structurally invisible to clause (a); they travel
automatically when the seal moves. **Write no move lines for them.** Proven by fixture: leaving
`gr-p5r5-successor-seal` live under the epic at run time makes it **its own orphan** and the epic cannot seal
(`UNNAMED RESIDUE (orphans): 1 · ✗ gr-p5r5-successor-seal`). **"Re-parented LAST" means last among the moves
and strictly BEFORE the run.** *(Census nit, corrected: it says both round-9 self-orphans are `done`;
`gr-p5r8-register-defect-commits` was `open` when the census was written. It is `done` now, lead-closed at
Decide — but the artifact must not repeat an unverified claim.)*

### Two charter task ids do not exist, and are corrected

Round 10's wave section names `gr-p5r10-land-defect-commits` and `gr-p5r10-terminal-run`. **Both 404.** The
real ids are **`gr-p5r8-register-defect-commits`** and **`gr-p5r5-successor-seal`**. `gr-p5r10-census` is the
one round-10 name that was real. Same class as this lead's invented `cloud-gui-remake-epic`. **Every id is
re-verified at L1 before it is passed to `bp`.**

### The wave — two slices, two rounds, no new instrument

- **`gr-p5r11-successor-charter-refresh`** (round 1, opus, **ledger-only, zero repo files**) — the successor's
  own published description under-lists **Band 3 (8 of 15)** and **Band 4 (7 of 13)** and still claims
  *"three children"* when it holds seven. It must name every row it is about to receive **before** 57 rows
  arrive, or the successor's roster is wider than its own charter and the "a row without a census line arrived
  by accident" rule cannot be applied by a reader.
- **`gr-p5r11-terminal-act`** (round 2, opus, `after: [gr-p5r11-successor-charter-refresh]`,
  `.claude/workflows/bp-cloud-gui-remake-charter.md`) — **ONE agent, ONE instant** (GR126): close the one row,
  execute 57 + 1 moves, move the seal LAST, **re-read the roster and prove 0 live**, then run the frozen
  predicate **once** and record its verbatim stdout, stderr, exit code, ISO stamp, roster count **and the
  roster delta**, whichever way it exits. **The terminal act is never split across agents** — a verdict is
  valid only at an instant, and the roster drifts.

**The ending, pre-committed.** The census is the deliverable; the exit code is only the signature. The
predicate can only ask *"does this row's parent equal the successor id"* — **a chartered successor and an
empty junk-drawer pass it identically.** That is why the honesty lives in the census, which the predicate
structurally cannot express, and why a NO SEAL is an ending and not a defect. **This epic tried to seal six
times and each round answered with a new instrument, the seal receding by one instrument per round. Round 11
answers with a verdict.**

---

## Wave 2026-07-21 — phase-5 seal round 12: THE EXECUTION (two acts, one verdict, no round 13)

**Round 11 wrote a line-exact runbook and ran nothing.** The disposition was re-derived at L1 twice more this
round — by an independent surveyor and again by a verifier — and both times `LIVE-NOT-PLANNED = []` and
`PLANNED-NOT-LIVE = []`. There is no planning left. 59 `bp task move` calls at 1.1 s is ~65 seconds; plus one
close and one predicate run the entire mechanical act is about two minutes of wall clock. **Seven rounds have
failed to spend two minutes.** Round 12 spends them.

### GR161 — the runbook contradicted itself, and the stale copy is the one a builder reads first

`gr-p5r11-terminal-act` carries the runbook **twice**. `doc.content.description` (17 121 B) and
`acceptance_criteria[6]/[9]` are **canonical and correct**. `doc.content.brief.blocks[1].content[0].value`
(16 817 B) and `brief.blocks[5].items[6]/[9]` are a **frozen earlier revision** — the two texts differ in
exactly **28 unified-diff lines across 4 hunks and nothing else**. In the raw `bp task get` output the stale
brief sits at byte 5 084 and the correct description at byte 27 099: **the poisoned copy is 22 KB earlier in
reading order.** The probable mechanism is already filed as `pds-bl-large-task-write-500` (task writes past
~5 KB hang and silently cap a brief), which means **patching the mirror cannot be trusted to stick.**

**RULING: round 12 does not patch the mirror. It files `gr-p5r12-terminal-act` with ONE authoritative runbook
field and no brief mirror at all.** A document that cannot contradict itself is cheaper than a document
repaired into agreement.

### GR162 — the stale copy's worst line is not the arithmetic, it is a path that fails SILENTLY GREEN

The stale brief cites `cloud/priv/static/preview/` in four places. **That directory does not exist**; the
instruments live at `cloud/priv/static/__preview__/`. Proven live:

    git diff --exit-code origin/main -- cloud/priv/static/preview/seal-predicate.mjs   →  exit 0

git exits 0 on a pathspec matching nothing. A builder following the brief pastes *"exit=0, both instruments
byte-clean vs origin/main"* as evidence **for the one gate whose entire job is proving the instruments were
not tampered with — having verified nothing.** The same path then yields `MODULE_NOT_FOUND` on the terminal
act itself, so round 12 would end having run nothing, for the eighth time, over a path typo. **The arithmetic
bug produces a wrong verdict; the path bug produces no verdict at all.**

### GR163 — 68, not 65; and the only number worth trusting is a difference

Live at Decide: epic `task-47bc4168392dec17` = 140 {done 80, open 60}; `cloud-console-hardening-epic` = **10**;
`task-96a908af98698118` = 46. So **10 + 57 banded + 1 self-moved seal = 68**, and the stale `7 → 65` is a
Verify-time measurement that Decide's own backlog filings invalidated. The stale copy also carries its own
copy of the embedded gate at `s["count"]>=65` — **three rows loose**: a run that moved only 55 of 58 rows
would print `GATE: PASS` and exit 0. The canonical gate asserts `>=68`.

**The invariant that binds is `after − before == 58`, true regardless of which absolute any field carries.**
Read the successor's count LIVE immediately before the moves and assert the difference.

### GR164 — the predicate has no provenance control, and "at origin/main" is a sentence it never earned

`seal-predicate.mjs:61` — `const REPO = arg('--repo') || process.cwd()` — and the guard is spawned under that
REPO; `serve.mjs` roots at `cloud/priv/static`. **Clause (b) measures the app.css sitting on disk in whatever
tree you `cd` into.** Its only contact with `origin/main` is the `--is-ancestor` commit check. Yet on failure
it prints, verbatim, *"guard exited 1 — the defect is still measurable at origin/main"*.

Fired twice this round, both on verified-free ports:

| run from | clause (b) |
|---|---|
| the repo root — *what the round-11 runbook literally says* | **RED on all three** |
| a pristine detached worktree | **GREEN on all three**, `OVERFLOW GUARD PASS … measured fixed in a real browser` |

The primary checkout is 9 commits behind origin/main **and** carries an uncommitted, unowned `app.css` edit
that deletes the GR108 rule outright (`.topbar-right > * { min-width: 0 }` exists at app.css:787 on main and
has zero occurrences locally). Correct code, correct guard, **wrong bytes**. This is a **third** clause-(b)
failure mode beside the port squat and a genuine regression, and it is textually identical to both — because
the predicate captures the guard's stderr and reads only `r.status`.

**RULING: the terminal act runs from a PRISTINE DETACHED WORKTREE, never from the repo root.** The disarm is a
`cd`, not an instrument.

### GR165 — the charter fork is closed by cutting the worktree at the charter commit, not at origin/main

GR154–GR160 exist only in unpushed commit `1ccf6206a` on the primary checkout's local main. A builder cutting
from `origin/main` gets green pixels and **dangling GR157/GR160 citations**; a builder using the repo root
gets resolving citations and a **false red**. Neither side is clean — and the charter-marker gate cannot tell
them apart, because it is a four-substring *post-append presence* check whose other three markers already
exist in both copies (pre-append both FAIL identically on the one marker naming the terminal-artifact heading;
post-append both PASS). *This charter deliberately never writes that marker string in full — doing so would
pre-satisfy the gate and hand the builder a vacuous green before it appended anything.*.

**RULING: the builder cuts its worktree at the round-12 charter commit** — which contains `1ccf6206a`, is
byte-identical to `origin/main` on `cloud/priv/static/app.css` and on `cloud/priv/static/__preview__/`
(`git diff --stat HEAD origin/main -- <those paths>` is empty), and carries GR154–GR168. **Both columns are
satisfied at once. Do not strengthen the marker gate; that would be the eighth instrument.**

### GR166 — clause (a) will red on 58, not 60, and bucket (c) will flip two flags on purpose

The predicate buckets the two permanent human gates **before** the orphan count, so 60 live = **58 orphans +
2 gated + 0 forwarded**. *An artifact that says "60 orphans" contradicts the banner the run actually printed.*
And after the moves, the bucket-(c) lines for `gr-ops-platform-admin-emails` and `gr-backlog-qr-live-scan-proof`
flip `in-epic-roster=true → false`. **That is informational output, not a regression** — `resolved` only
requires the doc to exist. A builder who reads that flip as a failure will abort a successful run.

`cloud-console-billing-live-gate` resolves parent-independently via `filter[_id]`, confirmed live at the exact
required string: `✓ cloud-console-billing-live-gate  status=open parent=cloud-console-goal in-epic-roster=false`.

### GR167 — the shell shape is load-bearing: `&&/||` can fabricate a verdict

Observed live: `lsof … && echo 'PORT BUSY' || node seal-predicate.mjs …; echo "EXIT=$?"` printed **`EXIT=0`
with zero stdout, having started no process** — `$?` was the echo's. That is the precise signature GR133
defines as a crash, arriving from a command that never ran. **Use an explicit `if … then exit 9; fi` guard.**
Ports are actively contested (4199 held by orphaned pid 92003 for 7 h; 4241 went free→busy→free inside 60 s
under sibling `serve.mjs` instances). **Pick from the 47xxx band and re-verify immediately before spawning.**

Two more hard-won mechanics for STEP 1: `criteria_mismatch` **exits 2, not 1** — branch on the JSON
`error.code`, never the exit code. Criterion [0] contains a literal **U+2014 em dash**; extract the criterion
strings programmatically from `bp task get`, never retype them. A `criteria_mismatch` 409 was proven by
mutation to write **absolutely nothing** (rev byte-identical before and after, claim survives, same epoch
re-closes cleanly), so a retry is safe and needs no re-claim. **Reserve the pre-authorised
close→forward fallback for a server-side refusal, never for a client-side typo.**

### GR168 — GR157 caveat 4 must NOT be transcribed verbatim; here is the corrected mechanism

GR157's fourth caveat asserts *"zero deploy scripts reference it, so no commit can set it."* The second half
holds; **the first half is falsified on main by `cloud/docker-compose.yml:67`**, which bare-lists
`PLATFORM_ADMIN_EMAILS` as a valueless passthrough — landed as GR60 step 1 and recorded DONE by GR68 **in this
same charter.** Transcribing it verbatim publishes a claim the charter itself contradicts.

**The sentence the artifact uses instead, every clause read from source:**

> The crown is DARK, structurally. `cloud/docker-compose.yml:67` bare-lists `PLATFORM_ADMIN_EMAILS` as a
> **valueless passthrough**; `cloud/.env.example:51` ships it empty; `cloud/config/runtime.exs:314` defaults it
> to `""` → `[]`. The only value source is `/opt/barkpark/cloud/.env`, which is **not tracked by git — so no
> commit can set it.** `Notifications.platform_admin_emails/0` additionally drops any address without a
> registered user. `Auth.require_platform_operator/2` runs `require_user` **first**, so an anonymous probe gets
> **401** and every authenticated user gets **403** — the console is dark for everyone, not selectively lit.
> This is a MECHANISM read from source; no live body was observed. **"Seal" here means CODE seal only.**

And the other disclosure the banner cannot make: **"one named false-done" is a FLOOR, not a ceiling.** No full
80-row done-set audit was ever completed — the only prior audit covered 35/56, predates the discovery of
`gr-blk-shootsh-scen-suggester`, and `gr-bl-doneset-merge-sha-reaudit` is OPEN saying to treat the done-set as
UNCHECKED. Say it in those words. `gr-blk-studio-presence-perf-flake` leaves the epic **without arriving at
the successor**, and the predicate — reading only `(_id, lifecycle_status, parent_id)` — is blind to it in
both places. Name it.

### The wave

One slice. One opus builder. One claim. `gr-p5r12-terminal-act` — execute the census, run the frozen
predicate LAST and ONCE from a pristine worktree, and append the terminal-artifact section under a heading carrying the marker string the gate looks for. **Exit 0 and exit 1 are
equally acceptable endings; the deliverable is a `VERDICT:` line and a roster-delta table a cold reader can
act on. There is no round 13.**

---

## THE TERMINAL ARTIFACT — round 12, the act executed and the verdict taken

The Cloud GUI Remake attempted to seal seven times. Round 11 wrote the runbook and ran nothing. Round 12 ran
it. This section is the whole ending: the two mechanical acts, the one predicate run, and what the green does
and does not mean. **No eighth instrument was built.** `seal-predicate.mjs` and `overflow-guard.mjs` are
byte-identical to `origin/main` at the end of this run, no `KNOWN_DEFECT` was added, no threshold was moved,
no `--ledger` or `--guard-cmd` was passed, and the only file changed by this commit is this charter.

### Where it ran, and why that decided the verdict

`seal-predicate.mjs:61` is `const REPO = arg('--repo') || process.cwd()`, and the overflow guard serves
`cloud/priv/static` **from disk**. Clause (b) therefore measures whatever tree you `cd` into, while printing
the sentence *"the defect is still measurable at origin/main"* — a claim it has not earned. This run was made
from a worktree cut at charter commit `d06f78eba`, never from the primary checkout.

Pre-flight, all four outputs:

```
git status --porcelain                              -> (empty)
wc -l < .claude/workflows/bp-cloud-gui-remake-charter.md  -> 1690
test -f cloud/priv/static/__preview__/seal-predicate.mjs  -> EXISTS
test -f cloud/priv/static/__preview__/overflow-guard.mjs  -> EXISTS
git diff --exit-code origin/main -- cloud/priv/static/__preview__/seal-predicate.mjs  -> exit 0
git diff --exit-code origin/main -- cloud/priv/static/__preview__/overflow-guard.mjs  -> exit 0
git diff --stat HEAD origin/main -- cloud/priv/static/app.css cloud/priv/static/__preview__/  -> (empty)
```

The `test -f` lines are not decoration. `cloud/priv/static/preview/` (no underscores) does not exist, and
`git diff --exit-code` returns **0** on a pathspec matching nothing — a vacuous green at the one gate that
exists to catch a tampered instrument. Existence is proven before the freeze check is believed.

### The port guard

`OVERFLOW_GUARD_PORT=47311`, proven free by an explicit `if … then exit 9; fi` guard and re-verified in the
second before spawning:

```
PORT 47311 VERIFIED FREE at 2026-07-21T03:29:11Z      (standalone guard warm-up: exit 0, stderr 0 bytes)
PORT 47311 RE-VERIFIED FREE at 2026-07-21T03:29:26Z   (predicate spawn)
```

The `&&/||` shape was not used. It was observed printing `EXIT=0` with zero stdout having started no process —
a fabricated verdict wearing the signature of a GR133 crash.

### The two mechanical acts

**One close.** `gr-backlog-bp-search-verb-discoverability` — declared closed by the round-10 census on merge
SHA `3f16c9f43`, but the ledger action was never executed. It read open 0/3, unclaimed, still under the epic.
Claimed and closed **done 3/3** on the first attempt; the pre-authorised close→forward fallback did **not**
fire, so there is no substitution to disclose. Criterion strings were extracted programmatically from
`bp task get -o json` (criterion [0] carries a literal U+2014 em dash; a retyped hyphen burns an attempt).
`git merge-base --is-ancestor 3f16c9f43 origin/main` exits 0.

Criterion 1's evidence is freshly captured CLI output, and it **corrects** what the task predicted. There is
no unknown-SUBcommand error state: because `search` has exactly one verb, `soleReadVerb`
(`internal/cli/cli.go:549,565`) absorbs the unknown token as a search *term*.

```
$ bp search zzznotasub          # unknown SUBcommand
note: `search` has one verb — running `barkpark search query`
{"correctedTo":null,"count":0,"documents":[], … "query":"zzznotasub" …}

$ bp zzznotacommand             # unknown COMMAND
{"error":{"code":"usage","message":"unknown command \"zzznotacommand\""},"ok":false}
```

The two are distinct in **kind**, not merely in wording — which is a stronger result than the criterion asked
for. Criterion 2's doctrine anchor is `origin/main:.claude/agents/felix.md:61`, which cites
`bp search <concept>` **without** the word `query`: `3f16c9f43` made a pre-existing doctrine sentence true.

**Fifty-nine moves — fifty-eight of them successor-bound.** One to `task-96a908af98698118`, fifty-seven in
census band order to `cloud-console-hardening-epic`, and `gr-p5r5-successor-seal` **last** into the same
successor — its children rode along, and no move line was written for them. The two counts are easy to
conflate and the roster delta below depends on keeping them apart: **58** is the successor-bound figure that
the `after − before == 58` invariant binds, **59** is the number of rows that left the epic.
`cloud-console-billing-live-gate` was never named; its parent stays
`cloud-console-goal`. Every move was paced ≥1.1 s and its response checked. Throttling was detected by `bp`
**exit code 7** only, never by grepping output for `429` (that substring occurs in ordinary 200 payloads).
**Zero exit-7 retries occurred.** One non-zero return is disclosed honestly: the first attempt at
`gr-bl-peer-ip-container` returned **rc=2**, `bp: piped stdin is unused and task move does not accept --file` —
a client-side harness fault from a `while read` loop feeding stdin, not a server refusal and not a throttle.
It wrote nothing; the loop was re-run with `</dev/null` and the move succeeded.

Before the predicate ran, the roster was re-read via `filter[parent_id]`: **81 children, `{"done":81}`,
zero live rows.** The successor's BEFORE count was read live immediately before the first write — **10**, not
the 7 measured at Verify — and after the moves it read **68**. The binding invariant held: `after − before == 58`.

### The run

Once. Last. `--successor cloud-console-hardening-epic`, no `--ledger`, no `--guard-cmd`.

**exit code: `0`**  ·  **stderr: 0 bytes**  ·  ISO stamp copied from the predicate's own `read at` line:
**`2026-07-21T03:29:26.196Z`**  ·  roster count from the banner: **81 children `{"done":81}`**

Verbatim stdout:

```
=== SEAL PREDICATE — Cloud GUI Remake phase 5 ===
read at 2026-07-21T03:29:26.196Z  (live ledger)
epic task-47bc4168392dec17   successor: cloud-console-hardening-epic
roster: 81 children  {"done":81}

CLAUSE (a) forwarding — live rows 0
  forwarded under successor : 0
  permanent human gate      : 0  [-]
  UNNAMED RESIDUE (orphans) : 0

BUCKET (c) permanent human gates
  ✓ cloud-console-billing-live-gate  status=open parent=cloud-console-goal in-epic-roster=false
  ✓ gr-ops-platform-admin-emails  status=open parent=cloud-console-hardening-epic in-epic-roster=false
  ✓ gr-backlog-qr-live-scan-proof  status=open parent=cloud-console-hardening-epic in-epic-roster=false

CLAUSE (b) known user-facing defects — 3 registered
  ✓ GR108-tablet-topbar-overflow
  ✓ GR109-attention-row-dead-rule
  ✓ GR115-bpconsole-dead-rule

VERDICT: SEAL

SCOPE — what this green does and does NOT claim, read at 2026-07-21T03:29:26.196Z:
  Sealed 81 children: 81 evidence-closed, 0 forwarded by name
  to cloud-console-hardening-epic, and 3 permanent human gate(s) disclosed by hardcoded name.
  Zero unnamed residue. Zero known user-facing defect, each re-measured in a browser.

  NOT asserted by this green:
   1. Defect coverage is bounded by what was REGISTERED. Clause (b) certifies the word
      KNOWN over 3 hand-registered defects. A defect nobody looked for is invisible to it.
   2. The overflow sweep covered 86/86 scenarios x 2 themes at 768px (default accent),
      plus 12/86 scenarios x 5 accents. NOT swept: 74 of 86 scenarios under the four non-default accents; widths other than 768 outside the 721-1440 band measured on the two past-due screens only.
   3. 21 clean-CAS children are sealed on evidence nobody read. 0 of 39 checked failed,
      which bounds the true material-failure rate at ~8% upper 95% — so up to ~2 of the 21
      may carry one. They are enumerated BY NAME in the charter, not described as a subtraction.
   4. The crown is DARK. The operator console shipped fully built and unreachable;
      gr-ops-platform-admin-emails is a human act. "Seal" here means CODE seal, never
      "this feature is live for any human".
```

### VERDICT: SEAL — and what that word is worth

`VERDICT: SEAL`, exit code 0, stderr 0 bytes. This is a **CODE seal**. It is not a claim that any human can
use the operator console, and it is not a claim that the done-set is clean. Both of those are addressed by
name below, because the banner cannot address them at all.

### The roster delta

The banner reads *"Sealed 81 children: 81 evidence-closed, **0 forwarded by name**"*. Read alone, that
sentence says nothing was forwarded — which is exactly backwards. The banner's `fwd` counter only counts
forwarded rows **still in the epic roster**, so a *perfect* triage drives it to zero. The roster delta is the
only place the 58 forwards are visible:

| roster | before | after | delta |
| --- | --- | --- | --- |
| epic `task-47bc4168392dec17` | 140 children / **60 live** | 81 children / **0 live** | −59 children, −60 live |
| successor `cloud-console-hardening-epic` | 10 | **68** | **+58** (57 banded + the self-orphaned seal) |
| `task-96a908af98698118` | 46 | **47** | +1 |
| `gr-backlog-bp-search-verb-discoverability` | open 0/3, under the epic | **done 3/3**, under the epic | closed, not forwarded |

The epic loses 59 children while losing 60 live rows because one of the 60 was *closed in place* rather than
moved. Clause (a) printed **58 orphans, not 60**: the predicate buckets the two permanent human gates before
the orphan count. Bucket (c) shows `gr-ops-platform-admin-emails` and `gr-backlog-qr-live-scan-proof` with
`in-epic-roster=false`, flipped from `true` by the moves. That flip is **informational, not a regression** —
`resolved` only requires the doc to exist.

**`gr-blk-studio-presence-perf-flake` left the epic without arriving at the successor.** It went to
`task-96a908af98698118`, its real home per the census. The predicate reads only
`(_id, lifecycle_status, parent_id)`, so it is **invisible in both places**: the epic-side roster is empty and
the successor-side count never includes it. Its only trace is the census line and this table. A cold reader
looking for it in either the seal banner or the successor's 68 will not find it.

### The crown is dark — a mechanism, not an observation

> The crown is DARK, structurally. `cloud/docker-compose.yml:67` bare-lists `PLATFORM_ADMIN_EMAILS` as a
> **valueless passthrough**; `cloud/.env.example:51` ships it empty; `cloud/config/runtime.exs:314` defaults it
> to `""` → `[]`. The only value source is `/opt/barkpark/cloud/.env`, which is **not tracked by git — so no
> commit can set it.** `Notifications.platform_admin_emails/0` additionally drops any address without a
> registered user. `Auth.require_platform_operator/2` runs `require_user` **first**, so an anonymous probe gets
> **401** and every authenticated user gets **403** — the console is dark for everyone, not selectively lit.
> This is a MECHANISM read from source; no live body was observed. **"Seal" here means CODE seal only.**

That paragraph is GR168's correction, used deliberately in place of GR157's caveat 4, whose clause "zero
deploy scripts reference it" is falsified on main by `cloud/docker-compose.yml:67` — a line this same charter
records as DONE at GR68.

### One named false-done — a FLOOR, not a ceiling

`gr-blk-shootsh-scen-suggester` is a known false-done in the sealed 81. Its sole evidence is unpushed branch
commit `8a1545bd7` (`--is-ancestor` exits 1, `git branch -r --contains` is empty), and `origin/main`'s
`shoot.sh` has zero occurrences of the described near-match ladder. **It is not reopened here** — reopening
would create a live orphan and turn a real green into a clerical NO SEAL.

**"One named false-done" is a FLOOR, not a ceiling.** No full 80-row done-set audit was ever completed. The
only prior audit covered **35/56**, and it predates the discovery of this row. `gr-bl-doneset-merge-sha-reaudit`
is **OPEN**, and it says to treat the done-set as **UNCHECKED**. The correct reading of clause (a) is
"81 rows carry a close record", never "81 rows were verified".

### The four SCOPE caveats

They printed, because the run exited 0 — they are in the verbatim stdout above, and they are the honest
boundary of this green. In short: coverage is bounded by what was **registered** (3 hand-registered defects);
the overflow sweep covered 86/86 scenarios × 2 themes at 768px plus 12/86 under 5 accents, leaving 74 of 86
unswept under the four non-default accents and **widths other than 768 outside the 721–1440 band measured on
the two past-due screens only**; 21 clean-CAS children are sealed on evidence nobody read, bounding the true
material-failure rate at ~8% upper 95%; and the crown is dark.

### Instrument freeze, re-checked at the end of the run

```
git diff --exit-code origin/main -- cloud/priv/static/__preview__/   -> exit 0   (files proven present)
```

### Reviewer's independent reproduction — the seal is not one tree's accident

The builder's own first doubt was that the green is **base-relative**: `seal-predicate.mjs:61` reads
`process.cwd()`, so a green proves the tree it was run from and nothing else. That doubt is now closed by a
second, independent run.

At review, the predicate was re-run from a **different worktree** (the reviewer's, cut at the branch tip
`19b526c66` — the actual merge candidate, not `d06f78eba`), on a **different port** (47313, cleared by the
same explicit `if … exit 9` guard), by a **different agent**, seven minutes later, with a fresh
`git fetch origin` first:

```
git status --porcelain                                             -> (empty)
git diff --exit-code origin/main -- cloud/priv/static/__preview__/ -> exit 0   (after fresh fetch)
OVERFLOW_GUARD_PORT=47313 node cloud/priv/static/__preview__/seal-predicate.mjs \
    --successor cloud-console-hardening-epic
  -> VERDICT: SEAL   ·   exit 0   ·   stderr 0 bytes   ·   read at 2026-07-21T03:36:31.029Z
     roster: 81 children {"done":81}   ·   clause (a) 0 orphans   ·   bucket (c) 3/3   ·   clause (b) 3/3
```

The banner was identical to the builder's line for line apart from the timestamp. This also closes doubt 5
(instrument freeze measured against a possibly-stale `origin/main`): the freeze was re-checked after a fresh
fetch and still exits 0. The merge candidate itself seals.

### Clause (b) is a live measurement — proven by mutation, not by trust

A green is worthless unless the right thing produced it, so clause (b) was attacked directly. With
`.topbar-right > *` forced to `min-width: 400px` in `cloud/priv/static/app.css`, the guard reported:

```
OVERFLOW GUARD FAIL — 44 finding(s) in: GR108-tablet-topbar-overflow
  ✗ overview-past-due/dark@769: scrollWidth 1932 > viewport 769 — horizontal scrollbar
```

Chrome 150 launched, the server logged *"served bytes == disk bytes"*, and real `scrollWidth`/`clientWidth`
numbers moved with the CSS. Clause (b) renders and measures; it is not a rubber stamp. `app.css` was restored
and re-verified byte-identical to `origin/main` before this section was written.

**One honest surprise from that probe, recorded rather than buried.** Setting `.topbar-right > *` to
`min-width: auto` — which is exactly *removing* the landed GR108 fix, since `auto` is the flex-item default —
did **not** reproduce the overflow: the guard still measured 0/44 with the chip at 169.78px. The GR108 defect
is therefore **over-determined** at `origin/main`: some other landed rule (most likely the `min-width: 0` on
`.topbar-left, .topbar-right` themselves at `app.css:776`) independently prevents it at these widths, so the
child rule is belt-and-braces rather than the sole load-bearing fix. This does not weaken the seal — the
defect is measured absent, which is what clause (b) certifies — but it means the charter's causal story
("the CHILDREN escape because they are flex items at the default `min-width:auto`") is **not the whole
mechanism** at the tree that shipped. Filed as `gr-bl-gr108-fix-overdetermined`, not fixed here: touching
`app.css` at the seal would have been the eighth instrument by another name.

The epic ends here. There is no round 13.


## Reconciliation Wave 2026-08-18 — the deferred audit discharged, the epic thinned to a holder
Wave Paper: `cloud-gui-remake-wave-2026-08-18`. This is NOT round 13 — the round-12 CODE seal stands untouched. It is a post-seal RECONCILE-AND-CHARACTERIZE pass that finally discharges the epic's one un-discharged promise (the GR112 done-set audit), states the true residue with evidence, and thins the epic to a thin holder. Builder model: **opus on both slices** (Fable capped until Aug 21). Almost entirely bp-ledger writes plus this docs-only charter PR. Zero code builds — the honest A-grade outcome, because no open row is an offline-buildable above-bar defect.
- **GR169 — The census is re-derived and unanimous; child_count is a Felix-w31 phantom.** Five surveyors plus the Decide re-derivation agree: `task-47bc4168392dec17` carries child_count=82 but the true lifecycle split is **76 done / 2 cancelled / 4 open / 0 considering**. Every done row has criteria met==total; zero lifecycle-vs-criteria mismatch; zero mis-parentage in either direction (all 82 doc_ids are `gr-*` or `task-*` — no foreign prefix hides here, and no native row belongs elsewhere). The four open rows are one GR112 audit meta-task plus three below-bar instrument-hygiene rows. None is an above-bar, user-facing, offline-buildable GUI defect.
- **GR170 — The GR112 audit is RUN FOR REAL and `gr-blk-false-done-audit-closed-children` closes only on genuine full-enumeration evidence.** The verify fleet already deep-audited the two blind-spot strata to zero: the 8 CAS-bypass rows (weakest attribution, audited first — all four cited merge SHAs `09735e96b`/`37304602f`/`32e6395a7`/`b9cb9b04a` are ancestors of `origin/main`, every named symbol true today) and the 21 unread clean-CAS rows the seal admitted "nobody read" (0/21 material failures). Slice 1 completes the enumeration over the remaining clean-CAS + no-claim rows under GR112's frozen material-failure definition and closes gr-blk on that per-row evidence. A ruling-close of a full-enumeration audit is itself the false-done sin (gr-blk's own prior close_reason says so) and is FORBIDDEN. Expected honest outcome: 0 material failures, 0 reopens — SEAL CLEAN stands and the residue no longer rests on unread evidence.
- **GR171 — For a POST-SEAL reconcile wave, reopen-with-evidence GOVERNS; GR112's "never a mid-wave reopen" was seal-scoped.** GR112's no-reopen invariant (line 148) protected an INSTANTANEOUS seal denominator — a mid-wave reopen would mutate the count being certified (the documented roster-drift hazard). That scope expired at the seal; nothing downstream is certifying this set at an instant now, and house false-done doctrine favours reopen-with-evidence. So a failing row is REOPENED with its specific material-failure evidence, count stated even if zero. Guardrail preserving GR112's real concern: enumerate the closed set FRESH at one read before touching anything, so a reopen never races a live roster mutation.
- **GR172 — The three below-bar rows are characterized and RE-HOMED to `cch-instruments-epic`, not fixed.** `gr-blk-studio-presence-perf-flake` (false-RED-only wall-clock flake at `studio_live_sheet_presence_test.exs:321`; ran 0.0–9.05ms quiet, structurally no false-GREEN), `gr-blk-shootsh-scen-suggester` (cosmetic empty-header at `shoot.sh:145-154`, never a false green; fix `8a1545bd7` not on main), and `gr-p5r7-badcode-shot-nondeterministic` (blinking caret at `app.js:1359`, NOT the byte-matched QR SVG at `app.js:22484`) are each stamped with their mutation-provable diagnosis and moved via `bp task move` to their live owner `cch-instruments-epic` ("keep the measuring equipment honest"), every move verified by re-reading `parent_id` (Felix-D211). The escape hatch is DECLINED: both cheap fixes are below-bar by the seal law's own definition, and building below-bar polish would risk the verify-floor refusing a vacuous build. Spin-with-diagnosis-to-a-named-live-owner is honest debt transfer, not laundering.
- **GR173 — SEAL-AND-SPIN: the epic is a thin holder with zero open rows of its own.** After Slice 1 (gr-blk closed) and Slice 2 (three rows re-homed), the epic carries 0 open children. The true residue: **0 offline-buildable above-bar defects**; **3 below-bar** (spun to `cch-instruments-epic`, open); **3 human/prod-gated** already spun out correctly — `gr-ops-platform-admin-emails` (the crown is dark — a prod `.env` append + restart, fail-closed by construction on origin/main) and `gr-backlog-qr-live-scan-proof` on `cloud-console-hardening-epic`, and `cloud-console-billing-live-gate` deliberately on `cloud-console-goal` (invisible to any epic-children census — counted by id). The GUI-remake foundation (phases 1–5) is DONE with evidence: prod `app.css` byte-identical to `origin/main` (sha256 `150f842e…`), GR73's swallowed `.modal-root` fixed and live, 76 done rows re-audited to 0 material failures. The epic seals as a thin holder; it remains open only as the re-home accumulator.
### The two slices (round 1, opus, ledger-only — no PR, each proven by a bp read-back)
| slice | task id | what it does | gate |
| --- | --- | --- | --- |
| 1 — discharge the audit | `gr-blk-false-done-audit-closed-children` | full-enumeration GR112 re-audit of the 76-done set (CAS-bypass first), reopen-per-GR171, close on genuine evidence | `bp task get` shows lifecycle=done, 4/4 criteria met with per-row evidence |
| 2 — re-home the below-bar rows | `gr-r-rehome-belowbar-instruments` | stamp diagnosis + `bp task move` the three rows to `cch-instruments-epic`, verify by re-reading parent_id | `bp task get` on all three shows parent=cch-instruments-epic, lifecycle=open |
The charter PR carries this run's three ledger recipes under `tooling/grip/ledger/` (the 2026-08-18 CAS/unread-cleancas, perf-flake-run, and residue-parentage-pin rows). Wave referent for the pr-task-gate: `cloud-gui-remake-wave-2026-08-18-log`.
---

## RECONCILIATION WAVE — 2026-08-18 (post-seal characterize-and-spin; NOT round 13)

The seal was a CODE seal that deferred exactly one promise: GR112's semantic re-audit of the done set (~21 clean-CAS rows "sealed on evidence nobody read"). This is not a build round — it is the reconcile that discharges that promise, characterizes the below-bar residue, and spins it to its live owner. Six surveyors + a deep verify fleet ran the census and the audit for real. Wave Paper: `cloud-gui-remake-wave-2026-08-18`. Wave referent: `gr-wave-reconcile-2026-08-18-log`.

### GR169 — Census closed: the true open count is 4, not child_count 82.

`bp task get task-47bc4168392dec17` reports `child_count 82`, but the enumerated lifecycle split is **76 done / 2 cancelled / 4 open / 0 considering** — the Felix-w31 child_count-vs-open gap. Six independent surveyors + Digest's re-derivation agree; zero lifecycle-vs-criteria mismatch across all 82. The 4 open = one GR112 audit meta-task (`gr-blk-false-done-audit-closed-children`, 0/4) + three below-bar instrument-hygiene rows (`gr-blk-studio-presence-perf-flake`, `gr-blk-shootsh-scen-suggester`, `gr-p5r7-badcode-shot-nondeterministic`). No mis-parentage in either direction — all 82 are `gr-*`/`task-*`, zero foreign prefixes. Named successors + crown-dark already spun correctly to `cloud-console-hardening-epic` / `cch-instruments-epic` / `cloud-console-goal`. GR73's modal-root crown fix is byte-identical prod==origin/main (`app.css` sha256 150f842e…, 329779 B), so no above-bar user-facing defect survives.

### GR170 — The audit is discharged FOR REAL, never by ruling.

The verify fleet ran GR112's two hardest strata to **zero material failures**: the 8-row CAS-bypass cohort (weakest attribution, audited first and separately — all four cited merge SHAs ancestors of origin/main, every named symbol live) and the 21 unread clean-CAS rows (the seal's admitted blind spot — a full enumeration, 0/21). The audit slice is `gr-blk-false-done-audit-closed-children` itself: a builder claims the row (re-claiming on a fresh epoch — it carries a stale epoch-1 closed-claim), completes the full enumeration over the remaining clean-CAS + no-claim rows, confirms the verified 29, and closes it on genuine per-row evidence. A ruling-close of a full-enumeration criterion on a sample IS the false-done sin `gr-blk` exists to catch (its own drafted close_reason says so) — forbidden. Reopen any failure with GR112-material evidence; state the reopened count even if zero.

### GR171 — Post-seal, REOPEN governs, not GR112's no-mid-wave-reopen.

GR112 line 148's "a finding becomes a successor task, NEVER a mid-wave reopen" was **seal-scoped** — it kept the certified denominator stable during an instantaneous seal verdict (the `gr-p5r7` roster-drift hazard). The epic is already sealed; nothing downstream certifies an instantaneous count over this set, and house false-done doctrine (the 11-fake-done finding `gr-blk` exists for) favors reopen-with-evidence. Reopen governs, preserving GR112's real safety three ways: (a) enumerate the closed set fresh at one read before touching anything; (b) stamp each reopen with GR112's frozen material-failure definition — cited artifact absent on origin/main, OR the criterion's user-visible claim false at origin/main today; (c) fall back to name-and-forward only if a concurrent wave is certifying this same set — none is.

### GR172 — The three below-bar rows re-home to cch-instruments-epic; the escape hatch is declined.

The three open instrument-hygiene rows are BELOW-BAR by the seal law's own definition — each verified live-on-main, false-RED-or-cosmetic-only (never a false green), offline-fixable but not user-facing GUI defects. Slice `gr-r-rehome-belowbar-instruments` re-homes all three to their true live owner `cch-instruments-epic` ("keep the measuring equipment honest," open, 254 children), the verify fleet's diagnosis stamped on each: perf-flake is false-RED only (peak 9.05ms on a quiet host, budget<10 at `studio_live_sheet_presence_test.exs:321` — NOT `validation_perf_test.exs`, which asserts shape not timing); shoot.sh returns an empty suggestion for a no-hyphen typo at `shoot.sh:152` (fix `8a1545bd7` not on main, abort exit-1 preserved); badcode is blinking-caret nondeterminism at `app.js:1359`, NOT QR-canvas (the QR is deterministic SVG byte-matched to `__qr_fixture.json`). Each move is verified by re-reading `parent_id` (Felix-D211) — honest debt-transfer-with-diagnosis to a named live owner, not laundering. **The escape hatch is declined: NO feature builds this wave** — both cheap fixes (perf-budget widening; shoot.sh edit-distance fallback) are below-bar by the seal law's own definition, building below-bar polish would dilute the wave's real value and risk the verify-floor refusing a vacuous build, and they are optional polish the new owner may take.

### GR173 — SEAL-AND-SPIN: the epic becomes a thin holder.

After `gr-blk` closes (GR170) and the three rows re-home (GR172), the epic holds **0 open children of its own**. **True residue (this epic's own, post-wave):** 0 offline-buildable above-bar defects · 3 below-bar offline-buildable (spun to `cch-instruments-epic`) · 3 design/human-gated already spun (`gr-ops-platform-admin-emails` + `gr-backlog-qr-live-scan-proof` on `cloud-console-hardening-epic`; `cloud-console-billing-live-gate` on `cloud-console-goal`) · 1 live-prod-gated (`gr-ops-platform-admin-emails` = human `.env` append + restart). **Convergence verdict: SEAL-AND-SPIN.** Phases 1-5 are DONE with evidence — 76 done rows re-audited to 0 material failures, GR73 crown fix live byte-for-byte, no above-bar defect survives. Keep `task-47bc4168392dec17` as a thin holder; its residue lives entirely on live sibling owners (the deferred seal act is tracked by `gr-recon-seal-and-spin`, a lead/human gate). Slices `gr-blk-false-done-audit-closed-children` + `gr-r-rehome-belowbar-instruments` (both round 1, opus). There is still no round 13; there is now an honest ledger.

### Wave 2026-08-18 — REVIEW debrief: reconcile wave built + reviewed, grade A

Both ledger-only slices green, reviewed adversarially against live bp state and the pasted git evidence, ledger-audited. No code was fixed — there is no code surface; the wave is bp writes plus two receipt files. Gates pass on the final state. Paper `cloud-gui-remake-wave-2026-08-18` holds the full debrief.

- **Slice 1 — `gr-blk-false-done-audit-closed-children`** → `loop-epic/discharge-the-deferred-gr112-done-set-au-0-r`, no fixes. The deferred GR112 full enumeration is discharged on genuine per-row evidence, never a ruling-close: one fresh read gave 76 done / 2 cancelled / 4 in_progress (the 4 in_progress are this wave's own rows — zero stale-open backlog), all 76 done rows checked against GR112's frozen material-failure definition with pasted `git merge-base --is-ancestor` / `git cat-file -e` output vs origin/main. 0 material failures, 0 reopens — SEAL CLEAN stands. `gr-blk` closed done, 4/4 criteria. Review independently re-derived the split (now 77 done, gr-blk self-closed), re-confirmed ancestry of `09735e96b`/`dcd80b36b`, and confirmed the subtle non-ancestor-but-present case (`79a50a7af` not an ancestor yet `seal-predicate.mjs` present on main — correctly NOT material). Recipe: `tooling/grip/ledger/cch-gr112-doneset-full-reaudit-2026-08-18.md` (rides this PR).
- **Slice 2 — `gr-r-rehome-belowbar-instruments`** → `loop-epic/re-home-the-three-below-bar-instrument-h-1-r`, no code fixes. The three below-bar rows each carry their mutation-provable diagnosis stamped into `content.description` (append-guarded, read back), then re-parented to `cch-instruments-epic` via the rail-l3 `bp task move` verb, each verified by re-reading `doc.parent_id`. Gate green: all three read parent=cch-instruments-epic, lifecycle=open. Receipt: `tooling/grip/ledger/cch-gui-remake-rehome-belowbar-2026-08-18.md`. Review ledger fix: slice-2 criterion 2 ("no row closed or code-fixed") was verifiably true but left unstamped — stamped met on the audit.

Grade **A**. The audit is the real thing — full enumeration at one fresh read, pasted git checks, CAS-bypass cohort first, the one tricky non-ancestor row reasoned correctly. Honest markers throughout (the 13-vs-8 CAS-bypass count note, reopen count stated plainly as zero). Not A+ only because a reconcile wave has no build surface, so the ceiling is bounded. No above-bar defect survived the census; nothing was built and nothing should have been. **Next wave: nothing to build here** — the epic is a thin re-home accumulator with 0 open children of its own; `cch-instruments-epic` disposes of the three below-bar rows. NB for the lead: this is the canonical charter PR (#12202); the earlier #12201 (branch `…-recon-20260818T050247Z`) is a stale duplicate carrying an earlier debrief draft and should be closed unmerged.
### GR172 — SEAL-AND-SPIN: the epic becomes a thin holder.
The three open instrument-hygiene rows are BELOW-BAR by the seal law's own definition — each verified live-on-main, false-RED-or-cosmetic-only (never a false green), offline-fixable but not user-facing GUI defects. Slice `gr-recon-rehome-instruments` re-homes all three to their true live owner `cch-instruments-epic` ("keep the measuring equipment honest," open, 254 children), the verify fleet's diagnosis stamped on each: perf-flake is false-RED only (peak 9.05ms on a quiet host, budget<10 at `studio_live_sheet_presence_test.exs:321` — NOT `validation_perf_test.exs`, which asserts shape not timing); shoot.sh returns an empty suggestion for a no-hyphen typo at `shoot.sh:152` (fix `8a1545bd7` not on main, abort exit-1 preserved); badcode is blinking-caret nondeterminism at `app.js:1359`, NOT QR-canvas (the QR is deterministic SVG byte-matched to `__qr_fixture.json`). Each move is verified by re-reading `parent_id` (Felix-D211) — honest debt-transfer-with-diagnosis to a named live owner, not laundering. **NO feature builds this wave** — no open row is an offline-buildable ABOVE-BAR defect; the two cheap fixes (perf-budget widening; shoot.sh edit-distance fallback) are optional polish the new owner may take. After `gr-blk` closes and the three rows re-home, the epic holds **0 open children of its own**.
**Convergence verdict: SEAL-AND-SPIN.** Phases 1-5 are DONE with evidence — 76 done rows re-audited to 0 material failures, GR73 crown fix live byte-for-byte, no above-bar defect survives. Keep `task-47bc4168392dec17` as a thin holder; its residue lives entirely on live sibling owners. Slices `gr-recon-audit-discharge` + `gr-recon-rehome-instruments` (both round 1, opus). There is still no round 13; there is now an honest ledger.
