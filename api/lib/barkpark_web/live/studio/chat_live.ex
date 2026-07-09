defmodule BarkparkWeb.Studio.ChatLive do
  @moduledoc """
  Studio **Claude chat** at `/studio/chat` — admin-only agent chat backed by
  the host's Claude Code CLI (wave 1: pure chat, plan mode).

  The chat subprocess is owned by `BarkparkWeb.Studio.ClaudeChat.Session`,
  started lazily on the connected mount. Every decoded stream-json event
  arrives here as `{:claude_chat_event, map}`:

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

  alias Barkpark.PortableDoc.FromMarkdown
  alias Barkpark.PortableDoc.Render
  alias Barkpark.StudioChat
  alias BarkparkWeb.Studio.ClaudeChat

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
         mode: "plan",
         status: :new,
         init: nil,
         messages: [],
         next_id: 0,
         streaming: nil,
         composer_rev: 0,
         last_result: nil
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

    if text == "" do
      {:noreply, socket}
    else
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
           |> assign(status: :thinking, composer_rev: socket.assigns.composer_rev + 1)}
      end
    end
  end

  # Switching permission mode. With no live subprocess yet (the common case now
  # that mount is lazy), it is a plain selector update — the mode is applied when
  # the next send spawns. With a live subprocess, the CLI fixes its mode at
  # spawn, so we tear it down and re-resume on the next send under the new mode;
  # an honest system line says the in-process context reset. (Mid-session mode
  # via a control frame is S4's job — this preserves the current contract.)
  def handle_event("set-mode", %{"mode" => mode}, socket) do
    mode = ClaudeChat.normalize_mode(mode)

    cond do
      mode == socket.assigns.mode ->
        {:noreply, socket}

      session = socket.assigns.session ->
        ClaudeChat.close(session)

        {:noreply,
         socket
         |> assign(mode: mode, session: nil, streaming: nil)
         |> append_message(:system, "Permission mode → #{mode}. The session will resume under the new mode on your next message.")}

      true ->
        {:noreply, assign(socket, mode: mode)}
    end
  end

  def handle_event("approve", %{"rid" => request_id}, socket) do
    {:noreply, resolve_permission(socket, request_id, :allow)}
  end

  def handle_event("deny", %{"rid" => request_id}, socket) do
    {:noreply, resolve_permission(socket, request_id, {:deny, "The user declined this action."})}
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
    socket =
      case ev["subtype"] do
        "success" -> socket
        subtype -> append_message(socket, :system, "The turn ended with an error (#{subtype}).")
      end

    record_result(socket, ev)
    last_result = %{duration_ms: ev["duration_ms"], cost_usd: ev["total_cost_usd"]}

    {:noreply,
     socket
     |> assign(status: :ready, streaming: nil, last_result: last_result)
     |> refresh_sessions()}
  end

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

  def handle_info({:claude_chat_exit, status}, socket) do
    if store_id = socket.assigns.store_session_id, do: StudioChat.mark_exited(store_id)

    {:noreply,
     socket
     |> append_message(
       :system,
       "Claude session ended (exit #{status}). Send a message to resume it."
     )
     |> assign(session: nil, status: :offline, streaming: nil)
     |> refresh_sessions()}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    if socket.assigns.session == pid do
      {:noreply, assign(socket, session: nil, status: :offline, streaming: nil)}
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
        .bp-chat-session { display: block; }
        .bp-chat-session:hover { background: hsl(var(--primary-hsl) / 0.08) !important; }
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
            :if={@sessions == []}
            class="text-xs text-dim"
            style="padding: 14px 10px; line-height: 1.55;"
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
            <.link
              :for={s <- @sessions}
              patch={"/studio/chat/#{s.id}"}
              class="bp-chat-session"
              style={session_row_style(s.id == active_id)}
            >
              <% {pill_class, pill_text} = session_pill(s.status) %>
              <div style="display: flex; align-items: center; gap: 6px;">
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
          </nav>
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
                  <%= if message.approval_status == :allowed, do: "✓ allowed", else: "✗ denied" %> — <%= message.tool_name %>
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
        <form phx-submit="send" style="display: flex; gap: 8px; max-width: 860px; margin: 0 auto;">
          <input
            id={"chat-composer-#{@composer_rev}"}
            type="text"
            name="message"
            autocomplete="off"
            placeholder={composer_placeholder(@status)}
            style="flex: 1; background: var(--bg); color: inherit; border: 1px solid var(--border-muted); border-radius: 8px; padding: 8px 12px; font: inherit;"
          />
          <button type="submit" class="btn btn-primary">
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
           session_id: store_id,
           resume: resume?
         }) do
      {:ok, session} ->
        Process.monitor(session)
        StudioChat.update_status(store_id, :working)
        # Ready as soon as the subprocess is up. The CLI emits its init event
        # only when the FIRST turn starts — gating the composer on init would
        # deadlock the tab (nothing sent → no init → composer never enables).
        socket |> assign(session: session, status: :ready) |> refresh_sessions()

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
      next_id: length(messages),
      streaming: nil,
      last_result: nil
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
      last_result: nil
    )
  end

  defp refresh_sessions(socket), do: assign(socket, sessions: StudioChat.list_sessions())

  # ── persistence (D7 — source markdown, on completion only) ──────────────

  defp persist_user_message(socket, text) do
    if store_id = socket.assigns.store_session_id do
      StudioChat.append_message(store_id, %{role: "user", source_markdown: text, metadata: %{}})
    end

    refresh_sessions(socket)
  end

  defp persist_assistant_blocks(socket, blocks) do
    if store_id = socket.assigns.store_session_id do
      Enum.each(blocks, fn
        %{"type" => "text", "text" => text} when is_binary(text) ->
          if String.trim(text) != "",
            do: StudioChat.append_message(store_id, %{role: "assistant", source_markdown: text})

        %{"type" => "tool_use", "name" => name} = block ->
          StudioChat.append_message(store_id, %{
            role: "tool",
            source_markdown: tool_line(name, block["input"]),
            metadata: %{"tool" => name, "input" => block["input"]}
          })

        _ ->
          :ok
      end)
    end

    :ok
  end

  defp record_result(socket, ev) do
    if store_id = socket.assigns.store_session_id do
      StudioChat.record_result_metrics(store_id, %{
        input_tokens: get_in(ev, ["usage", "input_tokens"]),
        output_tokens: get_in(ev, ["usage", "output_tokens"]),
        total_cost_usd: ev["total_cost_usd"],
        model: result_model(ev)
      })

      StudioChat.update_status(store_id, :active)
    end

    :ok
  end

  defp result_model(%{"modelUsage" => usage}) when is_map(usage) do
    usage |> Map.keys() |> List.first()
  end

  defp result_model(_), do: nil

  # Rebuild the transcript message list from the persisted store. Assistant
  # markdown re-renders through the SAME paper engine used live, so the improving
  # renderer wins on every reopen (D7).
  defp replay_messages(session_id) do
    session_id
    |> StudioChat.list_messages()
    |> Enum.map(fn m ->
      role = String.to_existing_atom(m.role)

      html =
        if role == :assistant and String.trim(m.source_markdown) != "",
          do: render_paper_html(m.source_markdown)

      %{id: m.seq, role: role, text: m.source_markdown, html: html}
    end)
  end

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
  defp status_label(:offline), do: "offline"

  defp composer_placeholder(:new), do: "Message Claude to begin…"
  defp composer_placeholder(:resumable), do: "Message Claude to resume this chat…"
  defp composer_placeholder(:offline), do: "Send a message to resume this session…"
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
