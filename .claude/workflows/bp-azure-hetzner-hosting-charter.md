# Epic Charter — Azure + Hetzner Hosting Parity

> One product, two clouds, one language. Barkpark Cloud must host on Azure as well
> as it hosts on Hetzner — and be better than both today — with provisioning,
> deploying, domains/TLS, lifecycle (archive/decommission/resurrect/adopt), and
> monitoring first-class on BOTH providers from BOTH the `bp` CLI and the Cloud
> control-plane SPA. Every provider difference is visible and honest; nothing is a
> fork.

## Vision

An operator opens barkpark.cloud → Providers and sees Hetzner and Azure as equal
cards with the same 60-second connect flow (Hetzner: one API token; Azure: a
service-principal 4-tuple), each **verified live before it saves**. Launch is
provider-neutral: pick a provider, pick region + size from a normalized catalog
that shows the **real monthly price on both clouds** (Kinsta/Vercel structurally
can't), and the `/new` step feed narrates the SAME create→live chain for both —
Azure's slower cold-create is honest, not a lying spinner. The Fleet mixes both
providers in one list: a **provider chip** (identity only) + a **lifecycle pill**
(status) on every row, the same vocabulary the CLI renders because one token
emitter writes both surfaces. Lifecycle verbs (archive/decommission/resurrect/
adopt/audit) are first-class and provider-neutral on both surfaces; capability
differences degrade **visibly with a reason**, never a dead button or fake
parity. `bp cloud instance <verb>` and `bp launch <provider>` speak the seam;
`bp cloud hetzner …` / `bp cloud azure …` survive as raw escape hatches. DNS/TLS
is an orthogonal axis: an Azure box gets its `name.barkpark.cloud` A-record from
the existing Hetzner-hosted zone with nobody thinking about it. The bold payoff:
**portable archives** — archive a box to an object-storage bundle and resurrect
it on the OTHER provider — a migration story neither provider offers. No gate
ever touches a live cloud: Azure and Hetzner APIs are faked/recorded in tests.

## Decisions

1. **Azure SDK = azure-sdk-for-go (Track-2 ARM: armcompute/armnetwork/armresources)
   in the Go seam, NOT az-CLI shell-out, NOT hand-rolled REST.** — The SDK handles
   ARM long-running-operation (LRO) polling, retry, and API-version pinning (the
   genuinely hard part); az-CLI drags a Python dependency onto every host and
   parses fragile output; raw REST re-implements LRO for no benefit. Its
   `azcore` `policy.Transporter` is the injection seam for zero-spend fixture
   tests — the same fake-in-tests idiom `runCapture`/`FakeProvider` already use.
2. **Azure reads in the Elixir control plane go through a thin ARM REST module
   behind the config-selected client seam** (`Azure.client/0`, mirroring the
   proven `GitHub.client/0` / `Vercel.client/0` / `hetzner_http_client`
   pattern), Fake in tests. — The control plane already makes server-side READ
   calls for `/v1/hetzner/overview` (token never reaches the browser); Azure
   overview/catalog is just token-exchange + tagged list, too thin to justify
   forcing the Go SDK into Elixir. Heavy compute/lifecycle stays in the Go worker.
3. **One provider seam: promote `internal/cli/cloud.CloudProvider` to canonical,
   grow it ONLY by optional capability interfaces (the existing `ServerLabeler`
   idiom), add a `ProviderFor(kind, creds)` registry, stamp
   `@canonical capability:cloud-provider-seam`.** — The seam, warm-pool chain,
   orphan sweep, and lifecycle verbs are already written against it; Azure lands
   as an implementation, not a fork. Capability interfaces are how the codebase
   already handles provider asymmetry — Azure's real differences (resource
   groups, LRO deletes, no 63-char label rule) never force
   lowest-common-denominator on Hetzner.
4. **Azure credentials live in the EXISTING control-plane providers table
   (`@kinds ~w(hetzner azure)`, `encrypted_token` = Vault-encrypted JSON blob of
   `{tenant_id, client_id, client_secret, subscription_id}`), NOT per-instance
   run-secrets.** — This honors the lead note's real intent ("don't invent a new
   store"): the providers row is the established team-scoped, Vault-encrypted,
   `redact:true` credential home that `/v1/providers`, the SPA picker, and the Go
   worker already read. Run-secrets are INSTANCE-scoped on the content API — a
   credential that PROVISIONS instances cannot live inside one instance. (Lead
   may override toward run-secrets; the plane mismatch is the reason not to.)
5. **Verify-before-save preflight for BOTH kinds** — POST /v1/providers runs a
   cheap authenticated list call before persisting, with per-kind remediation
   copy on failure. — The wish's "connect flow" bar is verification, not a blind
   save; Azure fails in ways Hetzner never does (quota/RBAC/capacity) and generic
   copy is a dead end.
6. **Provider-neutral routes + normalized catalog; Hetzner routes kept as
   aliases.** `/v1/providers/:kind/catalog` + `/v1/providers/:kind/overview`
   replace provider-named routes (`/v1/hetzner/*` delegates), and the catalog has
   ONE shape `{regions, server_types:[{slug,cores,ram_gb,disk_gb,monthly_price}]}`
   both providers map into. — Every provider-named route/panel is a file to
   duplicate for provider N; the normalized catalog also forces the Hetzner
   catalog to finally carry pricing (hcloud exposes it; today we drop it) — the
   single highest-leverage Hetzner improvement.
7. **Instance lifecycle + provider identity become design-token families, dual-
   emitted to SPA CSS and Go chrome** — `instanceLifecycle` (provisioning · live ·
   degraded · stopped · archived · decommissioned · adopted) and
   `color.provider.{hetzner,azure}` in `design/tokens.json`, emitted via
   `emit.mjs` exactly like the task `lifecycle` family + `chrome_gen.go` sibling.
   Identity NEVER doubles as status. — Reuses proven machinery (#1275/#1307/#1558);
   makes browser↔terminal parity mechanical, not aspirational; a third provider
   is a data row, not a design project.
8. **A committed `providers_capabilities.json` fixture is the cross-surface
   contract** — a capability claimed but unimplemented fails a Go test; one
   implemented but unclaimed fails the SPA harness. — This is how "honest
   degradation" becomes renderable and drift becomes a CI failure instead of a
   support ticket.
9. **Azure provisioning is honest cold-create through the SAME `provision_job`
   step machine, pool-size-zero (no Azure warm pool this epic).** The step vocab
   is already provider-neutral (`create freshen secure configure content verify
   ready`); Azure narrates the same steps, provider detail rides in the step's
   sub-caption, never a new step kind. — The warm pool is Hetzner's speed trick,
   not the product contract; the step machine exists precisely so slow paths stay
   honest.
10. **DNS stays on the Hetzner-hosted `barkpark.cloud` zone for ALL providers** —
    an Azure box gets its A-record via the existing `DNSProvider` seam; no Azure
    DNS integration. — Compute provider and DNS host are orthogonal; the zone
    lives on a separate Hetzner token with the biggest blast radius — don't touch
    it for zero operator-visible benefit.
11. **Hetzner native cutover: the seam's Hetzner impl moves from `hcloud` shell-out
    to the native `internal/hetzner` hcloud-go APIProvider, env-gated, AFTER seam
    v2, with a fake-driven equivalence golden test as the harness.** — Two Hetzner
    impls exist today (shell-out in the seam, native unused); an asymmetric epic
    (Azure native, Hetzner shell-out) would entrench the worse path and keep the
    hcloud-CLI install requirement the wish asks us to remove. Risk is real
    (prod warm-pool runs the shell-out) → env-gated, equivalence-proven, not
    big-bang.
12. **Portable archives are the bold bet: archive → object-storage bundle
    (manifest + pg_dump + media + secrets ciphertext + spec hints), resurrect on
    ANY provider.** Hetzner snapshot demoted to an explicit `--fast` optimization.
    — This is what makes Barkpark Cloud better than both providers rather than
    merely present on both, and it is the only credible day-one archive story for
    Azure (no warm pool, no snapshot tooling there). High risk (secrets/certs onto
    a fresh cross-provider box) → whole large slice, fake-S3 + fake-provider
    round-trip.
13. **Monitoring truth = the on-box agent beat, not provider metrics APIs** —
    extend the agent report with vitals, roll a window in the CP, render a Metrics
    tab + `bp cloud instance top`. — One shape, works identically on both clouds
    and on adopted/self-hosted boxes; two provider metrics APIs = two integrations
    and Azure Monitor is laggy.
14. **All gates offline** — FakeProvider parity on every capability, recorded
    ARM/hcloud HTTP fixtures for real clients, node:vm `__bpTestHook` helpers for
    every new SPA pure function, cross-runtime committed fixtures where Go and JS
    must agree. — Lead constraint + the distrust-vacuous-green doctrine.

## Roadmap

Integration order. Sizes: small / medium / large. Wave assignment in brackets.

**Foundation (Wave 1 — parallel, no shared files):**
- **S1 · Go provider seam v2** [medium] — registry keyed by slug (hetzner/fake +
  an azure hook), optional capability interfaces (Cataloger, InstanceLifecycler,
  Pauser), `ProviderFor(kind,creds)`, `providers_capabilities.json` cross-surface
  fixture + parity test, `@canonical capability:cloud-provider-seam`, `bp cloud
  providers`. Owns `provider.go`/`registry.go`/`fake.go`/fixture/`cloud_providers_cmd.go`.
- **S2 · Azure ARM client + AzureProvider** [large] — new `internal/cli/cloud/azure/`
  on azure-sdk-for-go, injected transporter + recorded fixtures, implements the
  EXISTING `CloudProvider` + label interfaces (no registry wiring — that's W2).
  Isolated package, zero overlap with S1.
- **S3 · Control-plane neutral** [medium] — `@kinds` grows azure, per-kind
  credential schema + verify-before-save preflight, `/v1/providers/:kind/catalog`
  + `/overview` neutral routes (hetzner alias), normalized catalog shape WITH
  pricing for both, `Azure.client/0` fake seam, azure failure_copy entries.
  Elixir only.
- **S4 · Design tokens: instance lifecycle + provider identity** [small] —
  `instanceLifecycle` + `color.provider.*` families, dual-emit (app.css generated
  block + Go chrome sibling), contrast-gate, styleguide swatches. Does NOT rewire
  consumers (later waves). design/ + generated blocks only.

**Wire-together (Wave 2):**
- **S5 · Neutral CLI verbs + azure wiring** [medium] — `bp cloud instance <verb>`
  routing through `ProviderFor`, `bp launch azure`, `bp cloud azure` escape hatch,
  register AzureProvider in the seam. Needs S1+S2.
- **S6 · Azure go-live through the step machine** [large] — `provision_job`/
  barkpark rows carry provider kind, worker resolves kind+creds and cold-creates
  Azure through the seam chain pool-size-zero, azure quota/RBAC failure copy
  reaches the job error, orphan sweep/teardown per-provider via ARM tags. Needs
  S2+S3.
- **S7 · SPA: Azure card + verified connect + neutral launch catalog** [large] —
  Azure `available:true` with the 4-field credential sheet, submit runs the
  preflight and renders success/remediation, launch fetches the normalized
  catalog and renders region+size WITH prices, provider chips + lifecycle pills
  consume S4 tokens. THE app.js slice — solo. Needs S3+S4.

**Depth (Wave 3+):**
- **S8 · Hetzner native cutover** [large] — seam → hcloud-go, env-gated,
  equivalence golden test (Decision 11). Needs S1.
- **S9 · Lifecycle verbs neutral + SPA lifecycle actions** [medium] — lift
  archive/decommission/resurrect/adopt/eject/audit to `bp cloud instance`
  through the seam; SPA instance-workspace action row with typed-confirm modal +
  optimistic pill transitions.
- **S10 · CLI chrome parity** [medium] — one table formatter for both providers
  (provider glyph + lifecycle glyph from emitted Go tokens), golden-render tests.
- **S11 · Console fleet + Infra tab** [large] — mixed-provider fleet, per-provider
  infra panel from the neutral overview, audit cross-check surfaced in the
  attention queue with fix-it hints, lifecycle modals.
- **S12 · Metrics: agent vitals beat + Metrics tab + `bp cloud instance top`**
  [large] — Decision 13.
- **S13 · Domains/TLS checklist panel** [medium] — Vercel-grade per-domain
  checklist (DNS found → points here → TLS issued → serving), same on both
  providers + `bp cloud domain status`.
- **S14 · Portable archives v1** [large] — manifest + object-storage bundle,
  cross-provider resurrect, Hetzner snapshot demoted to `--fast` (Decision 12).
- **S15 · Console-states styleguide completeness + drift tripwire** [small] —
  every lifecycle pill / provider chip / confirm / fleet empty-loading-error state
  in the styleguide, vocabulary↔styleguide completeness gate.
- **S16 · Hetzner journey polish** [small] — connect verify + pricing everywhere +
  remediation-copy parity backfilled onto the Hetzner path (the "improve Hetzner
  too" dividend measured against real stuck-points).

## Wave log

### Wave 2026-07-09 — Foundation (S1–S4)

**Landed (green, near-merge):**
- **S1 · Go seam v2** — `internal/cli/cloud.CloudProvider` promoted to canonical; optional capability interfaces (Cataloger/InstanceLifecycler/Pauser/Authenticator) advertised by satisfaction; `Capabilities`+`DetectCapabilities`; slug→factory registry (`ProviderFactory`/`Register`/`ProviderFor`, loud unknown-kind error) with hetzner+fake registered and a documented azure slot; committed `providers_capabilities.json` cross-surface contract + drift-parity test (fixture claim vs actual Go interface satisfaction); `bp cloud providers` matrix (table+json, golden test); `@canonical capability:cloud-provider-seam` in provider.go. Verified live against the built binary.
- **S2 · Azure ARM client** — isolated `internal/cli/cloud/azure/` on azure-sdk-for-go Track-2; implements the EXISTING seam (Create/IP/Delete/List + HasAuth) + label capabilities; RG-per-fleet convention (shared RG+VNet, per-box PublicIP/NIC/VM); LRO-blocking create with the failed-create-orphan-teardown guarantee (perfecter found+fixed a silent orphan-cleanup-failure — Hetzner-parity regression); idempotent 404-tolerant delete; injectable azcore transport replays 14 committed fixtures, 10 tests, ZERO live calls (verified GOPROXY=off). No registry/CLI wiring (S5's job).
- **S3 · Control-plane neutral** — `@kinds` grows azure; `encrypted_token` stays the single credential home (azure = vault-encrypted 4-field JSON) with a per-kind changeset shape gate; verify-before-save preflight on POST /v1/providers (nothing saved on auth failure, per-kind remediation returned); neutral `GET /v1/providers/:kind/{catalog,overview}` with the normalized `{regions,server_types:[{slug,cores,ram_gb,disk_gb,monthly_price}]}` shape for both kinds; `Azure.client/0` fake seam mirroring `GitHub.client/0`; azure FailureCopy classes (quota/capacity/RBAC). **Documented deviation:** neutral routes added ADDITIVELY; `/v1/hetzner/*` left intact (they serve different concerns — action allowlist + estate envelope — with large passing tier-tripwire tests). Correct call.

**Built, not yet verdicted/merged:**
- **S4 · Design tokens** — `instanceLifecycle` (7 states, colour read THROUGH a role so identity never doubles as status) + `color.provider.{hetzner,azure}` in tokens.json; dual-emit to app.css block + `internal/semrole/chrome_gen.go` sibling (keeps tokens_gen byte-stable); check.mjs Part D parity gate + contrast pairs (WCAG clear); styleguide "Console states" section; DESIGN.md §5 rule (provider tint is never a pill background). No consumer rewired — parallel-safe. gofmt/build/validate/doc gates pass; awaits perfecter verdict.

**Follow-ups filed / carried into next wave:**
- **Azure pricing is nil in prod** (S3) — real Azure SKU API carries no pricing; needs the separate Retail Prices API. FakeClient supplies prices so tests/shape are green, but a visible Azure-vs-Hetzner parity gap remains against the vision's "real monthly price on both clouds." Wire into S7's catalog work or a dedicated pricing slice.
- **`fake` provider shows in the operator matrix** (S1) — honest per the fixture but a cross-surface product call (SPA S7 reads the same fixture). Decide once, apply to CLI + SPA together — do NOT filter in one surface alone (drift).
- **Live-wiring prereqs** (S2) — first live Azure create needs `BARKPARK_AZURE_SSH_PUBKEY`; List is O(all-VMs); fixtures replay-not-validate; partial LRO coverage. All correctly deferred to S5/S6.
- **Integration hygiene** — S3 gate ran on a borrowed build (symlinked deps + copied _build); run the FULL cloud suite at integration, not just touched-route tests.

**Next wave:** Wave 2 wire-together — S5 (neutral CLI verbs + azure registry wiring; needs S1+S2 ✓), S6 (Azure go-live through the provision_job step machine, pool-size-zero; needs S2+S3 ✓), S7 (SPA Azure card + verified connect + neutral launch catalog; needs S3 ✓ + S4 — merge S4 first). All three are largely file-isolated (S5=Go CLI, S6=Elixir worker, S7=app.js solo); sequence S6 after S3's Elixir surface settles.
