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
  config :barkpark_cloud, BarkparkCloud.Billing,
    gateway: BarkparkCloud.Billing.StripeGateway,
    prices:
      %{
        "supporter" => System.get_env("STRIPE_PRICE_SUPPORTER"),
        "support_plus" => System.get_env("STRIPE_PRICE_SUPPORT_PLUS")
      }
      |> Enum.reject(fn {_plan, price} -> is_nil(price) end)
      |> Map.new()

  config :barkpark_cloud, BarkparkCloud.Billing.StripeGateway,
    secret_key: stripe_secret_key,
    webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET"),
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

  # Web (cloud-12a): the JSON API's listen port in prod, from PORT (default 4100).
  config :barkpark_cloud, BarkparkCloud.Web.Endpoint,
    server: true,
    port: String.to_integer(System.get_env("PORT") || "4100")

  # Artifact uploads (P7): the on-disk dir where the control plane writes the
  # tarballs streamed in via POST /v1/sites/:id/artifact. The builder reads
  # them back via the returned `file://` URL, so the dir must be shared with
  # the builder process. In prod we default to /var/lib/barkpark-cloud/artifacts
  # — a writable system path that survives restarts. Override via
  # BARKPARK_CLOUD_ARTIFACT_DIR (e.g. point at a tmpfs or a mounted volume).
  # Max upload bytes default to 100 MB; raise via BARKPARK_CLOUD_MAX_ARTIFACT_BYTES.
  config :barkpark_cloud, BarkparkCloud.Web.Router,
    artifact_dir:
      System.get_env("BARKPARK_CLOUD_ARTIFACT_DIR") || "/var/lib/barkpark-cloud/artifacts",
    max_artifact_bytes:
      String.to_integer(System.get_env("BARKPARK_CLOUD_MAX_ARTIFACT_BYTES") || "104857600")

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

  # VERIFY the SMTP relay's TLS certificate. gen_smtp does NOT verify unless
  # tls_options carries verify: :verify_peer + a trust store + a raised depth
  # (its default is 0), so without this an active MITM could terminate STARTTLS
  # and capture SMTP_USERNAME / SMTP_PASSWORD. SNI is pinned to the relay host.
  smtp_tls_opts =
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
end
