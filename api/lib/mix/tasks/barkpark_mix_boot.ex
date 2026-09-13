defmodule Barkpark.MixBoot do
  @moduledoc """
  Minimal boot for one-shot `mix barkpark.*` tasks that run ON A LIVE BOX.

  ## Why this exists

  Every one-shot Mix task used to open with `Mix.Task.run("app.start")`, which
  starts the WHOLE `:barkpark` application — `BarkparkWeb.Endpoint`, an `Oban`
  instance, every plugin worker, `Barkpark.SchemaBootstrap`'s codelist seeders,
  and the LAN-sharing banner. On a developer laptop that is merely slow. On a
  live box it is a fault:

  FOUND 2026-09-02 08:28–08:35Z on guerrilla, running
  `mix barkpark.edges.backfill`. The slot's env carries `PHX_SERVER`, so the
  one-shot's Endpoint tried to bind the port the LIVE node already owns —
  "Running BarkparkWeb.Endpoint with Bandit 1.12.0 at http failed, port 4001
  already in use" — and the run exited before the backfill started. The same
  boot also brought up a SECOND Oban node draining the live queues, raised an
  `Oban.Registry` error from the GitHub DrainWorker, and ran the onixedit
  codelist seeders (one hit `ERROR 57014 query_canceled` against the 60 s
  statement_timeout). The backfill needed none of it: it needs the Repo.

  ## What it starts

  `boot!/1` runs `app.config` (compile + `config/runtime.exs`, WITHOUT starting
  `:barkpark`), starts every application `:barkpark` DEPENDS on, and then starts
  an explicit, tiered child list under its own supervisor:

    * `:repo` — `Barkpark.Vault`, `Barkpark.Repo`. Nothing else. For tasks that
      only `Repo.all/1` + `Repo.update/1` (the offline paper migrations).
    * `:projector` — `:repo` plus the plugin registry, the validation kernel,
      `Barkpark.PubSub` and `Barkpark.TaskSupervisor`, and it installs the
      `:edge_extractor_collector` seam by hand (the composition root normally
      does this in `Barkpark.Application.start/2`, which we never call — WITHOUT
      it the edges backfill would silently project CORE edges only and drop
      every plugin-contributed edge).
    * `:content_write` — `:projector` plus `Barkpark.SchemaBootstrap` (so
      plugin-contributed document schemas are registered) and the webhook
      delivery supervisor, for tasks that go through the full
      `Barkpark.Content` write path.

  ## What it NEVER starts

  `BarkparkWeb.Endpoint` (so nothing binds a port, whatever `PHX_SERVER` says),
  the `Oban` instance, `Barkpark.Plugins.Supervisor` (plugin workers), the Indx
  / Sheets / StudioChat tiers, `DNSCluster`, `Barkpark.Sync`, the self-update
  checker, `Barkpark.Sharing`'s LAN banner — and, on the `:content_write` tier,
  the codelist SEEDERS: `boot!/1` sets `:run_boot_codelist_seeders` to `false`
  before `SchemaBootstrap` reads it, so schemas are REGISTERED while the seed
  writes that timed out on guerrilla never run.

  `boot_plan/1` is the pure description of all of that, and is what the tests
  assert against.
  """

  @dialyzer {:nowarn_function, boot!: 1}

  @type tier :: :repo | :projector | :content_write

  @tiers [:repo, :projector, :content_write]

  @doc """
  Children that must NEVER appear in a one-shot boot plan.

  This is the machine-readable form of the 2026-09-02 incident: each entry is
  something the full `app.start` brought up on the live box that a one-shot
  does not need, and that cost the run (a port bind, a second queue drainer, a
  seeder against the statement_timeout, a LAN banner advertising the box).
  """
  @spec forbidden_children() :: [module()]
  def forbidden_children do
    [
      BarkparkWeb.Endpoint,
      Oban,
      DNSCluster,
      BarkparkWeb.Presence,
      Barkpark.Plugins.Supervisor,
      Barkpark.Plugins.Indx.Supervisor,
      Barkpark.Plugins.Sheets.Supervisor,
      Barkpark.StudioChat.Supervisor,
      Barkpark.Sync.Worker,
      Barkpark.Sync.PushWorker,
      Barkpark.SelfUpdate.Checker,
      Barkpark.SelfUpdate.Runner,
      Barkpark.Sites.DeployRunner
    ]
  end

  @doc """
  The pure boot plan for `tier`: the child list, the application env overrides
  `boot!/1` applies before starting anything, and the tier's flags.

  Tested rather than `boot!/1` itself because `mix test` has already started
  the whole `:barkpark` application — the Endpoint and Oban are up in the test
  VM no matter what this module does, so observing live processes could never
  distinguish a correct plan from `app.start`. The plan is the thing that
  decides, so the plan is what the tests read.
  """
  @spec boot_plan(tier()) :: %{
          tier: tier(),
          children: [term()],
          env: keyword(),
          starts_endpoint?: boolean(),
          starts_oban?: boolean()
        }
  def boot_plan(tier) when tier in @tiers do
    children = children_for(tier)

    %{
      tier: tier,
      children: children,
      env: env_overrides(),
      starts_endpoint?: Enum.any?(children, &(child_module(&1) == BarkparkWeb.Endpoint)),
      starts_oban?: Enum.any?(children, &(child_module(&1) == Oban))
    }
  end

  @doc "The ordered child list for `tier`."
  @spec children_for(tier()) :: [term()]
  def children_for(:repo), do: [Barkpark.Vault, Barkpark.Repo]

  def children_for(:projector) do
    children_for(:repo) ++
      [
        Barkpark.Plugins.Registry,
        Barkpark.Validation.Registry,
        Barkpark.Content.Validation.Rules,
        {Phoenix.PubSub, name: Barkpark.PubSub},
        {Task.Supervisor, name: Barkpark.TaskSupervisor}
      ]
  end

  def children_for(:content_write) do
    [
      Barkpark.Vault,
      Barkpark.Repo,
      Barkpark.Plugins.Registry,
      Barkpark.Plugins.RunStatus,
      Barkpark.Validation.Registry,
      Barkpark.Content.Validation.Rules,
      Barkpark.SchemaBootstrap,
      {Phoenix.PubSub, name: Barkpark.PubSub},
      {Task.Supervisor, name: Barkpark.TaskSupervisor},
      {Task.Supervisor, name: Barkpark.WebhookDeliverySupervisor}
    ]
  end

  @doc """
  Application env forced before any child starts.

  `server: false` is the PHX_SERVER answer in depth. The primary defence is
  that `BarkparkWeb.Endpoint` is not in ANY tier's child list, so no listener
  can exist; this override additionally makes an inherited `PHX_SERVER=true`
  inert for anything that later reads the Endpoint config.
  """
  @spec env_overrides() :: keyword()
  def env_overrides do
    [
      # Codelist seeding is a BOOT convenience, never a one-shot's job. This is
      # the `ERROR 57014 query_canceled` from the 2026-09-02 run.
      run_boot_codelist_seeders: false
    ]
  end

  @doc """
  Boot the minimal runtime for `tier` and return the supervisor pid.

  Call this INSTEAD of `Mix.Task.run("app.start")` at the top of a one-shot
  `run/1`.
  """
  @spec boot!(tier()) :: pid()
  def boot!(tier \\ :repo) when tier in @tiers do
    # `app.config` = compile + load config (including config/runtime.exs).
    # It deliberately stops short of `app.start`, which is the whole point.
    Mix.Task.run("app.config")

    Enum.each(env_overrides(), fn {key, value} ->
      Application.put_env(:barkpark, key, value)
    end)

    force_endpoint_server_off!()
    start_dependency_apps!()

    if tier != :repo, do: install_edge_extractor_seam!()

    {:ok, pid} =
      Supervisor.start_link(children_for(tier),
        strategy: :one_for_one,
        name: Barkpark.MixBoot.Supervisor,
        timeout: :infinity
      )

    pid
  end

  @doc """
  Start every application `:barkpark` depends on — and never `:barkpark`
  itself.

  Starting the `:oban` / `:phoenix` APPLICATIONS is not starting an Oban
  instance or an Endpoint: both are children of `Barkpark.Supervisor`, which
  only `Barkpark.Application.start/2` builds, and we never call it.
  """
  @spec start_dependency_apps!() :: :ok
  def start_dependency_apps! do
    :ok = load_if_needed(:barkpark)

    for app <- dependency_apps() do
      {:ok, _} = Application.ensure_all_started(app)
    end

    :ok
  end

  @doc "The application list `:barkpark` declares, minus `:barkpark`."
  @spec dependency_apps() :: [atom()]
  def dependency_apps do
    :ok = load_if_needed(:barkpark)

    (Application.spec(:barkpark, :applications) || [])
    |> List.delete(:barkpark)
  end

  @doc false
  def load_if_needed(app) do
    case Application.load(app) do
      :ok -> :ok
      {:error, {:already_loaded, ^app}} -> :ok
      other -> other
    end
  end

  defp force_endpoint_server_off! do
    config = Application.get_env(:barkpark, BarkparkWeb.Endpoint, [])
    Application.put_env(:barkpark, BarkparkWeb.Endpoint, Keyword.put(config, :server, false))
    :ok
  end

  # Mirror of `Barkpark.Application.install_edge_extractor_seam/0`. Same
  # "explicit config wins" contract: a wired seam is never overwritten.
  defp install_edge_extractor_seam! do
    if is_nil(Application.get_env(:barkpark, :edge_extractor_collector)) do
      Application.put_env(
        :barkpark,
        :edge_extractor_collector,
        &Barkpark.Plugins.Registry.collect_edge_extractors/1
      )
    end

    :ok
  end

  defp child_module({mod, _}), do: mod
  defp child_module(%{start: {mod, _, _}}), do: mod
  defp child_module(mod) when is_atom(mod), do: mod
  defp child_module(_), do: nil
end
