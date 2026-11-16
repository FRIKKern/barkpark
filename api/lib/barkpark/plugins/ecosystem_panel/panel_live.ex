defmodule Barkpark.Plugins.EcosystemPanel.PanelLive do
  @moduledoc """
  The ecosystem panel shell, `/w/:ws/p/:proj/studio/ecosystem-panel`
  (task-d599e49ba75bb30b, plan Paper `ecosystem-panel-behind-login` §5).

  Mounted by `Barkpark.Plugins.EcosystemPanel` on the default `:admin`
  bucket, so the scoped copy rides `live_session :scoped_plugin_admin`:
  `LiveAuth :scoped_admin` (owner or admin role in the URL workspace), then
  `:require_org_mfa`, then `PluginScopeSession :scope`, which puts the
  RESOLVED workspace in `:current_workspace`. Every read below is keyed by
  that id.

  ## What it shows

  One line drawn by the server from the stored `built_at`, above a sandboxed
  iframe of `EcosystemPanelFrameController`:

    * "Built 12 minutes ago" while the snapshot is 30 minutes old or less;
    * "Stale: built 47 minutes ago" past that, in the Studio warning tone;
    * "No snapshot yet", and no iframe, when the workspace has no row.

  The line sits outside the frame, so the stored page cannot hide or fake it.

  ## What moves it

    * A tick every minute (`Process.send_after/3`) recomputes the age.
    * A `{:ecosystem_panel_snapshot, %{sha256: sha}}` broadcast on
      `EcosystemPanel.topic/1` re-reads the stamp and swaps the iframe src to
      `.../frame?v=<sha>`. Only the sha rides PubSub; the shell never holds
      the HTML (it reads `EcosystemPanel.get_stamp/1`).

  ## Losing the page

  `LiveAuth` arms the revocation teardown at mount (a revoked token or
  signed-out session leaves for `/login`). Role changes are not broadcast, so
  every tick and every snapshot broadcast re-reads the membership role with
  `Tenancy.Auth.workspace_admin?/2` (a fresh query, the per-write re-gate
  `SettingsLive` and `ConnectorsLive` use), for the socket's token or user.
  A demoted admin gets the `:scoped_admin` denial: the flash and `/studio`.

  The flat `/studio/ecosystem-panel` copy redirects to `/studio` without
  reading anything, whatever its query string says. The page reads a
  workspace only when `LiveAuth :scoped_admin` admitted that same workspace
  (its `:scoped_admin_workspace_slug` assign equals `current_workspace.slug`).
  """
  use BarkparkWeb, :live_view

  alias Barkpark.EcosystemPanel
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @tick_ms 60_000
  @stale_after_minutes 30

  # Scoped or flat is decided by what the scoped live_session wrote, never by
  # params: LiveView merges the query string into them, so the flat route can
  # send `?workspace_slug=`. `:scoped_admin_workspace_slug` is set only by
  # `LiveAuth :scoped_admin` once it has proved an owner/admin role in that
  # workspace; it must name the same workspace this page reads.
  @impl true
  def mount(_params, _session, socket) do
    case admitted_workspace(socket.assigns) do
      %{id: workspace_id} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Barkpark.PubSub, EcosystemPanel.topic(workspace_id))
          schedule_tick()
        end

        {:ok,
         socket
         |> assign(page_title: gettext("Ecosystem panel"), workspace_id: workspace_id)
         |> assign(frame_path: frame_path(socket))
         |> load_stamp()
         |> assign_age()}

      # The flat mount, or a scope the admin gate did not admit. Nothing is read.
      nil ->
        {:ok, redirect(socket, to: "/studio")}
    end
  end

  @impl true
  def handle_info(:tick, socket) do
    while_admin(socket, fn socket ->
      schedule_tick()
      assign(socket, :now, DateTime.utc_now())
    end)
  end

  def handle_info({:ecosystem_panel_snapshot, %{sha256: _}}, socket) do
    while_admin(socket, &load_stamp/1)
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bp-eco" data-test-id="ecosystem-panel">
      <style>
        .bp-eco { display:flex; flex-direction:column; flex:1; min-height:0; font-family:var(--font); }
        .bp-eco-age { margin:0; padding:10px 24px; font-size:13px; color:var(--muted-text); border-bottom:1px solid var(--border-muted); }
        .bp-eco-age[data-stale="true"] { background:var(--warn-soft); color:var(--warn-text); font-weight:600; }
        .bp-eco-frame { flex:1; width:100%; min-height:70vh; border:0; background:var(--bg); }
        .bp-eco-empty { margin:0; padding:24px; color:var(--muted-text); }
      </style>
      <%= if @stamp do %>
        <p class="bp-eco-age" data-test-id="ecosystem-panel-age" data-stale={to_string(@stale?)}>
          {age_line(@minutes, @stale?)}
        </p>
        <iframe
          class="bp-eco-frame"
          data-test-id="ecosystem-panel-frame"
          sandbox="allow-scripts"
          src={@frame_path <> "?v=" <> @stamp.sha256}
          title={gettext("Ecosystem panel")}
        >
        </iframe>
      <% else %>
        <p class="bp-eco-empty" data-test-id="ecosystem-panel-empty">{gettext("No snapshot yet")}</p>
      <% end %>
    </div>
    """
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp admitted_workspace(%{
         scoped_admin_workspace_slug: slug,
         current_workspace: %{id: id, slug: slug} = workspace
       })
       when is_binary(id) and is_binary(slug),
       do: workspace

  defp admitted_workspace(_assigns), do: nil

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  defp load_stamp(socket) do
    socket
    |> assign(:stamp, EcosystemPanel.get_stamp(socket.assigns.workspace_id))
    |> assign(:now, DateTime.utc_now())
  end

  # Runs `fun` only while the socket's principal is still an owner or admin of
  # the workspace; otherwise leaves with the `:scoped_admin` denial.
  defp while_admin(socket, fun) do
    if still_admin?(socket) do
      {:noreply, socket |> fun.() |> assign_age()}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("Admin access required"))
       |> redirect(to: "/studio")}
    end
  end

  defp still_admin?(socket) do
    workspace_id = socket.assigns.workspace_id

    Enum.any?(
      [socket.assigns[:api_token], socket.assigns[:current_user]],
      &(&1 && TenancyAuth.workspace_admin?(&1, workspace_id))
    )
  end

  # The frame lives next to this page: same workspace and project slugs.
  defp frame_path(socket) do
    ws = socket.assigns.current_workspace
    proj = socket.assigns[:current_project]
    "/w/#{ws.slug}/p/#{proj && proj.slug}/studio/ecosystem-panel/frame"
  end

  defp assign_age(%{assigns: %{stamp: %{built_at: built_at}, now: now}} = socket) do
    minutes = max(div(DateTime.diff(now, built_at, :second), 60), 0)
    assign(socket, minutes: minutes, stale?: minutes > @stale_after_minutes)
  end

  defp assign_age(socket), do: assign(socket, minutes: nil, stale?: false)

  defp age_line(0, false), do: gettext("Built just now")

  defp age_line(minutes, false),
    do: ngettext("Built 1 minute ago", "Built %{count} minutes ago", minutes)

  defp age_line(minutes, true) when minutes < 60,
    do: ngettext("Stale: built 1 minute ago", "Stale: built %{count} minutes ago", minutes)

  defp age_line(minutes, true) when minutes < 48 * 60,
    do: ngettext("Stale: built 1 hour ago", "Stale: built %{count} hours ago", div(minutes, 60))

  defp age_line(minutes, true),
    do: ngettext("Stale: built 1 day ago", "Stale: built %{count} days ago", div(minutes, 1440))
end
