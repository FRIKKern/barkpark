defmodule BarkparkWeb.Plugs.RequireShareEditToken do
  @moduledoc """
  WRITE counterpart of `BarkparkWeb.Plugs.RequireShareScope` (P5).

  Where `RequireShareScope` opens an ANONYMOUS read of a shared scope,
  this plug opens a SCOPED WRITE — but ONLY to a holder of a valid, scope-bound
  edit token. It never grants on an anonymous request: writes always require a
  presented token (the owner's hard constraint — no unauthenticated LAN writes).

  Placement: AFTER a token-resolving plug (`OptionalToken` /
  `RequireBearerOrSessionToken`) so `conn.assigns[:api_token]` is populated, and
  BEFORE `ResolveWorkspace`. The grant fires ONLY when ALL hold:

    * a token is present and carries the OPAQUE `"share-edit-<surface>"`
      permission for this route's surface (set via `init/1`);
    * the token's `share_scope` byte-equals the request `"ws/proj/dataset"`;
    * the registry STILL has that scope `:edit`-shared for the surface
      (`Sharing.shared?/4` + `Sharing.access_for/3` — a live kill-switch: drop or
      downgrade the share and every token goes inert on the next request, before
      revocation);
    * the workspace + project resolve to real rows.

  On a grant it pre-resolves + assigns `:current_workspace` / `:current_project`,
  sets `:share_public = true` (so `ResolveWorkspace` SKIPS its membership gate)
  and `:share_writer = true` (so `RequireWritePermission` passes without the
  token holding a global `:write` perm). In EVERY other case it returns the conn
  UNCHANGED, so the normal pipeline runs: a member writes via membership as
  today, and an anonymous / wrong-scope caller is denied by `ResolveWorkspace`.
  It never halts.

  Why opaque permissions + no membership (the load-bearing decision): the flat
  `POST /v1/data/mutate/:dataset` route authorizes on write-permission ALONE
  (no membership gate), so a token holding `"write"` could mutate the Default
  workspace there with no scope binding. Keeping the permission opaque and the
  token member-less means it satisfies no global tier and is inert on the flat
  route and on every normal scoped route — it can ONLY act through this plug.
  """

  import Plug.Conn

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Sharing
  alias Barkpark.Tenancy

  @default_dataset "production"

  @spec init(keyword()) :: %{surface: Sharing.Share.surface()}
  def init(opts) do
    surface = Keyword.fetch!(opts, :surface)

    unless surface in Sharing.surfaces() do
      raise ArgumentError,
            "RequireShareEditToken :surface must be one of #{inspect(Sharing.surfaces())}, " <>
              "got #{inspect(surface)}"
    end

    %{surface: surface}
  end

  @spec call(Plug.Conn.t(), %{surface: Sharing.Share.surface()}) :: Plug.Conn.t()
  def call(conn, %{surface: surface}) do
    conn = fetch_query_params(conn)
    token = conn.assigns[:api_token]
    ws = conn.path_params["workspace_slug"]
    proj = conn.path_params["project_slug"]
    dataset = request_dataset(conn)

    if grant?(token, surface, ws, proj, dataset) do
      grant_if_resolvable(conn, ws, proj, dataset)
    else
      conn
    end
  end

  # Every condition must hold. Fail-closed: a nil/garbage slug, an absent token,
  # a scope mismatch, or a share that is no longer :edit all yield false.
  defp grant?(token, surface, ws, proj, dataset) do
    # Ticket-key audit (Barkpark Tickets, charter Decision 1): `token` here is
    # already `verify_token/1`-filtered to `kind == "api"` (OptionalToken /
    # RequireBearerOrSessionToken set the assign), so a ticket key never
    # reaches this plug as an %ApiToken{}. This explicit `kind == "api"` check
    # is belt-and-suspenders — a ticket key must never satisfy an edit-share.
    is_binary(ws) and is_binary(proj) and is_binary(dataset) and
      match?(%ApiToken{}, token) and
      token.kind == "api" and
      "share-edit-#{surface}" in (token.permissions || []) and
      token.share_scope == "#{ws}/#{proj}/#{dataset}" and
      Sharing.shared?(ws, proj, dataset, surface) and
      Sharing.access_for(ws, proj, dataset) == :edit
  end

  # The dataset the REQUEST actually resolves to — read the same way
  # `BarkparkWeb.Plugs.RequireShareScope.request_dataset/1` reads it, and for
  # the same reason: a guard that reads the PATH while the controller derives
  # from the MERGED params (path over query string) is checking a value the
  # request never uses. Every route currently on the two `:scoped_*_mutate`
  # pipelines carries a `:dataset` path segment, so this is byte-identical
  # today; it exists so that adding a dataset-LESS write route to those
  # pipelines cannot silently reopen task-4f26838232b5ece0 on the write side.
  # Path wins the merge in Phoenix, so it wins here — a decoy `?dataset=` on
  # `/v1/data/mutate/:dataset` never moves the `share_scope` comparison.
  @spec request_dataset(Plug.Conn.t()) :: binary()
  defp request_dataset(conn) do
    case conn.path_params["dataset"] || conn.query_params["dataset"] do
      ds when is_binary(ds) -> ds
      _ -> @default_dataset
    end
  end

  defp grant_if_resolvable(conn, ws, proj, _dataset) do
    with %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(ws),
         %Tenancy.Project{} = project <- Tenancy.get_project(ws, proj) do
      conn
      |> assign(:current_workspace, workspace)
      |> assign(:current_project, project)
      |> assign(:share_public, true)
      |> assign(:share_access, :edit)
      |> assign(:share_writer, true)
    else
      _ -> conn
    end
  end
end
