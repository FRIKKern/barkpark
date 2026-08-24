defmodule Barkpark.StudioChat.Runtime.Codex.Session do
  @moduledoc false

  use GenServer

  require Logger

  alias Barkpark.StudioChat.Runtime.Codex.Protocol

  @default_timeout 15_000

  # Ceiling on the JSONL line-reassembly buffer. A codex app-server that streams
  # newline-free (or runaway) output would otherwise grow `state.buffer` without
  # bound — `split_lines/1` returns `{[], whole_buffer}` on a newline-free chunk,
  # so no line is ever consumed and the per-request `%{failure:}` guards never
  # fire. Config-overridable via the sibling `:max_buffer_bytes` key in the
  # `:codex_app_server` app-env keyword (tests shrink it to force the breach).
  @default_max_buffer_bytes 8 * 1024 * 1024

  def start(opts) do
    timeout = Map.get(opts, :timeout_ms, @default_timeout)

    with {:ok, pid} <- GenServer.start(__MODULE__, opts),
         result <- GenServer.call(pid, {:open, opts}, timeout + 1_000) do
      case result do
        {:ok, opened} ->
          {:ok, Map.put(opened, :runtime, pid)}

        {:error, _reason} = error ->
          GenServer.stop(pid, :normal)
          error
      end
    end
  catch
    :exit, reason -> {:error, {:app_server_exit, reason}}
  end

  def probe(opts) do
    case start(Map.put(opts, :probe_only, true)) do
      {:ok, %{runtime: pid, readiness: readiness}} ->
        GenServer.stop(pid, :normal)
        {:ok, readiness}

      error ->
        error
    end
  end

  def request(runtime, operation, params) do
    GenServer.call(unwrap(runtime), {:request, operation, params}, request_timeout(runtime))
  catch
    :exit, reason -> {:error, {:app_server_exit, reason}}
  end

  def answer_approval(runtime, approval_id, decision) do
    GenServer.call(unwrap(runtime), {:approval, approval_id, decision}, request_timeout(runtime))
  catch
    :exit, reason -> {:error, {:app_server_exit, reason}}
  end

  def task_hands(runtime) do
    GenServer.call(unwrap(runtime), :task_hands)
  catch
    :exit, _ -> :unknown
  end

  def close(runtime) do
    GenServer.stop(unwrap(runtime), :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp unwrap(%{runtime: pid}) when is_pid(pid), do: pid
  defp unwrap(pid) when is_pid(pid), do: pid

  defp request_timeout(%{timeout_ms: timeout}), do: timeout + 1_000
  defp request_timeout(_runtime), do: @default_timeout + 1_000

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    task_hands = setup_task_hands(opts)
    opts = Map.put(opts, :task_hands_env, task_hands.env)

    with {:ok, port} <- open_port(opts) do
      sink = Map.get(opts, :sink)
      sink_ref = if is_pid(sink), do: Process.monitor(sink)

      {:ok,
       %{
         port: port,
         sink: sink,
         sink_ref: sink_ref,
         buffer: "",
         next_id: 1,
         pending: %{},
         approvals: %{},
         failure: nil,
         timeout_ms: Map.get(opts, :timeout_ms, @default_timeout),
         session_id: Map.get(opts, :session_id),
         thread_id: Map.get(opts, :provider_session_id),
         turn_id: nil,
         sequence: 0,
         runtime_ingress_token: Map.get(opts, :runtime_ingress_token),
         task_hands: task_hands.status,
         task_token: task_hands.token,
         thread_config: task_hands.config
       }}
    else
      error ->
        cleanup_task_token(task_hands.token)
        error
    end
  end

  @impl true
  def handle_call({:open, opts}, from, state) do
    opts = Map.put(opts, :thread_config, state.thread_config)

    params = %{
      "clientInfo" => %{
        "name" => "barkpark",
        "title" => "Barkpark Studio Chat",
        "version" => Barkpark.BuildInfo.version()
      },
      "capabilities" => %{"experimentalApi" => false}
    }

    {:noreply, send_request(state, "initialize", params, {:initialize, from, opts})}
  end

  def handle_call(:task_hands, _from, state), do: {:reply, state.task_hands, state}

  def handle_call({:request, _operation, _params}, _from, %{failure: reason} = state)
      when not is_nil(reason) do
    {:reply, {:error, reason}, state}
  end

  def handle_call({:approval, _approval_id, _decision}, _from, %{failure: reason} = state)
      when not is_nil(reason) do
    {:reply, {:error, reason}, state}
  end

  def handle_call({:request, :send_turn, content}, from, state) do
    params = %{
      "threadId" => state.thread_id,
      "input" => normalize_input(content)
    }

    {:noreply, send_request(state, "turn/start", params, {:reply, from, :send_turn})}
  end

  def handle_call({:request, :steer, params}, from, state) do
    input = Map.get(params, :input) || Map.get(params, "input") || Map.get(params, :content)

    wire = %{
      "threadId" => state.thread_id,
      "expectedTurnId" => state.turn_id,
      "input" => normalize_input(input)
    }

    {:noreply, send_request(state, "turn/steer", wire, {:reply, from, :steer})}
  end

  def handle_call({:request, :interrupt, _params}, from, state) do
    wire = %{"threadId" => state.thread_id, "turnId" => state.turn_id}
    {:noreply, send_request(state, "turn/interrupt", wire, {:reply, from, :interrupt})}
  end

  def handle_call({:approval, approval_id, decision}, _from, state) do
    case Map.pop(state.approvals, to_string(approval_id)) do
      {nil, _approvals} ->
        {:reply, {:error, :unknown_approval}, state}

      {%{request_id: request_id, method: method}, approvals} ->
        case Protocol.approval_response(method, decision) do
          {:ok, result} -> send_response(state.port, request_id, result)
          {:error, error} -> send_error(state.port, request_id, error)
        end

        {:reply, :ok, %{state | approvals: approvals}}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    combined = state.buffer <> data

    if byte_size(combined) > max_buffer_bytes() do
      {:noreply, overflow(state, byte_size(combined))}
    else
      {lines, buffer} = split_lines(combined)
      state = Enum.reduce(lines, %{state | buffer: buffer}, &consume_line/2)
      {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state = emit(state, Protocol.process_failed(context(state), status))
    reply_all_pending(state.pending, {:error, {:process_exit, status}})
    {:stop, {:app_server_exit, status}, %{state | pending: %{}}}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {pending, rest} ->
        reply_pending(pending, {:error, :timeout})
        {:noreply, %{state | pending: rest, failure: :timeout}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{sink_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port} = state) do
    # The rescue is CONFINED to reap_port (below), never wrapped around this
    # whole body (task-95b4b28a56583b1c, twin of task-2f44ed9d10be629f). A
    # whole-body rescue here swallowed a raise out of reap_port AND skipped
    # `cleanup_task_token`, so the session's task-hands credential stayed live
    # past the session that minted it. The revoke must not depend on whether
    # the statement before it raised.
    reap_port(port)
    cleanup_task_token(state[:task_token])
    :ok
  end

  # Closing a `{:spawn_executable, _}` port closes the pipe fds and NOTHING ELSE —
  # the BEAM sends the child no signal, so an app-server that does not exit on
  # stdin EOF (or die to SIGPIPE) is left running, reparented to init, burning
  # whatever CPU it was burning. That is exactly the wedged/runaway provider this
  # module's overflow path exists to stop, so "the port is closed" is not enough:
  # the OS process must be signalled too (GH #6681 — a test stub with the same
  # shape held two cores for 1d19h).
  #
  # The pid is read WHILE the port is still open, never remembered from spawn
  # time: `Port.info/2` answers nil once closed, and a pid cached earlier may
  # since have been reaped and recycled onto an unrelated process.
  #
  # `if Port.info(port), do: ... Port.close(port)` was a check-then-act: it is a
  # membership test (Port.info/1 answers nil once the port is closed) and the
  # port can die inside the window before the close, which then raises badarg.
  # That raise used to escape into terminate/2's whole-body rescue and skip BOTH
  # the kill below and the task-token revoke after it. The membership test bought
  # nothing — the raise has to be handled either way — so it is gone and the
  # rescue is confined to the close alone. The pid is still read BEFORE the
  # close, which is the ordering the paragraph above requires.
  defp reap_port(port) do
    os_pid = port_os_pid(port)

    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    kill_os_process(os_pid)
    :ok
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> os_pid
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # Best-effort by design: the child has usually already exited on EOF, in which
  # case `kill` just reports "no such process". A missing `kill` binary or a
  # racing reap must never take the Session (or its terminate/2) down with it.
  defp kill_os_process(nil), do: :ok

  defp kill_os_process(os_pid) when is_integer(os_pid) do
    System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp consume_line("", state), do: state

  defp consume_line(line, state) do
    case Jason.decode(line) do
      {:ok, message} ->
        consume_message(message, state)

      {:error, _reason} ->
        state
        |> emit(Protocol.malformed(context(state), line))
        |> fail_pending(:malformed_response)
    end
  end

  defp consume_message(%{"id" => id, "result" => result}, state) do
    complete_request(state, id, {:ok, result})
  end

  defp consume_message(%{"id" => id, "error" => error}, state) do
    complete_request(state, id, {:error, sanitize_rpc_error(error)})
  end

  defp consume_message(%{"id" => id, "method" => method} = message, state) do
    state = emit(state, Protocol.normalize(message, context(state)))

    if Protocol.approval_method?(method) do
      approval_id = to_string(id)
      put_in(state, [:approvals, approval_id], %{request_id: id, method: method})
    else
      state
    end
  end

  defp consume_message(%{"method" => _method} = message, state) do
    event = Protocol.normalize(message, context(state))

    state
    |> track_native_ids(message)
    |> emit(event)
  end

  defp consume_message(_message, state), do: state

  defp complete_request(state, id, result) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {pending, rest} ->
        Process.cancel_timer(pending.timer)
        state = %{state | pending: rest}
        complete_pending(state, pending.kind, result)
    end
  end

  defp complete_pending(state, {:initialize, from, opts}, {:ok, _result}) do
    send_notification(state.port, "initialized", nil)
    send_request(state, "account/read", %{}, {:account_read, from, opts})
  end

  defp complete_pending(state, {:account_read, from, opts}, {:ok, result}) do
    readiness = readiness(result)

    cond do
      Map.get(opts, :probe_only, false) ->
        GenServer.reply(from, {:ok, %{readiness: readiness, provider_session_id: nil}})
        state

      not readiness.ready? ->
        GenServer.reply(from, {:error, readiness.reason})
        state

      true ->
        {method, params} = thread_request(opts)
        send_request(state, method, params, {:thread_open, from, readiness})
    end
  end

  defp complete_pending(state, {:thread_open, from, readiness}, {:ok, result}) do
    thread_id = get_in(result, ["thread", "id"])
    state = emit(state, Protocol.acknowledgement(result, context(state)))
    GenServer.reply(from, {:ok, %{provider_session_id: thread_id, readiness: readiness}})
    %{state | thread_id: thread_id}
  end

  defp complete_pending(state, {:reply, from, :send_turn}, {:ok, result}) do
    turn_id = get_in(result, ["turn", "id"])
    GenServer.reply(from, :ok)
    %{state | turn_id: turn_id || state.turn_id}
  end

  defp complete_pending(state, {:reply, from, _operation}, {:ok, _result}) do
    GenServer.reply(from, :ok)
    state
  end

  defp complete_pending(state, kind, {:error, reason}) do
    reply_pending(%{kind: kind}, {:error, reason})
    state
  end

  defp send_request(state, method, params, kind) do
    id = state.next_id
    send_json(state.port, %{"id" => id, "method" => method, "params" => params})
    timer = Process.send_after(self(), {:request_timeout, id}, state.timeout_ms)
    pending = Map.put(state.pending, id, %{kind: kind, timer: timer})
    %{state | next_id: id + 1, pending: pending}
  end

  defp send_notification(port, method, nil), do: send_json(port, %{"method" => method})

  defp send_notification(port, method, params),
    do: send_json(port, %{"method" => method, "params" => params})

  defp send_response(port, id, result), do: send_json(port, %{"id" => id, "result" => result})
  defp send_error(port, id, error), do: send_json(port, %{"id" => id, "error" => error})
  defp send_json(port, message), do: Port.command(port, Jason.encode!(message) <> "\n")

  defp emit(state, event) do
    event = %{event | sequence: state.sequence + 1}

    case state.sink do
      pid when is_pid(pid) and is_reference(state.runtime_ingress_token) ->
        send(pid, {:studio_chat_managed_runtime_event, state.runtime_ingress_token, event})

      pid when is_pid(pid) ->
        send(pid, {:studio_chat_runtime_event, event})

      fun when is_function(fun, 1) ->
        fun.(event)

      _ ->
        :ok
    end

    %{state | sequence: state.sequence + 1}
  end

  defp track_native_ids(state, %{"params" => params}) do
    %{
      state
      | thread_id: params["threadId"] || get_in(params, ["thread", "id"]) || state.thread_id,
        turn_id: params["turnId"] || get_in(params, ["turn", "id"]) || state.turn_id
    }
  end

  defp thread_request(opts) do
    case Map.get(opts, :provider_session_id) do
      id when is_binary(id) and id != "" ->
        {"thread/resume",
         %{
           "threadId" => id,
           "cwd" => Map.get(opts, :cwd),
           "developerInstructions" => Map.get(opts, :developer_instructions),
           "config" => Map.get(opts, :thread_config)
         }}

      _ ->
        {"thread/start",
         %{
           "cwd" => Map.get(opts, :cwd),
           "model" => Map.get(opts, :model),
           "approvalPolicy" => Map.get(opts, :approval_policy, "on-request"),
           "sandbox" => Map.get(opts, :sandbox, "workspace-write"),
           "developerInstructions" => Map.get(opts, :developer_instructions),
           "config" => Map.get(opts, :thread_config)
         }}
    end
  end

  defp readiness(%{"account" => nil, "requiresOpenaiAuth" => true}) do
    %{ready?: false, authed?: false, account: nil, reason: :not_authenticated}
  end

  defp readiness(%{"account" => account}) when is_map(account) do
    %{ready?: true, authed?: true, account: account, reason: nil}
  end

  defp readiness(%{"requiresOpenaiAuth" => false}) do
    %{ready?: true, authed?: true, account: nil, reason: nil}
  end

  defp readiness(_result) do
    %{ready?: false, authed?: false, account: nil, reason: :malformed_response}
  end

  defp normalize_input(content) when is_binary(content),
    do: [%{"type" => "text", "text" => content}]

  defp normalize_input(content) when is_list(content), do: content
  defp normalize_input(nil), do: []
  defp normalize_input(content), do: [%{"type" => "text", "text" => to_string(content)}]

  defp split_lines(data) do
    parts = String.split(data, "\n")
    {Enum.drop(parts, -1), List.last(parts) || ""}
  end

  defp context(state),
    do: %{
      session_id: state.session_id,
      thread_id: state.thread_id,
      turn_id: state.turn_id,
      sequence: state.sequence + 1
    }

  defp sanitize_rpc_error(error) when is_map(error),
    do: %{code: error["code"], message: String.slice(to_string(error["message"]), 0, 1_000)}

  defp sanitize_rpc_error(error), do: %{message: String.slice(inspect(error), 0, 1_000)}

  defp reply_all_pending(pending, result),
    do: Enum.each(pending, fn {_id, value} -> reply_pending(value, result) end)

  # Reassembly-buffer breach: a newline-free / runaway stream can never be stopped
  # by `fail_pending` alone (it lives on the handle_call clauses, and split_lines
  # keeps a newline-free chunk whole), so the cap MUST act here. Reap the port so
  # the runaway external process can no longer wedge the BEAM *or* the machine,
  # drop the buffer, and fail every pending caller closed — mirroring the
  # malformed-JSONL path (a Protocol failure event + fail_pending).
  defp overflow(state, byte_size) do
    reap_port(state.port)

    state
    |> emit(Protocol.buffer_overflow(context(state), byte_size))
    |> fail_pending(:buffer_overflow)
    |> Map.put(:buffer, "")
  end

  defp fail_pending(%{pending: pending} = state, reason) do
    Enum.each(pending, fn {_id, %{timer: timer}} -> Process.cancel_timer(timer) end)
    reply_all_pending(pending, {:error, reason})
    %{state | pending: %{}, failure: reason}
  end

  defp reply_pending(%{kind: kind}, result), do: reply_pending(kind, result)
  defp reply_pending({:initialize, from, _opts}, result), do: GenServer.reply(from, result)
  defp reply_pending({:account_read, from, _opts}, result), do: GenServer.reply(from, result)
  defp reply_pending({:thread_open, from, _readiness}, result), do: GenServer.reply(from, result)
  defp reply_pending({:reply, from, _operation}, result), do: GenServer.reply(from, result)

  defp open_port(opts) do
    binary = Map.get(opts, :binary) || configured_binary()
    args = Map.get(opts, :args, ["app-server", "--stdio"])

    case System.find_executable(binary) || executable_path(binary) do
      nil ->
        {:error, :binary_missing}

      path ->
        port_opts = [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: Enum.map(args, &String.to_charlist/1)
        ]

        port_opts =
          case Map.get(opts, :task_hands_env) do
            env when is_list(env) and env != [] -> [{:env, env} | port_opts]
            _ -> port_opts
          end

        port_opts =
          case Map.get(opts, :cwd) do
            cwd when is_binary(cwd) -> [{:cd, String.to_charlist(cwd)} | port_opts]
            _ -> port_opts
          end

        {:ok, Port.open({:spawn_executable, String.to_charlist(path)}, port_opts)}
    end
  rescue
    error -> {:error, {:spawn_failed, Exception.message(error)}}
  end

  defp configured_binary do
    :barkpark
    |> Application.get_env(:codex_app_server, [])
    |> Keyword.get(:binary, "codex")
  end

  defp max_buffer_bytes do
    :barkpark
    |> Application.get_env(:codex_app_server, [])
    |> Keyword.get(:max_buffer_bytes, @default_max_buffer_bytes)
  end

  defp executable_path(path) when is_binary(path) do
    if Path.type(path) == :absolute and File.exists?(path), do: path
  end

  defp setup_task_hands(opts) do
    minter = Map.get(opts, :minter)
    session_id = Map.get(opts, :session_id)
    workspace_id = Map.get(opts, :workspace_id)

    if is_nil(minter) or not is_binary(session_id) do
      %{status: :not_attempted, token: nil, config: nil, env: []}
    else
      case Barkpark.Auth.create_claude_session_token(minter, session_id,
             workspace_id: workspace_id
           ) do
        {:ok, {raw, token}} ->
          worker_id = "codex-chat-#{session_id}"
          api_url = BarkparkWeb.Studio.ClaudeChat.mcp_api_url()

          %{
            status: :minted,
            token: token,
            env: [
              {~c"BARKPARK_API_TOKEN", String.to_charlist(raw)},
              {~c"BARKPARK_API_URL", String.to_charlist(api_url)},
              {~c"BARKPARK_WORKER_ID", String.to_charlist(worker_id)}
            ],
            config: %{
              "mcp_servers" => %{
                "barkpark" => %{
                  "command" => "bp",
                  "args" => ["mcp", "serve", "--tools", "all"],
                  "env_vars" => [
                    "BARKPARK_API_TOKEN",
                    "BARKPARK_API_URL",
                    "BARKPARK_WORKER_ID"
                  ],
                  "required" => true
                }
              }
            }
          }

        {:error, _reason} ->
          %{status: :mint_refused, token: nil, config: nil, env: []}
      end
    end
  end

  # TOTAL by design, mirroring the claude twin's `safe_revoke/1`: with the
  # whole-body rescue gone from terminate/2 (task-95b4b28a56583b1c), this is the
  # last statement of teardown and nothing else would catch it. A dead Repo at
  # teardown — a sandbox owner that died WITH the session, a Repo already shut
  # down — must never turn a normal stop into a crash. The token's own expiry is
  # the backstop for a genuinely unreachable Repo.
  defp cleanup_task_token(nil), do: :ok

  defp cleanup_task_token(token) do
    _ = Barkpark.Auth.revoke_token(token)
    :ok
  rescue
    e in DBConnection.OwnershipError ->
      Logger.debug("codex session: task token revoke skipped (sandbox gone): #{inspect(e)}")
      :ok

    e ->
      Logger.warning("codex session: task token revoke failed: #{inspect(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.debug("codex session: task token revoke skipped (repo down): #{inspect(reason)}")
      :ok
  end
end
