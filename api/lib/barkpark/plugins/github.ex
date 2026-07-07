defmodule Barkpark.Plugins.Github do
  @moduledoc """
  GitHub — thin plugin wiring for the Barkpark→GitHub bridge (design paper
  `bp-github-bridge-epic-charter`, epic `github-bridge`). Off by default:
  the plugin ships inert until a maintainer adds `github` to
  `BARKPARK_PLUGINS` and provisions a GitHub App.

  Barkpark (the guerrilla ledger) is the SINGLE SOURCE OF TRUTH. This module
  owns only the mounting; the sync machinery (cursor, outbox reader, debounced
  per-task Oban MirrorJob, projection, App auth, REST/GraphQL client, inbound
  webhook + adopt controllers) lands in later waves as pure/DB-only modules the
  host calls into. Per the plugin contract (`Barkpark.Plugin` @moduledoc) a
  plugin is schemas + business logic, never UI — the host owns every route
  table, renderer, and console.

  ## Posture — outbound mirror (Wave 2) + inbound webhook route (Wave 3)

    * `register_workers/1` → `[Auth, DrainWorker]`. Both start ONLY when the
      plugin is whitelisted, so off-by-default is preserved. `Github.Auth` is the
      singleton App-token cache; `Github.DrainWorker` is the supervised drain-tick
      GenServer that pumps `mutation_events` → debounced `MirrorJob`s (mirrors
      `onixedit.ex` supervising `Bokbasen.Auth`).
    * `oban_crontab/0` → `[]` (the `use` default) STAYS empty. The drain worker is
      a supervised GenServer, NOT cron — the `Barkpark.Sync.PushWorker` precedent.
      The `github_mirror` Oban queue itself is declared statically in
      `config/config.exs` (plugins can add crontab, not queues).
    * `register_routes/1` → the ONE inbound webhook route (Wave 3). It mounts
      `POST /v1/plugins/github/webhook` → `BarkparkWeb.GithubWebhookController`
      on the `:github_webhook` bucket (signature-verified pipeline, slice 1).
      The adopt controller is still a later wave (4). Off-by-default is
      unaffected: the route only resolves a live handler when `github` is
      whitelisted AND the router carries the `:github_webhook` scope block.
    * `register_schemas/1` → `[]` (the `use` default). GitHub adds NO task
      schema (decision D3): the bookkeeping field `github:{repo,issue,synced_rev}`
      rides the task's plain CONTENT via `Content.*`, never a declared
      task-schema field — the github plugin must never mutate the tasks plugin's
      schema.

  ## What this slice DOES contribute

    * `settings_schema/0` — the six GitHub App credentials the admin Plugin
      Settings LiveView renders, dot-namespaced under the `github` settings row
      (`github.repo`, `github.app_id`, `github.installation_id`,
      `github.private_key`, `github.webhook_secret`, `github.project_id`). The
      two secrets are `:password` + `:masked` so they never render in cleartext.
    * `validate_settings/1` — fail-closed: every required credential must be
      present and non-blank before the plugin can talk to GitHub. A half-
      provisioned App is worse than a dark one, so validation refuses it.
    * `desk_items/1` — one Structure-desk link to the (future) sync-health
      console at `/admin/github`. The path lives under `/admin` (not `/studio`):
      the host's `scoped_plugin_href` rewrites `/studio/<x>` links assuming
      `<x>` is a dataset, which mangles the path — the pulse/onixedit precedent.

  Plugin off = zero routes, zero workers, dark tables. It is NOT added to any
  `BARKPARK_PLUGINS` whitelist by default — provisioning the GitHub App and
  flipping the whitelist is the sole (wave 7) human gate.
  """

  use Barkpark.Plugin, manifest_path: "../../../priv/plugins/github/plugin.json"

  # The settings row every credential lands in (leading dot-segment of each
  # field name). Kept as one constant so the schema and the validator agree.
  @settings_row "github"

  # Credentials that MUST be present + non-blank before the bridge may run.
  # `project_id` is intentionally absent — Projects v2 is optional (wave 5);
  # the Issues mirror works without a board.
  @required_creds ~w(repo app_id installation_id private_key webhook_secret)

  @doc """
  The credential keys (as flat `plugin_settings` strings) that MUST be present
  and non-blank before the bridge may run. `Github.Settings.active?/0` reuses
  this list so the settings-gate validator and the runtime creds resolver
  agree on exactly one definition of "provisioned".
  """
  @spec required_creds() :: [String.t()]
  def required_creds, do: @required_creds

  @doc """
  Declarative settings form for the admin Plugin Settings LiveView.

  Field names are dot-namespaced `github.<key>`: the leading `github` segment
  selects the `plugin_settings` row, the remainder is the flat key inside it —
  the exact shape the wave-2 App-auth GenServer + client read back. The private
  key and webhook secret are `:password` + `:masked` (stored encrypted at rest
  via `BARKPARK_CLOAK_KEY`).
  """
  @impl Barkpark.Plugin
  def settings_schema do
    [
      %{
        name: "github.repo",
        type: :string,
        label: "Repository (owner/name)",
        required: true,
        group: "GitHub",
        placeholder: "FRIKKern/barkpark",
        hint: "The repo issues mirror into, as owner/name."
      },
      %{
        name: "github.app_id",
        type: :string,
        label: "GitHub App ID",
        required: true,
        group: "GitHub",
        hint: "Numeric App ID from the GitHub App settings page."
      },
      %{
        name: "github.installation_id",
        type: :string,
        label: "Installation ID",
        required: true,
        group: "GitHub",
        hint: "The App installation on this repo/org."
      },
      %{
        name: "github.private_key",
        type: :password,
        label: "App private key (PEM)",
        required: true,
        masked: true,
        group: "GitHub",
        hint:
          "RS256 signing key for the App JWT. Stored encrypted at rest via BARKPARK_CLOAK_KEY."
      },
      %{
        name: "github.webhook_secret",
        type: :password,
        label: "Webhook secret",
        required: true,
        masked: true,
        group: "GitHub",
        hint: "Shared secret for HMAC verification of inbound webhooks. Stored encrypted."
      },
      %{
        name: "github.project_id",
        type: :string,
        label: "Projects v2 node ID (optional)",
        required: false,
        group: "GitHub",
        hint:
          "GraphQL node ID of the read-only dashboard board. Leave blank to disable Projects sync."
      }
    ]
  end

  @doc """
  Fail-closed credential validation.

  Receives the nested settings shape the admin LiveView hands every plugin —
  `%{"github" => %{"repo" => ..., ...}}` (row → flat keys). Returns `:ok` only
  when every required credential is present and non-blank; otherwise
  `{:error, [{field_atom, message}]}` naming each offending `github.<key>`.

  A partially-provisioned App (say a key but no installation id) must never be
  accepted: it would let the bridge start and then fail mid-mirror. Refusing it
  at the settings gate keeps the failure honest and in front of the operator.
  """
  @impl Barkpark.Plugin
  def validate_settings(settings) when is_map(settings) do
    # A present-but-non-map `github` row (e.g. `%{"github" => "junk"}`) must
    # fail CLOSED, not crash: `Map.get(non_map, key)` raises BadMapError, and
    # the admin LiveView's `run_plugin_validation/2` rescues any raise into
    # `:ok` — so a crash here would be silently treated as VALID (fail-open),
    # the exact opposite of the intent. Coerce a non-map row to empty so every
    # required credential reads blank and the settings are rejected.
    row =
      case Map.get(settings, @settings_row) do
        m when is_map(m) -> m
        _ -> %{}
      end

    errors =
      Enum.reduce(@required_creds, [], fn key, acc ->
        if blank?(Map.get(row, key)) do
          [{String.to_atom("#{@settings_row}.#{key}"), "is required"} | acc]
        else
          acc
        end
      end)
      |> Enum.reverse()

    if errors == [], do: :ok, else: {:error, errors}
  end

  def validate_settings(_settings),
    do: {:error, [{:github, "settings must be a map"}]}

  @doc """
  Surface the sync-health console in the Structure desk. The link points at
  `/admin/github` (an `/admin` path, NOT `/studio/...`) so the host's
  `scoped_plugin_href` leaves it intact on both flat and scoped desks — the
  same shape pulse/onixedit use. The console itself lands in a later wave; the
  link is harmless until then (routes it to a host 404, not a crash).
  """
  @impl Barkpark.Plugin
  def desk_items(_dataset) do
    [%{type: :link, label: "GitHub Sync", path: "/admin/github", icon: "github"}]
  end

  # The single inbound webhook route (Wave 3). Lands at
  # `POST /v1/plugins/github/webhook` via the `:github_webhook` scope block the
  # router carries (slice 1), which pipes it through the signature-verify
  # pipeline — signature is the sole auth. The adopt controller is a later wave.
  @impl Barkpark.Plugin
  def register_routes(_ctx) do
    [
      {:post, "/github/webhook", BarkparkWeb.GithubWebhookController, :receive,
       auth: :github_webhook}
    ]
  end

  @doc """
  Supervised workers the host splices into the plugin supervision tree when
  `github` is whitelisted (AUTH START contract #1). Both are singletons:

    * `Barkpark.Plugins.Github.Auth` — the App installation-token cache. Without
      it under supervision, `Auth.token/0` crashes no-process at mirror time.
    * `Barkpark.Plugins.Github.DrainWorker` — the drain-tick GenServer that reads
      the outbound cursor/outbox and enqueues debounced `MirrorJob`s. A supervised
      GenServer, not cron (the `Barkpark.Sync.PushWorker` precedent).

  They start ONLY here, so a non-whitelisted install runs neither — off by
  default. Mirrors `onixedit.ex` returning `[Bokbasen.Auth]`.
  """
  @impl Barkpark.Plugin
  def register_workers(_ctx) do
    [Barkpark.Plugins.Github.Auth | drain_worker_child()]
  end

  # Auth is a LAZY singleton (no boot DB, no timer — safe to supervise always,
  # like onixedit's Bokbasen.Auth). The DrainWorker, by contrast, runs a periodic
  # DB-touching tick; a boot-started instance in the test env fires against a
  # process that owns no ExUnit sandbox connection, raising DBConnection.Ownership
  # and cascading across the suite. So it is gated OFF in test (config/test.exs) —
  # the `Barkpark.Sync.PushWorker`/`Sync.enabled?()` precedent (splice only when
  # the engine should actually run). Defaults ON, so prod is unaffected. Tests that
  # exercise the drain loop start their OWN anonymous instance with injected seams.
  defp drain_worker_child do
    enabled? =
      :barkpark
      |> Application.get_env(Barkpark.Plugins.Github.DrainWorker, [])
      |> Keyword.get(:enabled, true)

    if enabled?, do: [Barkpark.Plugins.Github.DrainWorker], else: []
  end

  # Blank = nil, non-binary, or all-whitespace string. A credential the
  # operator typed as spaces is as good as missing.
  defp blank?(nil), do: true
  defp blank?(v) when is_binary(v), do: String.trim(v) == ""
  defp blank?(_), do: false
end
