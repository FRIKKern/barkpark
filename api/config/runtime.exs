import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/barkpark start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :barkpark, BarkparkWeb.Endpoint, server: true
end

# Server-owned CycleFleet release capture. The bearer token is passed only to
# the isolated reader processes and is never persisted in the challenge. The
# executable paths must be absolute; the adapter rejects relative/path-search
# execution so a user-controlled working directory cannot select a binary.
for {env_name, config_key} <- [
      {"BARKPARK_RELEASE_CAPTURE_TOKEN", :cycle_release_capture_token},
      {"BARKPARK_RELEASE_CAPTURE_BP_PATH", :cycle_release_capture_bp_path},
      {"BARKPARK_DEPLOYMENT_DIGEST", :release_deployment_digest}
    ] do
  case System.get_env(env_name) do
    value when is_binary(value) and value != "" -> config :barkpark, config_key, value
    _ -> :ok
  end
end

case System.get_env("BARKPARK_RELEASE_CAPTURE_HMAC_SECRET") do
  secret when is_binary(secret) and byte_size(secret) >= 32 ->
    config :barkpark, :cycle_release_capture_hmac_secret, secret

  _ ->
    if config_env() == :prod do
      raise "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET must contain at least 32 bytes"
    end
end

# SECRET_KEY_BASE, read and validated ONCE for every consumer (the endpoint
# and the media-signing derive below both use this binding). The predicate is
# on the RAW env string — at least 64 bytes, never trimmed, never decoded:
# Plug enforces a 64-byte minimum at first session use, so a shorter value
# boots clean and then 500s on /login and /studio. Prod refuses at boot with
# the message below instead; dev/test keep their config-file defaults (nil
# here). The refusal prints the LENGTH, never the value.
secret_key_base =
  case System.get_env("SECRET_KEY_BASE") do
    skb when is_binary(skb) and byte_size(skb) >= 64 ->
      skb

    other ->
      if config_env() == :prod do
        got =
          case other do
            nil -> "it is not set"
            short -> "got #{byte_size(short)} bytes"
          end

        raise """
        SECRET_KEY_BASE must be at least 64 bytes (#{got}).

        Phoenix derives cookie/session signing keys from it; Plug enforces a
        64-byte minimum at first session use — a shorter value boots clean,
        then 500s on /login and /studio.

        Generate one: openssl rand -base64 64 — and set SECRET_KEY_BASE in
        .env (compose) or /opt/barkpark/.env.
        """
      end
  end

# Continuous-canvas editor cutover: ON by default in PRODUCTION (the unified
# <bp-paper-canvas> Obsidian-style editor). Dev/test stay OFF (the per-block
# <bp-paper-editor>) so the flag-OFF byte-identical guarantee and its tests hold.
# PaperCanvas.paper_canvas_enabled?/0 reads BARKPARK_PAPER_CANVAS at request time, so
# this is an overridable DEFAULT — set BARKPARK_PAPER_CANVAS=0 in the prod env to roll
# back instantly (no code redeploy); flag-off is byte-identical, no data migration.
if config_env() == :prod and System.get_env("BARKPARK_PAPER_CANVAS") in [nil, ""] do
  System.put_env("BARKPARK_PAPER_CANVAS", "1")
end

# studio-anonymous-default-lockdown: production Studio requires a login by
# default — the anonymous Default-workspace demo posture is an explicit
# opt-in for self-hosters who WANT a public demo box. Published papers stay
# world-readable regardless (the reader surface doesn't carry this flag).
if config_env() == :prod do
  config :barkpark,
         :public_demo_studio,
         System.get_env("BARKPARK_PUBLIC_DEMO_STUDIO") in ["1", "true"]
end

# staging-barkpark identity tag: BARKPARK_ENV names WHICH instance this is
# ("staging", "prod", …) so the Studio chrome renders an unmissable banner.
# This is an IDENTITY label, NOT MIX_ENV — a prod-compiled release runs on the
# staging box with BARKPARK_ENV=staging. Raw lowercased string; stays nil when
# unset or empty (same opt-in shape as BARKPARK_PUBLIC_DEMO_STUDIO above).
if config_env() == :prod do
  case System.get_env("BARKPARK_ENV") do
    v when is_binary(v) and v != "" ->
      config :barkpark, :instance_env, String.downcase(v)

    _ ->
      :ok
  end
end

# Studio tmux console: ON by default on every Studio (admin-gated; auto-refused
# on any host where public_demo_studio is on). Opt OUT per host by setting
# BARKPARK_TMUX_CONSOLE to a falsy value. Merge keeps the compiled backend.
if System.get_env("BARKPARK_TMUX_CONSOLE") in ["0", "false", "no", "off"] do
  config :barkpark, :tmux_console, enabled: false
end

# Studio Claude chat: ON by default wherever the `claude` binary is installed
# (admin-gated; auto-refused on any host where public_demo_studio is on). Opt
# OUT per host by setting BARKPARK_CLAUDE_CHAT to a falsy value.
if System.get_env("BARKPARK_CLAUDE_CHAT") in ["0", "false", "no", "off"] do
  config :barkpark, :claude_chat, enabled: false
end

# "Log in with Barkpark Cloud" (instance-login handoff): on a cloud-managed
# instance, the control plane's public origin here puts the cloud sign-in
# button on /login. The button deep-links to the cloud SPA, which mints a
# login ticket via the existing studio-link route and lands the user back
# signed in. Unset → the button never renders (e.g. plain self-host).
case System.get_env("BARKPARK_CLOUD_URL") do
  url when is_binary(url) and url != "" ->
    config :barkpark, :cloud_login_url, url

  _ ->
    :ok
end

config :barkpark, BarkparkWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

cloak_key =
  case System.get_env("BARKPARK_CLOAK_KEY") do
    nil ->
      if config_env() == :prod do
        raise """
        BARKPARK_CLOAK_KEY is not set.

        Generate one with:
            openssl rand -base64 32
        and add to /opt/barkpark/.env as BARKPARK_CLOAK_KEY=<value>.

        This MUST be independent of SECRET_KEY_BASE so that key rotation
        in either system does not invalidate the other.
        """
      else
        # Dev/test fallback — documented constant; rotation in dev does not matter.
        "DEV-ONLY-cloak-key-do-not-use-in-prod-32"
      end

    val ->
      val
  end

config :barkpark, Barkpark.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1", key: :crypto.hash(:sha256, cloak_key), iv_length: 12
    }
  ]

# ── Connectors: the connect seam (connectors D50) ──────────────────────────
#
# CONNECTORS_CONNECT_SECRET is the SAME value the bridge reads — it is the HMAC
# key for connect tickets, generated ONCE by deploy/instance-deploy.sh into
# /opt/barkpark/.env and copied into /etc/barkpark/connectors.env. It is
# deliberately OPTIONAL: absent ⇒ no connect seam (the bridge does not mount the
# connect routes, Studio's catalog renders read-only with a banner). NEVER raise
# on a missing secret — an instance without connectors is a normal instance, and
# a boot failure here would take the whole app down for a feature it does not use.
#
# CONNECTORS_BRIDGE_URL points at the bridge's LOOPBACK listener. The default
# matches instance-deploy.sh's CONNECTORS_HTTP_ADDR (127.0.0.1:4020) +
# CONNECTORS_PATH_PREFIX (/connectors); override only if those move.
#
# The OAuth client config for Slack + Linear is plumbed here too (connectors
# D171): catalog.ex's slack_oauth_config/0 + linear_oauth_config/0 read
# :slack_client_id / :slack_redirect_uri / :linear_client_id /
# :linear_redirect_uri from THIS keyword block — without these reads those keys
# are never written and both OAuth cards sit permanently in the honest
# not-configured gate. These names are NOT secret-shaped (no TOKEN/SECRET/KEY
# suffix) — client ids + redirect URIs are public. The redirect_uri values MUST
# byte-match the bridge callback (<public>+<pathPrefix>/oauth/<provider>/callback)
# — Linear revalidates it at token exchange. Absent ⇒ nil ⇒ not-configured gate
# unchanged; the cards light up for free once a human registers the OAuth apps.
connectors_env =
  [
    connect_secret: System.get_env("CONNECTORS_CONNECT_SECRET"),
    bridge_url: System.get_env("CONNECTORS_BRIDGE_URL"),
    slack_client_id: System.get_env("CONNECTORS_SLACK_CLIENT_ID"),
    slack_redirect_uri: System.get_env("CONNECTORS_SLACK_REDIRECT_URI"),
    linear_client_id: System.get_env("CONNECTORS_LINEAR_CLIENT_ID"),
    linear_redirect_uri: System.get_env("CONNECTORS_LINEAR_REDIRECT_URI")
  ]
  |> Enum.reject(fn {_k, v} -> is_nil(v) or String.trim(v) == "" end)

if connectors_env != [] do
  config :barkpark, Barkpark.Connectors, connectors_env
end

# Master KEK for envelope encryption (core auth/secrets, Phase 0). The dev/test
# default lives in config/config.exs; here we OVERRIDE from BARKPARK_KEK and
# REQUIRE it in prod. Base64 of exactly 32 raw bytes — generate with
# `openssl rand -base64 32`. MUST be independent of BARKPARK_CLOAK_KEY and
# SECRET_KEY_BASE. A SET value is validated in EVERY env (an empty or
# wrong-length key would otherwise pass boot and only be rejected by LocalKek
# at the FIRST encrypted-field seal, an unbounded time after boot); the
# nil branch stays prod-gated.
case System.get_env("BARKPARK_KEK") do
  nil ->
    if config_env() == :prod do
      raise """
      BARKPARK_KEK is not set.

      Generate a base64 32-byte key and add it to /opt/barkpark/.env as
      BARKPARK_KEK=<value>. It MUST be independent of BARKPARK_CLOAK_KEY and
      SECRET_KEY_BASE. Without it, content fields marked `encrypted: true`
      cannot be sealed.
      """
    end

  kek ->
    case Base.decode64(kek) do
      {:ok, raw} when byte_size(raw) == 32 ->
        :ok

      _ ->
        raise """
        BARKPARK_KEK must be the base64 encoding of exactly 32 raw bytes.

        Generate one: openssl rand -base64 32 — it MUST be independent of
        BARKPARK_CLOAK_KEY and SECRET_KEY_BASE; LocalKek would otherwise
        reject this key at the FIRST encrypted-field seal, an unbounded time
        after boot.
        """
    end

    # MEDIUM-9: BARKPARK_KEK_PREVIOUS (comma-separated Base64 keys, oldest-last)
    # lets `DataKeys.rewrap_all/0` complete a KEK rotation — it unwraps blobs
    # sealed by a prior KEK and re-wraps them under the current one. Set it to the
    # OLD BARKPARK_KEK during the rotation window, then clear it once rewrap_all
    # has run. Absent → no fallback (single-key behaviour, unchanged).
    previous_keys =
      System.get_env("BARKPARK_KEK_PREVIOUS", "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    config :barkpark, Barkpark.Crypto.LocalKek,
      key: kek,
      previous_keys: previous_keys,
      version: String.to_integer(System.get_env("BARKPARK_KEK_VERSION", "1"))
end

# Bokbasen credentials (Phase 7 / OnixEdit plugin, WI2). Read from OS env in
# every environment so dev can `source deploy/bokbasen.env` and prod can rely
# on systemd's EnvironmentFile=. Missing values fall back to the encrypted
# plugin_settings row at lookup time — see
# `Barkpark.Plugins.OnixEdit.Bokbasen.Settings`. The HTTP client (WI3) and
# the Oban worker (WI4) read this via `get_credentials/0`.
bokbasen_env_keys = [
  api_base: System.get_env("BOKBASEN_API_BASE"),
  oauth_token_url: System.get_env("BOKBASEN_OAUTH_TOKEN_URL"),
  client_id: System.get_env("BOKBASEN_CLIENT_ID"),
  client_secret: System.get_env("BOKBASEN_CLIENT_SECRET"),
  client_role: System.get_env("BOKBASEN_CLIENT_ROLE")
]

bokbasen_env =
  bokbasen_env_keys
  |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

if bokbasen_env != [] do
  config :barkpark, Barkpark.Plugins.OnixEdit.Bokbasen, bokbasen_env
end

# Indx search-engine credentials (retriever seam). `Barkpark.Plugins.Indx.Settings`
# reads these from `Application.get_env(:barkpark, Barkpark.Plugins.Indx)` (env
# wins, else the encrypted plugin_settings row, else defaults) — but nothing
# populated that app-env key, so api_base/user_email/user_password resolved to
# nil and Indx.Auth raised "user_password not configured", failing every
# rebuild. Map the INDX_* OS env vars here, mirroring the Bokbasen block above.
# (INDX_INCREMENTAL_UPSERT is read directly via System.get_env in Settings, so
# it is intentionally not mapped here.)
indx_env =
  [
    api_base: System.get_env("INDX_API_BASE"),
    user_email: System.get_env("INDX_USER_EMAIL"),
    user_password: System.get_env("INDX_USER_PASSWORD"),
    # v5: team that owns the datasets (route scope) + static JWT API token from
    # the Indx portal (/Account/ApiKey). Setting INDX_TEAM flips the client to
    # v5 team-scoped routes + token auth; until both are set, legacy behavior.
    team: System.get_env("INDX_TEAM"),
    api_token: System.get_env("INDX_API_TOKEN")
  ]
  |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

if indx_env != [] do
  config :barkpark, Barkpark.Plugins.Indx, indx_env
end

# One-way PULL sync source (Barkpark.Sync). `Barkpark.Sync.Settings.load/0`
# reads these from `Application.get_env(:barkpark, Barkpark.Sync)` (env wins,
# else the config.exs `enabled: false` default). Placed OUTSIDE the
# `config_env() == :prod` guard so it applies in all envs — exactly the
# Indx/Bokbasen idiom above. DORMANT unless a source is configured AND
# BARKPARK_SYNC_ENABLED is truthy; `enabled?/0` additionally requires
# url+token+dataset all present, so a partial config can never accidentally
# start the puller.
sync_env =
  [
    url: System.get_env("BARKPARK_SYNC_URL"),
    token: System.get_env("BARKPARK_SYNC_TOKEN"),
    workspace: System.get_env("BARKPARK_SYNC_WORKSPACE"),
    project: System.get_env("BARKPARK_SYNC_PROJECT"),
    dataset: System.get_env("BARKPARK_SYNC_DATASET")
  ]
  |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

if sync_env != [] do
  # PUSH knobs (P2). `push_enabled` is a SEPARATE flag from `enabled` (pull):
  # push stays OFF unless explicitly requested, even when pull is on
  # (default-off, invariant #2). Batch size / interval are pure tunables.
  push_env =
    [
      push_enabled: System.get_env("BARKPARK_SYNC_PUSH_ENABLED") in ~w(1 true yes on),
      push_batch_size: System.get_env("BARKPARK_SYNC_PUSH_BATCH_SIZE"),
      push_interval_ms: System.get_env("BARKPARK_SYNC_PUSH_INTERVAL_MS")
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

  config :barkpark,
         Barkpark.Sync,
         sync_env ++
           [enabled: System.get_env("BARKPARK_SYNC_ENABLED") in ~w(1 true yes on)] ++ push_env
end

# Plugin selection from `bp setup` (BARKPARK_PLUGINS in .env). This is the
# runtime side of the registry kill switch — see
# `Barkpark.Plugins.Registry.discover_and_register/0`:
#
#   * env UNSET  -> leave :plugins unconfigured = discover-all-from-disk
#                   (fresh-install / production default — do NOT force []).
#   * env ""     -> config :plugins, [] = the kill switch (register nothing).
#   * env "a,b"  -> config :plugins, ["a", "b"] = explicit whitelist.
#
# `EnvConfig.parse/1` returns `:unset` only for nil, so the common unset case
# never touches the env and behaviour is identical to before.
case Barkpark.Plugins.EnvConfig.parse(System.get_env("BARKPARK_PLUGINS")) do
  :unset -> :ok
  plugins when is_list(plugins) -> config :barkpark, :plugins, plugins
end

# Task lease TTL override. The default (config.exs) is 2700 s (45 min), sized
# to real agent work. Operators tune it per-fleet without a rebuild via
# BARKPARK_TASK_LEASE_TTL_SECONDS — a positive integer number of seconds.
# Unset / empty / non-positive / non-integer leaves the compiled default in
# place (the TtlSweeper also falls back to its own default if config is nil).
case System.get_env("BARKPARK_TASK_LEASE_TTL_SECONDS") do
  raw when is_binary(raw) and raw != "" ->
    case Integer.parse(raw) do
      {ttl, ""} when ttl > 0 ->
        config :barkpark, :task_lease_ttl_seconds, ttl

      _ ->
        IO.warn(
          "BARKPARK_TASK_LEASE_TTL_SECONDS=#{inspect(raw)} is not a positive integer — " <>
            "keeping the compiled default"
        )
    end

  _ ->
    :ok
end

# Engagement honesty TTL override (tlv-s6). The default (config.exs) is 900 s
# (15 min) — the lapse lease for the considering/researching thought states.
# Same positive-int-or-warn shape as the work lease above.
case System.get_env("BARKPARK_TASK_ENGAGEMENT_TTL_SECONDS") do
  raw when is_binary(raw) and raw != "" ->
    case Integer.parse(raw) do
      {ttl, ""} when ttl > 0 ->
        config :barkpark, :task_engagement_ttl_seconds, ttl

      _ ->
        IO.warn(
          "BARKPARK_TASK_ENGAGEMENT_TTL_SECONDS=#{inspect(raw)} is not a positive integer — " <>
            "keeping the compiled default"
        )
    end

  _ ->
    :ok
end

# Paper access-log retention override (edit-on-the-link slice 4). The default
# (config.exs) is 90 days. Same positive-int-or-warn shape as the two leases
# above; an operator with a stricter retention policy sets it without a rebuild.
case System.get_env("BARKPARK_PAPER_ACCESS_LOG_TTL_DAYS") do
  raw when is_binary(raw) and raw != "" ->
    case Integer.parse(raw) do
      {days, ""} when days > 0 ->
        config :barkpark, :paper_access_log_ttl_days, days

      _ ->
        IO.warn(
          "BARKPARK_PAPER_ACCESS_LOG_TTL_DAYS=#{inspect(raw)} is not a positive integer — " <>
            "keeping the compiled default"
        )
    end

  _ ->
    :ok
end

# Pulse (Shared Storm) public event channels. DEFAULT-OFF: unset/empty/invalid
# env means %{} — every pulse route 404s and nothing on the instance is
# anonymously writable. Value is a JSON object keyed by channel name; see
# Barkpark.Pulse @moduledoc for the per-channel keys. Example:
#   BARKPARK_PULSE_CHANNELS='{"jarl-card":{"fields":{"hue":["int",0,359],
#     "x":["float",0,1],"y":["float",0,1],"mega":["bool"]}}}'
# The fixed monthly price of this box (EUR) — the pulse cost dashboard
# multiplies it by live CPU share for the "what the storm costs" estimate.
with raw when is_binary(raw) and raw != "" <- System.get_env("BARKPARK_HOST_EUR_MONTH"),
     {price, _} <- Float.parse(raw) do
  config :barkpark, :pulse_host_eur_month, price
else
  _ -> :ok
end

with raw when is_binary(raw) and raw != "" <- System.get_env("BARKPARK_PULSE_CHANNELS"),
     {:ok, channels} when is_map(channels) <- Jason.decode(raw) do
  config :barkpark, :pulse_channels, channels
else
  nil -> :ok
  "" -> :ok
  {:error, _} -> IO.warn("BARKPARK_PULSE_CHANNELS is not valid JSON — pulse channels closed")
  _ -> :ok
end

# Scoped-sharing registry (P1a/P1c). Enable via the BARKPARK_SHARES env var.
# Format: "ws/proj/dataset:papers,docs:read;acme/web/staging:media:edit".
# See Barkpark.Sharing.parse/1 for full syntax.
#
# DEFAULT-OFF is paramount: with BARKPARK_SHARES unset/empty, `parse/1` returns
# [], so :shares is set to the harmless empty list AND the Endpoint http binding
# is left exactly as the env file configured it (dev.exs keeps ip: {127,0,0,1}).
#
# P4: `:shares_env` is the STATIC env baseline. The live `:shares` starts equal
# to it and is recomputed post-boot by `Barkpark.Sharing.refresh/0` as
# `shares_env ++ <persisted shares table>`, so a `bp share add` survives a
# restart. We seed `:shares` here too so the registry is correct even before the
# Repo is up (refresh/0 is GUARDED and a no-op until it is).
#
# LAN binding: we deep-merge `ip: {0,0,0,0}` over the existing http config
# (preserving the port) when EITHER at least one env share parses OR
# BARKPARK_SHARE_LAN is truthy. The flag decouples "expose this box on the LAN"
# from "which scopes" — set it to manage shares entirely via `bp share`/Studio
# (the env list may be empty). With neither, the bind is untouched (127.0.0.1 in
# dev). The boot banner in Barkpark.Application logs URLs + a trust warning.
if Code.ensure_loaded?(Barkpark.Sharing) do
  shares = Barkpark.Sharing.parse(System.get_env("BARKPARK_SHARES"))
  config :barkpark, :shares_env, shares
  config :barkpark, :shares, shares

  lan_opt_in? = System.get_env("BARKPARK_SHARE_LAN") in ~w(1 true yes on)

  if shares != [] or lan_opt_in? do
    config :barkpark, BarkparkWeb.Endpoint, http: [ip: {0, 0, 0, 0}]
  end

  # P7: the public host SHARE LINKS advertise (Barkpark.Sharing.share_link_base/0
  # prefers it). Set to a tunnel domain (e.g. https://abc.trycloudflare.com) to
  # share OUTSIDE the LAN with the firewall untouched. Unset → LAN IP / Endpoint
  # url. Pair with the public-share guard so the tunnel host exposes ONLY the
  # read/share surfaces (see docs).
  config :barkpark, :share_host, System.get_env("BARKPARK_SHARE_HOST")
end

# Media blob root override (Personal-Development-Server W1, G1/G2). The blob root
# defaults to api/uploads (config/config.exs); BARKPARK_MEDIA_DIR relocates it at
# runtime so the Personal-Local twin can point it at a portable data dir where
# pulled cloud blobs land beside its Postgres data. `Barkpark.Media.upload_dir/0`
# reads this key at CALL time, so a `barkpark reload` picks it up. Unset ⇒ the
# compiled default, byte-identical to before. Applies in ALL envs (personal-local
# boots :prod), so it lives OUTSIDE the prod guard — same idiom as the media
# webhook/CDN blocks below.
# Indx durable state (`Barkpark.Plugins.Indx.Persistence`, the per-index
# key_maps). The compiled default is `priv/indx_state` — under an OTP release a
# per-version copy that a version bump abandons, under `mix phx.server` a symlink
# into the source tree — and NOTHING set the documented `:dir` override, so prod
# ran on the dev/test default (task-527b519e47669559). BARKPARK_INDX_STATE_DIR
# points it OUTSIDE the build. Unset in :prod ⇒ /var/lib/barkpark/indx-state
# WHEN that parent exists (deploy/instance-deploy.sh creates it), so a
# personal-local :prod boot without the directory keeps the compiled default
# instead of logging :eacces on every save. dev/test: unchanged unless set.
# Applies in ALL envs, same idiom as BARKPARK_MEDIA_DIR below.
indx_state_dir =
  case System.get_env("BARKPARK_INDX_STATE_DIR") do
    dir when is_binary(dir) and dir != "" ->
      Path.expand(dir)

    _ ->
      if config_env() == :prod and File.dir?("/var/lib/barkpark"),
        do: "/var/lib/barkpark/indx-state",
        else: nil
  end

if indx_state_dir do
  config :barkpark, Barkpark.Plugins.Indx.Persistence, dir: indx_state_dir
end

case System.get_env("BARKPARK_MEDIA_DIR") do
  dir when is_binary(dir) and dir != "" ->
    config :barkpark, :media_upload_dir, Path.expand(dir)

  _ ->
    :ok
end

# Media blob STORAGE BACKEND (see `Barkpark.Media.Blobstore`). Unset ⇒ :local,
# byte-identical to before — originals under the media blob root above.
# BARKPARK_MEDIA_STORAGE=s3 moves originals to any S3-compatible bucket
# (Cloudflare R2, AWS S3, MinIO, Backblaze B2, …); local disk becomes a
# regenerable write-through cache (renditions + probe/rendition source blobs),
# so the bucket is the source of truth and the disk can be lost without data
# loss. The five required keys FAIL LOUDLY at boot when the backend is
# selected — a half-configured bucket must not silently fall back to local
# and split the blob set across two stores. Applies in ALL envs (same idiom
# as BARKPARK_MEDIA_DIR above).
case System.get_env("BARKPARK_MEDIA_STORAGE") do
  "s3" ->
    require_s3 = fn name ->
      case System.get_env(name) do
        value when is_binary(value) and value != "" ->
          value

        _ ->
          raise """
          BARKPARK_MEDIA_STORAGE=s3 is set but #{name} is missing.

          The s3 media backend requires:
              BARKPARK_S3_ENDPOINT           e.g. https://<account>.r2.cloudflarestorage.com
              BARKPARK_S3_BUCKET             the bucket name
              BARKPARK_S3_ACCESS_KEY_ID
              BARKPARK_S3_SECRET_ACCESS_KEY
          Optional:
              BARKPARK_S3_REGION             default "auto" (R2); AWS needs a real region
              BARKPARK_S3_KEY_PREFIX         namespace inside the bucket, default ""
              BARKPARK_S3_PRESIGN_TTL        presigned-URL lifetime in seconds, default 3600
              BARKPARK_S3_PUBLIC_BASE_URL    public/CDN origin for unsigned delivery
          """
      end
    end

    config :barkpark, :media_storage,
      backend: :s3,
      s3: [
        endpoint: require_s3.("BARKPARK_S3_ENDPOINT"),
        bucket: require_s3.("BARKPARK_S3_BUCKET"),
        region: System.get_env("BARKPARK_S3_REGION") || "auto",
        access_key_id: require_s3.("BARKPARK_S3_ACCESS_KEY_ID"),
        secret_access_key: require_s3.("BARKPARK_S3_SECRET_ACCESS_KEY"),
        key_prefix: System.get_env("BARKPARK_S3_KEY_PREFIX") || "",
        presign_ttl: String.to_integer(System.get_env("BARKPARK_S3_PRESIGN_TTL") || "3600"),
        public_base_url: System.get_env("BARKPARK_S3_PUBLIC_BASE_URL")
      ]

  _ ->
    :ok
end

# Workspace-bundle export SPILL root (pds W11). The streamed export writes one
# per-table spill file plus the assembled tar here; peak transient disk is
# `tar-so-far + the largest single table`. Relocate it when the default lives
# on a small or memory-backed volume — `Archive.spill_dir/0` REFUSES to run on
# tmpfs/ramfs rather than silently paying the RSS peak the spill removes.
# Unset ⇒ the compiled default (api/tmp/bundle-spill). Applies in ALL envs.
case System.get_env("BARKPARK_BUNDLE_SPILL_DIR") do
  dir when is_binary(dir) and dir != "" ->
    config :barkpark, :bundle_spill_dir, Path.expand(dir)

  _ ->
    :ok
end

# Workspace-bundle IMPORT switch (pds W1, G3). Fail-closed: OFF unless
# BARKPARK_ALLOW_BUNDLE_IMPORT is truthy. `bin/barkpark up` writes =1 into the
# personal-local .env (the free local twin is the intended pull TARGET); a prod
# box that never sets the env keeps import denied. Applies in all envs. The
# import path (pds-w1-merge-import) reads this key with a false default; this is
# the runtime override that flips it on.
if System.get_env("BARKPARK_ALLOW_BUNDLE_IMPORT") in ~w(1 true yes on) do
  config :barkpark, :allow_bundle_import, true
end

# INSTANCE-OPERATOR allowlist (task-c7e2b87f1bbca815), mirroring cloud's
# PLATFORM_ADMIN_EMAILS shape (cloud/config/runtime.exs). Comma-separated, in
# ALL envs. BOTH unset/blank => the lists stay [] => UNSET => legacy behaviour
# (the `admin` bit alone still opens the seven instance-global route groups) plus
# a startup warning from BarkparkWeb.Plugs.RequirePlatformOperator.warn_if_unset/0.
# EITHER non-empty => the tier is ARMED and the seven groups are allowlist-only,
# fail closed. Emails are matched against the BEARER'S OWNER (a PAT's
# owner_user_id -> user.email, or an app token's "app:<email>" label); ids are
# `api_tokens.id` values, the direct handle for a machine token with no human
# behind it. Blank entries are dropped, so "a@b.io,," is one operator, not three.
for {env_name, config_key} <- [
      {"BARKPARK_OPERATOR_EMAILS", :operator_emails},
      {"BARKPARK_OPERATOR_TOKEN_IDS", :operator_token_ids}
    ] do
  entries =
    System.get_env(env_name, "")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  if entries != [] do
    config :barkpark, config_key, entries
  end
end

media_signing_secret =
  case System.get_env("MEDIA_SIGNING_SECRET") do
    val when is_binary(val) and val != "" ->
      val

    _ ->
      if config_env() == :prod do
        # Derives from the hoisted, already-validated SECRET_KEY_BASE binding
        # at the top of this file (>= 64 raw bytes or the boot refused).
        Base.encode64(
          :crypto.hash(:sha256, "barkpark-media:" <> secret_key_base),
          padding: false
        )
      end
  end

if is_binary(media_signing_secret) and media_signing_secret != "" do
  config :barkpark, :media_signing_secret, media_signing_secret
end

media_cdn_base =
  case System.get_env("MEDIA_CDN_BASE_URL") do
    val when is_binary(val) and val != "" -> val
    _ -> nil
  end

media_cdn_invalidation =
  case System.get_env("MEDIA_CDN_INVALIDATION_URL") do
    url when is_binary(url) and url != "" ->
      [
        adapter: :http,
        url: url,
        secret: System.get_env("MEDIA_CDN_INVALIDATION_SECRET") || ""
      ]

    _ ->
      [adapter: :noop]
  end

if media_cdn_base do
  config :barkpark, :media_cdn,
    base_url: media_cdn_base,
    invalidation: media_cdn_invalidation
end

media_callback_token =
  case System.get_env("MEDIA_PROCESSING_CALLBACK_TOKEN") do
    val when is_binary(val) and val != "" -> val
    _ -> nil
  end

if media_callback_token do
  config :barkpark, :media_processing_callback_token, media_callback_token
end

media_webhook_url = System.get_env("MEDIA_WEBHOOK_URL")
media_webhook_secret = System.get_env("MEDIA_WEBHOOK_SECRET")

if is_binary(media_webhook_url) and media_webhook_url != "" do
  events =
    case System.get_env("MEDIA_WEBHOOK_EVENTS") do
      nil -> ["media.uploaded", "media.processed", "media.deleted"]
      "" -> ["media.uploaded", "media.processed", "media.deleted"]
      list -> String.split(list, ",", trim: true)
    end

  config :barkpark, :media_webhooks,
    endpoints: [
      %{url: media_webhook_url, secret: media_webhook_secret || "", events: events}
    ]
end

# Transactional mailer (verify-email / password-reset / already-registered — see
# Barkpark.Accounts.UserNotifier). config/config.exs defaults Barkpark.Mailer to
# Swoosh.Adapters.Local — an in-memory mailbox that NEVER delivers — and test.exs
# to Swoosh.Adapters.Test. So without this block a prod box returns HTTP 200 on
# register / request-reset but the email is written to memory and dropped.
#
# Setting SMTP_HOST (+ optional port/creds) flips the adapter to
# Swoosh.Adapters.SMTP via the already-present gen_smtp dep and actually sends.
# When SMTP_HOST is UNSET we configure NOTHING, leaving the compile-time adapter
# intact (Local in dev/prod, Test in test) — zero behaviour change until the relay
# env is provided, so envs that haven't configured a relay are unaffected.
#
# Env-driven only, no secrets in code. Shares the SMTP_* vocabulary with the cloud
# control plane (cloud/config/runtime.exs) so one EnvironmentFile can drive both
# apps behind the same postfix relay. The From identity is NOT set here — it is
# independent of the transport (see the MAIL_FROM_* block below) so an operator
# can set a sender without also declaring a relay.
case System.get_env("SMTP_HOST") do
  relay when is_binary(relay) and relay != "" ->
    smtp_username = System.get_env("SMTP_USERNAME")
    smtp_password = System.get_env("SMTP_PASSWORD")
    smtp_has_auth? = is_binary(smtp_username) and smtp_username != ""

    # VERIFY the relay's TLS cert by default: gen_smtp does NOT verify unless
    # tls_options carries verify: :verify_peer + a trust store + a raised depth,
    # so without this an active MITM could terminate STARTTLS and capture the SMTP
    # credentials. SMTP_VERIFY_PEER=false opts out for the self-hosted postfix
    # sidecar reached over a trusted internal hop; a public third-party relay MUST
    # keep verification on (the default). Mirrors cloud/config/runtime.exs.
    smtp_verify_peer? = System.get_env("SMTP_VERIFY_PEER", "true") != "false"

    smtp_tls_opts =
      if smtp_verify_peer? do
        [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          depth: 9,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ],
          server_name_indication: String.to_charlist(relay)
        ]
      else
        [verify: :verify_none]
      end

    smtp_base_opts = [
      adapter: Swoosh.Adapters.SMTP,
      relay: relay,
      port: String.to_integer(System.get_env("SMTP_PORT") || "587"),
      ssl: false,
      # Opportunistic STARTTLS — upgrade when the relay advertises it; tls_options
      # above pin verification. :if_available (not :always) keeps a plaintext
      # local-relay hop working when no creds/TLS are configured.
      tls: :if_available,
      tls_options: smtp_tls_opts,
      auth: if(smtp_has_auth?, do: :always, else: :if_available),
      retries: 1
    ]

    smtp_creds_opts =
      if smtp_has_auth?,
        do: [username: smtp_username, password: smtp_password],
        else: []

    config :barkpark, Barkpark.Mailer, smtp_base_opts ++ smtp_creds_opts

  _ ->
    :ok
end

# The transactional From identity (gh-9531). Barkpark.Mailer.from/0 reads
# `config :barkpark, :mail` at CALL time; config.exs holds the historical
# no-reply@barkpark.cloud / "Barkpark" default. It used to be a compile-time
# `@from` module attribute inside each notifier, which a release BUILD freezes —
# so a self-hoster pointing SMTP_HOST at their own relay could not change the
# sender, and most relays reject (or the receiver DMARC-fails) a message whose
# From is not the authenticated sender. Delivery is fire-and-forget through
# Barkpark.TaskSupervisor, so those rejections were invisible: register /
# request-reset still returned 200 and the mail was simply never delivered.
#
# Shares the MAIL_FROM_* vocabulary with the cloud control plane
# (cloud/config/runtime.exs) so one EnvironmentFile drives both apps.
#
# Set only what is PRESENT in the environment: Config deep-merges keyword lists,
# so setting MAIL_FROM_ADDRESS alone leaves the default from_name intact, and
# setting NEITHER leaves config.exs untouched — zero behaviour change for every
# existing deployment. A present-but-malformed value is NOT silently discarded:
# Barkpark.Mailer.from/0 raises on it, and Barkpark.Application.start/2 calls
# from/0 at boot so the node REFUSES rather than emitting a wrong sender.
mail_from_overrides =
  [
    {:from_address, System.get_env("MAIL_FROM_ADDRESS")},
    {:from_name, System.get_env("MAIL_FROM_NAME")}
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

if mail_from_overrides != [] do
  config :barkpark, :mail, mail_from_overrides
end

# gh-9531 residual (task-eeabfd9bf3ed8371) — two more DEPLOYMENT values this app
# used to freeze at BUILD time in module attributes:
#
#   * ANTHROPIC_API_URL — the Anthropic-compatible Messages endpoint shared by
#     `Barkpark.Tasks.Judge` and `Barkpark.StudioChat.Titles`. Both modules
#     already config-read their adapter, model and key; only the URL was frozen,
#     so an operator routing through a gateway (LiteLLM, an internal proxy, a
#     Bedrock-style shim) could supply the key and the model and still not reach
#     their own endpoint. One key for both, exactly as `:anthropic_api_key` is
#     already shared.
#   * ONIX_DATASET_HOST — the `host:` half of every ONIX `<RecordReference>`
#     (`Barkpark.Plugins.OnixEdit.Export.dataset_host/0`). No call site passes
#     the `:dataset_host` opt, so a self-hoster exporting to Bokbasen published
#     their own catalogue under OUR namespace — wrong DATA, not wrong config.
#     Changing it re-identifies every record a partner already holds, so set it
#     before the first submission.
#
# Set only what is PRESENT, so an unset environment keeps the historical
# literals and every existing deployment is unchanged. A present-but-malformed
# value is NOT silently discarded: each reader raises, and
# `Barkpark.Application.start/2` resolves all three at boot, so the node REFUSES
# rather than quietly talking to the vendor (or stamping our domain onto someone
# else's books).
if anthropic_api_url = System.get_env("ANTHROPIC_API_URL") do
  config :barkpark, :anthropic_api_url, anthropic_api_url
end

if onix_dataset_host = System.get_env("ONIX_DATASET_HOST") do
  config :barkpark, Barkpark.Plugins.OnixEdit, dataset_host: onix_dataset_host
end

# Trust boundary for x-forwarded-for on every IP-keyed rate bucket
# (Barkpark.RateLimiter.client_ip/1). NOT prod-gated: which fronts sit in front
# of this box is a property of the DEPLOYMENT, not of MIX_ENV, and a self-hoster
# running MIX_ENV=dev behind a relay needs the same knob.
#
# Unset keeps the config.exs default (empty — loopback is trusted
# unconditionally and is never listed here), so a plain self-host needs nothing.
# Set it to the Barkpark Cloud control plane's egress address to let its relayed
# caller IP be believed on the revoke DELETE; unlisted, that relay is
# disbelieved and the whole team shares one bucket keyed on the egress IP.
#
# INDIVIDUAL ADDRESSES ONLY (mirrors cloud/config/runtime.exs TRUSTED_PROXY_PEERS
# and its charter D5 reasoning). A CIDR range re-opens the forgery hole: an
# attacker inside the range has its real appended hop SKIPPED and its forged
# left-hand hop believed. A malformed entry raises at boot rather than silently
# degrading the boundary to a no-op.
if proxies = System.get_env("BARKPARK_TRUSTED_PROXIES") do
  config :barkpark,
         :trusted_proxies,
         proxies
         |> String.split(",")
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == ""))
         |> Enum.map(fn proxy ->
           case :inet.parse_address(String.to_charlist(proxy)) do
             {:ok, address} ->
               address

             {:error, _} ->
               raise """
               BARKPARK_TRUSTED_PROXIES contains #{inspect(proxy)}, which is not a valid IP address.
               Expected a comma-separated list of individual addresses, e.g. "203.0.113.7".
               CIDR ranges are NOT supported: trusting a whole range lets any host in it forge
               every client's rate-limit bucket key via X-Forwarded-For.
               """
           end
         end)
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # Optional Unix-socket Postgres (Barkpark Cloud P4 / Move B): set
  # `DATABASE_SOCKET_DIR=/var/run/postgresql` to talk to a same-box Postgres
  # over a local socket instead of TCP loopback. Shaves a small but real
  # fixed cost off every query — on hosted boxes where Barkpark sits next to
  # its own Postgres, this is the production-recommended path. When unset,
  # the `:url` hostname stays authoritative.
  socket_dir = System.get_env("DATABASE_SOCKET_DIR")

  # NOTE ON queue_target/queue_interval PARITY WITH api/config/test.exs: that file
  # widens 50ms/1000ms -> 5_000ms/30_000ms under a comment naming this exact error
  # ("connection not available and request was dropped from queue"). Do NOT copy
  # those values here. They fix a DIFFERENT cause: test.exs's contention is a
  # healthy pool of `schedulers_online()*2` (~8) transiently outrun by the async
  # suite's own fan-out, where nothing is actually starved for long and no user is
  # waiting. Guerrilla prod's failures (root-caused live: tooling/grip/ledger/
  # dr-w5-500-class-distinct-requests-2026-08-06.md, birth-fence-500-root-cause-
  # 2026-07-31.md) are a STRUCTURALLY oversubscribed pool: 29 declared Oban queue
  # slots share this same POOL_SIZE (default 10) with all HTTP traffic on a 2-vCPU
  # box already deep in swap, and individual jobs (EdgeProjector, SSR site builds)
  # have been observed holding a connection 12-38s — well past even a 5s target and
  # past the unconfigured-here Ecto :timeout default (15_000ms). Widening the queue
  # window would not rescue those requests (they still die at :timeout) and would
  # make genuinely-overloaded HTTP requests wait longer before failing, which is
  # worse for callers and adds to swap pressure — it delays and hides the failure
  # rather than fixing it. The charter says so explicitly: "nothing here licenses
  # raising POOL_SIZE on a 2-core box already 1.1 GB into swap" (bp-deploy-
  # reliability-charter.md D75) and "raising POOL_SIZE just moves contention into
  # Postgres — sizing waits for guerrilla-db-probe evidence" (bp-jarl-platform-
  # followups-charter.md D11). The actual fix is tracked and gated on measurement:
  # `jpf-bl-guerrilla-db-probe-arm` (read POOL_SIZE/max_connections/pg_stat_activity
  # live) unblocks `jpf-bl-oban-pool-partition` (partition or cap Oban's pool share,
  # then size POOL_SIZE on the numbers — NOT on feel). Both are open and unclaimed
  # as of 2026-08-19; see also `mob-lm-guerrilla-pool-storm`.
  # ── statement_timeout: the SERVER-SIDE bound on ONE statement ──────────────
  #
  # MEASURED on guerrilla 2026-09-01T21:43-21:46Z (task-e2f5ecca0be9a6d1):
  # `statement_timeout` was 0, and SIX `postgres: barkpark barkpark_prod SELECT`
  # backends sat at 4-7 MINUTES elapsed each, 10-14% CPU apiece, on a 2-vCPU
  # box. Nothing stopped them. Every later request's token lookup queued behind
  # them and the AUTH PLUGS raised first: 618 "connection not available and
  # request was dropped from queue" in one hour, from auth.ex verify_token
  # (218), optional_token.ex (186), assign_default_scope.ex (130). 532 `Sent
  # 500` that hour, 0 in each of the four hours before the campaign started.
  #
  # WHY ECTO'S :timeout IS NOT THIS. Ecto's `:timeout` (default 15_000 ms, still
  # unset in `repo_opts` below) is a CLIENT-side deadline: DBConnection stops
  # waiting and raises, but the Postgres BACKEND KEEPS RUNNING — it goes on
  # burning one of the two CPUs and holding its snapshot until it finishes on
  # its own. `statement_timeout` is enforced INSIDE Postgres: it CANCELS the
  # backend, which is the only thing that actually gives the resource back. The
  # two are complementary; the incident is what the missing server-side half
  # looks like.
  #
  # WHY 30s. Well above every healthy measured path on this data (the ready
  # queue's worst measured plan is 13.7 s pre-index and 0.32 s post-index) and
  # far below the 4-7 minutes that produced the incident. On a request-path pool
  # a statement past 30 s is not "slow", it is a defect, and failing it loudly
  # beats holding a pool member hostage. Postgrex sends `:parameters` as
  # STARTUP parameters, so every connection in the pool carries it — HTTP and
  # all 29 Oban queue slots alike. The orchestrator's live stopgap on 2026-09-01
  # (`ALTER ROLE barkpark SET statement_timeout = '60s'`, applied by hand on the
  # box) is superseded by this: same mechanism, in code, at a number chosen from
  # the measurements rather than picked to be safe.
  #
  # THE OPT-OUT for a legitimately-long SINGLE statement is
  # `Barkpark.Repo.set_local_statement_timeout!/1` / `with_statement_timeout/2`
  # (SET LOCAL — dies with its transaction, never leaks back into the pool).
  # The inventory of what needs it lives in that module's @moduledoc.
  #
  # NOT IN config/test.exs (the SQL sandbox owns the connection and every test
  # would inherit a wall it did not ask for) and NOT in config/dev.exs: a local
  # `mix ecto.migrate` running a backfill or a `CREATE INDEX CONCURRENTLY` past
  # 30 s would be CANCELLED, which is a worse first experience than the pool
  # contention dev does not have. Prod's migrations carry their own opt-out —
  # see `Barkpark.Repo`'s @moduledoc and `Barkpark.Release.migrate/0`.
  #
  # BARKPARK_DB_STATEMENT_TIMEOUT overrides the value; "0" disables it outright
  # (the incident escape hatch, so an operator can lift the wall without a
  # deploy). A malformed value REFUSES BOOT rather than silently degrading the
  # bound to nothing, matching how BARKPARK_TRUSTED_PROXIES is treated above.
  statement_timeout =
    case System.get_env("BARKPARK_DB_STATEMENT_TIMEOUT") do
      nil ->
        "30s"

      raw ->
        value = String.trim(raw)

        if Regex.match?(~r/^\d+(us|ms|s|min|h|d)?$/, value) do
          value
        else
          raise """
          BARKPARK_DB_STATEMENT_TIMEOUT is #{inspect(raw)}, which Postgres cannot parse.
          Expected a bare integer, which Postgres reads as MILLISECONDS (e.g. "30000"),
          or an integer with a unit: us | ms | s | min | h | d (e.g. "30s").
          "0" disables the statement timeout entirely.
          Unset, the default is "30s" — see the comment above this raise for why.
          """
        end
    end

  repo_opts = [
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # The server-side wall (see the block above `statement_timeout =`).
    parameters: [statement_timeout: statement_timeout],
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6
  ]

  repo_opts =
    if socket_dir && socket_dir != "" do
      Keyword.put(repo_opts, :socket_dir, socket_dir)
    else
      repo_opts
    end

  config :barkpark, Barkpark.Repo, repo_opts

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # It is read and validated ONCE at the top of this file (>= 64 raw bytes or
  # boot refusal); the endpoint config below consumes that hoisted binding.

  host =
    case System.get_env("PHX_HOST") do
      nil ->
        raise """
        environment variable PHX_HOST is missing.

        PHX_HOST must be the public DNS hostname (e.g., api.barkpark.cloud),
        not an IP. Phoenix's Endpoint.check_origin whitelists exactly one
        host+scheme pair; a mismatch returns 403 on /live/websocket and
        silently breaks LiveView (Studio becomes click-dead).

        See docs/ops/studio-nav-bug-2026-04-19.md (task #11) for the incident
        and `make domain-cutover DOMAIN=...` for the remediation workflow.
        """

      "" ->
        raise """
        environment variable PHX_HOST is empty.
        Set PHX_HOST to the public DNS hostname. See
        docs/ops/studio-nav-bug-2026-04-19.md (task #11).
        """

      value ->
        value
    end

  scheme = System.get_env("PHX_SCHEME", "http")

  if scheme == "https" and Regex.match?(~r/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/, host) do
    raise """
    PHX_HOST is a literal IPv4 address (#{host}) but PHX_SCHEME=https.

    Phoenix Endpoint.check_origin will whitelist https://#{host}, but browsers
    reaching the site via a DNS name will send a different Origin header and
    receive 403 on /live/websocket — LiveView (Studio) will silently fail.

    Fix: set PHX_HOST to the DNS hostname served by your TLS terminator
    (Caddy, nginx, Cloudflare, etc.). If you truly need IP-only access, set
    PHX_SCHEME=http and terminate TLS elsewhere.

    See docs/ops/studio-nav-bug-2026-04-19.md (task #11).
    """
  end

  # LOW-15: mark the user-session cookie Secure when served over HTTPS, so it is
  # never echoed over plaintext HTTP. Driven by PHX_SCHEME — NOT force_ssl
  # (Golden Rule #5: force_ssl 301-loops on the prod-HTTP box). When the box is
  # genuinely HTTP-only (PHX_SCHEME=http) this stays false and the cookie is sent
  # as today; the moment TLS is fronted (PHX_SCHEME=https) it tightens.
  config :barkpark, :session_secure, scheme == "https"
  config :barkpark, :capabilities_base_url, "#{scheme}://#{host}"

  config :barkpark, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Phoenix Endpoint.check_origin allowlist. Without an explicit list it
  # whitelists only "#{scheme}://#{host}", which silently blocks the Vercel
  # apex demo and preview URLs (LiveView /live/websocket → 403).
  # cross-link: docs/ops/studio-nav-bug-2026-04-19.md (these origins are load-bearing for Vercel apex)
  # BARKPARK_EXTRA_ORIGINS: CSV of additional allowed origins, per-box. The
  # demo server sets http://<ip> here — operators reach Studio by IP out of
  # habit and a silent websocket 403 click-kills the panes (the journal shows
  # the rejects). Explicit env beats silently widening the default list.
  extra_origins =
    (System.get_env("BARKPARK_EXTRA_ORIGINS") || "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)

  check_origin =
    [
      "#{scheme}://#{host}",
      "https://barkpark.cloud",
      "https://www.barkpark.cloud",
      "https://*.vercel.app"
    ] ++ extra_origins

  # WebAuthn / passkeys: the relying-party id is the public host, and the
  # expected client origin is scheme://host. Derived from PHX_HOST so passkeys
  # bind to the real deployment domain (a passkey registered for one rp_id will
  # not assert against another — this MUST match the browser's origin).
  config :barkpark, :webauthn,
    rp_id: host,
    origin: "#{scheme}://#{host}"

  # PUBLIC url port ≠ internal listen port (PORT). Every prod box fronts the
  # app with a proxy on the scheme-standard port (Caddy 443/80; blue/green
  # listens on 4000/4001) — baking PORT into `url:` made Endpoint.url()
  # "https://host:4000", which broke every absolute-URL consumer: emailed
  # reset/confirm links and the /login cloud deep link (login-brand-ux).
  # PHX_PORT overrides for the rare box whose public port IS nonstandard.
  url_port =
    case System.get_env("PHX_PORT") do
      p when is_binary(p) and p != "" -> String.to_integer(p)
      _ -> if scheme == "https", do: 443, else: 80
    end

  config :barkpark, BarkparkWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme],
    check_origin: check_origin,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # Non-empty is the only requirement — no byte floor: the JWT HMAC accepts
  # any key length, and inventing a floor here would refuse working deployments.
  preview_secret =
    case System.get_env("PREVIEW_JWT_SECRET") do
      val when is_binary(val) and val != "" ->
        val

      _ ->
        raise """
        PREVIEW_JWT_SECRET must be set to a non-empty value.

        Generate one: openssl rand -base64 48 — and set PREVIEW_JWT_SECRET in
        .env (compose) or /opt/barkpark/.env.
        """
    end

  config :barkpark, :preview,
    secret: preview_secret,
    ttl_seconds: String.to_integer(System.get_env("PREVIEW_JWT_TTL_SECONDS") || "600"),
    issuer: "barkpark"

  base_rate_limits = Application.get_env(:barkpark, :rate_limits, [])

  rate_limits =
    base_rate_limits
    |> Keyword.put(
      :read_per_minute,
      String.to_integer(
        System.get_env("BARKPARK_RATE_LIMIT_READ") ||
          Integer.to_string(Keyword.get(base_rate_limits, :read_per_minute, 300))
      )
    )
    |> Keyword.put(
      :write_per_minute,
      String.to_integer(
        System.get_env("BARKPARK_RATE_LIMIT_WRITE") ||
          Integer.to_string(Keyword.get(base_rate_limits, :write_per_minute, 60))
      )
    )

  config :barkpark, :rate_limits, rate_limits

  # Ticket-key abuse rails (BarkparkWeb.Plugs.TicketRateLimit) — per-hour
  # budgets per key + write class, operator-tunable without a rebuild, same
  # pattern as BARKPARK_RATE_LIMIT_READ/_WRITE above.
  base_ticket_limits = Application.get_env(:barkpark, :ticket_rate_limits, [])

  ticket_rate_limits =
    Enum.reduce(
      [
        create: "BARKPARK_TICKET_RATE_CREATE",
        message: "BARKPARK_TICKET_RATE_MESSAGE",
        attachment: "BARKPARK_TICKET_RATE_ATTACHMENT"
      ],
      base_ticket_limits,
      fn {class, env_var}, acc ->
        case System.get_env(env_var) do
          nil -> acc
          raw -> Keyword.put(acc, class, String.to_integer(raw))
        end
      end
    )

  config :barkpark, :ticket_rate_limits, ticket_rate_limits

  # Anonymous auth-write rails (BarkparkWeb.Plugs.AuthWriteRateLimit) — per-hour
  # per-IP register budget, operator-tunable without a rebuild, same pattern as
  # BARKPARK_TICKET_RATE_* above.
  base_auth_write_limits = Application.get_env(:barkpark, :auth_write_rate_limits, [])

  auth_write_rate_limits =
    case System.get_env("BARKPARK_AUTH_RATE_REGISTER") do
      nil -> base_auth_write_limits
      raw -> Keyword.put(base_auth_write_limits, :register, String.to_integer(raw))
    end

  config :barkpark, :auth_write_rate_limits, auth_write_rate_limits

  if origins = System.get_env("DEFAULT_CORS_ORIGINS") do
    parsed = origins |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    config :barkpark, :default_cors_origins, parsed
  end

  # Paper-ingest shared secret. When unset, the ingest endpoint rejects every
  # request (RequireIngestToken treats nil as "no token configured" → 401), so
  # the seam is closed by default in prod. PAPERFLOW_INGEST_TOKEN is honored as
  # a legacy fallback so existing prod .env / external producers keep working.
  if ingest_token =
       System.get_env("BARKPARK_INGEST_TOKEN") || System.get_env("PAPERFLOW_INGEST_TOKEN") do
    config :barkpark, :ingest_token, ingest_token
  end

  # Instance self-update checker (Barkpark.SelfUpdate). ON by default in prod
  # — opt out with BARKPARK_SELF_UPDATE_CHECK=off. The BARKPARK_UPSTREAM_*
  # vars override the config.exs upstream defaults; nil/empty values are
  # dropped so the defaults survive. Channel is an explicit whitelist
  # ("tags" | "branch") — never String.to_atom on raw env input.
  self_update_channel =
    case System.get_env("BARKPARK_UPSTREAM_CHANNEL") do
      "tags" -> :tags
      "branch" -> :branch
      _ -> nil
    end

  self_update_env =
    [
      enabled: System.get_env("BARKPARK_SELF_UPDATE_CHECK", "on") != "off",
      repo: System.get_env("BARKPARK_UPSTREAM_REPO"),
      branch: System.get_env("BARKPARK_UPSTREAM_BRANCH"),
      channel: self_update_channel
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

  config :barkpark, Barkpark.SelfUpdate, self_update_env

  # Instance self-update EXECUTOR (Barkpark.SelfUpdate.Runner). Fail-closed:
  # OFF unless BARKPARK_SELF_UPDATE_APPLY=1 explicitly opts the box in to
  # running scripts/self-update.sh from the admin trigger endpoint.
  # BARKPARK_SELF_UPDATE_CD overrides the working directory (default: the
  # repo root, resolved from the BEAM's cwd — see the Runner moduledoc).
  self_update_runner_env =
    [
      enabled: System.get_env("BARKPARK_SELF_UPDATE_APPLY") == "1",
      cd: System.get_env("BARKPARK_SELF_UPDATE_CD")
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

  config :barkpark, Barkpark.SelfUpdate.Runner, self_update_runner_env

  # Site-deploy EXECUTOR (Barkpark.Sites.DeployRunner). Fail-closed, and gated
  # SEPARATELY from self-update: a box may accept instance self-updates without
  # accepting site builds (npm runs third-party postinstall code) and vice
  # versa. BARKPARK_SITE_DEPLOY_APPLY=1 is the only way to turn it on.
  # BARKPARK_SITE_DEPLOY_CD overrides the working directory (default: the repo
  # root, resolved from the BEAM's cwd — see the DeployRunner moduledoc).
  site_deploy_runner_env =
    [
      enabled: System.get_env("BARKPARK_SITE_DEPLOY_APPLY") == "1",
      cd: System.get_env("BARKPARK_SITE_DEPLOY_CD")
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

  config :barkpark, Barkpark.Sites.DeployRunner, site_deploy_runner_env

  # Site SOURCE PROVISIONER (Barkpark.Sites.Provisioner) — materializes a shipped
  # starter template into `<sites_dir>/<slug>/src` before BUILD (charter D33/D34,
  # search-template D7). BARKPARK_SITES_DIR MUST match what site-deploy.sh
  # resolves (same default `/opt/barkpark/sites`) or the template lands where the
  # engine won't look. Each shipped starter has its OWN template-dir env override
  # (default: the repo's `templates/<slug>`): BARKPARK_SITE_TEMPLATE_DIR
  # (astro-starter), BARKPARK_NODE_TEMPLATE_DIR (next-starter),
  # BARKPARK_SEARCH_TEMPLATE_DIR (search-starter),
  # BARKPARK_ASTRO_SEARCH_TEMPLATE_DIR (astro-search-starter). All unset ⇒ the
  # module's defaults. New starters insert their override directly below the
  # sites_dir line (scaffy add-site-template).
  site_provisioner_env =
    [
      sites_dir: System.get_env("BARKPARK_SITES_DIR"),
      template_dir: System.get_env("BARKPARK_SITE_TEMPLATE_DIR"),
      node_template_dir: System.get_env("BARKPARK_NODE_TEMPLATE_DIR"),
      search_template_dir: System.get_env("BARKPARK_SEARCH_TEMPLATE_DIR"),
      astro_search_template_dir: System.get_env("BARKPARK_ASTRO_SEARCH_TEMPLATE_DIR")
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

  config :barkpark, Barkpark.Sites.Provisioner, site_provisioner_env

  # ## SSL Support — TLS terminates UPSTREAM, not in Phoenix
  #
  # Barkpark does not hold a certificate. A reverse proxy (Caddy in prod, the
  # platform edge on the Cloud hosts) terminates TLS and forwards plain HTTP to
  # the app, so the endpoint has no `https:` listener and MUST NOT try to force
  # one. HTTPS-awareness in this file is driven by PHX_SCHEME — see the
  # `:session_secure` / `:capabilities_base_url` block earlier — and HSTS is
  # emitted by the proxy (docs/ops/adding-a-domain.md), never by Plug.SSL.
  #
  # ### Do NOT set `force_ssl` (CLAUDE.md Golden Rule #5 / Past Mistake #5)
  #
  # Stock Phoenix boilerplate recommends enabling `force_ssl` with `hsts` in
  # config/prod.exs. That recommendation is wrong for this deployment and it
  # already caused a real outage. Behind a terminating proxy Phoenix only ever
  # sees `http` on the wire, so `force_ssl` 301-redirects the request to https,
  # the proxy re-forwards it as http, and it redirects again — an infinite loop
  # in which every API call returned empty. Turning on `hsts` without a
  # `rewrite_on` is the worst form of it: the loop is guaranteed, and the HSTS
  # header pins browsers to https for a year while the loop is live. That form
  # is deliberately absent from api/config/prod.exs, and a test enforces it —
  # test/barkpark/config_force_ssl_guard_test.exs fails if it reappears in
  # config/**, comment included, because a comment is what taught it here.
  #
  # If TLS ever terminates at the app tier, the only safe form is the one
  # api/config/prod.exs already carries commented out — it trusts the proxy's
  # X-Forwarded-Proto so a proxied request is not mistaken for plaintext:
  #
  #     config :barkpark, BarkparkWeb.Endpoint,
  #       force_ssl: [rewrite_on: [:x_forwarded_proto]]
  #
  # ### If the app tier ever does terminate TLS
  #
  # Add the `https` key to the endpoint config (port 443, `cipher_suite:
  # :strong` for modern clients only or `:compatible` for wider support, plus
  # `keyfile`/`certfile` as absolute paths or paths relative to priv). Options:
  # https://hexdocs.pm/plug/Plug.SSL.html#configure/1 — and only then revisit
  # the `rewrite_on` form above.
end

# Ephemeral dev database override (CREATE-quickstart smoke, agent-onramps D24).
# `config/dev.exs` hardcodes the dev Repo to `barkpark_dev`; DATABASE_URL is only
# honored under :prod (above). The CREATE-quickstart smoke boots a THROWAWAY
# clean-profile server to prove the fresh-user AUTH+CREATE arc and drops its DB on
# exit — it must NEVER reuse (and drop) a developer's real `barkpark_dev`. When
# `BARKPARK_DEV_DATABASE` is set, point the dev Repo at that ephemeral database;
# unset (the default for every normal `mix phx.server` / `mix test`) leaves
# `barkpark_dev` untouched. Additive and dev-scoped: no other env is affected.
if config_env() == :dev do
  case System.get_env("BARKPARK_DEV_DATABASE") do
    db when is_binary(db) and db != "" ->
      config :barkpark, Barkpark.Repo, database: db

    _ ->
      :ok
  end
end

# MUTATE-PATH SCHEMA VALIDATION — the per-dataset ENFORCE opt-in
# (task-41a740fd6701ec28). See `Barkpark.Content.Validation`'s moduledoc for the
# ruling and the migration story. Unset (the default everywhere) leaves the
# compile-time `enforce_datasets: []` in place, so EVERY dataset advises and no
# write is refused on schema grounds. Set to a comma-separated list of dataset
# slugs to opt those datasets into 422 refusal, or to "all" for every dataset.
#
#   BARKPARK_SCHEMA_ENFORCE_DATASETS=production,staging
#
# Runtime, not compile-time, and deliberately: an operator opts a dataset in
# (or backs it out again, if a clean-up run was optimistic) with a restart
# rather than a deploy.
case System.get_env("BARKPARK_SCHEMA_ENFORCE_DATASETS") do
  "all" ->
    config :barkpark, Barkpark.Content.Validation, enforce_datasets: :all

  value when is_binary(value) and value != "" ->
    slugs =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    config :barkpark, Barkpark.Content.Validation, enforce_datasets: slugs

  _ ->
    :ok
end
