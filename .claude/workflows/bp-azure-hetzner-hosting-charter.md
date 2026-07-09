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

30. **Vitals ride the EXISTING agent beat; the metrics window is the durable
    `agent_events` table — NOT a new ETS ring, NOT a new ingest route.**
    Exploration disproved "the beat ingest is new": an authenticated on-box →
    CP push channel is code-complete end to end — the Go agent's 60s loop
    POSTs a Report to `POST /v1/agent/report` (per-instance agent bearer
    token, `Auth.require_agent`), and the handler already lands the FULL
    payload append-only as a `type:"health"` AgentEvent
    (`Registry.record_event`, router.ex:549) — any new Report field persists
    with ZERO route change. So S12a's carrier = three new Report fields
    (`cpu_percent`, `mem_used_percent`, `load1`; -1 sentinel = not-wired, the
    DiskProbe idiom) behind injectable probes (Linux /proc readers; fail-soft
    -1 elsewhere — a partial box still phones home). The window: the
    tentative "ETS ring unless precedent says table" resolved to TABLE —
    `/telemetry` already reads a rolling 100-event window of `agent_events`
    (compound-indexed, append-only), the CP is single-node blue/green with a
    fresh BEAM on every ~daily deploy (an ETS ring = empty charts after every
    flip, ~30 min to refill), and vitals riding the one-per-60s beat add ZERO
    new rows. Data cadence is the 60s beat; any "4s poll" is REFRESH cadence
    only. Pre-existing gap, not worsened: `agent_events` has no pruner —
    retention is a filed follow-up, never this wave's scope.
31. **One metrics envelope; the CP computes, consumers only render (conduit
    doctrine, third time).** New pure `BarkparkCloud.Metrics` (sibling of
    Telemetry/Usage — those stay untouched) reduces the health-event window
    to series; route `GET /v1/barkparks/:id/metrics?points=N` (require_user,
    team-scoped via resolve-or-404 no-leak, sibling of telemetry/usage;
    points clamped default 30 cap 200). Envelope, pinned verbatim in BOTH
    consumer briefs: `{ok, collected_at, instance:{id,host,provider},
    beat:{last_seen_at, age_seconds, status: live|stale|absent}, points,
    series:{cpu|mem|disk|load: [{at, value|null}] oldest→newest},
    service_health:{pass,total,failing:[]}}`. `stale` reuses
    `Registry.health_stale_after_seconds()` (180s — the CP-wide degraded
    definition the StalenessWorker enforces; NEVER a new threshold); `absent`
    = no health event yet. Honesty: value is null when that vital was absent
    in that beat (disk -1 → null; nil-not-zero, the Telemetry doctrine) —
    consumers render "waiting for first beat"/"last seen Xm ago", never
    zeros dressed as data.
32. **Consumers: Metrics = a 5th INSTANCE_TAB + the domain-checklist poll
    idiom; `bp cloud instance top` is ONE-SHOT.** SPA: "metrics" joins
    INSTANCE_TABS (registered only once the route is live — the 1694
    discipline), mount modeled on mountUsageTab, refresh via the
    loadInstanceDomains 4s seq-guarded self-limiting poll; charts are
    GREENFIELD (zero chart code exists in the SPA) — a hand-rolled pure
    string-returning SVG sparkline helper + a pure `metricsSeries(payload)`
    reducer, both exported via `__bpTestHook` and node-pinned; colors read
    the S4 role vars/`.bp-inst--*` tokens, no new hex. Go: `cloudclient.
    Metrics` + `bp cloud instance top <name>` copy the DomainStatus/
    `runCloudDomainStatus` template 1:1 (`-o json` = CP bytes verbatim);
    terminal rendering adapts the envelope into pdrender `stat-grid`/`chart`
    Blocks via an Attrs adapter (there is NO gauge block — "gauge" =
    stat/statBar); ONE-SHOT only — no `--watch` this wave (zero
    ticker/watch precedent in any cloud command; net-new machinery, filed
    follow-on), which also matches the 60s data cadence.
33. **The beat goes LIVE via provisioning (S12c) — mint + install, offline-
    gated.** Today the agent never runs on a provisioned box
    (`mint_agent_token` is test-only, `bp agent install` is render-only, no
    barkpark-agent.service exists) — without this slice the wave's pillar is
    dark in prod. Fix at the two existing seams: the CP mints the
    per-instance agent token at provision-claim time and threads it into
    `claim_json` (the decrypted-env-at-claim precedent, router.ex:6411);
    the Go configure step writes `/etc/barkpark/agent.token` (0600) +
    installs/enables a NEW `deploy/systemd/barkpark-agent.service`
    (`--control-url` + `--token-file`; the binary is already built on-box by
    freshen). instance-deploy.sh keeps the unit installed on self-update.
    The hetzner claim-payload refute-test updates INTENTIONALLY (the D23
    move — old bytes lacked the token). `bp agent install` stays
    render-only; adopted-box/existing-fleet install is a documented manual
    path + go-live note, not this slice. All gates offline (fake runner,
    ExUnit claim assert).
34. **S10-activation = the REGISTRY fold only; the provider seam is not
    touched.** Exploration corrected two premises: (a) `bp barkparks` cloud
    is NOT a renderHzTable caller — it has a bespoke golden-pinned renderer;
    activation = MIGRATE it to renderHzTable with PROVIDER + STATUS columns
    (goldens updated intentionally). (b) The direction's "one mapping table
    from {hcloud states, Azure power states, registry lifecycle}" is
    aspirational — neither provider's List() fetches a power state
    (cloud.Server has no status field), so the ONLY leg that can flow today
    is registry lifecycle. The map is ONE new Go function
    (`registryLifecycleToken(b cloudclient.Barkpark) → 7-token key`), a
    faithful port of app.js `lifecyclePillState` (:674-682 +
    instanceLifecycle booleans), in internal/cli next to its consumer — NOT
    in semrole (token vocab only), NOT via `attentionStatus` (a different
    8-label vocabulary, D32-fixture-pinned — touching it reds the gate).
    `cloudclient.Barkpark` gains the `provider` field (CP already emits it,
    Decision 9). `bp cloud instance list` gains a PROVIDER column for free
    (the `kind` param). Scoped OUT: a neutral STATUS on the seam list (a
    CloudProvider-interface change — both providers + fake; S8-adjacent);
    the `bp cloud hetzner server list` escape hatch stays raw + byte-
    identical (charter contract).
35. **Domain-status followups, resolved.** (a) The cross-surface fixture is
    ExUnit-GENERATED, not hand-committed — THREE hand-authored envelope
    samples exist today (Go test, node test, real server) and they already
    DISAGREE on labels/evidence/remediation-null; the generator folds
    canonical fake-seam cases (all-serving, mid-issuance, serving-failed)
    through the real `DomainStatus.check/2`, freezes `checked_at` +
    instance id, writes ONE cloud/-rooted committed file all three test
    runtimes read (fmt-display-parity pattern) — Go+node inline literals
    are replaced and their label asserts move to the real server strings.
    (b) Failed-serving keeps polling, NARROWLY: only `role==="failed" &&
    stage==="serving"` is non-terminal (an app restart heals HTTPS-down;
    NXDOMAIN stays terminal-by-trailing-pending as today). Go behavior
    UNCHANGED — `bp cloud domain status` stays one-shot and serving-failed
    stays exit-nonzero (a not-yet-serving box is not live); only help copy
    gains the "recoverable — re-run after restart" story. (c) Rail width via
    a SCOPED grid modifier on the instance workspace only — the 260px
    `.detail-grid` is shared with site-deploys, which must not widen.

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
  [W5, split] — Decisions 13, 30–33. S12a = Report vitals fields + probes +
  `BarkparkCloud.Metrics` + `GET /v1/barkparks/:id/metrics` (medium). S12b =
  the two consumers: SPA Metrics tab + `bp cloud instance top` (large, solo
  app.js owner). S12c = agent enablement: token minted at claim + token file +
  barkpark-agent.service installed by configure (medium).
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

### Wave 2026-07-09h — The fleet gets a pulse (W5: S12a/b/c, S10-activation, domain followups) — PLANNED

Waves 1–4 fully MERGED (#1629–#1633, #1661–#1664, #1714–#1720, #1736–#1740,
charter sync #1745). Monitoring is the wish's last dark pillar. Decisions
30–35 ratified this wave. Exploration corrections folded in:

- **"Fake the beat ingest as if it's new" was WRONG** — the push channel is
  code-complete end to end (60s agent loop → `POST /v1/agent/report`,
  per-instance agent token, full payload landed as an append-only "health"
  AgentEvent). Vitals are a Report payload extension; ingest/auth work ≈ zero
  (Decision 30).
- **The window-store precedent says TABLE, not ETS ring** — `/telemetry`
  already reads a rolling agent_events window; the CP is single-node
  blue/green with ~daily fresh-BEAM deploys (a ring = empty charts after
  every flip). Vitals ride the existing beat: zero new rows (Decision 30).
- **The beat is DARK in prod** — the agent is never installed on provisioned
  boxes (mint_agent_token test-only, `bp agent install` render-only, no
  systemd unit). New slice S12c makes it real at the existing seams
  (claim_json token threading + configure-step install), offline-gated
  (Decision 33).
- **The SPA has ZERO chart code** (two static icon SVGs only) and the cloud
  CLI has ZERO watch/ticker precedent — sparkline is greenfield-pure-helper
  work; `top` ships one-shot, `--watch` is a filed follow-on (Decision 32).
  pdrender has NO gauge block — stat/stat-grid/chart are the vocabulary.
- **S10-activation had two wrong premises** — the registry fleet table is
  bespoke (not renderHzTable) and no provider List() fetches a power state;
  activation = migrate the registry table + port lifecyclePillState to Go +
  PROVIDER column on the seam list; neutral STATUS on the seam list is
  scoped OUT (Decision 34).
- **The domain-status envelope has THREE drifting hand samples** (Go, node,
  real server disagree on labels/evidence/null-remediation) — the committed
  fixture must be ExUnit-generated from the real prober, replacing both
  inline sample sets (Decision 35).

Slices/tasks (children of azure-hetzner-hosting-epic):
azh-w5-s12a-vitals-beat-metrics-route (medium, P0, Go agent + Elixir CP),
azh-w5-s12b-metrics-consumers (large, P1, Go CLI + THE app.js slice — solo
owner of all app.js regions except the 3-line domainStages fold),
azh-w5-s12c-agent-enablement (medium, P1, Elixir claim + Go worker + deploy/),
azh-w5-s10-activation-fleet-vocab (medium, P2, Go CLI),
azh-w5-domain-status-followups (medium, P2, ADOPTED + repointed to D35).
All five build in parallel — S12b builds against the Decision 31 envelope
(pinned in both tasks); integration order S12a → S12b (tab registers only
when the route is live), S12c independent, S10-activation independent,
followups' app.js touch (domainStages terminal fold ~3985) is
region-disjoint from S12b — integrate S12b first, expect auto-merge. Shared
file internal/cloudclient/client.go: S12b adds Metrics (DomainStatus region),
S10 adds one Barkpark field — disjoint regions. Non-negotiables carried: mix
format/gofmt every commit; ALL gates offline (fake reports, deterministic
clock, no live boxes); FULL cloud suite at integration for cloud/ slices;
hetzner-visible behavior changes need refute-tests; api/ AuditWebhooksTest +
StudioLiveSheetPresenceTest reds on an untouched api/ tree are rerun-worthy;
app.js work stays in the node:vm __bpTestHook harness — do not grow the
browser-mount zone. NOT this wave: S14 portable archives (own dedicated wave
next), S8 hetzner-native, S11c infra tab, azh-w3-pricing-live-join-verify
(network-gated), agent_events retention pruner (filed follow-up), `--watch`
on `top` (filed follow-on).

Ledger: all five wave tasks FILED + PUBLISHED under azure-hetzner-hosting-epic
(2026-07-09): azh-w5-s12a-vitals-beat-metrics-route (P0),
azh-w5-s12b-metrics-consumers (P1), azh-w5-s12c-agent-enablement (P1),
azh-w5-s10-activation-fleet-vocab (P2), azh-w5-domain-status-followups
(P2, adopted — description + criteria repointed to Decision 35, rail-width
promoted to a criterion, S14-gated resurrect item stays out). Each carries
the pinned Decision-31 envelope / file anchors / offline gates in its brief
and a lead-closed "PR merged" criterion. Read-back verified: published, not
drafts, parented, criteria unmet.

### Wave 2026-07-09i — The fleet gets a pulse (W5) — BUILT + REVIEWED

All five slices green and reviewer-passed. Whole-wave integration PROVEN on a
scratch merge of all five final branches in order (zero conflicts; Go
build/vet/test whole-tree fresh, gofmt clean, node harness 274/0, FULL cloud
suite 1619/0). Integrate S12a → S12b → followups (shared app.js, regions
disjoint — auto-merge proven), S12c and S10-activation any order:

- **S12a · vitals beat + metrics route** — merge
  `loop-epic/w5-s12a-vitals-ride-the-agent-beat-cpu-m-0` (CLEAN — no reviewer
  changes). Report gains cpu_percent/mem_used_percent/load1 behind injectable
  probes (-1 sentinel, independently fail-soft, real-0≠sentinel proven);
  dep-free /proc readers wired in cmd/barkpark-agent/main.go; pure/total
  BarkparkCloud.Metrics folds the agent_events health window into the pinned
  D31 envelope (nil-not-zero; stale keyed off health_stale_after_seconds —
  AgentEvent timestamps verified utc_datetime_usec so the stale fold really
  fires); GET /v1/barkparks/:id/metrics require_user + no-leak 404, points
  clamped 30/200. 14+7 ExUnit; route tests cover 401/404-no-leak/clamp/absent.
  Integrator note: main.go is also touched by S12c — scratch merge proved
  clean.
- **S12b · both consumers** — merge
  `loop-epic/w5-s12b-metrics-rendered-on-both-surface-1` (CLEAN) AFTER S12a.
  The builder's route-path guess matches S12a exactly
  (/v1/barkparks/:id/metrics?points=N) — the flagged risk is void. SPA: 5th
  INSTANCE_TAB, pure metricsSeries + gap-honest sparklineSvg (a null breaks
  the stroke; api() never rejects, so the 4s poll always lands in an honest
  error state with Retry, never a dead spinner). Go: cloudclient.Metrics (Raw
  bytes verbatim) + one-shot `bp cloud instance top` via pdrender
  stat-grid+chart; no --watch pinned by test. Metric-card colors are
  IDENTITY-by-role-var (disk always warn-tinted regardless of value) —
  S15-grade polish candidate, not a defect.
- **followups · domain-status (D35)** — merge
  `loop-epic/domain-status-checklist-follow-ups-exuni-4` (CLEAN) AFTER S12b
  (shared app.js; auto-merge proven on the scratch merge). ExUnit-GENERATED
  cross-surface fixture (sorted-key OrderedObject → byte-stable across boots;
  drift-gated; Go test + node harness now read the ONE file, label asserts
  moved to the real server strings); failed-serving keeps polling NARROWLY
  (failed&&serving only, narrowness refute added); scoped
  .detail-grid--instance 340px rail (site-deploys grid byte-identical).
  Closes W4's carried fixture + poll-on-failed-serving + rail-width
  follow-ups in one slice.
- **S12c · agent enablement (D33)** — merge
  `loop-epic/w5-s12c-the-beat-goes-live-agent-token-m-2` (CLEAN). claim_json
  mints a per-instance "report" token (plaintext-once, fail-open) for BOTH
  providers; configure gains a NON-FATAL agentInstallStep (builds
  barkpark-agent on-box, token file 0600, EnvironmentFile-driven committed
  unit; injection-guarded — token alphabet verified base64url ⊂
  secretValueAlphabet, URLs shape-validated before shell interpolation);
  instance-deploy.sh refreshes the agent on self-update (armed boxes only).
  Reviewer verified POST /v1/agent/report already exists on main — the
  builder's "agent 404s until S12a" fear is MOOT (beats land today; S12a only
  adds the read route). REAL DEPLOY CAVEATS for the lead: (1) provisioning
  now runs `go build` on-box (seconds; degrades loudly if Go is missing);
  (2) systemd ${VAR} EnvironmentFile expansion is standard but smoke-test the
  first real provision; (3) every re-claim mints a fresh token row (no
  pruner — file with the agent_events retention follow-up).
- **S10-activation · fleet vocab (D34)** — merge
  `loop-epic/w5-s10-activation-fleet-rows-finally-spe-3-r` (REVIEWER FIX; this
  -r branch also carries the wave-log charter sync). registryLifecycleToken
  verified a VERBATIM port of lifecyclePillState/instanceLifecycle (same
  ladder, same precedence, JS-mirrored test); cloudclient.Barkpark.Provider
  (CP emits it — verified in barkpark_json); fleet table migrated to
  renderHzTable w/ PROVIDER+STATUS, tint-only color proven. Reviewer fix:
  fleet cells now ride hzCell like every other renderHzTable call site — a
  raw ESC in a CP-supplied name/url no longer reaches the terminal
  (protective test added) and empty PROVIDER/STATUS cells render the house
  em-dash, not a bare gap (golden regenerated).

**Ledger:** all five tasks claimed (epoch 1), in_progress, criteria stamped
with honest evidence, "PR merged" left open — the LEAD closes it + lifecycle
on merge. Prior-wave tasks untouched (azh-w3-pricing-live-join-verify
correctly still open backlog). No ledger fixes were needed.

**Carried / next wave:**
- With W5 merged, ALL FIVE wish pillars (provision/deploy/domains/lifecycle/
  monitoring) are first-class on both providers from both surfaces. The bold
  differentiator remains: **S14 portable archives** (archive → object-storage
  bundle → resurrect on the OTHER provider) — take it as its own dedicated
  wave, as planned. It also unlocks the parked azure adopt/resurrect facets
  (D20) and the fake-resurrect round-trip test.
- After S14: S8 hetzner-native cutover, S11c infra tab, S15 styleguide
  completeness (fold in: raw-vocab STATUS capitalization polish + the
  metric-card role-color identity question), S16 hetzner journey polish.
- Small follow-ups to file: token-row + agent_events retention pruner (S12c
  mints per re-claim, rows accumulate); `--watch` on `top` (filed follow-on);
  one live smoke after merge — barkpark-agent.service on a freshly
  provisioned box (systemd env expansion + go-build-on-box) and the Metrics
  tab against a real beat.
- Deploy note: S12c changes provisioning (Go worker) + claim (CP) — both ride
  one merge like the D23 pin fix; agents on EXISTING boxes appear only after
  their next self-update or the manual install recipe in the go-live doc.

### Wave 2026-07-09j — Portable archives (W6: S14a–e) — BUILT + REVIEWED

The bold bet, built in five parallel slices (decisions D36–D42 ratified at
planning: D36 identity set = bp-export-v1 + BARKPARK_KEK/+PREVIOUS-when-set;
D39 CP archive read = dep-free SigV4 conduit; D40 resurrect rides the SAME 7
provision steps, never warm-assigns; D41 azure freshen = from-scratch
base-install script; D42 honesty flips atomic with the capability). NOTE: the
planning entry never landed in this file — this entry carries it. Whole-wave
integration PROVEN on a scratch merge of all five final branches (Go
whole-tree build/vet/test fresh, gofmt clean, node harness 282/0, FULL cloud
suite 1651/0). Integrate S14a → S14b-r → S14c → S14d-r → S14e-r (the -r
branches already contain their upstream siblings — S14b-r has S14a merged;
S14d-r has S14a+S14b-r merged with the fixture-line union resolved):

- **S14a · bundle library** — merge
  `loop-epic/s14a-bp-bundle-v1-portable-bundle-format-0` (CLEAN — no reviewer
  changes). Pinned bp-bundle-v1 manifest (byte-locked test), manifest-last
  completeness fence, newest-first reader, AES-256-GCM secrets envelope
  (SHA256(BARKPARK_BUNDLE_KEK) key derivation — a cross-language sealer must
  replicate it, noted), D36 identity set, BundleStore seam + objstore adapter
  + exported stateful FakeBundleStore; FakeProvider archives became stateful.
- **S14b · neutral archive = the bundle** — merge
  `loop-epic/s14b-neutral-archive-portable-bundle-eve-1-r`. REVIEWER DID THE
  S14A INTEGRATION: the builder's offline stand-in substrate had drifted off
  the pinned contract (own manifest shape provider/team/created, own stamp
  format, and — the real bug — an objBundleStore that stored identity secrets
  UNSEALED) and its collection script omitted BARKPARK_KEK(+PREVIOUS), a D36
  violation. Rewired to cloud.WriteBundle (secrets sealed for real,
  sealed-at-rest asserted in tests), script keys now derive from
  cloud.IdentitySecretKeys, CLI-side D36 filter via SelectIdentitySecrets,
  loud BARKPARK_BUNDLE_KEK gate BEFORE collection, archives list reads via
  ReadManifest. --fast==escape-hatch byte-identity kept; azure archive:true
  honesty flip kept.
- **S14c · CP resurrect plumbing** — merge
  `loop-epic/s14c-resurrect-rides-the-job-machine-cp--2` (CLEAN — no reviewer
  changes). kind=resurrect (4th kind, same 7 steps, one-active guard,
  bundle_ref required-when-resurrect), POST /v1/resurrect (require_user +
  team-admin + ENTITLEMENT-gated — the builder's added 402 is right: a
  resurrect stands up a billed box), nil-honest fresh row, live-twin 422,
  enqueue-failure rolls the row back (no lying 202), worker claim route =
  provision claim payload + bundle_ref. Hetzner provision claim refute passes
  UNMODIFIED.
- **S14d · cross-provider restore** — merge
  `loop-epic/s14d-cross-provider-resurrect-restore-on-3-r` AFTER S14c.
  RestoreDriver seam + provisionRestore (7-step feed, cold create, KEK
  carried-never-minted refused-if-missing, drop→pg_restore→migrate content
  phase, template suppressed), deploy/azure-base-install.sh (D41), round-trip
  proven offline BOTH directions. Reviewer fixes (two REAL contract bugs
  proven against S14c's route): the portable-resurrect CLI POSTed on the
  WORKER token where the route is require_user (every real call would 401) —
  now cloudclient.Resurrect on the user-bearer `bp launch` plane; and it sent
  the archive as "bundle" where the route requires "bundle_ref" (422 always).
  Newest-default is resolved CLIENT-side from the bundle store (S14c 422s a
  blank bundle_ref); no archive → honest not-found, CP never POSTed. Also the
  fixture-union merge: azure archive+resurrect both true, adopt stays false,
  degrade test moved to adopt, FailureCopy's dead azure archive+resurrect
  clauses both removed.
- **S14e · console archives panel** — merge
  `loop-epic/s14e-archives-visible-in-the-console-dep-4-r` last. Dep-free
  SigV4 GET conduit (AWS known-answer vectors — non-vacuous), :xmerl added to
  extra_applications (OTP app, NOT a hex dep — release-correctness over the
  literal "mix.exs untouched" criterion; endorse), team-prefix scoping proven,
  502-never-lying-empty, honest 4-state SPA panel + copy-paste resurrect
  affordance. Reviewer fix: bundle_ref fallback now the bundle PREFIX (minus
  manifest.json) so a console row's ref is directly consumable as --bundle /
  POST bundle_ref.

**What is NOT yet live (the honest end-to-end gap, next wave's spine):** the
worker never POLLS /v1/internal/resurrect-jobs/claim — S14d keys restore off
JobSpec.BundleRef, but no drain translates S14c's claim (bundle_ref STRING)
into S14d's BundleRef struct {store,key,kek,manifest}, and nobody decides how
the worker gets BARKPARK_BUNDLE_KEK + store creds (worker env is the obvious
answer — the KEK must NOT ride the claim JSON unless deliberately sanctioned
like env-at-claim). The RestoreDriver's real implementation (ProvisionOneShot
in restore mode + pg_restore over the box runner + media unpack) is also
behind the seam, offline-proven but unwired. File "S14f · resurrect drain +
real RestoreDriver" as the wave-after slice; until it lands, resurrect
enqueues honestly and the job sits pending.

**Ledger:** five tasks evidence-stamped by builders; claims had lapsed AND
lifecycle sat "open" — S14a–d were showing in `bp task ready` (double-work
hazard). Reviewer patched all five to in_progress + republished. "PR merged"
criteria stay open — the LEAD closes them + lifecycle on merge (re-claim for
a fresh epoch; claims are lapsed). Human-gated follow-up
azh-s14d-azure-base-install-live-smoke filed + published by the S14d builder.

**Carried / next wave:**
- **S14f (file it): the resurrect worker drain** — poll the claim route, map
  claim bundle_ref → BundleRef (store creds + KEK from worker env), implement
  RestoreDriver for real (restore-mode one-shot, pg_restore, media unpack),
  then ONE wired smoke: archive a real box → resurrect cross-provider.
- Server-side newest-bundle resolution on POST /v1/resurrect via S14e's
  ArchiveStore (the CLI's client-side resolution needs platform S3 creds —
  fine for operators, wrong for team admins long-term); console "Resurrect"
  button rides the same route once the drain exists.
- Bundle spec hints (region/server_type) are always empty at archive time —
  populate best-effort so a resurrect can re-shape the target.
- Two same-second archives of one fqdn share a prefix (whole-second stamp) —
  last write wins; harmless today, note for the drain.
- After S14f: S8 hetzner-native cutover, S11c infra tab, S15 styleguide
  completeness, S16 hetzner journey polish (fold in: archives panel live
  look; the S14e live-Hetzner-S3 signing smoke, network-gated).
