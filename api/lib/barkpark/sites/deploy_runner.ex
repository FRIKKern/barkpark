defmodule Barkpark.Sites.DeployRunner do
  @moduledoc """
  Site-deploy EXECUTOR — the on-box process that actually runs
  `deploy/site-deploy.sh` for a content-bound site. This is the remote-exec seam
  the control plane reaches through `POST /v1/admin/site-deploy` (charter D22):
  an authenticated admin HTTP call on the instance's OWN API, turned into a real
  OS process here.

  ## Observer + finalizer, NOT a Port owner (search-template D29/D31/D32/D33)

  Guerrilla auto-deploys itself on every `api/**` merge, and the post-merge
  `barkpark.service` restart kills the BEAM. When this GenServer OWNED the build
  as a linked `Port`, that restart killed every in-flight site build with it — a
  grenade every few minutes on a busy day. Honest failure held (fail-closed, a
  CP retry hint, the reaper re-drove), but honest failure is not perfection.

  So on a systemd box the build no longer hangs off this process. `trigger/1`
  launches the WHOLE engine as a TRANSIENT systemd unit
  (`systemd-run --unit=bp-site-build-<slug>-<id>-<ts> …`) — a SIBLING cgroup,
  not a BEAM child. When `barkpark.service` restarts, that unit keeps running:
  its `npm ci`, its per-slug flock, its symlink swap all survive. This GenServer
  becomes an OBSERVER (it reads the unit's durable status + log files) and a
  FINALIZER (it force-stops a unit that outlives its deadline, and reconstructs
  a terminal `:done` once the unit is gone). On `init/1` it SCANS the run-state
  dir and RE-ATTACHES to every unit still `systemctl is-active` — re-arming the
  deadline and re-claiming the per-slug single-flight slot so a same-slug
  re-trigger still 409s across a restart.

  When `systemd-run` is absent (dev, macOS, CI) it FALLS BACK to the classic
  in-process `Port` path below, so local tests exercise the same lifecycle
  without systemd.

  ## Why this is NOT `Barkpark.SelfUpdate.Runner` (charter D23)

  The self-update Runner is the right SHAPE (supervised GenServer, fail-closed
  behind an apply flag, bounded log, deadline watchdog) but the wrong ENGINE for
  a site deploy, on three counts that each break a live deploy rather than
  merely offend taste:

    * **Compile-time command.** Its command comes from `config` — it can never
      carry a per-request `build_id`. Every site deploy names a different build.
    * **One GLOBAL run slot.** Self-update + rollback share it, and guerrilla
      auto-deploys on every merge — a site deploy racing the box's own
      post-merge self-update would get a bare `already_running` for a run that
      has nothing to do with it. Here the single-flight slot is **per slug**:
      two different sites deploy concurrently; the same site twice is a 409.
    * **A 500-line log ring that evicts the oldest.** A real `npm ci` prints far
      more than 500 lines, so the early `PLAN:`/`BUILD:` lines are gone before
      an orchestrator ever polls. Hence `stages` — parsed out of the engine's
      `BPSTAGE` lines and retained **separately from, and immune to,** the log
      ring. The raw log stays a bounded tail; the six stages never evict.

  ## The child's environment (charter D24)

  In BOTH paths the master encryption keys and stale ambient build vars are kept
  OUT of the build, and the per-site content binding comes only from the
  request. The mechanism differs:

    * **systemd unit.** A transient unit starts from a CLEAN environment — it
      does NOT inherit the BEAM's env, so `BARKPARK_KEK`/`BARKPARK_CLOAK_KEY`
      never reach it in the first place. The build's env is supplied by a
      per-run **0600 `EnvironmentFile`** (never `--setenv`/argv, so no secret
      lands on a `ps`-visible command line): every `BUILD_ALLOW` key SET from
      the request or simply omitted, plus `PATH` (asdf's `npm` shims) and the
      status/log file paths. The file is unlinked once the run finalizes.
    * **`Port` fallback.** `Port.open` with no `env:` gives the child the BEAM's
      FULL environment. Erlang's `env` option only ADDS/OVERRIDES; the ONLY way
      to REMOVE a var is `{~c"NAME", false}`. So `BARKPARK_KEK`/
      `BARKPARK_CLOAK_KEY` are removed with the `false` form and every
      `BUILD_ALLOW` var is set-from-request-or-removed. `PATH` is preserved.

  Both derive their KEY→value decision from the SAME `resolved_build_vars/1`
  (the allow-list is never forked).

  ## Fail-closed

  Always supervised (an idle GenServer is free), but every trigger is gated by
  `enabled?/0`, which ships OFF in config.exs and is only flipped on in prod by
  `BARKPARK_SITE_DEPLOY_APPLY=1`. With the defaults this process can execute
  nothing at all, and the admin endpoint degrades to a clean 503.

  Never-crash contract: `trigger/1` and `status/1` never raise — a dead process
  degrades to `{:error, :disabled}` / an idle status map, and a command that
  cannot start, dies abnormally, or outlives the deadline lands as a `:done`
  state with a non-zero exit code and an honest `failure_reason`.
  """

  use GenServer

  require Logger

  alias Barkpark.Sites.DeployRequest
  alias Barkpark.Sites.Provisioner

  @default_command {"bash", ["deploy/site-deploy.sh"]}
  @default_rollback_command {"bash", ["deploy/site-deploy.sh", "--rollback"]}
  # The node-slot SSR runtime target (charter D63): the SAME 6-stage state
  # machine, but the artifact is a long-running node process, so it drives a
  # SEPARATE engine script (`deploy/site-deploy-node.sh`) that boots + health-
  # probes + Caddy-upstream-flips a node port instead of swapping a symlink.
  @default_node_command {"bash", ["deploy/site-deploy-node.sh"]}
  @default_node_rollback_command {"bash", ["deploy/site-deploy-node.sh", "--rollback"]}
  # Teardown (the inverse of a spawn): disarm the Caddy route + delete the tree
  # (node also stops the slots). The engine emits no BPSTAGE — success is a
  # `TORN_DOWN=<slug>` line in the durable log, finalized like a rollback.
  @default_teardown_command {"bash", ["deploy/site-deploy.sh", "--teardown"]}
  @default_node_teardown_command {"bash", ["deploy/site-deploy-node.sh", "--teardown"]}

  # The transient-unit launcher + the status/liveness probes. All config-
  # injectable so a test on a systemd-less host can stub the whole path.
  @default_systemd_run {"systemd-run", []}
  @default_is_active {"systemctl", ["is-active"]}
  @default_systemctl_stop {"systemctl", ["stop"]}
  # Per-unit resource caps on the SIBLING cgroup (the inner `systemd-run --scope`
  # build cap is retired — stw6-engine-file-contract; the OUTER unit carries it).
  @default_memory_max "1500M"
  @default_cpu_quota "150%"

  @default_max_log_lines 500
  # 30 min — an `npm ci` + build on a small box, with headroom. A run that
  # outlives it is force-closed so a wedged unit/port can't hold the slug's slot
  # until the next BEAM restart.
  @default_run_deadline_ms 1_800_000

  # Hard deadline for a SYNCHRONOUS control-plane `System.cmd` (systemd-run,
  # `systemctl is-active`, `systemctl stop`). These run INSIDE the singleton
  # GenServer — a hung systemd/systemctl (a wedged unit, a stuck D-Bus) would
  # freeze {:trigger}/{:status} for every slug, and the {:unit_deadline}
  # watchdog's own stop cannot be rescued by safe_call. 15s is generous for a
  # local systemctl round-trip; a call that outlives it is force-killed and its
  # caller degrades (never crashes). Distinct from @default_run_deadline_ms,
  # which bounds the BUILD, not the ctl call that launches/reaps it.
  @default_ctl_cmd_timeout_ms 15_000

  # After a launch, systemd may report the unit `inactive` for a beat before it
  # transitions to `active`. Do NOT serve `:done` off an empty fold inside this
  # grace — an observer that flickers to done between spawn and start would race
  # the CP into a false failure.
  @spawn_grace_ms 3_000

  # Finished runs stay queryable (the orchestrator polls AFTER the exit), but not
  # forever — keep the newest N slugs, evicting finished ones first.
  @max_tracked_runs 32
  # How many trailing meaningful lines a failure_reason carries. The engine's own
  # "BUILD failed …" line is usually last; the REAL cause (npm's 401, the HEALTH
  # marker miss) is the line or two above it.
  @reason_lines 3

  # `BPSTAGE name=<STAGE> status=<STATUS> build_id=<ID> [detail="…"]` — emitted by
  # the engine at every state-machine boundary, to stdout AND (when the transient
  # unit sets it) appended to the durable status file. Both fields are whitelisted
  # below; a line that does not match is just log.
  #
  # `detail` is the REASON and it is load-bearing: the engine hangs npm's real
  # error (`FATAL: 401 Unauthorized …`) and HEALTH's marker miss off the terminal
  # stage line, and the control plane + `bp cloud site` render it as the failed
  # stage's message. Dropping it here does not fail loudly — it silently degrades
  # every failure to a canned "the build failed", which is precisely the dishonest
  # status this seam exists to prevent. build_id is `\S*` (not `\S+`) because the
  # engine emits `build_id=` empty on a PLAN that has not resolved one yet; `\S+`
  # would refuse the empty value and then swallow the detail with it.
  @stage_re ~r/\bBPSTAGE\s+name=([A-Za-z_]+)\s+status=([a-z]+)(?:\s+build_id=(\S*))?(?:\s+detail="([^"]*)")?/
  @stage_names ~w(PLAN BUILD STAGE HEALTH SWITCH RETIRE)
  @stage_statuses ~w(started ok skipped noop failed)

  # systemctl is-active states that mean the build is STILL running. Everything
  # else (inactive / failed / deactivating / unknown / "") is terminal or gone.
  @active_states ~w(active activating reloading)

  # The box's master encryption keys — REMOVED from the Port child (see moduledoc).
  @scrub_env ~w(BARKPARK_KEK BARKPARK_CLOAK_KEY)
  # Set-from-request-or-remove. Superset of DeployRequest.allowed_env_keys/0: the
  # engine derives BARKPARK_BUILD_ID / BARKPARK_CONTENT_REV itself from BUILD_ID /
  # CONTENT_REV, but they are in its BUILD_ALLOW list, so an ambient value could
  # still shadow — remove them too and let the engine set them.
  @build_env_keys DeployRequest.allowed_env_keys() ++
                    ~w(BARKPARK_BUILD_ID BARKPARK_CONTENT_REV)

  # ── public API ──────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Whether site deploys may execute on this instance. Fail-closed: config.exs
  ships `enabled: false`; prod's runtime.exs flips it on only when
  `BARKPARK_SITE_DEPLOY_APPLY=1`.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, false) == true

  @doc "The `Barkpark.Sites.DeployRunner` config keyword list (see config.exs)."
  @spec config() :: keyword()
  def config, do: Application.get_env(:barkpark, __MODULE__, [])

  @doc """
  Start a site deploy (or rollback) for a VALIDATED request. Single-flight PER
  SLUG — a second run for the same slug while one is in flight returns
  `{:error, :already_running}`; a different slug proceeds. Never raises.
  """
  @spec trigger(DeployRequest.t()) ::
          {:ok, :started} | {:error, :already_running | :disabled | :start_failed}
  def trigger(%DeployRequest{} = req), do: safe_call({:trigger, req}, {:error, :disabled})

  @doc """
  The run status for `slug`: `state` (`:idle` | `:running` | `:done`), the parsed
  `stages` (never evicted), `exit_code`, an honest `failure_reason`, the bounded
  `log` tail (oldest line first), and timestamps. A slug that has never run
  reports `:idle`. On a systemd box the status is RECONSTRUCTED from the transient
  unit's durable status + log files, so it survives a BEAM restart. Never raises.
  """
  @spec status(String.t()) :: map()
  def status(slug) when is_binary(slug),
    do: safe_call({:status, slug}, idle_status(slug))

  @doc "Whether a run for `slug` is currently in flight."
  @spec running?(String.t()) :: boolean()
  def running?(slug) when is_binary(slug), do: match?(%{state: :running}, status(slug))

  defp safe_call(msg, fallback) do
    case Process.whereis(__MODULE__) do
      nil ->
        fallback

      pid ->
        try do
          GenServer.call(pid, msg)
        catch
          # Runner died between whereis and call (or timed out) — degrade, never
          # propagate the exit to the caller.
          :exit, _reason -> fallback
        end
    end
  end

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Ports (fallback path) are linked to this process; trap so an abnormal port
    # death becomes a :done run instead of taking the Runner (and every other
    # slug) down.
    Process.flag(:trap_exit, true)
    state = %{runs: %{}, ports: %{}, units: %{}, timers: %{}}
    {:ok, reattach_units(state)}
  end

  @impl true
  def handle_call({:trigger, %DeployRequest{} = req}, _from, state) do
    cond do
      not enabled?() ->
        {:reply, {:error, :disabled}, state}

      true ->
        state = drop_stale(state, req.slug)

        if running_slug?(state, req.slug) do
          {:reply, {:error, :already_running}, state}
        else
          start_run(state, req)
        end
    end
  end

  def handle_call({:status, slug}, _from, state) do
    cond do
      # A live Port-mode run, or a cached finalized systemd render.
      Map.has_key?(state.runs, slug) ->
        {:reply, render_run(Map.fetch!(state.runs, slug)), state}

      # A tracked in-flight unit — reconstruct from its durable files.
      Map.has_key?(state.units, slug) ->
        observe_unit(state, slug)

      # No live tracking, but a manifest may survive on disk (a terminal run, or
      # one this process never launched — e.g. straight after a restart).
      manifest = load_manifest_for(slug) ->
        finalize_from_disk(state, manifest)

      true ->
        {:reply, idle_status(slug), state}
    end
  end

  # ── Port-mode async messages (fallback path only) ────────────────────────

  @impl true
  def handle_info({port, {:data, {_eol_or_noeol, line}}}, state) do
    {:noreply, update_run(state, port, &ingest_line(&1, line))}
  end

  def handle_info({port, {:exit_status, code}}, state) do
    {:noreply,
     state
     |> update_run(port, &finish_run(&1, code))
     |> release_port(port)}
  end

  # Abnormal port death without an exit_status — record a failure, never crash.
  def handle_info({:EXIT, port, reason}, state) when is_port(port) do
    if Map.has_key?(state.ports, port) do
      {:noreply,
       state
       |> update_run(port, fn run ->
         run
         |> ingest_line("[runner] deploy port closed: #{inspect(reason)}")
         |> finish_run(-1)
       end)
       |> release_port(port)}
    else
      {:noreply, state}
    end
  end

  # Deadline watchdog for a Port-mode run that is STILL live on this port. A stale
  # deadline from an already-finished run finds no port entry and falls through.
  def handle_info({:run_deadline, port}, state) do
    if Map.has_key?(state.ports, port) do
      _ = close_port(port)
      ms = run_deadline_ms()

      {:noreply,
       state
       |> update_run(port, fn run ->
         run
         |> ingest_line("[runner] run exceeded #{ms}ms deadline — force-closed")
         |> finish_run(-2)
       end)
       |> release_port(port)}
    else
      {:noreply, state}
    end
  end

  # Deadline watchdog for a systemd transient unit. If the unit is still alive,
  # stop it and finalize a `:done` run with the deadline reason so the slug's slot
  # can never wedge until the next restart.
  def handle_info({:unit_deadline, slug}, state) do
    case Map.fetch(state.units, slug) do
      {:ok, manifest} ->
        _ = systemctl_stop(manifest.unit_name)
        ms = run_deadline_ms()

        render =
          manifest
          |> reconstruct(:terminal)
          |> Map.merge(%{
            state: :done,
            exit_code: -2,
            failure_reason: exit_label(-2) <> " (#{ms}ms)"
          })

        {:noreply, cache_and_cleanup(state, slug, manifest, render)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── run lifecycle ───────────────────────────────────────────────────────

  # Per-slug single-flight. Port mode: a live in-memory run. systemd mode: a
  # tracked unit that `systemctl is-active` still reports running.
  defp running_slug?(state, slug) do
    cond do
      match?({:ok, %{state: :running}}, Map.fetch(state.runs, slug)) -> true
      match?({:ok, _}, Map.fetch(state.units, slug)) -> unit_running?(state, slug)
      true -> false
    end
  end

  defp unit_running?(state, slug) do
    case Map.fetch(state.units, slug) do
      {:ok, manifest} -> is_active(manifest.unit_name) in @active_states
      :error -> false
    end
  end

  # A finished/terminal record for this slug must not block a fresh trigger: drop
  # any cached render, and drop a tracked unit that is no longer active (freeing
  # the single-flight slot + its deadline timer + its secret env file).
  defp drop_stale(state, slug) do
    state =
      case Map.fetch(state.runs, slug) do
        {:ok, %{state: :running}} -> state
        {:ok, _finished} -> %{state | runs: Map.delete(state.runs, slug)}
        :error -> state
      end

    case Map.fetch(state.units, slug) do
      {:ok, manifest} ->
        if is_active(manifest.unit_name) in @active_states do
          state
        else
          _ = unlink_env(manifest)
          cancel_timer(state, slug) |> Map.update!(:units, &Map.delete(&1, slug))
        end

      :error ->
        state
    end
  end

  defp start_run(state, %DeployRequest{} = req) do
    # PROVISION FIRST (charter D33/D34): a content-bound site has no repo to check
    # out, so its source must be materialized from the shipped template BEFORE the
    # build starts — otherwise the engine walks PLAN and dies at BUILD with `no
    # site source dir …/src` (exit 10). Deploy only; a rollback is a symlink
    # repoint whose source is already there (Provisioner no-ops it). Fail-closed:
    # a provision failure short-circuits EXACTLY like a spawn failure — no build,
    # no run recorded, `{:error, :start_failed}`.
    case Provisioner.provision(req) do
      :ok ->
        spawn_run(state, req)

      {:error, {:provision_failed, reason}} ->
        Logger.warning(
          "[site-deploy] provision failed for #{inspect(req.slug)} — deploy not started: #{inspect(reason)}"
        )

        {:reply, {:error, :start_failed}, state}
    end
  end

  # The launch fork: a systemd box gets a SURVIVING transient unit; anywhere
  # `systemd-run` is absent falls back to the in-process Port.
  defp spawn_run(state, %DeployRequest{} = req) do
    case runner_mode() do
      :systemd -> launch_unit(state, req)
      :port -> open_port_and_record(state, req)
    end
  end

  # `:auto` (the default) resolves to `:systemd` only when `systemd-run` is
  # actually on the box; test/dev pins `:port` (config/test.exs) so the classic
  # Port lifecycle is exercised without systemd. An explicit `:systemd`/`:port`
  # is honored verbatim (tests stub the launcher + probes).
  defp runner_mode do
    case Keyword.get(config(), :runner_mode, :auto) do
      :systemd -> :systemd
      :port -> :port
      _auto -> if systemd_run_exe(), do: :systemd, else: :port
    end
  end

  defp systemd_run_exe do
    {exe, _prefix} = Keyword.get(config(), :systemd_run_command, @default_systemd_run)
    System.find_executable(exe)
  end

  # ── systemd transient-unit path (observer + finalizer) ────────────────────

  defp launch_unit(state, %DeployRequest{} = req) do
    dir = ensure_run_state_dir()
    unit = unit_name(req)
    status_file = Path.join(dir, "#{req.slug}.status")
    log_file = Path.join(dir, "#{req.slug}.log")
    env_file = Path.join(dir, "#{req.slug}.env")

    manifest = %{
      slug: req.slug,
      build_id: req.build_id,
      content_rev: req.content_rev,
      mode: req.mode,
      runtime_target: req.runtime_target,
      unit_name: unit,
      status_file: status_file,
      log_file: log_file,
      build_env_file: env_file,
      started_at: DateTime.utc_now()
    }

    with :ok <- write_env_file(env_file, req, status_file, log_file),
         :ok <- fresh_run_files([status_file, log_file]),
         :ok <- write_manifest(dir, manifest),
         :ok <- systemd_run(req, unit, env_file) do
      state =
        state
        |> Map.update!(:units, &Map.put(&1, req.slug, manifest))
        |> Map.update!(:runs, &(&1 |> Map.delete(req.slug) |> prune_runs()))
        |> arm_unit_deadline(req.slug, run_deadline_ms())

      _ = prune_run_state_dir(dir)
      {:reply, {:ok, :started}, state}
    else
      {:error, reason} ->
        Logger.warning(
          "[site-deploy] unit launch failed for #{inspect(req.slug)}: #{inspect(reason)}"
        )

        _ = unlink_env(manifest)
        {:reply, {:error, :start_failed}, state}
    end
  end

  # A unique, valid systemd unit name. The `.service` suffix pins the type so an
  # internal `.` in a build_id can never be read AS the type; the millisecond
  # stamp keeps a same-build_id redeploy from colliding with a `--collect`-swept
  # predecessor mid-GC. slug + build_id are already charset-validated upstream.
  defp unit_name(%DeployRequest{} = req) do
    tag = req.build_id || "rollback"
    ts = System.system_time(:millisecond)
    "bp-site-build-#{req.slug}-#{tag}-#{ts}.service"
  end

  # The launch itself. `systemd-run` REGISTERS the transient unit and returns
  # immediately — the build runs detached in its own cgroup, so a barkpark.service
  # restart cannot reach it. Every knob is a `--property=` (not argv), the secrets
  # ride the 0600 EnvironmentFile (never `--setenv`), and `--collect` GCs the unit
  # after it exits so a re-run of the same slug never trips "unit already exists".
  defp systemd_run(%DeployRequest{} = req, unit, env_file) do
    {launcher, prefix} = Keyword.get(config(), :systemd_run_command, @default_systemd_run)
    {engine_exe, engine_args} = command_for(req.mode, req.runtime_target)

    case System.find_executable(engine_exe) do
      nil ->
        {:error, {:executable_not_found, engine_exe}}

      engine_path ->
        args =
          prefix ++
            [
              "--unit=#{unit}",
              "--property=WorkingDirectory=#{run_cd()}",
              "--property=EnvironmentFile=#{env_file}",
              "--property=MemoryMax=#{memory_max()}",
              "--property=CPUQuota=#{cpu_quota()}",
              "--collect",
              engine_path
            ] ++ engine_args

        # Bounded: `systemd-run` REGISTERS-and-returns fast, but a wedged D-Bus /
        # a hung systemd would otherwise freeze this synchronous {:trigger} call.
        # A timeout or crash degrades to a start failure — the with-chain in
        # launch_unit maps every {:error, _} to {:error, :start_failed}.
        case bounded_cmd(launcher, args, cd: run_cd(), stderr_to_stdout: true) do
          {:ok, {_out, 0}} -> :ok
          {:ok, {out, code}} -> {:error, {:systemd_run_exit, code, String.slice(out, 0, 500)}}
          :timeout -> {:error, {:systemd_run_timeout, ctl_cmd_timeout_ms()}}
          {:crashed, reason} -> {:error, {:systemd_run_crashed, reason}}
        end
    end
  end

  # Reconstruct + advance an in-flight unit. Reads the durable status fold; if the
  # unit is still active it is `:running`; once it is gone the run is finalized,
  # cached, and its secret env file unlinked (single-flight freed).
  defp observe_unit(state, slug) do
    manifest = Map.fetch!(state.units, slug)

    case is_active(manifest.unit_name) do
      active when active in @active_states ->
        {:reply, reconstruct(manifest, :running), state}

      _terminal ->
        # Grace: right after launch systemd may report `inactive` for a beat
        # before the unit goes active. Do not serve a false `:done` off NO output
        # yet — keep it `:running` until the run shows something or the grace
        # elapses. A DEPLOY announces itself with its first BPSTAGE (the fold); a
        # ROLLBACK emits no BPSTAGE ever (its output is the log), so gating its
        # grace on an empty FOLD would hold every FINISHED rollback `:running`
        # for the whole grace and then mislabel it. `no_output_yet?` is mode-aware.
        if no_output_yet?(manifest) and within_spawn_grace?(manifest) do
          {:reply, reconstruct(manifest, :running), state}
        else
          render = reconstruct(manifest, :terminal)
          {:reply, render, cache_and_cleanup(state, slug, manifest, render)}
        end
    end
  end

  # A manifest found on disk with no live tracking (post-restart terminal, or a
  # unit another process launched). Reconstruct terminal and cache it.
  defp finalize_from_disk(state, manifest) do
    render = reconstruct(manifest, :terminal)
    {:reply, render, cache_and_cleanup(state, manifest.slug, manifest, render)}
  end

  defp cache_and_cleanup(state, slug, manifest, render) do
    _ = unlink_env(manifest)

    state
    |> cancel_timer(slug)
    |> Map.update!(:units, &Map.delete(&1, slug))
    |> Map.update!(:runs, &(&1 |> Map.put(slug, render) |> prune_runs()))
  end

  # ── re-attach on boot (search-template D32) ───────────────────────────────

  # Scan the run-state dir; for every manifest whose unit is STILL active,
  # re-attach as `:running`, re-arm the (remaining) deadline, and re-claim the
  # single-flight slot. A unit that is gone/terminal is left on disk (so a later
  # `status/1` reconstructs its outcome) but its secret env file is unlinked.
  defp reattach_units(state) do
    if runner_mode() == :systemd do
      dir = run_state_dir()

      state =
        dir
        |> list_manifests()
        |> Enum.reduce(state, fn manifest, acc ->
          if is_active(manifest.unit_name) in @active_states do
            remaining = remaining_deadline_ms(manifest)

            acc
            |> Map.update!(:units, &Map.put(&1, manifest.slug, manifest))
            |> arm_unit_deadline(manifest.slug, remaining)
          else
            _ = unlink_env(manifest)
            acc
          end
        end)

      _ = prune_run_state_dir(dir)
      state
    else
      state
    end
  rescue
    # Never let a malformed run dir take down the boot — degrade to a fresh state.
    error ->
      Logger.warning("[site-deploy] unit re-attach skipped: #{inspect(error)}")
      state
  end

  defp remaining_deadline_ms(manifest) do
    elapsed = DateTime.diff(DateTime.utc_now(), manifest.started_at, :millisecond)
    max(run_deadline_ms() - elapsed, 0)
  end

  # ── status-file / log-file reconstruction ─────────────────────────────────

  # Build the status map from the manifest + the unit's durable files. `phase`
  # is `:running` (unit still active) or `:terminal` (unit gone). The stage fold
  # keeps RAW tokens (never pre-normalized — the CP maps `ok`→`done`), first-seen
  # ORDER, latest-wins. build_id is preserved from the manifest (slice 3 needs it).
  defp reconstruct(manifest, phase) do
    log = read_log_tail(manifest.log_file)
    stages = fold_status_file(manifest.status_file, manifest.build_id)

    base = %{
      slug: manifest.slug,
      build_id: manifest.build_id,
      content_rev: manifest.content_rev,
      mode: manifest.mode,
      runtime_target: manifest.runtime_target,
      stages: stages,
      log: log,
      started_at: manifest.started_at
    }

    case phase do
      :running ->
        Map.merge(base, %{state: :running, exit_code: nil, failure_reason: nil, finished_at: nil})

      :terminal ->
        {code, reason} = terminal_outcome(manifest.mode, stages, log)

        Map.merge(base, %{
          state: :done,
          exit_code: code,
          failure_reason: reason,
          build_id: terminal_build_id(manifest, code, log),
          finished_at: file_mtime(manifest.status_file) || DateTime.utc_now()
        })
    end
  end

  # Fold the durable status file (one BPSTAGE line per state boundary) into the
  # stage list, using the SAME upsert as the Port stream so both paths agree.
  defp fold_status_file(path, default_build_id) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.reduce([], fn line, stages ->
          case parse_stage_line(line, default_build_id) do
            {:ok, stage} -> upsert_stage(stages, stage)
            :skip -> stages
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp read_log_tail(path) do
    max = Keyword.get(config(), :max_log_lines, @default_max_log_lines)

    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.take(-max)

      {:error, _} ->
        []
    end
  end

  defp empty_fold?(manifest),
    do: fold_status_file(manifest.status_file, manifest.build_id) == []

  # "No durable output yet" — the signal that a unit reporting `inactive` may just
  # be in the post-launch beat rather than genuinely finished. A DEPLOY announces
  # itself with its first BPSTAGE (the fold); a ROLLBACK emits no BPSTAGE, so for
  # it the signal is an empty LOG. Mode-aware so the deploy grace is byte-unchanged.
  defp no_output_yet?(%{mode: :rollback} = manifest), do: empty_log?(manifest)
  defp no_output_yet?(%{mode: :teardown} = manifest), do: empty_log?(manifest)
  defp no_output_yet?(manifest), do: empty_fold?(manifest)

  defp empty_log?(manifest), do: read_log_tail(manifest.log_file) == []

  defp within_spawn_grace?(manifest),
    do: DateTime.diff(DateTime.utc_now(), manifest.started_at, :millisecond) < @spawn_grace_ms

  # A terminal unit exposes no exit code (`--collect` sweeps it), so the outcome is
  # derived from the durable signals the child left behind. The signal set differs
  # by MODE, and conflating them is the rollback-finalizer bug: a DEPLOY reads its
  # BPSTAGE fold + log tail; a ROLLBACK emits NO BPSTAGE (it is a pointer flip, not
  # a deploy — see `deploy/site-deploy.sh` header: the machine contract is the
  # TARGET_BUILD= line + the typed exits, NOT BPSTAGE), so folding its empty stages
  # through the deploy path mislabels every SUCCESSFUL rollback as `stages == []`
  # → `-1` abnormal death, which the CP then reports as `rollback_failed`.
  defp terminal_outcome(:rollback, _stages, log), do: rollback_outcome(log)
  defp terminal_outcome(:teardown, _stages, log), do: teardown_outcome(log)
  defp terminal_outcome(_deploy, stages, log), do: deploy_outcome(stages, log)

  # TEARDOWN: like a rollback it emits no BPSTAGE — the engine prints a
  # `TORN_DOWN=<slug>` line to the durable log on success (the disarm/rm is
  # idempotent, so there is no typed-failure vocabulary). Its presence is exit 0;
  # a non-empty log without it, or an empty log, is an abnormal end (-1).
  defp teardown_outcome(log) do
    if Enum.any?(log, &String.contains?(&1, "TORN_DOWN=")),
      do: {0, nil},
      else: {-1, terminal_reason(-1, nil, log)}
  end

  # DEPLOY: a `failed` stage names its typed exit + carries its detail; a clean run
  # that reached SWITCH/RETIRE ok is exit 0; a unit that vanished without emitting a
  # stage is an abnormal death.
  defp deploy_outcome(stages, log) do
    failed = stages |> Enum.reverse() |> Enum.find(&(&1.status == "failed"))

    cond do
      failed ->
        {stage_exit_code(failed.name), terminal_reason(stage_exit_code(failed.name), failed, log)}

      Enum.any?(stages, &(&1.name in ~w(SWITCH RETIRE) and &1.status == "ok")) ->
        {0, nil}

      stages == [] ->
        {-1, terminal_reason(-1, nil, log)}

      true ->
        # Reached some stages but never a terminal failure or a clean switch —
        # the unit is gone; treat as an abnormal end with the log's own tail.
        {-1, terminal_reason(-1, nil, log)}
    end
  end

  # ROLLBACK: no stages exist, so the verdict comes from the log the engine typed.
  # A recognized typed failure wins first (`(no_previous)` → 21, `(not_supported)`
  # → 22). Otherwise a success marker (`ROLLED BACK` / `TARGET_BUILD=`, emitted by
  # both the real flip AND the "previous == current, nothing to do" path) is exit 0.
  # Neither — including a flip failure (24), which logs no distinct marker — falls
  # through to an abnormal death: still non-zero, still fail-closed, so the CP renders
  # a 422 refusal, never a false `rolled_back`.
  defp rollback_outcome(log) do
    case rollback_failure_code(log) do
      nil ->
        if rollback_succeeded?(log),
          do: {0, nil},
          else: {-1, terminal_reason(-1, nil, log)}

      code ->
        {code, terminal_reason(code, nil, log)}
    end
  end

  # The typed rollback failures name themselves in the log with a parenthetical
  # marker (`deploy/site-deploy.sh`): "(no_previous)" → 21, "(not_supported)" → 22.
  defp rollback_failure_code(log) do
    text = Enum.join(log, "\n")

    cond do
      String.contains?(text, "(no_previous)") -> 21
      String.contains?(text, "(not_supported)") -> 22
      true -> nil
    end
  end

  defp rollback_succeeded?(log) do
    Enum.any?(log, fn line ->
      String.contains?(line, "ROLLED BACK") or target_build_line?(line)
    end)
  end

  defp target_build_line?(line), do: Regex.match?(~r/^\s*TARGET_BUILD=\S/, line)

  # The build a deploy went live on is its manifest build_id; a SUCCESSFUL rollback
  # flips to a DIFFERENT build (its manifest build_id is empty — a rollback names no
  # build), so the now-live build is parsed from the engine's `TARGET_BUILD=<id>`
  # line, reusing the CP's parse (box_relay.target_build/1). Everything else keeps
  # the manifest build_id verbatim.
  defp terminal_build_id(%{mode: :rollback, build_id: fallback}, 0, log),
    do: parse_target_build(log) || fallback

  defp terminal_build_id(%{build_id: build_id}, _code, _log), do: build_id

  defp parse_target_build(log) do
    Enum.find_value(log, fn line ->
      case Regex.run(~r/^TARGET_BUILD=(\S+)/, String.trim(to_string(line))) do
        [_, id] -> id
        _ -> nil
      end
    end)
  end

  defp terminal_reason(code, failed_stage, log) do
    detail = failed_stage && failed_stage.detail
    tail = log_reason_tail(log)

    cond do
      is_binary(detail) and detail != "" -> "#{exit_label(code)}: #{detail}"
      tail != "" -> "#{exit_label(code)}: #{tail}"
      true -> exit_label(code)
    end
  end

  # The trailing meaningful lines of the child's raw log (BPSTAGE lines + blanks
  # are structure, not diagnosis). `log` is oldest-first, so take the last N.
  defp log_reason_tail(log) do
    log
    |> Enum.reject(&noise_line?/1)
    |> Enum.take(-@reason_lines)
    |> Enum.map_join(" | ", &String.trim/1)
  end

  # A `failed` stage's typed exit — the reverse of exit_label's mapping.
  defp stage_exit_code("PLAN"), do: 11
  defp stage_exit_code("BUILD"), do: 12
  defp stage_exit_code("STAGE"), do: 13
  defp stage_exit_code("HEALTH"), do: 14
  defp stage_exit_code("SWITCH"), do: 16
  defp stage_exit_code(_other), do: -1

  # ── the child's environment ───────────────────────────────────────────────

  # Configured working dir, or the repo root: the BEAM's cwd is api/ under both
  # `mix phx.server` and start.sh, so the parent is /opt/barkpark on a real box —
  # exactly where `bash deploy/site-deploy.sh` resolves.
  defp run_cd, do: Keyword.get(config(), :cd) || Path.dirname(File.cwd!())

  # The KEY→value decision, ONCE, shared by both sinks (the allow-list is never
  # forked): a request-supplied non-empty value, else `nil` (Port mode removes it
  # with `false`; a systemd EnvironmentFile omits the line — a transient unit
  # starts clean, so an omitted var is simply absent, never inherited).
  defp resolved_build_vars(%DeployRequest{} = req) do
    for key <- @build_env_keys do
      case Map.get(req.env, key) do
        value when is_binary(value) and value != "" -> {key, value}
        _absent -> {key, nil}
      end
    end
  end

  # The Port child's environment (fallback path). See the moduledoc: `false`
  # REMOVES, everything else is set explicitly, and PATH is untouched (inherited).
  defp child_env(%DeployRequest{} = req) do
    scrub = for key <- @scrub_env, do: {to_charlist(key), false}

    build =
      for {key, value} <- resolved_build_vars(req) do
        case value do
          v when is_binary(v) -> {to_charlist(key), to_charlist(v)}
          nil -> {to_charlist(key), false}
        end
      end

    engine = [
      {~c"SITE_SLUG", to_charlist(req.slug)},
      {~c"BUILD_ID", charlist_or_false(req.build_id)},
      {~c"CONTENT_REV", charlist_or_false(req.content_rev)}
    ]

    scrub ++ build ++ engine
  end

  defp charlist_or_false(value) when is_binary(value) and value != "", do: to_charlist(value)
  defp charlist_or_false(_value), do: false

  # The transient unit's EnvironmentFile (0600): the SAME set-or-omit decision as
  # child_env, rendered as `KEY=VALUE` lines. NO secret ever lands on argv, and
  # PATH is carried explicitly (a systemd unit's default PATH lacks asdf's `npm`
  # shims). The engine reads SITE_SLUG/BUILD_ID/CONTENT_REV and the status/log
  # file paths from here.
  defp write_env_file(path, %DeployRequest{} = req, status_file, log_file) do
    build_lines =
      for {key, value} <- resolved_build_vars(req), is_binary(value), do: "#{key}=#{value}"

    engine_lines =
      [{"SITE_SLUG", req.slug}, {"BUILD_ID", req.build_id}, {"CONTENT_REV", req.content_rev}]
      |> Enum.filter(fn {_k, v} -> is_binary(v) and v != "" end)
      |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)

    lines =
      ["PATH=#{System.get_env("PATH") || ""}"] ++
        build_lines ++
        engine_lines ++
        [
          "BARKPARK_SITE_STATUS_FILE=#{status_file}",
          "BARKPARK_SITE_LOG_FILE=#{log_file}"
        ]

    with :ok <- File.write(path, Enum.join(lines, "\n") <> "\n"),
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  rescue
    error -> {:error, error}
  end

  defp unlink_env(%{build_env_file: path}) when is_binary(path), do: File.rm(path)
  defp unlink_env(_), do: :ok

  # Each {mode, runtime_target} cell resolves its own injectable command (tests
  # stub these). The engine takes slug/build_id/content_rev from the ENVIRONMENT,
  # so argv carries only the MODE (`--rollback` or nothing); the RUNTIME TARGET
  # (charter D63) picks which engine script runs. runtime_target is a CLOSED enum
  # validated upstream, so these four clauses are total.
  defp command_for(:rollback, :node),
    do: Keyword.get(config(), :node_rollback_command, @default_node_rollback_command)

  defp command_for(:rollback, _static),
    do: Keyword.get(config(), :rollback_command, @default_rollback_command)

  defp command_for(:teardown, :node),
    do: Keyword.get(config(), :node_teardown_command, @default_node_teardown_command)

  defp command_for(:teardown, _static),
    do: Keyword.get(config(), :teardown_command, @default_teardown_command)

  defp command_for(_deploy, :node),
    do: Keyword.get(config(), :node_command, @default_node_command)

  defp command_for(_deploy, _static),
    do: Keyword.get(config(), :command, @default_command)

  # ── Port fallback (dev / macOS / CI) ──────────────────────────────────────

  defp open_port_and_record(state, %DeployRequest{} = req) do
    case open_port(req) do
      {:ok, port} ->
        schedule_run_deadline(port)

        run = %{
          slug: req.slug,
          build_id: req.build_id,
          content_rev: req.content_rev,
          mode: req.mode,
          runtime_target: req.runtime_target,
          state: :running,
          port: port,
          stages: [],
          log: [],
          exit_code: nil,
          failure_reason: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil
        }

        state = %{
          state
          | runs: state.runs |> Map.put(req.slug, run) |> prune_runs(),
            ports: Map.put(state.ports, port, req.slug)
        }

        {:reply, {:ok, :started}, state}

      {:error, _reason} ->
        {:reply, {:error, :start_failed}, state}
    end
  end

  defp open_port(%DeployRequest{} = req) do
    {exe, args} = command_for(req.mode, req.runtime_target)

    case System.find_executable(exe) do
      nil ->
        {:error, {:executable_not_found, exe}}

      path ->
        port =
          Port.open(
            {:spawn_executable, path},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              {:line, 4096},
              args: args,
              cd: run_cd(),
              env: child_env(req)
            ]
          )

        {:ok, port}
    end
  rescue
    # Port.open raises on e.g. a missing cd — degrade to a start failure so the
    # controller can answer 500 runner_start_failed instead of crashing.
    error -> {:error, error}
  end

  defp schedule_run_deadline(port) do
    Process.send_after(self(), {:run_deadline, port}, run_deadline_ms())
  end

  # Closing a `{:spawn_executable, _}` port terminates the external program;
  # tolerate an already-closed port so the watchdog never crashes the Runner.
  defp close_port(port) do
    Port.close(port)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Apply `fun` to the run this port belongs to; a port we do not know (a stale
  # message from a finished run) is ignored.
  defp update_run(state, port, fun) do
    with {:ok, slug} <- Map.fetch(state.ports, port),
         {:ok, run} <- Map.fetch(state.runs, slug) do
      %{state | runs: Map.put(state.runs, slug, fun.(run))}
    else
      :error -> state
    end
  end

  defp release_port(state, port) do
    %{state | ports: Map.delete(state.ports, port)}
  end

  # Every line goes into the bounded log tail; a BPSTAGE line ALSO upserts the
  # stage list, which is never evicted.
  defp ingest_line(run, line) do
    run
    |> push_log(line)
    |> parse_stage(line)
  end

  defp finish_run(run, code) do
    %{
      run
      | state: :done,
        port: nil,
        exit_code: code,
        failure_reason: failure_reason(code, run),
        finished_at: DateTime.utc_now()
    }
  end

  # Bounded log: newest-first internally, oldest dropped beyond the cap.
  defp push_log(run, line) do
    max = Keyword.get(config(), :max_log_lines, @default_max_log_lines)
    %{run | log: Enum.take([line | run.log], max)}
  end

  # ── stages ──────────────────────────────────────────────────────────────

  # Port-stream variant: parse one line, upsert into the run's stage list.
  defp parse_stage(run, line) do
    case parse_stage_line(line, run.build_id) do
      {:ok, stage} -> %{run | stages: upsert_stage(run.stages, stage)}
      :skip -> run
    end
  end

  # The ONE stage parser both sinks share. Returns `{:ok, stage}` for a
  # well-formed, whitelisted BPSTAGE line, else `:skip`. RAW tokens (no
  # normalization). build_id falls back to the run/manifest's own when the line
  # emits it empty.
  defp parse_stage_line(line, default_build_id) do
    case Regex.run(@stage_re, line, capture: :all_but_first) do
      [name, status | rest] when name in @stage_names and status in @stage_statuses ->
        {build_id, detail} = stage_rest(rest)

        {:ok,
         %{
           name: name,
           status: status,
           build_id: blank_to_nil(build_id) || default_build_id,
           detail: blank_to_nil(detail),
           at: DateTime.utc_now()
         }}

      _no_match ->
        :skip
    end
  end

  # Trailing optional groups that never participated are dropped by Regex.run; a
  # skipped MIDDLE group comes back as "". Both shapes mean "absent".
  defp stage_rest([]), do: {nil, nil}
  defp stage_rest([build_id]), do: {build_id, nil}
  defp stage_rest([build_id, detail | _]), do: {build_id, detail}

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s

  # Upsert by stage name, preserving first-seen order: `started` is later
  # overwritten by `ok`/`failed` for the same stage rather than appended.
  defp upsert_stage(stages, stage) do
    if Enum.any?(stages, &(&1.name == stage.name)) do
      Enum.map(stages, fn existing ->
        if existing.name == stage.name, do: stage, else: existing
      end)
    else
      stages ++ [stage]
    end
  end

  # ── failure reasons (Port stream) ─────────────────────────────────────────

  defp failure_reason(0, _run), do: nil

  defp failure_reason(code, run) do
    case reason_tail(run) do
      "" -> exit_label(code)
      tail -> "#{exit_label(code)}: #{tail}"
    end
  end

  # The REAL reason, not a generic message: the trailing meaningful lines of the
  # child's own stream. `run.log` is newest-first internally.
  defp reason_tail(run) do
    run.log
    |> Enum.reject(&noise_line?/1)
    |> Enum.take(@reason_lines)
    |> Enum.reverse()
    |> Enum.map_join(" | ", &String.trim/1)
  end

  defp noise_line?(line) do
    String.trim(line) == "" or Regex.match?(@stage_re, line)
  end

  # site-deploy.sh's typed exit codes (its header block is the contract).
  defp exit_label(2), do: "usage error (exit 2)"
  defp exit_label(10), do: "missing site source dir (exit 10)"
  defp exit_label(11), do: "missing or invalid required input (exit 11)"
  defp exit_label(12), do: "BUILD failed (exit 12)"
  defp exit_label(13), do: "STAGE failed — no dist/ (exit 13)"
  defp exit_label(14), do: "HEALTH gate failed — not switched (exit 14)"
  defp exit_label(15), do: "gave up waiting for the deploy lock (exit 15)"
  defp exit_label(16), do: "SWITCH failed (exit 16)"
  defp exit_label(21), do: "rollback: no previous release (exit 21)"
  defp exit_label(22), do: "rollback: not supported on this site (exit 22)"
  defp exit_label(23), do: "rollback: a deploy is in flight (exit 23)"
  defp exit_label(24), do: "rollback failed (exit 24)"
  defp exit_label(-1), do: "deploy process died abnormally"
  defp exit_label(-2), do: "deploy exceeded its deadline and was force-closed"
  defp exit_label(code), do: "deploy failed (exit #{code})"

  # ── deadline timers (systemd path) ────────────────────────────────────────

  defp arm_unit_deadline(state, slug, remaining_ms) do
    state = cancel_timer(state, slug)

    if remaining_ms <= 0 do
      # Already over the deadline (e.g. a long build re-attached after a slow
      # restart): fire immediately so the finalizer stops + finalizes it.
      send(self(), {:unit_deadline, slug})
      state
    else
      ref = Process.send_after(self(), {:unit_deadline, slug}, remaining_ms)
      Map.update!(state, :timers, &Map.put(&1, slug, ref))
    end
  end

  defp cancel_timer(state, slug) do
    case Map.fetch(state.timers, slug) do
      {:ok, ref} ->
        _ = Process.cancel_timer(ref)
        Map.update!(state, :timers, &Map.delete(&1, slug))

      :error ->
        state
    end
  end

  # ── manifests + run-state dir ─────────────────────────────────────────────

  # A config-injectable dir under which every run's manifest + status + log +
  # env files live. Must SURVIVE a BEAM restart (it is how init/1 re-attaches),
  # so it defaults under the repo root, not a per-boot tmp.
  defp run_state_dir do
    Keyword.get(config(), :run_state_dir) || Path.join(run_cd(), ".bp-site-deploy-runs")
  end

  defp ensure_run_state_dir do
    dir = run_state_dir()
    File.mkdir_p!(dir)
    dir
  end

  defp manifest_path(dir, slug), do: Path.join(dir, "#{slug}.manifest.json")

  defp write_manifest(dir, manifest) do
    File.write(manifest_path(dir, manifest.slug), Jason.encode!(encode_manifest(manifest)))
  rescue
    error -> {:error, error}
  end

  defp load_manifest_for(slug) do
    case runner_mode() do
      :systemd -> read_manifest(manifest_path(run_state_dir(), slug))
      :port -> nil
    end
  end

  defp read_manifest(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, json} <- Jason.decode(raw) do
      decode_manifest(json)
    else
      _ -> nil
    end
  end

  defp list_manifests(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".manifest.json"))
        |> Enum.map(&read_manifest(Path.join(dir, &1)))
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp encode_manifest(m) do
    %{
      "slug" => m.slug,
      "build_id" => m.build_id,
      "content_rev" => m.content_rev,
      "mode" => Atom.to_string(m.mode),
      "runtime_target" => Atom.to_string(m.runtime_target),
      "unit_name" => m.unit_name,
      "status_file" => m.status_file,
      "log_file" => m.log_file,
      "build_env_file" => m.build_env_file,
      "started_at" => DateTime.to_iso8601(m.started_at)
    }
  end

  defp decode_manifest(%{"slug" => slug, "unit_name" => unit} = j)
       when is_binary(slug) and is_binary(unit) do
    %{
      slug: slug,
      build_id: j["build_id"],
      content_rev: j["content_rev"],
      mode: safe_atom(j["mode"], [:deploy, :rollback, :teardown], :deploy),
      runtime_target: safe_atom(j["runtime_target"], [:static, :node], :static),
      unit_name: unit,
      status_file: j["status_file"],
      log_file: j["log_file"],
      build_env_file: j["build_env_file"],
      started_at: parse_dt(j["started_at"])
    }
  end

  defp decode_manifest(_), do: nil

  # Never String.to_atom on file data — map only the closed enum, else default.
  defp safe_atom(value, allowed, default) do
    Enum.find(allowed, default, &(Atom.to_string(&1) == value))
  end

  defp parse_dt(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_dt(_), do: DateTime.utc_now()

  # Start a fresh status + log so a redeploy of the same slug never folds a
  # previous run's stages.
  defp fresh_run_files(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case File.write(path, "") do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: secs}} -> DateTime.from_unix!(secs)
      _ -> nil
    end
  end

  # Keep the run-state dir bounded: newest @max_tracked_runs manifests survive;
  # for each evicted one, sweep its manifest/status/log/env quartet. A unit still
  # active is NEVER evicted (its files are load-bearing for re-attach).
  defp prune_run_state_dir(dir) do
    manifests = list_manifests(dir)

    if length(manifests) > @max_tracked_runs do
      {active, idle} =
        Enum.split_with(manifests, &(is_active(&1.unit_name) in @active_states))

      keep =
        idle
        |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
        |> Enum.take(max(@max_tracked_runs - length(active), 0))

      keep_slugs = MapSet.new(active ++ keep, & &1.slug)

      for m <- manifests, not MapSet.member?(keep_slugs, m.slug) do
        _ = File.rm(manifest_path(dir, m.slug))
        _ = m.status_file && File.rm(m.status_file)
        _ = m.log_file && File.rm(m.log_file)
        _ = unlink_env(m)
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  # ── config knobs ──────────────────────────────────────────────────────────

  defp run_deadline_ms, do: Keyword.get(config(), :run_deadline_ms, @default_run_deadline_ms)
  defp memory_max, do: Keyword.get(config(), :memory_max, @default_memory_max)
  defp cpu_quota, do: Keyword.get(config(), :cpu_quota, @default_cpu_quota)

  defp ctl_cmd_timeout_ms,
    do: Keyword.get(config(), :ctl_cmd_timeout_ms, @default_ctl_cmd_timeout_ms)

  # Run a control-plane `System.cmd` under a hard deadline on a SUPERVISED,
  # UNLINKED task so a hung external process cannot wedge the singleton Runner.
  # async_nolink (never linked Task.async) so a crash inside the child degrades
  # to a tuple instead of taking the GenServer down; Task.yield ||
  # Task.shutdown(:brutal_kill) is the same per-site pattern as
  # `studio_chat/probe.ex` + `onixedit/export/validator.ex`. Returns:
  #   {:ok, {out, code}} — the command completed inside the deadline;
  #   :timeout           — the deadline fired (task brutal-killed);
  #   {:crashed, reason} — `System.cmd` raised inside the task.
  # Each caller degrades these three per the never-crash contract.
  #
  # Sobelow CI.System is a false-positive here: every caller resolves `path` via
  # `System.find_executable/1` (a fixed binary name or a test-only config
  # override, never request data) and passes a fixed token list + the
  # server-generated unit name — no shell string, no client input. This inline
  # skip replaces the line-anchored `.sobelow-skips` fingerprints
  # (`deploy_runner.ex:526/:1351/:1368`) that the deadline wrapper moved
  # System.cmd off of.
  # sobelow_skip ["CI.System"]
  defp bounded_cmd(path, args, opts) do
    task =
      Task.Supervisor.async_nolink(Barkpark.TaskSupervisor, fn ->
        System.cmd(path, args, opts)
      end)

    case Task.yield(task, ctl_cmd_timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, code}} -> {:ok, {out, code}}
      {:exit, reason} -> {:crashed, reason}
      nil -> :timeout
    end
  end

  # `systemctl is-active <unit>` → the trimmed state word ("active", "inactive",
  # "failed", …). A missing systemctl / a swept unit is terminal ("unknown").
  # Injectable so a systemd-less test can drive re-attach + finalize.
  defp is_active(unit_name) do
    {exe, prefix} = Keyword.get(config(), :is_active_cmd, @default_is_active)

    case System.find_executable(exe) do
      nil ->
        "unknown"

      path ->
        # Bounded: a hung `systemctl is-active` would freeze the {:status} call
        # (and prune_run_state_dir). A timeout or crash degrades to "unknown" —
        # a terminal state (not in @active_states) that finalizes the run rather
        # than pinning it :running forever.
        case bounded_cmd(path, prefix ++ [unit_name], stderr_to_stdout: true) do
          {:ok, {out, _code}} ->
            out |> String.trim() |> String.split("\n") |> List.first() |> to_string()

          _timeout_or_crash ->
            "unknown"
        end
    end
  end

  defp systemctl_stop(unit_name) do
    {exe, prefix} = Keyword.get(config(), :systemctl_stop_cmd, @default_systemctl_stop)

    case System.find_executable(exe) do
      nil ->
        :ok

      path ->
        # Bounded: this is the {:unit_deadline} watchdog's OWN kill, running in a
        # handle_info that safe_call cannot rescue — a hung `systemctl stop` here
        # would wedge the Runner exactly where it must stay live to force-close a
        # wedged unit. On timeout/crash we WARN and still return :ok so the
        # watchdog finalizes the run (:done / exit -2) regardless.
        case bounded_cmd(path, prefix ++ [unit_name], stderr_to_stdout: true) do
          {:ok, _} ->
            :ok

          other ->
            Logger.warning(
              "[site-deploy] systemctl stop did not complete in #{ctl_cmd_timeout_ms()}ms " <>
                "for #{inspect(unit_name)} (#{inspect(other)}) — finalizing the run anyway"
            )

            :ok
        end
    end
  end

  # ── rendering ───────────────────────────────────────────────────────────

  # Keep the newest @max_tracked_runs slugs. Running (Port) runs are NEVER
  # evicted; among finished ones the oldest goes first. A systemd finalized cache
  # (no `:port`, always `:done`) is treated as finished.
  defp prune_runs(runs) when map_size(runs) <= @max_tracked_runs, do: runs

  defp prune_runs(runs) do
    {running, finished} =
      runs |> Map.values() |> Enum.split_with(&(&1.state == :running))

    keep =
      finished
      |> Enum.sort_by(&run_finished_at/1, {:desc, DateTime})
      |> Enum.take(max(@max_tracked_runs - length(running), 0))

    Map.new(running ++ keep, &{&1.slug, &1})
  end

  defp run_finished_at(%{finished_at: %DateTime{} = dt}), do: dt
  defp run_finished_at(_), do: ~U[1970-01-01 00:00:00Z]

  defp idle_status(slug) do
    %{
      state: :idle,
      slug: slug,
      build_id: nil,
      content_rev: nil,
      mode: nil,
      runtime_target: nil,
      stages: [],
      exit_code: nil,
      failure_reason: nil,
      log: [],
      started_at: nil,
      finished_at: nil
    }
  end

  # Whitelist-render — the configured COMMAND is never exposed, only its output.
  # A Port run holds its log newest-first (reverse it); a reconstructed systemd
  # render already carries an oldest-first log + a `:done`/`:running` state.
  defp render_run(%{port: _} = run) do
    %{
      state: run.state,
      slug: run.slug,
      build_id: run.build_id,
      content_rev: run.content_rev,
      mode: run.mode,
      runtime_target: run.runtime_target,
      stages: run.stages,
      exit_code: run.exit_code,
      failure_reason: run.failure_reason,
      log: Enum.reverse(run.log),
      started_at: run.started_at,
      finished_at: run.finished_at
    }
  end

  defp render_run(reconstructed), do: reconstructed
end
