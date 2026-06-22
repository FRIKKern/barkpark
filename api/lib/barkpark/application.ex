defmodule Barkpark.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # Goal barkpark-G1, task s2: ask the Plugins.Registry for every plugin-
    # contributed child spec BEFORE constructing the supervision tree. The
    # call is a pure function — Registry.collect_workers/1 does NOT depend
    # on the Registry GenServer being alive, which is essential because the
    # Registry process is itself a child below. See its moduledoc for the
    # source-of-truth precedence (Application env wins; otherwise sync disk
    # walk of priv/plugins). Per the locked Q1 grill decision, topology is
    # compile-time static — hot-reload is out of scope for v1.
    plugin_children = Barkpark.Plugins.Registry.collect_workers(%{phase: :boot})

    # C4-1: plugins may contribute Oban Cron entries via `oban_crontab/0`.
    # Collect them here (a pure, GenServer-independent call, same as
    # collect_workers/1 above) and fold them into the host's static Oban
    # config BEFORE the Oban child below reads it. When NO plugin
    # contributes, `merge_plugin_crontab/2` returns the base config
    # unchanged (dormant — the Tasks TTL/Compactor crontab in config.exs
    # is the only source of cron entries today).
    base_oban = Application.fetch_env!(:barkpark, Oban)
    plugin_crontab = Barkpark.Plugins.Registry.collect_oban_crontab()
    oban_config = merge_plugin_crontab(base_oban, plugin_crontab)

    children =
      [
        Barkpark.RateLimiter,
        BarkparkWeb.Telemetry,
        Barkpark.Repo,
        Barkpark.Vault,
        # WI1: plugin registry — must come up before workers/endpoint so any
        # later boot hook that calls Barkpark.Plugins.Registry has a live PID.
        Barkpark.Plugins.Registry,
        # Task barkpark-otv: in-memory run-status tracker the plugin admin LV
        # reads to surface "last bootstrap" / "last seed" timestamps. Must
        # come up before the post-boot Task that calls Bootstrap +
        # codelist seeders so the very first sweep's results land in the
        # map. Empty-state if absent — never crashes the caller.
        Barkpark.Plugins.RunStatus,
        # Phase 3 WI1: cross-field validation kernel — registry of value-
        # checkers (ETS-backed) and per-schema rule cache. Both must be up
        # before the endpoint can serve mutate/export traffic.
        Barkpark.Validation.Registry,
        Barkpark.Content.Validation.Rules
        # Plugin-contributed workers fold in BELOW (was: a hardcoded plugin
        # GenServer child here). Position between host services and Oban so
        # plugin workers can rely on Repo/Vault/Registry being up, but come
        # up before the endpoint serves traffic.
      ] ++
        plugin_children ++
        [
          # Boot-order fix: SchemaBootstrap runs SYNCHRONOUSLY here, after the
          # Repo + Plugins.Registry GenServer (above) and BEFORE Oban. The
          # supervisor blocks on its init/1 (which registers every plugin's
          # schemas) before starting Oban, so Oban can never dequeue a job
          # against an unregistered schema. No paused queues, no resume loop.
          Barkpark.SchemaBootstrap,
          # Indx retriever-seam runtime. Indx is NOT a registered plugin, so it
          # contributes nothing via collect_workers/1 — its supervised processes
          # MUST be declared statically here. Order matters: Auth first (the
          # :indx Oban queue jobs and Recovery's boot login both call
          # Auth.token/0), then Recovery (re-seats the live-dataset pointer
          # after a restart), then Oban. Without these, every IndexerWorker job
          # crashes on a dead Auth process and engine=indx silently falls back
          # to Postgres recovery.
          Barkpark.Plugins.Indx.Auth,
          Barkpark.Plugins.Indx.Recovery,
          {Oban, oban_config},
          {DNSCluster, query: Application.get_env(:barkpark, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: Barkpark.PubSub},
          # Sheets M1: per-sheet collaborative sessions — a unique Registry
          # over {dataset, published-id} keys plus the DynamicSupervisor the
          # sessions start under (lazily, on first op; restart: :temporary —
          # a crashed session restarts fresh from the persisted row on the
          # next op). CORE, plugin-independent (fresh-install invariant):
          # only the HTTP ops route is plugin wiring. Needs Repo (load /
          # persist) and PubSub (delta broadcasts) — both above.
          {Registry, keys: :unique, name: Barkpark.Plugins.Sheets.SessionRegistry},
          {DynamicSupervisor, name: Barkpark.Plugins.Sheets.SessionSupervisor, strategy: :one_for_one},
          # Start a worker by calling: Barkpark.Worker.start_link(arg)
          # {Barkpark.Worker, arg},
          BarkparkWeb.Presence,
          {Task.Supervisor, name: Barkpark.TaskSupervisor},
          # Start to serve requests, typically the last entry
          BarkparkWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Barkpark.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _pid} = ok ->
        Barkpark.Telemetry.Handlers.attach()

        # Plugin discovery + schema/checker/seeder registration now runs
        # synchronously in Barkpark.SchemaBootstrap (a child positioned
        # before the Oban child above), so it has completed by the time the
        # supervisor returns {:ok, _pid} here. Nothing left to do post-boot.

        # P4: fold the persisted `shares` table into the live `:shares` list
        # (= env baseline ++ stored rows). The Repo child is up by now, so the
        # store query is safe; refresh/0 is self-guarded, so a not-yet-ready
        # store (e.g. unmigrated DB at test boot) leaves the env baseline
        # untouched. MUST run before the banner so it reports stored shares too.
        Barkpark.Sharing.refresh()

        # P1c LAN-sharing banner. DEFAULT-OFF: with no shares (env OR stored),
        # this is a no-op (active?/0 is false) and nothing is logged. When
        # active, warn loudly with every reachable reader URL so the operator
        # knows the box is now exposed on the local network.
        log_sharing_banner()

        # Fresh-install safety: the Postgres search engine's fuzzy/typo recovery
        # relies on pg_trgm (similarity()). If the extension is missing — common
        # on managed Postgres where CREATE EXTENSION needs an explicit allowlist
        # — log a clear, actionable warning. Fully guarded: any failure (DB not
        # ready, query error) is swallowed so it can never block boot.
        check_pg_trgm()

        ok

      other ->
        other
    end
  end

  # C4-1: fold plugin-contributed Oban Cron entries into the host's Oban
  # keyword config. Pure, side-effect-free, and unit-testable (see
  # registry_oban_crontab_test.exs). Dormant by construction: an empty
  # `plugin_crontab` returns `oban_config` byte-for-byte unchanged.
  #
  # Behaviour:
  #   * empty contribution → return config unchanged.
  #   * Cron plugin already present in `:plugins` → append the entries to
  #     its `:crontab` list (host's static entries come first).
  #   * no Cron plugin entry but plugins DID contribute → add an
  #     `{Oban.Plugins.Cron, crontab: plugin_crontab}` entry.
  @doc false
  @spec merge_plugin_crontab(keyword(), list()) :: keyword()
  def merge_plugin_crontab(oban_config, []), do: oban_config

  def merge_plugin_crontab(oban_config, plugin_crontab) when is_list(plugin_crontab) do
    plugins = Keyword.get(oban_config, :plugins, [])

    {merged_plugins, found?} =
      Enum.map_reduce(plugins, false, fn
        {Oban.Plugins.Cron, opts}, _found when is_list(opts) ->
          base = Keyword.get(opts, :crontab, [])
          {{Oban.Plugins.Cron, Keyword.put(opts, :crontab, base ++ plugin_crontab)}, true}

        other, found ->
          {other, found}
      end)

    merged_plugins =
      if found? do
        merged_plugins
      else
        merged_plugins ++ [{Oban.Plugins.Cron, crontab: plugin_crontab}]
      end

    Keyword.put(oban_config, :plugins, merged_plugins)
  end

  # P1c: one-time post-boot banner for LAN sharing. No-op (and silent) unless
  # at least one share is configured — preserving the Default-OFF invariant.
  @spec log_sharing_banner() :: :ok
  defp log_sharing_banner do
    if Barkpark.Sharing.active?() do
      urls = Barkpark.Sharing.share_urls()

      url_lines =
        case urls do
          [] ->
            "  (no LAN IPv4 detected — reader URLs unavailable; bind is still 0.0.0.0)"

          list ->
            list
            |> Enum.map(fn {_share, url} -> "  • #{url}" end)
            |> Enum.join("\n")
        end

      Logger.warning("""
      [Sharing] LAN sharing is ACTIVE — the following paper readers are exposed:
      #{url_lines}
      These are reachable by anyone on this network — trusted networks only.
      """)
    end

    :ok
  end

  # Fresh-install guard: warn (don't crash) when pg_trgm is absent, since the
  # default Postgres search engine degrades fuzzy/typo recovery without it.
  @spec check_pg_trgm() :: :ok
  defp check_pg_trgm do
    case Barkpark.Repo.query("SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm'", []) do
      {:ok, %{num_rows: rows}} when rows > 0 ->
        :ok

      {:ok, _} ->
        Logger.warning("""
        [Search] pg_trgm extension is NOT installed — fuzzy/typo search is degraded.
        Trigram similarity() matching and typo recovery will be skipped on Postgres.
        Run `CREATE EXTENSION IF NOT EXISTS pg_trgm;` (or enable it in your managed
        Postgres extension allowlist) to restore full fuzzy search.
        """)

      _other ->
        :ok
    end
  rescue
    # Never let the boot-time probe take the app down (e.g. DB not yet ready).
    error ->
      Logger.debug("[Search] pg_trgm check skipped: #{inspect(error)}")
      :ok
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BarkparkWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
