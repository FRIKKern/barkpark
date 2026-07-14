defmodule Barkpark.Sites.DeployRunner do
  @moduledoc """
  Site-deploy EXECUTOR — the on-box process that actually runs
  `deploy/site-deploy.sh` for a content-bound static site. This is the remote-
  exec seam the control plane reaches through `POST /v1/admin/site-deploy`
  (charter D22): an authenticated admin HTTP call on the instance's OWN API,
  turned into a real OS process here.

  ## Why this is NOT `Barkpark.SelfUpdate.Runner` (charter D23)

  The self-update Runner is the right SHAPE (supervised GenServer wrapping a
  `Port`, fail-closed behind an apply flag, bounded log, deadline watchdog) but
  the wrong ENGINE for a site deploy, on three counts that each break a live
  deploy rather than merely offend taste:

    * **Compile-time command.** Its command comes from `config` — it can never
      carry a per-request `build_id`. Every site deploy names a different
      build.
    * **One GLOBAL run slot.** Self-update + rollback share it, and guerrilla
      auto-deploys on every merge — a site deploy racing the box's own
      post-merge self-update would get a bare `already_running` for a run that
      has nothing to do with it. Here the single-flight slot is **per slug**:
      two different sites deploy concurrently; the same site twice is a 409.
    * **A 500-line log ring that evicts the oldest.** A real `npm ci` prints
      far more than 500 lines, so the early `PLAN:`/`BUILD:` lines are gone
      before an orchestrator ever polls. Hence `stages` — parsed out of the
      engine's `BPSTAGE` lines and retained **separately from, and immune to,**
      the log ring. The raw log stays a bounded tail; the six stages never
      evict.

  ## The child's environment (charter D24)

  `Port.open` with no `env:` gives the child the BEAM's FULL environment —
  which on a real box contains `BARKPARK_KEK` and `BARKPARK_CLOAK_KEY`, the
  master encryption keys, and `npm ci` runs arbitrary third-party
  `postinstall` code. Erlang's `env` option only ADDS/OVERRIDES; the ONLY way
  to remove a var is `{~c"NAME", false}`. An allow-list-SHAPED `env: [...]`
  therefore does not scrub anything — it reads like a scrub and leaks the keys.
  So:

    * `BARKPARK_KEK` / `BARKPARK_CLOAK_KEY` are REMOVED with the `false` form.
    * Every var in the engine's `BUILD_ALLOW` set is either **set from the
      request** or **removed** — never inherited. site-deploy.sh reads them
      ambiently (`${!v}`), so an ambient `BARKPARK_TOKEN` on the box would
      silently shadow the per-site token and build the site against the wrong
      content.
    * `PATH` is PRESERVED (untouched, hence inherited): asdf's `npm` shims live
      there. Do not "fix" this — a bare `ssh box 'node -v'` reporting
      `command not found` is a login-shell artifact, not a missing toolchain.

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
  @default_max_log_lines 500
  # 30 min — an `npm ci` + build on a small box, with headroom. A run that
  # outlives it is force-closed so a wedged port can't hold the slug's slot
  # until the next BEAM restart.
  @default_run_deadline_ms 1_800_000

  # Finished runs stay queryable (the orchestrator polls AFTER the exit), but
  # not forever — keep the newest N slugs, evicting finished ones first.
  @max_tracked_runs 32
  # How many trailing meaningful lines a failure_reason carries. The engine's
  # own "BUILD failed …" line is usually last; the REAL cause (npm's 401, the
  # HEALTH marker miss) is the line or two above it.
  @reason_lines 3

  # `BPSTAGE name=<STAGE> status=<STATUS> build_id=<ID> [detail="…"]` — emitted by
  # site-deploy.sh at every state-machine boundary. Both fields are whitelisted
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

  # The box's master encryption keys — REMOVED from the child (see moduledoc).
  @scrub_env ~w(BARKPARK_KEK BARKPARK_CLOAK_KEY)
  # Set-from-request-or-remove. Superset of DeployRequest.allowed_env_keys/0:
  # the engine derives BARKPARK_BUILD_ID / BARKPARK_CONTENT_REV itself from
  # BUILD_ID / CONTENT_REV, but they are in its BUILD_ALLOW list, so an ambient
  # value could still shadow — remove them too and let the engine set them.
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
  The run status for `slug`: `state` (`:idle` | `:running` | `:done`), the
  parsed `stages` (never evicted), `exit_code`, an honest `failure_reason`, the
  bounded `log` tail (oldest line first), and timestamps. A slug that has never
  run reports `:idle`. Never raises.
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
          # Runner died between whereis and call (or timed out) — degrade,
          # never propagate the exit to the caller.
          :exit, _reason -> fallback
        end
    end
  end

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Ports are linked to this process; trap so an abnormal port death becomes
    # a :done run instead of taking the Runner (and every other slug) down.
    Process.flag(:trap_exit, true)
    {:ok, %{runs: %{}, ports: %{}}}
  end

  @impl true
  def handle_call({:trigger, %DeployRequest{} = req}, _from, state) do
    cond do
      not enabled?() ->
        {:reply, {:error, :disabled}, state}

      running_slug?(state, req.slug) ->
        {:reply, {:error, :already_running}, state}

      true ->
        start_run(state, req)
    end
  end

  def handle_call({:status, slug}, _from, state) do
    status =
      case Map.fetch(state.runs, slug) do
        {:ok, run} -> render_run(run)
        :error -> idle_status(slug)
      end

    {:reply, status, state}
  end

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

  # Deadline watchdog for a run that is STILL the live one on this port. A
  # stale deadline from an already-finished run finds no port entry and falls
  # through untouched.
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

  def handle_info(_msg, state), do: {:noreply, state}

  # ── run lifecycle ───────────────────────────────────────────────────────

  defp running_slug?(state, slug) do
    match?({:ok, %{state: :running}}, Map.fetch(state.runs, slug))
  end

  defp start_run(state, %DeployRequest{} = req) do
    # PROVISION FIRST (charter D33/D34): a content-bound static site has no repo
    # to check out, so its source must be materialized from the shipped template
    # BEFORE the deploy port opens — otherwise site-deploy.sh walks PLAN and dies
    # at BUILD with `no site source dir …/src` (exit 10). Deploy only; a rollback
    # is a symlink repoint whose source is already there (Provisioner no-ops it).
    # Fail-closed: a provision failure short-circuits EXACTLY like an open_port
    # failure — no Port, no run recorded, `{:error, :start_failed}`.
    case Provisioner.provision(req) do
      :ok ->
        open_port_and_record(state, req)

      {:error, {:provision_failed, reason}} ->
        Logger.warning(
          "[site-deploy] provision failed for #{inspect(req.slug)} — deploy not started: #{inspect(reason)}"
        )

        {:reply, {:error, :start_failed}, state}
    end
  end

  defp open_port_and_record(state, %DeployRequest{} = req) do
    case open_port(req) do
      {:ok, port} ->
        schedule_run_deadline(port)

        run = %{
          slug: req.slug,
          build_id: req.build_id,
          content_rev: req.content_rev,
          mode: req.mode,
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
    {exe, args} = command_for(req.mode)

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

  # Each mode resolves its own injectable command (tests stub these). The
  # engine takes slug/build_id/content_rev from the ENVIRONMENT (see
  # deploy/site-deploy.sh: SITE_SLUG / BUILD_ID / CONTENT_REV), so the MODE is
  # what argv carries — `--rollback` or nothing.
  defp command_for(:rollback),
    do: Keyword.get(config(), :rollback_command, @default_rollback_command)

  defp command_for(_deploy),
    do: Keyword.get(config(), :command, @default_command)

  # Configured working dir, or the repo root: the BEAM's cwd is api/ under both
  # `mix phx.server` and start.sh, so the parent is /opt/barkpark on a real box
  # — exactly where `bash deploy/site-deploy.sh` resolves (the same assumption
  # the shipped `deploy/instance-deploy.sh --rollback` command already makes).
  defp run_cd, do: Keyword.get(config(), :cd) || Path.dirname(File.cwd!())

  # The child's environment. See the moduledoc: `false` REMOVES, everything
  # else is set explicitly, and PATH is untouched (therefore inherited).
  defp child_env(%DeployRequest{} = req) do
    scrub = for key <- @scrub_env, do: {to_charlist(key), false}

    build =
      for key <- @build_env_keys do
        case Map.get(req.env, key) do
          value when is_binary(value) and value != "" -> {to_charlist(key), to_charlist(value)}
          # Not supplied ⇒ REMOVED, never inherited: an ambient BARKPARK_TOKEN
          # on the box would silently shadow the per-site one.
          _absent -> {to_charlist(key), false}
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

  defp schedule_run_deadline(port) do
    Process.send_after(self(), {:run_deadline, port}, run_deadline_ms())
  end

  defp run_deadline_ms, do: Keyword.get(config(), :run_deadline_ms, @default_run_deadline_ms)

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

  # Bounded log: newest-first internally, oldest dropped beyond the cap. The
  # cap is why `stages` exists — a 900-line npm build evicts PLAN/BUILD here.
  defp push_log(run, line) do
    max = Keyword.get(config(), :max_log_lines, @default_max_log_lines)
    %{run | log: Enum.take([line | run.log], max)}
  end

  # ── stages ──────────────────────────────────────────────────────────────

  # Upsert by stage name, preserving first-seen order: `started` is later
  # overwritten by `ok`/`failed` for the same stage rather than appended, so the
  # list stays exactly the six-stage story of this run — bounded by construction.
  defp parse_stage(run, line) do
    case Regex.run(@stage_re, line, capture: :all_but_first) do
      [name, status | rest]
      when name in @stage_names and status in @stage_statuses ->
        {build_id, detail} = stage_rest(rest)

        stage = %{
          name: name,
          status: status,
          build_id: blank_to_nil(build_id) || run.build_id,
          detail: blank_to_nil(detail),
          at: DateTime.utc_now()
        }

        %{run | stages: upsert_stage(run.stages, stage)}

      # Not a (well-formed, whitelisted) BPSTAGE line — it is just log.
      _no_match ->
        run
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

  defp upsert_stage(stages, stage) do
    if Enum.any?(stages, &(&1.name == stage.name)) do
      Enum.map(stages, fn existing ->
        if existing.name == stage.name, do: stage, else: existing
      end)
    else
      stages ++ [stage]
    end
  end

  # ── failure reasons ─────────────────────────────────────────────────────

  defp failure_reason(0, _run), do: nil

  defp failure_reason(code, run) do
    case reason_tail(run) do
      "" -> exit_label(code)
      tail -> "#{exit_label(code)}: #{tail}"
    end
  end

  # The REAL reason, not a generic message: the trailing meaningful lines of the
  # child's own stream (stderr_to_stdout means npm's 401, the HEALTH marker miss
  # and the engine's own diagnosis are ALL in there — surface them, never swallow
  # them). BPSTAGE lines and blanks are structure, not diagnosis.
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

  # ── rendering ───────────────────────────────────────────────────────────

  # Keep the newest @max_tracked_runs slugs. Running runs are NEVER evicted;
  # among finished ones the oldest goes first.
  defp prune_runs(runs) when map_size(runs) <= @max_tracked_runs, do: runs

  defp prune_runs(runs) do
    {running, finished} =
      runs |> Map.values() |> Enum.split_with(&(&1.state == :running))

    keep =
      finished
      |> Enum.sort_by(& &1.finished_at, {:desc, DateTime})
      |> Enum.take(max(@max_tracked_runs - length(running), 0))

    Map.new(running ++ keep, &{&1.slug, &1})
  end

  defp idle_status(slug) do
    %{
      state: :idle,
      slug: slug,
      build_id: nil,
      content_rev: nil,
      mode: nil,
      stages: [],
      exit_code: nil,
      failure_reason: nil,
      log: [],
      started_at: nil,
      finished_at: nil
    }
  end

  # Whitelist-render — the configured COMMAND is never exposed, only its output.
  defp render_run(run) do
    %{
      state: run.state,
      slug: run.slug,
      build_id: run.build_id,
      content_rev: run.content_rev,
      mode: run.mode,
      stages: run.stages,
      exit_code: run.exit_code,
      failure_reason: run.failure_reason,
      log: Enum.reverse(run.log),
      started_at: run.started_at,
      finished_at: run.finished_at
    }
  end
end
