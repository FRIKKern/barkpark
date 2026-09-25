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

    # Same FAIL-CLOSED contract, the gh-9531 RESIDUALS
    # (task-eeabfd9bf3ed8371): two more HOST deployment values that used to be
    # compile-time module attributes. A malformed ANTHROPIC_API_URL would
    # otherwise first surface as a judge/title call that quietly never runs —
    # both paths swallow every error by design. Unset env keeps the historical
    # literals, so this is a no-op for every deployment that has not opted in.
    #
    # The third residual, ONIX_DATASET_HOST, is NOT checked here: it belongs to
    # a REMOVABLE plugin, and naming `Barkpark.Plugins.OnixEdit` from the host
    # would break the fresh-install invariant (plugin.ex §Fresh-install
    # invariant — the host must not reach a removable plugin on a path that
    # runs while it is disabled). OnixEdit resolves it from its OWN
    # `register_workers/1` boot child instead, so it still refuses the node on
    # a malformed value wherever the plugin is enabled, and simply does not run
    # where it is absent. The task-dedup judge's endpoint check follows the
    # same shape (task-6325dacb0e233d75): it runs from the Tasks plugin's own
    # `register_workers/1` boot child. The HOST value it validates,
    # `:anthropic_api_url`, is still refused here at boot through the title
    # check below, which reads the same key with the same validation.
    _ = Barkpark.StudioChat.Titles.endpoint()

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

    # Same boot-warning mechanism, third condition (task-c7e2b87f1bbca815): the
    # INSTANCE-OPERATOR allowlist. Unset means legacy — the `admin` permission
    # alone still opens the seven instance-global route groups (run-secret
    # reveal, the instance-wide plugin-settings record, self-update/rollback/
    # site-deploy, status incidents, playground provisioning, bundle import) to
    # any admin-permissioned token, including one seated in exactly one
    # workspace. WARNS rather than raising for the same reason the mailer check
    # does: a single-tenant self-hosted box is a legitimate shape (its only
    # admin IS the operator), and refusing to boot would break every existing
    # deployment on upgrade. See
    # BarkparkWeb.Plugs.RequirePlatformOperator.warn_if_unset/0.
    _ = BarkparkWeb.Plugs.RequirePlatformOperator.warn_if_unset()

    # The /v1/graph admission-cap slot table, created HERE and nowhere else that
    # matters. It is a CONCURRENCY BOUND, not a cache: the rows are the slots
    # currently held, so the table must outlive every request that holds one.
    # Created lazily from a request process it would be owned by that process
    # and destroyed the moment the request finished — under exactly the
    # concurrent load the cap exists to shed, in-flight slots would be forgotten
    # (the bound silently resets) and a sibling's `:ets.insert`/`:ets.delete`
    # would raise ArgumentError, i.e. a 500 from the guard against 500s. This
    # process lives as long as the application, so the bound does too.
    # CORE, not the Tasks plugin: `GET /v1/graph` is core-mounted and must serve
    # with every plugin off (see `Barkpark.Content.Graph.CorpusSlots`).
    Barkpark.Content.Graph.CorpusSlots.init()

    # Goal barkpark-G1, task s2: ask the Plugins.Registry for every plugin-
    # contributed child spec BEFORE constructing the supervision tree. The
    # call is a pure function — Registry.collect_workers/1 does NOT depend
    # on the Registry GenServer being alive, which is essential because the
    # Registry process is itself a child below. See its moduledoc for the
    # source-of-truth precedence (Application env wins; otherwise sync disk
    # walk of priv/plugins). Per the locked Q1 grill decision, topology is
    # compile-time static — hot-reload is out of scope for v1.
    plugin_children = Barkpark.Plugins.Registry.collect_workers(%{phase: :boot})

    # THE inverted edge-extractor seam — the one and only installer.
    # `Barkpark.Content.Graph`'s drafts fold needs every plugin's projected
    # edges, but `content` is a KERNEL concept and the registry is a FEATURE:
    # the kernel importing the registry is a wrong-direction dependency the
    # boundary gate (tooling/concept-map/boundary.mjs) reports. So the arrow is
    # turned around HERE, at the composition root, which is allowed to know
    # both sides. Content reads `:edge_extractor_collector`; it never names the
    # registry. Unset → core edges only (the fresh-install invariant: a
    # plugin-free host still walks its drafts graph, it just has no plugin
    # edges to add).
    install_edge_extractor_seam()

    # The same inversion for the codelist health roster: `Content.CodelistHealth`
    # reads `:codelist_requirements_collector`; it never names the registry.
    # Unset → an empty roster (the fresh-install invariant: a plugin-free host
    # declares no codelists, so its audit is `:ok`, not a crash).
    install_codelist_requirements_seam()

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

    children =
      child_specs(plugin_children, oban_config, sync_children, self_update_children, boot_mode())

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
        # NOT in `:one_shot`: a backfill that is not serving anything must not
        # read the shares table, and must never print a banner announcing LAN
        # readers this node does not expose (it has no Endpoint). Skipping the
        # refresh also leaves the live `:shares` list untouched for the node
        # that IS serving on the same box.
        if boot_mode() != :one_shot do
          Barkpark.Sharing.refresh()

          # P1c LAN-sharing banner. DEFAULT-OFF: with no shares (env OR stored),
          # this is a no-op (active?/0 is false) and nothing is logged. When
          # active, warn loudly with every reachable reader URL so the operator
          # knows the box is now exposed on the local network.
          log_sharing_banner()
        end

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

  @typedoc """
  How much of the tree `start/2` puts up. See `child_specs/5`.
  """
  @type boot_mode :: :full | :seed | :one_shot

  @boot_modes [:full, :seed, :one_shot]

  @doc """
  The boot mode for THIS node, read from `:barkpark, :boot_mode` (default
  `:full`).

  A one-shot `bin/barkpark eval` sets it BEFORE `Application.ensure_all_started/1`
  (see `Barkpark.Release.seed_boot!/0`); nothing in `config/*.exs` sets it, so
  every ordinary boot — `bin/barkpark start`, `mix phx.server`, `mix test` —
  takes the `:full` default. Raises on an unknown value rather than silently
  falling back: a typo'd mode that quietly booted the FULL tree would bind a
  listener on a box that asked not to, which is the defect this seam exists to
  prevent.
  """
  @spec boot_mode() :: boot_mode()
  def boot_mode do
    case Application.get_env(:barkpark, :boot_mode, :full) do
      mode when mode in @boot_modes ->
        mode

      other ->
        raise ArgumentError,
              "unknown :barkpark, :boot_mode #{inspect(other)} " <>
                "(expected one of #{inspect(@boot_modes)})"
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
      The Sheets plugin's session supervisor is one of those children now: it
      starts only when the Sheets plugin is loaded (task-c10be8a9ad8f0145).
    * `Barkpark.Plugins.Indx.Supervisor` wraps Auth/Monitor/Recovery.
    * The studio-chat supervisor wraps the studio-chat registries/runtime/
      notifier.

  Ordering invariants held: Repo before everything that queries it; Registry
  before plugin workers; PubSub before the plugin tier, the studio-chat tier
  and the Endpoint; SchemaBootstrap after Repo+Registry and BEFORE Oban;
  Indx (Auth→Recovery) before Oban; Endpoint last.
  """
  @spec child_specs(list(), keyword(), list(), list()) :: [
          Supervisor.child_spec() | {module(), term()} | module()
        ]
  def child_specs(plugin_children, oban_config, sync_children, self_update_children),
    do: child_specs(plugin_children, oban_config, sync_children, self_update_children, :full)

  @doc """
  The same list, narrowed for a BOOT MODE.

    * `:full` — verbatim `child_specs/4`; what `bin/barkpark start` boots.
    * `:seed` — the canonical list MINUS `BarkparkWeb.Endpoint`, with the `Oban`
      child started INERT (`queues: false, plugins: false`).
    * `:one_shot` — the canonical list MINUS `BarkparkWeb.Endpoint` and `Oban`,
      with NO plugin boot workers, NO sync children and NO self-update children
      (the three list ARGUMENTS are ignored, not filtered). What
      `Barkpark.OneShot.boot!/0` puts up for an operator one-shot — see below.

  `:seed` exists for `Barkpark.Release.seed/0`. The seed bodies are ordinary
  application code — `Barkpark.Seeds.run/0` needs the live `Plugins.Registry`
  populated by the `SchemaBootstrap` boot child, PubSub, `Barkpark.Vault`, the
  validation registries, and an Oban instance (`Oban.insert/1` raises without
  one). So the seed eval cannot run repo-only. What it must NOT do is bind a
  listener or drain live queues: `bin/barkpark eval` runs on a box whose real
  node may already be serving, and an inert Oban still ACCEPTS inserts (the
  seeded jobs stay queued for the serving node) while starting no producer and
  no plugin (no Cron, no Pruner, no Lifeline) — it enqueues, it never dequeues.

  DERIVED, never hand-picked: the `:seed` clause filters the `:full` list, so a
  child added above appears in seed mode too and boot ORDER is preserved
  verbatim. Hand-picking a subset here would fork the order from the canonical
  list and silently change what a seeded instance contains (charter D9).

  `:one_shot` exists for the operator one-shot MIX TASKS —
  `mix barkpark.edges.backfill`, `barkpark.media.backfill`,
  `barkpark.paper.backfill_block_ids`, `barkpark.paper.composition_migrate` —
  which used to call `Mix.Task.run("app.start")` and therefore booted the FULL
  tree with whatever runtime env they inherited. On guerrilla, 2026-09-02
  08:28–08:35Z, that meant `PHX_SERVER` was set and the backfill's endpoint
  tried to bind the LIVE slot's port: `Running BarkparkWeb.Endpoint with Bandit
  1.12.0 at http failed, port 4001 already in use`, and the run died before the
  backfill started. The same boot brought up a SECOND Oban draining the live
  queues, the Github `DrainWorker` (which raised an `Oban.Registry` error before
  Oban was up), and `SchemaBootstrap`'s onixedit codelist seeders (one hit
  `ERROR 57014 query_canceled` under the 60 s statement_timeout).

  Why the three list arguments are IGNORED rather than filtered: `plugin_children`
  are pollers/drainers/DrainWorkers — a backfill needs none of them, and the one
  plugin contribution it DOES need (the edge extractors) is a PURE resolver-chain
  call off `Barkpark.Plugins.Registry`, which stays in the tree. `sync_children`
  and `self_update_children` are the LAN/pull sync and the upstream release poller.
  Both are dormant-by-default anyway; a one-shot never wants either.

  Why `Oban` is dropped OUTRIGHT here where `:seed` keeps it inert: a seed WRITES
  documents through `Content.apply_mutations`, which calls `Oban.insert/1`. A
  backfill sweep does not — `Projector.rebuild_scope/3` is a DELETE-then-
  `Content.add_edges` transaction with no job insert on the path. Dropping the
  child is what makes "this one-shot cannot touch the live queues" a property of
  the tree rather than a promise about its configuration.

  Why `Barkpark.SchemaBootstrap` STAYS, when the incident names its codelist
  seeders: MEASURED, not reasoned. Dropping it took the dev corpus's projected
  edge count from 962 to ZERO — the schema registration it performs is what the
  extractor chain resolves reference fields against, and a one-shot that boots
  without it writes an empty graph while exiting 0. Only the expensive half is
  suppressed, through the gate the module already has:
  `Barkpark.SchemaBootstrap` skips `run_all_codelist_seeders/0` +
  `CodelistHealth.log_boot_audit/0` in `:one_shot` mode, which is the
  `ERROR 57014 query_canceled` the incident actually hit.
  """
  @spec child_specs(list(), keyword(), list(), list(), boot_mode()) :: [
          Supervisor.child_spec() | {module(), term()} | module()
        ]
  def child_specs(_plugin_children, oban_config, _sync_children, _self_update_children, :one_shot) do
    []
    |> child_specs(oban_config, [], [], :full)
    |> Enum.reject(&one_shot_excluded?/1)
  end

  def child_specs(plugin_children, oban_config, sync_children, self_update_children, :seed) do
    plugin_children
    |> child_specs(oban_config, sync_children, self_update_children, :full)
    |> Enum.reject(&(&1 == BarkparkWeb.Endpoint))
    |> Enum.map(fn
      {Oban, config} -> {Oban, Keyword.merge(config, queues: false, plugins: false)}
      other -> other
    end)
  end

  def child_specs(plugin_children, oban_config, sync_children, self_update_children, :full)
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
      {DNSCluster, query: Application.get_env(:barkpark, :dns_cluster_query) || :ignore},
      # PubSub starts BEFORE the plugin tier (task-c10be8a9ad8f0145). The Sheets
      # plugin's session supervisor is a plugin boot child now, and its sessions
      # broadcast deltas on PubSub; with PubSub here, every plugin boot child
      # starts after it, which is the order the static Sheets tier had. Nothing
      # above needs PubSub to be absent, and nothing started later loses it.
      {Phoenix.PubSub, name: Barkpark.PubSub},
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
      # Admission control for the export route (PDS-D719). A permanent
      # GenServer owning one small ETS table — it holds no connections, no
      # files and no timers, so an idle instance is free. Placed immediately
      # after the Janitor (its moduledoc cites this guard's ABSENCE when it
      # justifies the pid-liveness sidecar, and the two are read together) and
      # BEFORE the Endpoint, because the first request this node serves must
      # already find the guard alive: `acquire/1` degrades to "admit
      # unguarded" when it is not, which is the correct posture for a
      # contention remedy and the wrong one to rely on at boot.
      Barkpark.Tenancy.WorkspaceBundle.SingleFlight,
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

  # The `:one_shot` exclusion predicate, spelled out beside the clause that uses
  # it. Everything NOT named here survives, so a child added to the `:full` list
  # above is present in one-shot mode too (the same derived-not-hand-picked rule
  # `:seed` follows) — the list names what a one-shot must NOT do, and each entry
  # carries the incident that put it there.
  defp one_shot_excluded?(BarkparkWeb.Endpoint), do: true
  defp one_shot_excluded?({Oban, _config}), do: true
  defp one_shot_excluded?(_other), do: false

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

  # Installs the plugin edge-extractor fan-out into the key
  # `Barkpark.Content.Graph` reads. An explicit `config :barkpark,
  # :edge_extractor_collector, …` WINS — an operator (or a test) that has
  # already wired the seam is not overwritten at boot, which is what makes the
  # seam substitutable rather than merely indirect.
  defp install_edge_extractor_seam do
    if is_nil(Application.get_env(:barkpark, :edge_extractor_collector)) do
      Application.put_env(
        :barkpark,
        :edge_extractor_collector,
        &Barkpark.Plugins.Registry.collect_edge_extractors/1
      )
    end

    :ok
  end

  # Installs the plugin codelist-roster fan-out into the key
  # `Barkpark.Content.CodelistHealth` reads. As with the edge-extractor seam, an
  # explicit `config :barkpark, :codelist_requirements_collector, …` WINS — the
  # seam is substitutable, not merely indirect.
  defp install_codelist_requirements_seam do
    if is_nil(Application.get_env(:barkpark, :codelist_requirements_collector)) do
      Application.put_env(
        :barkpark,
        :codelist_requirements_collector,
        &Barkpark.Plugins.Registry.collect_codelist_requirements/0
      )
    end

    :ok
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
