defmodule Barkpark.Plugins.Github.Settings do
  @moduledoc """
  Typed credential resolver for the `github` mirror plugin — the DB-settings→
  config bridge that feeds the App-auth GenServer (`Github.Auth`) and gates the
  wave-2 drain worker.

  Modelled on `Barkpark.Plugins.OnixEdit.Bokbasen.Settings`. Resolves each
  credential per-field in this order:

    1. **Application env** — `config :barkpark, Barkpark.Plugins.Github, ...`,
       which `runtime.exs` populates from OS env vars at boot. This is the SAME
       config key `Github.Auth`/`Github.Client` already read directly, so the
       wave-1 auth/client tests (which `Application.put_env` that key) keep
       passing unchanged.
    2. **Encrypted `plugin_settings` row** keyed `"github"` (the row the admin
       Plugin Settings LiveView writes) via `Barkpark.Plugins.Settings` — no new
       migration, no new encryption code.

  Env wins per-field; a blank/absent env value falls back to the DB row;
  otherwise the field is left ABSENT (`nil`) — never fabricated.

  ## Public API

    * `get_credentials/0` — resolved creds map (`:repo, :app_id,
      :installation_id, :private_key, :webhook_secret, :project_id, :api_base`).
      Never raises on missing/blank settings; any unconfigured field is `nil`.
      (It DOES touch the DB for the fallback row, so a hard DB/Cloak failure
      still propagates — deliberately un-rescued so a bad `BARKPARK_CLOAK_KEY`
      surfaces loudly rather than silently darkening the bridge.)
    * `active?/0` — `true` only when ALL required creds (`repo`, `app_id`,
      `installation_id`, `private_key`, `webhook_secret` — reused from
      `Github.required_creds/0`) are present and non-blank. Fail-closed.
    * `repo/0` — the `owner/name` repo string, or `nil` if unset/blank.
    * `datasets/0` — the datasets whose tasks mirror to GitHub, from config
      `:github_mirror_datasets`, defaulting to `["production"]`.
    * `webhook_secret_cached/0` — the `webhook_secret` ONLY, memoized with a
      short monotonic TTL so the hot inbound-webhook signature plug stops
      forcing a DB read + audit row on every probe.
  """

  alias Barkpark.Plugins.Settings

  @app :barkpark
  @config_key Barkpark.Plugins.Github
  @plugin_name "github"

  # persistent_term slot for the memoized webhook secret. Stores
  # `{value :: String.t() | nil, deadline :: integer()}` in native monotonic
  # units; writes happen at most once per TTL so global-GC churn is negligible.
  @webhook_secret_cache_key {__MODULE__, :webhook_secret_cache}
  @webhook_secret_ttl_key :webhook_secret_ttl_ms
  @default_webhook_secret_ttl_ms 5_000

  # Every credential the resolver surfaces. `:project_id` (Projects v2, wave 5)
  # and `:api_base` (Bypass override) are optional; the required subset is
  # `Github.required_creds/0`.
  @cred_keys [
    :repo,
    :app_id,
    :installation_id,
    :private_key,
    :webhook_secret,
    :project_id,
    :api_base
  ]

  @datasets_key :github_mirror_datasets
  @default_datasets ["production"]

  # OS env var naming the workspace inbound intake tasks are born into. Absent/
  # blank → `nil` → the webhook falls back to today's default-workspace scope
  # (byte-identical behavior). See `intake_workspace_id/0` (charter D15).
  @intake_workspace_env "BARKPARK_GITHUB_INTAKE_WORKSPACE_ID"

  @typedoc "Resolved GitHub credentials. Any field may be `nil` if unconfigured."
  @type credentials :: %{
          repo: String.t() | nil,
          app_id: String.t() | nil,
          installation_id: String.t() | nil,
          private_key: String.t() | nil,
          webhook_secret: String.t() | nil,
          project_id: String.t() | nil,
          api_base: String.t() | nil
        }

  @doc "The plugin row name used in `plugin_settings`."
  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @doc """
  The required credential keys (atoms), reused from `Github.required_creds/0`
  so the settings-gate validator and this runtime resolver never drift.
  """
  @spec required_keys() :: [atom()]
  def required_keys do
    Enum.map(Barkpark.Plugins.Github.required_creds(), &String.to_existing_atom/1)
  end

  @doc """
  Resolved credentials map. Per-field: env wins, DB row falls back, otherwise
  `nil`. Never raises on missing/blank settings — callers gate on `active?/0`
  before any network call. (A hard DB/Cloak failure on the fallback read still
  propagates; see the moduledoc.)
  """
  @spec get_credentials() :: credentials()
  def get_credentials do
    env = env_config()
    db = load_db_settings()

    @cred_keys
    |> Enum.map(fn key -> {key, resolve(key, env, db)} end)
    |> Map.new()
  end

  @doc """
  `true` only when every required credential is present and non-blank —
  fail-closed. A half-provisioned App (say a key but no installation id) is
  worse than a dark one, so the gate refuses it.

  NOT free: each call resolves `get_credentials/0`, which reads the DB fallback
  row via `Settings.get/1` — and that logs a `"read"` audit row + telemetry per
  call. A caller that ticks `active?/0` in a tight loop MUST memoize the result
  (short TTL) rather than hammer the DB + audit table. `Github.DrainWorker` does
  exactly this: it caches the boolean for `active_ttl_ms` (~5 s) so a backoff/idle
  loop re-resolves at most once per window, not once per tick.
  """
  @spec active?() :: boolean()
  def active? do
    creds = get_credentials()
    Enum.all?(required_keys(), fn key -> not blank?(Map.get(creds, key)) end)
  end

  @doc "The `owner/name` repo string, or `nil` when unset/blank."
  @spec repo() :: String.t() | nil
  def repo do
    case get_credentials()[:repo] do
      v when is_binary(v) -> if blank?(v), do: nil, else: v
      _ -> nil
    end
  end

  @doc """
  The datasets whose tasks mirror to GitHub. Reads config
  `:github_mirror_datasets` (a list of dataset-name strings) off the plugin's
  env key, defaulting to `["production"]`. A malformed value (non-list, empty,
  or containing non-binaries) falls back to the default rather than mirroring
  nothing or crashing the drain worker.
  """
  @spec datasets() :: [String.t()]
  def datasets do
    case env_config()[@datasets_key] do
      list when is_list(list) and list != [] ->
        cleaned = for d <- list, is_binary(d) and not blank?(d), do: d
        if cleaned == [], do: @default_datasets, else: cleaned

      _ ->
        @default_datasets
    end
  end

  @doc """
  The workspace id inbound intake tasks are born into, from OS env
  `#{@intake_workspace_env}`. `nil` when the env var is unset or blank.

  Read ONCE per delivery by the webhook controller and threaded as `:workspace_id`
  into the intake/inbound ingest opts (charter D15). Optional by design — an
  absent value keeps today's default-workspace behavior byte-identical (the
  controller adds no `:workspace_id` key at all). A workspace id is a `binary_id`
  (UUID string), so the raw env value is used as-is.

  Read straight from the OS env (no DB, no audit row) so it is cheap on the hot
  webhook path — unlike the App credentials it is not a secret and needs no
  encrypted `plugin_settings` fallback.
  """
  @spec intake_workspace_id() :: String.t() | nil
  def intake_workspace_id, do: present(System.get_env(@intake_workspace_env))

  @doc """
  The `webhook_secret` ONLY, memoized with a short monotonic TTL.

  The inbound-webhook signature plug runs on every `POST
  /v1/plugins/github/webhook` — including unauthenticated probes carrying a
  bogus `x-hub-signature-256` header. Resolving the full `get_credentials/0`
  there forces a `plugin_settings` DB read (which logs a `"read"` audit row +
  telemetry) BEFORE the HMAC is even checked — a mild flood primitive. This
  reader caches just the one field so a burst of probes touches the DB at most
  once per TTL window.

  Backed by `:persistent_term` keyed `{#{inspect(__MODULE__)},
  :webhook_secret_cache}` holding `{value, deadline_native}`:

    * cache hit within TTL → return the value with ZERO DB touch;
    * miss/expiry → resolve `get_credentials()[:webhook_secret]`, store
      `{value, now + ttl}`, return it.

  `nil` is a valid cached value: a dark plugin (no secret) caches `nil` and the
  signature plug still fail-closes 401 — only the read cadence changes, never
  the fail-closed semantics.

  TTL comes from app-env `config :barkpark, Barkpark.Plugins.Github,
  webhook_secret_ttl_ms: <n>` (default `#{@default_webhook_secret_ttl_ms}`).
  TRADEOFF: a rotated webhook secret takes effect only within one TTL window —
  stale for up to ~#{@default_webhook_secret_ttl_ms}ms after rotation. A test
  can set `webhook_secret_ttl_ms: 0` to force a re-resolve on every read.
  """
  @spec webhook_secret_cached() :: String.t() | nil
  def webhook_secret_cached, do: webhook_secret_cached(&get_credentials/0)

  # Test seam: the underlying resolver defaults to `&get_credentials/0`, so a
  # test can inject a counting resolver to assert the DB is touched at most
  # once per TTL.
  @doc false
  @spec webhook_secret_cached((-> credentials())) :: String.t() | nil
  def webhook_secret_cached(resolver) when is_function(resolver, 0) do
    now = System.monotonic_time()

    case :persistent_term.get(@webhook_secret_cache_key, nil) do
      {value, deadline} when now < deadline ->
        value

      _ ->
        value = present(resolver.()[:webhook_secret])
        ttl_native = System.convert_time_unit(webhook_secret_ttl_ms(), :millisecond, :native)
        :persistent_term.put(@webhook_secret_cache_key, {value, now + ttl_native})
        value
    end
  end

  @doc """
  Drop the memoized webhook secret. For tests that need a deterministic
  cache state between cases; no production caller.
  """
  @spec reset_webhook_secret_cache() :: :ok
  def reset_webhook_secret_cache do
    :persistent_term.erase(@webhook_secret_cache_key)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp env_config, do: Application.get_env(@app, @config_key, [])

  defp webhook_secret_ttl_ms do
    case env_config()[@webhook_secret_ttl_key] do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_webhook_secret_ttl_ms
    end
  end

  defp load_db_settings do
    case Settings.get(@plugin_name) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp resolve(key, env, db) do
    cond do
      v = present(env_value(env, key)) -> v
      v = present(Map.get(db, Atom.to_string(key))) -> v
      v = present(Map.get(db, key)) -> v
      true -> nil
    end
  end

  defp env_value(env, key) when is_list(env), do: Keyword.get(env, key)
  defp env_value(env, key) when is_map(env), do: Map.get(env, key)
  defp env_value(_, _), do: nil

  defp present(v) when is_binary(v), do: if(blank?(v), do: nil, else: v)
  defp present(_), do: nil

  # Blank = nil, non-binary, or all-whitespace string — mirrors `github.ex`
  # `blank?/1` so "provisioned" means the same thing at the settings gate and
  # here at the runtime resolver.
  defp blank?(nil), do: true
  defp blank?(v) when is_binary(v), do: String.trim(v) == ""
  defp blank?(_), do: true
end
