# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.
import Config

config :barkpark_cloud,
  ecto_repos: [BarkparkCloud.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# site-spawner W5 (charter D45): the control plane's OWN public origin — the host a
# co-located box POSTs a content-publish webhook back to (guerrilla →
# barkpark.cloud). Used to build the per-site receiver URL registered on the box.
# Prod overrides from PUBLIC_URL / CONTROL_PLANE_URL in runtime.exs; this default
# is the prod API host so an unset env still points at a real receiver.
config :barkpark_cloud, :public_url, "https://api.barkpark.cloud"

# cch-w1-peer-ip-pin: the peers whose X-Forwarded-For may move conn.remote_ip
# (Web.Router.trusted_peer?/1). Loopback is ALWAYS trusted in code; this list is
# the extra front-door peers on top of it.
#
# The default is the docker bridge gateway, because Caddy runs as a HOST service
# proxying to localhost:4100 and Docker's hairpin NAT rewrites the source the
# container sees to the gateway — so in prod the peer is the gateway, never
# 127.0.0.1. This value is PINNED to a single address, never a CIDR range: with
# a 172.16/12 widening, peer {172,18,0,77} was measured forging 203.0.113.5, and
# cloud-postfix-1 sits on 172.18.0.2 publishing 0.0.0.0:587 to the internet.
#
# It MUST agree with the `networks.default.ipam` subnet pinned in
# cloud/docker-compose.yml; runtime.exs overrides it from TRUSTED_PROXY_PEERS so
# an operator who moves the bridge changes both in one place. Entries are :inet
# address tuples.
config :barkpark_cloud, :trusted_proxy_peers, [{172, 18, 0, 1}]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing
config :ecto, json_library: Jason

# Registry (cloud-9): the at-rest encryption key for connected-provider tokens
# (e.g. the Hetzner API token a Team links). This is a 32-byte AES-256-GCM key,
# Base64-encoded. The value here is a DEV/TEST default ONLY — prod overrides it
# from the REGISTRY_ENCRYPTION_KEY env var in runtime.exs. Real key management
# (rotation, a KMS/HSM, per-tenant keys) is a later/human concern; this is the
# encrypt-at-rest SEAM, deliberately simple. See BarkparkCloud.Registry.Vault.
config :barkpark_cloud, BarkparkCloud.Registry.Vault,
  key: "kvm81OuQQi9o5bZpN2Lb2yKkNH+Mi5LjaJtKc9nAMi0="

# Billing (cloud-5): which BarkparkCloud.Billing.Gateway runs. Default to the
# in-memory StubGateway — no network, deterministic ids, €0 spend — so the whole
# pay-once go-live path is buildable and testable without any payment provider.
# runtime.exs swaps in BarkparkCloud.Billing.StripeGateway in prod when
# STRIPE_SECRET_KEY is set. Live keys + the per-plan price ids are HUMAN task
# cloud-17. See BarkparkCloud.Billing.Gateway.
config :barkpark_cloud, BarkparkCloud.Billing,
  gateway: BarkparkCloud.Billing.StubGateway,
  # Plan → gateway-side price id (cloud-17). PLACEHOLDERS in dev/test — a human
  # wires the REAL Stripe price ids at Gate 4; runtime.exs overrides each from
  # STRIPE_PRICE_<PLAN> in prod. "free" has NO price → it never opens a checkout.
  prices: %{
    "supporter" => "price_PLACEHOLDER_supporter",
    "support_plus" => "price_PLACEHOLDER_support_plus"
  },
  # Plan → the max number of managed Barkpark instances a team on that plan may
  # hold (usage-limits-quotas). This is the QUOTA half of go-live — Coolify's
  # `Team::serverLimit` — distinct from the ENTITLEMENT half (active-or-not,
  # the 402 gate), which already gates launch. These are PLACEHOLDER ceilings;
  # the real commercial numbers are HUMAN task cloud-17, the same gate as
  # `prices`. runtime.exs makes the self-serve tiers env-overridable in prod.
  # Every plan that can be an ACTIVE subscription needs a key: `trial` is the
  # signup grant (BILL-1) and `forever` is the admin comp (effectively
  # unlimited). `none` is the fallback for a team with NO active subscription
  # (already 402-blocked at go-live; 0 keeps the internal register path honest).
  limits: %{
    "free" => 1,
    "trial" => 1,
    "supporter" => 3,
    "support_plus" => 10,
    "forever" => 1_000_000,
    "none" => 0
  }

# GitHub App (gh-2): the config-selected GitHub client seam. Default to the
# in-memory GitHub.Fake — no network, no App key — so the connect/disconnect/
# state path is buildable and testable without any GitHub credential. The App id
# + RSA private key + webhook secret + app slug are HUMAN-LAST (no real
# credential exists): runtime.exs swaps in GitHub.Real ONLY when GITHUB_APP_ID +
# GITHUB_APP_PRIVATE_KEY are set in prod, and `GitHub.configured?/0` gates the
# endpoints (503 feature_not_configured) until then. The app BOOTS with GitHub
# off (plugins-off philosophy). See BarkparkCloud.GitHub.
config :barkpark_cloud, BarkparkCloud.GitHub,
  client: BarkparkCloud.GitHub.Fake,
  app_id: nil,
  private_key: nil,
  webhook_secret: nil,
  app_slug: nil

# Zero-paste Vercel handoff: the in-memory Fake by default (dev/test — no
# network, no token); runtime.exs selects Real in prod once the platform token
# is wired. Off (feature_not_configured) is a valid state.
config :barkpark_cloud, BarkparkCloud.Vercel,
  client: BarkparkCloud.Vercel.Fake,
  token: nil

# dwb-17: the provision stale-claim threshold. A `claimed` provision job whose
# `claimed_at` is older than this is treated as abandoned and re-claimable by the
# StaleProvisionJobReaper. Raised 12 → 25 min to stay ABOVE the Go worker's
# DefaultProvisionTimeout (now 20 min, which includes the freshen deploy-rebuild
# sub-budget) plus margin for teardown + the report round-trip — otherwise the
# reaper double-claims a provision that legitimately outlives the old threshold.
# Read via `BarkparkCloud.Registry.stale_after_seconds/0` (registry.ex keeps its
# own 12-min DEFAULT; this config value overrides it without editing that module).
config :barkpark_cloud, :provision_stale_after_seconds, 25 * 60

# Audit trail (activity-audit-log): how many days a team's audit events are
# retained before a future retention sweeper may prune them (keeping a floor of
# the most-recent rows per team so a quiet team never loses its whole trail to
# age alone). Default 90 days; runtime.exs overrides from AUDIT_RETENTION_DAYS in
# prod. Read via `BarkparkCloud.Accounts.audit_retention_days/0` — never a magic
# literal. The sweeper itself is a follow-up; this knob documents the contract.
config :barkpark_cloud, :audit_retention_days, 90

# OAuth/SSO (oauth-sso): "Continue with GitHub / Google". Dev/test DEFAULT —
# empty client creds ⇒ both providers DISABLED (no buttons, the routes 404), so
# the app boots with social login simply off until creds are supplied. prod
# wires real creds + the verified-TLS http_client from env in runtime.exs;
# test.exs sets a fixed state_secret + a stub http_client (hermetic, €0). The
# state_secret here is a DEV-ONLY placeholder (same discipline as the
# Registry.Vault dev key above) — it is the HMAC key for the single-use CSRF
# state token, NOT a provider secret. See BarkparkCloud.OAuth.
config :barkpark_cloud, BarkparkCloud.OAuth,
  base_url: "http://localhost:4100",
  state_secret: "dev-only-oauth-state-secret-change-me",
  http_client: nil,
  providers: %{
    "github" => %{
      module: BarkparkCloud.OAuth.Github,
      client_id: nil,
      client_secret: nil
    },
    "google" => %{
      module: BarkparkCloud.OAuth.Google,
      client_id: nil,
      client_secret: nil
    }
  }

# Web (cloud-12a): the minimal JSON HTTP API (Plug.Router + Bandit) that exposes
# the Accounts/Registry/Billing contexts to the agent (cloud-10) and the Go CLI
# client (cloud-12b). `server` controls whether the Bandit listener joins the
# supervision tree; `port` is the listen port. Defaults here; test.exs sets
# `server: false` (the router is driven directly via Plug.Test), runtime.exs
# reads PORT in prod. NOT Phoenix — there is no dashboard yet (a later task).
config :barkpark_cloud, BarkparkCloud.Web.Endpoint, server: true, port: 4100

# azure-retail-pricing: the transport for the credential-free Azure Retail Prices
# client (BarkparkCloud.Azure.Pricing). Default nil in dev/test → the client
# fails CLOSED (:http_client_not_configured), so no byte reaches
# prices.azure.com and the azure catalog simply degrades to nil prices. prod
# (runtime.exs) wires the real verified-TLS :httpc transport; tests may program
# a per-process fake.
config :barkpark_cloud, BarkparkCloud.Azure.Pricing, http_client: nil

# portable-archives (S14/D39): the read conduit into Hetzner Object Storage for
# archived-instance bundles. Default is UNCONFIGURED (blank creds) → the store
# fails closed with {:error, :not_configured} and GET /v1/archives degrades
# honestly, so dev/test boot with the archives panel showing an honest
# unconfigured state. prod (runtime.exs) wires HETZNER_S3_ACCESS_KEY /
# HETZNER_S3_SECRET_KEY / BARKPARK_BUNDLE_BUCKET; tests inject a fake transport
# via :archive_store_http_client. See BarkparkCloud.ArchiveStore.
config :barkpark_cloud, BarkparkCloud.ArchiveStore,
  access_key: nil,
  secret_key: nil,
  bucket: nil,
  location: "fsn1"

# push relay (mobile charter D15): how one notification's adapter is chosen.
#
# `:auto` = resolve PER PLATFORM at send time (BarkparkCloud.Push.adapter_for/1):
# apns → Adapters.APNS iff its credentials are configured, fcm → Adapters.FCM
# iff its service-account key is, otherwise Adapters.NotConfigured (honest
# terminal cancel — never retried, never faked). No APNs/FCM credentials exist
# in any environment yet, so today every send still cancels; the relay turns
# itself on when a credential appears, with no flag to flip. The exact
# credentials a human must supply are in the Adapters.NotConfigured moduledoc.
#
# Setting a MODULE here instead overrides the resolution for every platform —
# that is how config/test.exs pins BarkparkCloud.PushFakeAdapter.
config :barkpark_cloud, :push_adapter, :auto

# The push relay's HTTP boundary (BarkparkCloud.Push.HTTP) — the one seam the
# real APNs/FCM adapters put bytes through, and the one the adapter tests fake.
# Mint, not :httpc, because the APNs provider API is HTTP/2-only.
config :barkpark_cloud, :push_http_client, BarkparkCloud.Push.HTTP.Mint

# oban-substrate: the cloud control plane's job + cron engine. Postgres-backed
# on BarkparkCloud.Repo (no Redis). A near-verbatim port of the proven api/ Oban
# setup (api/config/config.exs:81-118), trimmed to what the control plane needs
# today. Queues are sized small — the cloud plane is a low-volume control plane,
# not a content firehose:
#
#   * maintenance — recurring housekeeping (the stale-provision-job reaper today;
#     health-staleness sweeps, usage downgrade, billing reconcile later). Low
#     concurrency: these are cheap scans that must not stampede.
#   * default     — ad-hoc / fan-out work enqueued by request handlers
#     (notification dispatch, backup kickoff) once those slugs land.
#
# Adding a queue here is the ONLY place a new recurring subsystem needs to touch
# this file — workers name their queue via `use Oban.Worker, queue: :…`. Unlike
# api/, cloud/ has NO plugin system, so the crontab is fully static (no boot-time
# plugin-crontab merge seam — YAGNI until a plugin layer exists).
config :barkpark_cloud, Oban,
  repo: BarkparkCloud.Repo,
  queues: [
    default: 10,
    maintenance: 2,
    # site-spawner W5 (charter D44): the publish-to-live auto-rebuild queue.
    # Concurrency 1 so the debounced auto-deploy enqueue+start step is serial per
    # box — the trailing rebuild after an in-flight build never races it (the box
    # additionally flock-serializes the build itself). AutoDeployWorker names this
    # queue via `use Oban.Worker, queue: :site_deploy`.
    site_deploy: 1
  ],
  # dr-w8-s7: how long the BEAM waits for :executing jobs to finish before it
  # tears the queues down. Oban's UNSET default is 15_000ms — and the all-time
  # MAX completed AutoDeployWorker duration measured on prod (13,287 jobs) is
  # 15.017s, i.e. the observed distribution is CLIPPED exactly at that boundary:
  # the healthy tail beyond it is unobservable from completed rows alone, because
  # anything longer was killed, not completed. 60s gives the real tail room and
  # PREVENTS most orphans in the first place — a blue/green container replacement
  # that used to strand an :executing row now usually lets it finish.
  shutdown_grace_period: :timer.seconds(60),
  plugins: [
    # dr-w8-s7: rescue jobs orphaned by a dead node. Without this, an :executing
    # row whose BEAM died is stranded FOREVER — Pruner only reaps
    # completed/cancelled/discarded, so it never touches :executing — and the
    # ledger goes on claiming the job has been running for ten days. Eight rows
    # sat that way (five AutoDeployWorker, oldest 2026-07-28), each attempted_by
    # a different, now-dead node: blue/green container replacements.
    #
    # 5 minutes is deliberately FAR above the healthy runtime, not near it:
    # AutoDeployWorker.perform/1 only enqueues + SPAWNS the supervised driver and
    # returns (the 2-4 minute build runs outside the job), measured p50 0.329s /
    # p99 5.771s / max 15.017s over 13,287 completed jobs, ZERO over 30s. It is
    # also comfortably above the 60s AUTODEPLOY_DEBOUNCE_S window. Never set this
    # below 60s: see the clipping note on shutdown_grace_period above — the max
    # is an artifact of the old grace boundary, so the true tail is unknown.
    #
    # Rescue vs discard is Engine.rescue_jobs/3's split, pinned by a test in
    # test/barkpark_cloud/sites/auto_deploy_worker_test.exs: attempt <
    # max_attempts → back to "available" (re-runs), attempt >= max_attempts →
    # "discarded" (never re-runs). Leader-gated (Peer.leader?/1), so only one
    # node rescues during a blue/green overlap.
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(5)},
    # Reap finished/discarded job rows after 7 days so oban_jobs never grows
    # unbounded (same retention api/ uses — control-plane volume is far lower, so
    # 7 days is harmless and keeps a useful audit window).
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # Recurring schedule. One entry today: the stale-provision-job reaper every
    # minute, mirroring api/'s per-minute TtlSweeper cadence. Sibling slugs add
    # their own entries here (e.g. {"0 4 * * *", BackupWorker}).
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", BarkparkCloud.Workers.StaleProvisionJobReaper},
       # bp-login-ux: sweep expired device-authorization requests (abandoned
       # `bp login` flows). Pure hygiene — expiry is enforced in-band by every
       # DeviceAuth query — so it rides the cheap :maintenance queue.
       {"* * * * *", BarkparkCloud.Workers.DeviceAuthReaper},
       # cch-w2: the same sweep for abandoned OAuth `state` nonces. Both oauth
       # GET legs insert a row per hit on an UNAUTHENTICATED route and only the
       # REDEEMED row was ever deleted, so every bounced consent screen leaked a
       # tombstone. Expiry is enforced in-band by verify_state/consume_state —
       # pure hygiene, so it rides :maintenance beside its twin above.
       {"* * * * *", BarkparkCloud.Workers.OAuthStateReaper},
       # cch-w3: the third of the same sweep, for burned/expired `"sse"` stream
       # tickets. The mint inserts one user_tokens row per call and the burn is a
       # soft `revoked_at` stamp, never a DELETE, so a console tab's reconnect
       # loop accreted a row per connect forever. A mint THROTTLE was rejected —
       # the mint is non-superseding on purpose (two-tab eviction storm), so a
       # per-user limit would 429 a legitimate second tab. Pure hygiene, so it
       # rides :maintenance beside its twins above.
       {"* * * * *", BarkparkCloud.Workers.SseTicketReaper},
       # cch-w10: the fourth of the same sweep, for burned/expired
       # `"oauth_exchange"` codes — the one-time code the OAuth callback now puts
       # on the `location` header in place of a live 30-day session token. Filed
       # WITH the mint rather than after it: `oauth_states` and `"sse"` above were
       # both discovered as accretion later, and this mint has the identical shape
       # (bare Repo.insert, soft `revoked_at` burn, never a DELETE). Expiry is
       # enforced in-band by consume_oauth_exchange_code/1 — pure hygiene, so it
       # rides :maintenance beside its three twins.
       {"* * * * *", BarkparkCloud.Workers.OAuthExchangeReaper},
       # deploy-queue twin of the reaper above: recover deployments wedged in
       # "building" (crashed builder) or "pushing" (crashed on-box agent) so one
       # crashed worker never strands a site's deploys behind an eternal spinner.
       {"* * * * *", BarkparkCloud.Workers.StaleDeploymentReaper},
       # warm-pool twin of the two reapers above — the third claim table, and the
       # one that never got a scheduled sweep. Registry.reap_stale_warm_claims/0
       # was only ever called INSIDE a claim transaction, so recovery was LAZY:
       # it ran only when a NEW warm claim arrived. And the trigger is OFF BY
       # DEFAULT (WARM_POOL_SIZE=0 disables the pool in the Go provisioner), so
       # whenever the pool is off or the provisioner is down, nothing claimed and
       # therefore nothing reaped — while each leaked row is a real, billed
       # Hetzner box the control plane no longer tracks. Unconditional on
       # purpose: with the pool disabled the sweep just matches zero rows.
       {"* * * * *", BarkparkCloud.Workers.StaleWarmClaimReaper},
       # health-status: the per-minute silent-agent staleness sweep (the
       # ServerManagerJob analog). Rides the same :maintenance queue as the
       # reaper above — cheap index range-scans that must not stampede.
       {"* * * * *", BarkparkCloud.Health.StalenessWorker},
       # dwb-13: the free-trial lifecycle worker — hourly advance notices (T-3 /
       # T-1) + expiry teardown of unconverted trials via the deprovision path.
       # Hourly (not per-minute): the notices are day-grained and each is claimed
       # once on the team ledger, so precision to the hour is ample.
       {"0 * * * *", BarkparkCloud.Workers.TrialExpiryWorker},
       # isu-6: the hourly self-update status sweep — mirrors each live
       # instance's OWN update verdict (GET /v1/admin/self-update) onto its
       # row. Offset to :17 so it never stampedes with the on-the-hour jobs.
       {"17 * * * *", BarkparkCloud.Workers.UpdateStatusWorker},
       # isu-w4: the fleet autoupdate rollout — every 5 min, advance the
       # opt-out auto-rollout by ONE health-gated instance (trigger a `behind`
       # box, wait for it to settle `current`, then advance). Cheap per tick (≤1
       # refresh or ≤1 trigger); rides the hourly :17 sweep's `behind` verdicts.
       {"*/5 * * * *", BarkparkCloud.Workers.AutoupdateRolloutWorker},
       # cloud-console-w3: the fleet usage sampler — every 15 min (offset off the
       # quarter-hours so it never stampedes the :00/:05 sweeps) cache one usage
       # envelope per checkable instance so GET /v1/usage/summary answers the
       # Overview fleet strip with ZERO live instance HTTP. max_attempts: 1 — a
       # missed tick just re-samples next quarter-hour.
       {"7,22,37,52 * * * *", BarkparkCloud.Workers.UsageSamplerWorker},
       # azh-w6: daily retention prune of the unbounded agent tables (agent_events
       # >14d, dead agent_tokens >30d past revoked/expired, usage_samples >14d).
       # Runs off-peak at 03:30 so it never stampedes the on-the-hour sweeps; a
       # missed tick is harmless (max_attempts: 1 — the next day catches up).
       {"30 3 * * *", BarkparkCloud.Workers.AgentRetentionWorker},
       # cch-w54-bl: the daily archive-bundle purge — the erasure path a
       # decommission did not have. A bundle is kept 30 days past the teardown
       # that made it, then deleted from object storage; a still-live team
       # NEVER loses its most recent bundle. Runs at 03:45, after the agent
       # prune and before the 06:00 digest, so the two off-peak sweeps do not
       # overlap. max_attempts: 1 — the window is 30 days wide, so a missed
       # tick costs nothing.
       {"45 3 * * *", BarkparkCloud.Workers.ArchiveRetentionWorker},
       # isu-w5: the daily fleet-update digest — one plain-text operator email
       # summarizing where every instance stands against the newest release the
       # fleet has seen (curator judgment → a human inbox). Runs at 06:00 (quiet,
       # off every on-the-hour + off-peak sweep). max_attempts: 1 + unique daily —
       # a missed tick is harmless and a double-enqueue must not double-send.
       {"0 6 * * *", BarkparkCloud.Workers.DailyDigestWorker},
       # stw9 (charter D57b): the hourly TEMPLATE-freshness sweep — re-enqueue an
       # UNFORCED "template-auto" build for every deployed content-bound site, so
       # a merged template change reaches live sites with no human in the loop.
       # Unforced means an unchanged site collapses to the (site_id, build_id)
       # no-op, so a quiet fleet costs one analytics read per site per hour; the
       # worker additionally SKIPS any site whose content_rev it cannot read (the
       # fail-open would otherwise mint a fresh build every tick — a build storm
       # on a 2-core box). Offset to :41 so it never stampedes the :00 / :17 / :07
       # sweeps, and it rides :site_deploy (concurrency 1) rather than
       # :maintenance — a sweep that starts builds belongs behind the same serial
       # gate the debounced auto-deploy uses.
       {"41 * * * *", BarkparkCloud.Sites.TemplateFreshnessWorker}
     ]}
  ]

# notifications-email: the PLATFORM mailer transport. Dev = in-memory Local
# mailbox (no network). test.exs swaps in Swoosh.Adapters.Test; runtime.exs swaps
# in Swoosh.Adapters.SMTP (gen_smtp) from env in prod. Per-team SMTP rides a
# per-call config override carried in the Notifications context — one mailer
# module serves both. Same config-selected-adapter seam as Billing.Gateway.
config :barkpark_cloud, BarkparkCloud.Mailer, adapter: Swoosh.Adapters.Local

# Platform From + identity. from_address / from_name are read by Mailer.from/0;
# runtime.exs overrides each from MAIL_FROM_* in prod. No secret here.
config :barkpark_cloud, BarkparkCloud.Notifications,
  from_address: "noreply@barkpark.cloud",
  from_name: "Barkpark Cloud"

# isu-w5: the platform-operator recipient allowlist for the daily fleet digest.
# There is NO platform-admin flag on a User (roles are strictly per-team), so the
# operator names the admin account(s) `mix barkpark_cloud.create_admin` minted
# here; each entry is resolved to a REGISTERED user before it is ever mailed. Empty
# by default → the digest worker is a logged no-op until an operator opts in.
# runtime.exs overrides from PLATFORM_ADMIN_EMAILS (comma-separated) in prod;
# unset/blank there keeps this honest [] no-op.
config :barkpark_cloud, :platform_admin_emails, []

# No HTTP-client dep for the SMTP/Local/Test adapters — only a hosted-API adapter
# (Resend/SendGrid, deferred) would need one. Keeps the "no new HTTP dep" posture
# the Billing layer already took (:httpc via Billing.HttpClient).
config :swoosh, :api_client, false

# email-verification-recovery: base URL of the hash-routed dashboard SPA the
# emailed `?confirm=` link points at. runtime.exs overrides from DASHBOARD_URL in
# prod. No secret here.
config :barkpark_cloud, dashboard_url: "https://barkpark.cloud"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
