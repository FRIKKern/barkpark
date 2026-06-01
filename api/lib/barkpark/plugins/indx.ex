defmodule Barkpark.Plugins.Indx do
  @moduledoc """
  Indx full-text search engine plugin (CORE).

  Backs a Barkpark search surface with a dedicated single-tenant Indx
  instance instead of Postgres. The manifest at
  `priv/plugins/indx/plugin.json` is read and validated at compile time by
  `Barkpark.Plugin.__using__/1` (decision D7 — no runtime eval).

  ## What it wires

    * **Auth GenServer** — `Indx.Auth`, a lazy JWT cache, folded into the
      host supervision tree via `register_workers/1`.
    * **Retriever engine** — registers `Indx.Retriever` under the engine
      name `"indx"` in `config :barkpark, :search_retrievers` at boot (also
      done statically in `config/config.exs` so the seam resolves even
      before the plugin's workers wire up). A surface whose
      `config["engine"]` is `"indx"` then routes its searches through Indx
      via `Barkpark.Search.Retrievers.resolve/1`.
    * **Lifecycle hooks** — `after_save` / `after_publish` /
      `after_unpublish` / `after_delete` each enqueue a DEBOUNCED blue/green
      rebuild (`Indx.IndexerWorker`, queue `:indx`) for the doc's scope.

  ## Fresh-install invariant

  With `config :barkpark, :plugins, []` (the kill switch) NOTHING here
  registers — no engine, no workers, no hooks — and Barkpark searches on
  Postgres exactly as before. The static `search_retrievers` entry in
  `config.exs` is inert until a surface opts into engine `"indx"`, and no
  surface does so by default. This plugin is purely additive.

  ## Blue/green sync, single-tenant

  The 2026-06-01 spike confirmed re-loading a key onto a live indexed
  dataset HANGS the engine. So every sync loads the full corpus into a
  FRESH `<prefix>_<scope>_v<n>` dataset, indexes it, verifies the count,
  atomically swaps the live pointer, then deletes the old dataset. Loads
  are serialised by the `:indx` queue + the worker's `unique` clause keyed
  on scope. Run a DEDICATED Indx for Barkpark — do not share it.
  """

  use Barkpark.Plugin,
    manifest_path: "../../../priv/plugins/indx/plugin.json"

  @plugin_name "indx"
  @engine "indx"

  @doc "Returns the plugin's discriminator name (D20)."
  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @doc "The search-engine name this plugin registers a retriever under."
  @spec engine() :: String.t()
  def engine, do: @engine

  @doc """
  Plugin-contributed supervision children.

  Returns the lazy JWT cache (`Indx.Auth`). Folded into the host
  supervision tree by `Barkpark.Plugins.Registry.collect_workers/1` during
  `Barkpark.Application.start/2`.

  As a side effect this also (idempotently) registers the `"indx"` engine
  in `config :barkpark, :search_retrievers` so the seam resolves the
  retriever at runtime even if `config.exs`'s static entry was stripped.
  `register_workers/1` runs once at boot, before the endpoint accepts
  traffic — the same ordering rationale OnixEdit relies on for its Bokbasen
  auth cache.
  """
  @impl Barkpark.Plugin
  def register_workers(_ctx) do
    ensure_engine_registered()
    [Barkpark.Plugins.Indx.Auth]
  end

  @doc """
  Lifecycle-hook registrations.

  All four mutating `after_*` events route to the same fast hook
  (`Indx.Lifecycle.enqueue_rebuild/1`), which enqueues a debounced
  blue/green rebuild for the doc's scope. See `Barkpark.Plugins.Indx.Lifecycle`.
  """
  @impl Barkpark.Plugin
  def lifecycle_hooks do
    fun = &Barkpark.Plugins.Indx.Lifecycle.enqueue_rebuild/1

    %{
      after_save: [fun],
      after_publish: [fun],
      after_unpublish: [fun],
      after_delete: [fun]
    }
  end

  @doc """
  Declarative settings form for the admin Plugin Settings LiveView.

  Field names are dot-namespaced: the leading segment is the
  `plugin_settings` row (`"indx"`), the remainder the flat key inside it —
  the exact shape `Barkpark.Plugins.Indx.Settings.get/0` reads back.
  """
  @impl Barkpark.Plugin
  def settings_schema do
    [
      %{
        name: "indx.api_base",
        type: :url,
        label: "Indx API base URL",
        required: true,
        default: "http://127.0.0.1:5001",
        placeholder: "http://127.0.0.1:5001",
        group: "Indx",
        hint: "Dedicated single-tenant Indx. The /api segment is appended automatically."
      },
      %{
        name: "indx.user_email",
        type: :string,
        label: "Indx login email",
        required: true,
        default: "admin@indx.co",
        group: "Indx"
      },
      %{
        name: "indx.user_password",
        type: :password,
        label: "Indx login password",
        required: true,
        masked: true,
        group: "Indx",
        hint: "Stored encrypted at rest via BARKPARK_CLOAK_KEY"
      },
      %{
        name: "indx.dataset_prefix",
        type: :string,
        label: "Dataset name prefix",
        required: false,
        default: "bp",
        group: "Indx",
        hint: "Blue/green rebuilds produce <prefix>_<scope>_v<n>."
      }
    ]
  end

  @doc """
  Test the live Indx connection. Pulls a JWT via `Indx.Auth.token/0`
  (using the configured/encrypted credentials) and shapes the result into
  the host's first-wins `test_connection` contract.
  """
  @impl Barkpark.Plugin
  def test_connection(_settings) do
    auth = Barkpark.Plugins.Indx.Auth

    cond do
      not Code.ensure_loaded?(auth) or not function_exported?(auth, :token, 0) ->
        {:error, "Indx auth client not loaded."}

      true ->
        case auth.token() do
          {:ok, _jwt} -> {:ok, %{message: "Indx reachable: login OK."}}
          {:error, %{message: msg}} -> {:error, "Indx unreachable: #{msg}"}
          {:error, reason} -> {:error, "Indx unreachable: #{inspect(reason)}"}
        end
    end
  end

  # Idempotently merge the "indx" engine into :search_retrievers. Preserves
  # any other engines already registered (e.g. from config.exs or another
  # plugin). Safe to call repeatedly.
  defp ensure_engine_registered do
    current = Application.get_env(:barkpark, :search_retrievers, %{})

    unless Map.get(current, @engine) == Barkpark.Plugins.Indx.Retriever do
      Application.put_env(
        :barkpark,
        :search_retrievers,
        Map.put(current, @engine, Barkpark.Plugins.Indx.Retriever)
      )
    end

    :ok
  end
end
