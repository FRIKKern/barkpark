defmodule BarkparkWeb.Studio.ScopeResolver do
  @moduledoc """
  Resolve the `{workspace, project}` a flat / under-determined Studio URL
  should land in — the shared brain behind the flat→scoped 302 funnel
  (`StudioRedirectController`, `PageController.redirect_to_studio`,
  `LegacyRedirectController.onixedit_book`). Slice `sdl-w1-admin-canonical`
  reuses `resolve_scope/2` too, so the API is small and total.

  ## The teleport, killed

  A flat link like `/studio/production/...` (or bare `/studio`) carries NO
  workspace in the URL. The old resolver answered that by unconditionally
  picking `List.first(Tenancy.list_workspaces_for(token))` — the first
  slug-ordered membership. A user working in workspace `beta` who followed a
  flat link was silently *teleported* to workspace `acme` (it sorts first),
  and the dataset could teleport with it. The address bar lied about where
  you were.

  ## Resolution order (workspace under-determined by the URL)

  1. **URL scope** — if the URL already names the workspace, the caller does
     not reach here (`legacy_scoped/2` is a pure rewrite; the canonical
     `/w/:ws/p/:proj/d/:ds/studio` route authorizes its own scope). This
     module only runs when the URL is flat.
  2. **Referer preference** — parse the PATH of the `Referer` header, match a
     leading `/w/:ws/p/:proj` prefix, resolve those slugs via `Tenancy`, and
     REQUIRE the token be a member (`Tenancy.Auth.member?/2`). When valid, use
     that workspace AND project — so returning to a flat link keeps you where
     you were. The Referer is a scope *preference* only, NEVER an auth input:
     membership is verified here, and the canonical scoped route re-authorizes
     at mount regardless. Cross-origin, unparseable, or non-member Referers are
     ignored — they fall through to step 3.
  3. **Session / first-membership fallback** — the token's first slug-ordered
     membership workspace (anonymous → the seeded Default workspace), then that
     workspace's Default project (else its first project). This is the exact
     pre-existing behavior, now the *last* resort instead of the only one.

  Callers must always 302 (never 301): the target depends on the token +
  Referer, so it must never be browser-cached across users.
  """

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.{Project, Workspace}

  @scope_prefix ~r{^/w/([^/]+)/p/([^/]+)(?:/|$)}

  @doc """
  Resolve `{:ok, workspace, project}` for a flat Studio URL, or `:error` when
  no workspace/project is resolvable (the caller redirects to `/login`).

  `token` is `conn.assigns[:api_token]` — an `%ApiToken{}` or `nil` (anonymous).
  The Referer is read from `conn` and used only as a membership-verified scope
  preference; see the module doc for the full order.
  """
  # @canonical capability:studio-scope-resolution aka:teleport,referer,flat-scoped,resolve_workspace
  @spec resolve_scope(Plug.Conn.t(), ApiToken.t() | nil) ::
          {:ok, Workspace.t(), Project.t()} | :error
  def resolve_scope(conn, token) do
    case referer_scope(conn, token) do
      {%Workspace{} = ws, %Project{} = project} ->
        {:ok, ws, project}

      nil ->
        with %Workspace{} = ws <- resolve_workspace(token),
             %Project{} = project <- resolve_project(ws) do
          {:ok, ws, project}
        else
          _ -> :error
        end
    end
  end

  @doc """
  The session / first-membership workspace fallback (step 3): the token's
  first slug-ordered membership workspace, else the seeded Default. `nil`
  token (anonymous) → the Default workspace.
  """
  @spec resolve_workspace(ApiToken.t() | nil) :: Workspace.t() | nil
  def resolve_workspace(nil), do: Tenancy.get_default_workspace()

  def resolve_workspace(token) do
    case Tenancy.list_workspaces_for(token) do
      [ws | _] -> ws
      _ -> Tenancy.get_default_workspace()
    end
  end

  @doc """
  The default project for a workspace: the Default project when it belongs to
  that workspace, else the workspace's first project. `nil` when the workspace
  has no projects (Studio cannot render there).
  """
  @spec resolve_project(Workspace.t()) :: Project.t() | nil
  def resolve_project(%{id: ws_id}) do
    default =
      case Tenancy.get_default_project() do
        %Project{workspace_id: ^ws_id} = proj -> proj
        _ -> nil
      end

    default || List.first(Tenancy.list_projects(ws_id))
  end

  @doc """
  Resolve the dataset leaf within `project`. The requested slug when the
  project owns a dataset row with it; else the project's default
  (`production`-preferred, else first); a project with NO dataset rows keeps
  the requested string (the string-seam stays authoritative), and a bare
  request falls back to the configured default dataset.
  """
  @spec resolve_dataset(Project.t(), String.t() | nil) :: String.t()
  def resolve_dataset(project, requested) do
    datasets = Tenancy.list_datasets(project.id)
    slugs = Enum.map(datasets, & &1.slug)

    cond do
      is_binary(requested) and requested in slugs ->
        requested

      "production" in slugs ->
        "production"

      slugs != [] ->
        List.first(slugs)

      # No dataset rows (string-seam-only project): the requested string
      # stays authoritative; a bare /studio falls back to the configured
      # default dataset.
      is_binary(requested) and requested != "" ->
        requested

      true ->
        Barkpark.Content.default_dataset()
    end
  end

  # ── Referer preference (step 2) ─────────────────────────────────────────
  #
  # Only an authenticated token can express a membership-verified preference;
  # an anonymous request (nil token) has no membership to check, so it skips
  # straight to the fallback.
  defp referer_scope(_conn, nil), do: nil

  defp referer_scope(conn, %ApiToken{} = token) do
    with [referer | _] <- Plug.Conn.get_req_header(conn, "referer"),
         %URI{path: path} = uri when is_binary(path) <- URI.parse(referer),
         true <- same_origin?(conn, uri),
         {ws_slug, proj_slug} <- parse_scope_prefix(path),
         %Workspace{} = ws <- Tenancy.get_workspace_by_slug(ws_slug),
         %Project{} = project <- Tenancy.get_project(ws_slug, proj_slug),
         true <- Tenancy.Auth.member?(token, ws.id) do
      {ws, project}
    else
      _ -> nil
    end
  end

  # A relative Referer (no host) is same-origin by definition. An absolute one
  # counts only when its host matches this request's host — a cross-origin
  # Referer (or garbage that happens to parse a host) is ignored so an attacker
  # can never even nudge scope preference. Membership is still required either
  # way, so this is defence-in-depth, not the auth boundary.
  defp same_origin?(_conn, %URI{host: nil}), do: true
  defp same_origin?(conn, %URI{host: host}), do: host == conn.host

  defp parse_scope_prefix(path) do
    case Regex.run(@scope_prefix, path) do
      [_, ws_slug, proj_slug] -> {ws_slug, proj_slug}
      _ -> nil
    end
  end
end
