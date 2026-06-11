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

  It also attaches a `handle_event` hook to EVERY chrome surface:

    * The **scope menu** (`scope-menu-*` / `scope-open`) is handled here
      for all views — the Sanity-style title button opens ONE popover
      where workspace, project and dataset are picked together; choosing
      a dataset is a `push_navigate` to the triple's canonical Studio URL
      (Scoped-by-URL: a scope pick IS a navigation). Menu state lives in
      the `:scope_menu` assign (nil = closed); the preview columns only
      ever list membership workspaces, and `scope-open` re-gates the
      target server-side regardless of what the client claims.
    * The **legacy single-axis events** (`switch-*`, `shares-open`,
      `toggle-create`, `create-*`) pass through (`:cont`) on StudioLive —
      it keeps its richer in-socket handlers — and get NAVIGATION
      semantics here on every other view (they used to crash
      MediaLive/ApiTesterLive, which never defined them).
  """

  import Phoenix.Component, only: [assign: 2, assign: 3, assign_new: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, push_navigate: 2, put_flash: 3]

  alias Barkpark.{Content, Tenancy}

  @studio_live BarkparkWeb.Studio.StudioLive

  # Events StudioLive handles itself — the hook only intercepts them on
  # surfaces that would otherwise crash (no handler defined).
  @per_view_events ~w(switch-workspace switch-project switch-dataset shares-open
                      toggle-create create-workspace create-project)

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
      |> assign_new(:scope_menu, fn -> nil end)

    {:cont, attach_hook(socket, :studio_chrome_nav, :handle_event, &chrome_event/3)}
  end

  # ── scope menu (ALL chrome surfaces — StudioLive included) ───────────────

  defp chrome_event("scope-menu-toggle", _params, socket) do
    if socket.assigns[:scope_menu] do
      {:halt, assign(socket, :scope_menu, nil)}
    else
      {:halt, open_scope_menu(socket)}
    end
  end

  defp chrome_event("scope-menu-close", _params, socket),
    do: {:halt, assign(socket, :scope_menu, nil)}

  defp chrome_event("scope-menu-ws", %{"id" => id}, socket),
    do: {:halt, preview_menu_workspace(socket, id)}

  defp chrome_event("scope-menu-proj", %{"id" => id}, socket),
    do: {:halt, preview_menu_project(socket, id)}

  defp chrome_event("scope-open", params, socket),
    do: {:halt, open_scope(socket, params)}

  # ── legacy single-axis events (non-StudioLive surfaces) ──────────────────

  defp chrome_event(event, params, socket) when event in @per_view_events do
    if socket.view == @studio_live do
      {:cont, socket}
    else
      {:halt, chrome_fallback(event, params, socket)}
    end
  end

  defp chrome_event(_event, _params, socket), do: {:cont, socket}

  defp chrome_fallback("switch-workspace", %{"workspace" => slug}, socket),
    do: nav_to_workspace(socket, slug)

  defp chrome_fallback("switch-project", %{"project" => slug}, socket),
    do: nav_to_project(socket, slug)

  defp chrome_fallback("switch-dataset", %{"dataset" => slug}, socket),
    do: nav_to_dataset(socket, slug)

  defp chrome_fallback("shares-open", _params, socket),
    do: nav_to_shares(socket)

  # The popover's create affordances fire the same events StudioLive
  # already handles; here they get the chrome's navigation semantics —
  # create, then push_navigate into the new scope's canonical URL.
  defp chrome_fallback("toggle-create", %{"target" => target}, socket)
       when target in ["workspace", "project"] do
    next = if socket.assigns[:create_open] == target, do: nil, else: target
    assign(socket, :create_open, next)
  end

  defp chrome_fallback("create-workspace", %{"name" => name}, socket) do
    case socket.assigns[:api_token] do
      %Barkpark.Auth.ApiToken{} = token ->
        case Tenancy.create_workspace_with_owner(%{name: name}, token) do
          {:ok, ws} ->
            case project_for(ws) do
              %{} = project ->
                push_navigate(socket, to: studio_root(ws, project, dataset_for(project, socket)))

              _ ->
                put_flash(socket, :error, "Workspace created without a project")
            end

          {:error, _changeset} ->
            put_flash(socket, :error, "Could not create workspace")
        end

      _ ->
        put_flash(socket, :error, "Sign in to create a workspace")
    end
  end

  defp chrome_fallback("create-project", %{"name" => name}, socket) do
    ws = socket.assigns[:current_workspace]

    cond do
      not match?(%Barkpark.Auth.ApiToken{}, socket.assigns[:api_token]) ->
        put_flash(socket, :error, "Sign in to create a project")

      is_nil(ws) or not can_reach?(socket, ws) ->
        socket

      true ->
        case Tenancy.create_project_with_dataset(ws, %{name: name}) do
          {:ok, created} ->
            project = Tenancy.get_project_by_id(created.id) || created
            push_navigate(socket, to: studio_root(ws, project, dataset_for(project, socket)))

          {:error, _changeset} ->
            put_flash(socket, :error, "Could not create project")
        end
    end
  end

  defp chrome_fallback(_event, _params, socket), do: socket

  # ── scope-menu state ──────────────────────────────────────────────────────
  #
  # The menu previews a (workspace, project) pair without navigating; only
  # `scope-open` — a dataset pick — leaves the page. The workspace column is
  # the same membership-gated list the old select used
  # (`list_workspaces_for/1` + union-in the current workspace for the
  # anonymous/dev session), so a preview can never reach a foreign tenant,
  # and `open_scope/2` independently re-gates the final triple anyway.

  defp open_scope_menu(socket) do
    ws = socket.assigns[:current_workspace]
    proj = socket.assigns[:current_project]

    workspaces =
      socket.assigns[:api_token]
      |> Tenancy.list_workspaces_for()
      |> ensure_current(ws)

    assign(socket, :scope_menu, %{
      ws: ws,
      proj: proj,
      workspaces: workspaces,
      projects: menu_projects(ws),
      datasets: menu_datasets(proj)
    })
  end

  defp preview_menu_workspace(socket, id) do
    with %{} = menu <- socket.assigns[:scope_menu],
         %{} = ws <- Enum.find(menu.workspaces, &(&1.id == id)) do
      proj = project_for(ws)

      assign(socket, :scope_menu, %{
        menu
        | ws: ws,
          proj: proj,
          projects: menu_projects(ws),
          datasets: menu_datasets(proj)
      })
    else
      _ -> socket
    end
  end

  defp preview_menu_project(socket, id) do
    with %{} = menu <- socket.assigns[:scope_menu],
         %{} = proj <- Enum.find(menu.projects, &(&1.id == id)) do
      assign(socket, :scope_menu, %{menu | proj: proj, datasets: menu_datasets(proj)})
    else
      _ -> socket
    end
  end

  defp menu_projects(%{id: ws_id}) when is_binary(ws_id), do: Tenancy.list_projects(ws_id)
  defp menu_projects(_), do: []

  defp menu_datasets(%{id: proj_id}) when is_binary(proj_id), do: Tenancy.list_datasets(proj_id)
  defp menu_datasets(_), do: []

  # A dataset pick: navigate to the triple's canonical Studio URL. Every
  # level is re-resolved and re-gated server-side — membership for the
  # workspace, containment for project and dataset — so forged
  # phx-value-* can never re-scope across the tenant boundary.
  defp open_scope(socket, %{"ws" => ws_slug, "proj" => proj_slug, "ds" => ds}) do
    with %Tenancy.Workspace{} = ws <- Tenancy.get_workspace_by_slug(ws_slug),
         true <- can_reach?(socket, ws),
         %Tenancy.Project{} = project <- Tenancy.get_project(ws.slug, proj_slug),
         true <- is_binary(ds) and ds != "",
         true <- Enum.any?(Tenancy.list_datasets(project.id), &(&1.slug == ds)) do
      socket
      |> assign(:scope_menu, nil)
      |> push_navigate(to: studio_root(ws, project, ds))
    else
      _ -> assign(socket, :scope_menu, nil)
    end
  end

  defp open_scope(socket, _params), do: assign(socket, :scope_menu, nil)

  # Keep the active workspace visible in the menu even when it isn't in the
  # membership list — the anonymous/dev session seeds `current_workspace`
  # from the Default backfill (no membership row). Never exposes a FOREIGN
  # workspace: only the one already on the socket, which `open_scope/2`
  # independently re-checks.
  defp ensure_current(workspaces, %{id: id} = current) do
    if Enum.any?(workspaces, &(&1.id == id)) do
      workspaces
    else
      Enum.sort_by([current | workspaces], & &1.slug)
    end
  end

  defp ensure_current(workspaces, _), do: workspaces

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
    do: "/w/#{ws.slug}/p/#{project.slug}/d/#{dataset}/studio"

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
