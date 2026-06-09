defmodule BarkparkWeb.Plugs.RequireShareScope do
  @moduledoc """
  Public-share gate for a scoped tenant surface.

  This plug is the ONLY mechanism that can turn a normally membership-gated
  `/w/:workspace_slug/p/:project_slug/…` route into an anonymous-readable one,
  and it does so STRICTLY and DEFAULT-OFF:

    * It consults `Barkpark.Sharing.shared?/4` for the
      `(workspace_slug, project_slug, dataset, surface)` of the request. The
      surface is fixed per route via `init/1` opts (`surface: :papers | :docs |
      :media`).
    * If — and ONLY if — that scope is shared for the surface, the request is
      METHOD- and ACCESS-appropriate (see below), AND both the workspace and
      the project resolve to REAL tenant rows, the plug resolves them itself,
      assigns `:current_workspace` / `:current_project`, and marks
      `:share_public = true`. Downstream `ResolveWorkspace` sees that flag and
      SKIPS its membership-authorize gate (the bypass), so an anonymous caller
      reads the shared scope.

  ## Method + access awareness (the read-vs-write gate)

  A share carries an access level (`:read` or `:edit`, via
  `Barkpark.Sharing.access_for/3`). The grant is METHOD-aware so a read-only
  share can NEVER open a write:

    * On a SAFE-READ method (`GET` / `HEAD`) the grant fires whenever the scope
      is shared for the surface, regardless of access level — a `:read` share
      is enough to read.
    * On any UNSAFE method (`POST` / `PUT` / `PATCH` / `DELETE`, etc.) the grant
      fires ONLY when the share's access is `:edit`. A `:read` share on an
      unsafe method is NOT granted: the plug no-ops and the normal membership
      gate runs and denies the anonymous caller.

  This is what makes the `:docs` surface safe to mount on a pipeline that also
  carries the mutate route: a `:docs:read` share opens the GET query/doc reads
  but leaves the POST mutate gated, because the mutate's unsafe method fails the
  `:edit`-only branch. The existing `:papers` reader is GET-only, so it always
  takes the safe-read branch and its behaviour is unchanged.
    * In EVERY other case — no shares configured, a non-matching scope, the
      surface not shared, a missing/garbage slug param, or a shared scope whose
      slug does NOT resolve to a real workspace/project — the plug DOES NOTHING
      and returns the conn UNCHANGED. The normal pipeline then runs:
      `ResolveWorkspace` enforces its membership gate exactly as today, so a
      non-member is gated (404/403) byte-identically to a normal scoped request.

  Security invariants (must never regress):

    * **Default-OFF.** With no `:shares` configured, `Sharing.shared?/4` is
      always `false`, so this plug is a pure no-op and behaviour is unchanged
      everywhere.
    * **Default-DENY / fail-closed.** A share grant is honoured ONLY when the
      scope is an EXACT match (enforced by `Sharing.shared?/4`) AND resolves to
      real rows. A grant for a workspace/project slug that does not exist is
      treated as NOT shared — never granted, never raised.
    * **No grant on garbage.** A nil or non-binary slug param can never match a
      share, so the plug no-ops and the membership gate runs.

  Pipeline placement: runs BEFORE `BarkparkWeb.Plugs.ResolveWorkspace` (and
  `ResolveProject`). It only ever ADDS assigns on the public-share path; it
  never halts. The non-shared path leaves the conn assigns identical to what a
  plain scoped request carries on entry to `ResolveWorkspace`.
  """

  import Plug.Conn

  alias Barkpark.Sharing
  alias Barkpark.Tenancy

  @default_dataset "production"

  # The HTTP methods a read-only (`:read`) share is allowed to serve. Anything
  # outside this set requires an `:edit` share (see `grant_if_resolvable/4`).
  @safe_read_methods ~w(GET HEAD)

  @doc """
  `init/1` validates the `:surface` opt at compile time. It MUST be one of the
  legal `Barkpark.Sharing` surfaces; anything else raises at compile/boot so a
  miswired route fails loudly rather than silently never-sharing.
  """
  @spec init(keyword()) :: %{surface: Sharing.Share.surface()}
  def init(opts) do
    surface = Keyword.fetch!(opts, :surface)

    unless surface in Sharing.surfaces() do
      raise ArgumentError,
            "RequireShareScope :surface must be one of #{inspect(Sharing.surfaces())}, " <>
              "got #{inspect(surface)}"
    end

    %{surface: surface}
  end

  @spec call(Plug.Conn.t(), %{surface: Sharing.Share.surface()}) :: Plug.Conn.t()
  def call(conn, %{surface: surface}) do
    ws_slug = conn.path_params["workspace_slug"]
    project_slug = conn.path_params["project_slug"]
    dataset = conn.path_params["dataset"] || @default_dataset

    # `Sharing.shared?/4` is strict default-deny: a nil/garbage slug, an
    # unconfigured registry, or a non-matching scope all return false, and it
    # never raises. Only a true result even considers granting.
    if Sharing.shared?(ws_slug, project_slug, dataset, surface) do
      grant_if_resolvable(conn, ws_slug, project_slug, dataset)
    else
      conn
    end
  end

  # A share matched the scope — but a grant only fires when (a) the request is
  # method/access-appropriate (a `:read` share serves only safe-read methods;
  # an unsafe method needs an `:edit` share) AND (b) the workspace/project
  # resolve to real rows (a grant for a non-existent scope must NOT open the
  # route — fail-closed). When either guard fails, leave the conn untouched so
  # the normal membership gate runs and denies the anonymous caller.
  defp grant_if_resolvable(conn, ws_slug, project_slug, dataset) do
    if method_access_allows?(conn, ws_slug, project_slug, dataset) do
      with %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(ws_slug),
           %Tenancy.Project{} = project <- Tenancy.get_project(ws_slug, project_slug) do
        conn
        |> assign(:current_workspace, workspace)
        |> assign(:current_project, project)
        |> assign(:share_public, true)
        |> assign(:share_access, Sharing.access_for(ws_slug, project_slug, dataset))
      else
        _ -> conn
      end
    else
      conn
    end
  end

  # The read-vs-write gate. A safe-read method (GET/HEAD) is always allowed for
  # a shared surface, regardless of access level. Any unsafe method (POST/PUT/
  # PATCH/DELETE/…) is allowed ONLY when the share grants `:edit`. This is the
  # invariant that keeps a `:docs:read` share from ever opening the mutate route.
  defp method_access_allows?(conn, ws_slug, project_slug, dataset) do
    conn.method in @safe_read_methods or
      Sharing.access_for(ws_slug, project_slug, dataset) == :edit
  end
end
