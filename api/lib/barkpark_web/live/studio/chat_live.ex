defmodule BarkparkWeb.Studio.ChatLive do
  @moduledoc """
  Studio **Claude chat** at `/studio/chat` — admin-only agent chat backed by
  the host's Claude Code CLI. Sessions are a PLACE: every conversation is
  persisted (`Barkpark.StudioChat`), listed in the sidebar, addressable at
  `/studio/chat/:session_id`, and resumable via the CLI's `--resume`.

  The chat subprocess is owned by `BarkparkWeb.Studio.ClaudeChat.Session`,
  started lazily on the first send — never on mount, never on reopen
  (reopen replays OUR persisted history instantly). Every decoded
  stream-json event arrives here as `{:claude_chat_event, map}`:

    * `system/init`   → model + session id for the header
    * `stream_event`  → `text_delta`s accumulate into the in-progress bubble
    * `assistant`     → the completed message replaces the streaming buffer
                        (t3code's accumulate-and-reconcile pattern); tool_use
                        blocks render as dim activity lines
    * `result`        → the turn is over — back to ready, usage in the footer

  Gating lives in `BarkparkWeb.Studio.ClaudeChat` — this mount redirects out
  unless `ClaudeChat.enabled?/0` (which hard-refuses public-demo hosts and
  honors the per-host opt-out), and the `:admin_studio` live_session carrying
  the route applies the admin `on_mount` gate.

  Zero JS: the transcript scroll container is `column-reverse`, so the newest
  content sticks to the bottom without a hook; the composer input remounts
  (id bump) to clear after each send.
  """

  use BarkparkWeb, :live_view

  require Logger

  alias Barkpark.PortableDoc.FromMarkdown
  alias Barkpark.PortableDoc.Render
  alias Barkpark.StudioChat
  alias BarkparkWeb.Studio.ClaudeChat

  # How long a Stop may sit in `:interrupting` before we force-close a wedged
  # CLI (charter D18). Config-overridable so tests can drive the timeout fast.
  @default_interrupt_timeout_ms 8_000

  # Mount no longer spawns (the eager-spawn contract is inverted, charter D8/D14):
  # mount lays out the chrome + loads the sidebar session list; `handle_params/3`
  # is the single source of truth for WHICH session is on screen. A subprocess is
  # started lazily only on the first user send, never on mount and never on
  # reopen — reopening replays OUR persisted history instantly and resumes the
  # CLI's memory on the next send via `--resume`.
  @impl true
  def mount(_params, _session, socket) do
    if ClaudeChat.enabled?() do
      {:ok,
       socket
       |> assign(
         page_title: "chat",
         nav_section: :chat,
         dataset: default_dataset(),
         current_path: "/studio/chat",
         session: nil,
         store_session_id: nil,
         session_id: nil,
         sessions: StudioChat.list_sessions(),
         show_archived: false,
         renaming_session: nil,
         open_menu_session: nil,
         mode: "plan",
         status: :new,
         init: nil,
         messages: [],
         next_id: 0,
         streaming: nil,
         composer_rev: 0,
         interrupt_requested: false,
         mode_switch_from: nil,
         detached: false,
         last_result: nil,
         ring: blank_ring(),
         title_source: "default",
         title_kicked: false
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "Claude chat is not enabled on this instance.")
       |> redirect(to: "/studio")}
    end
  end

  # Single source of truth for the on-screen session. Fires on the initial mount
  # AND on every `push_patch` (sidebar click, new-chat, first-send self-patch).
  @impl true
  def handle_params(%{"session_id" => sid}, _uri, socket) do
    cond do
      # A `push_patch` to the session we already own (e.g. right after a fresh
      # send minted + patched to its own uuid) — keep the live state untouched.
      socket.assigns.store_session_id == sid ->
        {:noreply, assign(socket, session_id: sid)}

      true ->
        case StudioChat.get_session(sid) do
          nil ->
            # Unknown/deleted session — fall back to the new-chat state with an
            # honest notice. (A mount-time push_patch would fight the initial
            # navigation; resetting in place is simpler and just as clear.)
            {:noreply,
             socket
             |> reset_to_new_chat()
             |> put_flash(:error, "That chat is no longer available.")}

          session ->
            {:noreply, load_stored_session(socket, session)}
        end
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, reset_to_new_chat(socket)}
  end

  @impl true
  def handle_event("send", %{"message" => text}, socket) do
    text = String.trim(text)

    # No send queue (t3 item 10): while a turn runs the only control is Stop —
    # a stray Enter-submit must not fire a second overlapping turn. Enter is a
    # server-side no-op here; the composer shows Stop, not Send.
    cond do
      text == "" ->
        {:noreply, socket}

      turn_active?(socket.assigns.status) ->
        {:noreply, socket}

      true ->
        socket = ensure_session(socket)

        case socket.assigns.session do
          nil ->
            {:noreply, socket}

          session ->
            ClaudeChat.send_message(session, text)

            {:noreply,
             socket
             |> persist_user_message(text)
             |> append_message(:user, text)
             |> assign(
               status: :thinking,
               interrupt_requested: false,
               composer_rev: socket.assigns.composer_rev + 1
             )}
        end
    end
  end

  # Stop a running turn. The interrupt is a control-request frame on stdin
  # (proven on the raw wire): the CLI aborts the turn and emits a terminal
  # `result` with subtype `error_during_execution` /
  # `terminal_reason: "aborted_streaming"` — but the session SURVIVES. We flag
  # `interrupt_requested` so the result classifies as "interrupted", never an
  # error, and flip to a transient `:interrupting` status for honest feedback.
  # A late ack (or a duplicate Stop) is harmless — the cast is idempotent.
  #
  # Stopping cannot wedge (charter D18): we arm an {:interrupt_timeout, sid}
  # timer. If a terminal `result` arrives first, status leaves `:interrupting`
  # and the timer no-ops; if the CLI wedges (no result), the timer force-closes
  # the subprocess and runs the shared honest teardown so the composer never
  # sticks at "Stopping…" forever.
  def handle_event("stop_turn", _params, socket) do
    case socket.assigns.session do
      nil ->
        {:noreply, socket}

      session ->
        ClaudeChat.interrupt(session)

        Process.send_after(
          self(),
          {:interrupt_timeout, socket.assigns[:store_session_id]},
          interrupt_timeout_ms()
        )

        {:noreply, assign(socket, interrupt_requested: true, status: :interrupting)}
    end
  end

  # Switching permission mode steers the LIVE session via a `set_permission_mode`
  # control frame (key `mode`, charter D12) — the model's context is preserved,
  # no respawn. With no live subprocess (the common case now that spawn is lazy)
  # it is a silent selector update; the next spawn carries the mode via
  # build_args. Either way we PERSIST the switch (charter D17) so a reopened
  # session shows the mode you chose and the next lazy `--resume` spawn carries
  # it — the store row no longer keeps its stale creation mode.
  def handle_event("set-mode", %{"mode" => mode}, socket) do
    mode = ClaudeChat.normalize_mode(mode)

    cond do
      mode == socket.assigns.mode ->
        {:noreply, socket}

      session = socket.assigns.session ->
        # Optimistic: move the selector + persist now, but remember the prior
        # mode so the echoed control_response can revert it if the switch didn't
        # take (the CLI acks subtype:success even for a silent no-op — D12).
        prev = socket.assigns.mode
        ClaudeChat.set_permission_mode(session, mode)
        persist_mode(socket, mode)

        {:noreply,
         socket
         |> assign(mode: mode, mode_switch_from: prev)
         |> append_message(:system, "Permission mode → #{mode_label(mode)}.")}

      true ->
        persist_mode(socket, mode)
        {:noreply, assign(socket, mode: mode)}
    end
  end

  # Take the session back after another tab adopted it (charter D20). Clears the
  # detached banner and re-acquires the live process via `ensure_session` —
  # which, finding the other tab still registered, ADOPTS it (the other tab now
  # sees the detached banner). One writer at a time, ownership ping-pongs
  # honestly.
  def handle_event("take_over", _params, socket) do
    {:noreply, socket |> assign(detached: false) |> ensure_session()}
  end

  def handle_event("approve", %{"rid" => request_id}, socket) do
    {:noreply, resolve_permission(socket, request_id, :allow)}
  end

  def handle_event("deny", %{"rid" => request_id}, socket) do
    {:noreply, resolve_permission(socket, request_id, {:deny, "The user declined this action."})}
  end

  # ── sidebar as a managed resource list (wave 2) ──────────────────────────

  # Toggle the per-row kebab menu (idempotent open/close). `phx-click-away` on
  # the open menu closes it; opening a different row's menu replaces the target.
  def handle_event("session-menu-toggle", %{"id" => id}, socket) do
    next = if socket.assigns.open_menu_session == id, do: nil, else: id
    {:noreply, assign(socket, open_menu_session: next)}
  end

  def handle_event("session-menu-close", _params, socket) do
    {:noreply, assign(socket, open_menu_session: nil)}
  end

  # Inline rename triad (cloned from the sheet-tab rename, sheet_grid.ex) with
  # ONE divergence: blur COMMITS (a click-away while editing keeps your edit).
  def handle_event("session-rename-start", %{"id" => id}, socket) do
    {:noreply, assign(socket, renaming_session: id, open_menu_session: nil)}
  end

  # Commit path shared by Enter (form submit → `title`) and blur (→ `value`).
  # A blank/whitespace title cancels rather than erroring through the required
  # validation — an empty rename is a no-op, never a wipe.
  def handle_event("session-rename", %{"id" => id} = params, socket) do
    title = (params["title"] || params["value"] || "") |> String.trim()
    socket = assign(socket, renaming_session: nil)

    socket =
      if title == "" do
        socket
      else
        # rename/2 pins title_source: "human" — a human name is never
        # overwritten by the AI titler (charter D13).
        StudioChat.rename(id, title)
        refresh_sessions(socket)
      end

    {:noreply, socket}
  end

  def handle_event("session-rename-cancel", _params, socket) do
    {:noreply, assign(socket, renaming_session: nil)}
  end

  def handle_event("session-archive", %{"id" => id}, socket) do
    StudioChat.archive_session(id)
    {:noreply, after_lifecycle_mutation(socket, id)}
  end

  # Unarchive keeps an on-screen session on screen (store_session_id unchanged);
  # it only leaves the archived shelf, so a refresh is enough — no push_patch.
  def handle_event("session-unarchive", %{"id" => id}, socket) do
    StudioChat.unarchive_session(id)
    {:noreply, socket |> assign(open_menu_session: nil) |> refresh_sessions()}
  end

  def handle_event("session-delete", %{"id" => id}, socket) do
    StudioChat.delete_session(id)
    {:noreply, after_lifecycle_mutation(socket, id)}
  end

  # Flip the active ⇄ archived shelf. refresh_sessions reads the new flag.
  def handle_event("toggle-archived", _params, socket) do
    show = not (socket.assigns.show_archived == true)

    {:noreply,
     socket |> assign(show_archived: show, open_menu_session: nil) |> refresh_sessions()}
  end

  # Stale/unknown client events must never crash the chat — mirror the other
  # admin LVs' tolerant catch-all.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:claude_chat_event, %{"type" => "system", "subtype" => "init"} = ev}, socket) do
    init = %{
      model: ev["model"],
      session_id: ev["session_id"],
      permission_mode: ev["permissionMode"] || ev["permission_mode"]
    }

    status = if socket.assigns.status == :starting, do: :ready, else: socket.assigns.status
    {:noreply, assign(socket, init: init, status: status)}
  end

  def handle_info(
        {:claude_chat_event,
         %{
           "type" => "stream_event",
           "event" => %{
             "type" => "content_block_delta",
             "delta" => %{"type" => "text_delta", "text" => text}
           }
         }},
        socket
      ) do
    {:noreply, assign(socket, streaming: advance_streaming(socket.assigns.streaming, text))}
  end

  def handle_info(
        {:claude_chat_event, %{"type" => "assistant", "message" => %{"content" => blocks}}},
        socket
      )
      when is_list(blocks) do
    socket =
      Enum.reduce(blocks, socket, fn
        %{"type" => "text", "text" => text}, acc when is_binary(text) ->
          if String.trim(text) == "" do
            acc
          else
            append_message(acc, :assistant, text, html: render_paper_html(text))
          end

        %{"type" => "tool_use", "name" => name} = block, acc ->
          append_message(acc, :tool, tool_line(name, block["input"]))

        _block, acc ->
          acc
      end)

    # Persist on COMPLETION (D7) — the whole assistant message is here, so this
    # is the message boundary, never a per-delta write. Streaming deltas only
    # touch the `:streaming` assign; nothing hits the store mid-turn.
    persist_assistant_blocks(socket, blocks)

    # The complete message supersedes the accumulated preview, and the sidebar
    # picks up the fresh summary/message_count.
    {:noreply, socket |> assign(streaming: nil) |> refresh_sessions()}
  end

  def handle_info({:claude_chat_event, %{"type" => "result"} = ev}, socket) do
    # An interrupted turn arrives as `error_during_execution` too — the ONLY
    # way to tell it from a genuine error is that WE asked to stop
    # (`interrupt_requested`) or the CLI tagged the terminus
    # `aborted_streaming`. Classify honestly: an interrupt is a normal outcome,
    # not a failure, and the session stays live for a follow-up.
    interrupted? =
      socket.assigns[:interrupt_requested] == true or
        ev["terminal_reason"] == "aborted_streaming"

    socket =
      cond do
        ev["subtype"] == "success" ->
          maybe_kick_title(socket)

        interrupted? ->
          append_message(socket, :system, "⊘ Interrupted — the session is still live.")

        true ->
          append_message(socket, :system, "The turn ended with an error (#{ev["subtype"]}).")
      end

    socket = record_result(socket, ev)
    last_result = %{duration_ms: ev["duration_ms"], cost_usd: ev["total_cost_usd"]}

    {:noreply,
     socket
     |> assign(
       status: :ready,
       streaming: nil,
       last_result: last_result,
       interrupt_requested: false
     )
     |> refresh_sessions()}
  end

  # The async AI title landed (the store's clobber guard already refused any
  # write that would stomp a human rename) — refresh the sidebar so the row
  # shows it, whichever session it belongs to.
  def handle_info({:chat_title, _session_id, _title}, socket) do
    {:noreply, refresh_sessions(socket)}
  end

  # The CLI acked a permission-mode switch (charter D17). NEVER trust the bare
  # subtype:success — assert the ECHOED mode (D12 vacuous-green: the alt wire key
  # no-ops silently, returning an empty echo). A confirmed echo clears the revert
  # marker; an empty/mismatched echo reverts the optimistic selector + persisted
  # mode and says so honestly, so the UI never claims a switch that didn't land.
  def handle_info({:claude_chat_control, :set_mode, response}, socket) do
    echoed = if is_map(response), do: response["mode"], else: nil

    if echoed == socket.assigns.mode do
      {:noreply, assign(socket, mode_switch_from: nil)}
    else
      revert_to = socket.assigns[:mode_switch_from] || socket.assigns.mode
      persist_mode(socket, revert_to)

      {:noreply,
       socket
       |> assign(mode: revert_to, mode_switch_from: nil)
       |> append_message(
         :system,
         "Couldn't switch permission mode — still #{mode_label(revert_to)}."
       )}
    end
  end

  # Interrupt / set_model acks need no UI action: the interrupt's real outcome
  # arrives as the terminal `result` frame, and set_model has no surface. Swallow
  # them so they never fall to the noisy catch-all.
  def handle_info({:claude_chat_control, _kind, _response}, socket), do: {:noreply, socket}

  def handle_info({:claude_chat_permission, ask}, socket) do
    id = socket.assigns.next_id

    message = %{
      id: id,
      role: :approval,
      text: ask.title || tool_line(ask.tool_name, ask.input),
      html: nil,
      request_id: ask.request_id,
      tool_name: ask.tool_name,
      approval_status: :pending
    }

    {:noreply,
     assign(socket,
       messages: socket.assigns.messages ++ [message],
       next_id: id + 1
     )}
  end

  def handle_info({:claude_chat_event, _event}, socket), do: {:noreply, socket}

  # A real port exit (exit_status frame). Run the shared honest teardown.
  def handle_info({:claude_chat_exit, status}, socket) do
    {:noreply,
     teardown_session(
       socket,
       "Claude session ended (exit #{status}). Send a message to resume it."
     )}
  end

  # The interrupt timed out (charter D18). CRITICAL: `ClaudeChat.close/1` does
  # NOT emit {:claude_chat_exit} (only a real port exit_status does), so this
  # path must force-close AND run teardown itself. Guarded: a `result` arriving
  # first left `:interrupting`, and a session switch changed `store_session_id`
  # — both make a stale timer a no-op.
  def handle_info({:interrupt_timeout, sid}, socket) do
    if socket.assigns.status == :interrupting and socket.assigns[:store_session_id] == sid do
      if pid = socket.assigns[:session], do: ClaudeChat.close(pid)

      {:noreply,
       teardown_session(
         socket,
         "Stopping timed out — the session was force-closed. Send a message to resume it."
       )}
    else
      {:noreply, socket}
    end
  end

  # Another tab took this session over (charter D20 single-writer). The session
  # process now drives that tab; ours must stop pretending to own it. Drop the
  # live pid, freeze the composer behind an honest banner, and let "Take over
  # here" re-acquire it. Idempotent — a second detach (ownership ping-pong) is a
  # no-op so the system line never stacks.
  def handle_info({:claude_chat_detached}, socket) do
    if socket.assigns[:detached] do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(
         detached: true,
         session: nil,
         status: :detached,
         streaming: nil,
         interrupt_requested: false
       )
       |> append_message(
         :system,
         "This chat is now active in another tab. Use “Take over here” to continue."
       )}
    end
  end

  # A bare process DOWN with no prior exit frame (an unexpected Session crash, or
  # the DOWN that follows our own force-close). Only act while WE still own that
  # pid — after a teardown set `session: nil`, the double-fire DOWN finds no
  # match and no-ops; teardown itself is idempotent besides.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    if socket.assigns.session == pid do
      {:noreply,
       teardown_session(socket, "Claude session ended unexpectedly. Send a message to resume it.")}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if session = socket.assigns[:session], do: ClaudeChat.close(session)
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="flex: 1; display: flex; flex-direction: row; min-height: 0; background: var(--bg);">
      <style>
        @keyframes bp-skel-pulse { 0%, 100% { opacity: 0.22; } 50% { opacity: 0.55; } }
        /* Primary (evergreen) fill, NOT --border-muted: the dark theme's border
           tone is an 11%-lightness gray on a dark bg — the shapes rendered
           invisible. Primary reads in both schemes; the pulse keeps it a ghost. */
        .bp-chat-skel .bp-skel-shape {
          background: var(--primary);
          border-radius: 4px;
          animation: bp-skel-pulse 1.2s ease-in-out infinite;
        }
        .bp-chat-skel .bp-skel-dot {
          width: 7px; height: 7px; border-radius: 50%;
          background: var(--primary);
          animation: bp-skel-pulse 1.2s ease-in-out infinite;
        }
        .bp-chat-session-row { position: relative; border-radius: 8px; }
        /* !important beats the inline `background` the active/inactive row style
           sets, so an inactive row still lights on hover. */
        .bp-chat-session-row:hover { background: hsl(var(--primary-hsl) / 0.08) !important; }
        .bp-chat-session-link { display: block; text-decoration: none; }
        /* Kebab: a quiet affordance — revealed on row hover, keyboard focus, or
           while its own menu is open, so a resting sidebar stays calm. */
        .bp-chat-kebab {
          position: absolute; top: 6px; right: 6px;
          width: 22px; height: 22px; line-height: 1; font-size: 15px;
          display: inline-flex; align-items: center; justify-content: center;
          background: transparent; border: none; border-radius: 6px; cursor: pointer;
          opacity: 0; transition: opacity 0.12s ease;
        }
        .bp-chat-session-row:hover .bp-chat-kebab,
        .bp-chat-kebab:focus,
        .bp-chat-kebab[aria-expanded="true"] { opacity: 1; }
        .bp-chat-kebab:hover { background: hsl(var(--primary-hsl) / 0.14); }
        .bp-chat-menu {
          position: absolute; top: 30px; right: 6px; z-index: 20;
          min-width: 132px; padding: 4px;
          display: flex; flex-direction: column; gap: 1px;
          background: var(--bg); border: 1px solid var(--border-muted);
          border-radius: 8px; box-shadow: 0 6px 20px rgba(0, 0, 0, 0.18);
        }
        .bp-chat-menuitem {
          text-align: left; padding: 6px 9px; font-size: 0.8125rem;
          background: transparent; color: var(--text); border: none;
          border-radius: 5px; cursor: pointer;
        }
        .bp-chat-menuitem:hover { background: hsl(var(--primary-hsl) / 0.12); }
        .bp-chat-menuitem-danger { color: var(--danger); }
        .bp-chat-menuitem-danger:hover { background: hsl(var(--danger-hsl) / 0.12); }
        .bp-chat-rename-input {
          width: 100%; box-sizing: border-box; font: inherit;
          background: var(--bg); color: var(--text);
          border: 1px solid var(--primary); border-radius: 6px; padding: 6px 8px;
        }
      </style>
      <aside style="width: 280px; flex: none; border-right: 1px solid var(--border-muted); display: flex; flex-direction: column; min-height: 0;">
        <div style="display: flex; align-items: center; gap: 8px; padding: 8px 12px; border-bottom: 1px solid var(--border-muted); flex: none;">
          <span class="h3" style="display: flex; align-items: center; gap: 8px; flex: 1;">
            <.icon name="message-circle" size={15} /> chats
          </span>
          <.link
            patch="/studio/chat"
            class="btn btn-primary text-xs"
            style="display: inline-flex; align-items: center; gap: 4px; padding: 3px 9px;"
          >
            <.icon name="plus" size={13} /> New
          </.link>
        </div>

        <div style="flex: 1; min-height: 0; overflow-y: auto; padding: 6px;">
          <div
            :if={@sessions == [] and @show_archived}
            class="text-xs text-dim"
            style="padding: 14px 10px; line-height: 1.55;"
            data-test-id="chat-archived-empty"
          >
            <div class="text-sm" style="font-weight: 600; color: var(--text); margin-bottom: 6px;">
              No archived chats
            </div>
            <p style="margin: 0;">
              Archived chats rest here. Archive one from its <span aria-hidden="true">⋯</span>
              menu to tuck it away without deleting it — it stays fully resumable.
            </p>
          </div>

          <div
            :if={@sessions == [] and not @show_archived}
            class="text-xs text-dim"
            style="padding: 14px 10px; line-height: 1.55;"
            data-test-id="chat-empty"
          >
            <div class="text-sm" style="font-weight: 600; color: var(--text); margin-bottom: 6px;">
              No chats yet
            </div>
            <p style="margin: 0 0 8px;">
              This is your remembered agent workspace. Every conversation with
              <code>claude</code> on this host is saved here — reopen one to pick up
              exactly where you left off. Admins only.
            </p>
            <p style="margin: 0;">
              Try: <em>“Walk the studio LiveViews and sketch how a request flows.”</em>
            </p>
          </div>

          <nav :if={@sessions != []} style="display: flex; flex-direction: column; gap: 2px;">
            <% active_id = @session_id %>
            <div
              :for={s <- @sessions}
              class="bp-chat-session-row"
              style={session_row_style(s.id == active_id)}
              data-test-id="chat-session-row"
            >
              <%= if @renaming_session == s.id do %>
                <%!-- Inline rename (sheet-tab triad) — blur COMMITS (divergence);
                      Enter submits, Escape cancels. The commit path accepts both
                      the form's `title` and blur's `value`. --%>
                <form phx-submit="session-rename" phx-value-id={s.id} style="display: block;">
                  <input
                    name="title"
                    type="text"
                    value={s.title}
                    class="bp-chat-rename-input"
                    autocomplete="off"
                    autofocus
                    aria-label={"Rename #{s.title}"}
                    phx-blur="session-rename"
                    phx-value-id={s.id}
                    phx-keydown="session-rename-cancel"
                    phx-key="Escape"
                    data-test-id={"chat-session-rename-input-#{s.id}"}
                  />
                </form>
              <% else %>
                <.link patch={"/studio/chat/#{s.id}"} class="bp-chat-session-link">
                  <% {pill_class, pill_text} = session_pill(s.status) %>
                  <div style="display: flex; align-items: center; gap: 6px; padding-right: 22px;">
                    <span class={"badge #{pill_class}"} style="height: 18px; padding: 0 7px; font-size: 10px;">
                      <%= pill_text %>
                    </span>
                    <span class="text-xs text-dim" style="margin-left: auto;">
                      <%= session_stamp(s) %>
                    </span>
                  </div>
                  <div
                    class="text-sm"
                    style="font-weight: 600; color: var(--text); margin-top: 3px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"
                  >
                    <%= s.title %>
                  </div>
                  <div
                    :if={s.summary}
                    class="text-xs text-dim"
                    style="margin-top: 1px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"
                  >
                    <%= s.summary %>
                  </div>
                </.link>

                <button
                  type="button"
                  class="bp-chat-kebab text-dim"
                  phx-click="session-menu-toggle"
                  phx-value-id={s.id}
                  aria-haspopup="menu"
                  aria-expanded={to_string(@open_menu_session == s.id)}
                  aria-label={"Actions for #{s.title}"}
                  data-test-id={"chat-session-menu-#{s.id}"}
                >
                  ⋯
                </button>

                <div
                  :if={@open_menu_session == s.id}
                  class="bp-chat-menu"
                  role="menu"
                  aria-label={"Actions for #{s.title}"}
                  phx-click-away="session-menu-close"
                  data-test-id={"chat-session-menu-list-#{s.id}"}
                >
                  <button
                    type="button"
                    role="menuitem"
                    class="bp-chat-menuitem"
                    phx-click="session-rename-start"
                    phx-value-id={s.id}
                    data-test-id={"chat-session-rename-#{s.id}"}
                  >
                    Rename
                  </button>
                  <button
                    :if={@show_archived}
                    type="button"
                    role="menuitem"
                    class="bp-chat-menuitem"
                    phx-click="session-unarchive"
                    phx-value-id={s.id}
                    data-test-id={"chat-session-unarchive-#{s.id}"}
                  >
                    Unarchive
                  </button>
                  <button
                    :if={not @show_archived}
                    type="button"
                    role="menuitem"
                    class="bp-chat-menuitem"
                    phx-click="session-archive"
                    phx-value-id={s.id}
                    data-test-id={"chat-session-archive-#{s.id}"}
                  >
                    Archive
                  </button>
                  <button
                    type="button"
                    role="menuitem"
                    class="bp-chat-menuitem bp-chat-menuitem-danger"
                    phx-click="session-delete"
                    phx-value-id={s.id}
                    data-test-id={"chat-session-delete-#{s.id}"}
                  >
                    Delete
                  </button>
                </div>
              <% end %>
            </div>
          </nav>
        </div>

        <div style="flex: none; border-top: 1px solid var(--border-muted); padding: 6px 10px;">
          <button
            type="button"
            class="text-xs text-dim"
            phx-click="toggle-archived"
            aria-pressed={to_string(@show_archived)}
            data-test-id="chat-archived-toggle"
            style="display: inline-flex; align-items: center; gap: 5px; background: transparent; border: none; cursor: pointer; padding: 4px 6px;"
          >
            <.icon name={if @show_archived, do: "arrow-left", else: "archive"} size={12} />
            <%= if @show_archived, do: "Back to active chats", else: "Show archived" %>
          </button>
        </div>
      </aside>

      <div style="flex: 1; display: flex; flex-direction: column; min-height: 0;">
      <div style="display: flex; align-items: center; gap: 10px; padding: 8px 16px; border-bottom: 1px solid var(--border-muted); flex: none;">
        <span class="h3" style="display: flex; align-items: center; gap: 8px;">
          <.icon name="message-circle" size={16} /> chat
        </span>
        <span :if={@init} class="text-xs text-dim" style="font-family: var(--font-mono);">
          <%= @init.model %>
        </span>
        <form phx-change="set-mode" style="display: inline-flex; align-items: center;">
          <select
            name="mode"
            class="text-xs"
            style="background: var(--bg); color: inherit; border: 1px solid var(--border-muted); border-radius: 6px; padding: 2px 6px;"
          >
            <option :for={m <- ClaudeChat.modes()} value={m} selected={m == @mode}>
              <%= mode_label(m) %>
            </option>
          </select>
        </form>
        <.context_ring ring={@ring} />
        <span class="text-xs text-dim" style="margin-left: auto;">
          <%= status_label(@status) %> — Claude on this host, admins only.
        </span>
      </div>

      <div
        id="chat-transcript"
        style="flex: 1; min-height: 0; overflow-y: auto; display: flex; flex-direction: column-reverse; padding: 16px;"
      >
        <div style="display: flex; flex-direction: column; gap: 10px; max-width: 860px; width: 100%; margin: 0 auto;">
          <p :if={@messages == [] and @streaming == nil} class="text-sm text-dim">
            An agent chat backed by this host's <code>claude</code> login. Plan mode: it can
            read this host's files, but cannot edit or execute anything.
          </p>

          <div
            id="chat-messages"
            phx-hook="PaperMermaid"
            style="display: flex; flex-direction: column; gap: 10px;"
          >
            <div :for={message <- @messages} data-role={message.role}>
            <%= case message.role do %>
              <% :user -> %>
                <div style="display: flex; justify-content: flex-end;">
                  <div class="text-sm" style="white-space: pre-wrap; overflow-wrap: anywhere; background: var(--bg-raised, rgba(127,127,127,0.08)); border: 1px solid var(--border-muted); border-radius: 10px; padding: 8px 12px; max-width: 85%;">
                    <%= message.text %>
                  </div>
                </div>
              <% :assistant -> %>
                <div
                  :if={message.html}
                  class="bp-paper-surface bp-chat-md"
                  style="overflow-wrap: anywhere; padding: 2px 0; font-size: 0.925rem;"
                >
                  {Phoenix.HTML.raw(message.html)}
                </div>
                <div
                  :if={message.html == nil}
                  class="text-sm"
                  style="white-space: pre-wrap; overflow-wrap: anywhere; padding: 2px 0;"
                >
                  <%= message.text %>
                </div>
              <% :tool -> %>
                <div class="text-xs text-dim" style="font-family: var(--font-mono); overflow-wrap: anywhere;">
                  ⚒ <%= message.text %>
                </div>
              <% :approval -> %>
                <div
                  :if={message.approval_status == :pending}
                  data-approval={message.request_id}
                  style="border: 1px solid var(--border-muted); border-left: 3px solid var(--primary); border-radius: 8px; padding: 10px 12px; display: flex; align-items: center; gap: 12px;"
                >
                  <div style="flex: 1; min-width: 0;">
                    <div class="text-sm" style="font-weight: 600;">
                      Allow <%= message.tool_name %>?
                    </div>
                    <div class="text-xs text-dim" style="font-family: var(--font-mono); overflow-wrap: anywhere;">
                      <%= message.text %>
                    </div>
                  </div>
                  <button
                    type="button"
                    class="btn btn-primary"
                    phx-click="approve"
                    phx-value-rid={message.request_id}
                  >
                    Allow
                  </button>
                  <button
                    type="button"
                    class="btn"
                    phx-click="deny"
                    phx-value-rid={message.request_id}
                  >
                    Deny
                  </button>
                </div>
                <div
                  :if={message.approval_status != :pending}
                  class="text-xs text-dim"
                  style="font-family: var(--font-mono); overflow-wrap: anywhere;"
                >
                  <%= approval_outcome_label(message.approval_status) %> — <%= message.tool_name %>
                </div>
              <% _ -> %>
                <div class="text-xs text-dim" style="font-style: italic;">
                  <%= message.text %>
                </div>
            <% end %>
            </div>
          </div>

          <div :if={@streaming} style="opacity: 0.92;">
            <div
              :if={@streaming.stable_html}
              class="bp-paper-surface bp-chat-md"
              style="overflow-wrap: anywhere; padding: 2px 0; font-size: 0.925rem;"
            >
              {Phoenix.HTML.raw(@streaming.stable_html)}
            </div>
            <%= case classify_tail(streaming_tail(@streaming)) do %>
              <% {:text, tail} -> %>
                <div class="text-sm" style="white-space: pre-wrap; overflow-wrap: anywhere; padding: 2px 0;">
                  <%= tail %><span class="text-dim">▌</span>
                </div>
              <% {:component, kind, prose} -> %>
                <div
                  :if={String.trim(prose) != ""}
                  class="text-sm"
                  style="white-space: pre-wrap; overflow-wrap: anywhere; padding: 2px 0;"
                >
                  <%= prose %>
                </div>
                <.skeleton kind={kind} />
            <% end %>
          </div>

          <div :if={@streaming == nil and @status == :thinking} class="text-xs text-dim" style="font-style: italic;">
            thinking…
          </div>
        </div>
      </div>

      <div style="flex: none; border-top: 1px solid var(--border-muted); padding: 10px 16px;">
        <%!-- Single-writer honesty (charter D20): another tab holds this
              session's process. Freeze the composer behind a banner rather than
              spawn a second writer; "Take over here" re-acquires it. --%>
        <div
          :if={@detached}
          style="display: flex; align-items: center; gap: 12px; max-width: 860px; margin: 0 auto; padding: 10px 12px; border: 1px solid var(--border-muted); border-left: 3px solid var(--warn); border-radius: 8px;"
        >
          <div style="flex: 1; min-width: 0;">
            <div class="text-sm" style="font-weight: 600;">This chat is open in another tab</div>
            <div class="text-xs text-dim">
              Only one tab drives a session at a time, so its history never tears. Take over to continue here.
            </div>
          </div>
          <button type="button" class="btn btn-primary" phx-click="take_over">
            Take over here
          </button>
        </div>
        <form
          :if={not @detached}
          phx-submit="send"
          style="display: flex; gap: 8px; max-width: 860px; margin: 0 auto;"
        >
          <input
            id={"chat-composer-#{@composer_rev}"}
            type="text"
            name="message"
            autocomplete="off"
            placeholder={composer_placeholder(@status)}
            style="flex: 1; background: var(--bg); color: inherit; border: 1px solid var(--border-muted); border-radius: 8px; padding: 8px 12px; font: inherit;"
          />
          <%!-- While a turn runs, Stop replaces Send — the ONLY safe control is
                to cancel, never to queue a second turn (t3: no send queue). --%>
          <button
            :if={turn_active?(@status)}
            type="button"
            class="btn"
            phx-click="stop_turn"
            disabled={@status == :interrupting}
            aria-label="Stop the current turn"
            style="display: inline-flex; align-items: center; gap: 6px;"
          >
            <span style="display: inline-block; width: 10px; height: 10px; background: currentColor; border-radius: 2px;"></span>
            <%= if @status == :interrupting, do: "Stopping…", else: "Stop" %>
          </button>
          <button :if={not turn_active?(@status)} type="submit" class="btn btn-primary">
            <.icon name="send" size={14} />
          </button>
        </form>
        <p :if={@last_result && @last_result.cost_usd} class="text-xs text-dim" style="max-width: 860px; margin: 6px auto 0;">
          last turn: <%= format_duration(@last_result.duration_ms) %> · $<%= :erlang.float_to_binary(@last_result.cost_usd / 1, decimals: 4) %>
        </p>
      </div>
      </div>
    </div>
    """
  end

  # A dedicated shimmering placeholder per forming component — the reader sees
  # WHAT is coming (a chart, a diagram, a table…) instead of raw source noise.
  # Pure CSS (the pulse keyframes ride the transcript <style> in render/1).
  defp skeleton(assigns) do
    ~H"""
    <div
      class="bp-chat-skel"
      data-skel={@kind}
      style="border: 1px dashed hsl(var(--primary-hsl) / 0.45); border-radius: 8px; padding: 10px 12px; margin: 6px 0;"
    >
      <div
        class="text-xs text-dim"
        style="font-family: var(--font-mono); margin-bottom: 8px; display: flex; align-items: center; gap: 6px;"
      >
        <span class="bp-skel-dot"></span> rendering <%= skeleton_label(@kind) %>…
      </div>
      <%= case @kind do %>
        <% "chart" -> %>
          <div style="display: flex; align-items: flex-end; gap: 6px; height: 64px;">
            <div :for={h <- [40, 62, 30, 52, 44, 58]} class="bp-skel-shape" style={"width: 22px; height: #{h}px;"}></div>
          </div>
        <% "stats" -> %>
          <div style="display: flex; gap: 8px;">
            <div :for={_i <- 1..3} class="bp-skel-shape" style="flex: 1; height: 52px;"></div>
          </div>
        <% "table" -> %>
          <div style="display: flex; flex-direction: column; gap: 5px;">
            <div :for={_r <- 1..3} style="display: flex; gap: 5px;">
              <div :for={_c <- 1..3} class="bp-skel-shape" style="flex: 1; height: 14px;"></div>
            </div>
          </div>
        <% "diagram" -> %>
          <div style="display: flex; align-items: center; gap: 10px; height: 56px;">
            <div class="bp-skel-shape" style="width: 88px; height: 34px;"></div>
            <div class="bp-skel-shape" style="flex: 1; height: 2px;"></div>
            <div class="bp-skel-shape" style="width: 88px; height: 34px;"></div>
          </div>
        <% "callout" -> %>
          <div style="display: flex; gap: 8px;">
            <div class="bp-skel-shape" style="width: 3px; align-self: stretch;"></div>
            <div style="flex: 1; display: flex; flex-direction: column; gap: 6px;">
              <div class="bp-skel-shape" style="height: 12px; width: 40%;"></div>
              <div class="bp-skel-shape" style="height: 12px; width: 85%;"></div>
            </div>
          </div>
        <% _ -> %>
          <div style="display: flex; flex-direction: column; gap: 6px;">
            <div :for={w <- [70, 90, 55]} class="bp-skel-shape" style={"height: 12px; width: #{w}%;"}></div>
          </div>
      <% end %>
    </div>
    """
  end

  # ── session lifecycle (mount-lazy, handle_params-driven) ────────────────

  # Fire the AI title generation once per session, on the first successful turn,
  # while the title is still the default (the store makes a human rename
  # authoritative regardless). Fire-and-forget under Barkpark.TaskSupervisor —
  # a failure keeps the default title silently and never touches this LV.
  defp maybe_kick_title(socket) do
    cond do
      socket.assigns[:title_kicked] ->
        socket

      Map.get(socket.assigns, :title_source, "default") != "default" ->
        socket

      true ->
        with sid when is_binary(sid) <- socket.assigns[:store_session_id],
             first when is_binary(first) <- first_user_message(socket) do
          Barkpark.StudioChat.Titles.kick_title(sid, first, self())
          assign(socket, title_kicked: true)
        else
          _ -> socket
        end
    end
  end

  defp first_user_message(socket) do
    case Enum.find(socket.assigns.messages, &(&1.role == :user)) do
      %{text: text} -> text
      _ -> nil
    end
  end

  # Called on the first send with no live subprocess. Fresh chat: mint the
  # session uuid (D2), create the store row, spawn with `--session-id`, and
  # `push_patch` to the session's own URL so it becomes a place. Reopened chat:
  # a store row already exists (store_session_id set by replay) — spawn with
  # `--resume` to rehydrate the CLI's memory. Never eager-respawn; never scrape
  # ids off hook_* frames (D8).
  defp ensure_session(%{assigns: %{session: session}} = socket) when is_pid(session), do: socket

  defp ensure_session(socket) do
    {store_id, resume?, socket} =
      case socket.assigns.store_session_id do
        nil ->
          id = Ecto.UUID.generate()

          {:ok, _} =
            StudioChat.create_session(%{
              id: id,
              cwd: ClaudeChat.cwd(),
              mode: socket.assigns.mode
            })

          {id, false,
           socket
           |> assign(store_session_id: id, session_id: id, status: :working)
           |> push_patch(to: "/studio/chat/#{id}")}

        id ->
          {id, true, socket}
      end

    case ClaudeChat.start_session(%{
           sink: self(),
           mode: socket.assigns.mode,
           session_opts: %{session_id: store_id, resume: resume?}
         }) do
      {:ok, session} ->
        Process.monitor(session)
        StudioChat.update_status(store_id, "working")
        # Ready as soon as the subprocess is up. The CLI emits its init event
        # only when the FIRST turn starts — gating the composer on init would
        # deadlock the tab (nothing sent → no init → composer never enables).
        socket |> assign(session: session, status: :ready, detached: false) |> refresh_sessions()

      # Another tab already owns this session's process (charter D20). Adopt it
      # as the sole sink instead of spawning a second `claude --resume` writer —
      # the other tab gets the detached banner. Single writer, no torn transcript.
      {:error, {:already_started, other}} when is_pid(other) ->
        ClaudeChat.adopt_sink(other, self())
        Process.monitor(other)
        StudioChat.update_status(store_id, "working")
        socket |> assign(session: other, status: :ready, detached: false) |> refresh_sessions()

      {:error, reason} ->
        socket
        |> append_message(:system, spawn_error_text(reason))
        |> assign(session: nil, status: :offline)
    end
  end

  # Replay a remembered session INSTANTLY from our own store — no subprocess is
  # started (D8: reopen is display-only until the next send lazy-resumes). Any
  # subprocess from the previously-viewed session is torn down so we never leak.
  defp load_stored_session(socket, session) do
    if pid = socket.assigns[:session], do: ClaudeChat.close(pid)

    messages = replay_messages(session.id)

    assign(socket,
      session: nil,
      store_session_id: session.id,
      session_id: session.id,
      mode: session.mode || "plan",
      status: :resumable,
      init: replay_init(session),
      messages: messages,
      # Strictly past every replayed id (seqs are 1-based), so a live append
      # never collides with a replayed message's id.
      next_id: Enum.reduce(messages, 0, &max(&1.id, &2)) + 1,
      streaming: nil,
      interrupt_requested: false,
      mode_switch_from: nil,
      detached: false,
      last_result: nil,
      # Reopen must show the last-known headroom (charter D19) — read the snapshot
      # off the stored row; nil window renders hollow, never a fake arc.
      ring: ring_from_session(session),
      # Title state follows the STORED session: a titled (ai/human) session
      # never re-kicks; a still-default one may kick on its next good turn.
      title_source: session.title_source || "default",
      title_kicked: false,
      # Any half-open sidebar affordance is stale after a navigation.
      renaming_session: nil,
      open_menu_session: nil
    )
  end

  # The new-chat empty state: no store row, no subprocess. A previously-viewed
  # session's subprocess is closed (navigating away from a live turn tears it
  # down; the CLI keeps the memory for a later `--resume`).
  defp reset_to_new_chat(socket) do
    if pid = socket.assigns[:session], do: ClaudeChat.close(pid)

    assign(socket,
      session: nil,
      store_session_id: nil,
      session_id: nil,
      mode: "plan",
      status: :new,
      init: nil,
      messages: [],
      next_id: 0,
      streaming: nil,
      interrupt_requested: false,
      mode_switch_from: nil,
      detached: false,
      last_result: nil,
      ring: blank_ring(),
      title_source: "default",
      title_kicked: false,
      renaming_session: nil,
      open_menu_session: nil
    )
  end

  defp refresh_sessions(socket) do
    assign(socket,
      sessions: StudioChat.list_sessions(archived: socket.assigns[:show_archived] == true)
    )
  end

  # A row-level archive/delete. Always refresh the sidebar; when the mutated row
  # is the ON-SCREEN session, push_patch to /studio/chat so `handle_params/3`
  # (the single source of truth) re-resets to the clean new-chat state — a
  # background row leaves the open session untouched. The refreshed session list
  # survives the patch (reset_to_new_chat never re-lists), so the deleted row is
  # gone from the sidebar too.
  defp after_lifecycle_mutation(socket, id) do
    socket = socket |> assign(open_menu_session: nil) |> refresh_sessions()

    if socket.assigns.store_session_id == id do
      push_patch(socket, to: "/studio/chat")
    else
      socket
    end
  end

  # ONE idempotent honest teardown for a dead/wedged subprocess (charter D18),
  # shared by the port-exit handler, the interrupt-timeout guard, and the DOWN
  # handler. Fail the in-flight turn (drop the streaming buffer), force-cancel
  # EVERY pending approval — their control-response can never be delivered, so a
  # hanging Allow/Deny would be a dead button — mark the persisted session exited
  # (nil-safe), and go offline. The CLI keeps the memory: the next send
  # lazy-resumes. Idempotent: already `:offline` ⇒ no-op, so a close-then-DOWN
  # double-fire never duplicates the system line or re-cancels approvals.
  defp teardown_session(socket, message) do
    if socket.assigns.status == :offline do
      socket
    else
      messages =
        Enum.map(socket.assigns.messages, fn
          %{role: :approval, approval_status: :pending} = m -> %{m | approval_status: :canceled}
          m -> m
        end)

      mark_session_exited(socket.assigns[:store_session_id])

      socket
      |> assign(messages: messages)
      |> append_message(:system, message)
      |> assign(session: nil, status: :offline, streaming: nil, interrupt_requested: false)
      |> refresh_sessions()
    end
  end

  # Persist a mode switch onto the store row (charter D17) — no-op with no store
  # session yet (a brand-new chat before its first send has no row to write).
  defp persist_mode(socket, mode) do
    if store_id = socket.assigns[:store_session_id], do: StudioChat.set_mode(store_id, mode)
    :ok
  end

  defp interrupt_timeout_ms do
    Application.get_env(
      :barkpark,
      :studio_chat_interrupt_timeout_ms,
      @default_interrupt_timeout_ms
    )
  end

  # ── persistence (D7 — source markdown, on completion only) ──────────────

  # Persist the user's turn (D7). A store write can fail (e.g. a same-session
  # append race that outlived its retries) — we never discard that error: log it
  # and tell the user honestly that THIS message may not survive a reopen, so
  # the transcript never lies about what was remembered (charter D20b).
  defp persist_user_message(socket, text) do
    socket =
      case persist_store(socket, %{role: "user", source_markdown: text, metadata: %{}}) do
        {:error, reason} ->
          Logger.warning("studio chat: failed to persist user message: #{inspect(reason)}")

          append_message(
            socket,
            :system,
            "⚠ This message could not be saved — it may not appear if you reopen this chat."
          )

        _ ->
          socket
      end

    refresh_sessions(socket)
  end

  defp persist_assistant_blocks(socket, blocks) do
    Enum.each(blocks, fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        if String.trim(text) != "",
          do:
            persist_store_logged(socket, %{role: "assistant", source_markdown: text}, "assistant")

      %{"type" => "tool_use", "name" => name} = block ->
        persist_store_logged(
          socket,
          %{
            role: "tool",
            source_markdown: tool_line(name, block["input"]),
            metadata: %{"tool" => name, "input" => block["input"]}
          },
          "tool"
        )

      _ ->
        :ok
    end)

    :ok
  end

  # Append to the store when a session row exists; `:no_store` when this chat is
  # still unsaved (a pre-first-send draft), otherwise the append result verbatim
  # so callers can react to `{:error, _}` (never silently drop it).
  defp persist_store(socket, attrs) do
    case socket.assigns.store_session_id do
      nil -> :no_store
      store_id -> StudioChat.append_message(store_id, attrs)
    end
  end

  defp persist_store_logged(socket, attrs, kind) do
    case persist_store(socket, attrs) do
      {:error, reason} ->
        Logger.warning("studio chat: failed to persist #{kind} message: #{inspect(reason)}")

      _ ->
        :ok
    end
  end

  # Record the turn's usage AND capture the per-turn context snapshot for the
  # header ring (charter D19). The lifetime totals stay summed; last_context_tokens
  # / context_window are SET from THIS frame (input + both cache reads + output,
  # and the answering model's contextWindow — never a hardcoded window map). The
  # returned session drives the ring assign so the header updates on every result.
  defp record_result(socket, ev) do
    if store_id = socket.assigns.store_session_id do
      result =
        StudioChat.record_result_metrics(store_id, %{
          input_tokens: get_in(ev, ["usage", "input_tokens"]),
          output_tokens: get_in(ev, ["usage", "output_tokens"]),
          cache_read_input_tokens: get_in(ev, ["usage", "cache_read_input_tokens"]),
          cache_creation_input_tokens: get_in(ev, ["usage", "cache_creation_input_tokens"]),
          total_cost_usd: ev["total_cost_usd"],
          model: result_model(ev),
          context_window: result_context_window(ev)
        })

      StudioChat.update_status(store_id, "active")

      case result do
        {:ok, session} -> assign(socket, ring: ring_from_session(session))
        _ -> socket
      end
    else
      socket
    end
  end

  defp result_model(%{"modelUsage" => usage}) when is_map(usage) do
    usage |> Map.keys() |> List.first()
  end

  defp result_model(_), do: nil

  # The context window for the answering model, read off the frame's modelUsage
  # (never a hardcoded model→window map — that goes stale silently). nil when the
  # frame doesn't carry it → the store keeps the last-known window, ring stays honest.
  defp result_context_window(%{"modelUsage" => usage} = ev) when is_map(usage) do
    case usage[result_model(ev)] do
      %{"contextWindow" => cw} when is_integer(cw) and cw > 0 -> cw
      _ -> nil
    end
  end

  defp result_context_window(_), do: nil

  # Rebuild the transcript message list from the persisted store. Assistant
  # markdown re-renders through the SAME paper engine used live, so the improving
  # renderer wins on every reopen (D7).
  defp replay_messages(session_id) do
    session_id
    |> StudioChat.list_messages()
    |> Enum.map(fn m ->
      role = replay_role(m.role)

      html =
        if role == :assistant and is_binary(m.source_markdown) and
             String.trim(m.source_markdown) != "",
           do: render_paper_html(m.source_markdown)

      %{id: m.seq, role: role, text: m.source_markdown, html: html}
    end)
  end

  # A stored role must never make a session unopenable: map the known roles and
  # degrade anything else (a future wave's vocabulary) to a system line.
  defp replay_role("user"), do: :user
  defp replay_role("assistant"), do: :assistant
  defp replay_role("tool"), do: :tool
  defp replay_role(_), do: :system

  defp replay_init(%{model: model}) when is_binary(model),
    do: %{model: model, session_id: nil, permission_mode: nil}

  defp replay_init(_), do: nil

  defp append_message(socket, role, text, opts \\ []) do
    id = socket.assigns.next_id
    message = %{id: id, role: role, text: text, html: Keyword.get(opts, :html)}

    assign(socket,
      messages: socket.assigns.messages ++ [message],
      next_id: id + 1
    )
  end

  defp resolve_permission(socket, request_id, decision) do
    pending? =
      Enum.any?(
        socket.assigns.messages,
        &(&1.role == :approval and &1[:request_id] == request_id and
            &1.approval_status == :pending)
      )

    if pending? and socket.assigns.session do
      ClaudeChat.respond_permission(socket.assigns.session, request_id, decision)

      status = if decision == :allow, do: :allowed, else: :denied

      messages =
        Enum.map(socket.assigns.messages, fn
          %{role: :approval, request_id: ^request_id} = m -> %{m | approval_status: status}
          m -> m
        end)

      assign(socket, messages: messages)
    else
      socket
    end
  end

  # ── progressive streaming render ────────────────────────────────────────
  # Blocks render the moment they complete, not when the whole message ends:
  # the accumulated stream is split at the last block boundary ("\n\n") whose
  # prefix has BALANCED code fences (never split inside a streaming ```mermaid
  # or ```portabledoc fence — a half fence would render as a broken block).
  # The stable prefix renders through the paper engine once per boundary
  # advance; only the still-forming tail re-renders as plain text per delta.

  defp advance_streaming(nil, delta),
    do: advance_streaming(%{text: "", stable_html: nil, stable_len: 0}, delta)

  defp advance_streaming(state, delta) do
    text = state.text <> delta
    state = %{state | text: text}
    boundary = stable_boundary(text)

    if boundary > state.stable_len do
      prefix = binary_part(text, 0, boundary)
      %{state | stable_len: boundary, stable_html: render_paper_html(prefix)}
    else
      state
    end
  end

  defp streaming_tail(%{text: text, stable_len: stable_len}) do
    binary_part(text, stable_len, byte_size(text) - stable_len)
  end

  # ── forming-component classification (streaming skeletons) ──────────────
  # The tail after the last balanced-fence boundary is a SINGLE forming block
  # (a "\n\n" with balanced fences would have advanced the boundary), so a
  # cheap look at how it starts tells us what component is being built. The
  # raw source of a forming component reads as noise — render a dedicated
  # skeleton in the component's shape instead; prose keeps streaming as text.
  #
  # Returns `{:text, tail}` or `{:component, kind, prose_before_component}`.
  defp classify_tail(tail) do
    fence_count = length(:binary.matches(tail, "```"))

    cond do
      rem(fence_count, 2) == 1 ->
        {pos, _} = List.last(:binary.matches(tail, "```"))
        prose = binary_part(tail, 0, pos)
        fence = binary_part(tail, pos, byte_size(tail) - pos)
        {:component, fence_kind(fence), prose}

      forming_table?(tail) ->
        {:component, "table", ""}

      String.starts_with?(String.trim_leading(tail), ">") ->
        {:component, "callout", ""}

      true ->
        {:text, tail}
    end
  end

  defp fence_kind("```" <> rest) do
    case rest |> String.split("\n", parts: 2) |> hd() |> String.trim() do
      "mermaid" -> "diagram"
      "portabledoc" -> portabledoc_kind(rest)
      _ -> "code"
    end
  end

  defp fence_kind(_), do: "code"

  # Sniff the first "type" in the (partial) JSON to pick the skeleton shape.
  defp portabledoc_kind(fence_rest) do
    case Regex.run(~r/"type"\s*:\s*"([\w-]+)"/, fence_rest) do
      [_, "chart"] -> "chart"
      [_, "heatmap"] -> "chart"
      [_, t] when t in ["stat", "stats"] -> "stats"
      [_, "table"] -> "table"
      [_, "callout"] -> "callout"
      [_, "divider"] -> "code"
      [_, _other] -> "block"
      _ -> "block"
    end
  end

  defp forming_table?(tail) do
    tail |> String.trim_leading() |> String.starts_with?("|")
  end

  defp skeleton_label("diagram"), do: "diagram"
  defp skeleton_label("chart"), do: "chart"
  defp skeleton_label("stats"), do: "stats"
  defp skeleton_label("table"), do: "table"
  defp skeleton_label("callout"), do: "callout"
  defp skeleton_label("code"), do: "code"
  defp skeleton_label(_), do: "block"

  defp stable_boundary(text) do
    case :binary.matches(text, "\n\n") do
      [] ->
        0

      matches ->
        matches
        |> Enum.reverse()
        |> Enum.find_value(0, fn {pos, len} ->
          boundary = pos + len
          if balanced_fences?(binary_part(text, 0, boundary)), do: boundary, else: nil
        end)
    end
  end

  defp balanced_fences?(prefix) do
    rem(length(:binary.matches(prefix, "```")), 2) == 0
  end

  # Assistant markdown -> PortableDoc blocks -> the SAME article renderer the
  # paper reader uses. The renderer escapes all text at walk time, so the
  # fragment is safe to embed with raw/1. Fail-soft: any crash means the
  # message falls back to its plain-text form (html: nil).
  defp render_paper_html(markdown) do
    markdown
    |> FromMarkdown.blocks()
    |> Render.render_blocks(%{style: :article})
  rescue
    _ -> nil
  end

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

  defp mode_label("plan"), do: "plan (read-only)"
  defp mode_label("default"), do: "ask to act"
  defp mode_label("acceptEdits"), do: "auto-accept edits"
  defp mode_label(other), do: other

  defp status_label(:new), do: "new chat"
  defp status_label(:resumable), do: "resumable"
  defp status_label(:starting), do: "starting"
  defp status_label(:ready), do: "ready"
  defp status_label(:working), do: "working"
  defp status_label(:thinking), do: "working"
  defp status_label(:interrupting), do: "stopping…"
  defp status_label(:offline), do: "offline"
  defp status_label(:detached), do: "open in another tab"

  # A turn is in flight while the model works or while we're aborting it — both
  # states show Stop, never Send (there is no queue; the only in-turn control
  # is to cancel).
  defp turn_active?(status), do: status in [:thinking, :interrupting]

  defp approval_outcome_label(:allowed), do: "✓ allowed"
  defp approval_outcome_label(:canceled), do: "✗ canceled"
  defp approval_outcome_label(_), do: "✗ denied"

  defp mark_session_exited(nil), do: :ok
  defp mark_session_exited(id), do: StudioChat.mark_exited(id)

  defp composer_placeholder(:new), do: "Message Claude to begin…"
  defp composer_placeholder(:resumable), do: "Message Claude to resume this chat…"
  defp composer_placeholder(:offline), do: "Send a message to resume this session…"
  defp composer_placeholder(:thinking), do: "Claude is working — press Stop to interrupt…"
  defp composer_placeholder(:interrupting), do: "Stopping…"
  defp composer_placeholder(_), do: "Message Claude…"

  # ── sidebar helpers ─────────────────────────────────────────────────────

  # Store status → tokenized pill. Priority read is Working > idle(active) >
  # offline(exited); PendingApproval elevation is live-only (approval state is
  # per-mount, not persisted this wave) and is an S4 follow-up.
  defp session_pill("working"), do: {"badge-chat-working", "working"}
  defp session_pill("exited"), do: {"badge-chat-offline", "offline"}
  defp session_pill(_), do: {"badge-chat-idle", "idle"}

  # The active row wears the evergreen accent; the rest are transparent (hover
  # tint lives in the render <style>). All colours are emitted tokens.
  defp session_row_style(true),
    do:
      "padding: 8px 9px; border-radius: 8px; text-decoration: none; border: 1px solid hsl(var(--primary-hsl) / 0.35); background: var(--primary-soft);"

  defp session_row_style(false),
    do:
      "padding: 8px 9px; border-radius: 8px; text-decoration: none; border: 1px solid transparent; background: transparent;"

  # Coarse relative age off `last_active_at` (fallback `inserted_at`). Copied
  # from board_live.ex age_label/age_words — no shared module exists.
  defp age_label(%DateTime{} = dt), do: age_words(DateTime.diff(DateTime.utc_now(), dt))

  defp age_label(%NaiveDateTime{} = dt),
    do: age_words(NaiveDateTime.diff(NaiveDateTime.utc_now(), dt))

  defp age_label(_), do: nil

  defp age_words(s) when s < 60, do: "now"
  defp age_words(s) when s < 3_600, do: "#{div(s, 60)}m"
  defp age_words(s) when s < 86_400, do: "#{div(s, 3_600)}h"
  defp age_words(s) when s < 604_800, do: "#{div(s, 86_400)}d"
  defp age_words(s), do: "#{div(s, 604_800)}w"

  defp session_stamp(%{last_active_at: t}) when not is_nil(t), do: age_label(t)
  defp session_stamp(%{inserted_at: t}), do: age_label(t)
  defp session_stamp(_), do: nil

  # ── header context-headroom ring (charter D19) ──────────────────────────
  #
  # A from-scratch inline-SVG arc (no ring prior art in Studio). The arc length
  # IS last_context_tokens / context_window — geometry encodes the datum, colour
  # only reinforces it. Honest unknown: a nil window (pre-migration session, no
  # result yet) draws the track alone + an em-dash, NEVER a fake full/empty arc.

  # Circumference of the r=15.5 arc, evaluated at compile time. The progress
  # circle's stroke-dasharray is "<arc> <circ>" — arc = fraction × circ.
  @ring_circ 2 * :math.pi() * 15.5

  # A ring datum carried in assigns: the CURRENT-turn snapshot, not the summed
  # totals (which cannot express window occupancy). `cost` is the lifetime total.
  defp blank_ring, do: %{context_tokens: nil, context_window: nil, cost: 0.0}

  defp ring_from_session(session) do
    %{
      context_tokens: session.last_context_tokens,
      context_window: session.context_window,
      cost: session.total_cost_usd || 0.0
    }
  end

  # Known only when BOTH the used-tokens and a positive window are present.
  defp ring_geometry(%{context_tokens: used, context_window: window})
       when is_integer(used) and used >= 0 and is_integer(window) and window > 0 do
    frac = min(used / window, 1.0)
    %{known: true, frac: frac, pct: round(frac * 100)}
  end

  defp ring_geometry(_), do: %{known: false, frac: 0.0, pct: nil}

  # Token ramp (charter D19): ok < 70% · warn 70–90% · danger ≥ 90%. All tokens.
  defp ring_color(frac) when frac >= 0.9, do: "var(--danger)"
  defp ring_color(frac) when frac >= 0.7, do: "var(--warn)"
  defp ring_color(_), do: "var(--ok)"

  defp ring_dash(frac) do
    arc = frac * @ring_circ
    "#{Float.round(arc, 2)} #{Float.round(@ring_circ, 2)}"
  end

  defp ring_title(%{context_tokens: used, context_window: window})
       when is_integer(used) and is_integer(window) and window > 0 do
    "Context: #{used} / #{window} tokens"
  end

  defp ring_title(_), do: "Context window unknown until the first result"

  defp format_cost(cost) when is_number(cost) and cost > 0 do
    "$" <> :erlang.float_to_binary(cost / 1, decimals: 4)
  end

  defp format_cost(_), do: "$0.0000"

  attr :ring, :map, required: true

  defp context_ring(assigns) do
    assigns = assign(assigns, :geo, ring_geometry(assigns.ring))

    ~H"""
    <div style="display: inline-flex; align-items: center; gap: 8px;" title={ring_title(@ring)}>
      <div style="position: relative; display: inline-flex; align-items: center; justify-content: center;">
        <svg width="30" height="30" viewBox="0 0 36 36" style="display: block;" aria-hidden="true">
          <circle cx="18" cy="18" r="15.5" fill="none" stroke="var(--primary-soft)" stroke-width="3.5" />
          <circle
            :if={@geo.known}
            cx="18"
            cy="18"
            r="15.5"
            fill="none"
            stroke={ring_color(@geo.frac)}
            stroke-width="3.5"
            stroke-linecap="round"
            stroke-dasharray={ring_dash(@geo.frac)}
            transform="rotate(-90 18 18)"
          />
        </svg>
        <span
          class="text-dim"
          style="position: absolute; font-size: 9px; font-weight: 600; font-variant-numeric: tabular-nums;"
        >
          <%= if @geo.known, do: "#{@geo.pct}%", else: "—" %>
        </span>
      </div>
      <span
        class="text-xs text-dim"
        style="font-family: var(--font-mono); font-variant-numeric: tabular-nums;"
      >
        <%= format_cost(@ring.cost) %>
      </span>
    </div>
    """
  end

  defp format_duration(ms) when is_integer(ms) and ms >= 1000,
    do: "#{Float.round(ms / 1000, 1)}s"

  defp format_duration(ms) when is_integer(ms), do: "#{ms}ms"
  defp format_duration(_), do: "–"

  defp spawn_error_text(:disabled),
    do: "Claude chat is not enabled on this host."

  defp spawn_error_text(:binary_not_found),
    do:
      "The `claude` binary is not installed on this host. Install Claude Code and run `claude auth login`."

  defp spawn_error_text(_),
    do: "Failed to start the Claude session."

  defp default_dataset do
    case Barkpark.Content.list_datasets() do
      [ds | _] when is_binary(ds) -> ds
      _ -> "production"
    end
  rescue
    _ -> "production"
  end
end
