defmodule BarkparkWeb.Studio.ClaudeChat do
  @moduledoc """
  Gate + subprocess seam for the Studio **Claude chat** (`/studio/chat`).

  A chat panel backed by the host's Claude Code CLI. The `claude` binary is
  spawned in streaming print mode (`--input-format stream-json
  --output-format stream-json`) and inherits the host's `claude auth login`
  OAuth credentials via `$HOME` — Barkpark never sees, stores, or refreshes a
  token. Same trust model as the tmux console, held safe by the same three
  controls:

    1. **Admin-only.** The `/studio/chat` route rides the `:admin_studio`
       live_session, so its `on_mount` requires an admin token / account. The
       nav tab is likewise shown only to admins (`shares_admin?`).
    2. **Public-demo hard refuse.** `enabled?/0` returns false whenever
       `public_demo_studio` is on. Fail-closed, not overridable by the flag.
    3. **Per-host opt-out.** `BARKPARK_CLAUDE_CHAT=0` (runtime.exs) disables
       it on a given host; `enabled?/0` also requires the `claude` binary
       (or a configured command override) to be present.

  Wave 1 runs the agent in **plan mode** (`--permission-mode plan`): the
  model may read the filesystem it runs in but cannot edit or execute —
  no approval UI is needed. The stream-json wire protocol is the same one
  `@anthropic-ai/claude-agent-sdk` speaks, so the t3code-style agent-chat
  features (tool approvals, `--resume` threads, MCP callbacks) layer on
  without changing this seam.

  The subprocess command is read from config (tests inject `{"cat", []}` or
  small `sh -c` scripts), so the whole spawn → NDJSON parse → event path is
  exercised without a real `claude`.
  """

  require Logger

  @default_binary "claude"
  @modes ~w(plan default acceptEdits)
  @default_mode "plan"

  @doc """
  Whether the chat may run on this host. ON by default; requires the flag
  (default on, opt out via env) and a launchable command, and is HARD-REFUSED
  whenever anonymous Studio is on (`public_demo_studio`). Both the nav tab
  (admin-only) and the LiveView mount gate on this.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    flag_on?() and not public_demo?() and launchable?()
  end

  # Enable flag defaults ON; only an explicit `enabled: false` (base config or
  # BARKPARK_CLAUDE_CHAT=0 via runtime.exs) turns it off.
  defp flag_on?, do: Keyword.get(config(), :enabled, true) != false

  # Fail-closed: a host that serves Studio to anonymous visitors must never
  # expose an agent with the server's filesystem in reach.
  defp public_demo?, do: Application.get_env(:barkpark, :public_demo_studio, false) == true

  defp launchable? do
    {exe, _args} = command()
    System.find_executable(exe) != nil
  end

  @doc "The configured Claude binary (default `claude`)."
  @spec binary() :: String.t()
  def binary, do: Keyword.get(config(), :binary, @default_binary)

  @doc """
  The subprocess command as `{executable, args}`. Defaults to the Claude CLI
  in streaming print mode, plan permission mode. Overridable via config
  (tests inject a trivial command so they don't require `claude`).
  """
  @spec command(String.t()) :: {String.t(), [String.t()]}
  def command(mode \\ @default_mode) do
    case Keyword.get(config(), :command) do
      {exe, args} when is_binary(exe) and is_list(args) -> {exe, args}
      _ -> {binary(), default_args(mode)}
    end
  end

  @doc "Permission modes the chat may run in. `plan` is read-only; the others ask."
  @spec modes() :: [String.t()]
  def modes, do: @modes

  @doc "Clamp an arbitrary mode string to a supported one (fail-closed to plan)."
  @spec normalize_mode(term()) :: String.t()
  def normalize_mode(mode) when mode in @modes, do: mode
  def normalize_mode(_), do: @default_mode

  defp default_args(mode) do
    base = [
      "--print",
      "--verbose",
      "--input-format",
      "stream-json",
      "--output-format",
      "stream-json",
      "--include-partial-messages",
      "--permission-mode",
      mode,
      "--append-system-prompt",
      render_appendix()
    ]

    # Outside plan mode the CLI must route permission asks to us instead of
    # auto-denying: `--permission-prompt-tool stdio` makes it emit
    # `control_request` (subtype `can_use_tool`) NDJSON events, which the
    # Session forwards as `{:claude_chat_permission, …}` and answers via
    # `respond_permission/3` — the Agent SDK's canUseTool bridge, spoken raw.
    if mode == "plan", do: base, else: base ++ ["--permission-prompt-tool", "stdio"]
  end

  # Replies render through Barkpark's paper engine (FromMarkdown -> blocks ->
  # Render). Teach the model the two upgrade fences and the native block
  # vocabulary the converter accepts, so it can answer with real Barkpark
  # blocks (charts, callouts, tables) instead of ASCII approximations.
  defp render_appendix do
    """
    Your replies render inside Barkpark Studio through its PortableDoc paper \
    engine. Write GitHub-flavored markdown. Two special fences upgrade a reply:

    1. ```mermaid — renders as a live diagram figure.
    2. ```portabledoc — a JSON array of native Barkpark blocks, rendered \
    exactly like published papers. Use it whenever data deserves richer form \
    than prose. Supported block types:
    {"type":"callout","tone":"info|success|warning|danger","title":"...","content":[{"type":"text","value":"..."}]}
    {"type":"chart","kind":"line|bars","caption":"...","series":[{"label":"...","points":[1,2,3]}],"axes":{"xLabels":["a","b","c"]}}
    {"type":"stats","items":[{"type":"stat","label":"...","value":"42","max":100,"spark":[1,2,3]}]}
    {"type":"table","head":[[{"type":"text","value":"Col"}]],"rows":[[[{"type":"text","value":"cell"}]]]}
    {"type":"divider"}

    Prefer a chart or stats block over a markdown table of numbers; prefer a \
    callout for warnings and key takeaways. Keep JSON valid — malformed \
    fences degrade to a raw code block.
    """
  end

  @doc "Working directory for the subprocess (config `:cwd`, default server cwd)."
  @spec cwd() :: String.t()
  def cwd, do: Keyword.get(config(), :cwd) || File.cwd!()

  @doc """
  Start a chat session subprocess.

  `sink` is the pid that receives:

    * `{:claude_chat_event, map}` — one decoded stream-json event per NDJSON
      line the CLI emits (`system/init`, `stream_event`, `assistant`,
      `result`, …)
    * `{:claude_chat_exit, status}` — the subprocess ended

  The session monitors the sink and shuts the subprocess down when the sink
  dies, so an abandoned LiveView never leaks a `claude` process.
  """
  @spec start_session(%{:sink => pid(), optional(:mode) => String.t()}) ::
          {:ok, pid()} | {:error, term()}
  def start_session(%{sink: sink} = opts) when is_pid(sink) do
    cond do
      not enabled?() -> {:error, :disabled}
      true -> __MODULE__.Session.start(%{sink: sink, mode: normalize_mode(opts[:mode])})
    end
  end

  @doc """
  Answer a pending `{:claude_chat_permission, …}` ask. `decision` is `:allow`
  or `{:deny, message}`; the message travels back to the model so it can
  adjust its approach (t3's deny_message).
  """
  @spec respond_permission(pid(), String.t(), :allow | {:deny, String.t()}) :: :ok
  def respond_permission(session, request_id, decision)
      when is_pid(session) and is_binary(request_id) do
    GenServer.cast(session, {:respond_permission, request_id, decision})
  end

  @doc "Send a user turn to the session as a stream-json user message."
  @spec send_message(pid(), String.t()) :: :ok
  def send_message(session, text) when is_pid(session) and is_binary(text) do
    GenServer.cast(session, {:send_user_message, text})
  end

  @doc "Terminate the session subprocess."
  @spec close(pid()) :: :ok
  def close(session) when is_pid(session) do
    GenServer.cast(session, :close)
  end

  @doc """
  Split a stdout buffer into decoded NDJSON events and the trailing partial
  line. Non-JSON complete lines are dropped (logged at debug) — the CLI's
  stdout is JSON-only, but we never let a stray line crash the session.
  """
  @spec parse_chunk(String.t(), String.t()) :: {[map()], String.t()}
  def parse_chunk(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    parts = String.split(buffer <> chunk, "\n")
    {complete, [rest]} = Enum.split(parts, length(parts) - 1)

    events =
      complete
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, event} when is_map(event) ->
            [event]

          _ ->
            Logger.debug("claude chat: ignoring non-JSON stdout line (#{byte_size(line)} bytes)")
            []
        end
      end)

    {events, rest}
  end

  defp config, do: Application.get_env(:barkpark, :claude_chat, [])

  defmodule Session do
    @moduledoc """
    One chat subprocess. Owns the Port, assembles NDJSON lines off stdout,
    and forwards decoded events to the sink. Deliberately un-supervised and
    unlinked: it lives and dies with the LiveView that started it (the sink
    is monitored; sink death stops the session and the Port closes with it).
    """

    use GenServer, restart: :temporary

    require Logger

    alias BarkparkWeb.Studio.ClaudeChat

    @spec start(%{sink: pid()}) :: {:ok, pid()} | {:error, term()}
    def start(opts), do: GenServer.start(__MODULE__, opts)

    @impl true
    def init(%{sink: sink} = opts) do
      {exe, args} = ClaudeChat.command(Map.get(opts, :mode, "plan"))

      case System.find_executable(exe) do
        nil ->
          {:stop, :binary_not_found}

        path ->
          port =
            Port.open(
              {:spawn_executable, path},
              [:binary, :exit_status, :hide, args: args, cd: ClaudeChat.cwd()]
            )

          Process.monitor(sink)
          {:ok, %{port: port, sink: sink, buffer: ""}}
      end
    rescue
      e ->
        Logger.warning("claude chat: failed to spawn subprocess: #{inspect(e)}")
        {:stop, :spawn_failed}
    end

    @impl true
    def handle_cast({:send_user_message, text}, state) do
      line =
        Jason.encode!(%{
          "type" => "user",
          "message" => %{
            "role" => "user",
            "content" => [%{"type" => "text", "text" => text}]
          }
        }) <> "\n"

      safe_command(state.port, line)
      {:noreply, state}
    end

    def handle_cast({:respond_permission, request_id, decision}, state) do
      payload =
        case decision do
          :allow -> %{"behavior" => "allow"}
          {:deny, message} -> %{"behavior" => "deny", "message" => to_string(message)}
        end

      line =
        Jason.encode!(%{
          "type" => "control_response",
          "response" => %{
            "subtype" => "success",
            "request_id" => request_id,
            "response" => payload
          }
        }) <> "\n"

      safe_command(state.port, line)
      {:noreply, state}
    end

    def handle_cast(:close, state), do: {:stop, :normal, state}

    @impl true
    def handle_info({port, {:data, chunk}}, %{port: port} = state) do
      {events, rest} = ClaudeChat.parse_chunk(state.buffer, chunk)
      Enum.each(events, &dispatch_event(&1, state))
      {:noreply, %{state | buffer: rest}}
    end

    def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
      send(state.sink, {:claude_chat_exit, status})
      {:stop, :normal, %{state | port: nil}}
    end

    def handle_info({:DOWN, _ref, :process, sink, _reason}, %{sink: sink} = state) do
      {:stop, :normal, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}

    @impl true
    def terminate(_reason, %{port: port}) when is_port(port) do
      # Closing the Port closes the subprocess's stdin; the CLI exits on EOF.
      if port in Port.list(), do: Port.close(port)
      :ok
    rescue
      _ -> :ok
    end

    def terminate(_reason, _state), do: :ok

    # Permission asks become a dedicated sink message; any other control
    # request gets an immediate error response so the CLI never hangs waiting
    # on a capability this bridge doesn't implement. Everything else flows
    # through as a plain chat event.
    defp dispatch_event(
           %{
             "type" => "control_request",
             "request_id" => request_id,
             "request" => %{"subtype" => "can_use_tool"} = request
           },
           state
         ) do
      send(
        state.sink,
        {:claude_chat_permission,
         %{
           request_id: request_id,
           tool_name: Map.get(request, "tool_name", "tool"),
           input: Map.get(request, "input", %{}),
           title: Map.get(request, "title"),
           decision_reason: Map.get(request, "decision_reason")
         }}
      )
    end

    defp dispatch_event(
           %{"type" => "control_request", "request_id" => request_id, "request" => request},
           state
         ) do
      line =
        Jason.encode!(%{
          "type" => "control_response",
          "response" => %{
            "subtype" => "error",
            "request_id" => request_id,
            "error" => "unsupported control request: #{Map.get(request, "subtype", "?")}"
          }
        }) <> "\n"

      safe_command(state.port, line)
    end

    defp dispatch_event(event, state), do: send(state.sink, {:claude_chat_event, event})

    defp safe_command(port, data) when is_port(port) do
      Port.command(port, data)
      :ok
    rescue
      e ->
        Logger.warning("claude chat: write to subprocess failed: #{inspect(e)}")
        :ok
    end

    defp safe_command(_port, _data), do: :ok
  end
end
