defmodule Barkpark.StudioChat.Recorder do
  @moduledoc """
  Server-owned chat runtime (wave 4, charter D28). One Recorder per live
  session is the provider runtime's PERMANENT sink: it persists every
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

  alias Barkpark.{CycleFleet, StudioChat}
  alias Barkpark.StudioChat.Runtime
  alias Barkpark.StudioChat.Runtime.Event
  alias Barkpark.StudioChat.{RuntimeAdmission, RuntimeTelemetry, RuntimeUsage}

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

  @doc "The underlying provider runtime reference (sends/controls go there)."
  @spec session_pid(pid()) :: {:ok, term()} | {:error, term()}
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
    provider = Map.get(opts, :provider, "claude")
    runtime_attempt = CycleFleet.get_runtime_attempt_by_session(id)
    runtime_ingress_token = make_ref()

    # A Task holder authorized this managed attempt but is not the Studio
    # process's principal. Never mint or forward Task hands for that process.
    minter = if runtime_attempt, do: nil, else: Map.get(opts, :minter)

    # The AT-SPAWN Cloud sandbox binding (charter D139/D154): read ONCE here so
    # both `runtime_opts` (which resumes the box) and Recorder state (which
    # decides at exit whether this was a resume turn) see the SAME value. nil on
    # a create/first turn or a self-hosted session. Never re-read at exit — a
    # create turn's mid-turn bp_sandbox capture would otherwise mask the truth.
    cloud_sandbox_id = load_cloud_sandbox_id(id)

    session_opts =
      %{
        session_id: id,
        resume: Map.get(opts, :resume, false),
        model: Map.get(opts, :model),
        effort: Map.get(opts, :effort),
        bypass_armed: Map.get(opts, :bypass_armed, false),
        provider_session_id: Map.get(opts, :provider_session_id)
      }
      |> maybe_put_minter(minter)

    runtime_opts =
      %{
        session_id: id,
        sink: self(),
        mode: Map.get(opts, :mode, "plan"),
        resume: Map.get(opts, :resume, false),
        execution_target: Map.get(opts, :execution_target, "managed"),
        execution_host_id: Map.get(opts, :execution_host_id),
        workspace_id: Map.get(opts, :workspace_id),
        # The session-scoped Cloud sandbox binding (charter D137/D139). Loaded
        # from the Session row so a fresh Recorder (each turn may spawn one) hands
        # the LAST-KEPT sandbox id to the runtime — runtime/claude.ex lifts it into
        # `session_opts` (mirroring `workspace_id`, D110) where W14-1's
        # `cloud_build_args` reads it to `--resume` the same box. NULL/inert for a
        # self-hosted session (the build_args there ignore the key).
        cloud_sandbox_id: cloud_sandbox_id,
        cwd: Map.get(opts, :cwd),
        provider_session_id: Map.get(opts, :provider_session_id),
        runtime_ingress_token: runtime_ingress_token,
        developer_instructions: codex_developer_instructions(provider, id),
        session_opts: session_opts
      }
      |> maybe_put_minter(minter)

    case RuntimeAdmission.acquire(id, Map.merge(opts, runtime_opts)) do
      {:ok, admission} ->
        case Runtime.open(provider, runtime_opts) do
          {:ok, session} ->
            initialize_runtime(id, session, provider)
            RuntimeTelemetry.observe_identity(id, Runtime.runtime_identity(session, admission))

            {:ok,
             new_state(
               id,
               session,
               provider,
               admission,
               runtime_attempt,
               runtime_ingress_token,
               cloud_sandbox_id
             )}

          {:error, {:already_started, session}} ->
            # A Session survived its Recorder (recorder crash). Re-adopt it as
            # our sink so its frames flow again instead of casting into a dead
            # pid. The old Recorder-owned admission lease died with its owner.
            Runtime.adopt_sink(provider, session, self())
            initialize_runtime(id, session, provider)
            RuntimeTelemetry.observe_identity(id, Runtime.runtime_identity(session, admission))

            {:ok,
             new_state(
               id,
               session,
               provider,
               admission,
               runtime_attempt,
               runtime_ingress_token,
               cloud_sandbox_id
             )}

          {:error, reason} ->
            RuntimeAdmission.release(admission)
            {:stop, {:shutdown, reason}}
        end

      {:error, reason} ->
        {:stop, {:shutdown, reason}}
    end
  end

  defp initialize_runtime(id, session, provider) do
    monitor_runtime(session)
    capture_provider_session_id(id, session)
    # Ask the CLI for its slash-command list right after spawn (charter D36a)
    # — the ack lands as {:claude_chat_control, :initialize, …}, which we hold
    # so a LATE-joining tab still gets the vocabulary.
    Runtime.initialize(provider, session)
    send(self(), :replay_registered_host_events)
  end

  defp codex_developer_instructions("codex", session_id) do
    """
    You are Barkpark Studio Chat worker codex-chat-#{session_id}. Be Task obsessed: for non-trivial repository work, use the repository's AGENTS.md and bp task workflow as the operating contract. Claim the relevant task before implementation, pulse at phase boundaries, stamp acceptance criteria with concrete evidence, and close only after fresh verification. Use Codex native subagents for independent bounded work when that materially improves quality or throughput, and preserve their lifecycle evidence.
    """
  end

  defp codex_developer_instructions(_, _), do: nil

  defp maybe_put_minter(opts, nil), do: opts
  defp maybe_put_minter(opts, minter), do: Map.put(opts, :minter, minter)

  defp new_state(
         id,
         session,
         provider,
         admission,
         runtime_attempt,
         runtime_ingress_token,
         cloud_sandbox_id
       ) do
    %{
      session_id: id,
      provider: provider,
      session: session,
      admission: admission,
      # The Cloud sandbox binding captured AT SPAWN (charter D154), NOT the
      # mutable `chat_sessions.cloud_sandbox_id` column: a create turn's
      # bp_sandbox capture writes the column mid-turn, so re-reading it at exit
      # would orphan a healthy fresh sandbox. nil for a create/first turn or a
      # self-hosted session; a non-nil value means this turn tried to RESUME an
      # existing box, so a loud exit means that box is gone → clear the binding.
      cloud_sandbox_id: cloud_sandbox_id,
      monitor_pid: Runtime.runtime_pid(session),
      timer: arm_idle(nil),
      activity: nil,
      runtime_text: "",
      # The tool_use_id of THIS turn's FIRST TodoWrite-shaped block (charter D39).
      # Each TodoWrite arrives as a fresh tool_use with a unique id, so a later
      # one in the same turn UPDATES this persisted row's input in place rather
      # than appending — replay then reconstructs ONE final-state checklist card.
      # Reset to nil on every `system/init` (the per-turn boundary).
      todo_tool_use_id: nil,
      # The advertised slash-command list (charter D36a). `commands` is the rich
      # authoritative list from the initialize ack; `slash_commands` is the
      # name-only fallback captured off `system/init`; a live/late tab reads the
      # best available via `advertised_commands/1`.
      commands: nil,
      slash_commands: nil,
      # Assignment usage authority is loaded from the immutable server row, never
      # accepted from Recorder opts. Generic Studio chats remain unbound and do
      # not mint CycleFleet receipts.
      runtime_attempt: runtime_attempt,
      runtime_ingress_token: runtime_ingress_token,
      # Codex reports cumulative thread snapshots separately from terminal events.
      # Hold the preceding snapshot as the next turn's baseline and only a usage
      # event observed during the active turn as its terminal candidate.
      runtime_usage_snapshot: nil,
      runtime_usage_turn: nil,
      # The current thinking bout's token count (charter D41). Accumulated off
      # `system/thinking_tokens` (`estimated_tokens` is monotonic cumulative — we
      # take the max seen since the last flush, NEVER sum thinking_delta counts),
      # flushed as a compact `"thinking"` row the instant the turn's assistant
      # blocks (or the terminal result) land so replay renders the pulse in-order.
      # nil ⇒ no active bout.
      pending_thinking: nil,
      # Agent-lifecycle correlation (charter D45). Maps a sub-agent's `task_id`
      # → `%{tool_use_id, last_line}`: the spawn's tool_use_id (so a
      # `task_updated` frame — which carries task_id ONLY — resolves the row it
      # belongs to) and the last progress line we persisted (so a chatty agent's
      # repeated `task_progress` heartbeat writes the row only on a real change).
      # SESSION-LIFETIME — never reset on the per-turn `system/init` boundary; a
      # spawn started in one turn may still complete after a fresh init.
      task_index: %{},
      # The agents-rail snapshot (charter D47), task_id-keyed — the mission-
      # control view below the composer. Driven by `background_tasks_changed`
      # (the row set), `task_progress.workflow_progress` (the phase→agent tree +
      # last-known usage), and task_updated/task_notification (status). HYDRATED
      # from the store on start so a restarted Recorder never loses the history
      # (replay reads the same column). SESSION-LIFETIME — never reset per turn.
      # Persisted COARSELY: only a structural/state change (rail_signature) hits
      # the store; a token-only progress tick updates memory but skips Repo.
      rail_snapshot: load_rail_snapshot(id)
    }
  end

  # Seed the rail from the persisted column (charter D47) so a Recorder that
  # restarts mid-run keeps the last-known rows/tree as its change-only baseline —
  # otherwise the first `background_tasks_changed` would overwrite the stored
  # history with only the currently-live rows.
  defp load_rail_snapshot(session_id) do
    case StudioChat.get_session(session_id) do
      %{rail_snapshot: rail} when is_map(rail) -> rail
      _ -> %{}
    end
  end

  # The persisted Cloud sandbox binding (charter D137/D139) — the id the next
  # one-shot :cloud turn resumes. nil when unbound (no sandbox yet, expired, or a
  # self-hosted session). Read once at Recorder start and threaded into
  # `runtime_opts` above.
  defp load_cloud_sandbox_id(session_id) do
    case StudioChat.get_session(session_id) do
      %{cloud_sandbox_id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  @impl true
  def handle_call(:session_pid, _from, state), do: {:reply, {:ok, state.session}, state}

  def handle_call({:project_runtime_event, %Event{} = event}, _from, state) do
    state = capture_runtime_event(state, event, false)
    broadcast(state, {:studio_chat_runtime_event, event})
    {:reply, :ok, touch(state)}
  end

  # Late-join query (charter D36a): a tab that opens AFTER the initialize ack
  # already fired still gets the held vocabulary. Returns the best available
  # list of `%{"name", "description", "argumentHint"}` maps (rich, then the
  # name-only init fallback, then []).
  def handle_call(:advertised_commands, _from, state),
    do: {:reply, advertised(state), state}

  # Only the private capability echoed by the managed Session may feed
  # assignment usage. The public/generic event shape remains projection-only.
  def handle_info(
        {:studio_chat_managed_runtime_event, token, %Event{} = event},
        %{runtime_ingress_token: token} = state
      ) do
    state = capture_runtime_event(state, event, true)
    broadcast(state, {:studio_chat_runtime_event, event})
    {:noreply, touch(state)}
  end

  # Provider-neutral untrusted ingress for registered-host replay and generic
  # projection callers. It can update chat UI state but cannot mint usage.
  def handle_info({:studio_chat_runtime_event, %Event{} = event} = msg, state) do
    state = capture_runtime_event(state, event, false)
    broadcast(state, msg)
    {:noreply, touch(state)}
  end

  def handle_info(:replay_registered_host_events, state) do
    state =
      state.session_id
      |> Barkpark.ChatHosts.replay_unprojected()
      |> Enum.reduce(state, fn
        {event_id, %Event{} = event}, acc ->
          acc = capture_runtime_event(acc, event, false)
          broadcast(acc, {:studio_chat_runtime_event, event})
          Barkpark.ChatHosts.mark_projected(event_id)
          acc

        _, acc ->
          acc
      end)

    {:noreply, touch(state)}
  end

  # ── sink messages: persist, then rebroadcast verbatim ──────────────────────

  @impl true
  def handle_info({:claude_chat_event, %{"type" => "assistant"} = ev} = msg, state) do
    blocks = get_in(ev, ["message", "content"])
    # A thinking bout that preceded these blocks flushes FIRST (charter D41), so
    # replay reconstructs the ✻ pulse row in the same order it streamed live.
    state = flush_thinking(state)
    state = persist_assistant_blocks(state, blocks, ev)
    broadcast(state, msg)
    {:noreply, state |> publish_activity(assistant_activity(blocks, state.activity)) |> touch()}
  end

  def handle_info({:claude_chat_event, %{"type" => "result"} = ev} = msg, state) do
    # Edge case: a turn that thought then produced NO assistant blocks (straight
    # to result) still flushes its pulse row so the thought is never lost.
    state = flush_thinking(state)
    record_result(state.session_id, ev)
    broadcast(state, msg)
    {:noreply, state |> publish_activity(%{state: :idle, line: nil}) |> touch()}
  end

  # The extended-thinking pulse (charter D41). The wire never carries thinking
  # TEXT (empty across models) — only a monotonic cumulative `estimated_tokens`
  # and an encrypted signature we NEVER persist. Track the bout's high-water mark
  # so the flushed row reports how much thinking happened; rebroadcast verbatim so
  # live tabs run their own counter. This clause MUST precede the generic
  # `{:claude_chat_event, _ev}` catch-all below.
  def handle_info(
        {:claude_chat_event, %{"type" => "system", "subtype" => "thinking_tokens"} = ev} = msg,
        state
      ) do
    broadcast(state, msg)
    {:noreply, state |> accumulate_thinking(thinking_tokens_count(ev)) |> touch()}
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
    # A new turn begins: forget the previous turn's todo row (D39) and drop any
    # unflushed thinking count from a prior turn (D41) — both are per-turn state.
    state = %{
      maybe_capture_slash_commands(state, ev)
      | todo_tool_use_id: nil,
        pending_thinking: nil
    }

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

  # ── agent lifecycle: task_* frames stamp the spawn row (charter D45) ─────────
  # A Task/Agent spawn persists as a plain tool row keyed by its `tool_use_id`;
  # the CLI then interleaves `task_started` / `task_progress` / `task_updated` /
  # `task_notification` system frames on the SAME stream, each correlating to the
  # spawn by that id. We MERGE the lifecycle facts (task_id, task_status, the live
  # "Running …" line) onto the spawn row so replay reconstructs the agent block's
  # terminal state, while every frame rebroadcasts VERBATIM so a live tab animates
  # the drill-down. These clauses MUST precede the generic `{:claude_chat_event,
  # _ev}` catch-all below (which would otherwise merely rebroadcast them). No
  # `publish_activity` here — the drill-down is its own surface, not a sidebar
  # line (charter D45).
  def handle_info(
        {:claude_chat_event, %{"type" => "system", "subtype" => "task_started"} = ev} = msg,
        state
      ) do
    state = task_started(state, ev)
    broadcast(state, msg)
    {:noreply, touch(state)}
  end

  def handle_info(
        {:claude_chat_event, %{"type" => "system", "subtype" => "task_progress"} = ev} = msg,
        state
      ) do
    state = task_progress(state, ev)
    broadcast(state, msg)
    {:noreply, touch(state)}
  end

  def handle_info(
        {:claude_chat_event, %{"type" => "system", "subtype" => "task_updated"} = ev} = msg,
        state
      ) do
    state = task_updated(state, ev)
    broadcast(state, msg)
    {:noreply, touch(state)}
  end

  def handle_info(
        {:claude_chat_event, %{"type" => "system", "subtype" => "task_notification"} = ev} = msg,
        state
      ) do
    state = task_notification(state, ev)
    broadcast(state, msg)
    {:noreply, touch(state)}
  end

  # The agents rail's row set (charter D47). `background_tasks_changed` is a
  # task_id-keyed SNAPSHOT with NO tool_use_id — it replaces the live rows and,
  # by omission, marks vanished tasks terminal. This clause MUST precede the
  # generic catch-all below (which would merely rebroadcast the frame, exactly
  # why the user saw no agents). Broadcasts every frame so live tabs animate.
  def handle_info(
        {:claude_chat_event, %{"type" => "system", "subtype" => "background_tasks_changed"} = ev} =
          msg,
        state
      ) do
    state = background_tasks_changed(state, ev)
    broadcast(state, msg)
    {:noreply, touch(state)}
  end

  # The Cloud shim's session-scoped sandbox binding (charter D137). When the
  # :cloud execution profile keeps a Vercel Sandbox alive across turns it emits
  # ONE `{"type":"bp_sandbox","subtype":"created","sandbox_id":"…"}` frame. We
  # persist the id onto the Session row — the durable binding the NEXT one-shot
  # turn resumes (threaded back through `session_opts` below) — and then SWALLOW
  # the frame entirely: it is execution control-plumbing, never conversation. No
  # PubSub broadcast (the customer NDJSON/SSE stream stays clean) and no
  # `append_message` (no chat_messages row). This clause MUST precede the generic
  # `{:claude_chat_event, _ev}` catch-all below, which would otherwise rebroadcast
  # it and leak the sandbox id into every viewer.
  def handle_info({:claude_chat_event, %{"type" => "bp_sandbox"} = ev}, state) do
    capture_cloud_sandbox_id(state.session_id, ev["sandbox_id"])
    {:noreply, touch(state)}
  end

  def handle_info({:claude_chat_event, _ev} = msg, state) do
    broadcast(state, msg)
    {:noreply, touch(state)}
  end

  def handle_info({:claude_chat_permission, ask} = msg, state) do
    if Runtime.auto_approve?(state.provider, ask) do
      # D65: a READ-ONLY loopback tool auto-approves at this single D31
      # ask-routing seam — in EVERY mode, plan included. Answered wire-side
      # (the Session echoes its tracked original input as `updatedInput`,
      # D32) and NEVER persisted or broadcast as an ask: no pending row, no
      # needs-you flip, no card — live and replay agree the question was
      # never the human's. Mutating loopback tools (task_next claims,
      # doc_create writes, …) fall through to the honest card below.
      if pid = state.session,
        do: Runtime.answer_approval(state.provider, pid, ask.request_id, :allow)

      {:noreply, touch(state)}
    else
      persist_approval_ask(state.session_id, ask)
      broadcast(state, msg)

      {:noreply,
       state
       |> publish_activity(%{state: :needs_you, line: needs_you_line(ask.tool_name)})
       |> touch()}
    end
  end

  def handle_info({:claude_chat_control, _kind, _rid, _resp} = msg, state) do
    broadcast(state, msg)
    {:noreply, touch(state)}
  end

  def handle_info({:claude_chat_exit, status, _stderr_tail} = msg, state) do
    session_exited(state.session_id)
    release_admission(state)
    # A loud reuse failure means the bound Cloud sandbox is gone — clear the
    # binding SYNCHRONOUSLY here (charter D139 half B / D152–D155), before the
    # {:stop, :normal} below releases the Registry `:via` name. The Ecto commit
    # must precede that release so the next turn's fresh Recorder never re-reads
    # a stale binding and `--resume`s into an empty filesystem.
    maybe_clear_dead_sandbox_binding(state, status)
    # Rebroadcast verbatim so the stderr tail (charter D54) rides through to
    # every viewer's ChatLive; the tail is what lets it refuse a doomed resume.
    broadcast(state, msg)
    publish_activity(state, %{state: :offline, line: nil})
    {:stop, :normal, %{state | session: nil}}
  end

  # The Session process died without a port exit (crash). Tell the store and
  # the viewers the same honest story an exit tells.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{monitor_pid: pid} = state) do
    session_exited(state.session_id)
    release_admission(state)
    broadcast(state, {:claude_chat_exit, :crashed, nil})
    publish_activity(state, %{state: :offline, line: nil})
    {:stop, :normal, %{state | session: nil, monitor_pid: nil}}
  end

  # Frame-silence reaper: nothing arrived for @idle_after_ms. Close the
  # subprocess (the persisted cursor makes the next send lazy-resume) and tell
  # any idle viewers honestly. `:close` produces NO exit message (charter D18),
  # so we broadcast the teardown ourselves and stop.
  def handle_info(:idle_reap, state) do
    if pid = state.session, do: Runtime.close(state.provider, pid)
    session_exited(state.session_id)
    release_admission(state)
    broadcast(state, {:claude_chat_exit, :idle_reaped, nil})
    publish_activity(state, %{state: :offline, line: nil})
    {:stop, :normal, %{state | session: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    release_admission(state)
    :ok
  end

  # ── persistence (mirrors the store shapes replay reads back) ───────────────

  # `ev` is the whole assistant frame so we can stamp its top-level
  # `parent_tool_use_id` onto EVERY row it produces (charter D40): a non-nil id
  # means these rows belong to the sub-agent that spawn created, and replay reads
  # the id back to indent them under the matching spawn row. A top-level frame
  # (null parent) writes the same shape it always did.
  defp persist_assistant_blocks(state, blocks, ev) when is_list(blocks) do
    # The frame-level metadata every row this frame produces inherits: the
    # sub-agent parent (D40) AND the wire frame uuid (D70). `parent_agent` alone
    # decides sub-agent routing (the TodoWrite top-level guard below keys on it);
    # `frame` adds the uuid on top and is what each row actually stamps, so a
    # sub-agent row carries BOTH ids. NOTE: never fold frame_uuid into the routing
    # value — a real top-level TodoWrite frame always carries a uuid, so a merged
    # value would fail the `== %{}` guard and mis-route the turn's checklist.
    parent_agent = parent_meta(ev)
    frame = Map.merge(parent_agent, frame_uuid_meta(ev))

    Enum.reduce(blocks, state, fn
      %{"type" => "text", "text" => text}, st when is_binary(text) ->
        if String.trim(text) != "" do
          persist(
            st.session_id,
            %{role: "assistant", source_markdown: text, metadata: frame},
            "assistant"
          )
        end

        st

      %{"type" => "tool_use", "name" => name} = block, st ->
        input = block["input"]

        if StudioChat.todo_shaped?(input) and parent_agent == %{} do
          # Only a TOP-LEVEL TodoWrite is the turn's living checklist (D39) —
          # a sub-agent's todo list must never hijack the main turn's card, so
          # a child frame's TodoWrite persists as a plain (indented) tool row.
          persist_todo_block(st, name, block)
        else
          persist(
            st.session_id,
            %{
              role: "tool",
              source_markdown: tool_line(name, input),
              metadata:
                %{
                  "tool" => name,
                  "input" => input,
                  "tool_use_id" => block["id"]
                }
                |> Map.merge(mcp_meta(st.provider, name))
                |> Map.merge(frame)
            },
            "tool"
          )

          st
        end

      _, st ->
        st
    end)
  end

  defp persist_assistant_blocks(state, _, _), do: state

  # Tag OUR loopback server's tool rows (charter D64) so the chip renderer
  # (scc-w12-native-chips) can classify persisted rows without re-parsing
  # names: `"mcp" => true` + the bare tool (`task_ready`, `bp_search_query`).
  # `%{}` for every other tool, so a non-loopback row's metadata is unchanged.
  defp mcp_meta(provider, name) do
    case Runtime.tool_name(provider, name) do
      nil -> %{}
      tool -> %{"mcp" => true, "mcp_tool" => tool}
    end
  end

  # `%{"parent_tool_use_id" => id}` for a sub-agent frame; `%{}` for a top-level
  # frame (null parent) so the row's metadata is unchanged.
  defp parent_meta(ev) when is_map(ev) do
    case ev["parent_tool_use_id"] do
      id when is_binary(id) and id != "" -> %{"parent_tool_use_id" => id}
      _ -> %{}
    end
  end

  defp parent_meta(_), do: %{}

  # The top-level `uuid` the CLI stamps on EVERY frame (charter D70 — there is
  # NO `message.uuid`; the wire id is the frame uuid). Capturing it into each
  # persisted row's `metadata.frame_uuid` (jsonb, no migration) turns our
  # message log into a uuid-keyed index of the turn's rows — the branch-point
  # substrate a future fork/rewind UI (wave-13) replays against, with D1 intact
  # (we never read the CLI's private transcript jsonl). A frame with no uuid
  # (a synthetic/legacy frame) leaves the row's metadata unchanged, exactly as
  # `parent_meta` does. Kept a standalone clause, disjoint from the mcp tagging.
  defp frame_uuid_meta(ev) when is_map(ev) do
    case ev["uuid"] do
      uuid when is_binary(uuid) and uuid != "" -> %{"frame_uuid" => uuid}
      _ -> %{}
    end
  end

  defp frame_uuid_meta(_), do: %{}

  # TodoWrite collapse (charter D39). The turn's FIRST TodoWrite persists a fresh
  # "todo" row and becomes the turn's canonical checklist; every later TodoWrite
  # in the SAME turn updates that row's `metadata.input` in place (never appends),
  # so replay reconstructs ONE final-state card. Reset happens on `system/init`.
  defp persist_todo_block(%{todo_tool_use_id: nil} = state, name, block) do
    persist(
      state.session_id,
      %{
        role: "todo",
        source_markdown: tool_line(name, block["input"]),
        metadata: %{
          "tool" => name,
          "input" => block["input"],
          "tool_use_id" => block["id"]
        }
      },
      "todo"
    )

    %{state | todo_tool_use_id: block["id"]}
  end

  defp persist_todo_block(%{todo_tool_use_id: tool_use_id} = state, _name, block) do
    case StudioChat.update_tool_input(state.session_id, tool_use_id, block["input"]) do
      {:error, reason} ->
        Logger.warning("studio chat recorder: failed to update todo row: #{inspect(reason)}")

      _ ->
        :ok
    end

    state
  end

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

  # Accumulate a thinking bout's token high-water mark (charter D41). The wire's
  # `estimated_tokens` is monotonic cumulative WITHIN a bout, so max/2 is safe
  # against out-of-order or repeated frames and never regresses.
  defp accumulate_thinking(state, n) when is_integer(n) and n > 0 do
    %{state | pending_thinking: max(state.pending_thinking || 0, n)}
  end

  defp accumulate_thinking(state, _), do: state

  # Persist the pending bout as a compact `"thinking"` row and clear it. The
  # signature is NEVER stored — only the count (charter D41). A bout with no
  # positive count leaves no row ("no thinking frames ⇒ no row").
  defp flush_thinking(%{pending_thinking: n} = state) when is_integer(n) and n > 0 do
    persist(
      state.session_id,
      %{
        role: "thinking",
        source_markdown: thinking_label(n),
        metadata: %{"tokens" => n}
      },
      "thinking"
    )

    %{state | pending_thinking: nil}
  end

  defp flush_thinking(state), do: %{state | pending_thinking: nil}

  defp thinking_label(n), do: "thought for ~#{n} tokens"

  # The cumulative estimated-token count off a `system/thinking_tokens` frame.
  # Zero for a frame missing the field — accumulate_thinking treats it as a noop.
  defp thinking_tokens_count(ev) do
    case ev["estimated_tokens"] do
      n when is_integer(n) and n > 0 -> n
      _ -> 0
    end
  end

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

  defp capture_runtime_event(state, %Event{} = event, trusted_managed_ingress?) do
    RuntimeTelemetry.observe(state.session_id, event)
    trusted_source? = trusted_managed_ingress? and trusted_runtime_source?(state, event)

    state =
      if trusted_source? or (not trusted_managed_ingress? and is_nil(state.runtime_attempt)) do
        maybe_capture_event_provider_session_id(state.session_id, event.provider_session_id)

        %{
          state
          | session: Runtime.with_provider_session_id(state.session, event.provider_session_id)
        }
      else
        state
      end

    state =
      if trusted_source? and trusted_runtime_usage_identity?(state, event) do
        capture_runtime_usage(state, event)
      else
        state
      end

    case event.kind do
      :session_started ->
        state

      :turn_started ->
        StudioChat.update_status(state.session_id, "working")
        %{state | runtime_text: ""} |> publish_activity(%{state: :working, line: "thinking…"})

      :text_delta ->
        %{state | runtime_text: state.runtime_text <> runtime_delta(event)}
        |> publish_activity(%{state: :working, line: "writing…"})

      :approval_requested ->
        ask = runtime_approval(event)
        persist_approval_ask(state.session_id, ask)
        broadcast(state, {:claude_chat_permission, ask})
        publish_activity(state, %{state: :needs_you, line: needs_you_line(ask.tool_name)})

      :turn_completed ->
        persist_runtime_text(state)
        StudioChat.update_status(state.session_id, "active")
        %{state | runtime_text: ""} |> publish_activity(%{state: :idle, line: nil})

      :control_completed ->
        state

      kind when kind in [:item_started, :item_completed] ->
        lifecycle = if kind == :item_started, do: :started, else: :completed
        item = get_in(event.native, ["params", "item"]) || %{}
        commit_rail(state, StudioChat.rail_apply_codex_item(state.rail_snapshot, item, lifecycle))

      kind when kind in [:error, :process_failed, :protocol_error] ->
        persist_runtime_text(state)
        StudioChat.update_status(state.session_id, "exited")
        publish_activity(state, %{state: :offline, line: nil})

      _ ->
        state
    end
  end

  defp capture_runtime_usage(%{runtime_attempt: nil} = state, _event), do: state

  defp capture_runtime_usage(state, %Event{kind: :usage} = event) do
    usage_turn =
      case state.runtime_usage_turn do
        %{turn_id: turn_id} = turn when turn_id == event.turn_id ->
          %{turn | terminal_snapshot: event}

        turn ->
          turn
      end

    %{state | runtime_usage_snapshot: event, runtime_usage_turn: usage_turn}
  end

  defp capture_runtime_usage(state, %Event{kind: :turn_started, turn_id: turn_id} = event)
       when is_binary(turn_id) and turn_id != "" do
    observe_runtime_boundary(state, :baseline, state.runtime_usage_snapshot, event)
    %{state | runtime_usage_turn: %{turn_id: turn_id, terminal_snapshot: nil}}
  end

  defp capture_runtime_usage(
         state,
         %Event{kind: kind, turn_id: turn_id} = event
       )
       when kind in [:turn_completed, :error, :process_failed, :protocol_error] and
              is_binary(turn_id) and turn_id != "" do
    case state.runtime_usage_turn do
      %{turn_id: ^turn_id, terminal_snapshot: snapshot} ->
        observe_runtime_boundary(state, :terminal, snapshot, event)

      _ ->
        :ok
    end

    %{state | runtime_usage_turn: nil}
  end

  defp capture_runtime_usage(state, _event), do: state

  defp trusted_runtime_source?(state, event),
    do: event.provider == state.provider and event.session_id == state.session_id

  defp trusted_runtime_usage_identity?(state, event) do
    expected_provider_session_id = Runtime.provider_session_id(state.session)

    is_binary(expected_provider_session_id) and
      event.provider_session_id == expected_provider_session_id
  end

  defp observe_runtime_boundary(_state, _boundary, nil, _identity), do: :ok

  defp observe_runtime_boundary(state, boundary, %Event{} = snapshot, %Event{} = identity) do
    event = %{
      snapshot
      | provider: identity.provider,
        session_id: identity.session_id,
        provider_session_id: identity.provider_session_id,
        turn_id: identity.turn_id,
        idempotency_key: nil,
        native: %{}
    }

    attribution =
      case CycleFleet.current_runtime_attempt_attribution(state.runtime_attempt) do
        {:ok, attribution} -> attribution
        {:error, _reason} -> Barkpark.CycleFleet.RuntimeAttempt.attribution(state.runtime_attempt)
      end

    case RuntimeUsage.observe(attribution, boundary, event) do
      {:ok, result} when result in [:recorded, :duplicate] ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "studio chat recorder: runtime usage #{boundary} was rejected: #{inspect(reason)}"
        )
    end
  end

  defp capture_provider_session_id(session_id, runtime_ref) do
    maybe_capture_event_provider_session_id(session_id, Runtime.provider_session_id(runtime_ref))
  end

  defp maybe_capture_event_provider_session_id(session_id, provider_session_id)
       when is_binary(provider_session_id) and provider_session_id != "" do
    case StudioChat.set_provider_session_id(session_id, provider_session_id) do
      {:ok, _session} ->
        :ok

      {:error, :immutable} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "studio chat recorder: failed to persist provider session id: #{inspect(reason)}"
        )
    end
  end

  defp maybe_capture_event_provider_session_id(_session_id, _provider_session_id), do: :ok

  # Persist the Cloud sandbox binding off a swallowed `bp_sandbox` frame (charter
  # D137). Unlike the write-once provider session id, this SETS/OVERWRITES (a
  # fresh sandbox after an expiry is a legitimate re-bind, D139). An absent/blank
  # id is a no-op — never clobber the stored binding with garbage.
  defp capture_cloud_sandbox_id(session_id, sandbox_id)
       when is_binary(sandbox_id) and sandbox_id != "" do
    case StudioChat.set_cloud_sandbox_id(session_id, sandbox_id) do
      {:ok, _session} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "studio chat recorder: failed to persist cloud sandbox id: #{inspect(reason)}"
        )
    end
  end

  defp capture_cloud_sandbox_id(_session_id, _sandbox_id), do: :ok

  # Clear the Cloud sandbox binding when a RESUME turn dies LOUD (charter D139
  # half B / D152). The coarse Elixir-only signature: this turn was spawned WITH
  # a binding (at-spawn `is_binary(id)` — only the `:cloud` shim's bp_sandbox
  # frame ever sets the column, so self-hosted sessions never trip this) AND the
  # port exited nonzero (`is_integer(status) and status != 0`). A reuse-path
  # failure propagates the runner's raw nonzero code (create-fail is 1 via the
  # shim's catch, reuse-fail propagates raw codes like 47), so NEVER key a fixed
  # code. The accepted cost (D152): a transient control-plane blip clears a live
  # binding → one loud honest re-create, never a `--resume` into the void.
  # Atom statuses (:crashed, :idle_reaped) and clean exit 0 all fall through the
  # catch-all and PRESERVE the binding (the sandbox is presumed alive).
  defp maybe_clear_dead_sandbox_binding(
         %{cloud_sandbox_id: id, session_id: session_id},
         status
       )
       when is_binary(id) and is_integer(status) and status != 0 do
    case StudioChat.set_cloud_sandbox_id(session_id, nil) do
      {:ok, _session} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "studio chat recorder: failed to clear dead cloud sandbox binding: #{inspect(reason)}"
        )
    end
  end

  defp maybe_clear_dead_sandbox_binding(_state, _status), do: :ok

  defp monitor_runtime(runtime_ref) do
    case Runtime.runtime_pid(runtime_ref) do
      pid when is_pid(pid) -> Process.monitor(pid)
      _ -> nil
    end
  end

  defp runtime_delta(%Event{native: native}) do
    case get_in(native, ["params", "delta"]) || get_in(native, [:params, :delta]) do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  defp runtime_approval(%Event{} = event) do
    params = event.native["params"] || event.native[:params] || %{}

    %{
      request_id: event.approval_id,
      tool_name: runtime_approval_name(event.native),
      input: params,
      title: nil
    }
  end

  defp runtime_approval_name(native) do
    case native["method"] || native[:method] do
      "item/fileChange/requestApproval" -> "FileChange"
      "item/permissions/requestApproval" -> "Permissions"
      "item/commandExecution/requestApproval" -> "CommandExecution"
      method when is_binary(method) -> method
      _ -> "Approval"
    end
  end

  defp persist_runtime_text(%{runtime_text: text, session_id: session_id})
       when is_binary(text) and text != "" do
    persist(session_id, %{role: "assistant", source_markdown: text, metadata: %{}}, "assistant")
  end

  defp persist_runtime_text(_state), do: :ok

  defp session_exited(session_id) do
    StudioChat.cancel_pending_approvals(session_id)
    # Any sub-agent still "running" at teardown can never report — flip it to
    # "interrupted" so a reopened block never lies "running" forever (charter D45).
    StudioChat.interrupt_running_tasks(session_id)
    StudioChat.mark_exited(session_id)
  end

  defp release_admission(%{admission: admission}), do: RuntimeAdmission.release(admission)
  defp release_admission(_state), do: :ok

  # ── agent lifecycle (charter D45) ──────────────────────────────────────────

  # A sub-agent begins. Correlate the spawn row (by tool_use_id) with the task_id,
  # stamp its `running` status (a status transition — always persisted), and
  # remember the id pair so a later task_id-only `task_updated` finds the row.
  defp task_started(state, ev) do
    tid = ev["task_id"]
    tuid = ev["tool_use_id"]

    if is_binary(tid) and is_binary(tuid) do
      stamp_task(state.session_id, tuid, %{"task_id" => tid, "task_status" => "running"})
      put_task(state, tid, tuid)
    else
      state
    end
  end

  # A live progress line (the `description` field carries "Running …") AND the
  # crown-jewel `workflow_progress` phase→agent tree for the rail (charter D47).
  # The caller rebroadcasts every frame, but we PERSIST coarsely on BOTH surfaces:
  # the spawn-row line writes only when it CHANGED; the rail writes only when its
  # STRUCTURE changed (a token-only tick updates memory but skips Repo).
  defp task_progress(state, ev) do
    state
    |> stamp_progress_line(ev)
    |> rail_capture_progress(ev)
  end

  defp stamp_progress_line(state, ev) do
    tid = ev["task_id"]
    tuid = ev["tool_use_id"] || tool_use_for(state, tid)
    line = ev["description"]

    cond do
      not (is_binary(tuid) and is_binary(line)) ->
        state

      line == last_line(state, tid) ->
        state

      true ->
        stamp_task(state.session_id, tuid, %{"task_progress" => line})
        put_line(state, tid, tuid, line)
    end
  end

  # task_updated carries ONLY task_id + patch{status,end_time}. Resolve the spawn
  # row via the session-lifetime index; a task_id we never saw start (or a patch
  # with no status) drops harmlessly. Terminal status is a transition — persisted.
  defp task_updated(state, ev) do
    tid = ev["task_id"]
    status = get_in(ev, ["patch", "status"])

    with tuid when is_binary(tuid) <- tool_use_for(state, tid),
         s when is_binary(s) <- status do
      stamp_task(state.session_id, tuid, %{"task_status" => s})
    end

    rail_stamp_status(state, tid, status)
  end

  # The PRIMARY completion driver — it carries `tool_use_id` directly, so no index
  # lookup is needed; the terminal status is stamped straight onto the spawn row.
  # Also (re)records the id pair in case task_started was somehow missed.
  defp task_notification(state, ev) do
    tid = ev["task_id"]
    tuid = ev["tool_use_id"] || tool_use_for(state, tid)
    status = ev["status"]

    if is_binary(tuid) and is_binary(status) do
      stamp_task(state.session_id, tuid, %{"task_status" => status})
    end

    state = if is_binary(tid) and is_binary(tuid), do: put_task(state, tid, tuid), else: state
    rail_stamp_status(state, tid, status)
  end

  # Merge a lifecycle patch onto the spawn row (never clobbering its input, D45).
  defp stamp_task(session_id, tool_use_id, patch) do
    case StudioChat.merge_tool_metadata(session_id, tool_use_id, patch) do
      {:error, reason} ->
        Logger.warning("studio chat recorder: failed to stamp task metadata: #{inspect(reason)}")

      _ ->
        :ok
    end
  end

  # task_index helpers (session-lifetime; %{task_id => %{tool_use_id, last_line}}).
  defp put_task(state, tid, tuid) do
    entry = state.task_index |> Map.get(tid, %{}) |> Map.put(:tool_use_id, tuid)
    %{state | task_index: Map.put(state.task_index, tid, entry)}
  end

  defp put_line(state, tid, tuid, line) do
    entry =
      state.task_index
      |> Map.get(tid, %{})
      |> Map.merge(%{tool_use_id: tuid, last_line: line})

    %{state | task_index: Map.put(state.task_index, tid, entry)}
  end

  defp tool_use_for(state, tid) when is_binary(tid),
    do: get_in(state.task_index, [tid, :tool_use_id])

  defp tool_use_for(_state, _), do: nil

  defp last_line(state, tid) when is_binary(tid),
    do: get_in(state.task_index, [tid, :last_line])

  defp last_line(_state, _), do: nil

  # ── agents rail (charter D47) ──────────────────────────────────────────────
  #
  # The PURE folds live in StudioChat (rail_apply_background / rail_capture_progress
  # / rail_stamp_status) so the Recorder and ChatLive fold identically off the same
  # code — the Recorder wraps each with commit_rail (persist-on-structural-change),
  # ChatLive wraps them with its own render guard.

  defp background_tasks_changed(state, ev),
    do: commit_rail(state, StudioChat.rail_apply_background(state.rail_snapshot, ev))

  defp rail_capture_progress(state, ev),
    do: commit_rail(state, StudioChat.rail_capture_progress(state.rail_snapshot, ev))

  defp rail_stamp_status(state, tid, status),
    do: commit_rail(state, StudioChat.rail_stamp_status(state.rail_snapshot, tid, status))

  # Persist the rail COARSELY (charter D47): only when the token/usage-stripped
  # structural signature actually changed. A token-only progress tick updates the
  # in-memory copy (so the last-known totals ride the next structural persist) but
  # never issues a Repo.update. ONE shared signature fn with ChatLive.
  defp commit_rail(state, new_rail) do
    if StudioChat.rail_signature(new_rail) != StudioChat.rail_signature(state.rail_snapshot) do
      persist_rail(state.session_id, new_rail)
    end

    %{state | rail_snapshot: new_rail}
  end

  defp persist_rail(session_id, rail) do
    case StudioChat.set_rail_snapshot(session_id, rail) do
      {:error, reason} ->
        Logger.warning("studio chat recorder: failed to persist rail: #{inspect(reason)}")

      _ ->
        :ok
    end
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
  # A diff-shaped call (Edit/Write/MultiEdit by SHAPE — mirrors
  # BarkparkWeb.Studio.ChatToolRenderer.classify/1, which the core-side Recorder
  # must not call) headlines only the path: the D38 diff below carries the
  # content, so a duplicate old/new-string preview would just be noise.
  defp tool_line(name, input) when is_map(input) do
    if diff_shaped?(input) do
      "#{name} — #{input["file_path"]}"
    else
      preview =
        input
        |> Enum.filter(fn {_k, v} -> is_binary(v) end)
        |> Enum.map(fn {k, v} -> "#{k}: #{String.slice(v, 0, 80)}" end)
        |> Enum.take(2)
        |> Enum.join(" · ")

      if preview == "", do: name, else: "#{name} — #{preview}"
    end
  end

  defp tool_line(name, _input), do: name

  defp diff_shaped?(input) when is_map(input) do
    is_binary(input["file_path"]) and
      ((is_binary(input["old_string"]) and is_binary(input["new_string"])) or
         is_binary(input["content"]) or
         (is_list(input["edits"]) and input["edits"] != []))
  end

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
