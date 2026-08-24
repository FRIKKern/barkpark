defmodule Barkpark.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # gh-9531 FAIL-CLOSED: resolve the transactional From once, HERE, so a
    # malformed MAIL_FROM_ADDRESS / MAIL_FROM_NAME refuses the node at boot.
    # Barkpark.Mailer.from/0 raises on a bad value rather than falling back to
    # the barkpark.cloud default — a silent fallback IS the gh-9531 defect in a
    # new costume (the operator believes their sender is set while the box keeps
    # emitting ours). Without this call the first observation of a typo would be
    # a real user's password reset never arriving, because delivery is
    # fire-and-forget through Barkpark.TaskSupervisor and nothing reads the
    # result. Unset env keeps the config.exs default, so this is a no-op for
    # every deployment that has not opted in.
    _ = Barkpark.Mailer.from()

    # Companion to the check above, and the other half of the same defect: the
    # From can be perfectly valid while there is no relay to hand the message
    # to. `config/config.exs` defaults `Barkpark.Mailer` to
    # `Swoosh.Adapters.Local`, an in-memory mailbox whose `deliver/2` returns
    # `{:ok, _}`, so an instance that never set SMTP_HOST accepts every magic
    # link, password reset, verification and access grant and discards it while
    # answering 200. WARNS rather than raising: a box with no relay is a
    # legitimate configuration (every laptop is one), so this states the
    # condition instead of refusing to boot. See
    # `Barkpark.Mailer.warn_if_undeliverable/0`.
    _ = Barkpark.Mailer.warn_if_undeliverable()

    # The /v1/graph admission-cap slot table, created HERE and nowhere else that
    # matters. It is a CONCURRENCY BOUND, not a cache: the rows are the slots
    # currently held, so the table must outlive every request that holds one.
    # Created lazily from a request process it would be owned by that process
    # and destroyed the moment the request finished — under exactly the
    # concurrent load the cap exists to shed, in-flight slots would be forgotten
    # (the bound silently resets) and a sibling's `:ets.insert`/`:ets.delete`
    # would raise ArgumentError, i.e. a 500 from the guard against 500s. This
    # process lives as long as the application, so the bound does too.
    BarkparkWeb.TasksController.init_graph_corpus_slots()

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

    # One-way PULL sync (Barkpark.Sync). DORMANT by default: when no sync
    # source is configured (`BARKPARK_SYNC_*` env unset), enabled?/0 is false
    # and this is `[]` — the fresh-install invariant holds. When configured,
    # the dedicated Finch pool isolates the endless stream connection from the
    # webhook dispatcher's shared pool, and the Worker is the puller. Both are
    # spliced in just BEFORE the Endpoint (below) so PubSub + TaskSupervisor —
    # which Content.apply_mutations broadcasts/dispatches through — are already
    # up by the time the first event is applied.
    sync_children =
      if Barkpark.Sync.enabled?() do
        # The PushWorker rides the SAME dedicated Finch pool as the puller and is
        # spliced ONLY when push is separately activated (push_active?: full
        # creds + the push flag). Default-off holds: a fresh install starts
        # neither (invariant #2).
        push_children =
          if Barkpark.Sync.push_active?(), do: [Barkpark.Sync.PushWorker], else: []

        [
          {Finch, name: Barkpark.Sync.Finch, pools: %{default: [size: 2, count: 1]}},
          Barkpark.Sync.Worker
        ] ++ push_children
      else
        []
      end

    # Instance self-update checker (Barkpark.SelfUpdate). DORMANT by default:
    # config.exs ships `enabled: false` (dev/test start nothing — the
    # fresh-install invariant holds) and only prod's runtime.exs flips it on
    # (opt-out via BARKPARK_SELF_UPDATE_CHECK=off). Read-only: the Checker
    # only polls the upstream repo for newer release tags — it never mutates
    # the instance. Spliced next to sync_children, before the Endpoint.
    self_update_children =
      if Barkpark.SelfUpdate.enabled?(), do: [Barkpark.SelfUpdate.Checker], else: []

    children = child_specs(plugin_children, oban_config, sync_children, self_update_children)

    # Chapter 64 (layering isolates blast radius). The top supervisor keeps the
    # OTP-default 3-restarts-in-5s budget — made EXPLICIT here — but that budget
    # now guards only critical infra (Repo/Oban/PubSub/Endpoint) and the
    # intermediate supervisors. The volatile plugin + Indx tiers churn under
    # their OWN budgets (see child_specs/4), so their crash-loops can no longer
    # breach this shared intensity and take the whole app down.
    # Starting this supervisor includes the deliberately synchronous
    # SchemaBootstrap child. Production plugin/schema inventories can take
    # longer than GenServer's default five-second start deadline, so the root
    # caller must wait for the ordered boot sequence instead of killing it.
    opts = [
      strategy: :one_for_one,
      name: Barkpark.Supervisor,
      max_restarts: 3,
      max_seconds: 5,
      timeout: :infinity
    ]

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

  @doc """
  Build the top-level child spec list, tiered for blast-radius isolation.

  Pure and unit-testable (see `application_child_specs_test.exs`): given the
  collected `plugin_children`, the merged `oban_config`, and the dormant-by-
  default `sync_children` / `self_update_children`, it returns the ordered list
  handed to `Supervisor.start_link/2`.

  The genuinely-volatile children are NOT direct children of `Barkpark.Supervisor`
  anymore — they are wrapped in intermediate supervisors, each in the SAME slot
  the flat children used to occupy, so global boot ORDER is preserved verbatim:

    * `Barkpark.Plugins.Supervisor` wraps `plugin_children` (was folded in flat).
    * `Barkpark.Plugins.Indx.Supervisor` wraps Auth/Monitor/Recovery.
    * `Barkpark.Plugins.Sheets.Supervisor` wraps the sheets session registry/
      supervisor/replay-ring.
    * `Barkpark.StudioChat.Supervisor` wraps the studio-chat registries/runtime/
      notifier.

  Ordering invariants held: Repo before everything that queries it; Registry
  before plugin workers; SchemaBootstrap after Repo+Registry and BEFORE Oban;
  Indx (Auth→Recovery) before Oban; PubSub before the Sheets/StudioChat tiers
  and the Endpoint; Endpoint last.
  """
  @spec child_specs(list(), keyword(), list(), list()) :: [
          Supervisor.child_spec() | {module(), term()} | module()
        ]
  def child_specs(plugin_children, oban_config, sync_children, self_update_children)
      when is_list(plugin_children) and is_list(sync_children) and is_list(self_update_children) do
    [
      # Dedicated Finch pool for the auth/login OUTBOUND path (Felix W10,
      # task-felix-outbound-pool-isolation + task-felix-sso-explicit-timeout).
      # The 5 auth-outbound clients (SSO OIDC/Social, github/indx/bokbasen
      # plugin-auth token fetches) route through THIS pool via `finch:
      # Barkpark.Auth.Finch` instead of Req's global default (Req.Finch).
      # DEFENSE-IN-DEPTH, not a crash-fix: Finch partitions connection slots
      # per {scheme,host,port}, so a webhook/CDN storm to other hosts already
      # cannot drain the IdP host's slots on the shared instance. The value is
      # (a) an owned/tunable/observable connection budget for the login path
      # decoupled from the global default (mirrors Sync.Finch:~51 below),
      # (b) bounds BEAM-global socket/FD/ephemeral-port pressure under a real
      # concurrent storm, (c) deterministically isolates the same-host edge (a
      # self-hosted IdP sharing a reverse-proxy host with a webhook target).
      # UNCONDITIONAL + no Repo dep — free idle pool, always up before the
      # Endpoint so the first login never races an unstarted pool.
      {Finch, name: Barkpark.Auth.Finch, pools: %{default: [size: 10, count: 1]}},
      Barkpark.RateLimiter,
      BarkparkWeb.Telemetry,
      # Rolling req/s + p95 aggregator over [:phoenix, :endpoint, :stop]
      # (cloud-console W5). Up before the Endpoint so early traffic is counted;
      # a pure ETS-backed window, no Repo dependency.
      BarkparkWeb.RequestStats,
      # Always-on Linux-host vitals sampler for the Studio bottom bar. Core /
      # plugin-independent (unlike Pulse.Metrics), no Repo dependency; reads
      # :os_mon + /proc every few seconds and broadcasts on "server_vitals".
      Barkpark.HostVitals.Sampler,
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
      Barkpark.Content.Validation.Rules,
      # VOLATILE plugin tier (was folded in FLAT here via plugin_children).
      # Now isolated under its own supervisor + restart budget: a crash-looping
      # third-party/plugin worker can no longer breach Barkpark.Supervisor's
      # budget and take Repo/Oban/Endpoint down. Same slot → boot order held
      # (plugin workers still come up after Repo/Vault/Registry, before Oban).
      {Barkpark.Plugins.Supervisor, plugin_children},
      # Boot-order fix: SchemaBootstrap runs SYNCHRONOUSLY here, after the
      # Repo + Plugins.Registry GenServer (above) and BEFORE Oban. The
      # supervisor blocks on its init/1 (which registers every plugin's
      # schemas) before starting Oban, so Oban can never dequeue a job
      # against an unregistered schema. No paused queues, no resume loop.
      Barkpark.SchemaBootstrap,
      # VOLATILE Indx retriever-seam subsystem (was Auth/Monitor/Recovery flat).
      # Indx is NOT a registered plugin, so these are declared statically. Now
      # wrapped so an Indx crash-loop degrades (engine=indx falls back to
      # Postgres) instead of escalating to a whole-app shutdown. Same slot →
      # still starts after SchemaBootstrap and BEFORE Oban (whose :indx queue
      # jobs call Auth.token/0); internal order Auth→Monitor→Recovery preserved.
      Barkpark.Plugins.Indx.Supervisor,
      {Oban, oban_config},
      {DNSCluster, query: Application.get_env(:barkpark, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Barkpark.PubSub},
      # Sheets M1 collaborative-session subsystem (was SessionRegistry +
      # SessionSupervisor + ReplayRing flat). CORE, plugin-independent
      # (fresh-install invariant). Wrapped for domain isolation; positioned
      # after PubSub (delta broadcasts) + Repo (load/persist), as before.
      Barkpark.Plugins.Sheets.Supervisor,
      # Studio Claude-chat runtime subsystem (was the two registries +
      # RuntimeSupervisor + Notifier flat). Wrapped for domain isolation;
      # positioned after PubSub (Recorders rebroadcast frames on it), as before.
      Barkpark.StudioChat.Supervisor,
      BarkparkWeb.Presence,
      {Task.Supervisor, name: Barkpark.TaskSupervisor},
      # Boot-time collector for workspace-bundle temp files a SIGKILLed BEAM
      # could not clean up after itself (PDS-D210). The export engine's
      # try/after covers raises and disconnects, but not the OOM killer — and
      # the OOM killer is precisely the scenario the disk spill exists to
      # survive, so a crashed BEAM's leftovers are collected by its successor.
      # Placed BEFORE the Endpoint so stale bundles are reclaimed before this
      # node can serve a new export into the same directory, and AFTER
      # Barkpark.TaskSupervisor because the sweep's bounded `ps` liveness
      # probe runs on it (task-felix-w21-bl-janitor-ps-bound) — it needs no
      # Repo (pure filesystem work), but the supervisor must exist. A
      # `:temporary` Task: it runs once, never restarts, and its own moduledoc
      # explains why the sweep is boot-only rather than periodic.
      Barkpark.Tenancy.WorkspaceBundle.Janitor,
      # Dedicated supervisor for outbound webhook/media deliveries. The
      # generic TaskSupervisor has max_children: :infinity, so a webhook
      # storm or a slow endpoint (each child sleeps in-task on retry
      # backoff + a 10s per-attempt HTTP timeout) accumulates thousands of
      # long-lived processes → unbounded memory. Deliveries fan out through
      # Task.Supervisor.async_stream_nolink on THIS supervisor, which
      # backpressures beyond :webhook_delivery_concurrency (queues, never
      # drops) instead of the old start_child-per-webhook fan-out.
      {Task.Supervisor, name: Barkpark.WebhookDeliverySupervisor}
    ] ++
      sync_children ++
      self_update_children ++
      [
        # Self-update EXECUTOR (Barkpark.SelfUpdate.Runner). ALWAYS in the
        # tree — an idle GenServer is free — but every trigger is gated by
        # its own `enabled` config (fail-closed OFF unless prod sets
        # BARKPARK_SELF_UPDATE_APPLY=1), so with the defaults it can never
        # execute anything. Unconditional so the admin endpoint degrades to
        # a clean "feature_not_configured" instead of a dead-process call.
        Barkpark.SelfUpdate.Runner,
        # Site-deploy EXECUTOR (Barkpark.Sites.DeployRunner). Same always-in-the-
        # tree, fail-closed-on-trigger contract as the self-update Runner above
        # (OFF unless BARKPARK_SITE_DEPLOY_APPLY=1), but a SEPARATE process: its
        # single-flight slot is per-site-slug, so a box auto-deploying itself on
        # merge can never 409 a site deploy that has nothing to do with it.
        Barkpark.Sites.DeployRunner,
        # Start to serve requests, typically the last entry
        BarkparkWeb.Endpoint
      ]
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
