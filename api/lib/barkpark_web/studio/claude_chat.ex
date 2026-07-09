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

  `session_opts` threads session identity onto the real argv through the pure
  `build_args/2` seam (`%{session_id: uuid}` ⇒ `--session-id`,
  `%{session_id: uuid, resume: true}` ⇒ `--resume`).

  VACUOUS-GREEN LAW: the `:command` config override returns its tuple
  **verbatim**, bypassing `build_args/2` entirely — never assert session/mode
  flags through a `:command` fake. Assert flags either against `build_args/2`
  directly, or end-to-end through a `:binary` override (which keeps
  `build_args/2`).
  """
  @spec command(String.t(), map()) :: {String.t(), [String.t()]}
  def command(mode \\ @default_mode, session_opts \\ %{}) do
    case Keyword.get(config(), :command) do
      {exe, args} when is_binary(exe) and is_list(args) -> {exe, args}
      _ -> {binary(), build_args(mode, session_opts)}
    end
  end

  @doc """
  Pure assembly of the CLI argv for a given `mode` and `session_opts`. This is
  the single seam where session identity reaches the real process — kept pure
  and public so flag behavior is unit-testable without spawning a Port.

  Session flags (charter D8/D9), appended after the base args:

    * fresh session — `%{session_id: uuid}` ⇒ `["--session-id", uuid]`
      (we mint the uuid, so persistence needs no wire-protocol id scraping)
    * resume — `%{session_id: uuid, resume: true}` ⇒ `["--resume", uuid]`,
      and NEVER `--session-id` (the two are mutually exclusive on the binary)
    * absent — no `session_id` ⇒ neither flag (back-compat with w1–w2c)
  """
  @spec build_args(String.t(), map()) :: [String.t()]
  def build_args(mode, session_opts \\ %{}) do
    default_args(mode) ++ session_args(session_opts) ++ model_args(session_opts)
  end

  # Resume wins over a fresh pin: --resume and --session-id are mutually
  # exclusive, so a resume never also emits --session-id.
  defp session_args(%{session_id: id, resume: true}) when is_binary(id), do: ["--resume", id]
  defp session_args(%{session_id: id}) when is_binary(id), do: ["--session-id", id]
  defp session_args(_), do: []

  # A chosen model rides the spawn (`--model <alias>`); absent/default = the
  # CLI's own setting. Allowlisted aliases only — never a raw user string.
  defp model_args(%{model: m}) when is_binary(m) and m != "", do: ["--model", m]
  defp model_args(_), do: []

  @models ~w(haiku sonnet opus fable)

  @doc "Model aliases the picker may choose (the CLI accepts these)."
  @spec models() :: [String.t()]
  def models, do: @models

  @doc ~S"""
  Clamp a picker value to an allowlisted model alias, or nil for the CLI
  default. Fail-closed: an unknown string never reaches the argv.
  """
  @spec normalize_model(term()) :: String.t() | nil
  def normalize_model(m) when m in @models, do: m
  def normalize_model(_), do: nil

  @doc "Permission modes the chat may run in. `plan` is read-only; the others ask."
  @spec modes() :: [String.t()]
  def modes, do: @modes

  @doc "Clamp an arbitrary mode string to a supported one (fail-closed to plan)."
  @spec normalize_mode(term()) :: String.t()
  def normalize_mode(mode) when mode in @modes, do: mode
  def normalize_mode(_), do: @default_mode

  defp default_args(mode) do
    [
      "--print",
      "--verbose",
      "--input-format",
      "stream-json",
      "--output-format",
      "stream-json",
      "--include-partial-messages",
      "--permission-mode",
      mode,
      # `--permission-prompt-tool stdio` ships in ALL modes, plan included
      # (charter D33). It makes the CLI route permission asks to us as
      # `control_request` (subtype `can_use_tool`) NDJSON events instead of
      # auto-handling them — the Session forwards them as
      # `{:claude_chat_permission, …}` and answers via `respond_permission/3`
      # (the Agent SDK's canUseTool bridge, spoken raw). Plan mode is the
      # product default and EVERY plan session hits ExitPlanMode; without the
      # flag that ask never reaches Barkpark (the CLI auto-handles it), so the
      # proposed-plan card could never render. Consequence accepted: other
      # tools' asks in plan mode now also reach us as honest approval cards.
      "--permission-prompt-tool",
      "stdio",
      "--append-system-prompt",
      render_appendix()
    ]
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

  `:session_opts` (charter D8) pins or resumes a session: `%{session_id: uuid}`
  starts a fresh pinned session, `%{session_id: uuid, resume: true}` resumes an
  existing one. Absent ⇒ an anonymous one-shot session (w1–w2c behavior).
  """
  @spec start_session(%{
          :sink => pid(),
          optional(:mode) => String.t(),
          optional(:session_opts) => map()
        }) :: {:ok, pid()} | {:error, term()}
  def start_session(%{sink: sink} = opts) when is_pid(sink) do
    cond do
      not enabled?() ->
        {:error, :disabled}

      true ->
        __MODULE__.Session.start(%{
          sink: sink,
          mode: normalize_mode(opts[:mode]),
          session_opts: Map.get(opts, :session_opts, %{})
        })
    end
  end

  @doc """
  Answer a pending `{:claude_chat_permission, …}` ask (charter D32). `decision`:

    * `:allow` — approve, echoing the ORIGINAL ask input back as `updatedInput`
      (the Session tracked it by `request_id` — never trust the caller to
      round-trip it). A bare `{"behavior":"allow"}` FAILS ExitPlanMode on the
      real binary (ZodError, mode stays plan); the CLI's own internal
      `checkPermissions` shape requires `updatedInput`, so plain allow always
      echoes it.
    * `{:allow, updated_input}` — approve with a CALLER-supplied `updatedInput`
      map. Question answers ride here as `%{"questions" => unchanged,
      "answers" => %{<question string> => <value>}}` (proven: the CLI keys
      internally by the question string; multiSelect = comma-joined labels).
    * `{:deny, message}` — refuse; `message` (required by the schema) travels
      back to the model so it can adjust (t3's deny_message).
  """
  @spec respond_permission(pid(), String.t(), :allow | {:allow, map()} | {:deny, String.t()}) ::
          :ok
  def respond_permission(session, request_id, decision)
      when is_pid(session) and is_binary(request_id) do
    GenServer.cast(session, {:respond_permission, request_id, decision})
  end

  @doc """
  Send a user turn to the session as a stream-json user message.

  A `GenServer.call` (charter D24) — the reply carries the REAL write outcome so
  the caller can tell a DISPATCHED turn (the model has it; keep the optimistic
  echo, clear the composer) from a failed one (withdraw the echo, hand the words
  back). `:ok` means the frame reached the port; `{:error, reason}` means it did
  not (a closed/absent port, a write that raised, or a session that has already
  gone — never a false `:ok`). The honesty bar is DISPATCHED, not delivered: a
  later result frame still reports the model's answer.

  `content` is EITHER a plain `String.t()` (the text-only default shape) OR a
  ready content-block list — `[%{"type" => "text", …}, %{"type" => "image",
  "source" => %{"type" => "base64", "media_type" => …, "data" => …}}]` — so a
  turn can carry pasted/dropped images alongside the text (charter D25, proven
  on the real binary v2.1.205: a mixed text+image content list is accepted and
  the model sees the image). A binary is wrapped into a single text block; a
  list rides the user frame verbatim.
  """
  @spec send_message(pid(), String.t() | [map()]) :: :ok | {:error, term()}
  def send_message(session, content)
      when is_pid(session) and (is_binary(content) or is_list(content)) do
    GenServer.call(session, {:send_user_message, content})
  catch
    # The session GenServer died between the caller's `ensure_session` and this
    # call (port exit, teardown). That is a failed dispatch, not a crash — the
    # composer must restore, so surface it as an honest {:error}.
    :exit, reason -> {:error, {:not_running, reason}}
  end

  @doc """
  Interrupt the running turn (charter D10). Writes a `control_request` frame
  with subtype `interrupt` on stdin — proven on the raw wire 2026-07-09: the
  CLI acks with a `control_response` (subtype `success`), aborts the turn, and
  the session SURVIVES (the terminal `result` carries
  `terminal_reason: "aborted_streaming"`, which the LiveView discriminates from
  a real error). Returns the minted `request_id` so the caller can match the
  ack (forwarded to the sink as a `{:claude_chat_event, control_response}`).
  """
  @spec interrupt(pid()) :: {:ok, String.t()}
  def interrupt(session) when is_pid(session) do
    control_request(session, %{"subtype" => "interrupt"})
  end

  @doc """
  Switch the permission mode of a live session in place (charter D12),
  replacing the context-destroying respawn. The wire key MUST be `mode`: the
  real binary treats the plausible-looking `permission_mode` key as a silent
  no-op (returns success with an EMPTY response). Returns the minted
  `request_id`; the LiveView must confirm the echoed `response.mode` before
  trusting the switch (subtype `success` alone is a vacuous-green trap).
  """
  @spec set_permission_mode(pid(), String.t()) :: {:ok, String.t()}
  def set_permission_mode(session, mode) when is_pid(session) and is_binary(mode) do
    control_request(session, %{"subtype" => "set_permission_mode", "mode" => mode})
  end

  @doc """
  Switch the model of a live session in place. Returns the minted `request_id`;
  the caller should verify the next `result` frame's `modelUsage` key actually
  changed before trusting the switch (the CLI acks `success` regardless).
  """
  @spec set_model(pid(), String.t()) :: {:ok, String.t()}
  def set_model(session, model) when is_pid(session) and is_binary(model) do
    control_request(session, %{"subtype" => "set_model", "model" => model})
  end

  # Mint a request_id and cast an outbound control_request frame. The id lets
  # the caller correlate the CLI's control_response ack (forwarded to the sink).
  defp control_request(session, request) when is_map(request) do
    request_id = mint_request_id()
    GenServer.cast(session, {:control_request, request_id, request})
    {:ok, request_id}
  end

  defp mint_request_id do
    "bp-req-" <> (8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))
  end

  @doc """
  Take over a running session's event stream (charter D20 — single writer).

  Two tabs must never each spawn a `claude --resume` process against the same
  session: two OS processes writing the CLI's own transcript concurrently. The
  `Session` registers under `{:via, Barkpark.StudioChat.SessionRegistry, uuid}`
  when its `session_id` is pinned, so the SECOND tab's `start_session/1` returns
  `{:error, {:already_started, pid}}` instead of spawning. That tab calls this
  to become the sole sink: the `Session` demonitors the previous sink, monitors
  the caller, and sends `{:claude_chat_detached}` to the old sink so its tab can
  show an honest "opened in another tab" banner and disable its composer. The
  old tab takes back the same way on its next send. Adopting into the SAME sink
  is a harmless no-op.
  """
  @spec adopt_sink(pid(), pid()) :: :ok
  def adopt_sink(session, new_sink) when is_pid(session) and is_pid(new_sink) do
    GenServer.cast(session, {:adopt_sink, new_sink})
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

    # Single-writer registry (charter D20). When a session id is pinned, the
    # process registers here under the uuid so a SECOND tab that tries to start
    # the same session gets `{:error, {:already_started, pid}}` and adopts the
    # running process rather than spawning a second `claude --resume` writer.
    @registry Barkpark.StudioChat.SessionRegistry

    @spec start(%{sink: pid()}) :: {:ok, pid()} | {:error, term()}
    def start(opts) do
      case pinned_session_id(opts) do
        nil ->
          # Anonymous one-shot (no session identity) — nothing to serialize on,
          # so it stays unnamed (two anonymous chats never share a transcript).
          GenServer.start(__MODULE__, opts)

        uuid ->
          GenServer.start(__MODULE__, opts, name: {:via, Registry, {@registry, uuid}})
      end
    end

    # A pinned OR resumed session both key on the same minted uuid — the whole
    # point of D8's one-identity design: `--session-id` and `--resume` name the
    # same transcript, so both must register under it.
    defp pinned_session_id(opts) do
      case Map.get(opts, :session_opts, %{}) do
        %{session_id: id} when is_binary(id) -> id
        _ -> nil
      end
    end

    @impl true
    def init(%{sink: sink} = opts) do
      {exe, args} =
        ClaudeChat.command(Map.get(opts, :mode, "plan"), Map.get(opts, :session_opts, %{}))

      case System.find_executable(exe) do
        nil ->
          {:stop, :binary_not_found}

        path ->
          port =
            Port.open(
              {:spawn_executable, path},
              [:binary, :exit_status, :hide, args: args, cd: ClaudeChat.cwd()]
            )

          # Keep the monitor ref so an adopt can cleanly demonitor the outgoing
          # sink (a bare Process.monitor/1 leaks a ref that would fire a stale
          # DOWN and stop a session the new owner is still driving).
          sink_ref = Process.monitor(sink)

          {:ok,
           %{
             port: port,
             sink: sink,
             sink_ref: sink_ref,
             buffer: "",
             pending_controls: %{},
             # request_id → the ORIGINAL ask input, tracked so a plain `:allow`
             # echoes it back as `updatedInput` (charter D32 — a bare allow fails
             # ExitPlanMode; the CLI wants its own checkPermissions shape).
             pending_asks: %{}
           }}
      end
    rescue
      e ->
        Logger.warning("claude chat: failed to spawn subprocess: #{inspect(e)}")
        {:stop, :spawn_failed}
    end

    @impl true
    def handle_call({:send_user_message, content}, _from, state) do
      line =
        Jason.encode!(%{
          "type" => "user",
          "message" => %{
            "role" => "user",
            "content" => user_content_blocks(content)
          }
        }) <> "\n"

      # Reply with the REAL write outcome (charter D24) — the LiveView gates its
      # optimistic echo on a DISPATCHED frame, so a swallowed failure would lie.
      {:reply, safe_command(state.port, line), state}
    end

    @impl true
    def handle_cast({:respond_permission, request_id, decision}, state) do
      # Consume the tracked ask input (charter D32): a plain `:allow` echoes it
      # verbatim as `updatedInput`; a `{:allow, updated}` carries the caller's
      # map (question answers); a deny drops it. Pruned either way so the map
      # never grows unbounded across a long session.
      {original, pending_asks} = Map.pop(state.pending_asks, request_id)

      payload =
        case decision do
          :allow ->
            %{"behavior" => "allow", "updatedInput" => original || %{}}

          {:allow, updated} when is_map(updated) ->
            %{"behavior" => "allow", "updatedInput" => updated}

          {:deny, message} ->
            %{"behavior" => "deny", "message" => to_string(message)}
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
      {:noreply, %{state | pending_asks: pending_asks}}
    end

    # Outbound control_request (interrupt / set_permission_mode / set_model).
    # The CLI answers with a control_response echoing this request_id. We map
    # request_id → kind here so the inbound ack dispatches as a TYPED
    # {:claude_chat_control, kind, request_id, response} (charter D17/D23) —
    # otherwise the ack falls through to the generic sink event and the ChatLive
    # catch-all eats it. The request_id rides the dispatch so the consumer can
    # ignore a stale ack from a superseded switch (correlate, don't guess).
    def handle_cast({:control_request, request_id, request}, state) do
      line =
        Jason.encode!(%{
          "type" => "control_request",
          "request_id" => request_id,
          "request" => request
        }) <> "\n"

      safe_command(state.port, line)

      state =
        case control_kind(request) do
          nil -> state
          kind -> put_in(state.pending_controls[request_id], kind)
        end

      {:noreply, state}
    end

    # Single-writer takeover (charter D20). A second tab that found this session
    # already running adopts it as the sole sink: demonitor the outgoing sink
    # (flush any in-flight DOWN so it can't stop us), monitor the newcomer, and
    # tell the old sink it was detached so its tab shows the honest banner. The
    # session lifetime now follows the NEW sink; the old tab takes back the same
    # way on its next send.
    def handle_cast({:adopt_sink, new_sink}, %{sink: old_sink} = state)
        when is_pid(new_sink) do
      if new_sink == old_sink do
        {:noreply, state}
      else
        if ref = state[:sink_ref], do: Process.demonitor(ref, [:flush])
        new_ref = Process.monitor(new_sink)
        send(old_sink, {:claude_chat_detached})
        {:noreply, %{state | sink: new_sink, sink_ref: new_ref}}
      end
    end

    def handle_cast(:close, state), do: {:stop, :normal, state}

    @impl true
    def handle_info({port, {:data, chunk}}, %{port: port} = state) do
      {events, rest} = ClaudeChat.parse_chunk(state.buffer, chunk)
      # Thread state so a control_response ack can prune its pending entry.
      state = Enum.reduce(events, %{state | buffer: rest}, &dispatch_event/2)
      {:noreply, state}
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
    # through as a plain chat event. Each clause RETURNS the (possibly updated)
    # state — the data handler reduces over events threading it.
    defp dispatch_event(
           %{
             "type" => "control_request",
             "request_id" => request_id,
             "request" => %{"subtype" => "can_use_tool"} = request
           },
           state
         ) do
      input = Map.get(request, "input", %{})

      send(
        state.sink,
        {:claude_chat_permission,
         %{
           request_id: request_id,
           tool_name: Map.get(request, "tool_name", "tool"),
           input: input,
           title: Map.get(request, "title"),
           decision_reason: Map.get(request, "decision_reason")
         }}
      )

      # Remember the ask's input so a plain `:allow` can echo it as
      # `updatedInput` (charter D32) — the answer seam never reconstructs it
      # from an untrusted round-trip.
      put_in(state.pending_asks[request_id], input)
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
      state
    end

    # The CLI's ack for one of OUR control_requests (interrupt / set_mode /
    # set_model). Match it by the request_id we minted and dispatch a TYPED
    # {:claude_chat_control, kind, request_id, response} (charter D17/D23) so
    # ChatLive can (a) assert the echoed mode instead of trusting a bare
    # subtype:success (D12) AND (b) correlate the ack to the SPECIFIC outbound
    # request by its id — a rapid double mode-switch acks twice and only the
    # LATEST outstanding request per kind may commit/revert; a stale ack is
    # dropped by the consumer. An untracked control_response (not one we sent)
    # flows through as a plain event — the previous behavior for any ack the
    # LiveView doesn't correlate.
    defp dispatch_event(%{"type" => "control_response", "response" => response} = event, state)
         when is_map(response) do
      request_id = Map.get(response, "request_id")

      case pop_pending(state, request_id) do
        {nil, state} ->
          send(state.sink, {:claude_chat_event, event})
          state

        {kind, state} ->
          send(
            state.sink,
            {:claude_chat_control, kind, request_id, Map.get(response, "response") || %{}}
          )

          state
      end
    end

    defp dispatch_event(event, state) do
      send(state.sink, {:claude_chat_event, event})
      state
    end

    # A plain string is the text-only default shape (wrap as ONE text block —
    # unchanged w1–w2 behavior); a caller-assembled content-block list (text +
    # base64 image blocks, charter D25) rides the user frame verbatim.
    defp user_content_blocks(text) when is_binary(text),
      do: [%{"type" => "text", "text" => text}]

    defp user_content_blocks(blocks) when is_list(blocks), do: blocks

    # Classify an outbound control_request by its subtype so the inbound ack can
    # be typed. Anything else (or a malformed request) is left untracked.
    defp control_kind(%{"subtype" => "interrupt"}), do: :interrupt
    defp control_kind(%{"subtype" => "set_permission_mode"}), do: :set_mode
    defp control_kind(%{"subtype" => "set_model"}), do: :set_model
    defp control_kind(_), do: nil

    # Pull a pending control's kind by request_id (nil if untracked/absent).
    defp pop_pending(state, request_id) when is_binary(request_id) do
      case Map.pop(state.pending_controls, request_id) do
        {nil, _} -> {nil, state}
        {kind, rest} -> {kind, %{state | pending_controls: rest}}
      end
    end

    defp pop_pending(state, _), do: {nil, state}

    # Honest write (charter D24): return the outcome instead of swallowing every
    # failure to `:ok`. A port that has already closed is NOT in `Port.list/0`;
    # writing to it would raise, so we check first and report `{:error, ...}`.
    # Outbound acks/control frames ignore the return; the user-turn write threads
    # it back to the composer so a lost frame is never rendered as sent.
    defp safe_command(port, data) when is_port(port) do
      if port in Port.list() do
        Port.command(port, data)
        :ok
      else
        {:error, :port_closed}
      end
    rescue
      e ->
        Logger.warning("claude chat: write to subprocess failed: #{inspect(e)}")
        {:error, e}
    end

    defp safe_command(_port, _data), do: {:error, :no_port}
  end
end
