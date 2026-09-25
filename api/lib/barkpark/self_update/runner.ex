defmodule Barkpark.SelfUpdate.Runner do
  @moduledoc """
  Self-hosted update EXECUTOR — the apply side of instance self-update,
  deliberately separate from the read-only `Barkpark.SelfUpdate.Checker`.
  On `trigger/0` it runs the configured update command (by default
  `bash scripts/self-update.sh`, which fast-forwards the checkout so the
  post-merge hook performs the rebuild + restart) as an OS process via a
  `Port`, streaming its output into a bounded in-memory log.

  ALWAYS supervised (an idle GenServer is free — see `Barkpark.Application`),
  but fail-closed on execution: every trigger is gated by its own `enabled`
  config, which ships OFF in config.exs and is only flipped on in prod when
  `BARKPARK_SELF_UPDATE_APPLY=1`. Single-flight: a second trigger while a run
  is in flight returns `{:error, :already_running}` (the script's own flock
  is the cross-process backstop).

  Working-directory assumption: `cd: nil` resolves to the PARENT of the
  BEAM's cwd, because under both `mix phx.server` and prod's start.sh (which
  `cd`s to its own directory) the cwd is `api/` — so the parent is the repo
  root the update script expects. Boxes with a different layout override it
  via `BARKPARK_SELF_UPDATE_CD`.

  Never-crash contract: `trigger/0` and `status/0` never raise — a dead
  process degrades to `{:error, :disabled}` / the on-disk status (below), and
  a command that fails to start or dies abnormally lands as a `:done` state
  with a non-zero exit code, never as a Runner crash.

  ## Durable run records (the run outlives the process that started it)

  The default command RESTARTS the service that owns this process:
  `deploy-rebuild.sh` ends in `systemctl restart barkpark`, and systemd
  SIGTERMs the whole cgroup — the BEAM, this GenServer, the port and the
  script itself. So in-memory state alone made the happy path report `:idle`
  with an empty log, indistinguishable from "never ran". The run is therefore
  recorded on disk, following `Barkpark.Sites.DeployRunner`'s pattern
  (manifest at trigger, terminal record at exit, re-attach on `init/1`):

    * `run.manifest.json` — written at trigger: run id, mode, `started_at`
      and the child's OS pid. A POINTER, not a record: no outcome.
    * `run.log` — every captured line, appended as it arrives, already
      folded through `Barkpark.Sites.BuildLogScrub.raw/1` (the same pattern
      set DeployRunner's recorded logs use). Scrubbed AT WRITE, so unlike
      DeployRunner's finalize-time fold there is no raw window on disk.
    * `run.terminal.json` — written at exit (natural exit, abnormal port
      death, deadline): exit code, timestamps and the bounded scrubbed log.

  One global run slot means ONE set of fixed-name files, overwritten per
  trigger — bounded at one run by construction, no retention sweep needed.
  They live in `run_state_dir` (default `<repo>/.bp-self-update-runs`, the
  same location class as DeployRunner's `.bp-site-deploy-runs`: writable by
  the running release and outside `_build`, which a rebuild nukes).

  `init/1` and the dead-process `status/0` fallback read them back:

    * terminal record for the manifest's run → `:done` with its real outcome.
    * manifest, no terminal record, child pid still alive → re-attached as
      `:running` (single-flight slot re-claimed, deadline re-armed against the
      ORIGINAL `started_at`, pid polled until it exits) — DeployRunner's
      re-attach of a still-active unit.
    * manifest, no terminal record, child gone → the run died with the BEAM.
      Like DeployRunner reconstructing a vanished unit from the engine's own
      durable status file, the outcome is recovered from `deploy-rebuild.sh`'s
      flight recorder (`<repo>/.deploy-status.json`), matched on the child's
      pid (self-update.sh `exec`s deploy-rebuild.sh, so `$$` is the pid we
      spawned) and a timestamp not older than the run. `phase=restart
      outcome=applied` — written immediately before the restart that killed
      us — is exit 0. With no matching record the run is `:done` with exit
      `-3` (interrupted, outcome unknown) — never `:idle`. The recovered
      outcome is then written as the terminal record, so it is stable.
  """

  use GenServer

  require Logger

  alias Barkpark.Sites.BuildLogScrub

  @default_command {"bash", ["scripts/self-update.sh"]}
  # Rollback rides the SAME Runner single-flight as self-update (one run slot
  # for both verbs). `--rollback` resets the shared checkout to the idle slot's
  # recorded sha, reboots + health-gates that slot, and flips Caddy only on
  # green (W6 charter D11/D13/D15). `--rollback-preflight` is the synchronous,
  # read-only probe the controller runs FIRST to learn the target sha and to
  # get a typed refusal before anything mutates.
  @default_rollback_command {"bash", ["deploy/instance-deploy.sh", "--rollback"]}
  @default_rollback_preflight_command {"bash",
                                       ["deploy/instance-deploy.sh", "--rollback-preflight"]}
  @default_max_log_lines 500

  # Deadlines. The preflight is read-only but a hung git/ssh under it would block
  # the admin request forever; the main run holds `running?`=true until the port
  # closes, so a wedged run would block every future trigger until a BEAM restart.
  # Both are config-overridable per env for tests via
  # `config :barkpark, __MODULE__, preflight_timeout_ms: N, run_deadline_ms: N`.
  @default_preflight_timeout_ms 60_000
  # 30 min — comfortably covers a real self-update/rollback + clean rebuild.
  @default_run_deadline_ms 1_800_000

  # exit 0 prints `TARGET_SHA=<40-hex>` (charter W6 contract); tolerate a short
  # sha for stub-command tests, but require hex so a garbage line can't pass.
  @target_sha_re ~r/TARGET_SHA=([0-9a-fA-F]{7,40})\b/

  # Exit code for a run the BEAM restarted under with no terminal record and no
  # matching deploy-rebuild flight record: interrupted, outcome unknown. Beside
  # -1 (port closed abnormally) and -2 (deadline force-close).
  @interrupted_exit -3

  # How often a re-attached run's child pid is probed for liveness.
  @default_orphan_poll_ms 5_000

  @manifest_file "run.manifest.json"
  @log_file "run.log"
  @terminal_file "run.terminal.json"

  # deploy-rebuild.sh's `write_status` phase/outcome → the exit code the script
  # would have returned had it survived to return one (its header documents
  # 0 ok · 1 build failed · 13 migrate failed · 15 restart unverified).
  @deploy_status_exits %{
    {"restart", "applied"} => 0,
    {"build", "failed"} => 1,
    {"migrate", "failed"} => 13,
    {"restart", "unverified"} => 15
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Whether applying updates is enabled on this instance (config.exs default
  OFF; prod runtime.exs flips it on only when `BARKPARK_SELF_UPDATE_APPLY=1`).
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Keyword.get(config(), :enabled, false) == true
  end

  @doc """
  The `Barkpark.SelfUpdate.Runner` config keyword list (enabled, command,
  cd, max_log_lines — see config.exs for the defaults).
  """
  @spec config() :: keyword()
  def config do
    Application.get_env(:barkpark, __MODULE__, [])
  end

  @doc """
  Start the configured update command. Single-flight; never raises.
  """
  @spec trigger() :: {:ok, :started} | {:error, :already_running | :disabled | :start_failed}
  def trigger, do: safe_call({:trigger, :self_update}, {:error, :disabled})

  @doc """
  Start the configured rollback command as an async `Port`, SHARING the same
  single-flight run slot as `trigger/0` — a rollback while a self-update runs
  (or vice-versa) returns `{:error, :already_running}`. Never raises.

  The controller runs `preflight_rollback/0` synchronously first; this only
  spawns the mutating `--rollback` run once preflight has cleared it.
  """
  @spec trigger_rollback() ::
          {:ok, :started} | {:error, :already_running | :disabled | :start_failed}
  def trigger_rollback, do: safe_call({:trigger, :rollback}, {:error, :disabled})

  @doc """
  Whether a run (self-update OR rollback) is currently in flight. Used by the
  controller to reject a colliding rollback with a clean 409 before it spends a
  preflight subprocess; the GenServer trigger remains the authoritative gate.
  """
  @spec running?() :: boolean()
  def running?, do: match?(%{state: :running}, status())

  @doc """
  Run the synchronous, read-only rollback preflight and map the script's typed
  exit codes to a result. Never raises.

    * `{:ok, target_sha}` — exit 0, `TARGET_SHA=` parsed from stdout
    * `{:error, :no_previous_slot}` — exit 21
    * `{:error, :not_supported}` — exit 22 (box has no `.slots` machinery)
    * `{:error, :already_running}` — exit 23 (script flock held)
    * `{:error, {:preflight_failed, code}}` — any other outcome (incl. an
      exit 0 with no parseable sha) → the caller FAILS CLOSED, never flips.
  """
  @spec preflight_rollback() ::
          {:ok, String.t()}
          | {:error,
             :no_previous_slot | :not_supported | :already_running | {:preflight_failed, term()}}
  def preflight_rollback do
    {exe, args} =
      Keyword.get(config(), :rollback_preflight_command, @default_rollback_preflight_command)

    case bounded_preflight(exe, args) do
      # A hung preflight is force-killed at the deadline and fails closed — never
      # a silent flip, never an unbounded hang of the admin request.
      {:preflight_timeout, ms} ->
        {:error, {:preflight_failed, {:preflight_timeout, ms}}}

      {:preflight_crashed, reason} ->
        {:error, {:preflight_failed, reason}}

      {output, 0} ->
        case Regex.run(@target_sha_re, output) do
          [_, sha] -> {:ok, sha}
          # exit 0 but no sha = a malformed success; refuse rather than flip
          # to garbage (deny-path: never a flip to an unknown target).
          nil -> {:error, {:preflight_failed, {:no_target_sha, 0}}}
        end

      {_output, 21} ->
        {:error, :no_previous_slot}

      {_output, 22} ->
        {:error, :not_supported}

      {_output, 23} ->
        {:error, :already_running}

      {_output, code} ->
        {:error, {:preflight_failed, code}}
    end
  rescue
    # System.cmd raises (e.g. ErlangError :enoent) when the executable is
    # missing — a preflight that cannot even run is a fail-closed refusal,
    # never a silent flip. (With async_nolink the raise surfaces as a crash
    # tuple below; this rescue stays a backstop.)
    error -> {:error, {:preflight_failed, error}}
  end

  # Run the read-only preflight probe under a hard deadline. Mirrors
  # `studio_chat/titles.ex` per-site: Task.yield waits, Task.shutdown brutal-kills
  # a child that outlives the deadline. `async_nolink` (via the app's
  # TaskSupervisor) so a missing/crashing executable degrades to a `{:exit, _}`
  # crash tuple here rather than taking the caller down.
  #
  # Sobelow CI.System is a false-positive: `exe`/`args` come from module config
  # (`@default_rollback_preflight_command` or a test-only override), never request
  # data — no shell string, no client input. This inline skip replaces the
  # line-anchored `.sobelow-skips` fingerprint (`runner.ex:114`) that the deadline
  # wrapper moved System.cmd off of.
  # sobelow_skip ["CI.System"]
  defp bounded_preflight(exe, args) do
    task =
      Task.Supervisor.async_nolink(Barkpark.TaskSupervisor, fn ->
        System.cmd(exe, args, cd: run_cd(), stderr_to_stdout: true)
      end)

    ms = Keyword.get(config(), :preflight_timeout_ms, @default_preflight_timeout_ms)

    case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:preflight_crashed, reason}
      nil -> {:preflight_timeout, ms}
    end
  end

  @doc """
  The current run status: `state` (`:idle` | `:running` | `:done`),
  `exit_code` (nil until a run finishes; `-1` port died, `-2` deadline,
  `-3` interrupted by a BEAM restart with no recoverable outcome), the bounded
  `log` (oldest line first), and `started_at` / `finished_at`. Never raises.

  When the process is not answering it falls back to the durable run records
  (see the moduledoc), never to a blank `:idle` that would hide a real run.
  """
  @spec status() :: map()
  def status, do: safe_call(:status, render_status(disk_state()))

  @doc """
  The directory holding the durable run records. Must survive a BEAM restart
  and a rebuild — see the moduledoc.
  """
  @spec run_state_dir() :: String.t()
  def run_state_dir do
    Keyword.get(config(), :run_state_dir) || Path.join(run_cd(), ".bp-self-update-runs")
  end

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

  @impl true
  def init(_opts) do
    # The command port is linked to this process; trap so an abnormal port
    # death becomes a :done state instead of taking the Runner down.
    Process.flag(:trap_exit, true)
    {:ok, recover()}
  end

  @impl true
  def handle_call({:trigger, mode}, _from, state) do
    cond do
      not enabled?() ->
        {:reply, {:error, :disabled}, state}

      state.run == :running ->
        {:reply, {:error, :already_running}, state}

      true ->
        case open_port(mode) do
          {:ok, port} ->
            # Watchdog: force-close a run that outlives the deadline so `running?`
            # can't wedge true (and block every future trigger) until a BEAM restart.
            schedule_run_deadline(port)

            state = %{
              state
              | run: :running,
                port: port,
                mode: mode,
                log: [],
                started_at: DateTime.utc_now(),
                finished_at: nil,
                run_id: new_run_id(),
                os_pid: port_os_pid(port),
                orphan?: false
            }

            _ = persist_start(state)
            {:reply, {:ok, :started}, state}

          {:error, _reason} ->
            {:reply, {:error, :start_failed}, state}
        end
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, render_status(state), state}
  end

  @impl true
  def handle_info({port, {:data, {_eol_or_noeol, line}}}, %{port: port} = state) do
    {:noreply, push_log(state, line)}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    {:noreply, finish(state, code)}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) when state.run == :running do
    # Abnormal port death without an exit_status — record a failure, never crash.
    state = push_log(state, "[runner] command port closed: #{inspect(reason)}")
    {:noreply, finish(state, -1)}
  end

  # Deadline watchdog fired for the CURRENT run — force-close the port and record
  # a bounded failure so `running?` flips back to done. Matches only the live port
  # + a still-:running state; a stale deadline from an already-finished run has a
  # nil `state.port`, so it falls through to the catch-all below.
  def handle_info({:run_deadline, port}, %{port: port, run: :running} = state) do
    _ = close_port(port)

    state =
      push_log(state, "[runner] run exceeded #{run_deadline_ms()}ms deadline — force-closed")

    {:noreply, finish(state, -2)}
  end

  # A RE-ATTACHED run (its child outlived the process that spawned it): poll the
  # pid; once it is gone, recover the outcome exactly as `init/1` would have.
  def handle_info(
        {:orphan_check, run_id},
        %{run: :running, orphan?: true, run_id: run_id} = state
      ) do
    if os_pid_alive?(state.os_pid) do
      schedule_orphan_check(run_id)
      {:noreply, state}
    else
      {:noreply, finish_interrupted(%{state | log: read_log_tail()})}
    end
  end

  # A re-attached run that outlived its deadline. There is no port to close and
  # a bare pid is not ours to signal (it may have been reused) — release the
  # slot and say so; the script's own flock remains the cross-process backstop.
  def handle_info(
        {:orphan_deadline, run_id},
        %{run: :running, orphan?: true, run_id: run_id} = state
      ) do
    state =
      push_log(
        state,
        "[runner] re-attached run exceeded #{run_deadline_ms()}ms deadline — released, pid #{state.os_pid} not signalled"
      )

    {:noreply, finish(state, -2)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── internals ───────────────────────────────────────────────────────────

  defp schedule_run_deadline(port) do
    Process.send_after(self(), {:run_deadline, port}, run_deadline_ms())
  end

  defp run_deadline_ms, do: Keyword.get(config(), :run_deadline_ms, @default_run_deadline_ms)

  # Closing a `{:spawn_executable, _}` port closes the pipe fds and sends the child
  # NO signal — it terminates only a program that exits on stdin EOF or dies to
  # SIGPIPE, which is most but not all of them (GH #6681 proved the gap on the
  # Codex runtime, where `Session.reap_port/1` now SIGKILLs the pid after the
  # close). This watchdog has the same hole for a self-update child that ignores
  # EOF; reaping here is filed, not done. Tolerate an already-closed port
  # (ArgumentError) so the watchdog never crashes the Runner.
  defp close_port(port) do
    Port.close(port)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp initial_state do
    # `mode` records which verb the current/last run is — defaults to
    # :self_update so a box that has never run reports the primary verb.
    %{
      run: :idle,
      port: nil,
      mode: :self_update,
      log: [],
      started_at: nil,
      finished_at: nil,
      run_id: nil,
      os_pid: nil,
      orphan?: false
    }
  end

  # Each mode resolves its own injectable command (tests stub these); the
  # single-flight, port handling, and log capture are identical for both.
  defp command_for(:rollback),
    do: Keyword.get(config(), :rollback_command, @default_rollback_command)

  defp command_for(_self_update),
    do: Keyword.get(config(), :command, @default_command)

  defp open_port(mode) do
    {exe, args} = command_for(mode)

    case System.find_executable(exe) do
      nil ->
        {:error, {:executable_not_found, exe}}

      path ->
        port =
          Port.open(
            {:spawn_executable, path},
            [:binary, :exit_status, :stderr_to_stdout, {:line, 4096}, args: args, cd: run_cd()]
          )

        {:ok, port}
    end
  rescue
    # Port.open raises on e.g. a missing cd — degrade to a start failure.
    error -> {:error, error}
  end

  # Configured working dir, or the repo root: the BEAM's cwd is api/ under
  # both `mix phx.server` and start.sh, so the parent is the repo root (see
  # the moduledoc for the assumption + the BARKPARK_SELF_UPDATE_CD override).
  defp run_cd do
    Keyword.get(config(), :cd) || Path.dirname(File.cwd!())
  end

  # Bounded log: newest-first internally, oldest dropped beyond the cap. Every
  # line is folded through the recorded-log scrubber FIRST, so neither the
  # served status nor the on-disk record ever holds a raw secret-shaped value.
  defp push_log(state, line) do
    line = BuildLogScrub.raw(line)
    _ = append_log_line(state, line)
    %{state | log: Enum.take([line | state.log], max_log_lines())}
  end

  defp max_log_lines, do: Keyword.get(config(), :max_log_lines, @default_max_log_lines)

  # ── durable run records ─────────────────────────────────────────────────
  #
  # Every write is best-effort: a record that cannot be written must never
  # block, fail or crash an update — it only costs the post-restart status.
  # Paths are `run_state_dir()` (config or a repo-root join) plus a fixed file
  # name; nothing request-derived reaches a path.

  defp finish(state, code) do
    state = %{state | run: {:done, code}, port: nil, finished_at: DateTime.utc_now()}
    _ = write_terminal(state)
    state
  end

  defp new_run_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  defp record_path(name), do: Path.join(run_state_dir(), name)

  # Order matters: the previous run's terminal record goes FIRST, so a crash
  # between the two steps leaves a manifest with no terminal record (→ recovered
  # as interrupted), never a stale terminal record the new manifest would adopt.
  # (The run_id match makes that doubly impossible.)
  # sobelow_skip ["Traversal.FileModule"]
  defp persist_start(state) do
    File.mkdir_p!(run_state_dir())
    _ = File.rm(record_path(@terminal_file))
    File.write!(record_path(@log_file), "")

    write_json(@manifest_file, %{
      "run_id" => state.run_id,
      "mode" => Atom.to_string(state.mode),
      "started_at" => DateTime.to_iso8601(state.started_at),
      "os_pid" => state.os_pid
    })
  rescue
    error -> record_failed(:manifest, error)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp append_log_line(%{run_id: nil}, _line), do: :ok

  defp append_log_line(_state, line) do
    File.write(record_path(@log_file), [line, "\n"], [:append])
  rescue
    _ -> :ok
  end

  defp write_terminal(%{run_id: nil}), do: :ok

  defp write_terminal(state) do
    write_json(@terminal_file, %{
      "run_id" => state.run_id,
      "mode" => Atom.to_string(state.mode),
      "exit_code" => run_exit_code(state.run),
      "started_at" => iso(state.started_at),
      "finished_at" => iso(state.finished_at),
      "log" => Enum.reverse(state.log),
      "log_scrub" => BuildLogScrub.version()
    })
  rescue
    error -> record_failed(:terminal, error)
  end

  # Write-then-rename so a reader never sees a half-written record.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_json(name, map) do
    path = record_path(name)
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(map))
    File.rename!(tmp, path)
    :ok
  end

  defp record_failed(what, error) do
    Logger.warning("[self-update] #{what} record not written: #{inspect(error)}")
    {:error, error}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_json(name) do
    with {:ok, raw} <- File.read(record_path(name)),
         {:ok, %{} = json} <- Jason.decode(raw) do
      json
    else
      _ -> nil
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_log_tail do
    case File.read(record_path(@log_file)) do
      {:ok, raw} ->
        raw
        |> String.split("\n", trim: true)
        |> Enum.take(-max_log_lines())
        |> Enum.reverse()

      {:error, _} ->
        []
    end
  end

  # ── recovery (init/1 and the dead-process status fallback) ─────────────

  # init/1: rebuild state from the records, then perform the side effects the
  # pure read cannot — re-arm a re-attached run, persist a recovered outcome.
  defp recover do
    case read_disk() do
      {:idle, state} ->
        state

      {:terminal, state} ->
        state

      {:alive, state} ->
        schedule_orphan_check(state.run_id)
        Process.send_after(self(), {:orphan_deadline, state.run_id}, remaining_deadline_ms(state))
        state

      {:gone, state} ->
        finish_interrupted(state)
    end
  rescue
    # A malformed record must never take the boot down — degrade to idle.
    error ->
      Logger.warning("[self-update] run-record recovery skipped: #{inspect(error)}")
      initial_state()
  end

  # status/0 fallback when the process is not answering: the same read, no
  # writes and no timers (this runs in the CALLER's process).
  defp disk_state do
    case read_disk() do
      {:gone, state} -> interrupted_outcome(state)
      {_kind, state} -> state
    end
  rescue
    _ -> initial_state()
  end

  defp read_disk do
    with %{"run_id" => run_id} = manifest when is_binary(run_id) <- read_json(@manifest_file),
         {:ok, started_at, _} <- DateTime.from_iso8601(to_string(manifest["started_at"])) do
      base = %{
        initial_state()
        | mode: decode_mode(manifest["mode"]),
          started_at: started_at,
          run_id: run_id,
          os_pid: pid_or_nil(manifest["os_pid"])
      }

      case read_json(@terminal_file) do
        %{"run_id" => ^run_id} = terminal ->
          {:terminal, from_terminal(base, terminal)}

        _no_terminal ->
          state = %{base | run: :running, log: read_log_tail()}

          if os_pid_alive?(state.os_pid),
            do: {:alive, %{state | orphan?: true}},
            else: {:gone, state}
      end
    else
      _ -> {:idle, initial_state()}
    end
  end

  defp from_terminal(base, terminal) do
    code =
      if is_integer(terminal["exit_code"]), do: terminal["exit_code"], else: @interrupted_exit

    %{
      base
      | run: {:done, code},
        mode: decode_mode(terminal["mode"]),
        log: terminal["log"] |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.reverse(),
        finished_at: parse_dt(terminal["finished_at"])
    }
  end

  defp finish_interrupted(state) do
    state = interrupted_outcome(state)
    _ = write_terminal(state)
    state
  end

  # The run's child is gone and left no terminal record: the BEAM (and with it
  # this process) died mid-run — on the happy path, by the restart the run
  # itself queued. Recover the outcome from deploy-rebuild.sh's own flight
  # recorder when it names THIS run; otherwise say interrupted, never idle.
  defp interrupted_outcome(state) do
    now = DateTime.utc_now()

    case matching_deploy_status(state) do
      %{"phase" => phase, "outcome" => outcome} = record ->
        code = Map.get(@deploy_status_exits, {phase, outcome}, @interrupted_exit)

        line =
          "[runner] service restarted during this run; deploy-rebuild recorded " <>
            "phase=#{phase} outcome=#{outcome} sha=#{record["sha"]} at #{record["ts"]}"

        %{push_log_memory(state, line) | run: {:done, code}, port: nil, finished_at: now}

      nil ->
        line =
          "[runner] interrupted: the service restarted while this run was in flight " <>
            "and no terminal record exists — outcome unknown"

        %{
          push_log_memory(state, line)
          | run: {:done, @interrupted_exit},
            port: nil,
            finished_at: now
        }
    end
  end

  # Recovery lines are appended to memory + the terminal record, not run.log:
  # the log file is the child's captured output.
  defp push_log_memory(state, line),
    do: %{state | log: Enum.take([line | state.log], max_log_lines())}

  # A flight record belongs to this run only if deploy-rebuild wrote it from the
  # pid we spawned (self-update.sh `exec`s it, so `$$` is our child's pid) and
  # no earlier than the run started (its `ts` is second-granular).
  defp matching_deploy_status(%{os_pid: pid, started_at: %DateTime{} = started_at})
       when is_integer(pid) do
    with %{"pid" => ^pid, "ts" => ts} = record <- read_deploy_status(),
         {:ok, at, _} <- DateTime.from_iso8601(to_string(ts)),
         true <- DateTime.compare(at, DateTime.truncate(started_at, :second)) != :lt do
      record
    else
      _ -> nil
    end
  end

  defp matching_deploy_status(_state), do: nil

  # sobelow_skip ["Traversal.FileModule"]
  defp read_deploy_status do
    path =
      Keyword.get(config(), :deploy_status_file) || Path.join(run_cd(), ".deploy-status.json")

    with {:ok, raw} <- File.read(path),
         {:ok, %{} = json} <- Jason.decode(raw) do
      json
    else
      _ -> nil
    end
  end

  defp schedule_orphan_check(run_id) do
    ms = Keyword.get(config(), :orphan_poll_ms, @default_orphan_poll_ms)
    Process.send_after(self(), {:orphan_check, run_id}, ms)
  end

  defp remaining_deadline_ms(state) do
    elapsed = DateTime.diff(DateTime.utc_now(), state.started_at, :millisecond)
    max(run_deadline_ms() - elapsed, 0)
  end

  # `kill -0` probes existence without signalling. Pid reuse can make a dead
  # run look alive; the re-armed deadline bounds how long that can hold the slot.
  # sobelow_skip ["CI.System"]
  defp os_pid_alive?(pid) when is_integer(pid) and pid > 0 do
    case System.find_executable("kill") do
      nil ->
        false

      kill ->
        match?({_, 0}, System.cmd(kill, ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
    end
  rescue
    _ -> false
  end

  defp os_pid_alive?(_pid), do: false

  defp decode_mode("rollback"), do: :rollback
  defp decode_mode(_other), do: :self_update

  defp pid_or_nil(pid) when is_integer(pid), do: pid
  defp pid_or_nil(_other), do: nil

  defp parse_dt(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_dt(_value), do: nil

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp render_status(state) do
    %{
      state: run_state(state.run),
      mode: state.mode,
      exit_code: run_exit_code(state.run),
      log: Enum.reverse(state.log),
      started_at: state.started_at,
      finished_at: state.finished_at
    }
  end

  defp run_state(:idle), do: :idle
  defp run_state(:running), do: :running
  defp run_state({:done, _code}), do: :done

  defp run_exit_code({:done, code}), do: code
  defp run_exit_code(_run), do: nil
end
