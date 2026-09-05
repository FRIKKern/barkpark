import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
# CI keeps the stock postgres/postgres service creds (the defaults). The env
# overrides exist for boxes whose Postgres has real auth (e.g. the prod host),
# where tests run as a dedicated random-password role instead of downgrading
# the superuser password to a known constant.
config :barkpark, Barkpark.Repo,
  username: System.get_env("BARKPARK_TEST_DB_USER", "postgres"),
  password: System.get_env("BARKPARK_TEST_DB_PASS", "postgres"),
  hostname: System.get_env("BARKPARK_TEST_DB_HOST", "localhost"),
  database: "barkpark_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  # Flat, generous, env-overridable pool — was `System.schedulers_online() * 2`.
  # On a cgroup-throttled CI runner schedulers_online() can report 1–2, giving a
  # pool of only 2–4; a handful of legitimate boot-time holds (Indx monitor/
  # recovery, the post-boot Sharing.refresh/check_pg_trgm probes, Postgrex
  # reconnect churn) then starve it, and test_helper.exs's very first CREATE
  # SCHEMA sits in the checkout queue until it is DROPPED — reddening the whole
  # gate before a single test runs (run 29665467133: 89.7s in-queue, 0 tests).
  # postgres:15's default max_connections is 100, so 20 is comfortably safe.
  # DIAGNOSTIC VALUE: if the boot checkout STILL starves for ~90s at pool 20,
  # the cause is a lock/held-connection or a wedged CI Postgres service — NOT
  # pool math — and the fix belongs at the workflow/infra layer.
  pool_size: String.to_integer(System.get_env("BARKPARK_TEST_POOL_SIZE", "20")),
  # Per-hold watchdog. At the 15s default, a legitimately long single hold
  # under saturated-suite CPU (the EDItEUR/Thema codelist seed's big JSONB
  # register) gets force-disconnected mid-query — killing a pool connection
  # and starving concurrent tests' setups (same poisoning as the orphan-task
  # leak drained by DataCase.setup_sandbox). 45s stays under ExUnit's 60s
  # test timeout so a truly hung test still fails as a test, not a disconnect.
  timeout: 45_000,
  # Checkout-queue tolerance. The pool is only schedulers_online()*2 (≈8 on the
  # 4-core CI runner) yet the async suite fans out schedulers_online() concurrent
  # tests, each spawning $callers-scoped Tasks that also check out. Under that
  # contention — plus a service-container Postgres still warming at job start —
  # a checkout can miss the default 50ms target / 1000ms interval and get DROPPED
  # after ~5s ("connection not available and request was dropped from queue"),
  # reddening the WHOLE gate: at boot it kills test_helper's first CREATE SCHEMA
  # before a single test runs; mid-suite it fails a random test. Widen the wait
  # so a transient spike QUEUES instead of dropping. This never masks a real hang
  # (that still hits :timeout above / ExUnit's 60s) — it only stops declaring a
  # busy-but-healthy pool dead. Ecto's own remedy #4 for this exact error.
  #
  # DOES NOT TRANSFER TO PROD: api/config/runtime.exs deliberately does NOT carry
  # these two keys (Ecto defaults 50ms/1000ms apply there), and that is a decision,
  # not an oversight — see the note above `repo_opts` in runtime.exs for the full
  # reasoning and the open tasks (`jpf-bl-guerrilla-db-probe-arm`,
  # `jpf-bl-oban-pool-partition`) that own the production pool fix. Short version:
  # this remedy suits a healthy-but-transiently-busy CI pool where nothing is
  # actually starved for long; guerrilla prod's failures come from a structurally
  # oversubscribed pool (Oban + HTTP sharing POOL_SIZE=10) with jobs holding
  # connections 12-38s, well past even this widened target — widening the queue
  # window there would make overloaded requests wait longer before failing instead
  # of fixing the oversubscription.
  queue_target: 5_000,
  queue_interval: 30_000

# Mount the test-only /__error_test__/boom route (router.ex) so the RenderErrors
# integration tests can exercise ErrorJSON/ErrorHTML through the real endpoint.
config :barkpark, error_test_routes: true

# Search-intel record writes are async in prod (a keystroke must never stall on
# the event INSERT); tests run them sync so every existing "row exists after
# record" assertion stays deterministic. The async path has its own test.
config :barkpark, search_intel_record_async: false

# Preview-JWT test signing secret (throwaway). Kept OUT of config.exs so Sobelow
# Config.Secrets stays clean (test.exs is in Sobelow's config skip-list). Merges
# with the ttl_seconds/issuer base set in config.exs.
config :barkpark, :preview, secret: "test-preview-secret-change-in-prod-please-32"
config :barkpark, :cycle_release_capture_hmac_secret, String.duplicate("capture-test-secret-", 2)

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :barkpark, BarkparkWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "/WlOyDI2/9z2XIW0syrE1JBZpUAiuyRHm9KLShzBXqB35t3S1Y0gP1WIrI2azToL",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Drive Oban manually in tests so we can drain queues from assertions.
#
# This block sets ONLY `testing: :manual` — it does NOT override `:queues`, so
# the queue list from `config/config.exs` (which now includes `edge_projector: 2`
# alongside `indx: 2`) is INHERITED here verbatim. Config import order is
# config.exs then test.exs, and Oban merges on the keys each file sets, so the
# `:edge_projector` queue flows into the test env. The EdgeProjector tests still
# drive the worker via `Oban.Testing.with_testing_mode(:inline, fn -> ... end)`
# or `perform_job/2` — `testing: :manual` means enqueued jobs do NOT auto-run.
# If a future edit adds a `:queues` key here, `edge_projector` MUST be added too.
config :barkpark, Oban, testing: :manual

# Search analytics inserts run synchronously in tests (no Task race).
config :barkpark, :search_analytics_async, false

# The post-commit audit-webhook fan-out runs SYNCHRONOUSLY in the test's process
# (no unawaited `Task.Supervisor.start_child` spawn on the shared
# `Barkpark.TaskSupervisor`). The async spawn's DataCase drain is scoped to its
# ORIGINATING test, and ExUnit gives no ordering guarantee it finishes before a
# concurrent raw-DDL test opens its window — so the leaked audit SELECT
# (AccessShareLock on webhooks/search_synonyms) deadlocks the `ALTER TABLE`
# (AccessExclusiveLock) with a Postgrex 40P01. Inline delivery joins the caller's
# sandbox connection and dies with the test. Read by
# `Barkpark.Webhooks.Dispatcher.dispatch_audit_async/1`.
config :barkpark, :audit_dispatch_async, false

# Self-update stays OFF (no Checker in the tree) and the upstream client is
# the scripted Fake — tests prime it per-call via Application env.
config :barkpark, Barkpark.SelfUpdate,
  enabled: false,
  client: Barkpark.SelfUpdate.Client.Fake

# Core-auth mailer captured in-process during tests (assert_email).
config :barkpark, Barkpark.Mailer, adapter: Swoosh.Adapters.Test

# The prod register ceiling is 5/HOUR/IP (BarkparkWeb.Plugs.AuthWriteRateLimit),
# and the limiter's ETS bucket is process-global with an hourly refill — so the
# suite's own anonymous registers (auth_controller_test, org_require_mfa_test,
# webauthn_controller_test, …) all bill the SAME 127.0.0.1 bucket and would trip
# it within seconds of the run starting. Effectively-off here; the real ceiling
# is pinned by test/barkpark_web/plugs/auth_write_rate_limit_test.exs, which sets
# a small budget explicitly and drives the live route until it 429s.
config :barkpark, :auth_write_rate_limits, register: 1_000_000

# Fixed paper-ingest secret for tests.
config :barkpark, :ingest_token, "barkpark-test-ingest-token"
config :barkpark, :media_signing_secret, "test-media-signing-secret"
config :barkpark, :media_processing_callback_token, "test-media-processing-callback-token"

# SSRF guard escape hatch (Barkpark.Net.SafeOutbound). Tests dispatch webhooks
# at Bypass on 127.0.0.1, which the guard would otherwise refuse. Prod/runtime
# leaves this false so tenant webhook URLs cannot reach internal hosts.
config :barkpark, :allow_private_outbound, true

# The boot-time codelist seeders do DB writes from the SchemaBootstrap process
# before any test owns an Ecto sandbox connection ("cannot find ownership
# process"), which intermittently cascades into unrelated test setups. Tests that
# need codelist data seed it explicitly, so skip the boot pass here.
config :barkpark, run_boot_codelist_seeders: false

# Same sandbox constraint for the core tag-schema registration (charter D12):
# SchemaBootstrap would upsert the `tag` schema before any test owns a
# connection. Tests prove the registration path by calling
# `Content.TagRegistry.register!/1` directly (tag_registry_test.exs).
config :barkpark, run_boot_core_schema_registration: false

# Pulse (Shared Storm): one channel fixture so the public-surface tests can
# exercise ingest/feed/caps end-to-end. Prod channels come from
# BARKPARK_PULSE_CHANNELS (runtime.exs); default everywhere is %{} = closed.
config :barkpark, :pulse_channels, %{
  "test-storm" => %{
    "fields" => %{
      "hue" => ["int", 0, 359],
      "x" => ["float", 0, 1],
      "y" => ["float", 0, 1],
      "mega" => ["bool"],
      "chg" => ["float", 0, 1, 0]
    },
    "rate_per_min" => 600,
    "daily_cap" => 100_000
  },
  # Tight-cap fixtures for the abuse drill (pulse_abuse_drill_test.exs). Each
  # isolates ONE cap so the drill can prove it holds — and go RED if neutered.
  "abuse-rate" => %{
    # slow refill (0.1/sec) so a rapid volley from one IP is bounded to the
    # burst (3) with no in-loop refill slop — the 429 boundary stays crisp.
    "fields" => %{"hue" => ["int", 0, 359]},
    "rate_per_min" => 6,
    "daily_cap" => 1_000_000
  },
  "abuse-daily" => %{
    # daily ceiling of 3, rate wide open so distinct IPs never trip the bucket.
    "fields" => %{"hue" => ["int", 0, 359]},
    "rate_per_min" => 6000,
    "daily_cap" => 3
  },
  "abuse-bytes" => %{
    # three required fields whose coerced payload (~28 B) blows a 20 B ceiling.
    "fields" => %{"hue" => ["int", 0, 359], "x" => ["float", 0, 1], "y" => ["float", 0, 1]},
    "max_bytes" => 20,
    "rate_per_min" => 6000,
    "daily_cap" => 1_000_000
  }
}

# The anonymous-Default Studio allowance stays ON in test — the P3/P4
# contract tests pin the demo posture; the lockdown tests flip it off
# per-test (async: false) to pin the prod fail-closed behavior.
config :barkpark, :public_demo_studio, true

# Claude chat stays off in tests unless a test enables it with an explicit
# fake command (no real `claude` on CI).
config :barkpark, :claude_chat, enabled: false

# The chat's mount-time readiness probe (chat-task-hands, decision 4) resolves
# to :ready by default in test — the REAL probe shells out to whatever `claude`
# the host has (present+authed on a dev Mac, absent on CI), which would make
# every chat-mounting test host-dependent and 1–2s slower. The onboarding-card
# tests override this per-test ({:static, state} or a 0-arity fun) to drive
# every named state deterministically through the same async machinery.
config :barkpark, :studio_chat_readiness_probe, {:static, :ready}

# Studio chat image attachments (charter D25) — write bytes under a temp dir in
# test so they never touch a real store. Tests that assert file lifecycle point
# it at a per-test unique dir via Application.put_env.
config :barkpark, Barkpark.StudioChat,
  attachments_dir: Path.join(System.tmp_dir!(), "bp_studio_chat_test_attachments")

# The github-bridge DrainWorker runs a periodic DB-touching drain tick. Keep the
# boot-started singleton dormant in test so it never fires against a process that
# owns no ExUnit sandbox connection (DBConnection.OwnershipError cascade). Drain
# tests start their own anonymous instance with injected seams. Mirrors the
# Sync.PushWorker `enabled?` gate. (Auth is lazy and stays boot-started.)
config :barkpark, Barkpark.Plugins.Github.DrainWorker, enabled: false

# Site-deploy EXECUTOR (Barkpark.Sites.DeployRunner). Pin the classic in-process
# Port lifecycle in test: `:auto` would flip to the systemd transient-unit path
# on any host where `systemd-run` happens to resolve (some Linux CI images),
# making the stub-command tests host-dependent. The unit-path tests opt into
# `:systemd` explicitly with a stubbed launcher + is-active probe.
config :barkpark, Barkpark.Sites.DeployRunner, runner_mode: :port

# Content.DedupWall candidate-fetch TRIPWIRE. The wall's rescue answers a
# database outage and a bug in the wall itself with the same `{:degraded, …}`;
# that laundered a live FunctionClauseError in `maybe_filter_dataset/2` into a
# green 25-test suite. In test, a CODE-class error (FunctionClauseError,
# ArgumentError, MatchError …) re-raises instead; infra errors still degrade.
# Off everywhere else — prod keeps its fail-closed refusal rather than a 500.
config :barkpark, dedup_raise_on_code_errors: true

# Default Workspace / Default Project cache (Barkpark.Tenancy.DefaultScopeCache).
# OFF in test: the Ecto sandbox rolls every test back, so an entry that survived
# one test would hand the next a `%Workspace{}` whose row no longer exists — an
# order-dependent suite that fails somewhere far from the cause. Tests that
# exercise the cache turn it on for their own duration
# (test/barkpark_web/capabilities_no_db_test.exs).
config :barkpark, tenancy_default_scope_cache_ttl_ms: 0
