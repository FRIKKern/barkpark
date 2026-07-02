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
  process degrades to `{:error, :disabled}` / an idle status map, and a
  command that fails to start or dies abnormally lands as a `:done` state
  with a non-zero exit code, never as a Runner crash.
  """

  use GenServer

  @default_command {"bash", ["scripts/self-update.sh"]}
  @default_max_log_lines 500

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
  def trigger, do: safe_call(:trigger, {:error, :disabled})

  @doc """
  The current run status: `state` (`:idle` | `:running` | `:done`),
  `exit_code` (nil until a run finishes), the bounded `log` (oldest line
  first), and `started_at` / `finished_at`. Never raises.
  """
  @spec status() :: map()
  def status, do: safe_call(:status, render_status(initial_state()))

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
    {:ok, initial_state()}
  end

  @impl true
  def handle_call(:trigger, _from, state) do
    cond do
      not enabled?() ->
        {:reply, {:error, :disabled}, state}

      state.run == :running ->
        {:reply, {:error, :already_running}, state}

      true ->
        case open_port() do
          {:ok, port} ->
            {:reply, {:ok, :started},
             %{
               state
               | run: :running,
                 port: port,
                 log: [],
                 started_at: DateTime.utc_now(),
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
    {:noreply, %{state | run: {:done, code}, port: nil, finished_at: DateTime.utc_now()}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) when state.run == :running do
    # Abnormal port death without an exit_status — record a failure, never crash.
    state = push_log(state, "[runner] command port closed: #{inspect(reason)}")
    {:noreply, %{state | run: {:done, -1}, port: nil, finished_at: DateTime.utc_now()}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── internals ───────────────────────────────────────────────────────────

  defp initial_state do
    %{run: :idle, port: nil, log: [], started_at: nil, finished_at: nil}
  end

  defp open_port do
    {exe, args} = Keyword.get(config(), :command, @default_command)

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

  # Bounded log: newest-first internally, oldest dropped beyond the cap.
  defp push_log(state, line) do
    max = Keyword.get(config(), :max_log_lines, @default_max_log_lines)
    %{state | log: Enum.take([line | state.log], max)}
  end

  defp render_status(state) do
    %{
      state: run_state(state.run),
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
