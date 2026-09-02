import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
#
# In prod the control plane's database is wired entirely from the
# environment. DATABASE_URL points at the control plane's own Postgres —
# the store of metadata about many Barkpark instances, never customer
# content.
if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  config :barkpark_cloud, BarkparkCloud.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  # Registry (cloud-9): the at-rest key for connected-provider tokens. In prod
  # the dev/test default in config.exs is REQUIRED to be overridden — a Base64
  # 32-byte AES-256-GCM key from REGISTRY_ENCRYPTION_KEY. Generate one with:
  #     mix run -e 'IO.puts(:crypto.strong_rand_bytes(32) |> Base.encode64())'
  # Real key management (rotation, KMS) is a later/human concern.
  registry_key =
    System.get_env("REGISTRY_ENCRYPTION_KEY") ||
      raise """
      environment variable REGISTRY_ENCRYPTION_KEY is missing.
      Generate a Base64 32-byte key:
        mix run -e 'IO.puts(:crypto.strong_rand_bytes(32) |> Base.encode64())'
      """

  config :barkpark_cloud, BarkparkCloud.Registry.Vault, key: registry_key

  # Audit trail (activity-audit-log): retention window in days, overridable per
  # deploy. No secret — just an operational knob. Falls back to the config.exs
  # default (90) when AUDIT_RETENTION_DAYS is unset.
  if days = System.get_env("AUDIT_RETENTION_DAYS") do
    config :barkpark_cloud, :audit_retention_days, String.to_integer(days)
  end

  # Billing (cloud-5): in prod, route money through the real Stripe gateway. The
  # LIVE secret key + the per-plan price ids are HUMAN task cloud-17 — but the
  # control plane must not BOOT in prod without a key wired, so we raise here
  # rather than silently fall back to the in-memory stub (which would accept
  # "payments" that never happen). A Stripe test key (`sk_test_…`) satisfies this
  # and exercises the same request shape at €0.
  stripe_secret_key =
    System.get_env("STRIPE_SECRET_KEY") ||
      raise """
      environment variable STRIPE_SECRET_KEY is missing.
      Set the Stripe secret key (a `sk_test_…` key works for the same request
      shape). The LIVE key + per-plan price ids are HUMAN task cloud-17.
      """

  # The per-plan Stripe PRICE ids (cloud-17 / Gate 4). Read from the environment
  # — each MAY be nil here (a human wires the real `price_…` ids at Gate 4). A
  # nil price for a plan means a checkout for that plan can't resolve (the
  # context returns :plan_invalid) until the env is set. "free" has no price.
  stripe_prices =
    %{
      "supporter" => System.get_env("STRIPE_PRICE_SUPPORTER"),
      "support_plus" => System.get_env("STRIPE_PRICE_SUPPORT_PLUS")
    }
    |> Enum.reject(fn {_plan, price} -> is_nil(price) end)
    |> Map.new()

  stripe_webhook_secret = System.get_env("STRIPE_WEBHOOK_SECRET")

  # Per-plan managed-instance ceilings (usage-limits-quotas). Plain integers, no
  # secret — ops can retune a self-serve ceiling via LIMIT_* env without a code
  # change, mirroring how `prices` reads STRIPE_PRICE_*. The defaults match
  # config.exs; the real commercial numbers are HUMAN task cloud-17. `trial` is
  # the signup grant, `forever` the admin comp (effectively unlimited), `none`
  # (no active subscription) is always 0.
  #
  # cch-prod-limit-override-seam-unmirrored: this resolution used to be written
  # out right here, which put it inside `if config_env() == :prod` where no test
  # could reach it. The cross-layer mirror guard could therefore only compare
  # COMMITTED DEFAULTS, and once cloud/docker-compose.yml began passing LIMIT_*
  # through (2c25288479) an operator could move the server's real ceiling from
  # cloud/.env while the console's PLAN_CATALOG constant stayed put — with
  # nothing red. The rule now lives in a callable module and THIS IS ITS ONLY
  # CALLER, so test/barkpark_cloud/billing_client_mirror_test.exs compares what
  # actually runs. Behaviour is unchanged: same four names, same defaults, same
  # String.to_integer — a malformed LIMIT_* still raises at boot rather than
  # silently reading as "no override".
  barkpark_limits = BarkparkCloud.Billing.PlanLimits.resolve()

  # BILL-2 boot-check: the StripeGateway is selected (a secret key is set), but
  # the PAID path is inert until the per-plan price ids AND the webhook signing
  # secret are also wired — without prices a checkout can't resolve a price, and
  # without the webhook secret an activation event can't be verified. We WARN
  # loudly rather than raise: a trial-only deploy (FREE TRIAL → PAID) is a valid
  # launch state where nobody can subscribe yet, so it must still boot. (The
  # STRIPE_SECRET_KEY check above is the hard raise; this is the soft one.)
  if stripe_prices == %{} or is_nil(stripe_webhook_secret) or stripe_webhook_secret == "" do
    IO.warn("""
    Barkpark Cloud billing is only PARTIALLY configured: the Stripe gateway is \
    selected (STRIPE_SECRET_KEY is set) but #{if(stripe_prices == %{}, do: "no STRIPE_PRICE_* prices are wired", else: "")}\
    #{if(stripe_prices == %{} and (is_nil(stripe_webhook_secret) or stripe_webhook_secret == ""), do: " and ", else: "")}\
    #{if(is_nil(stripe_webhook_secret) or stripe_webhook_secret == "", do: "STRIPE_WEBHOOK_SECRET is missing", else: "")}. \
    The FREE TRIAL works, but NO paid subscription can complete until these are \
    set (cloud-17 / Gate 4). bp subscribe will report billing_not_configured.\
    """)
  end

  # dwb-13: the free-trial length in days, ops-tunable via TRIAL_DAYS (default
  # 14). Same env-override seam as `prices` / `limits`.
  trial_days = String.to_integer(System.get_env("TRIAL_DAYS") || "14")

  config :barkpark_cloud, BarkparkCloud.Billing,
    gateway: BarkparkCloud.Billing.StripeGateway,
    prices: stripe_prices,
    limits: barkpark_limits,
    trial_days: trial_days

  config :barkpark_cloud, BarkparkCloud.Billing.StripeGateway,
    secret_key: stripe_secret_key,
    webhook_secret: stripe_webhook_secret,
    # Stripe Checkout return URLs. Default (in the gateway) to the prod domain;
    # override per-deploy (staging/dev) via STRIPE_SUCCESS_URL / STRIPE_CANCEL_URL
    # so a customer is redirected back to the SAME host they checked out from,
    # not always prod. nil here → the gateway's prod-domain fallback.
    success_url: System.get_env("STRIPE_SUCCESS_URL"),
    cancel_url: System.get_env("STRIPE_CANCEL_URL"),
    # Where the Stripe Customer Portal returns the customer after they manage
    # their subscription (subscription-billing). nil → the gateway's prod-domain
    # fallback (https://barkpark.cloud/?billing=portal). No secret.
    portal_return_url: System.get_env("STRIPE_PORTAL_RETURN_URL"),
    # The HTTP client is INJECTED. cloud-17 wires the real one: Erlang's built-in
    # :httpc (no new dep) over VERIFIED TLS — see BarkparkCloud.Billing.HttpClient.
    # This is set ONLY in the prod branch (the StripeGateway is only selected
    # here), so dev/test keep no client and can never silently spend.
    http_client: &BarkparkCloud.Billing.HttpClient.request/1

  # GitHub App (gh-2): HUMAN-LAST. The App id + RSA private key are the human
  # gate — with BOTH set, the Real client is selected and the connect/deploy flow
  # can go live; without them the feature stays flagged OFF (`configured?/0` is
  # false, so every GitHub endpoint 503s feature_not_configured) and the app
  # still BOOTS. No raise: GitHub off is a valid launch state, exactly like a
  # plugin being off. The webhook signing secret + app slug are companion env.
  github_app_id = System.get_env("GITHUB_APP_ID")
  github_private_key = System.get_env("GITHUB_APP_PRIVATE_KEY")

  if github_app_id && github_private_key && github_private_key != "" do
    config :barkpark_cloud, BarkparkCloud.GitHub,
      client: BarkparkCloud.GitHub.Real,
      app_id: github_app_id,
      private_key: github_private_key,
      webhook_secret: System.get_env("GITHUB_APP_WEBHOOK_SECRET"),
      app_slug: System.get_env("GITHUB_APP_SLUG"),
      # Injected verified-TLS transport (no new dep) — the same built-in :httpc
      # client the billing + studio-link seams use.
      http_client: &BarkparkCloud.Billing.HttpClient.request/1
  else
    # Creds absent → keep the in-memory Fake OUT of prod. Select Real with NO
    # credentials so any accidental invocation fails CLOSED (:not_configured /
    # :http_client_not_configured) rather than fabricating a success — but the
    # endpoints are already gated OFF by `configured?/0`. `app_slug` MAY still be
    # set so the dashboard shows the right hint.
    config :barkpark_cloud, BarkparkCloud.GitHub,
      client: BarkparkCloud.GitHub.Real,
      app_id: nil,
      private_key: nil,
      app_slug: System.get_env("GITHUB_APP_SLUG")
  end

  # Zero-paste Vercel handoff (task-4e4a53b101a97051, HUMAN-LAST): with
  # VERCEL_PLATFORM_TOKEN wired, the deploy endpoint platform-deploys templates
  # (env installed server-side) and mints claim codes. Absent → configured?/0 is
  # false, the endpoint 503s feature_not_configured, and the SPA falls back to
  # the classic /new/clone copy-block handoff. VERCEL_TEAM_ID is required only
  # for a team-scoped token (appended as ?teamId= on every call).
  vercel_token = System.get_env("VERCEL_PLATFORM_TOKEN")

  if vercel_token && vercel_token != "" do
    config :barkpark_cloud, BarkparkCloud.Vercel,
      client: BarkparkCloud.Vercel.Real,
      token: vercel_token,
      team_id: System.get_env("VERCEL_TEAM_ID"),
      http_client: &BarkparkCloud.Billing.HttpClient.request/1
  else
    # Token absent → keep the in-memory Fake OUT of prod. Select Real with NO
    # token so any accidental invocation fails CLOSED (:not_configured) — the
    # endpoint is already gated OFF by `configured?/0`.
    config :barkpark_cloud, BarkparkCloud.Vercel,
      client: BarkparkCloud.Vercel.Real,
      token: nil
  end

  # azure-retail-pricing: wire the REAL transport for the credential-free Azure
  # Retail Prices client only in prod — the same built-in verified-TLS :httpc
  # client the billing/oauth/github seams use (no new dep). The Retail Prices API
  # is unauthenticated and global, so no credential is threaded here; dev/test
  # leave this nil (config.exs) and never hit the wire.
  config :barkpark_cloud, BarkparkCloud.Azure.Pricing,
    http_client: &BarkparkCloud.Billing.HttpClient.request/1

  # portable-archives (S14/D39): wire the S3 read conduit's credentials + bucket
  # in prod from env. The location defaults to fsn1 (Hetzner Object Storage). The
  # transport defaults to the module's own verified-TLS :httpc client — no new
  # dep. Blank creds ⇒ the store fails closed (:not_configured) and GET
  # /v1/archives degrades honestly. See BarkparkCloud.ArchiveStore.
  config :barkpark_cloud, BarkparkCloud.ArchiveStore,
    access_key: System.get_env("HETZNER_S3_ACCESS_KEY"),
    secret_key: System.get_env("HETZNER_S3_SECRET_KEY"),
    bucket: System.get_env("BARKPARK_BUNDLE_BUCKET"),
    location: System.get_env("BARKPARK_BUNDLE_LOCATION") || "fsn1"

  # ── Push relay credentials (mobile charter D15) — THE HUMAN GATE ───────────
  #
  # These five (+ one) env vars are the ONLY thing standing between the built,
  # tested relay and real notifications. Set them and restart; nothing else
  # changes. Absent, BarkparkCloud.Push.adapter_for/1 resolves to
  # Adapters.NotConfigured and every send cancels terminally — no flag, no dead
  # code, no half-state. The full acquisition steps (which Apple/Firebase
  # console page, what the value looks like, and the CLIENT-side entitlements
  # that must land in the same wave) live in the moduledoc of
  # BarkparkCloud.Push.Adapters.NotConfigured — read that before opening the
  # gate. cloud/.env.example carries the same list in env form.
  #
  # The two platforms are INDEPENDENT: Android alone is a valid state.
  config :barkpark_cloud, BarkparkCloud.Push.Adapters.APNS,
    # The FULL .p8 PEM contents. Docker/systemd env cannot carry raw newlines,
    # so a literal "\n" in the value is expanded back — paste the file with
    # `awk '{printf "%s\\n", $0}' AuthKey_XXX.p8` or with real newlines; both work.
    key_p8: System.get_env("APNS_KEY_P8") |> then(&(&1 && String.replace(&1, "\\n", "\n"))),
    key_id: System.get_env("APNS_KEY_ID"),
    team_id: System.get_env("APNS_TEAM_ID"),
    topic: System.get_env("APNS_BUNDLE_ID"),
    # "sandbox" (default) or "production". The wrong value 400s every send with
    # BadDeviceToken on a perfectly valid token — the classic APNs trap.
    env: System.get_env("APNS_ENV") || "sandbox"

  config :barkpark_cloud, BarkparkCloud.Push.Adapters.FCM,
    service_account_json: System.get_env("FCM_SERVICE_ACCOUNT_JSON")

  # Web (cloud-12a): the JSON API's listen port in prod, from PORT (default 4100).
  config :barkpark_cloud, BarkparkCloud.Web.Endpoint,
    server: true,
    port: String.to_integer(System.get_env("PORT") || "4100")

  # Artifact uploads: NO on-disk config, deliberately (site-spawner W9, charter
  # D91). This block used to set `artifact_dir` — a host-local path the upload
  # route wrote tarballs to, returned as a `file://` URL, with a comment claiming
  # it "survives restarts". The compose file refutes that: the control-plane
  # container declares no volume for it, and the box that would read the path
  # runs on a different host entirely, so nothing could ever open the URL. The
  # sink is now Postgres (`site_artifacts` on cloud_pgdata, the CP's only durable
  # volume) and the 32 MB cap is a module attribute on the router — a size that
  # bounds a build OUTPUT rather than a whole project dir needs no per-deploy
  # tuning knob.

  # Provisioning: the shared WORKER token the off-box Go warm-pool
  # provisioner presents to /v1/internal/provision-jobs/*. May be nil here — the
  # control plane still boots without it; require_worker then fails CLOSED (every
  # internal request 401s) until WORKER_TOKEN is set. The SAME secret is handed
  # to the Go provisioner (--token / --token-file).
  config :barkpark_cloud, :worker_token, System.get_env("WORKER_TOKEN")

  # oban-substrate: let prod tune queue concurrency / pause the engine without a
  # redeploy (e.g. during a migration window). Additive — the queues/plugins from
  # config.exs stay in force; this only overrides the `:queues` key, leaving the
  # Pruner + Cron plugins untouched. Default preserves config.exs. NO new secret:
  # Oban needs only the Repo, already wired from DATABASE_URL above.
  #   OBAN_QUEUES_DISABLED=true → queues: false (drain nothing; jobs accrue and
  #   run once re-enabled). Cron still inserts scheduled jobs; they wait.
  oban_queues =
    case System.get_env("OBAN_QUEUES_DISABLED") do
      "true" -> false
      _ -> [default: 10, maintenance: 2]
    end

  config :barkpark_cloud, Oban, queues: oban_queues

  # notifications-email: the PLATFORM mailer transport in prod — Swoosh over
  # gen_smtp, every credential from env (mirrors the Stripe / Vault env reads).
  # No secret in code. The HUMAN gate (the notifications-email analogue of
  # cloud-17) is wiring the live SMTP relay creds + a verified From domain; until
  # SMTP_HOST is set, a send fails closed (a `failed` Delivery row) rather than
  # spending or leaking. Per-team SMTP secrets ride Registry.Vault, not this.
  smtp_relay = System.get_env("SMTP_HOST")

  # VERIFY the SMTP relay's TLS certificate by default. gen_smtp does NOT
  # verify unless tls_options carries verify: :verify_peer + a trust store +
  # a raised depth (its default is 0), so without this an active MITM could
  # terminate STARTTLS and capture SMTP_USERNAME / SMTP_PASSWORD. SNI is
  # pinned to the relay host.
  #
  # SMTP_VERIFY_PEER=false opts out, for the self-hosted `postfix` sidecar
  # (cloud/postfix/) reachable only over the docker-compose internal network
  # — that hop's transport is already trusted, so peer verification adds
  # nothing but cert-provisioning friction. A public third-party relay MUST
  # keep verification on (the default).
  smtp_verify_peer? = System.get_env("SMTP_VERIFY_PEER", "true") != "false"

  smtp_tls_opts =
    if smtp_verify_peer? do
      [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 9,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ] ++
        if(is_binary(smtp_relay) and smtp_relay != "",
          do: [server_name_indication: String.to_charlist(smtp_relay)],
          else: []
        )
    else
      [verify: :verify_none]
    end

  config :barkpark_cloud, BarkparkCloud.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    relay: smtp_relay,
    username: System.get_env("SMTP_USERNAME"),
    password: System.get_env("SMTP_PASSWORD"),
    port: String.to_integer(System.get_env("SMTP_PORT") || "587"),
    ssl: false,
    tls: :always,
    tls_options: smtp_tls_opts,
    auth: :always,
    retries: 2

  config :barkpark_cloud, BarkparkCloud.Notifications,
    from_address: System.get_env("MAIL_FROM_ADDRESS") || "noreply@barkpark.cloud",
    from_name: System.get_env("MAIL_FROM_NAME") || "Barkpark Cloud"

  # isu-w5: the platform-operator allowlist for the daily fleet digest —
  # comma-separated emails (e.g. "ops@x.io, admin@x.io"). This is the runtime
  # override the config.exs default promises: unset/blank keeps `[]`, so the
  # digest worker stays a LOGGED no-op until an operator opts in. Each entry is
  # still resolved to a REGISTERED user before it is ever mailed
  # (Notifications.platform_admin_emails/0) — this var alone can't open a relay.
  config :barkpark_cloud,
         :platform_admin_emails,
         System.get_env("PLATFORM_ADMIN_EMAILS", "")
         |> String.split(",")
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == ""))

  # OAuth/SSO (oauth-sso): "Continue with GitHub / Google". Creds come from env
  # exactly like Stripe / the registry key — NEVER in code. A provider with empty
  # creds is simply DISABLED (its button hides, its routes 404), so the control
  # plane boots fine with neither, one, or both providers wired.
  #
  # OAUTH_STATE_SECRET is REQUIRED in prod (it is the HMAC key for the single-use
  # CSRF state token) — raise rather than silently sign with a guessable default.
  # The redirect_uri is DERIVED from OAUTH_BASE_URL, not stored: the operator
  # registers `<base>/v1/auth/oauth/<provider>/callback` in each provider's app.
  # The http_client is the SAME verified-TLS :httpc transport billing uses — set
  # only here (prod), so dev/test never hit the wire.
  config :barkpark_cloud, BarkparkCloud.OAuth,
    base_url: System.get_env("OAUTH_BASE_URL") || "https://barkpark.cloud",
    state_secret:
      System.get_env("OAUTH_STATE_SECRET") ||
        raise("""
        environment variable OAUTH_STATE_SECRET is missing (the HMAC key for the
        OAuth CSRF state token). Generate one with:
          mix run -e 'IO.puts(:crypto.strong_rand_bytes(32) |> Base.encode64())'
        """),
    http_client: &BarkparkCloud.Billing.HttpClient.request/1,
    providers: %{
      "github" => %{
        module: BarkparkCloud.OAuth.Github,
        client_id: System.get_env("GITHUB_OAUTH_CLIENT_ID"),
        client_secret: System.get_env("GITHUB_OAUTH_CLIENT_SECRET")
      },
      "google" => %{
        module: BarkparkCloud.OAuth.Google,
        client_id: System.get_env("GOOGLE_OAUTH_CLIENT_ID"),
        client_secret: System.get_env("GOOGLE_OAUTH_CLIENT_SECRET")
      }
    }

  # email-verification-recovery: the public dashboard base URL the emailed
  # `?confirm=` link points at. Falls back to the config.exs default.
  if dashboard_url = System.get_env("DASHBOARD_URL") do
    config :barkpark_cloud, dashboard_url: dashboard_url
  end

  # site-spawner W5 (charter D45): the control plane's own public origin, the host
  # a co-located box POSTs a content-publish webhook back to. Falls back to the
  # config.exs default (the prod API host).
  if public_url = System.get_env("PUBLIC_URL") || System.get_env("CONTROL_PLANE_URL") do
    config :barkpark_cloud, :public_url, public_url
  end
end

# cch-w1-peer-ip-pin: the front-door peers whose X-Forwarded-For may move
# conn.remote_ip, as a comma-separated list of IP addresses (e.g.
# "172.18.0.1"). Loopback is always trusted in code and does not need listing.
#
# Deliberately OUTSIDE the prod block: the container runs this stack in any
# MIX_ENV, and the docker bridge gateway is a property of the DEPLOYMENT, not of
# the environment name. Unset keeps the config.exs default (the pinned gateway),
# which is what compose's pinned subnet allocates.
#
# List INDIVIDUAL ADDRESSES ONLY, and keep this in step with the `networks:`
# subnet in cloud/docker-compose.yml. Do not be tempted to accept CIDR ranges
# here: a range re-opens the forgery hole this pin exists to close (charter D5 —
# 172.18.0.2 is an internet-facing SMTP container). A malformed entry raises at
# boot rather than silently degrading the guard to a no-op.
if peers = System.get_env("TRUSTED_PROXY_PEERS") do
  config :barkpark_cloud,
         :trusted_proxy_peers,
         peers
         |> String.split(",")
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == ""))
         |> Enum.map(fn peer ->
           case :inet.parse_address(String.to_charlist(peer)) do
             {:ok, address} ->
               address

             {:error, _} ->
               raise """
               TRUSTED_PROXY_PEERS contains #{inspect(peer)}, which is not a valid IP address.
               Expected a comma-separated list of individual addresses, e.g. "172.18.0.1".
               CIDR ranges are NOT supported: trusting a whole subnet lets any container on
               it forge every client's session IP and rate-limit bucket.
               """
           end
         end)
end

# gh-9531 residual (task-eeabfd9bf3ed8371) — the two DEPLOYMENT values this
# control plane used to freeze at BUILD time in module attributes:
#
#   * PLATFORM_BASE_DOMAIN — the public zone every managed instance lives under
#     (`BarkparkCloud.Registry.Barkpark.base_domain/0`). It names every
#     provisioning subdomain, every site URL, and the zone split inside
#     `custom_host_changeset/2` — so a self-hosted plane could neither issue
#     URLs under its own zone NOR accept its operator's own domain shape.
#     The off-box Go warm-pool worker carries its own base domain: set BOTH to
#     the same zone, or the FQDN this plane shows and the one the worker stands
#     up diverge.
#   * TEMPLATES_REPO_URL — the repo the `/new?template=…` clone handoff points
#     at (`BarkparkCloud.Templates.repo/0`). Running the plane against a FORK
#     still handed users the upstream repo.
#
# Deliberately OUTSIDE the prod block: which zone this plane owns is a property
# of the DEPLOYMENT, not of MIX_ENV. Unset keeps the historical literals, so an
# existing deployment is unchanged. A present-but-malformed value is NOT
# silently discarded — both readers raise, and
# `BarkparkCloud.Application.start/2` calls them at boot, so the node REFUSES
# rather than quietly serving ours.
if base_domain = System.get_env("PLATFORM_BASE_DOMAIN") do
  config :barkpark_cloud, :base_domain, base_domain
end

if templates_repo_url = System.get_env("TEMPLATES_REPO_URL") do
  config :barkpark_cloud, :templates_repo_url, templates_repo_url
end
