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
15. **Azure retail pricing = a sibling `BarkparkCloud.Azure.Pricing` client, its
    OWN slice (S7a), NOT an `Azure.Client` callback and NOT inside S7.** The
    Retail Prices API (`prices.azure.com/api/retail/prices`) is unauthenticated
    and global — hanging it off the per-credential `Azure.Client` behaviour is a
    category error, and S7 is app.js-solo while pricing is Elixir. Own injectable
    transport fn under its own config key (third key beside `:azure_http_client`
    and `{BarkparkCloud.Azure, :http_client}`), fail-closed like
    `RealClient.request/1`. Join is direct equality: `armSkuName` == server_type
    slug, `armRegionName` == region slug (verified live). monthly =
    `retailPrice × 730`; per server_type reduce to CHEAPEST monthly across
    offered regions (parity with Hetzner's `cheapest_monthly`). Exclude
    Spot/Low-Priority (meterName/skuName) and Windows (productName) rows —
    fixtures MUST carry those decoys or a spot price silently poses as
    on-demand. ETS GenServer cache ~24h TTL (`TwoFactorRateLimiter` pattern),
    credential-free, app child. Enrichment stamps `monthlyPriceUsd` onto
    vm_sizes in `build_provider_catalog("azure")` BEFORE `AzureCatalog.normalize`
    (the normalizer already reads that key — zero change). A pricing outage
    degrades to `monthly_price: nil` + catalog still 200 — NEVER the 502
    `catalog_unavailable`. The normalized shape grows `currency` ("EUR" hetzner /
    "USD" azure) so the side-by-side comparison is honest; SPA copy reads
    "from ~$X/mo compute" (retail excludes disk/egress/licensing).
16. **Fake-provider visibility is decided ONCE, in `providers_capabilities.json`,
    as a `tier` attribute — landed via a `ProviderRow` wrapper struct** (`Tier`
    + embedded `Capabilities`) so `DetectCapabilities`/the parity test keep
    comparing pure capability bools (a bare Tier field on `Capabilities` reds
    parity; a fixture-only key is silently discarded by the plain unmarshal —
    both dead ends, verified). `fake` gets `"tier":"dev"`; `bp cloud providers`
    hides dev-tier rows by default, `--all` reveals; golden CLI tests gate their
    "fake" expectations behind `--all`. The SPA needs NO change this wave — its
    hardcoded PROVIDERS list never contained fake, so surfaces already agree;
    the CP-served capability/tier conduit that makes CLI+SPA read one contract
    by construction is Wave-3 work (fold into S11). The fixture OWNS the
    attribute from today, so nothing forks meanwhile.
17. **Two credential planes, on purpose.** Managed Hetzner keeps provisioning in
    the PLATFORM account (worker-env `HCLOUD_TOKEN`, no providers row — status
    quo, untouched). Azure go-live is BYO: it REQUIRES the team's verified azure
    providers row; `POST /v1/launch {provider:"azure"}` without one is a 422
    `provider_not_connected` + FailureCopy remediation at launch time (fail at
    the button, not in the job). Azure creds reach the worker DECRYPTED inside
    `claim_json`, mirroring exactly how `env` is decrypted at claim time
    (router.ex:6411) — the single sanctioned plaintext crossing, over the
    already-authed worker channel.
18. **The launch write path is S6's, and S6 spans BOTH stacks.** Exploration
    disproved "S6 is Elixir-only" and found the structural gap: `go_live` DROPS
    the `provider` param, no provider/region/server_type columns exist, the
    claim payload hardcodes nbg1/cax11, Go `JobSpec` carries no kind/creds, and
    `ProvisionWith` uses a hardcoded Hetzner singleton — `ProviderFor` is dead
    code w.r.t. provisioning. S6 = barkparks migration (provider default
    'hetzner', region, server_type) + launch accepts/persists them + claim_json
    threads kind/region/size/creds + Go JobSpec/ProvisionWith route
    kind→`ProviderFor` with the hetzner path BYTE-UNTOUCHED (kind ""|"hetzner"
    keeps `seams.Provider` + warm pool; "azure" forces pool-size-zero +
    provider-aware FreshSpec). Until S6 lands, S7's priced picker is
    display-only — that is why the extension is a named AC, not a hope.
19. **The SPA renders verify-failure remediation IN the credential sheet;
    `friendly()` never touches it.** `friendly()` reads only
    `data.error`/`data.details` and silently DROPS `data.remediation` — a live
    bug on the Hetzner path today, fixed for both kinds by S7. Remediation copy
    stays server-owned in `FailureCopy.connect_remediation`; never duplicated in
    JS.
20. **The single `Capabilities.Lifecycle` bool splits into five facet bools —
    `archive`, `resurrect`, `decommission`, `adopt`, `audit`** (core/catalog/
    pause/labels unchanged) in the Go struct AND `providers_capabilities.json`.
    Ratified claims: hetzner all five true; azure `decommission` + `audit` true,
    `archive`/`resurrect`/`adopt` false; fake all true (tier:dev). An Azure
    "adopt" facet is REJECTED this wave: Hetzner adopt is a clone-swap that
    REQUIRES a snapshot (hetzner_instance_cmd.go:1064); a register-only Azure
    adopt would silently mean something different under the same verb — revisit
    when portable archives (S14) give both providers one archive substrate.
    Azure decommission is decommission-WITHOUT-archive: the typed-confirm
    carries an explicit "no archive exists — this is unrecoverable" warning.
    Azure audit is tri-surface minus archives (compute residue via the RG list +
    DNS + registry are all reachable; the archive residue check is skipped with
    an honest printed note). `TestFixtureAzureRowHonest` (registry_test.go:116)
    is updated in the SAME PR or it red-lines.
21. **Neutral lifecycle lands at the DISPATCH layer — verb guts are NOT ported
    into the seam.** The ~1500 lines of Hetzner lifecycle CLI functions stay
    byte-untouched; `bp cloud instance archive|resurrect|decommission|adopt|
    audit|pause|resume` dispatches per kind: hetzner → the EXISTING free
    functions (same flags threaded); azure → new CLI-level decommission/audit
    composed from AzureProvider + the same DNS/registry helpers the hetzner
    verbs use (the barkpark.cloud zone and cpFleet registry are provider-
    neutral by Decision 10/17); unsupported combos → `degradeUnsupported` with
    a reason. Facet DETECTION is two-source: per-facet seam interfaces
    (`InstanceLifecycler` splits into `Archiver`/`Resurrector`/`Decommissioner`/
    `Adopter`/`Auditor`; FakeProvider regroups) OR a `cloud.RegisterLifecycleVerbs
    (kind, verbs)` registration populated in the cli package FROM the dispatch
    table itself — so a fixture claim can only be satisfied by a real dispatch
    entry or a real interface impl; the parity test bites on the merged truth.
    Rationale: `HcloudProvider` is a zero-value shell-out struct holding no DNS
    token / worker token / progress writer (provider.go:547), and the verbs need
    a second hcloud DNS client + cpFleet + `out *writer` — forcing them behind
    the seam interface is a 1500-line high-risk migration for zero user-visible
    gain (that extraction is S8 territory). `bp cloud hetzner instance` survives
    as the escape hatch, refute-tested byte-identical.
22. **The capability conduit is a committed duplicate + byte-drift gate — NOT
    "one file by construction" (impossible: the CLI must embed its copy for
    offline use, and cloud/'s Docker build context cannot reach the repo
    root).** The Go fixture is CANONICAL (it alone is gated against real
    implementation truth); `cloud/priv/static/__fixtures__/providers_capabilities
    .json` is the derived byte-copy shipped in the image; an ExUnit contract
    test Path.expands to the Go fixture and asserts byte equality — the proven
    event_types.json / fmt-display-parity pattern. `GET /v1/providers/
    capabilities` (require_user) serves `{providers: {<kind>: {tier,
    capabilities, gaps}}}`: bools passed through GENERICALLY from the fixture
    copy (no hardcoded key list, so the facet split lands without a conduit
    change), `gaps` = a server-owned reason for EVERY false capability via new
    `FailureCopy.capability_gap_reason/2` (Decision 19 extended: JS never
    invents reasons — the module carries a default clause so no false
    capability is reason-less). The CLI keeps its embedded copy (offline
    contract, cloud_providers_cmd.go:8-10). SPA presentation (console URL,
    blurb, credential field specs) STAYS SPA-side — the conduit carries
    capabilities/tier/gaps only. NOTE: registry.go:133-135 / provider.go:99-100
    claim Elixir+SPA already read this fixture — false until this lands; fix
    the comments with the conduit.
23. **Warm-pool pin honesty is a TWO-STACK fix.** Go alone cannot distinguish
    "user pinned cax11" from "CP default-stamped cax11": the CP stamps
    nbg1/cax11 onto every unpinned hetzner claim (router.ex claim_region/
    claim_server_type + registry.ex @default_region/@default_server_type) while
    the pool's real spec is env-derived (warmBaseSpec → DefaultSpec: nbg1/cx23
    unless BARKPARK_SERVER_TYPE/LOCATION override) — a naive Go-side compare
    would skip warm for EVERY unpinned launch. Fix: (a) CP stops default-
    filling hetzner claims — region/server_type ride the user's pin or null,
    exactly the azure reviewer-fix pattern from wave 2; (b) Go `tryWarmAssign`
    skips warm when the job spec is non-empty AND differs from
    `warmBaseSpec(ctx)`'s region/server_type (empty = pool-compatible → fast
    path untouched); (c) the hetzner one-shot fills empty region/type from
    FreshSpec so the resilience ladder never leads with an empty create. The S6
    "hetzner claim payload byte-identical" refute-test is updated as an
    INTENTIONAL improvement — the old bytes encoded the lie.
24. **Pricing goes serve-stale-while-refreshing, demand-triggered — never a
    timer.** Fresh cache → serve; ABSENT cache → synchronous fetch in the
    caller (unchanged — nothing to serve, and it preserves the first-ever-
    failure nil-degrade tests); STALE → serve the stale row IMMEDIATELY and
    hand ONE refresh to the Pricing GenServer (an in-flight guard in GenServer
    state coalesces concurrent stale reads — no thundering herd). The process-
    dictionary fake transport is invisible to the GenServer, so it is reworked
    into a cross-process collaborator (named public ETS queue) — the REAL cost
    of the slice, bounded to one test file + one support module (its only
    consumers). Exactly one test pins the old synchronous-refetch-on-TTL
    contract (azure_pricing_test.exs:125-138); it rewrites to serve-stale
    (stale value now, fresh value on the next read after a deterministic
    GenServer flush). The live armSkuName==slug join verification SPLITS OUT
    into its own network-gated task — it is never an offline gate.

25. **Domain truth is a CP-side prober behind three injectable seams; ONE
    status shape serves console + CLI.** A browser cannot resolve DNS or dial
    TLS, so the probe lives in the control plane (the conduit pattern — a
    Go-side prober would mean two probers, two truths). New
    `BarkparkCloud.DomainStatus` modeled on `Verify` (structured envelope,
    total-over-failure, per-probe ~5s budgets, route stays bounded): three
    resolved-at-call-time seams under ONE config key — DNS via
    `:inet.getaddrs` (PUBLIC resolution, never a zone-read: the CP holds no
    DNS token, and what the customer's resolver sees is the whole point),
    HTTP via the proven verify_peer `:httpc` transport
    (Verify.HttpClient idiom), and TLS attribution via a NEW dep-free
    `:ssl.connect`/`:ssl.peercert` step (the one greenfield primitive;
    validity window + issuer via `:public_key`). Route: `GET
    /v1/barkparks/:id/domain-status` (require_user, team-scoped, sibling of
    telemetry/usage). Estate = `Barkpark.provisioning_fqdn/1` (never ad-hoc
    url parsing) + `custom_host` (a SCALAR — one custom host per instance;
    multi-custom-domain needs a schema change, explicitly NOT this wave),
    each compared against `bp.host`. Contract per host: ordered stages
    `dns_found → points_here → tls → serving`, each
    `{stage, label, status: ok|pending|failed, evidence, remediation}`;
    a stage downstream of a non-ok stage is `pending` (skipped, never
    probed-and-red); a fresh-attach DNS-propagation miss is `pending` with
    retry copy, never a failure. Response envelope:
    `{ok, checked_at, instance: {id, host}, domains: [{host, kind:
    platform|custom, overall, stages: [...]}]}`.
    `FailureCopy.domain_stage_remediation/2` owns ALL remediation copy
    ("add this A record…", "cert pending — retry in ~60s"), and it knows the
    fqdn cert is provision-time Caddy while the custom_host cert is on-demand
    `/v1/tls/ask` — two different pending stories. JS and Go never invent
    reasons (Decision 19 extended again).
26. **CLI and SPA consume the domain-status route; neither probes.** Go: new
    `cloudclient.DomainStatus(id)` (Bearer, VerifyInstance timeout-headroom
    precedent) + `bp cloud domain status <name>`; `-o json` renders CP bytes
    verbatim (the verify pattern — live state is a CP call, never an embedded
    fixture). SPA: the instance-workspace Domain rail row grows into a
    per-host stage checklist — a pure `domainStages(payload, now)` reducer
    shaped like `provisionSteps` (pending/active/ok/failed rows), exported
    via `__bpTestHook` and asserted in `__app.test.mjs`; DOM mount polls the
    route on the /new 4s idiom while any stage is non-terminal; the attach
    modal's fire-and-forget "DNS + TLS will be live shortly" toast is
    replaced by the live checklist. Only the pure reducer is node-tested —
    do not deepen the untested browser-mount zone.
27. **S10 chrome = header-driven painting inside the ONE shared renderer.**
    `renderHzTable` (already the single table path for all 33 cloud+hetzner
    call sites, and it already holds `out *writer`) gains a paint step keyed
    on COLUMN HEADER — `PROVIDER` → GenProviderMark tint by cell value;
    `STATUS`/`STATE`/`LIFECYCLE` → GenInstanceLifecycle role hue by cell
    value — zero call-site changes and zero value-collision risk (a server
    named "live" in a NAME column never paints). Color rides lipgloss with
    the style_cmd pinned-profile idiom (Gen* are AdaptiveColor; the raw-SGR
    paintCell family cannot express them), gated on `writer.color`; with
    color OFF the output is BYTE-IDENTICAL to today (tint only — no glyph or
    byte injection into existing columns; `cloud.Server` carries no status
    field, so NO invented state column). Goldens in both modes (TrueColor +
    Ascii pinned, the style_golden_test recipe); consumers read Gen* SYMBOLS,
    never hex (the #1563 lit-allow ratchet). Existing Contains-based table
    tests stay Contains-based.
28. **The fqdn-tag task is repointed to ground truth.** Go-live azure boxes
    ALREADY get barkpark-fqdn: ProvisionWith routes azure through the same
    ProvisionOneShot (provision.go:295-299 sets seams.Provider from
    ProviderFor) and labelFQDN (warmpool.go:1273) stamps the tag fail-closed
    via the ServerLabeler facet, which AzureProvider satisfies. The REAL gap:
    the direct-create escape path (`bp cloud instance create`, BOTH
    providers) stamps only barkpark-managed. Fix: `doInstanceCreate` stamps
    `cloud.Fqdn(name, cloud.Zone)` post-Create through ServerLabeler
    (mirroring labelFQDN), erroring loud with the created box's name if
    labeling fails (never silent); the audit additionally exempts
    `barkpark-warm` boxes (legitimately fqdn-less until assign — a latent
    second defect in the same loop); a create-then-audit test proves a fresh
    box audits clean + a refute keeps a truly unlabeled box flagged. NOT a
    ServerSpec.FQDN threading (blast radius for zero gain) and NOT a derived
    fqdn inside AzureProvider.Create (go-live create names are
    oneShotServerName-mangled — the derivation would stamp a lie).
29. **Fake lifecycle honesty = generic interface-driven executor (Option A);
    fixture untouched.** At runCloudInstanceLifecycle's `!known` branch
    (cloud_instance_lifecycle_cmd.go:108-117), replace degradeUnsupported
    with a generic facet executor modeled on runCloudInstancePause: resolve
    the provider off the seam → type-assert the verb's facet interface →
    call → emit structured result; degrade ONLY when the assert fails.
    hetzner/azure never route there (they sit in lifecycleDispatch), so
    azure archive keeps degrading honestly (it implements no archive
    facets) and hetzner is byte-untouched. TestNeutralLifecycleDegrades
    flips its fake-archive assertion to success and loses the rationalizing
    comment. Stated seam semantics: GENERIC dispatch is the default for any
    provider satisfying a facet; the dispatch table is the override for
    verbs needing collaborators (DNS/cpFleet/writer). Option B (dispatch-
    truth detection) is REJECTED: it rewrites Decision 21's two-source
    semantics, contradicts the fake's all-capable-reference doctrine, deads
    five fake methods, and ripples the fixture byte-copy across surfaces.

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

**Wire-together (Wave 2) — integration order S5 → S6 → S7a → S7:**
- **S5 · Neutral CLI verbs + azure wiring + tier honesty** [medium] — azure
  `Factory` + self-registration via the azure package's own `init()`
  (`cloud.Register(ProviderAzure, azure.Factory)`, blank-import in the cli
  package); new `runCloud` arms `instance` (core verbs list/create/delete/ip +
  labels through `ProviderFor`, `--provider` flag, honest degrade on missing
  capability) and `azure` (raw escape hatch, creds flag>env AZURE_* 4-tuple);
  fixture flips azure core/labels/pause=true (catalog/lifecycle stay false);
  `ProviderRow`/tier work per Decision 16. `bp launch azure` is ALREADY an
  opaque pass-through at the CLI layer — prove it, don't rebuild it. Lifecycle
  verbs stay on `bp cloud hetzner` until S9. Needs S1+S2 (merged ✓).
- **S6 · Azure go-live through the step machine** [large] — BOTH stacks, per
  Decision 17/18: barkparks migration + launch write path + claim_json creds
  threading (Elixir) AND JobSpec.Kind/Credentials + kind-routed ProvisionWith
  (Go). Azure narrates the same steps pool-size-zero; quota/RBAC raw ARM errors
  reach the job error and classify through the EXISTING FailureCopy-at-serialize
  (no Elixir vocab change). Carries S2's deferred edges as ACs:
  `BARKPARK_AZURE_SSH_PUBKEY` prereq with honest failure copy, O(all-VMs) List
  scoped or explicitly waived, fixtures documented replay-not-validate. Go tests
  route kind through the FAKE provider (no build-time dependency on S5's
  factory); azure resolution proven at integration after S5. Needs S2+S3
  (merged ✓); integrate after S5.
- **S7a · Azure Retail Prices client + priced neutral catalog** [medium] —
  Decision 15 verbatim: sibling Pricing client + fixtures-with-decoys +
  NextPageLink replay + ETS cache + enrichment in `build_provider_catalog`
  + nil-degrade-never-502 + `currency` in the normalized shape (both
  normalizers). Elixir-only; router.ex overlap with S6 is in a DIFFERENT region
  (~5702 catalog vs ~5049/6394 launch+claim). Needs S3 (merged ✓).
- **S7 · SPA: Azure card + verified connect + priced neutral launch** [large] —
  Azure `available:true`; credential sheet branches on kind (hetzner token vs
  azure 4-tuple → `{kind, credentials:{...}}`); 422 remediation rendered
  IN-SHEET per Decision 19; launch grows a provider→region+size picker fed by
  `GET /v1/providers/:kind/catalog` with monthly_price + currency + honest
  "price unavailable" nil state, submitting
  `{provider,name,region,server_type}` (honored once S6 lands; extra fields are
  ignored harmlessly before that) while preserving the three mount points and
  the name→402-plan→checkout reducer; provider chip component consumes S4
  tokens (`--provider-*`), retires the drifted `.brand-hetzner` #d50c2d, and
  renders on fleet rows ONLY when the payload carries `provider` (no fake
  identity). New pure helpers exported via `__bpTestHook` + asserted in
  `__app.test.mjs`. THE app.js slice — solo. Needs S3+S4 (merged ✓).

**Depth (Wave 3+):**
- **S8 · Hetzner native cutover** [large] — seam → hcloud-go, env-gated,
  equivalence golden test (Decision 11). Needs S1.
- **S9 · Lifecycle verbs neutral (CLI)** [W3, large] — facet capability split
  (Decision 20) + dispatch-layer neutral verbs (Decision 21): `bp cloud
  instance archive|resurrect|decommission|adopt|audit|pause|resume`, hetzner
  guts byte-untouched + refute-tested, azure decommission-without-archive +
  minus-archives audit, fixture facets + parity + providers matrix columns.
  The SPA half moved into S11b (the action row consumes the conduit).
- **S10 · CLI chrome parity** [W4, medium] — header-driven painting in the one
  shared renderer per Decision 27 (GenProviderMark + GenInstanceLifecycle
  finally consumed), golden-render tests in color + NO_COLOR.
- **S11a · Capability conduit** [W3, medium] — Decision 22: committed priv
  fixture copy + byte-drift ExUnit gate + `GET /v1/providers/capabilities`
  (tier + generic capability bools + FailureCopy gap reasons).
- **S11b · Console fleet + lifecycle action row** [W3, medium] — fleet rows
  show region/server_type (live from barkpark_json); lifecycle pill rendered
  through the S4 `instanceLifecycle` tokens (client-derived states mapped);
  instance-workspace lifecycle action row driven by the conduit: decommission
  is LIVE (existing deprovision path upgraded to the typed-confirm destroy
  modal), provider-supported-but-console-unwired verbs render an honest
  `bp cloud instance <verb> <name>` CLI affordance, unsupported verbs render
  disabled with the SERVER-OWNED gap reason. Pure model helpers hooked via
  `__bpTestHook`.
- **S11c · Infra tab** [large, later] — per-provider infra panel from the
  neutral overview, the :mutate/:destroy raw-resource allowlist routes (the
  catalog tiers declared-but-unrouted), audit cross-check in the attention
  queue. NOT wave 3.
- **S12 · Metrics: agent vitals beat + Metrics tab + `bp cloud instance top`**
  [large] — Decision 13.
- **S13 · Domains/TLS checklist** [W4, split] — Vercel-grade per-domain
  checklist (DNS found → points here → TLS issued → serving), same on both
  providers. S13a = CP prober + `GET /v1/barkparks/:id/domain-status` +
  FailureCopy stage remediation (Decision 25, large). S13b = the two
  consumers: `bp cloud domain status <name>` + the SPA stage checklist with
  polling (Decision 26, large).
- **S14 · Portable archives v1** [large] — manifest + object-storage bundle,
  cross-provider resurrect, Hetzner snapshot demoted to `--fast` (Decision 12).
- **S15 · Console-states styleguide completeness + drift tripwire** [small] —
  every lifecycle pill / provider chip / confirm / fleet empty-loading-error state
  in the styleguide, vocabulary↔styleguide completeness gate.
- **S16 · Hetzner journey polish** [small] — connect verify + pricing everywhere +
  remediation-copy parity backfilled onto the Hetzner path (the "improve Hetzner
  too" dividend measured against real stuck-points).

## Wave log

### Wave 2026-07-09 — Foundation (S1–S4) — ALL MERGED

Merged to main: S1 #1629, S2 #1630, S3 #1631, S4 #1632, plus #1633 (pre-existing
clause-grouping warning that was red-lining every cloud/** PR). Tasks
azh-w1-s1..s4 closed.

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

### Wave 2026-07-09b — Wire-together (S5, S6, S7a, S7) — PLANNED

Decisions 15–19 ratified this wave (pricing sibling client as own slice S7a;
tier-in-fixture via ProviderRow; two credential planes, Azure BYO; launch write
path owned by S6 across BOTH stacks; remediation in-sheet). Exploration
corrections folded in:

- The old "S6 = Elixir worker, file-isolated" framing was WRONG. Provisioning is
  Go-worker-driven end to end; Elixir is the queue + narration store. `go_live`
  drops `provider`, no provider/region/size columns exist, claim payload
  hardcodes nbg1/cax11, JobSpec carries no kind/creds, ProvisionWith uses the
  hardcoded Hetzner singleton — `ProviderFor` was DEAD w.r.t. provisioning. S6
  builds that plumbing in both stacks (Decision 18).
- `bp launch azure` was already wired at the CLI arg layer (opaque provider
  positional) — S5's real work is Factory + registry + `bp cloud instance`/
  `bp cloud azure` arms + fixture/tier honesty, not launch.
- FailureCopy azure classes already ship and classify at the JSON serialize
  boundary — S6 needs zero Elixir vocab change, only honest raw ARM strings.
- Hetzner monthly_price is REAL in prod already (S16 dividend landed with S3);
  Azure's is nil until S7a. `friendly()` drops `data.remediation` — live bug on
  the Hetzner path too, fixed by S7 for both kinds.
- `freshen` is a Hetzner-warm-pool-only step; Azure never emits it and the SPA
  hides unreported steps — no lying spinner.

Tasks: azh-w2-s5-neutral-cli-verbs, azh-w2-s6-azure-provision-job,
azh-w2-s7a-azure-retail-pricing (new), azh-w2-s7-spa-azure-card — children of
azure-hetzner-hosting-epic. Integration order S5 → S6 → S7a → S7 (S6's azure
resolution needs S5's factory at integration; all four build in parallel — S6's
Go tests use the fake kind). Non-negotiables: mix format/gofmt before every
commit; all gates offline; FULL cloud suite at integration; api/
AuditWebhooksTest red on an untouched tree = rerun, not a bug.

NOT this wave: Hetzner native cutover (S8), lifecycle verbs through the seam
(S9), portable archives (S14), metrics (S12), CP-served capability/tier conduit
for the SPA (fold into S11).

### Wave 2026-07-09c — Wire-together (S5, S6, S7a, S7) — BUILT + REVIEWED

All four slices built green and reviewer-passed. Integrate in order S5 → S6 →
S7a → S7 from the reviewer branches (`…-r` where fixed):

- **S5 · bp speaks Azure** — `loop-epic/s5-bp-speaks-azure-azure-in-providerfor--0-r`.
  Azure self-registers via factory.go init() (NAMED import in cli — the escape
  hatch needs azure.ResolveCredentials for flag>env, init still fires); Pause/
  Resume wrappers satisfy cloud.Pauser; fixture azure=core/labels/pause,
  fake=tier:dev via ProviderRow wrapper; `bp cloud instance
  list|create|delete|ip|label --provider …` with honest capability degrade;
  `bp cloud azure` escape hatch; `bp launch azure` pass-through pinned by test.
  Reviewer fix: gofmt'd the two PRE-EXISTING dirty files (table_status_test.go,
  template.go) so `gofmt -l internal/` is literally clean repo-wide.
- **S6 · Azure go-live** — `loop-epic/s6-azure-go-live-provider-region-size-cr-1-r`.
  Migration 20260709120000 (provider NOT NULL default hetzner + region/
  server_type); launch validates provider + 422 provider_not_connected w/
  remediation; claim_json threads kind + decrypted 4-tuple (hetzner payload
  byte-identical, refute-tested); Go JobSpec.Kind/Credentials + ProvisionWith
  kind-routing, pool-size-zero, SSH-pubkey prereq before any box. Reviewer fix
  (REAL bug): claim region/size fallback is now PROVIDER-AWARE — an unpinned
  azure launch (`bp launch azure --name x` sends neither) was inheriting
  Hetzner's nbg1/cax11 into the ARM call; azure rows now emit nil and the Go
  azure provider fills its own eastus/Standard_B1s defaults (+ regression test).
- **S7a · Azure retail pricing** — `loop-epic/s7a-real-azure-prices-in-the-neutral-cat-2`
  (no reviewer changes — clean). Sibling credential-free Pricing ETS client,
  decoy-proven fixtures (Spot/Low-Priority/Windows) + NextPageLink replay,
  fail-closed transport (3rd config key), nil-degrade-never-502, `currency`
  (EUR/USD) added to both normalizers. Full cloud suite 1543/0.
- **S7 · SPA Azure card** — `loop-epic/s7-spa-azure-card-4-field-verified-conne-3-r`.
  4-field verified connect w/ in-sheet remediation (friendly() drop proven);
  priced provider→region+size launch picker w/ honest
  loading/no_provider/unavailable/error states; provider chip on S4 tokens,
  #d50c2d retired. Reviewer fixes: (1) prices now render the CATALOG's currency
  — hetzner EUR was being dressed as "$" (S7a lands first, so currency is
  always present); (2) azure no_provider copy no longer promises a managed
  fallback (azure is BYO-only per Decision 17 — the old copy contradicted S6's
  422); (3) the launch-submit 422 path surfaces server remediation instead of
  friendly() dropping it (Decision 19, launch edition).

**Ledger:** S5/S6/S7a criteria stamped by builders; S7's criteria 0–5 were left
unstamped (builder believed no in_progress write path existed) — reviewer
stamped them via doc patch+publish. All four remain claimed (epoch 1) +
not-done; the LEAD closes the "PR merged" criterion + lifecycle on merge.

**Carried / next wave:**
- **Warm-pool ignores a pinned Hetzner region/size** — S7's picker + S6's claim
  thread e.g. fsn1/cx32, but tryWarmAssign hands out a default nbg1/cax11 warm
  box regardless. Charter-protected this wave (hetzner path byte-untouched);
  fix in S16/S9: skip warm assign when the pin differs from the pool's default.
- **Azure end-to-end lights up only at integration** — S6 alone can't resolve
  the azure factory (S5 registers it); after merging S5+S6 run one wired smoke
  of a kind=azure job through the real binary.
- **Azure List still O(all-VMs)** (S2 waiver, restated by S6) — scope to the
  fleet RG before real fleets grow.
- **Retail Prices first-fetch latency** — the unscoped global sheet fetch runs
  synchronously in the first catalog request after TTL expiry; consider a
  region-scoped $filter or background refresh. The armSkuName==slug join still
  needs one LIVE verification (only fixtures prove it today).
- **SPA tier conduit** (fold into S11) — CLI hides dev-tier from the fixture;
  the SPA never listed fake, but the CP-served capability/tier conduit is still
  the Wave-3 unification.
- **Recommended next wave:** S9 (neutral lifecycle verbs + SPA lifecycle
  actions — the biggest remaining parity gap now that create/launch are
  neutral), S11 (console fleet/infra tab consuming barkpark_json's new
  provider/region/server_type), and the S16 warm-pool-pin fix. S8 (hetzner
  native) and S14 (portable archives) stay behind those.

### Wave 2026-07-09d — Operate the fleet (W3: S9, S11a, S11b, warm-pool pin, pricing) — PLANNED

Waves 1+2 fully MERGED (#1629–#1633, #1661–#1664); post-integration wired smoke
passed (azure factory resolves in the real binary). Decisions 20–24 ratified
this wave. Exploration corrections folded in:

- **"Lift the hetzner lifecycle verbs to the seam" was WRONG as stated.** The
  verbs are ~1500 lines of free CLI functions on raw hcloud-go + a DNS client +
  cpFleet; the seam's only lifecycle implementer is FakeProvider, and
  HcloudProvider is a credential-less shell-out struct. Neutrality lands at the
  dispatch layer (Decision 21); the seam-guts extraction is S8 territory.
- **"Reuse the /v1/hetzner action allowlist behind neutral routes" conflated two
  surfaces.** The allowlist is RAW hcloud resources (read tier only routed);
  the lifecycle verbs' only server routes are worker-token-internal. The SPA
  action row therefore drives ONLY what the CP can already execute (the
  deprovision queue = decommission); everything else is an honest CLI
  affordance or a reasoned gap — no new user-authed lifecycle routes this wave.
- **The "CP-served conduit reading the same fixture" did not exist** (code
  comments claiming it were false). Decision 22 builds it as committed
  duplicate + byte-drift gate; conduit passes bools through generically so the
  S9 facet split and the conduit build in parallel.
- **The warm-pool pin is TWO-STACK** (Decision 23): the CP default-stamps
  nbg1/cax11 onto unpinned hetzner claims while the pool truth is env-derived
  nbg1/cx23 — a Go-only guard would skip warm for every unpinned launch.
- **Pricing serve-stale forces a fake-transport rework** (Decision 24): the
  process-dictionary fake is invisible to the GenServer; live join verification
  split to a network-gated backlog task (azh-w3-pricing-live-join-verify).

Slices/tasks (children of azure-hetzner-hosting-epic): azh-w3-s9-neutral-
lifecycle-cli (large), azh-w3-s11-capability-conduit (medium), azh-w3-s11-fleet-
lifecycle-row (medium), azh-w3-warm-pool-pin (medium, adopted + repointed to
Decision 23), azh-w3-pricing-fetch-hardening (medium, adopted + narrowed to the
offline half). Integration order: S9 → conduit (refresh the priv byte-copy from
the just-merged Go fixture — the drift gate forces it) → fleet row; warm-pool
pin and pricing are independent. Non-negotiables carried: mix format/gofmt
before every commit; all gates offline; FULL cloud suite at integration for
cloud/ slices; hetzner refute-tests; api/ AuditWebhooksTest red on an untouched
api/ tree = rerun. NOT this wave: S8, S11c infra tab, S12 metrics, S14 portable
archives.

### Wave 2026-07-09e — Operate the fleet (W3) — BUILT + REVIEWED

Four of five slices green and reviewer-passed. Integration order S9 → S11a →
(S11b when re-greened); warm-pool pin + pricing independent:

- **S9 · neutral lifecycle CLI** — merge
  `loop-epic/s9-bp-cloud-instance-lifecycle-verbs-fac-0-r`. Facet split
  (archive/resurrect/decommission/adopt/audit) in struct + fixture;
  `DetectCapabilities(kind, p)` two-source (interface OR RegisterLifecycleVerbs
  — cli dispatch table + cloud-package hetzner baseline, pinned equal by test);
  `bp cloud instance <verb> --provider …` with hetzner byte-identical
  (refute-tested) and azure CLI-level decommission (typed-confirm UNRECOVERABLE
  banner, VM+DNS+registry-detach+residue-verify) + audit (archives skipped w/
  honest note); providers matrix grew the 5 facet columns. Reviewer fix: the
  fake-provider degrade the test comment claimed is now actually asserted.
  KNOWN INCOHERENCE (small, dev-tier only): the fixture claims fake
  archive/resurrect/adopt=true via the facet interfaces, but the neutral CLI
  has no dispatch entry for fake, so those verbs degrade — a generic
  interface-driven executor would close it; fine to ship as-is.
- **S11a · capability conduit** — merge
  `loop-epic/s11a-capability-conduit-cp-serves-provid-1-r` AFTER S9 (the -r
  branch already has S9-r merged in). GET /v1/providers/capabilities
  (require_user) serves {tier, capabilities (generic bool passthrough), gaps
  (FailureCopy.capability_gap_reason/2 — no false capability reason-less)};
  priv byte-copy + byte-drift ExUnit gate. Reviewer fixes: priv fixture
  REFRESHED to the post-S9 facet bytes (criterion 4 done); FailureCopy grew
  specific azure archive/resurrect/adopt facet copy (the actual false keys
  post-S9 — the aggregated "lifecycle" clauses were dead post-split, removed).
  FULL cloud suite 1571/0 on the integrated -r branch.
- **Warm-pool pin (D23)** — merge
  `loop-epic/warm-pool-honors-a-pinned-hetzner-region-3` (no reviewer changes —
  clean). CP claims emit pin-or-nil for every provider; Go tryWarmAssign
  pin-guard vs warmBaseSpec env truth (never hardcoded); hetzner one-shot fills
  empties from FreshSpec. DEPLOY NOTE: Elixir + Go deploy from the same merge —
  an old Go worker + new CP would one-shot with an empty spec on unpinned
  launches (window is one deploy; both stacks ride the one PR).
- **Pricing serve-stale (D24)** — merge
  `loop-epic/azure-retail-prices-serve-stale-while-re-4-r`. Stale → serve +
  ONE coalesced background refresh (GenServer in-flight guard + cache
  re-check); absent → synchronous (nil-degrade preserved); fake transport now
  a cross-process named-ETS collaborator. Reviewer fix: the coalescing test
  had a real race (a fast refresh could land between the two stale reads and
  flake the assertion) — de-raced with :sys.suspend/resume.
- **S11b · console lifecycle row — STALLED, not merged.** Built + 14 new
  pure-helper tests pass, but its gate is red on ONE PRE-EXISTING failure
  (`__app.test.mjs` test 212, stale styleguide_tokens.txt golden — reviewer
  REPRODUCED it on untouched origin/main). Ledger records the stall honestly.
  Re-green by fixing the stale golden (S4/coherence-owned) on main first, then
  re-run the S11b gate on `loop-epic/s11b-console-operates-the-instance-condu-2`.

**Ledger:** all five W3 tasks in_progress, claimed (epoch 1), evidence stamped;
reviewer stamped S11a criterion 4 (post-S9 refresh) done on the -r branch. The
LEAD closes each "PR merged" criterion + lifecycle on merge.

**Carried / next wave:**
- Fix the stale `styleguide_tokens.txt` golden on main (blocks S11b's gate),
  then land S11b — the console side of "operate the fleet" is the wave's only
  gap.
- Azure audit keys on the barkpark-fqdn tag but AzureProvider.Create stamps
  only barkpark-managed — real azure boxes will flag `unlabeled-vm` until
  create stamps the fqdn tag (small follow-up; file with S11b's re-green).
- azh-w3-pricing-live-join-verify (network-gated armSkuName==slug live check)
  stays open backlog.
- After this wave merges: S10 CLI chrome parity, S13 domains/TLS checklist,
  S12 metrics, S14 portable archives (the bold bet), S8 hetzner native cutover.

### Wave 2026-07-09f — The domain story becomes provable (W4) — PLANNED

Waves 1–3 fully MERGED and live (S11b re-greened + merged; #1714–#1720).
Decisions 25–29 ratified this wave. Exploration corrections folded in:

- **No domain-health truth exists anywhere**: attach is a fire-and-forget
  ProvisionJob (worker-plan success ≠ domain healthy), the SPA shows one rail
  row + a toast, and NO code in the CP resolves DNS / dials TLS / probes HTTP.
  S13a builds the prober from zero, on the Verify template (the near-verbatim
  precedent: injectable transport, structured probes, both surfaces already
  consume it).
- **The probe MUST be CP-side** — a browser cannot resolve DNS or dial TLS;
  CLI-side probing would fork the truth. Confirmed the tentative architecture.
- **The fqdn-tag task premise was half-wrong**: go-live azure boxes already
  get barkpark-fqdn via ProvisionOneShot's fail-closed labelFQDN on the
  kind-routed provider. Task repointed (Decision 28) at the real gaps: the
  direct-create escape path (both providers) + the audit's missing
  barkpark-warm exemption.
- **S10 is not "build a formatter"** — renderHzTable is already the single
  shared table path (33 call sites, both providers) and already holds the
  writer; the work is a header-driven, color-gated paint step (Decision 27).
  No byte-golden pins any hetzner table; the color-off byte-identity contract
  is satisfiable by construction.
- **The fake-honesty fix is small and additive** (Decision 29): the generic
  facet executor mirrors runCloudInstancePause in the same file; azure/hetzner
  routing untouched.

Slices/tasks (children of azure-hetzner-hosting-epic):
azh-w4-s13a-domain-status-prober (large, P0, Elixir-only),
azh-w4-s13b-domain-status-surfaces (large, P1, Go cloudclient/CLI + the
app.js slice — solo owner of app.js this wave),
azh-w4-s10-cli-chrome-parity (medium, P1, Go CLI),
azh-w4-azure-fqdn-tag-on-create (small, P1, ADOPTED + repointed),
azh-w4-fake-lifecycle-dispatch-honesty (small, P2, Go CLI).
All five build in parallel — S13b builds against the Decision 25 response
contract (pinned in both tasks), integration order S13a → S13b. The two small
Go slices touch different regions of cloud_instance_lifecycle_cmd.go{,_test}
— auto-mergeable; integrate honesty → fqdn → S10. Non-negotiables carried:
mix format/gofmt every commit; ALL gates offline (every prober primitive
injectable, fail-closed); FULL cloud suite at integration for cloud/ slices;
hetzner behavior changes need refute-tests; api/ AuditWebhooksTest +
StudioLiveSheetPresenceTest reds on an untouched api/ tree are rerun-worthy.
NOT this wave: S8 hetzner-native, S14 portable archives, S12 metrics,
azh-w3-pricing-live-join-verify (network-gated), external-domain attach
(the status shape is domain-agnostic; the attach surface is not built).

### Wave 2026-07-09g — The domain story becomes provable (W4) — BUILT + REVIEWED

All five slices green and reviewer-passed. Whole-wave integration PROVEN on a
scratch merge of all five final branches (Go build/vet/test fresh, node 263/0,
FULL cloud suite 1596/0). Integrate S13a → S13b, honesty → fqdn → S10:

- **S13a · domain-status prober** — merge
  `loop-epic/w4-s13a-domain-status-prober-cp-answers--0-r`.
  BarkparkCloud.DomainStatus on the Verify template: 4 ordered stages
  (dns_found → points_here → tls → serving), three fail-closed injectable
  seams + offline test guard, FailureCopy.domain_stage_remediation/2
  (platform-Caddy vs custom-/v1/tls/ask stories, terminal default), team-scoped
  no-leak route. Reviewer fixes (one REAL product bug): (1) serving required
  strict 2xx but a HEALTHY instance root returns 302 (proven live on prod) —
  every live box would have shipped serving:failed; now <500 per the Verify
  doctrine, protective 302-test added. (2) points_here canonicalizes a stored
  IPv6 host through parse+ntoa (non-canonical form no longer reads "points
  elsewhere"). (3) The greenfield TLS DER decode (the builder's own top blind
  spot) is now exercised REAL against a loopback :ssl server (pkix_test_data
  chain; RSA keys — the generator default can't satisfy TLS1.3 sig-algs) + a
  refused-port error-path test. 24 tests; full suite 1596/0.
- **S13b · both surfaces** — merge
  `loop-epic/w4-s13b-domain-status-on-both-surfaces-b-1-r` AFTER S13a (the -r
  branch already has S13a-r merged in; integrated gates green). Go
  cloudclient.DomainStatus + `bp cloud domain status <name>` (server
  remediation verbatim, -o json = CP bytes, exit 0 only when serving); SPA
  domainStages pure fold + #instance-domains rail checklist w/ 4s poll,
  attach-toast replaced by the live checklist. Reviewer fixes: comment/copy
  accuracy only (pending paints cyan/info not yellow; a node test titled
  "failed is terminal — no infinite poll" actually asserts NOT-terminal —
  retitled: a skipped-pending rung downstream keeps polling so the operator
  can fix + watch). Note: a hard-failed SERVING rung (all upstream ok) does
  stop the poll — inconsistent with the fix-and-watch story; small S16-grade
  follow-up if a live look wants it. Checklist may want a rail width tweak in
  app.css after a live look (out of slice scope). A cross-surface fixture
  pinning the envelope for Go+JS remains unfiled (builder + reviewer agree
  it's the durable guard).
- **honesty · fake lifecycle dispatch** — merge
  `loop-epic/w4-fake-provider-lifecycle-verbs-actuall-4` (CLEAN — no reviewer
  changes). runNeutralFacet generic facet executor at the !known branch only;
  hetzner/azure byte-untouched; degrade refute now uses a genuinely facet-less
  provider; fake archive/adopt/decommission(±not-found)/audit proven executing.
  Fake resurrect success path is untested (a fresh per-call fake has no archive
  to resurrect — honest not-found by construction).
- **fqdn · direct-create identity** — merge
  `loop-epic/direct-create-boxes-get-their-barkpark-f-3-r` AFTER honesty (the
  -r branch already has honesty merged in — the shared-file auto-merge is
  proven green). doInstanceCreate stamps cloud.Fqdn(name, instDefaultZone) via
  ServerLabeler on BOTH providers, loud failure naming the box + copy-paste fix
  command; azure audit exempts barkpark-warm boxes; create-then-audit-clean +
  truly-unlabeled refute + warm-exemption + Tags-PATCH-Merge assert (transport
  fake grew request-body capture). No reviewer code changes.
- **S10 · CLI table chrome** — merge
  `loop-epic/w4-s10-cli-table-chrome-provider-marks-l-2` (CLEAN — no reviewer
  changes). Header-driven paint step in renderHzTable: PROVIDER →
  GenProviderMark, STATUS/STATE/LIFECYCLE → GenInstanceLifecycle role hue;
  unknown values + neutral-role states unpainted; color-off BYTE-IDENTICAL
  (golden'd in TrueColor + Ascii + no-color byte-identity + strip-and-compare
  tint-only). HONEST CAVEAT: no current caller emits a PROVIDER column and
  hetzner STATUS cells carry raw hcloud vocab ("running") — operator-visible
  tint lights up only when fleet rows emit the neutral vocabulary (S11b/S15
  follow-on).

**Ledger:** all five tasks claimed (epoch 1), in_progress, criteria stamped
with honest evidence, "PR merged" left open — the LEAD closes it + lifecycle
on merge. Builders' criteria patches changed each task's work_digest, so
`bp task close` will 409 doc_changed_since_claim — re-read then close (by
design). No ledger fixes were needed this wave.

**Carried / next wave:**
- The wish's last unbuilt first-class pillar is MONITORING — S12 (agent
  vitals beat + Metrics tab + `bp cloud instance top`) is the biggest
  remaining wish gap; S14 portable archives is the bold differentiator the
  vision names as the payoff. Recommended: take S12 next (closes the wish's
  five-pillar promise on both providers), with the small S10-activation work
  (fleet rows emit PROVIDER + neutral lifecycle STATUS through renderHzTable)
  riding along; then S14 as its own dedicated wave; S8/S11c/S15/S16 behind.
- Small follow-ups worth filing with S16: domain-status cross-surface fixture
  (Go+JS pin of the envelope); keep-polling-on-failed-serving; app.css rail
  width for the domain checklist; fake resurrect round-trip once archives
  hold state across invocations (S14 gives them a substrate).
- Deploy note (S13a): the prober runs in-process on the CP — no migration, no
  worker change; the route is live the moment cloud/ deploys.
