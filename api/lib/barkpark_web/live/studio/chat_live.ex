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
  alias BarkparkWeb.Studio.ClaudeChat

  @impl true
  def mount(_params, _session, socket) do
    if ClaudeChat.enabled?() do
      socket =
        socket
        |> assign(
          page_title: "chat",
          nav_section: :chat,
          dataset: default_dataset(),
          current_path: "/studio/chat",
          session: nil,
          mode: "plan",
          status: :starting,
          init: nil,
          messages: [],
          next_id: 0,
          streaming: nil,
          composer_rev: 0,
          last_result: nil
        )

      {:ok, if(connected?(socket), do: start_session(socket), else: socket)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Claude chat is not enabled on this instance.")
       |> redirect(to: "/studio")}
    end
  end

  @impl true
  def handle_event("send", %{"message" => text}, socket) do
    text = String.trim(text)

    if text == "" do
      {:noreply, socket}
    else
      socket = if socket.assigns.session, do: socket, else: start_session(socket)

      case socket.assigns.session do
        nil ->
          {:noreply, socket}

        session ->
          ClaudeChat.send_message(session, text)

          {:noreply,
           socket
           |> append_message(:user, text)
           |> assign(status: :thinking, composer_rev: socket.assigns.composer_rev + 1)}
      end
    end
  end

  # Switching permission mode restarts the subprocess (the CLI fixes its mode
  # at spawn). The transcript survives in the LiveView; the model's context
  # does not — an honest system line says so.
  def handle_event("set-mode", %{"mode" => mode}, socket) do
    mode = ClaudeChat.normalize_mode(mode)

    if mode == socket.assigns.mode do
      {:noreply, socket}
    else
      if session = socket.assigns.session, do: ClaudeChat.close(session)

      {:noreply,
       socket
       |> assign(mode: mode, session: nil, streaming: nil)
       |> append_message(:system, "Permission mode → #{mode}. New session started.")
       |> start_session()}
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

    # The complete message supersedes the accumulated preview.
    {:noreply, assign(socket, streaming: nil)}
  end

  def handle_info({:claude_chat_event, %{"type" => "result"} = ev}, socket) do
    socket =
      case ev["subtype"] do
        "success" -> socket
        subtype -> append_message(socket, :system, "The turn ended with an error (#{subtype}).")
      end

    last_result = %{duration_ms: ev["duration_ms"], cost_usd: ev["total_cost_usd"]}
    {:noreply, assign(socket, status: :ready, streaming: nil, last_result: last_result)}
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
    {:noreply,
     socket
     |> append_message(
       :system,
       "Claude session ended (exit #{status}). Send a message to start a new one."
     )
     |> assign(session: nil, status: :offline, streaming: nil)}
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
    <div style="flex: 1; display: flex; flex-direction: column; min-height: 0; background: var(--bg);">
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
                  style="border: 1px solid var(--border-muted); border-left: 3px solid var(--accent, #2f6b4f); border-radius: 8px; padding: 10px 12px; display: flex; align-items: center; gap: 12px;"
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
            <div class="text-sm" style="white-space: pre-wrap; overflow-wrap: anywhere; padding: 2px 0;">
              <%= streaming_tail(@streaming) %><span class="text-dim">▌</span>
            </div>
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
    """
  end

  # ── internals ──────────────────────────────────────────────────────────

  defp start_session(socket) do
    case ClaudeChat.start_session(%{sink: self(), mode: socket.assigns.mode}) do
      {:ok, session} ->
        Process.monitor(session)
        # Ready as soon as the subprocess is up. The CLI emits its init event
        # only when the FIRST turn starts — gating the composer on init would
        # deadlock the tab (nothing sent → no init → composer never enables).
        assign(socket, session: session, status: :ready)

      {:error, reason} ->
        socket
        |> append_message(:system, spawn_error_text(reason))
        |> assign(session: nil, status: :offline)
    end
  end

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

  defp status_label(:starting), do: "starting"
  defp status_label(:ready), do: "ready"
  defp status_label(:thinking), do: "working"
  defp status_label(:offline), do: "offline"

  defp composer_placeholder(:offline), do: "Send a message to start a new session…"
  defp composer_placeholder(_), do: "Message Claude…"

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
