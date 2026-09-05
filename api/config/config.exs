# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :barkpark,
  ecto_repos: [Barkpark.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  media_upload_dir: Path.expand("../uploads", __DIR__),
  # Where the workspace-bundle export streams its per-table spills and
  # assembles the tar. Anchored under the app's own data dir, NEVER a bare
  # System.tmp_dir!/0 — `Archive.spill_dir/0` asserts at runtime that the
  # chosen path is not memory-backed, because a tmpfs spill would reinstate
  # the full-bundle RSS peak the streamed export exists to remove.
  bundle_spill_dir: Path.expand("../tmp/bundle-spill", __DIR__)

# Media blob byte storage. :local (the default) keeps today's on-disk layout
# under :media_upload_dir, byte-identical to the pre-blobstore behaviour.
# :s3 moves ORIGINALS to any S3-compatible bucket (Cloudflare R2, AWS S3,
# MinIO, …) with local disk demoted to a regenerable write-through cache —
# see `Barkpark.Media.Blobstore` and the BARKPARK_MEDIA_STORAGE / BARKPARK_S3_*
# wiring in runtime.exs.
config :barkpark, :media_storage, backend: :local

# Configure the endpoint
config :barkpark, BarkparkWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    # JSON-first: Phoenix renders the FIRST format when Accept can't be
    # resolved, and NoRouteError fires before the :accepts plug runs — so the
    # Go apiclient (no Accept header on ordinary calls) and the JS SDK (sends
    # the vendor Accept registered below, which is otherwise unmapped) both
    # need JSON to win by default. Browsers are unaffected: they always send
    # an explicit `Accept: text/html`.
    formats: [json: BarkparkWeb.ErrorJSON, html: BarkparkWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: Barkpark.PubSub,
  live_view: [signing_salt: "MXGKAyTI"]

# Configure Elixir's Logger
# Tenant scope keys (workspace_id/workspace_slug/project_id/dataset) are stamped
# by BarkparkWeb.Plugs.TenantLogMetadata (API pipelines) + StudioLive (LiveView)
# so every log line is tenant-attributable — see that plug's @moduledoc. They
# MUST be listed here or they resolve but never render.
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :workspace_id, :workspace_slug, :project_id, :dataset]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Register the JS SDK's vendor Accept header so it resolves to the JSON error
# format above instead of falling through to ErrorHTML. Mapping it under the
# "json" extension also makes :mime's reverse extension->type lookup
# ambiguous ("extension .json currently maps to different mime-types") unless
# we pin the canonical reverse mapping back to application/json — the vendor
# type still resolves forward, it just isn't what .json reverse-resolves to.
config :mime, :types, %{"application/vnd.barkpark+json" => ["json"]}
config :mime, :extensions, %{"json" => "application/json"}

# Mailer (core auth email flows — verify-email / password reset). Swoosh's
# default API client (hackney) is unused: dev renders to the local mailbox,
# test captures in-process, prod sends via SMTP (gen_smtp) — wired in
# dev/test.exs + runtime.exs. Disabling the API client avoids the hackney dep.
config :swoosh, :api_client, false
config :barkpark, Barkpark.Mailer, adapter: Swoosh.Adapters.Local

# The transactional From identity, read by `Barkpark.Mailer.from/0` at CALL time
# (NOT a module attribute — gh-9531: an attribute is frozen at release BUILD, so
# runtime.exs could never move it and a self-hoster on their own relay was stuck
# sending as no-reply@barkpark.cloud, which most relays reject). runtime.exs
# overrides each from MAIL_FROM_ADDRESS / MAIL_FROM_NAME. No secret here.
config :barkpark, :mail,
  from_address: "no-reply@barkpark.cloud",
  from_name: "Barkpark"

config :barkpark, :idempotency, ttl_seconds: 86_400

config :barkpark, :rate_limits,
  read_per_minute: 300,
  write_per_minute: 60,
  datasets: %{}

# Trust boundary for x-forwarded-for on every IP-keyed rate bucket
# (Barkpark.RateLimiter.client_ip/1). Loopback is trusted UNCONDITIONALLY and is
# not listed here — Caddy is co-located and dials localhost:4000, which is the
# whole self-host/instance topology. This list ADDS non-loopback fronts whose
# relayed chain may be believed: in practice the Barkpark Cloud control plane's
# egress address, which relays the caller's IP on the revoke DELETE. Empty by
# default: a self-hosted box has no second front, and an unlisted relay is
# disbelieved (its own address becomes the bucket key) rather than trusted.
#
# Entries are :inet address tuples, INDIVIDUAL ADDRESSES ONLY — never a CIDR
# range. A range re-opens the forgery hole this exists to close: an attacker
# whose real (appended) address falls inside it has that hop SKIPPED, and the
# forged hop to its left is believed instead. Overridden at runtime from
# BARKPARK_TRUSTED_PROXIES (runtime.exs), which raises on a malformed entry.
config :barkpark, :trusted_proxies, []

# Per-key abuse rails for the low-trust ticket-key WRITE surface (Barkpark
# Tickets, charter Decision 9). Per-HOUR budgets, billed per {key_id, class};
# reads (the poll-with-key loop) are exempt. See
# BarkparkWeb.Plugs.TicketRateLimit for the hourly→token-bucket mapping.
# Prod-tunable without a rebuild via BARKPARK_TICKET_RATE_CREATE /
# _MESSAGE / _ATTACHMENT (runtime.exs).
config :barkpark, :ticket_rate_limits,
  create: 10,
  message: 60,
  attachment: 30

# Per-IP abuse rails for UNAUTHENTICATED auth writes, per HOUR, billed in a
# bucket of their own ON TOP of the shared 60/min anon-write meter
# (BarkparkWeb.Plugs.AuthWriteRateLimit). `register` = POST /v1/auth/register,
# which mails a third party on every call (confirmation for a fresh address,
# re-notification for an existing account), so the meaningful ceiling is MAIL
# volume, not request volume: 5/hour/IP fits a human signing up with retries and
# bounds the mailbomb. Prod-tunable without a rebuild via
# BARKPARK_AUTH_RATE_REGISTER (runtime.exs). Throttle only — invite codes /
# allowlists / closing signup are the instance owner's policy call.
config :barkpark, :auth_write_rate_limits, register: 5

# The preview-JWT signing secret is env-specific and is NEVER a hardcoded
# default in this shared base (closes Sobelow Config.Secrets, config.exs:64
# at the source rather than the baseline):
#   * prod REQUIRES `PREVIEW_JWT_SECRET` — runtime.exs raises if it is unset;
#   * dev/test supply a throwaway literal in config/dev.exs + config/test.exs,
#     both in Sobelow's config skip-list, so no secret literal ever lands in a
#     scanned config file.
# `ttl_seconds`/`issuer` stay here and merge per-key with the env secret at boot.
config :barkpark, :preview,
  ttl_seconds: 600,
  issuer: "barkpark"

config :barkpark, :media_signing_secret, "dev-media-signing-secret-change-in-prod"

# Anonymous browsers entering the Default workspace's STUDIO (the public
# demo / no-login dev posture) — FAIL-CLOSED base. dev.exs/test.exs turn it
# on; prod opts in via BARKPARK_PUBLIC_DEMO_STUDIO=1 (runtime.exs). The
# public PAPER READER is unaffected (published papers stay world-readable).
config :barkpark, :public_demo_studio, false

# Instance identity tag (staging-barkpark). Names WHICH deployment this box is
# — "staging", "prod", … — so the Studio chrome can wear an unmissable banner
# (staging is the canary for Barkpark's own builds; its data is disposable).
# This is an IDENTITY label, NOT MIX_ENV: a prod-compiled release runs on the
# staging box. Default nil (dev/test show no banner); prod sets it from
# BARKPARK_ENV at runtime (runtime.exs), mirroring the public_demo_studio opt-in.
config :barkpark, :instance_env, nil

# Studio tmux console — ON by default on every Studio. It stays admin-gated
# (the /studio/tmux route's on_mount) and `enabled?/0` HARD-REFUSES any host
# where anonymous Studio is on (public_demo_studio) so a demo box never
# exposes a shell. Opt OUT per host with BARKPARK_TMUX_CONSOLE=0 (runtime.exs).
# See BarkparkWeb.Studio.TmuxConsole for the full contract.
config :barkpark, :tmux_console, enabled: true, backend: ExPTY

# Studio Claude chat — admin-gated agent chat backed by the host's Claude Code
# CLI (`claude`), OAuth inherited from the host's `claude auth login`; Barkpark
# never stores a token. Same trust model as the tmux console: ON by default,
# `enabled?/0` HARD-REFUSES public-demo hosts, per-host opt-out via
# BARKPARK_CLAUDE_CHAT=0 (runtime.exs). Hidden automatically where the
# `claude` binary is not installed.
config :barkpark, :claude_chat, enabled: true

# Connectors — the Elixir edge of the chat-bridge seam (connectors D50/D51).
#
# `connect_secret: nil` is the DEFAULT and a fully supported state: an instance
# with no CONNECTORS_CONNECT_SECRET simply has no connect seam (the bridge does
# not mount the connect routes; the Studio catalog renders read-only with a
# banner). It must never raise at boot and never leave an unauthenticated route
# — which is also what removes the merge-order hazard between the bridge slice
# and the deploy step that generates the secret.
#
# `bridge_url` is LOOPBACK by construction: the bridge binds 127.0.0.1:4020 on
# the same box as the BEAM (CONNECTORS_HTTP_ADDR), and the connect routes 404 on
# any request carrying `x-forwarded-*` — so the raw chat token never traverses
# anything but the loopback interface.
config :barkpark, Barkpark.Connectors,
  bridge_url: "http://127.0.0.1:4020/connectors",
  connect_secret: nil,
  # The connectors HTTP path prefix — the Caddy route + `webhook-server.ts`'s
  # `{prefix}/webhooks/:provider[/:installKey]` grammar both hang off it. Studio
  # mirrors it to DISPLAY the per-install webhook/interactions URL an operator
  # pastes into a vendor portal (connectors D260). Distinct from `bridge_url`
  # (loopback, for the connect wire) — this joins the PUBLIC base, never loopback.
  path_prefix: "/connectors",
  bridge: Barkpark.Connectors.BridgeClient

config :barkpark, :media_cdn,
  base_url: nil,
  invalidation: [adapter: :noop]

config :barkpark, :media_webhooks, endpoints: []

# Audit-webhook fan-out mode (era-w7 bridge). TRUE = the post-commit audit
# bridge dispatches on a supervised fire-and-forget task so a slow endpoint
# never blocks `Audit.emit`. config/test.exs flips it FALSE so the fan-out runs
# SYNCHRONOUSLY in the test's own process — an unawaited task on the shared
# `Barkpark.TaskSupervisor` outlives its DataCase sandbox drain and its leaked
# audit SELECT deadlocks a concurrent raw-DDL test (Postgrex 40P01). Read by
# `Barkpark.Webhooks.Dispatcher.dispatch_audit_async/1`.
config :barkpark, :audit_dispatch_async, true

# Auto-disable a webhook endpoint after this many CONSECUTIVE terminal delivery
# give-ups (permanent 4xx / SSRF block / retry exhaustion). The counter resets to
# 0 on any successful delivery, so only a persistently-dead endpoint trips it.
# `Barkpark.Webhooks.auto_disable_threshold/0` reads this (module default 20).
config :barkpark, :webhook_auto_disable_threshold, 20

# INBOUND GitHub webhook body cap (BYTES), read by `BarkparkWeb.Plugs.CacheBodyReader`.
# The endpoint parses up to `length: 100_000_000` (100 MB) BEFORE the HMAC gate
# runs, and CacheBodyReader tees the raw bytes on the webhook path — so an
# unauthenticated, bogus-signature sender can force pre-auth buffering up to that
# global bound. GitHub documents a hard 25 MB payload ceiling (larger events are
# never delivered), so a per-route cap at 26 MB rejects zero legitimate deliveries
# while bounding the pre-signature buffering. NOTE: this BOUNDS buffering (reads up
# to the cap before the {:more} → 413 short-circuits), it does not PREVENT it.
#
# DESCOPE (felix-w27): the original slice also proposed a per-probe RATE LIMIT on
# this route. That half is deliberately dropped — `Settings.webhook_secret_cached/0`
# already memoizes the secret (short-TTL `:persistent_term`), so a burst of bogus
# signatures no longer forces a DB read + audit row per request; the marginal cost
# of an unauthenticated probe is now near-zero. The body cap is the load-bearing
# resource bound; a rate limiter would add moving parts without a measured win.
config :barkpark, :github_webhook_body_cap, 26_000_000

# Config-gated media upload allowlist + per-upload size cap (SECURITY, PART 2).
# Ships OFF: empty lists + nil cap = allow-all, i.e. accept every server-derived
# MIME / extension and any size up to the endpoint's 100 MB body bound — today's
# behavior, zero rejections. An operator opts in by listing allowed types and/or
# a tighter cap; `Barkpark.Media.upload/3` then rejects disallowed uploads BEFORE
# the blob is persisted (unsupported_media_type → 422 / payload_too_large → 413).
config :barkpark, :media_uploads,
  allowed_mime_types: [],
  allowed_extensions: [],
  max_upload_bytes: nil

config :barkpark, :media_processing_callback_token, "dev-media-processing-callback-token"

# Workspace-bundle IMPORT switch (Personal-Development-Server W1, G3). FAIL-CLOSED
# by default: a bundle import writes another instance's workspace data into THIS
# one, so it stays OFF everywhere unless an operator opts in via
# BARKPARK_ALLOW_BUNDLE_IMPORT (runtime.exs). `bin/barkpark up` writes =1 into the
# personal-local scratch .env — the free local twin is the intended pull TARGET —
# while prod boxes (which never set the env) keep import denied. Enforcement of
# this key lives in the import path (pds-w1-merge-import); this is the default it
# reads.
config :barkpark, :allow_bundle_import, false

# INSTANCE-OPERATOR allowlist (task-c7e2b87f1bbca815). The default is EMPTY on
# purpose: empty means UNSET, and UNSET means LEGACY — the `admin` permission
# alone still opens the seven instance-global route groups
# (BarkparkWeb.Plugs.RequirePlatformOperator's moduledoc enumerates them), which
# is what every existing deployment already runs. runtime.exs overrides these
# from BARKPARK_OPERATOR_EMAILS / BARKPARK_OPERATOR_TOKEN_IDS (comma-separated);
# the moment EITHER list is non-empty the tier is ARMED and allowlist-only.
# Mirrors cloud's `:platform_admin_emails` shape (cloud/config/config.exs).
config :barkpark, :operator_emails, []
config :barkpark, :operator_token_ids, []

# Fallback CORS allowlist for API routes without a dataset path segment
# (e.g. /v1/meta, /media without ?dataset=, legacy /api/*).
config :barkpark, :default_cors_origins, []

# Shared secret for the paper-ingest endpoint. Overridden per-env: runtime.exs
# reads BARKPARK_INGEST_TOKEN in prod (PAPERFLOW_INGEST_TOKEN as legacy
# fallback); dev.exs/test.exs set a local default.
config :barkpark, :ingest_token, nil

# Plain STRING, not a ~r sigil: a compiled Regex in config cannot be
# serialized into sys.config by `mix release` on Elixir 1.19 (the Dockerfile's
# build stage), and 1.18 (CI) rejects invented workarounds. The consumer
# (Barkpark.Search.Sanitizer.compile_pattern/1) compiles binaries with "i" at
# runtime, so a string here is behavior-identical on both toolchains.
config :barkpark, :search_query_exclude_patterns, [
  "^(test|asdf|qwerty|foo|bar)$"
]

# Engine → retriever registry for the document search SEAM. The Indx plugin
# backs the "indx" engine; "postgres" (the default) stays the built-in
# DocumentsRetriever. Resolved by Barkpark.Search.Retrievers; an unknown
# engine falls back to Postgres so a misconfig never takes a surface dark.
config :barkpark, :search_retrievers, %{"indx" => Barkpark.Plugins.Indx.Retriever}

# W7-05: the `tasks_ttl` queue is concurrency=1 per node — only one TTL
# sweep runs at a time on a given node, defense in depth against double-
# sweeping the same expired claim (the per-task advisory lock inside the
# worker is the authoritative serializer; queue=1 keeps the noise floor
# low on small clusters and avoids ten redundant SELECT scans every
# `task_lease_sweep_interval_seconds`).

# The INVERTED after-write listener seam (boundary: content → workers).
# `Barkpark.Content.WriteScope.fire_after/3` calls every entry here, post-commit,
# with the same after-payload it hands `Plugins.Hooks.fire/2`. Config is the
# composition root, so naming a worker HERE creates no module edge from the
# kernel; naming it inside content did (tooling/concept-map/boundary.mjs,
# wrong-direction). Entries are `{module, function}` (arity 1) or a 1-arity
# fun; a raising listener is logged and dropped, never failing the write.
config :barkpark, :after_write_listeners, [
  # E5 findability self-test (authoring-excellence D9/D29): self-gated to
  # `:after_publish` on walled types (paper/task); a no-op for every other event.
  {Barkpark.Workers.FindabilityPosttest, :enqueue_after}
]

config :barkpark, Oban,
  repo: Barkpark.Repo,
  # `indx` drives Barkpark.Plugins.Indx.IndexerWorker (blue/green corpus
  # rebuild + per-doc upsert/delete). Indx is a retriever-SEAM, not a registered
  # plugin, so it contributes nothing via the plugin oban-merge — its queue MUST
  # be declared statically here. Without it, every reindex job sits `available`
  # forever and the Indx index silently goes stale (engine=indx → empty →
  # Postgres recovery). Low concurrency: rebuilds are debounced + scope-unique.
  # `edge_projector` drives Barkpark.EdgeProjector.ProjectorWorker (content-graph
  # edge projection into the durable `content_edges` table). Like `indx` it is a
  # core subsystem, not a registered plugin, so its queue MUST be declared
  # statically here — without it every projection job sits `available` forever
  # and the graph silently goes stale. Own named queue (concurrency 2) so it
  # never competes with `:indx`.
  # `github_mirror` drives Barkpark.Plugins.Github.MirrorJob (outbound task→Issue
  # mirror). A plugin's oban-merge can add CRONTAB but NOT queues (same reason
  # `indx`/`edge_projector` are static here), so the queue is declared statically
  # even though `github` is a registered plugin. Low concurrency (2) is a
  # deliberate secondary-rate-limit guard (epic D9): a snoozed job re-reads
  # current state when it runs, so throttling loses no intent.
  # `playground_ttl` drives Barkpark.Tenancy.Workers.PlaygroundReaper (two-stage
  # TTL reaper for ephemeral playground workspaces — suspend@expires_at,
  # swept-delete@+24h). Tenancy is core, NOT a plugin, so — like `indx` /
  # `edge_projector` — its queue MUST be declared statically here; a queue that
  # only a plugin's oban-merge added would sit `available` forever (plugins can
  # add CRONTAB but not queues). Concurrency 1: at most one reaper tick runs at a
  # time, defense-in-depth alongside the worker's `unique` window.
  queues: [
    default: 10,
    bokbasen: 4,
    plugins: 6,
    tasks_ttl: 1,
    tasks_compact: 1,
    indx: 2,
    edge_projector: 2,
    github_mirror: 2,
    playground_ttl: 1
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"30 3 * * *", Barkpark.Search.Workers.Crystallize},
       # authoring-excellence D45 — daily per-type tag-count distribution
       # heartbeat over the published corpus (paper/task). Pure/derivable read
       # (Barkpark.Content.TagDistribution) that only Logger.info's the top-N
       # tags per type — no table, no persisted artifact. Placed one minute
       # after Crystallize (both nightly, disjoint queries) so the two heavy
       # nightly reads never kick off in the same tick.
       {"31 3 * * *", Barkpark.Workers.TagDistribution},
       {"0 4 * * *", Barkpark.Search.Workers.Prune},
       # edit-on-the-link slice 4 — retention sweep for the paper view/edit
       # trail (`paper_access_log`). Daily, fifteen minutes after the search
       # prune so the two range deletes never open their scans in one tick.
       # Window: `:paper_access_log_ttl_days` below. Core (not a plugin), so it
       # lives in this static crontab and rides the `default` queue.
       {"15 4 * * *", Barkpark.Content.Workers.PaperAccessSweeper},
       # Recover webhook deliveries stranded in `pending` by a dispatcher
       # crash / BEAM restart mid-delivery — re-dispatches any row still
       # `pending` past `:webhook_stuck_delivery_after_seconds` (default 300s)
       # so a crash mid-delivery self-heals instead of becoming permanently
       # undeliverable. Core subsystem (webhooks are not a plugin), so it lives
       # in this static crontab alongside the search workers; its job runs on
       # the existing `default` queue.
       {"* * * * *", Barkpark.Webhooks.StuckDeliverySweeper},
       # era-w5 — stream the append-only audit log to configured SIEM sinks
       # (cursor-based tail-shipping; a no-op when no active sink exists).
       {"* * * * *", Barkpark.Audit.ExportWorker},
       # bl-api-task-create-idempotency C4 — GC for the `idempotency_keys`
       # dedup store. `Idempotency.sweep/1` has existed since the table was
       # created and, until this entry, was called by NOTHING outside its own
       # test: the store was append-only in production, each row carrying a
       # full cached response body. Hourly (not per-minute) because the TTL is
       # 24h — an hour of lateness on a 24h expiry costs nothing, and the sweep
       # is an index scan, not a recovery path. Runs on the static `default`
       # queue alongside the webhook/audit sweepers; the worker bounds one tick
       # by construction (`Idempotency.sweep_batch/1`), so a cold first pass
       # over a long-unswept table cannot become one giant transaction.
       {"17 * * * *", Barkpark.Idempotency.Sweeper},
       # perfect-plan-build W2c (D28) — two-stage TTL reaper for ephemeral
       # playground workspaces: Stage 1 suspends at `expires_at`, Stage 2
       # swept-deletes at `expires_at + 24h` grace. Tenancy is core (not a
       # plugin), so this cron entry lives in the static crontab alongside the
       # webhook/audit sweepers and runs on the static `playground_ttl` queue
       # declared above. A no-op tick when no playground has expired.
       {"* * * * *", Barkpark.Tenancy.Workers.PlaygroundReaper}
       # The W7-05 TTL sweep ({"* * * * *", Barkpark.Tasks.TtlSweeper}) and
       # W7-06 compaction ({"0 */6 * * *", Barkpark.Tasks.Compactor}) cron
       # entries now live in the Tasks plugin's `oban_crontab/0`
       # (`Barkpark.Plugins.Tasks`); the C4-1 boot merge folds them back into
       # this crontab via `Plugins.Registry.collect_oban_crontab/0`. The
       # `tasks_ttl` / `tasks_compact` queues above stay here — only the worker
       # scheduling moved to the plugin.
     ]}
  ]

# W7-05 — TTL sweep tuning. Tests override `:task_lease_ttl_seconds`
# (e.g. to 0 / 1) to make sweep-or-not deterministic. The default
# 45-minute lease is the contract: any worker that hasn't refreshed
# its claim.ts_iso in 2700 s is considered crashed. This is sized to
# REAL agent work, not process liveness: an honestly-claimed task
# routinely runs 10-30 min (worktree build + full mix suite + PR),
# and nothing auto-renews the lease yet (no CLI heartbeat; the cmux
# v2 heartbeat is filed-not-built). A 5-minute lease reaped every
# live worker mid-task — board flipped to open, the row became
# re-claimable (duplicate-work risk), and the honest close got
# `:fenced_off`. 2700 s leaves generous headroom above the longest
# real task while still bounding a genuine crash's recovery to well
# under an hour. Runtime override: BARKPARK_TASK_LEASE_TTL_SECONDS
# (see runtime.exs). Sweep cadence is fixed by the Oban.Cron entry
# above — once per minute. Sub-minute cadence is intentionally NOT
# supported: the task recovery SLO is "minutes, not seconds," and
# the per-minute cron + per-task advisory lock + fencing epoch
# already cover the crash path without driving Oban poll pressure
# higher than the rest of the fleet (Search.Crystallize / Prune are
# daily).
config :barkpark, :task_lease_ttl_seconds, 2700

# edit-on-the-link slice 4 — retention window for `paper_access_log`, the paper
# view/edit trail. 90 days is a quarter: long enough to answer "who has been on
# this link" for the period anybody actually asks about, short enough that an
# unbounded per-mount series stays bounded. Swept daily by
# Barkpark.Content.Workers.PaperAccessSweeper; tests pass an explicit `days` in
# the job args rather than overriding this. Runtime override:
# BARKPARK_PAPER_ACCESS_LOG_TTL_DAYS (see runtime.exs).
config :barkpark, :paper_access_log_ttl_days, 90

# tlv-s6 — engagement honesty lease (TLV charter D4). The THOUGHT states
# (considering/researching) carry a content.engagement companion whose `ts`
# the holder refreshes; the TtlSweeper's second sweep lapses rows whose ts
# went stale (researching → considering, engagement cleared; considering →
# engagement cleared, stays considering). 900 s / 15 min: thought idles much
# faster than the 45-min work lease above — an investigation that hasn't
# touched its engagement in 15 minutes belongs back in the considering pool,
# and lapsing is cheap (no epoch fence, no re-claim ceremony; the next cycle
# just re-engages). Tests override to 0/1 for determinism. Runtime override:
# BARKPARK_TASK_ENGAGEMENT_TTL_SECONDS (see runtime.exs). Cadence rides the
# same per-minute Oban.Cron job as the lease sweep.
config :barkpark, :task_engagement_ttl_seconds, 900

# One-way PULL sync (Barkpark.Sync) — DORMANT default so a fresh install boots
# with sync OFF. runtime.exs maps the BARKPARK_SYNC_* env vars and flips
# `enabled` on only when explicitly requested; without them this default keeps
# Barkpark.Sync.enabled?/0 false (Worker absent from the supervision tree).
config :barkpark, Barkpark.Sync, enabled: false, push_enabled: false

# Instance self-update checker (Barkpark.SelfUpdate) — DORMANT default so a
# fresh install boots with the checker OFF (dev/test never touch the network).
# runtime.exs flips `enabled` on in prod unless BARKPARK_SELF_UPDATE_CHECK=off
# and maps the BARKPARK_UPSTREAM_* env vars over these defaults. Read-only:
# the Checker only polls the upstream repo for newer `vA.B.C` release tags.
config :barkpark, Barkpark.SelfUpdate,
  enabled: false,
  repo: "FRIKKern/barkpark",
  # The open-source Barkpark repo. When `repo` differs (a FORK), the checker
  # also compares the fork's newest release against this one and surfaces
  # "your fork is behind upstream Barkpark" as advice (isu-7).
  canonical_repo: "FRIKKern/barkpark",
  branch: "main",
  channel: :tags,
  check_interval_ms: 3_600_000,
  initial_delay_ms: 10_000,
  client: Barkpark.SelfUpdate.Client.GitHub

# Instance self-update EXECUTOR (Barkpark.SelfUpdate.Runner) — the APPLY side
# of self-update, separate from the read-only Checker above. Fail-closed
# default: `enabled: false` means the admin trigger endpoint answers 503 and
# nothing can ever execute; only prod's runtime.exs flips it on, and only when
# BARKPARK_SELF_UPDATE_APPLY=1 is set explicitly. `cd: nil` resolves to the
# repo root at runtime (the BEAM's cwd is api/ under both `mix phx.server`
# and start.sh — see the Runner moduledoc).
config :barkpark, Barkpark.SelfUpdate.Runner,
  enabled: false,
  command: {"bash", ["scripts/self-update.sh"]},
  # Rollback shares the Runner single-flight with self-update. `--rollback`
  # is the mutating slot flip; `--rollback-preflight` is the synchronous,
  # read-only probe the controller runs first for the target sha + a typed
  # refusal (W6 charter D13/D15). Both default here so an operator can see
  # and override them exactly like `command`.
  rollback_command: {"bash", ["deploy/instance-deploy.sh", "--rollback"]},
  rollback_preflight_command: {"bash", ["deploy/instance-deploy.sh", "--rollback-preflight"]},
  cd: nil,
  max_log_lines: 500

# Site-deploy EXECUTOR (Barkpark.Sites.DeployRunner) — runs deploy/site-deploy.sh
# for a content-bound STATIC site (site-spawner charter D22/D23/D24). Same
# fail-closed default as the self-update Runner: `enabled: false` means
# POST /v1/admin/site-deploy answers 503 and nothing can ever execute; prod's
# runtime.exs flips it on ONLY when BARKPARK_SITE_DEPLOY_APPLY=1.
#
# Deliberately a SEPARATE runner from Barkpark.SelfUpdate.Runner: the slug and
# build_id come from each REQUEST (the self-update command is compile-time
# config), and the single-flight slot is per-slug (self-update's is global, and
# a box auto-deploys itself on every merge). `cd: nil` resolves to the repo root
# at runtime — the BEAM's cwd is api/, so the parent is /opt/barkpark, where
# `bash deploy/site-deploy.sh` resolves.
# `runner_mode: :auto` resolves to the systemd transient-unit path (an in-flight
# build survives a barkpark.service restart; the runner re-attaches on boot) when
# `systemd-run` is on the box, else the in-process Port fallback (dev/macOS/CI).
# `run_state_dir` (default `<repo>/.bp-site-deploy-runs`) MUST survive a BEAM
# restart — it is how init/1 finds units to re-attach.
config :barkpark, Barkpark.Sites.DeployRunner,
  enabled: false,
  runner_mode: :auto,
  command: {"bash", ["deploy/site-deploy.sh"]},
  rollback_command: {"bash", ["deploy/site-deploy.sh", "--rollback"]},
  cd: nil,
  run_state_dir: nil,
  memory_max: "1500M",
  cpu_quota: "150%",
  max_log_lines: 500,
  run_deadline_ms: 1_800_000,
  # Hard deadline for the synchronous control-plane System.cmd calls (systemd-run
  # launch, `systemctl is-active`, `systemctl stop`) that run inside the singleton
  # GenServer — a hung systemd/systemctl can't wedge {:trigger}/{:status} or the
  # {:unit_deadline} watchdog. Bounds the CTL call, not the build (run_deadline_ms).
  ctl_cmd_timeout_ms: 15_000

# Site SOURCE PROVISIONER (Barkpark.Sites.Provisioner) — materializes a shipped
# starter template into `<sites_dir>/<slug>/src` before BUILD (site-spawner
# D33/D34, search-template D7). The template is chosen by the request's
# `template` slug (falling back to the runtime_target default), and EACH shipped
# starter has its OWN overridable source-dir key so a test/box can point any one
# at a stand-in: `:template_dir` (astro-starter), `:node_template_dir`
# (next-starter), `:search_template_dir` (search-starter). All nil here ⇒ the
# module's cwd-relative `templates/<slug>` defaults; runtime.exs maps the
# BARKPARK_*_TEMPLATE_DIR env vars over them, and BARKPARK_SITES_DIR over
# `:sites_dir`.
config :barkpark, Barkpark.Sites.Provisioner,
  sites_dir: nil,
  template_dir: nil,
  node_template_dir: nil,
  search_template_dir: nil

# Master KEK for envelope encryption (core auth/secrets, Phase 0). This is the
# compile-time DEV/TEST default — a deterministic, non-secret 32-byte key.
# Production OVERRIDES it from BARKPARK_KEK in runtime.exs (which raises if the
# env var is unset in prod). Wraps the per-scope DEKs in `data_keys`
# (Barkpark.Crypto.LocalKek / DataKeys). MUST stay independent of
# BARKPARK_CLOAK_KEY and SECRET_KEY_BASE so the three rotate on their own.
config :barkpark, Barkpark.Crypto.LocalKek,
  key: Base.encode64(:crypto.hash(:sha256, "barkpark-dev-kek-not-for-prod")),
  version: 1

# MUTATE-PATH SCHEMA VALIDATION (Barkpark.Content.Validation,
# task-41a740fd6701ec28). Every create-family and update write runs the
# validator at the Writer chokepoint. The DEFAULT is ADVISE: findings ride the
# mutate success envelope as `warnings` (code `schema_validation`) and NEVER
# block — status and stored bytes are unchanged from before the mount.
#
# ENFORCE (422 `validation_failed`) is opt-in PER DATASET: list the dataset
# slugs here, or the atom `:all`. Empty list = nobody enforces. Flipping the
# default is the owner's call, announced, with its own row — not a config edit.
# runtime.exs maps BARKPARK_SCHEMA_ENFORCE_DATASETS (comma-separated slugs, or
# "all") over this, so an operator opts a dataset in without shipping code.
config :barkpark, Barkpark.Content.Validation, enforce_datasets: []

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
