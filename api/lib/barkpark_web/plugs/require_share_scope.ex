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
    * If — and ONLY if — that scope is shared for the surface AND both the
      workspace and the project resolve to REAL tenant rows, the plug resolves
      them itself, assigns `:current_workspace` / `:current_project`, and marks
      `:share_public = true`. Downstream `ResolveWorkspace` sees that flag and
      SKIPS its membership-authorize gate (the bypass), so an anonymous caller
      reads the shared scope.
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
      grant_if_resolvable(conn, ws_slug, project_slug)
    else
      conn
    end
  end

  # A share matched the scope — but a share grant for a non-existent
  # workspace/project must NOT open the route (fail-closed). Resolve both rows
  # here; only if BOTH resolve do we assign the scope + the bypass flag.
  # Otherwise leave the conn untouched so the membership gate runs and denies.
  defp grant_if_resolvable(conn, ws_slug, project_slug) do
    with %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(ws_slug),
         %Tenancy.Project{} = project <- Tenancy.get_project(ws_slug, project_slug) do
      conn
      |> assign(:current_workspace, workspace)
      |> assign(:current_project, project)
      |> assign(:share_public, true)
    else
      _ -> conn
    end
  end
end
