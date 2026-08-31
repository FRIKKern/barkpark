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
    * **The guard reads the dataset the READ will read.** The dataset comes from
      `request_dataset/1`, which resolves it exactly the way the controllers do
      (path segment, else query string, else the default) — see that function.
      Comparing a path-only dataset while the controller went on to derive a
      query-string one is the "guard before derivation" split that let
      `?dataset=` escape the share (task-4f26838232b5ece0).

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
    conn = fetch_query_params(conn)
    ws_slug = conn.path_params["workspace_slug"]
    project_slug = conn.path_params["project_slug"]
    dataset = request_dataset(conn)

    # An AUTHENTICATED caller never takes the share grant: a verified token
    # (assigned by OptionalToken, which runs before this plug in every
    # pipeline that mounts it) means the normal membership gate decides
    # access — with full drafts/raw visibility for a member. Without this
    # guard, creating a `:read` share silently DOWNGRADED the scope's own
    # members on these routes: `read_share?/1` pinned their reads to the
    # published perspective and 404'd every `drafts.` doc-id (found live
    # 2026-06-10 — the TUI lost all drafts the moment a share existed). An
    # invalid/revoked token gets no :api_token assign, so it still reads at
    # anonymous share grade.
    #
    # `Sharing.shared?/4` is strict default-deny: a nil/garbage slug, an
    # unconfigured registry, or a non-matching scope all return false, and it
    # never raises. Only a true result even considers granting.
    cond do
      not is_nil(conn.assigns[:api_token]) ->
        conn

      Sharing.shared?(ws_slug, project_slug, dataset, surface) ->
        grant_if_resolvable(conn, ws_slug, project_slug, dataset)

      true ->
        # P4 (Scoped-by-URL): `?share=<item-token>` on a SCOPED route.
        # Capability never changes the URL — the same canonical address
        # serves a member, a section-share grantee, or an item-token
        # holder. The grant fires ONLY when the link's stored scope
        # (workspace/project ids + dataset) equals the URL's resolved
        # scope AND the link's bound resource equals the route's
        # single-resource param — a token for another scope or another
        # doc leaves the conn untouched (the membership gate then denies;
        # no existence oracle).
        maybe_grant_item_token(conn, ws_slug, project_slug, dataset)
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
        |> assign(:share_grant, :section)
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

  # ── The dataset the REQUEST actually resolves to ────────────────────────────
  #
  # NOT `path_params["dataset"]`. Three share-reachable routes carry NO
  # `:dataset` path segment — `/w/:ws/p/:proj/papers/:slug/source`,
  # `…/papers/:slug/email` and the `…/media` block — and their controllers
  # derive the dataset from the MERGED params, i.e. from the QUERY STRING
  # (`BulldocsSourceController.requested_dataset/1`,
  # `BulldocsEmailController.requested_dataset/1`,
  # `MediaController.index/2` + `render_file/2`). Reading only the path made
  # this guard compare `"production"` while the controller went on to read
  # `?dataset=staging`: a share minted for one dataset served another
  # (task-4f26838232b5ece0). The guard must read the value the DERIVATION will
  # read, or it is not guarding the read that happens.
  #
  # Precedence mirrors Phoenix exactly: on a `/d/:dataset/…` route the path
  # segment wins the params merge, so it wins here too and a decoy
  # `?dataset=` changes nothing. The `is_binary` clamp mirrors the same soft
  # fail-to-default the paper controllers apply, so `?dataset[]=x` (which
  # decodes to a list) resolves to the same value on both sides.
  @spec request_dataset(Plug.Conn.t()) :: binary()
  defp request_dataset(conn) do
    case conn.path_params["dataset"] || conn.query_params["dataset"] do
      ds when is_binary(ds) -> ds
      _ -> @default_dataset
    end
  end

  # ── P4: item-token grant (?share=<token>) ──────────────────────────────────

  defp maybe_grant_item_token(conn, ws_slug, project_slug, dataset) do
    with raw when is_binary(raw) and raw != "" <- conn.query_params["share"],
         # Item links are read capabilities — never an unsafe method.
         true <- conn.method in @safe_read_methods,
         {:ok, link} <- Barkpark.Sharing.Links.resolve(raw),
         %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(ws_slug),
         %Tenancy.Project{} = project <- Tenancy.get_project(ws_slug, project_slug),
         true <- link.workspace_id == workspace.id,
         true <- link.project_id == project.id,
         true <- link.dataset == dataset,
         true <- link_matches_route_resource?(link, conn.path_params) do
      conn
      |> assign(:current_workspace, workspace)
      |> assign(:current_project, project)
      |> assign(:share_public, true)
      |> assign(:share_access, :read)
      |> assign(:share_grant, :item)
      |> strip_item_grant_walk_params()
    else
      _ -> conn
    end
  end

  # An item grant is confined to the ONE resource it is bound to
  # (`link_matches_route_resource?/2` above). `query_controller`'s `?expand=`
  # and `?resolve=tasks` both walk OUTWARD from the bound doc — expand follows
  # its references, resolve=tasks runs a scope-wide task query — so either
  # param would let a leaked item link read documents it was never minted for.
  # A `:section` grant has no such confinement (the whole scope is already
  # readable), so only the `:item` grant strips these.
  #
  # STRIP, not a 403: a 403 would BREAK a reader's link the moment a paper
  # happens to carry a reference or a task-list block — collateral damage for
  # a param the reader never asked for. Stripping instead degrades silently to
  # exactly the bound document, which is everything the link ever promised.
  # Both `conn.params` (what the controller action pattern-matches against)
  # AND `conn.query_params` (what a re-fetch or a downstream plug would see)
  # are dropped, so neither copy of the param survives to the controller.
  @strippable_walk_params ~w(expand resolve)

  defp strip_item_grant_walk_params(conn) do
    %{
      conn
      | params: Map.drop(conn.params, @strippable_walk_params),
        query_params: Map.drop(conn.query_params, @strippable_walk_params)
    }
  end

  # An item link is bound to ONE resource; it only opens a route addressing
  # exactly that resource. Paper reader → slug; doc read → doc_id (compared
  # exactly as minted); media meta/renditions → file id. Routes without a
  # single-resource param (lists, file paths) never item-grant.
  defp link_matches_route_resource?(link, %{"slug" => slug}),
    do: link.kind == "doc" and link.ref_type == "paper" and link.ref_id == slug

  defp link_matches_route_resource?(link, %{"doc_id" => doc_id}),
    do: link.kind == "doc" and link.ref_id == doc_id

  defp link_matches_route_resource?(link, %{"id" => id}),
    do: link.kind == "media" and link.ref_id == id

  defp link_matches_route_resource?(_link, _path_params), do: false
end
