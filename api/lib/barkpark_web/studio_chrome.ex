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
      to the seeded Default scope ONLY for a principal
      `Tenancy.Auth.authorize/3` actually authorizes there — a principal
      holding no membership anywhere keeps a nil workspace rather than
      being handed a tenant it cannot act in (task-e9386e19bd7bb376).
    * `shares_admin?` — WORKSPACE-SCOPED. Delegates to
      `BarkparkWeb.Studio.Caps.admin?/1`, the same seat-authority oracle
      StudioLive derives its `caps.admin` from and re-checks in every
      shares-* handler (the button is chrome; the HANDLER gate stays the
      security boundary).
    * `instance_admin?` — HOST-LEVEL, deliberately NOT workspace-scoped.
      The self-update banner's oracle (see below).
    * `nav_section` / `current_path` / `create_open` / `api_token` —
      nil-safe defaults so the layout never KeyErrors on a surface that
      doesn't care.

  ## Two admin oracles, split deliberately (arpss-w10)

  `shares_admin?` used to be `token_admin? or account_admin?`, where the
  account arm authorized against `Tenancy.get_default_workspace()` — NOT
  the workspace `hydrate_scope/1` had just resolved two lines earlier.
  That was wrong in both directions, and neither is an authorization
  bypass (every consumer re-gates; the scoped routes are gated by
  `LiveAuth :scoped_admin` and StudioLive by the `Caps` deny-gate) — both
  are display defects:

    * FALSE-SHOW — an admin of Default who is a plain `member` of B saw
      Share / Settings / tmux chrome while browsing `/w/B/…`, which the
      scoped gate then refused. On the flat `/studio/*` routes it was
      worse: an `admin`-permissioned api_token with ZERO membership rows
      anywhere got `shares_admin? == true` against the Default workspace
      `default_scope_fallback/1` had just pinned for it — a phantom
      admin affordance for a non-member.
    * FALSE-HIDE, the operationally worse one — an admin or OWNER of B
      holding no role on Default saw no admin chrome anywhere, including
      on B's own scoped surfaces, so they could not discover the Settings
      tab for a workspace they own.

  The fix splits the assign in two rather than picking one oracle:

    * `shares_admin?` — every WORKSPACE-scoped affordance (Share button,
      Settings/tmux/chat tabs). Now literally `Caps.admin?/1`, the
      seat-authority predicate: `role_permits?(membership_role, ws_id,
      :admin)` on the MOUNTED workspace, for BOTH principal kinds (an
      `admin`-permissioned token must ALSO hold an admin-conferring
      membership ROLE here). Calling Caps rather than re-spelling it is
      the point — chrome and the deny-gate must never be able to drift,
      and a nil/unresolved workspace DENIES, which is what retires the
      phantom flat-route affordance.
    * `instance_admin?` — the HOST-level oracle, kept verbatim: an admin
      api_token OR an account with admin authority on the Default
      workspace. The self-update banner is genuinely instance-wide (it
      offers to upgrade the BEAM everyone is running, not a tenant's
      content), so narrowing it to the mounted workspace would hide it
      from the host operator the moment they browsed a workspace they
      merely belong to. `LiveAuth.on_mount(:admin)` uses the same
      default-workspace bar, so this arm stays its mirror.

  > NOTE: `layouts/studio.html.heex` still passes `shares_admin?` to
  > `studio_update_banner`. Re-pointing that one attribute at
  > `instance_admin?` is a layout change, outside this fence, filed as
  > `task-4cfc68a1e3bec452`. Until it lands the banner rides the narrowed
  > flag.

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
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.ScopeResolver

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
      # ORDER IS THE FIX (task-e656670726427b96): derive the principal's OWN
      # workspace BEFORE the Default fallback, which is no-op-if-set. Reversed,
      # it fails SILENTLY — the fallback pins Default and the derivation never
      # runs. Same ordering contract as the HTTP pipeline's
      # DeriveWorkspaceFromToken → AssignDefaultScope (router.ex:40-61).
      |> derive_scope_from_principal()
      |> default_scope_fallback()
      # PRESENCE, not merely value (task-e9386e19bd7bb376). Now that the
      # fallback is authority-checked, a perfectly legitimate mount can end with
      # no workspace at all, and that used to be the rare unseeded-tenancy case.
      # Every consumer already reads `assigns[:current_workspace]` (bracket
      # access, nil-safe) — pin the keys as PRESENT-and-nil anyway, so the day
      # someone writes `@current_workspace` in a studio-layout template it
      # degrades to a blank instead of KeyError-crashing the mount for exactly
      # the principal this row narrows.
      |> assign_new(:current_workspace, fn -> nil end)
      |> assign_new(:current_project, fn -> nil end)
      # Resolve the workspace THEME IDENTITY (ts-w4e) from the now-resolved
      # current_workspace, so root.html.heex stamps `data-bp-theme` server-side
      # (no flash). A nil/unseeded workspace → the default theme → no attribute.
      |> then(fn s ->
        assign(s, :bp_theme, Tenancy.workspace_theme(s.assigns[:current_workspace]))
      end)
      # Two oracles, one resolved scope (see "Two admin oracles" above).
      # `shares_admin?` is workspace-scoped seat authority on the MOUNTED
      # workspace; `instance_admin?` stays the host-level one.
      |> then(fn s ->
        s
        |> assign(:shares_admin?, Caps.admin?(s))
        |> assign(
          :instance_admin?,
          instance_admin?(s.assigns[:api_token], s.assigns[:current_user])
        )
      end)
      |> assign_new(:nav_section, fn -> nil end)
      |> assign_new(:current_path, fn -> nil end)
      |> assign_new(:create_open, fn -> nil end)
      |> assign_new(:scope_menu, fn -> nil end)
      # scope_subpath (ssp-w3, charter D16): the path a scope switch appends
      # to the target's `studio_root`. "" lands on the desk (the default for
      # every desk surface); a scoped chrome surface OVERRIDES it in its own
      # mount (SettingsLive sets "/settings") so a switch fired from that
      # surface re-opens the SAME surface under the NEW scope, not the desk.
      |> assign_new(:scope_subpath, fn -> "" end)

    {:cont,
     socket
     |> attach_hook(:studio_chrome_nav, :handle_event, &chrome_event/3)
     |> attach_hook(:studio_chrome_path, :handle_params, &chrome_path/3)}
  end

  # ── current_path (ALL chrome surfaces — the ONE producer) ────────────────
  #
  # Active-state highlighting is a pure function of `current_path`
  # (`StudioComponents.Nav.plugin_tab_active?/2`). `handle_params` fires on
  # every connected mount AND every push_patch, so deriving it here — once,
  # for every studio-layout live_session — lights the right tab on EVERY
  # surface (ApiTester/Settings/Styleguide/OrgAdmin/plugin-admin used to
  # render with none) and keeps it fresh across live patches (ChatLive used
  # to freeze at `/studio/chat` while patched to `/studio/chat/:session_id`).
  # This is the SINGLE producer: no LiveView hand-sets `current_path`.
  #
  # Normalized: `URI.parse/1` already drops query + fragment; we strip a
  # trailing slash (except bare root) so `active_when` boundary matches
  # ("/studio/media" vs "/studio/media/") stay deterministic.
  defp chrome_path(_params, uri, socket) when is_binary(uri) do
    {:cont, assign(socket, :current_path, normalize_path(URI.parse(uri).path))}
  end

  defp chrome_path(_params, _uri, socket), do: {:cont, socket}

  defp normalize_path(nil), do: nil
  defp normalize_path("/"), do: "/"

  defp normalize_path(path) when is_binary(path) do
    case String.trim_trailing(path, "/") do
      "" -> "/"
      trimmed -> trimmed
    end
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

  # BOTH create affordances decide on the SAME principal the scope menu itself
  # is built from (`ScopeResolver.principal_from_assigns/1`: a token, else the
  # account session's %User{}, else nil) — not on `:api_token` alone. Reading
  # the token was the #34 follow-up defect: an ACCOUNT session is signed in, so
  # `create-workspace` fell through to a silent-ish "Sign in to create a
  # workspace" and `create-project` answered "Sign in to create a project" to a
  # person who IS signed in. The message was false and the affordance dead.
  #
  # The authority is REUSED, never invented: `create_workspace_with_owner/2`
  # already has a `%User{}` head that writes a `principal_type: "user"` owner
  # membership (tenancy.ex, pinned by tenancy_test.exs:246), which is exactly
  # what `/api/workspaces` gives a token creator. Only a `nil` principal — a
  # genuinely anonymous / public-demo session — still gets "Sign in", and for
  # that one it is TRUE.
  defp chrome_fallback("create-workspace", %{"name" => name}, socket) do
    case principal(socket) do
      nil ->
        put_flash(socket, :error, "Sign in to create a workspace")

      principal ->
        case Tenancy.create_workspace_with_owner(%{name: name}, principal) do
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
    end
  end

  defp chrome_fallback("create-project", %{"name" => name}, socket) do
    ws = socket.assigns[:current_workspace]

    cond do
      is_nil(principal(socket)) ->
        put_flash(socket, :error, "Sign in to create a project")

      is_nil(ws) ->
        socket

      not can_create_in?(socket, ws) ->
        # NOT "sign in" — this principal IS signed in, it simply holds no
        # membership here. The silent no-op this replaces was not a lie, but it
        # was not an answer either: the form just did nothing.
        put_flash(
          socket,
          :error,
          "You are not a member of this workspace — ask an owner to add you before creating a project"
        )

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

    # The switcher's principal is the token OR the account session's user —
    # the SAME seam as the conn-side funnel, called rather than re-encoded.
    # Reading `:api_token` alone made `list_workspaces_for(nil)` return `[]`
    # for every signed-in account, so the menu showed only the workspace they
    # were already in: teleported by the funnel AND no in-UI way back (#34).
    workspaces =
      socket.assigns
      |> BarkparkWeb.Studio.ScopeResolver.principal_from_assigns()
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
      |> push_navigate(to: scoped_root(socket, ws, project, ds))
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
      push_navigate(socket, to: scoped_root(socket, ws, project, dataset_for(project, socket)))
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
      push_navigate(socket, to: scoped_root(socket, ws, project, dataset_for(project, socket)))
    else
      _ -> socket
    end
  end

  defp nav_to_dataset(socket, slug) do
    with %{} = ws <- socket.assigns[:current_workspace],
         %{id: proj_id} = project when is_binary(proj_id) <- socket.assigns[:current_project],
         true <- is_binary(slug) and slug != "",
         true <- Enum.any?(Tenancy.list_datasets(proj_id), &(&1.slug == slug)) do
      push_navigate(socket, to: scoped_root(socket, ws, project, slug))
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

  # A scope switch lands on the target's `studio_root` PLUS the current
  # surface's `:scope_subpath` (ssp-w3 D16). "" on every desk surface (the
  # default) → the desk root, byte-identical to before. A scoped chrome
  # surface (SettingsLive → "/settings") re-opens ITSELF under the new scope.
  defp scoped_root(socket, ws, project, dataset) do
    case socket.assigns[:scope_subpath] || "" do
      # Workspace Settings is a PROJECT-level route (/w/:ws/p/:proj/studio/
      # settings — no dataset segment; #1936) — a scope switch from Settings
      # must land on the new scope's Settings, not a dataset-ful decoy the
      # desk catch-all would swallow.
      "/settings" -> "/w/#{ws.slug}/p/#{project.slug}/studio/settings"
      subpath -> studio_root(ws, project, dataset) <> subpath
    end
  end

  # Who is asking, by the ONE precedence rule the flat->scoped funnel and the
  # scope menu already share. Never re-encoded here (two copies of "token wins
  # over user" drift, and a create gate that disagrees with the menu that
  # rendered it is #34 all over again).
  defp principal(socket), do: ScopeResolver.principal_from_assigns(socket.assigns)

  # May THIS principal mint sibling tenancy inside `ws`? Membership, asked of
  # the principal's OWN kind — `Tenancy.Auth.member?/2` reads a token id out of
  # the "api_token" row space and a %User{} id out of the "user" row space, so
  # this widens nothing. For a token it is byte-identical to `can_reach?/2`
  # (that arm already IS `member?/2`); it exists so the account arm asks the
  # SAME question instead of `can_reach?/2`'s anonymous fallback ("is this the
  # workspace I am already mounted in?"), which every mounted account session
  # answers yes to and which therefore gates nothing.
  defp can_create_in?(socket, %{id: ws_id}) do
    case principal(socket) do
      nil -> false
      principal -> Tenancy.Auth.member?(principal, ws_id)
    end
  end

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

  # The LiveView analogue of `BarkparkWeb.Plugs.DeriveWorkspaceFromToken`
  # (task-e656670726427b96). The flat live_sessions — `:plugin_admin` most
  # sharply — carry NO workspace producer: `LiveAuth :admin` gates on the
  # workspace-BLIND `admin` permission and assigns only `:api_token`, so before
  # this step `default_scope_fallback/1` below was the ONLY producer and it
  # pinned the seeded Default for every admin, including one whose token is
  # bound elsewhere. That is not merely a display defect on plugin surfaces:
  # Tickets' `InboxLive` reads this very assign for `Keys.mint/rotate/pause/
  # unpause`, so a workspace-B admin MINTED a live credential into Default and
  # could churn Default's existing keys. `Keys.scope_workspace/2` is fail-closed
  # and was working perfectly — it was handed the wrong workspace and faithfully
  # confined the operator to the wrong tenant. The fence was never the bug; the
  # assign upstream of it was.
  #
  # Runs only when nothing stronger resolved: a scoped mount's LiveScope /
  # PluginScopeSession assign short-circuits on the same truthy guard the
  # fallback uses, so the scoped surfaces are untouched by this step.
  #
  # FAIL-SOFT, exactly like the plug — it never halts, it only narrows:
  #
  #   * `:current_workspace` already set → untouched.
  #   * no `:api_token` (the account-session arm, which carries `:current_user`)
  #     → untouched, and the Default fallback below is CORRECT for it:
  #     `LiveAuth.authorize_user/3` authorizes that principal against the
  #     DEFAULT workspace specifically, so Default IS its authorized scope.
  #   * `workspace_id` nil — a genuinely instance-wide token — → untouched
  #     HERE, because this step only binds a workspace the principal NAMES and
  #     that principal names none. It does NOT follow that Default is its scope:
  #     `default_scope_fallback/1` below now authority-checks that population
  #     through `Tenancy.Auth.authorize/3` and leaves it nil when it holds no
  #     membership anywhere (task-e9386e19bd7bb376, superseding the carve-out
  #     this bullet used to assert).
  #   * `workspace_id` names no row → untouched rather than a 500.
  defp derive_scope_from_principal(socket) do
    if socket.assigns[:current_workspace] do
      socket
    else
      with %{workspace_id: ws_id} when is_binary(ws_id) <- socket.assigns[:api_token],
           %Tenancy.Workspace{} = ws <- Tenancy.get_workspace_by_id(ws_id) do
        assign(socket, current_workspace: ws, current_project: project_for(ws))
      else
        _ -> socket
      end
    end
  end

  # Flat surfaces where the principal named NO workspace of its own (an
  # instance-wide token, or the account session, whose authority
  # `LiveAuth.authorize_user/3` measures on Default): pin the seeded Default
  # scope — but ONLY when the principal is actually AUTHORIZED in Default — so
  # the full switcher renders for the operators entitled to it. An unseeded
  # tenancy stays nil and the layout's dataset-only branch covers it.
  #
  # SETTLED (task-e656670726427b96, acceptance 4): it must NOT pin Default for a
  # principal that HAS a resolvable workspace — a bound principal's own tenant is
  # a fact, and overriding it with Default silently redirects that operator's
  # WRITES into a tenant they may hold no authority in. Hence
  # `derive_scope_from_principal/1` runs first and this is now genuinely a
  # last-resort fallback, reached only when there is nothing truer to bind to.
  #
  # AUTHORITY-CHECKED SINCE task-e9386e19bd7bb376, which RETRACTS the
  # unconditional pin task-e656670726427b96 left standing for the
  # membership-less population. `Tenancy.Auth.authorize/3` (auth.ex) is
  # literally `member?(token, workspace_id) and permits?(token, action)` —
  # there is NO global-permission bypass — so an api_token with
  # `workspace_id == nil` and no `workspace_memberships` row is authorized in
  # NO workspace, the seeded Default INCLUDED. Pinning Default for that
  # principal handed it a tenant it cannot be authorized in, and every
  # workspace-scoped read and write on the surface then ran against that
  # tenant: Tickets' `InboxLive` read Default's ticket keys and MINTED a live
  # credential into Default; `ChatLive` listed Default's REGISTERED EXECUTION
  # HOSTS (remote command-execution targets).
  #
  # The old argument was the HTTP sibling `DeriveWorkspaceFromToken`'s
  # nil-token carve-out. It does not survive: preserving Default for a
  # nil-workspace token is not evidence that the token has AUTHORITY in
  # Default, and `authorize/3` says it does not.
  #
  # BOTH LEGITIMATE DEFAULT POPULATIONS ARE UNCHANGED, because both clear the
  # very same chokepoint:
  #
  #   * the ACCOUNT-session arm — `LiveAuth.authorize_user/3` already demands
  #     `Tenancy.Auth.authorize(user, default_ws_id, :admin) == :ok` before it
  #     will `{:cont, …}` at all, so this principal holds a real Default
  #     membership and clears `:read` here a fortiori.
  #   * a TOKEN that holds a Default membership — `authorize/3` passes.
  #
  # A principal that clears neither keeps `current_workspace: nil`. We NARROW
  # rather than halt on purpose: the six resolver-less live_sessions also carry
  # genuinely scope-free host surfaces (OrgAdminLive, StyleguideLive,
  # SwatchLive, TmuxLive) an instance operator must keep reaching. nil is an
  # already-supported chrome state — an unseeded tenancy has always produced it
  # — and every consumer on that path is fail-CLOSED, not fail-open:
  #
  #   * the studio layout renders its dataset-only branch;
  #   * `Caps.admin?/1` DENIES on a nil workspace (arpss-w10), so no admin
  #     chrome;
  #   * `ChatLive.execution_hosts/1` pattern-matches `%{id: ws_id}` -> `[]`;
  #   * Tickets' `Keys.list/1` AND its by-id fences are fail-closed on nil —
  #     `scope_workspace(query, nil)` is `is_nil(t.workspace_id)`, i.e. the
  #     un-bound tenant, NOT every tenant (proved by `keys_test.exs`'s
  #     colliding two-tenant fixture). A `Keys.mint/1` from this state creates
  #     an un-bound, member-less, kind-fenced key — inert on every normal route
  #     — instead of a live credential inside Default.
  defp default_scope_fallback(socket) do
    if socket.assigns[:current_workspace] do
      socket
    else
      with %Tenancy.Workspace{} = ws <- Tenancy.get_default_workspace(),
           true <- authorized_in?(socket, ws.id) do
        assign(socket, current_workspace: ws, current_project: project_for(ws))
      else
        _ -> socket
      end
    end
  end

  # Both principal kinds go through the ONE chokepoint, `Tenancy.Auth.authorize/3`
  # — never a second, laxer copy of the membership rule.
  #
  # `:read` is deliberately the WEAKEST action: the only question here is "may
  # this principal be SCOPED to this tenant at all". Every consumer re-gates its
  # own action afterwards (`Caps.admin?/1` for the admin chrome, the per-surface
  # deny-gates for writes), so demanding `:admin` here would strip chrome from a
  # legitimate read-only member of Default.
  #
  # Checked as an OR over BOTH arms rather than `api_token || current_user`:
  # `LiveAuth.on_mount(:fetch_api_token)` (the `:plugin_public` session) assigns
  # BOTH, and a `||` would silently answer the question for the wrong principal.
  defp authorized_in?(socket, ws_id) do
    principal_authorized?(socket.assigns[:api_token], ws_id) or
      principal_authorized?(socket.assigns[:current_user], ws_id)
  end

  defp principal_authorized?(nil, _ws_id), do: false

  defp principal_authorized?(principal, ws_id),
    do: Tenancy.Auth.authorize(principal, ws_id, :read) == :ok

  # HOST-LEVEL admin, for the self-update banner ONLY (arpss-w10): an admin
  # API token OR an account whose role on the DEFAULT workspace is admin-grade.
  # These are the SAME two paths `LiveAuth.on_mount(:admin)` accepts
  # (live_auth.ex:199-211), and mirroring it is deliberate — the banner offers
  # to upgrade the instance, which is not a tenant-scoped act. Without the
  # account arm, a cloud/SSO session — which carries no api_token — would see
  # no host chrome even as the owner (this is why the tmux tab was invisible on
  # cloud-login instances). The tmux TAB itself is NOT on this flag — it is a
  # workspace-scoped affordance and rides `shares_admin?`, so a workspace admin
  # now reaches it on their own workspace with no Default role at all. What this
  # arm still carries is the self-update banner.
  #
  # NOT used for any workspace-scoped affordance — that is `shares_admin?`,
  # which is `Caps.admin?/1`. Do not re-merge these two.
  defp instance_admin?(token, user), do: token_admin?(token) or account_admin?(user)

  defp token_admin?(%_{} = token), do: Barkpark.Auth.has_permission?(token, "admin")
  defp token_admin?(_), do: false

  # The DEFAULT-workspace arm — correct HERE (host-level) and only here.
  defp account_admin?(%Barkpark.Accounts.User{} = user) do
    case Tenancy.get_default_workspace() do
      %{id: ws_id} -> Tenancy.Auth.authorize(user, ws_id, :admin) == :ok
      _ -> false
    end
  end

  defp account_admin?(_), do: false
end
