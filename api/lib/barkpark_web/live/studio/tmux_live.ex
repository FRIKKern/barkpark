defmodule BarkparkWeb.Studio.TmuxLive do
  @moduledoc """
  Studio **tmux console** at `/studio/tmux` — on by default on every Studio,
  admin-only.

  Renders an `xterm.js` terminal (the `TmuxTerminal` JS hook) wired over the
  LiveView channel to a real PTY running `tmux new-session -A -s
  barkpark-studio` on the host. Every keystroke rides `term-input`; every
  chunk of PTY output rides a `term-out` push_event — both base64-encoded so
  raw terminal bytes survive the JSON transport intact.

  Gating lives in `BarkparkWeb.Studio.TmuxConsole` — this mount redirects out
  unless `TmuxConsole.enabled?/0` (which hard-refuses public-demo hosts and
  honors the per-host opt-out), and the `:admin_studio` live_session carrying
  the route applies the admin `on_mount` gate. See that module's `@moduledoc`
  for the full contract.

  The PTY is spawned lazily on the hook's first `term-init` so it is created
  at the browser's real geometry. tmux persistence means a LiveView reconnect
  re-attaches to the same session with scrollback and running programs intact;
  `terminate/2` kills only the tmux *client*, never the session.
  """

  use BarkparkWeb, :live_view

  alias BarkparkWeb.Studio.ReturnTo
  alias BarkparkWeb.Studio.TmuxConsole

  @impl true
  def mount(params, _session, socket) do
    principal = socket.assigns[:api_token] || socket.assigns[:current_user]

    # A live shell on the INSTANCE HOST is the instance owner's alone
    # (task-6ca882967fd95dda): the platform operator when the allowlist is
    # armed, else an owner/admin of the Default workspace — not any Studio admin.
    if TmuxConsole.enabled?() and BarkparkWeb.HostExecutionGate.instance_principal?(principal) do
      {:ok,
       socket
       |> assign(
         page_title: "tmux",
         dataset: default_dataset(),
         # current_path is owned by StudioChrome's :handle_params hook.
         # Truthful return path (charter D5): a scoped surface links here with
         # `?return_to=<its canonical path>`; sanitized (open-redirect guard) so
         # a back affordance can land back in the SAME scope, not the `/studio`
         # session funnel. nil when arrived at flat/directly.
         return_to: ReturnTo.sanitize(params["return_to"]),
         session_name: TmuxConsole.session_name(),
         pty: nil,
         exited: false
       )}
    else
      {:ok,
       socket
       |> put_flash(
         :error,
         if(TmuxConsole.enabled?(),
           do: "The host terminal is reserved for the instance owner (the platform operator).",
           else: "The tmux console is not enabled on this instance."
         )
       )
       |> redirect(to: ReturnTo.sanitize(params["return_to"]) || "/studio")}
    end
  end

  @impl true
  # EVERY EVENT RE-CHECKS THE PRINCIPAL (owner ruling #30 Q13, 2026-10-03). The
  # mount gate ran once; a token revoked, expired or stripped of admin, or an
  # account removed from the Default workspace, kept a live host shell until the
  # socket reconnected. Each event now re-reads the principal from the database
  # and re-asks the mount's own rule; a principal that no longer passes is sent
  # back to /studio (the LiveView exits, and `terminate/2` kills the tmux
  # client).
  def handle_event(event, params, socket) do
    if host_principal_now?(socket) do
      handle_console_event(event, params, socket)
    else
      {:noreply,
       socket
       |> put_flash(:error, "Your access to the host terminal ended. Sign in again to continue.")
       |> redirect(to: "/studio")}
    end
  end

  defp host_principal_now?(socket) do
    TmuxConsole.enabled?() and
      BarkparkWeb.HostExecutionGate.instance_principal?(fresh_principal(socket.assigns))
  end

  # The mount-time struct, re-read: a token through the same WHERE clause
  # `Auth.verify_token/1` applies (api kind, not revoked, not expired); a user
  # by id. `nil` when it is gone — which `instance_principal?/1` refuses.
  defp fresh_principal(%{api_token: %Barkpark.Auth.ApiToken{id: id}}) when is_binary(id) do
    import Ecto.Query, only: [from: 2]
    now = DateTime.utc_now()

    Barkpark.Repo.one(
      from(t in Barkpark.Auth.ApiToken,
        where: t.id == ^id,
        where: t.kind == "api",
        where: is_nil(t.revoked_at),
        where: is_nil(t.expires_at) or t.expires_at > ^now
      )
    )
  end

  defp fresh_principal(%{current_user: %Barkpark.Accounts.User{id: id}}),
    do: Barkpark.Accounts.get_user(id)

  defp fresh_principal(_assigns), do: nil

  # First message from the hook: it has measured the viewport and reports the
  # initial geometry. Spawn the PTY exactly once, at that size.
  defp handle_console_event("term-init", %{"cols" => cols, "rows" => rows}, socket) do
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
  defp handle_console_event("term-input", %{"d" => d}, socket) do
    with pty when not is_nil(pty) <- socket.assigns.pty,
         {:ok, bytes} <- Base.decode64(d) do
      TmuxConsole.send_input(pty, bytes)
    end

    {:noreply, socket}
  end

  # Browser resize → PTY SIGWINCH so tmux repaints at the new geometry.
  defp handle_console_event("term-resize", %{"cols" => cols, "rows" => rows}, socket) do
    if pty = socket.assigns.pty do
      TmuxConsole.resize(pty, to_int(cols), to_int(rows))
    end

    {:noreply, socket}
  end

  # Stale/unknown client events (e.g. a hook firing mid-reconnect) must never
  # crash the console — mirror the other admin LVs' tolerant catch-all.
  defp handle_console_event(_event, _params, socket), do: {:noreply, socket}

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
          A live shell on this host — admins only.
        </span>
      </div>

      <div
        id="tmux-terminal"
        phx-hook="TmuxTerminal"
        phx-update="ignore"
        data-src="/assets/xterm.bundle.js?v=2"
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
