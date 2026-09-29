import Config

# notifications-email: tests assert on sent mail via Swoosh.TestAssertions
# (`assert_email_sent` / `refute_email_sent`) — the Test adapter captures every
# email in the process mailbox instead of touching a network.
config :barkpark_cloud, BarkparkCloud.Mailer, adapter: Swoosh.Adapters.Test

# ── Which test database (task-b169445c9f0031b3) ────────────────────────────
#
# The SAME rule api/config/test.exs uses since #20107 (task-a0b11b3ae0cf45f0);
# read either file and you have read both. The database is
# `barkpark_cloud_test<suffix>`, and the suffix is chosen in this order:
#
#   1. MIX_TEST_PARTITION is SET (even to "") -> it wins, verbatim. Setting it to
#      the empty string is the explicit opt-in to the unpartitioned, shared
#      `barkpark_cloud_test`.
#   2. CI is set (GitHub Actions always sets CI=true) -> "" — CI keeps
#      `barkpark_cloud_test`, the POSTGRES_DB of its own ephemeral postgres
#      service (.github/workflows/cloud.yml, jobs `test` and `census`, whose
#      DATABASE_URL names the same database). CI's database is unchanged.
#   3. Otherwise -> a per-checkout default, `_wt_<dirname>_<hash>`, derived from
#      THIS checkout's absolute path. Two worktrees therefore never share a
#      database unless one opts in.
#
# Why 3 is the default: with the variable unset every worktree on a box shared
# ONE `barkpark_cloud_test`, and each inherited the others' migrations — a
# console builder read DeliveryRecipientIndexTest red because #20298's index was
# missing from the shared database another worktree had migrated to a different
# head. The `test` alias in mix.exs runs `ecto.create` + `ecto.migrate` before
# `test`, so a fresh per-checkout database is created and migrated on first use.
#
# The suffix is byte-identical to api's for the same checkout (same root, same
# slug, same hash), so `barkpark_test_wt_X_h` and `barkpark_cloud_test_wt_X_h`
# are visibly the same worktree's pair.
#
# The chosen suffix and its source are recorded under `:test_db_partition` so
# test/support/shared_test_db.ex can say which database a red ran in and why.
test_db_partition =
  case System.fetch_env("MIX_TEST_PARTITION") do
    {:ok, explicit} ->
      %{suffix: explicit, source: :explicit}

    :error ->
      if System.get_env("CI") in [nil, "", "false", "0"] do
        # config/ -> cloud/ -> the checkout root.
        root = Path.expand("../..", __DIR__)

        slug =
          root
          |> Path.basename()
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "_")
          |> String.slice(0, 24)
          |> String.trim("_")

        # phash2 is stable across machines and ERTS versions, so the same path
        # always names the same database. The slug is for humans; the hash is
        # what keeps two checkouts with the same dirname apart.
        hash = root |> :erlang.phash2() |> Integer.to_string(36) |> String.downcase()

        %{suffix: "_wt_#{slug}_#{hash}", source: :worktree_default, root: root}
      else
        %{suffix: "", source: :ci}
      end
  end

config :barkpark_cloud, :test_db_partition, test_db_partition

config :barkpark_cloud, BarkparkCloud.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "barkpark_cloud_test#{test_db_partition.suffix}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# notifications-chat: swap the chat egress transport for the in-process fake so
# the dispatch/retry/give-up paths run without the wire (€0, hermetic). The same
# config seam prod reads to reach the real verified-TLS Billing.HttpClient.
config :barkpark_cloud,
  notifications_http_client: BarkparkCloud.Notifications.FakeHttpClient

# dwb-7 studio-link: swap the instance-side login-ticket mint call for the
# in-process fake (same seam shape as notifications above).
config :barkpark_cloud,
  studio_link_http_client: BarkparkCloud.StudioLinkFakeHttpClient

# deploy-reliability W21 (S2): the commit-distance compare client is UNSET in
# test, so the whole suite fails CLOSED on the network. The module's default is
# the real verified-TLS Billing.HttpClient (deliberate — the hourly sweep must
# work in prod with no config change), which means any test that PERFORMS
# UpdateStatusWorker without programming its own responder would otherwise make
# a live, rate-limited call to api.github.com. With this seam nil, such a test
# gets `{:error, :http_client_not_configured}` -> the "unknown" rung, and
# commit_distance_test.exs's own cases keep injecting per-test as they already
# do. nil is the SAFE reading here: the module treats an unconfigured client as
# unmeasured, never as distance 0.
config :barkpark_cloud, BarkparkCloud.GitHub.CommitDistance, http_client: nil

# hetzner-proxy: swap the server-side Hetzner API fan-out for the in-process
# per-path fake (same seam shape as notifications/studio-link above).
config :barkpark_cloud,
  hetzner_http_client: BarkparkCloud.HetznerFakeHttpClient

# azure: the config-selected Azure client seam. Default (prod) is
# Azure.RealClient; tests use the in-memory Azure.FakeClient so verify-before-
# save + the normalized catalog run with ZERO real Azure credentials.
config :barkpark_cloud,
  azure_http_client: BarkparkCloud.Azure.FakeClient

# domain-status (S13): the three DomainStatus outbound seams (DNS resolve, TLS
# dial, serving GET) default to a FAIL-CLOSED offline guard in test, so no test
# can touch the network by accident. Tests that assert real behaviour inject
# their own seam fakes (per-call opts or Application.put_env), which win.
config :barkpark_cloud,
  domain_status_dns: &BarkparkCloud.DomainStatusOfflineGuard.getaddrs/2,
  domain_status_tls: &BarkparkCloud.DomainStatusOfflineGuard.tls/2,
  domain_status_http: &BarkparkCloud.DomainStatusOfflineGuard.http/1

# Speed up the test suite: the default 12 bcrypt log_rounds (~250ms/hash) is
# overkill for tests. 1 round keeps register/verify cycles fast while still
# exercising the real Bcrypt code path.
config :bcrypt_elixir, log_rounds: 1

# Print only warnings and errors during test
config :logger, level: :warning

# Web (cloud-12a): do NOT boot the Bandit HTTP listener in test — the router is
# exercised directly via Plug.Test (`conn(...) |> Router.call(@opts)`), so no
# live socket is needed and the suite stays hermetic / port-conflict-free.
config :barkpark_cloud, BarkparkCloud.Web.Endpoint, server: false

# Billing (cloud-5): tests run the whole pay-once go-live path through the
# in-memory StubGateway — €0, deterministic ids, no network. (config.exs already
# defaults to StubGateway; this is the explicit, env-local statement of intent.)
config :barkpark_cloud, BarkparkCloud.Billing, gateway: BarkparkCloud.Billing.StubGateway

# A FAKE Stripe secret key so the StripeGateway request-builder test can assert
# the exact Authorization header without reaching the wire. There is no
# http_client configured, so even if a callback tried to send, it would fail
# closed (:http_client_not_configured) rather than spend. The LIVE key is HUMAN
# task cloud-17.
config :barkpark_cloud, BarkparkCloud.Billing.StripeGateway,
  secret_key: "sk_test_FAKE_cloud5",
  webhook_secret: "whsec_test_FAKE_cloud5"

# Artifact uploads (P7): use a unique tmp dir per test process so the
# upload route's writes are hermetic. Cap the size at 1 MiB so the
# too-large test stays cheap.
config :barkpark_cloud, BarkparkCloud.Web.Router,
  artifact_dir: Path.join(System.tmp_dir!(), "barkpark-cloud-artifacts-test"),
  max_artifact_bytes: 1024 * 1024

# Provisioning: the shared WORKER token the off-box Go warm-pool
# provisioner presents as `Authorization: Bearer <token>` to the
# /v1/internal/provision-jobs/* endpoints. A FIXED value in test so the
# worker-auth tests can present the right secret (and assert that user/agent
# tokens are rejected). runtime.exs reads WORKER_TOKEN in prod.
config :barkpark_cloud, :worker_token, "worker-token-test-fixed"

# push-relay spike: the process-local fake push transport. Worker tests run
# jobs in-process via Oban.Testing's perform_job/2, so the fake programs its
# verdict and records sends in the TEST process's dictionary (no global state,
# async-safe).
config :barkpark_cloud, :push_adapter, BarkparkCloud.PushFakeAdapter

# push-relay BUILD: the HTTP BOUNDARY fake, one level below the adapter seam
# above. The REAL APNs/FCM adapters are exercised through this — their JWTs,
# URLs, headers and status→verdict mapping run for real; only the socket is
# fake. Adapter tests set :push_adapter to the real module for their own
# duration (the line above stays the default so the worker suite is untouched)
# and program responses per request. Process-dictionary backed, so async-safe.
config :barkpark_cloud, :push_http_client, BarkparkCloud.PushFakeHttpClient

# oban-substrate: manual testing mode — Oban inserts jobs but its queue pollers
# and Cron plugin do NOT auto-execute, so the SQL.Sandbox stays deterministic.
# Tests assert enqueues with Oban.Testing and run a job synchronously via
# `perform_job/2` (which calls the worker inside the test's own transaction).
# Mirrors api/config/test.exs:43 exactly. Config merges on keys, so this only
# overrides `testing:` — the queues/plugins from config.exs stay intact, and no
# Oban process touches the sandboxed connection.
config :barkpark_cloud, Oban, testing: :manual

# OAuth/SSO (oauth-sso): both providers ENABLED with FAKE creds so the routes
# and enabled_providers/0 are exercised. A FIXED state_secret makes the signed
# -state round-trip deterministic, and the http_client is the canned
# BarkparkCloud.OAuthStub — the whole token-exchange + userinfo path runs with
# ZERO network calls (€0, hermetic), exactly the Stripe-stub discipline.
config :barkpark_cloud, BarkparkCloud.OAuth,
  base_url: "http://localhost:4100",
  state_secret: "oauth-state-test-fixed",
  http_client: &BarkparkCloud.OAuthStub.request/1,
  providers: %{
    "github" => %{
      module: BarkparkCloud.OAuth.Github,
      client_id: "gh_test_client_id",
      client_secret: "gh_test_client_secret"
    },
    "google" => %{
      module: BarkparkCloud.OAuth.Google,
      client_id: "g_test_client_id",
      client_secret: "g_test_client_secret"
    }
  }

# site-spawner D22: the box seam. A static site deploy runs ON the instance
# (site-deploy.sh over the admin relay); tests drive an in-memory box instead, so
# the six-stage walk — including a HEALTH failure that must never reach a visitor
# — is proven with ZERO network and zero shell. Same seam shape as the
# studio-link / Hetzner / Azure fakes above.
config :barkpark_cloud,
  site_box_relay: BarkparkCloud.Sites.FakeBoxRelay,
  # The driver is invoked SYNCHRONOUSLY in tests (`Sites.Deploy.run/1`) rather
  # than spawned, so a route test asserts a settled row instead of racing a Task.
  site_deploy_starter: BarkparkCloud.Sites.Deploy.NoopStarter,
  site_deploy_poll_ms: 0,
  site_deploy_poll_max: 10,
  # The restart-grace budget, shrunk to 3 so grace-exhaustion (4 consecutive
  # unreachable polls) and grace-reset (a good poll refreshing the budget between
  # two error bursts) are cheap to prove. Prod default is 45 (~90s).
  site_deploy_poll_grace: 3
