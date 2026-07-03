# Barkpark Cloud Epic Charter — Peak Aesthetics, UX and DX

Wish: "Reach peak aesthetics, UX and DX for Barkpark."
Focus surface: the Cloud dashboard (`cloud/priv/static/` SPA + `cloud/lib/barkpark_cloud/` control plane) and the `bp cloud`/`bp cloud hetzner` CLI — the two operator surfaces, made provably one product.

## Vision

Open the dashboard and it reads like Vercel operating hardware you own. Every question in the operator's week has a live answer and every answer has an action: a closed SSE event contract keeps every panel live (unknown event types are a test failure, not a silent stale view); the instance detail grows a chronological Timeline off the currently consumer-less events endpoint; the Hetzner estate stops being CLI-only — an Infrastructure panel renders the exact JSON that `bp cloud hetzner overview -o json` prints, served through a control-plane proxy so the browser never touches a Hetzner token. Destructive operations share one grammar on both surfaces: typed-name confirm in the GUI, `hzConfirmDestroy` in the CLI, non-TTY passthrough for scripts. The design language is one machine-enforced token contract (semantic status roles that mean the same thing in a fleet dot, a deploy pill, and a CLI table), with skeleton/empty/error states designed as a system, a ⌘K palette and copy-as-CLI chips generated from one action registry, and zero dead CSS shipped — checked, not hoped.

## Decisions (settled — build against these)

1. **Vanilla SPA stays; discipline is machine-enforced.** No framework rewrite. The node:vm `__bpTestHook` harness (`__app.test.mjs`) is the SPA's test spine — every new pure helper gets exported and tested. A new `__css_check.mjs` validator (dead classes, undefined tokens) gates every SPA slice. *Why: 3.4k lines of working, freshly-hardened code; a rewrite burns waves reproducing what exists.*
2. **SSE event-contract registry lands before any new live panel.** `events.ex` closes the type set; `app.js` mirrors it in a `TYPE_ACTIONS` table; a shared fixture (`cloud/priv/static/__fixtures__/event_types.json`) is asserted from both Elixir and the node harness. Every future live panel registers its types in the same PR or the gate fails. *Why: five planned panels all consume this stream; unversioned string vocabularies are how dashboards rot. Direction-ratified already.*
3. **Hetzner in the GUI goes through a control-plane proxy — never browser-direct.** `/v1/hetzner/*` routes resolve the vault-stored provider token server-side. A pure catalog module (`hetzner_catalog.ex`: resource, verb, method, exact path template, danger tier) IS the allowlist — no prefix matching, no free-form passthrough. Read-only ships first; allowlisted mutations (reboot/poweron/poweroff/snapshot — no delete in v1) come with the panel, each writing an audit event, tier-3 requiring a server-verified `confirm: name` echo. *Why: only honest path to GUI infra ops; token custody and CORS make client-direct impossible; the choke point makes audit + confirm structural.*
4. **One JSON contract, two surfaces.** `bp cloud hetzner overview -o json` is the reference implementation; the proxy's `/v1/hetzner/overview` emits the same envelope; the Infrastructure panel renders it; a committed golden fixture (`cloud/priv/static/__fixtures__/hetzner_overview.json`) is asserted by the Go tests and the node harness. Envelope (charter-canonical):
   ```json
   {
     "ok": true,
     "fetched_at": "<RFC3339>",
     "provider": { "kind": "hetzner", "label": "<label>" },
     "resources": {
       "servers": [], "volumes": [], "networks": [], "firewalls": [],
       "load_balancers": [], "floating_ips": [], "primary_ips": [],
       "dns_zones": [], "backups": []
     },
     "counts": { "<one int per resources key>": 0 }
   }
   ```
   Each resource row carries at least `{"id","name","status"}` (`"status":"n/a"` where the kind has none) plus kind-specific fields; the fixture is byte-truth. *Why: GUI/CLI drift is the chronic disease (layer-parity memory); making the CLI verb the contract makes parity structural.*
   **Partial failure (ratified wave 1):** a kind that failed to load rides as `null` (never `[]`) with `counts.<kind>: 0`, and an `"errors": {"<kind>": "<provider message>"}` map appears only when at least one kind degraded; `ok` stays `true` while any kind loaded; all-kinds-failed is a command failure (non-zero exit / mapped error), not an envelope.
5. **One destructive-op grammar, both surfaces, three tiers.** read = free; mutate = single confirm; destroy = typed-resource-name + consequence list. CLI: one `hzConfirmDestroy` helper swept across every hetzner delete/rebuild site, `--yes` and non-TTY passthrough (scripts and existing tests keep working). SPA: one focus-trapped typed-name modal component. Tier assignments live in the catalog. *Why: an operator who deletes a volume by muscle memory never trusts the tool again; per-surface shared helpers make the contract testable.*
6. **IA reshape after the spine:** Overview home (rollup strip, latest deploys, activity, Launch as action), 4-place nav (Overview/Fleet/Sites/Activity) + Settings cluster, instance detail becomes sub-tabbed workspace (Overview | Timeline | Env vars | Domains | Infrastructure | Danger). Legacy hash routes map via a pure `legacyRoute(hash)` helper — no broken bookmarks. *Why: 8 flat tabs rank a one-field form equal to Fleet; Kinsta/Vercel converge on few places, many actions.*
7. **Rollback/redeploy become control-plane primitives** (`POST /v1/sites/:id/rollback`, redeploy), reusing the existing fenced deployment transition + `current_deployment_id` re-point (verified present: router ~3723, registry). *Why: THE Vercel table-stakes feature we lack entirely; the machinery already exists.*
8. **Palette + copy-as-CLI chips come from ONE action registry, after panels exist.** A declarative registry (action id → route/handler → `bp` command template) powers both ⌘K and per-action CLI chips. *Why: two signature features for one tested data structure; the dashboard teaches the CLI.*
9. **Design-language scope: cloud SPA is the reference implementation; Studio/web adoption deferred.** Semantic status tokens (`--ok/--warn/--danger/--info`) drive SPA components now and CLI ANSI roles later; self-hosted Inter + a real Barkpark mark (mark flagged for human sign-off); `/styleguide.html` as the living spec. *Why: unifying four styling islands in one epic is where design systems die.*
10. **Timeline is the incident home.** Instance events (`GET /v1/barkparks/:id/events` — exists, consumer-less) merged chronologically with instance-scoped audit entries, live-ticking via the registry, console lines expandable inline. *Why: "what happened to this thing, in order" is the single answer Kinsta/Vercel won on; the server side already exists.*

Corrections to strategist claims (verified against tree): the "four referenced-but-undefined CSS tokens" do not exist — the token block is currently consistent; the checker is preventive, not remedial. `hzConfirmDestroy` does not exist yet anywhere. There is no `overview` verb. The invitation accept flow has routes (`GET /v1/invitations/:token`, `POST /v1/invitations/accept`) but no SPA consumer.

## Roadmap (integration order)

### Wave 1 — spine + contracts (current)
1. **SSE event-contract registry** (M) — events.ex closed set + app.js TYPE_ACTIONS + shared fixture, gated both sides.
2. **Design-token contract + `__css_check.mjs` validator** (M) — semantic status tokens in app.css; dead-class/undefined-token checker as a gate.
3. **`bp cloud hetzner overview` + golden fixture** (M) — the reference contract implementation in Go.
4. **CLI destructive-confirm sweep (`hzConfirmDestroy`)** (M) — every hetzner delete/rebuild site, typed-name, `--yes`/non-TTY passthrough.
5. **Hetzner catalog + read-only control-plane proxy** (L) — hetzner_catalog.ex allowlist + `/v1/hetzner/catalog` + `/v1/hetzner/overview` via fake-transport-tested proxy.

### Wave 2 — the operator's home
6. **IA reshape** (L) — Overview home, 4-place nav + Settings cluster, legacyRoute map, Launch-as-action.
7. **Instance workspace + Timeline** (L) — sub-tabbed instance detail; merged events+audit timeline, SSE-live, expandable consoles.
8. **Infrastructure panel (SEE)** (L) — renders the golden fixture shape; unified `statusMeta` status component migrated across badge-dot/dep-pill/notices.
9. **State grammar** (M) — skeletonRows, renderError-with-retry, per-view empty states, btn loading, modal focus trap, prefers-reduced-motion.

### Wave 3 — actions everywhere
10. **Hetzner DRIVE** (L) — allowlisted mutations through the proxy, action poller → `hetzner.action.*` SSE progress, typed-name modal, audit events in Activity.
11. **Rollback + redeploy end-to-end** (L) — control-plane routes + deployment rows with git sha/duration + live status flip.
12. **Env-vars, custom domains, invitation-accept panels** (M) — three curl-only dead ends closed.
13. **Team members/roles panel** (M) — list/invite/revoke/role-change over existing team routes.

### Wave 4 — signature DX + brand
14. **Action registry: ⌘K palette + copy-as-CLI chips** (M) — replace the decorative search stub.
15. **Brand self-containment** (S) — self-hosted Inter woff2, real inline-SVG mark (human sign-off), no-external-hosts lint.
16. **CLI parity polish** (M) — ANSI semantic roles in output.go mapped from statusMeta, completion tree, post-mutation dashboard deep-links.
17. **/styleguide.html living spec** (M) — every component, every state, both themes, linted by the same validator.

## Wave log

### Wave 2026-07-03 (wave 1 — spine + contracts)

**Landed (5/5 green, perfecter-verified; branches `loop-epic/*-p`, merge to main in flight at assessment time):**
1. **SSE event contract** (73fc11cb) — real vocabulary is **11 types, not 6** (adds members/notifications/onboarding + barkpark.suspended/restored, found by grepping every broadcast site). `events.ex` closed set, `broadcast/3` raises on unregistered types **in every env**, `TYPE_ACTIONS` mirror in app.js (byte-identical per-type behavior incl. newFlow fleet hook + unknown-fallback), fixture `__fixtures__/event_types.json` gated from Elixir AND node. Full cloud suite 1182/0. Fixture not publicly served (Plug.Static allowlist checked).
2. **Token contract + `__css_check.mjs`** (7e90591e) — semantic `--ok/--warn/--danger/--info` (+`-soft` tints, `--warn-strong`, console triple) in both theme blocks; every scattered status literal migrated with exact original alphas (zero rendered change, verified hunk-by-hunk, **no browser screenshot** — profile lock). Checker found 2 real phantom tokens (`--accent`, `--surface-2` with 3 different fallbacks). E1/E2/E3 all mutation-probed. `--info` + `-soft` tints are intentional wave-2 statusMeta scaffolding, not dead weight.
3. **`bp cloud hetzner overview`** (c80584d2) — concurrent 9-kind fan-out, frozen envelope, golden byte-fixture, partial-failure honesty. Perfecter fixed `server_type`→`type` naming drift **inside the fixture** — wave-2 consumers must assert against the `-p` branch's fixture.
4. **`hzConfirmDestroy`** (ae94889f) — 17 destroy sites swept, typed-name + stderr consequence line, `--yes`/`-y`/non-TTY passthrough, mismatch proven to send zero API requests. adopt/eject old-box delete deliberately ungated.
5. **Catalog + read-only proxy** (4d54766b) — `hetzner_catalog.ex` allowlist-as-data, `/v1/hetzner/catalog` + `/v1/hetzner/overview`, vault decrypt server-side, per-kind degradation, token proven absent from every response body. Perfecter fixed a real **silent first-page-truncation bug** (no pagination → wrong counts >25/kind). Cloud suite 1203/0.

**Ratified amendments:** decision-4 partial-failure semantics appended above (builder doubt-7).

**Debt created this wave (next wave MUST take):**
- **Fixture reconciliation Go↔Elixir** — the two overview implementations were built in parallel; proxy normalizes rows to exactly `{id,name,status}`, second-truncates `fetched_at`, and must match the (perfecter-amended) Go fixture byte-for-byte, incl. pagination behavior. No cross-language test asserts this yet. This IS the contract; close it before the Infrastructure panel renders anything.
- **Catalog↔CLI destroy-tier diff** — catalog ships 9 `:destroy` entries though the charter says no delete in v1 (unrouted data, guard in moduledoc); decide keep-as-data vs delete (30-line removal, 2 tests). Also diff catalog destroy tier vs the CLI's 17 swept sites (lb delete-service / network delete-subnet noted).
- **Merge-order conflicts** — overview + confirm slices both touch `hetzner_cmd.go` (dispatch switch, parseHzArgs); textual conflicts expected, semantic unlikely.
- `provider.label` can be JSON null → Infrastructure panel must render a fallback.
- `broadcast/3` raises everywhere now: wave-3 `hetzner.action.*` progress types must be registered in the same PR that emits them (the gate exists; this is a reminder that the raise is prod-live).
- Live smokes owed post-merge: one light+dark browser eyeball of the token migration; one real-token curl of `/v1/hetzner/overview` on staging.

**Assessment:** genuinely on-wish, zero drift. All five slices are contract/spine work the charter said must precede panels, and two slices caught real latent bugs (phantom tokens, pagination truncation) proving the gates earn their keep. Next wave: reconciliation micro-slice first, then wave-2 items — but do NOT run IA reshape + Timeline + Infrastructure panel concurrently; they all edit the same 3.4k-line app.js. Sequence SPA-heavy slices; parallelize with server-only work (rollback/redeploy primitives, item 7 of roadmap wave 3).
