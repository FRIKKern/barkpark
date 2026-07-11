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
  media_upload_dir: Path.expand("../uploads", __DIR__)

# Configure the endpoint
config :barkpark, BarkparkWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BarkparkWeb.ErrorHTML, json: BarkparkWeb.ErrorJSON],
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

# Mailer (core auth email flows — verify-email / password reset). Swoosh's
# default API client (hackney) is unused: dev renders to the local mailbox,
# test captures in-process, prod sends via SMTP (gen_smtp) — wired in
# dev/test.exs + runtime.exs. Disabling the API client avoids the hackney dep.
config :swoosh, :api_client, false
config :barkpark, Barkpark.Mailer, adapter: Swoosh.Adapters.Local

config :barkpark, :idempotency, ttl_seconds: 86_400

config :barkpark, :rate_limits,
  read_per_minute: 300,
  write_per_minute: 60,
  datasets: %{}

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

config :barkpark, :preview,
  secret: "dev-preview-secret-change-in-prod-please-32-chars",
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

config :barkpark, :media_cdn,
  base_url: nil,
  invalidation: [adapter: :noop]

config :barkpark, :media_webhooks, endpoints: []

# Auto-disable a webhook endpoint after this many CONSECUTIVE terminal delivery
# give-ups (permanent 4xx / SSRF block / retry exhaustion). The counter resets to
# 0 on any successful delivery, so only a persistently-dead endpoint trips it.
# `Barkpark.Webhooks.auto_disable_threshold/0` reads this (module default 20).
config :barkpark, :webhook_auto_disable_threshold, 20

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

# Fallback CORS allowlist for API routes without a dataset path segment
# (e.g. /v1/meta, /media without ?dataset=, legacy /api/*).
config :barkpark, :default_cors_origins, []

# Shared secret for the paper-ingest endpoint. Overridden per-env: runtime.exs
# reads BARKPARK_INGEST_TOKEN in prod (PAPERFLOW_INGEST_TOKEN as legacy
# fallback); dev.exs/test.exs set a local default.
config :barkpark, :ingest_token, nil

config :barkpark, :search_query_exclude_patterns, [
  ~r/^(test|asdf|qwerty|foo|bar)$/i
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
  queues: [
    default: 10,
    bokbasen: 4,
    plugins: 6,
    tasks_ttl: 1,
    tasks_compact: 1,
    indx: 2,
    edge_projector: 2,
    github_mirror: 2
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"30 3 * * *", Barkpark.Search.Workers.Crystallize},
       {"0 4 * * *", Barkpark.Search.Workers.Prune},
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
       {"* * * * *", Barkpark.Audit.ExportWorker}
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

# Master KEK for envelope encryption (core auth/secrets, Phase 0). This is the
# compile-time DEV/TEST default — a deterministic, non-secret 32-byte key.
# Production OVERRIDES it from BARKPARK_KEK in runtime.exs (which raises if the
# env var is unset in prod). Wraps the per-scope DEKs in `data_keys`
# (Barkpark.Crypto.LocalKek / DataKeys). MUST stay independent of
# BARKPARK_CLOAK_KEY and SECRET_KEY_BASE so the three rotate on their own.
config :barkpark, Barkpark.Crypto.LocalKek,
  key: Base.encode64(:crypto.hash(:sha256, "barkpark-dev-kek-not-for-prod")),
  version: 1

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
