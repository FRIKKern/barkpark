defmodule BarkparkWeb.Studio.TmuxLive do
  @moduledoc """
  Dev-only Studio **tmux console** at `/studio/tmux`.

  Renders an `xterm.js` terminal (the `TmuxTerminal` JS hook) wired over the
  LiveView channel to a real PTY running `tmux new-session -A -s
  barkpark-studio` on the host. Every keystroke rides `term-input`; every
  chunk of PTY output rides a `term-out` push_event — both base64-encoded so
  raw terminal bytes survive the JSON transport intact.

  Gating lives in `BarkparkWeb.Studio.TmuxConsole` — this mount redirects out
  unless `TmuxConsole.enabled?/0` (dev-only dep + explicit config flag), and
  the `:admin_studio` live_session carrying the route already applies the
  admin `on_mount` gate. See that module's `@moduledoc` for the full
  fail-closed contract.

  The PTY is spawned lazily on the hook's first `term-init` so it is created
  at the browser's real geometry. tmux persistence means a LiveView reconnect
  re-attaches to the same session with scrollback and running programs intact;
  `terminate/2` kills only the tmux *client*, never the session.
  """

  use BarkparkWeb, :live_view

  alias BarkparkWeb.Studio.TmuxConsole

  @impl true
  def mount(_params, _session, socket) do
    if TmuxConsole.enabled?() do
      {:ok,
       socket
       |> assign(
         page_title: "tmux",
         nav_section: :tmux,
         dataset: default_dataset(),
         current_path: "/studio/tmux",
         session_name: TmuxConsole.session_name(),
         pty: nil,
         exited: false
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "The tmux console is not enabled on this instance.")
       |> redirect(to: "/studio")}
    end
  end

  @impl true
  # First message from the hook: it has measured the viewport and reports the
  # initial geometry. Spawn the PTY exactly once, at that size.
  def handle_event("term-init", %{"cols" => cols, "rows" => rows}, socket) do
    if socket.assigns.pty do
      {:noreply, socket}
    else
      case TmuxConsole.start_terminal(%{cols: to_int(cols), rows: to_int(rows), sink: self()}) do
        {:ok, pty} ->
          {:noreply, assign(socket, pty: pty, exited: false)}

        {:error, reason} ->
          {:noreply,
           socket
           |> push_event("term-out", %{d: encode(spawn_error_text(reason))})
           |> assign(exited: true)}
      end
    end
  end

  # User keystrokes → PTY stdin.
  def handle_event("term-input", %{"d" => d}, socket) do
    with pty when not is_nil(pty) <- socket.assigns.pty,
         {:ok, bytes} <- Base.decode64(d) do
      TmuxConsole.send_input(pty, bytes)
    end

    {:noreply, socket}
  end

  # Browser resize → PTY SIGWINCH so tmux repaints at the new geometry.
  def handle_event("term-resize", %{"cols" => cols, "rows" => rows}, socket) do
    if pty = socket.assigns.pty do
      TmuxConsole.resize(pty, to_int(cols), to_int(rows))
    end

    {:noreply, socket}
  end

  # Stale/unknown client events (e.g. a hook firing mid-reconnect) must never
  # crash the console — mirror the other admin LVs' tolerant catch-all.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  # PTY stdout → terminal. Base64 so raw bytes survive JSON.
  def handle_info({:pty_out, data}, socket) do
    {:noreply, push_event(socket, "term-out", %{d: encode(data)})}
  end

  # The tmux client process ended (session may still be alive elsewhere).
  def handle_info(:pty_exit, socket) do
    {:noreply,
     socket
     |> push_event("term-out", %{
       d: encode("\r\n\e[38;5;244m[tmux client detached — reload to re-attach]\e[0m\r\n")
     })
     |> assign(pty: nil, exited: true)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if pty = socket.assigns[:pty], do: TmuxConsole.close(pty)
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="flex: 1; display: flex; flex-direction: column; min-height: 0; background: var(--bg);">
      <div style="display: flex; align-items: center; gap: 10px; padding: 8px 16px; border-bottom: 1px solid var(--border-muted); flex: none;">
        <span class="h3" style="display: flex; align-items: center; gap: 8px;">
          <.icon name="terminal" size={16} /> tmux
        </span>
        <span class="text-xs text-dim" style="font-family: var(--font-mono);">
          session: <%= @session_name %>
        </span>
        <span class="text-xs text-dim" style="margin-left: auto;">
          A live shell on this host — admin + dev only.
        </span>
      </div>

      <div
        id="tmux-terminal"
        phx-hook="TmuxTerminal"
        phx-update="ignore"
        data-src="/assets/xterm.bundle.js"
        style="flex: 1; min-height: 0; padding: 6px 8px; background: #000; overflow: hidden;"
      >
      </div>
    </div>
    """
  end

  # ── internals ──────────────────────────────────────────────────────────

  defp encode(data) when is_binary(data), do: Base.encode64(data)
  defp encode(data), do: Base.encode64(IO.iodata_to_binary(data))

  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_float(n), do: trunc(n)

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp to_int(_), do: 0

  defp default_dataset do
    case Barkpark.Content.list_datasets() do
      [ds | _] when is_binary(ds) -> ds
      _ -> "production"
    end
  rescue
    _ -> "production"
  end

  defp spawn_error_text(:tmux_not_found),
    do: "\e[31mtmux is not installed on this host.\e[0m\r\n"

  defp spawn_error_text(:disabled),
    do: "\e[31mtmux console backend unavailable.\e[0m\r\n"

  defp spawn_error_text(_),
    do: "\e[31mFailed to start the tmux session.\e[0m\r\n"
end
