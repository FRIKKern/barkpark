defmodule Barkpark.StudioChat.Recorder do
  @moduledoc """
  Server-owned chat runtime (wave 4, charter D28). One Recorder per live
  session is the `ClaudeChat.Session`'s PERMANENT sink: it persists every
  durable outcome to the store the moment it happens and rebroadcasts every
  sink message verbatim on PubSub `"studio_chat:<session_id>"`.

  Tabs are VIEWERS, not owners: a LiveView subscribes to the topic and renders
  the same tuples it used to receive as the direct sink; closing every tab no
  longer kills a running turn — the model finishes, the Recorder persists the
  answer, and the next reopen replays it from the store. Multiple tabs on the
  same session co-view live (PubSub multicasts), and sends still serialize
  through the single Session process.

  Lifetime: the Recorder reaps itself (closing the subprocess) after
  `@idle_after_ms` of frame-silence — the CLI in stream-json mode idles
  indefinitely otherwise. Reaping is invisible to the user: the persisted
  cursor makes the next send lazy-`--resume`.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Barkpark.StudioChat
  alias BarkparkWeb.Studio.ClaudeChat

  @registry Barkpark.StudioChat.RecorderRegistry
  @supervisor Barkpark.StudioChat.RuntimeSupervisor
  @idle_after_ms 30 * 60 * 1000

  # ── public API ─────────────────────────────────────────────────────────────

  @doc """
  Start (or return) the running Recorder for a session. `opts` needs
  `:session_id` (the minted store UUID), `:mode`, and `:resume` (whether the
  subprocess should `--resume` rather than `--session-id`-pin).
  """
  @spec ensure(%{session_id: String.t(), mode: String.t(), resume: boolean()}) ::
          {:ok, pid()} | {:error, term()}
  def ensure(%{session_id: id} = opts) when is_binary(id) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, {:shutdown, reason}} -> {:error, reason}
      other -> other
    end
  end

  @doc "The live Recorder for a session id, or nil."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(session_id) when is_binary(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  def whereis(_), do: nil

  @doc "The underlying ClaudeChat.Session pid (sends/controls go there)."
  @spec session_pid(pid()) :: {:ok, pid()} | {:error, term()}
  def session_pid(recorder) when is_pid(recorder) do
    GenServer.call(recorder, :session_pid)
  catch
    :exit, reason -> {:error, {:not_running, reason}}
  end

  @doc """
  The held slash-command vocabulary for a session (charter D36a) — the rich
  advertised list from the initialize ack, the name-only `system/init` fallback,
  or `[]`. A tab queries this on subscribe so it never has to wait for the
  broadcast it may already have missed. `[]` on a dead/absent recorder.
  """
  @spec advertised_commands(pid()) :: [map()]
  def advertised_commands(recorder) when is_pid(recorder) do
    GenServer.call(recorder, :advertised_commands)
  catch
    :exit, _ -> []
  end

  def advertised_commands(_), do: []

  @doc "PubSub topic a viewer subscribes to for this session's frames."
  @spec topic(String.t()) :: String.t()
  def topic(session_id), do: "studio_chat:#{session_id}"

  @doc """
  The GLOBAL live-activity topic (wave 5). Every Recorder broadcasts
  `{:chat_activity, session_id, %{state: :working | :needs_you | :idle |
  :offline, line: String.t() | nil}}` here whenever its derived activity
  CHANGES — the sidebar renders what each session is doing right now (the
  current tool line, writing/thinking) without polling the store.
  """
  @spec activity_topic() :: String.t()
  def activity_topic, do: "studio_chat:activity"

  def start_link(%{session_id: id} = opts) do
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, id}})
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl true
  def init(%{session_id: id} = opts) do
    session_opts = %{
      session_id: id,
      resume: Map.get(opts, :resume, false),
      model: Map.get(opts, :model)
    }

    case ClaudeChat.start_session(%{
           sink: self(),
           mode: Map.get(opts, :mode, "plan"),
           session_opts: session_opts
         }) do
      {:ok, session} ->
        Process.monitor(session)
        # Ask the CLI for its slash-command list right after spawn (charter D36a)
        # — the ack lands as {:claude_chat_control, :initialize, …}, which we hold
        # so a LATE-joining tab still gets the vocabulary (a one-shot broadcast
        # alone would miss it).
        ClaudeChat.initialize(session)
        {:ok, new_state(id, session)}

      {:error, {:already_started, session}} ->
        # A Session survived its Recorder (recorder crash). Re-adopt it as our
        # sink so its frames flow again instead of casting into a dead pid.
        ClaudeChat.adopt_sink(session, self())
        Process.monitor(session)
        ClaudeChat.initialize(session)
        {:ok, new_state(id, session)}

      {:error, reason} ->
        {:stop, {:shutdown, reason}}
    end
  end

  defp new_state(id, session) do
    %{
      session_id: id,
      session: session,
      timer: arm_idle(nil),
      activity: nil,
      # The advertised slash-command list (charter D36a). `commands` is the rich
      # authoritative list from the initialize ack; `slash_commands` is the
      # name-only fallback captured off `system/init`; a live/late tab reads the
      # best available via `advertised_commands/1`.
      commands: nil,
      slash_commands: nil
    }
  end

  @impl true
  def handle_call(:session_pid, _from, state), do: {:reply, {:ok, state.session}, state}

  # Late-join query (charter D36a): a tab that opens AFTER the initialize ack
  # already fired still gets the held vocabulary. Returns the best available
  # list of `%{"name", "description", "argumentHint"}` maps (rich, then the
  # name-only init fallback, then []).
  def handle_call(:advertised_commands, _from, state),
    do: {:reply, advertised(state), state}

  # ── sink messages: persist, then rebroadcast verbatim ──────────────────────

  @impl true
  def handle_info({:claude_chat_event, %{"type" => "assistant"} = ev} = msg, state) do
    blocks = get_in(ev, ["message", "content"])
    persist_assistant_blocks(state.session_id, blocks, ev)
    broadcast(state, msg)
    {:noreply, state |> publish_activity(assistant_activity(blocks, state.activity)) |> touch()}
  end

  def handle_info({:claude_chat_event, %{"type" => "result"} = ev} = msg, state) do
    record_result(state.session_id, ev)
    broadcast(state, msg)
    {:noreply, state |> publish_activity(%{state: :idle, line: nil}) |> touch()}
  end

  # A turn is starting (the CLI emits init per TURN): the session is working.
  # Persist the status too so a COLD sidebar load (no live overlay yet) reads
  # the same truth off the store. The init frame also carries `slash_commands`
  # (names only) — hold it as the FALLBACK vocabulary (charter D36a) in case the
  # richer initialize ack never landed, and broadcast if it upgrades what we hold.
  def handle_info(
        {:claude_chat_event, %{"type" => "system", "subtype" => "init"} = ev} = msg,
        state
      ) do
    StudioChat.update_status(state.session_id, "working")
    state = maybe_capture_slash_commands(state, ev)
    broadcast(state, msg)
    {:noreply, state |> publish_activity(%{state: :working, line: "thinking…"}) |> touch()}
  end

  # The CLI's answer to our `initialize` control_request (charter D36a): the
  # AUTHORITATIVE slash-command list. HOLD it in the runtime (so a late tab gets
  # it via `advertised_commands/1`) and broadcast the vocabulary so live tabs
  # populate their slash menu without polling. This clause MUST precede the
  # generic control handler below, which would otherwise rebroadcast it raw.
  def handle_info({:claude_chat_control, :initialize, _rid, response}, state) do
    # An EMPTY commands payload never clobbers a held list — the CLI may answer
    # with none, and a fake `cat` subprocess echoes our own initialize back into
    # a spurious empty ack. Only a non-empty list updates + broadcasts.
    case extract_commands(response) do
      [] ->
        {:noreply, touch(state)}

      commands ->
        state = %{state | commands: commands}
        broadcast_commands(state)
        {:noreply, touch(state)}
    end
  end

  # A tool's RESULT arrives as a user-frame tool_result block (wire-proven).
  # Attach it to the persisted tool row so replay shows the terminal's ⎿ line;
  # the frame also rebroadcasts so live tabs update their in-memory row.
  def handle_info({:claude_chat_event, %{"type" => "user"} = ev} = msg, state) do
    for {tool_use_id, output} <- user_tool_results(ev) do
      StudioChat.attach_tool_result(state.session_id, tool_use_id, output)
    end

    broadcast(state, msg)
    {:noreply, touch(state)}
  end

  def handle_info({:claude_chat_event, %{"type" => "stream_event"}} = msg, state) do
    broadcast(state, msg)
    {:noreply, state |> publish_activity(%{state: :working, line: "writing…"}) |> touch()}
  end

  def handle_info({:claude_chat_event, _ev} = msg, state) do
    broadcast(state, msg)
    {:noreply, touch(state)}
  end

  def handle_info({:claude_chat_permission, ask} = msg, state) do
    persist_approval_ask(state.session_id, ask)
    broadcast(state, msg)

    {:noreply,
     state
     |> publish_activity(%{state: :needs_you, line: needs_you_line(ask.tool_name)})
     |> touch()}
  end

  def handle_info({:claude_chat_control, _kind, _rid, _resp} = msg, state) do
    broadcast(state, msg)
    {:noreply, touch(state)}
  end

  def handle_info({:claude_chat_exit, _status} = msg, state) do
    session_exited(state.session_id)
    broadcast(state, msg)
    publish_activity(state, %{state: :offline, line: nil})
    {:stop, :normal, %{state | session: nil}}
  end

  # The Session process died without a port exit (crash). Tell the store and
  # the viewers the same honest story an exit tells.
  def handle_info({:DOWN, _ref, :process, session, _reason}, %{session: session} = state) do
    session_exited(state.session_id)
    broadcast(state, {:claude_chat_exit, :crashed})
    publish_activity(state, %{state: :offline, line: nil})
    {:stop, :normal, %{state | session: nil}}
  end

  # Frame-silence reaper: nothing arrived for @idle_after_ms. Close the
  # subprocess (the persisted cursor makes the next send lazy-resume) and tell
  # any idle viewers honestly. `:close` produces NO exit message (charter D18),
  # so we broadcast the teardown ourselves and stop.
  def handle_info(:idle_reap, state) do
    if pid = state.session, do: ClaudeChat.close(pid)
    session_exited(state.session_id)
    broadcast(state, {:claude_chat_exit, :idle_reaped})
    publish_activity(state, %{state: :offline, line: nil})
    {:stop, :normal, %{state | session: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── persistence (mirrors the store shapes replay reads back) ───────────────

  # `ev` is the whole assistant frame so we can stamp its top-level
  # `parent_tool_use_id` onto EVERY row it produces (charter D40): a non-nil id
  # means these rows belong to the sub-agent that spawn created, and replay reads
  # the id back to indent them under the matching spawn row. A top-level frame
  # (null parent) writes the same shape it always did.
  defp persist_assistant_blocks(session_id, blocks, ev) when is_list(blocks) do
    parent = parent_meta(ev)

    Enum.each(blocks, fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        if String.trim(text) != "" do
          persist(
            session_id,
            %{role: "assistant", source_markdown: text, metadata: parent},
            "assistant"
          )
        end

      %{"type" => "tool_use", "name" => name} = block ->
        persist(
          session_id,
          %{
            role: "tool",
            source_markdown: tool_line(name, block["input"]),
            metadata:
              Map.merge(
                %{
                  "tool" => name,
                  "input" => block["input"],
                  "tool_use_id" => block["id"]
                },
                parent
              )
          },
          "tool"
        )

      _ ->
        :ok
    end)
  end

  defp persist_assistant_blocks(_session_id, _, _), do: :ok

  # `%{"parent_tool_use_id" => id}` for a sub-agent frame; `%{}` for a top-level
  # frame (null parent) so the row's metadata is unchanged.
  defp parent_meta(ev) when is_map(ev) do
    case ev["parent_tool_use_id"] do
      id when is_binary(id) and id != "" -> %{"parent_tool_use_id" => id}
      _ -> %{}
    end
  end

  defp parent_meta(_), do: %{}

  defp persist_approval_ask(session_id, ask) do
    text = ask.title || tool_line(ask.tool_name, ask.input)
    role = permission_role(ask.tool_name)

    persist(
      session_id,
      %{
        role: role,
        source_markdown: text,
        metadata: %{
          "request_id" => ask.request_id,
          "tool_name" => ask.tool_name,
          "input" => ask.input,
          "approval_status" => "pending"
        }
      },
      role
    )
  end

  # The store is the router (charter D31): the same wire ask becomes one of
  # three roles by its tool_name, each rendered as a distinct surface
  # downstream. Message.role is a free string — no migration. All three count
  # as "the agent needs you" (the widened needs-you role set in StudioChat).
  defp permission_role("AskUserQuestion"), do: "question"
  defp permission_role("ExitPlanMode"), do: "plan"
  defp permission_role(_), do: "approval"

  # The live-activity line the sidebar shows while an ask is pending (charter
  # D35). A question is asking you something; a proposed plan is ready to
  # review; any other tool is waiting on an approval named by its tool.
  defp needs_you_line("AskUserQuestion"), do: "asking you"
  defp needs_you_line("ExitPlanMode"), do: "plan ready"
  defp needs_you_line(tool_name), do: "waiting: #{tool_name}"

  defp record_result(session_id, ev) do
    StudioChat.record_result_metrics(session_id, %{
      input_tokens: get_in(ev, ["usage", "input_tokens"]),
      output_tokens: get_in(ev, ["usage", "output_tokens"]),
      cache_read_input_tokens: get_in(ev, ["usage", "cache_read_input_tokens"]),
      cache_creation_input_tokens: get_in(ev, ["usage", "cache_creation_input_tokens"]),
      total_cost_usd: ev["total_cost_usd"],
      model: result_model(ev),
      context_window: result_context_window(ev)
    })

    StudioChat.update_status(session_id, "active")
  end

  defp session_exited(session_id) do
    StudioChat.cancel_pending_approvals(session_id)
    StudioChat.mark_exited(session_id)
  end

  defp persist(session_id, attrs, kind) do
    case StudioChat.append_message(session_id, attrs) do
      {:error, reason} ->
        Logger.warning("studio chat recorder: failed to persist #{kind}: #{inspect(reason)}")

      _ ->
        :ok
    end
  end

  # ── live activity (wave 5): what this session is doing right now ───────────

  # The most informative line wins: the LAST tool_use in the frame names the
  # concrete action ("Bash — mix test"); a text-only frame means prose is
  # being written. Keeps the previous activity when the frame adds nothing.
  defp assistant_activity(blocks, previous) when is_list(blocks) do
    tool =
      blocks
      |> Enum.reverse()
      |> Enum.find_value(fn
        %{"type" => "tool_use", "name" => name} = b -> tool_line(name, b["input"])
        _ -> nil
      end)

    cond do
      tool -> %{state: :working, line: tool}
      Enum.any?(blocks, &(&1["type"] == "text")) -> %{state: :working, line: "writing…"}
      true -> previous
    end
  end

  defp assistant_activity(_blocks, previous), do: previous

  # Broadcast on CHANGE only — a hundred stream deltas collapse into one
  # "writing…" event, so the sidebar never gets spammed.
  defp publish_activity(state, activity) do
    if activity != state.activity and activity != nil do
      Phoenix.PubSub.broadcast(
        Barkpark.PubSub,
        activity_topic(),
        {:chat_activity, state.session_id, activity}
      )

      %{state | activity: activity}
    else
      state
    end
  end

  # ── slash-command vocabulary (charter D36a) ────────────────────────────────

  # Normalize the initialize ack's `commands` into a stable list of
  # `%{"name", "description", "argumentHint"}` maps. Anything non-list (or an
  # empty payload — the fake-CLI echo path) yields [] so `advertised/1` falls
  # back to the init names or the LiveView's builtin floor.
  defp extract_commands(response) when is_map(response) do
    case Map.get(response, "commands") do
      list when is_list(list) -> list |> Enum.map(&normalize_command/1) |> Enum.reject(&is_nil/1)
      _ -> []
    end
  end

  defp extract_commands(_), do: []

  defp normalize_command(%{"name" => name} = cmd) when is_binary(name) and name != "" do
    %{
      "name" => name,
      "description" => Map.get(cmd, "description"),
      "argumentHint" => Map.get(cmd, "argumentHint") || Map.get(cmd, "argument_hint")
    }
  end

  defp normalize_command(_), do: nil

  # Hold the name-only fallback from a `system/init` frame, but only while the
  # richer initialize list hasn't arrived (that one is authoritative). Broadcast
  # only when this actually changes what a tab would see.
  defp maybe_capture_slash_commands(state, ev) do
    names =
      case Map.get(ev, "slash_commands") do
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> []
      end

    if names != [] and state.slash_commands != names do
      state = %{state | slash_commands: names}
      broadcast_commands(state)
      state
    else
      state
    end
  end

  # The best-available vocabulary: the rich initialize list wins; else synthesize
  # name-only maps from the init fallback; else [].
  defp advertised(%{commands: commands}) when is_list(commands) and commands != [], do: commands

  defp advertised(%{slash_commands: names}) when is_list(names) and names != [] do
    Enum.map(names, fn name -> %{"name" => name, "description" => nil, "argumentHint" => nil} end)
  end

  defp advertised(_), do: []

  defp broadcast_commands(state) do
    broadcast(state, {:chat_commands, state.session_id, advertised(state)})
  end

  # ── frame plumbing ──────────────────────────────────────────────────────────

  defp broadcast(state, msg) do
    Phoenix.PubSub.broadcast(Barkpark.PubSub, topic(state.session_id), msg)
  end

  defp touch(state), do: %{state | timer: arm_idle(state.timer)}

  defp arm_idle(old) do
    if old, do: Process.cancel_timer(old)
    Process.send_after(self(), :idle_reap, idle_after_ms())
  end

  defp idle_after_ms do
    Application.get_env(:barkpark, :studio_chat_idle_reap_ms, @idle_after_ms)
  end

  # {tool_use_id, output} pairs off a wire user-frame; [] for anything else
  # (our own echoed sends through test fakes never match). Output capped so a
  # huge tool result can't bloat the jsonb row.
  defp user_tool_results(%{"message" => %{"content" => content}}) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "tool_result" and is_binary(&1["tool_use_id"])))
    |> Enum.map(fn b -> {b["tool_use_id"], result_text(b["content"])} end)
    |> Enum.reject(fn {_id, out} -> out in [nil, ""] end)
  end

  defp user_tool_results(_), do: []

  defp result_text(content) when is_binary(content), do: String.slice(content, 0, 4_000)

  defp result_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => t} when is_binary(t) -> t
      _ -> ""
    end)
    |> Enum.join("\n")
    |> String.slice(0, 4_000)
  end

  defp result_text(_), do: nil

  # Same preview shape ChatLive renders, so live lines and replayed rows agree.
  defp tool_line(name, input) when is_map(input) do
    preview =
      input
      |> Enum.filter(fn {_k, v} -> is_binary(v) end)
      |> Enum.map(fn {k, v} -> "#{k}: #{String.slice(v, 0, 80)}" end)
      |> Enum.take(2)
      |> Enum.join(" · ")

    if preview == "", do: name, else: "#{name} — #{preview}"
  end

  defp tool_line(name, _input), do: name

  defp result_model(ev) do
    case ev["modelUsage"] do
      usage when is_map(usage) and map_size(usage) > 0 -> usage |> Map.keys() |> List.first()
      _ -> nil
    end
  end

  defp result_context_window(ev) do
    case ev["modelUsage"] do
      usage when is_map(usage) and map_size(usage) > 0 ->
        usage |> Map.values() |> List.first() |> Kernel.||(%{}) |> Map.get("contextWindow")

      _ ->
        nil
    end
  end
end
