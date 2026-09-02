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
  process degrades to `{:error, :disabled}` / a reattached (else idle) status
  map, and a command that fails to start or dies abnormally lands as a `:done`
  state with a non-zero exit code, never as a Runner crash.

  ## The run outlives the process that owns it (task-dba2b246d420c372)

  The default command is `bash scripts/self-update.sh`, which fast-forwards the
  checkout so the post-merge hook rebuilds and RESTARTS THE SERVICE. The BEAM
  that started the run is therefore killed BY the run, on the happy path. In-memory
  state alone means the operator who pressed the button comes back to `:idle` with
  an empty log — indistinguishable from "never ran". That is not an edge case; it
  is the normal outcome of a successful update.

  So the run is also written to disk, in the shape `Barkpark.Sites.DeployRunner`
  already uses for the same problem:

    * `<run_state_dir>/current.manifest.json` — the POINTER to the current/last
      run (run_tag, mode, started_at, log path). Overwritten per trigger.
    * `<run_state_dir>/<run_tag>.log` — the command's output, appended as it
      arrives, so a run cut short still has everything printed before the cut.
    * `<run_state_dir>/<run_tag>.terminal.json` — the durable RECORD: state,
      exit code, started_at/finished_at. Written when the run reaches a terminal
      state, and this is the only thing that can answer "how did it end".

  `init/1` reattaches from those files, and the `status/0` fallback (Runner not
  running at all) reads them too. Three outcomes:

    * no manifest → `:idle` (this box has never run one)
    * manifest + terminal record → that record's `:done` state, exit code and log
    * manifest, NO terminal record → `:interrupted`: the BEAM died mid-run, which
      is exactly what a successful self-update does to it. The log is reported;
      the exit code is `nil`, because nothing ever observed one. The interruption
      is stamped as a terminal record on reattach so the answer stays stable.

  There is deliberately no re-attach to the PROCESS: unlike DeployRunner's systemd
  units, the child here died with the BEAM's port. Reattaching to the RECORD is
  the whole job.
  """

  use GenServer

  require Logger

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
  # Directory for the run manifest / log / terminal records (see the moduledoc).
  # Config-overridable per env, which is also how the tests get a tmp dir.
  @default_run_state_dirname ".bp-self-update-runs"
  # Retention: newest N runs' log + terminal record survive a prune.
  @default_max_run_records 20
  @manifest_name "current.manifest.json"

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
  The current run status: `state` (`:idle` | `:running` | `:done` |
  `:interrupted`), `exit_code` (nil until a run finishes, and nil forever for an
  `:interrupted` run — nothing observed one), the bounded `log` (oldest line
  first), and `started_at` / `finished_at`. Never raises.

  `:interrupted` means a run was started and the BEAM went away before it
  finished — the ordinary outcome of a successful self-update, which restarts
  this service. It is reported from disk, not from memory.
  """
  @spec status() :: map()
  def status, do: safe_call(:status, render_status(reattached_state()))

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
    # Reattach to whatever the PREVIOUS BEAM left on disk before answering any
    # status call. On the self-update happy path that previous BEAM was killed by
    # the very run we are reporting on (see the moduledoc).
    {:ok, reattached_state()}
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

            started_at = DateTime.utc_now()
            run_tag = new_run_tag(mode, started_at)
            # Write the pointer BEFORE replying: from here on the run exists on
            # disk even if this BEAM never gets another scheduling slice.
            _ = write_manifest(run_tag, mode, started_at)

            {:reply, {:ok, :started},
             %{
               state
               | run: :running,
                 port: port,
                 mode: mode,
                 log: [],
                 run_tag: run_tag,
                 started_at: started_at,
                 finished_at: nil
             }}

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

  def handle_info(_msg, state), do: {:noreply, state}

  # ── internals ───────────────────────────────────────────────────────────

  defp schedule_run_deadline(port) do
    Process.send_after(self(), {:run_deadline, port}, run_deadline_ms())
  end

  defp run_deadline_ms, do: Keyword.get(config(), :run_deadline_ms, @default_run_deadline_ms)

  # Closing a `{:spawn_executable, _}` port closes the pipe fds and sends the child
  # NO signal — it terminates only a program that exits on stdin EOF or dies to
  # SIGPIPE, which is most but not all of them (GH #6681). This watchdog is the
  # sharpest case in the tree: the deadline fires precisely BECAUSE the update
  # child is misbehaving, so the one thing a bare close cannot assume is that
  # this particular child honours EOF. `PortReaper.reap/1` reads the os_pid while
  # the port is still open, closes it, and SIGKILLs the pid best-effort. It is
  # total (never raises, never exits), so the watchdog still cannot crash the
  # Runner on an already-closed port.
  defp close_port(port), do: Barkpark.PortReaper.reap(port)

  defp initial_state do
    # `mode` records which verb the current/last run is — defaults to
    # :self_update so a box that has never run reports the primary verb.
    %{
      run: :idle,
      port: nil,
      mode: :self_update,
      log: [],
      run_tag: nil,
      started_at: nil,
      finished_at: nil
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

  # Bounded log: newest-first internally, oldest dropped beyond the cap. The
  # DISK copy is unbounded-by-line but append-only and per-run: it is the only
  # thing that survives the restart this run causes, and dropping the oldest
  # lines there would drop exactly the "what did the update do" prefix.
  defp push_log(state, line) do
    max = Keyword.get(config(), :max_log_lines, @default_max_log_lines)
    _ = append_log_line(state[:run_tag], line)
    %{state | log: Enum.take([line | state.log], max)}
  end

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
  defp run_state(:interrupted), do: :interrupted
  defp run_state({:done, _code}), do: :done

  defp run_exit_code({:done, code}), do: code
  defp run_exit_code(_run), do: nil

  # ── durable run records ────────────────────────────────────────────────
  # Everything below is best-effort by contract: a box with an unwritable run
  # state dir must still run updates. A failed write costs the operator the
  # post-restart status, never the update.

  @doc """
  Where the run manifest, logs and terminal records live. `run_state_dir:` in
  this module's config overrides it; the default sits beside the checkout the
  run operates on.
  """
  @spec run_state_dir() :: String.t()
  def run_state_dir do
    Keyword.get(config(), :run_state_dir) || Path.join(run_cd(), @default_run_state_dirname)
  end

  # A run_tag is unique per run: the mode, the start instant, and 4 random hex
  # so two runs inside the same second cannot share a log.
  defp new_run_tag(mode, %DateTime{} = started_at) do
    stamp =
      started_at
      |> DateTime.to_iso8601(:basic)
      |> String.replace(~r/[^0-9TZ]/, "")

    "#{mode}-#{stamp}-#{Base.encode16(:crypto.strong_rand_bytes(2), case: :lower)}"
  end

  # Reachability for the Sobelow traversal skips below: every path handed to
  # File.* in this module is `run_state_dir()` (a config constant, or the
  # checkout's own parent) joined with a run_tag this module MINTED from a mode
  # atom + a timestamp + random hex. No request data, no caller-supplied path.
  defp manifest_path, do: Path.join(run_state_dir(), @manifest_name)
  defp log_path(run_tag), do: Path.join(run_state_dir(), "#{run_tag}.log")
  defp terminal_path(run_tag), do: Path.join(run_state_dir(), "#{run_tag}.terminal.json")

  # sobelow_skip ["Traversal.FileModule"]
  defp write_manifest(run_tag, mode, started_at) do
    dir = run_state_dir()
    File.mkdir_p!(dir)

    payload = %{
      "run_tag" => run_tag,
      "mode" => to_string(mode),
      "started_at" => DateTime.to_iso8601(started_at),
      "log_file" => log_path(run_tag)
    }

    result = File.write(manifest_path(), Jason.encode!(payload))
    _ = prune_run_records(dir)
    result
  rescue
    error ->
      Logger.warning("[self-update] could not write the run manifest: #{inspect(error)}")
      :ok
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp append_log_line(run_tag, line) when is_binary(run_tag) do
    File.write(log_path(run_tag), [line, "\n"], [:append])
  rescue
    _ -> :ok
  end

  defp append_log_line(_run_tag, _line), do: :ok

  # The one place a terminal record is written. `state` is either an atom
  # (:interrupted) or an exit code.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_terminal_record(run_tag, mode, run_state, exit_code, started_at, finished_at)
       when is_binary(run_tag) do
    File.mkdir_p!(run_state_dir())

    payload = %{
      "run_tag" => run_tag,
      "mode" => to_string(mode),
      "state" => to_string(run_state),
      "exit_code" => exit_code,
      "started_at" => iso_or_nil(started_at),
      "finished_at" => iso_or_nil(finished_at)
    }

    File.write(terminal_path(run_tag), Jason.encode!(payload))
  rescue
    error ->
      Logger.warning("[self-update] could not write the terminal record: #{inspect(error)}")
      :ok
  end

  defp write_terminal_record(_run_tag, _mode, _state, _code, _started, _finished), do: :ok

  defp iso_or_nil(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso_or_nil(_), do: nil

  # Terminal transition: stamp the record, THEN move in-memory state. Both
  # orderings are observable only through status/0, but the record is the copy
  # that survives, so it is written first.
  defp finish(state, exit_code) do
    finished_at = DateTime.utc_now()

    _ =
      write_terminal_record(
        state[:run_tag],
        state.mode,
        :done,
        exit_code,
        state.started_at,
        finished_at
      )

    %{state | run: {:done, exit_code}, port: nil, finished_at: finished_at}
  end

  # Rebuild the last known run from disk. Total: any unreadable/garbage record
  # degrades to the idle state, never a crash on boot or on a status call.
  defp reattached_state do
    case read_manifest() do
      {:ok, manifest} -> reattach_from(manifest)
      :error -> initial_state()
    end
  rescue
    _ -> initial_state()
  catch
    _, _ -> initial_state()
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_manifest do
    with {:ok, raw} <- File.read(manifest_path()),
         {:ok, %{"run_tag" => tag} = manifest} when is_binary(tag) <- Jason.decode(raw) do
      {:ok, manifest}
    else
      _ -> :error
    end
  end

  defp reattach_from(%{"run_tag" => run_tag} = manifest) do
    mode = decode_mode(manifest["mode"])
    started_at = decode_dt(manifest["started_at"])
    log = read_log(run_tag)

    case read_terminal_record(run_tag) do
      {:ok, %{"state" => "interrupted"} = record} ->
        %{
          initial_state()
          | run: :interrupted,
            mode: mode,
            run_tag: run_tag,
            log: log,
            started_at: started_at,
            finished_at: decode_dt(record["finished_at"])
        }

      {:ok, record} ->
        %{
          initial_state()
          | run: {:done, record["exit_code"]},
            mode: mode,
            run_tag: run_tag,
            log: log,
            started_at: started_at,
            finished_at: decode_dt(record["finished_at"])
        }

      :error ->
        # A manifest with no terminal record: the run was in flight when this
        # BEAM's predecessor went away — which is precisely what a successful
        # self-update does. Stamp the interruption so the answer is durable and
        # this reconstruction happens once, not on every boot.
        finished_at = log_mtime(run_tag)

        _ =
          write_terminal_record(run_tag, mode, :interrupted, nil, started_at, finished_at)

        %{
          initial_state()
          | run: :interrupted,
            mode: mode,
            run_tag: run_tag,
            log: log,
            started_at: started_at,
            finished_at: finished_at
        }
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_terminal_record(run_tag) do
    with {:ok, raw} <- File.read(terminal_path(run_tag)),
         {:ok, record} when is_map(record) <- Jason.decode(raw) do
      {:ok, record}
    else
      _ -> :error
    end
  end

  # Newest-first, capped the same way the live log is.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_log(run_tag) do
    max = Keyword.get(config(), :max_log_lines, @default_max_log_lines)

    case File.read(log_path(run_tag)) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.reverse()
        |> Enum.drop_while(&(&1 == ""))
        |> Enum.take(max)

      {:error, _} ->
        []
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp log_mtime(run_tag) do
    case File.stat(log_path(run_tag), time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> DateTime.from_unix!(mtime)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp decode_mode("rollback"), do: :rollback
  defp decode_mode(_), do: :self_update

  defp decode_dt(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp decode_dt(_), do: nil

  # Keep the newest N runs' artifacts. The manifest is a pointer and is never
  # pruned; a run whose log is pruned keeps nothing to report, which is the
  # honest outcome for the 21st-oldest run on the box.
  # sobelow_skip ["Traversal.FileModule"]
  defp prune_run_records(dir) do
    max = Keyword.get(config(), :max_run_records, @default_max_run_records)

    tags =
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".terminal.json"))
      |> Enum.map(&String.replace_suffix(&1, ".terminal.json", ""))

    tags
    |> Enum.sort_by(&log_sort_key(dir, &1), :desc)
    |> Enum.drop(max)
    |> Enum.each(fn tag ->
      _ = File.rm(terminal_path(tag))
      _ = File.rm(log_path(tag))
    end)

    :ok
  rescue
    _ -> :ok
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp log_sort_key(dir, tag) do
    case File.stat(Path.join(dir, "#{tag}.terminal.json"), time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      _ -> 0
    end
  end
end
