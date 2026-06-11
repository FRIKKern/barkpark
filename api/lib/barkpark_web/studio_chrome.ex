defmodule BarkparkWeb.StudioChrome do
  @moduledoc """
  The shared top-bar contract for every LiveView rendered in the Studio
  layout (`layouts/studio.html.heex`).

  ## Why this exists

  The Studio top bar is data-driven off each LiveView's private assigns:
  `current_workspace` gates the Workspace·Project·Dataset switcher,
  `dataset` gates the tabs, `shares_admin?` gates the Share button,
  `api_token` gates Sign out. Before this hook, every surface set a
  different subset — StudioLive showed the full bar, Media/API-tester
  lost the Share button, `/studio/settings` degraded to a lone dataset
  dropdown, and plugin admin pages collapsed to a bare logo. Worse: once
  LiveScope started assigning `current_workspace` on the scoped mounts,
  the switcher RENDERED on MediaLive/ApiTesterLive — whose modules have
  no `switch-*` handlers, so interacting with it crashed the LiveView.

  ## What it does

  `on_mount(:default)` — runs AFTER LiveAuth/LiveScope/PluginScopeSession
  in each live_session's on_mount list, so it only fills gaps
  (`assign_new`), never overrides a stronger resolver:

    * `dataset` — URL param, else the configured default.
    * `scope_prefix` — derived from the URL's `/w/:ws/p/:proj` params
      ("" on flat surfaces), so the tabs address the page's tenant.
    * `current_workspace` / `current_project` — hydrated to full structs
      (PluginScopeSession bridges id+slug maps; the switcher and the
      navigation handlers want `.name`/`.slug`); flat surfaces fall back
      to the seeded Default scope, mirroring the flat Studio's
      `ensure_tenancy_scope`.
    * `shares_admin?` — the same nil-safe admin predicate StudioLive
      re-checks in every shares-* handler (the button is chrome; the
      HANDLER gate stays the security boundary).
    * `nav_section` / `current_path` / `create_open` / `api_token` —
      nil-safe defaults so the layout never KeyErrors on a surface that
      doesn't care.

  For every view EXCEPT StudioLive it also attaches a `handle_event`
  hook giving the switcher NAVIGATION semantics: a workspace/project/
  dataset switch is a `push_navigate` to the target scope's canonical
  Studio URL (Scoped-by-URL: a switch IS a navigation), and Share opens
  the Studio with `?shares=open`. StudioLive keeps its own richer
  in-socket handlers — the hook is never attached there.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3, assign_new: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, push_navigate: 2, put_flash: 3]

  alias Barkpark.{Content, Tenancy}

  def on_mount(:default, params, _session, socket) do
    socket =
      socket
      |> assign_new(:api_token, fn -> nil end)
      |> assign_new(:dataset, fn -> params["dataset"] || Content.default_dataset() end)
      |> assign_new(:scope_prefix, fn -> scope_prefix_from(params) end)
      |> hydrate_scope()
      |> default_scope_fallback()
      |> then(fn s -> assign(s, :shares_admin?, admin?(s.assigns[:api_token])) end)
      |> assign_new(:nav_section, fn -> nil end)
      |> assign_new(:current_path, fn -> nil end)
      |> assign_new(:create_open, fn -> nil end)

    socket =
      if socket.view == BarkparkWeb.Studio.StudioLive do
        socket
      else
        attach_hook(socket, :studio_chrome_nav, :handle_event, &chrome_event/3)
      end

    {:cont, socket}
  end

  # ── chrome-level switcher events (non-StudioLive surfaces) ───────────────

  defp chrome_event("switch-workspace", %{"workspace" => slug}, socket),
    do: {:halt, nav_to_workspace(socket, slug)}

  defp chrome_event("switch-project", %{"project" => slug}, socket),
    do: {:halt, nav_to_project(socket, slug)}

  defp chrome_event("switch-dataset", %{"dataset" => slug}, socket),
    do: {:halt, nav_to_dataset(socket, slug)}

  defp chrome_event("shares-open", _params, socket),
    do: {:halt, nav_to_shares(socket)}

  defp chrome_event(_event, _params, socket), do: {:cont, socket}

  # Same hard tenant boundary as StudioLive's switch handler: a principal
  # may switch only into a membership workspace; the anonymous/dev session
  # may "switch" only to the workspace already on the socket.
  defp nav_to_workspace(socket, slug) do
    with %Tenancy.Workspace{} = ws <- Tenancy.get_workspace_by_slug(slug),
         true <- can_reach?(socket, ws),
         %{} = project <- project_for(ws) do
      push_navigate(socket, to: studio_root(ws, project, dataset_for(project, socket)))
    else
      nil -> socket
      false -> socket
      _ -> put_flash(socket, :error, "Workspace has no projects yet — create one first")
    end
  end

  defp nav_to_project(socket, slug) do
    with %{slug: ws_slug} = ws when is_binary(ws_slug) <- socket.assigns[:current_workspace],
         true <- can_reach?(socket, ws),
         %Tenancy.Project{} = project <- Tenancy.get_project(ws_slug, slug) do
      push_navigate(socket, to: studio_root(ws, project, dataset_for(project, socket)))
    else
      _ -> socket
    end
  end

  defp nav_to_dataset(socket, slug) do
    with %{} = ws <- socket.assigns[:current_workspace],
         %{id: proj_id} = project when is_binary(proj_id) <- socket.assigns[:current_project],
         true <- is_binary(slug) and slug != "",
         true <- Enum.any?(Tenancy.list_datasets(proj_id), &(&1.slug == slug)) do
      push_navigate(socket, to: studio_root(ws, project, slug))
    else
      _ -> socket
    end
  end

  # The shares PANEL lives in StudioLive — from any other surface the
  # button navigates there with ?shares=open (handled in handle_params).
  defp nav_to_shares(socket) do
    with %{} = ws <- socket.assigns[:current_workspace],
         %{} = project <- socket.assigns[:current_project] do
      push_navigate(socket,
        to: studio_root(ws, project, socket.assigns[:dataset]) <> "?shares=open"
      )
    else
      _ -> socket
    end
  end

  defp studio_root(ws, project, dataset),
    do: "/w/#{ws.slug}/p/#{project.slug}/studio/#{dataset}"

  defp can_reach?(socket, %{id: ws_id}) do
    case socket.assigns[:api_token] do
      %Barkpark.Auth.ApiToken{} = token ->
        Tenancy.Auth.member?(token, ws_id)

      _ ->
        match?(%{id: ^ws_id}, socket.assigns[:current_workspace])
    end
  end

  defp project_for(%{id: ws_id}) do
    default =
      case Tenancy.get_default_project() do
        %{workspace_id: ^ws_id} = proj -> proj
        _ -> nil
      end

    default || List.first(Tenancy.list_projects(ws_id))
  end

  defp dataset_for(%{id: proj_id}, socket) do
    slugs = Tenancy.list_datasets(proj_id) |> Enum.map(& &1.slug)

    cond do
      "production" in slugs -> "production"
      slugs != [] -> List.first(slugs)
      true -> socket.assigns[:dataset] || Content.default_dataset()
    end
  end

  # ── assigns plumbing ──────────────────────────────────────────────────────

  defp scope_prefix_from(%{"workspace_slug" => ws, "project_slug" => proj})
       when is_binary(ws) and is_binary(proj),
       do: "/w/#{ws}/p/#{proj}"

  defp scope_prefix_from(_params), do: ""

  # PluginScopeSession bridges %{id, slug} maps; the switcher label and the
  # navigation handlers want full structs (.name, projects). Hydrate in
  # place; full structs (LiveScope / StudioLive) pass through untouched.
  defp hydrate_scope(socket) do
    socket
    |> hydrate(:current_workspace, &Tenancy.get_workspace_by_id/1)
    |> hydrate(:current_project, &Tenancy.get_project_by_id/1)
  end

  defp hydrate(socket, key, fetch) do
    case socket.assigns[key] do
      %{__struct__: _} -> socket
      %{id: id} when is_binary(id) -> assign(socket, key, fetch.(id) || socket.assigns[key])
      _ -> socket
    end
  end

  # Flat surfaces (no resolver ran): pin the seeded Default scope so the
  # full switcher renders everywhere — the same fallback the flat Studio's
  # ensure_tenancy_scope applies. An unseeded tenancy stays nil and the
  # layout's dataset-only branch covers it.
  defp default_scope_fallback(socket) do
    if socket.assigns[:current_workspace] do
      socket
    else
      case Tenancy.get_default_workspace() do
        %Tenancy.Workspace{} = ws ->
          assign(socket, current_workspace: ws, current_project: project_for(ws))

        _ ->
          socket
      end
    end
  end

  defp admin?(%_{} = token), do: Barkpark.Auth.has_permission?(token, "admin")
  defp admin?(_), do: false
end
