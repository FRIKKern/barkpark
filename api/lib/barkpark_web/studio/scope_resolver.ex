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
  3. **Session / first-membership fallback** — the principal's first
     slug-ordered membership workspace (anonymous → the seeded Default
     workspace), then that workspace's Default project (else its first
     project). For an ACCOUNT principal the seeded Default is *demoted* below
     any other membership — see `resolve_workspace/1`.

  ## Principals: a token OR an account (gfr-w1-studio-principal-kind)

  The principal is `%ApiToken{}` **or** `%Accounts.User{}` or `nil`. That is
  not cosmetic: `OptionalSessionToken` assigns `:current_user` (NOT
  `:api_token`) for an account session, so callers that read only
  `conn.assigns[:api_token]` handed this module `nil` for every signed-in
  account and got `Tenancy.get_default_workspace()` back — Gyldendal's field
  report #34: an editor who is a member of exactly one workspace was 302'd
  into Default and then truthfully told the document did not exist there.
  Callers must derive the principal with `principal/1`, never by reaching for
  one assign.

  Callers must always 302 (never 301): the target depends on the token +
  Referer, so it must never be browser-cached across users.
  """

  alias Barkpark.Accounts.User
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.{Project, Workspace}

  @scope_prefix ~r{^/w/([^/]+)/p/([^/]+)(?:/|$)}

  @typedoc """
  Who is asking. A token session, an ACCOUNT session (`user_session` →
  `:current_user`), or anonymous.
  """
  @type principal :: ApiToken.t() | User.t() | nil

  @doc """
  The scope principal for this conn — the ONE place the two session kinds are
  reconciled. A token wins when both are present (it is the narrower,
  explicitly-presented credential, and `OptionalSessionToken` already gives it
  precedence); otherwise the account session's `%User{}`; otherwise `nil`.

  Every flat→scoped caller must go through here. Reading
  `conn.assigns[:api_token]` directly is what teleported every account session
  to Default (field report #34).
  """
  @spec principal(Plug.Conn.t()) :: principal()
  def principal(%Plug.Conn{assigns: assigns}), do: principal_from_assigns(assigns)

  @doc """
  The same precedence rule, for an assigns map that is NOT on a conn — a
  LiveView socket's. `StudioChrome`'s scope switcher needs exactly this and
  must not re-encode the rule: two copies of "token wins over user" drift, and
  a switcher that disagrees with the funnel is #34's second half all over
  again.
  """
  @spec principal_from_assigns(map()) :: principal()
  def principal_from_assigns(assigns) when is_map(assigns),
    do: assigns[:api_token] || assigns[:current_user]

  @doc """
  Resolve `{:ok, workspace, project}` for a flat Studio URL, or `:error` when
  no workspace/project is resolvable (the caller redirects to `/login`).

  `principal` comes from `principal/1` — an `%ApiToken{}`, a `%User{}`
  (account session), or `nil` (anonymous). The Referer is read from `conn` and
  used only as a membership-verified scope preference; see the module doc for
  the full order.
  """
  # @canonical capability:studio-scope-resolution aka:teleport,referer,flat-scoped,resolve_workspace
  @spec resolve_scope(Plug.Conn.t(), principal()) ::
          {:ok, Workspace.t(), Project.t()} | :error
  def resolve_scope(conn, principal) do
    case referer_scope(conn, principal) do
      {%Workspace{} = ws, %Project{} = project} ->
        {:ok, ws, project}

      nil ->
        with %Workspace{} = ws <- resolve_workspace(principal),
             %Project{} = project <- resolve_project(ws) do
          {:ok, ws, project}
        else
          _ -> :error
        end
    end
  end

  @doc """
  The session / first-membership workspace fallback (step 3): the principal's
  first slug-ordered membership workspace, else the seeded Default. `nil`
  principal (anonymous) → the Default workspace.

  ## The preference rule, stated (gfr-w1-studio-principal-kind)

  For an ACCOUNT principal the seeded **Default workspace is demoted**: the
  first slug-ordered membership that is NOT Default wins, and Default answers
  only when it is the principal's only membership.

  Threading the `%User{}` through without this rule is NOT enough, which is why
  the rule lives here rather than at the call sites. A cloud/SSO account is
  auto-granted a Default membership by
  `SessionController.ensure_default_owner_membership/1` — the user never chose
  it, the handoff issued it — and `"default"` sorts ahead of most real slugs,
  so bare list order would still land Gyldendal's editor (member of
  `gyl-b-…`) in Default. A membership someone was actually invited into
  outranks one the system minted for them. The Referer preference (step 2)
  still wins over this whenever the request came from inside a workspace.

  The TOKEN arm deliberately keeps plain first-slug order: it is the
  pre-existing contract (pinned by `scoped_studio_mount_test.exs`), tokens are
  minted per-purpose rather than auto-granted, and #34 is an account-session
  defect. Widening the demotion to tokens is a separate, deliberate change.
  """
  @spec resolve_workspace(principal()) :: Workspace.t() | nil
  def resolve_workspace(nil), do: Tenancy.get_default_workspace()

  def resolve_workspace(%User{} = user) do
    user
    |> Tenancy.list_workspaces_for()
    |> prefer_non_default()
    |> case do
      %Workspace{} = ws -> ws
      nil -> Tenancy.get_default_workspace()
    end
  end

  def resolve_workspace(token) do
    case Tenancy.list_workspaces_for(token) do
      [ws | _] -> ws
      _ -> Tenancy.get_default_workspace()
    end
  end

  defp prefer_non_default([]), do: nil

  defp prefer_non_default(workspaces) do
    default_id =
      case Tenancy.get_default_workspace() do
        %Workspace{id: id} -> id
        _ -> nil
      end

    Enum.find(workspaces, &(&1.id != default_id)) || List.first(workspaces)
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
  # Only an authenticated principal can express a membership-verified
  # preference; an anonymous request (nil) has no membership to check, so it
  # skips straight to the fallback. Both principal kinds qualify —
  # `Tenancy.Auth.member?/2` discriminates `%ApiToken{}` from `%User{}` by
  # `principal_type`, so an account session's Referer preference is verified
  # exactly as strictly as a token's.
  defp referer_scope(_conn, nil), do: nil

  defp referer_scope(conn, principal)
       when is_struct(principal, ApiToken) or is_struct(principal, User) do
    with [referer | _] <- Plug.Conn.get_req_header(conn, "referer"),
         %URI{path: path} = uri when is_binary(path) <- URI.parse(referer),
         true <- same_origin?(conn, uri),
         {ws_slug, proj_slug} <- parse_scope_prefix(path),
         %Workspace{} = ws <- Tenancy.get_workspace_by_slug(ws_slug),
         %Project{} = project <- Tenancy.get_project(ws_slug, proj_slug),
         true <- Tenancy.Auth.member?(principal, ws.id) do
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
