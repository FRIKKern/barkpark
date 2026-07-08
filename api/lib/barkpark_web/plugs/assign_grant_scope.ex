defmodule BarkparkWeb.Plugs.AssignGrantScope do
  @moduledoc """
  Grant-fold companion for the FLAT (back-compat) `/v1/data` READ routes
  (airdrop-grants ag-enforcement — flat-routes arm).

  The scoped `/w/:ws/p/:project` reads run the grant arm inside
  `BarkparkWeb.Plugs.ResolveWorkspace`. The flat routes never touch that
  resolver: `AssignDefaultScope` infers the seeded Default workspace but does
  NO membership/grant reasoning (it stays pure). This plug is the flat-path
  twin of ResolveWorkspace's grant arm — run AFTER `AssignDefaultScope` (which
  set `:current_workspace`) and AFTER `ResolveTokenOwner` (which resolved an
  OWNED api_token to its owner `:current_user`), it admits an owned-token
  grantee as a GRANT-DERIVED caller so `ScopeHelpers` threads Layer-2 row
  narrowing into the read.

  ## Fail-closed + containment

  Membership FIRST, unchanged: if the token OR the user is a Default-workspace
  member, this plug is a NO-OP — members (and unowned/service tokens, which
  yield no user) read byte-identical to before, and NEVER carry the grant flag.
  Only a non-member USER with an ACTIVE grant COVERING the Default workspace is
  admitted, as a grant-bearing `CallerContext` + the `:grant_scoped_read` flag;
  `Content.Scope.scope_to_grants/3` (Layer 2) then does the per-request
  containment, narrowing every read to the UNION of that user's grant ladders
  and failing CLOSED (`where: false`) on any dataset/type the grants don't
  cover. A non-member user with NO covering grant is left untouched (reads as
  today — the owned token keeps its back-compat Default read).

  ### Why COVERAGE, not `Access.validate/3`, is the admission test here

  `ResolveWorkspace`'s scoped-route arm calls `Access.validate(grant, :read,
  %{workspace_id})`, whose `scope_contained?` treats a bare-workspace request as
  an ESCAPE and DENIES any grant with a non-NULL sub-level (project/dataset/
  type). On the SCOPED routes a non-admitted grantee 403s (safe). But the FLAT
  path has NO membership gate — a non-admitted owned token falls through to the
  full back-compat Default read, so copying that strict admission would leak the
  WHOLE workspace to a dataset-scoped grantee (fail-OPEN). So admission is at
  workspace-COVERAGE granularity (the same `grant.workspace_id == ws` test
  `scope_to_grants` uses for `covers_workspace?`): a sub-scoped grantee IS
  flagged and Layer-2-narrowed to their exact ladder, which is fail-CLOSED.
  Active/expiry/revocation/single-use are already enforced in-query by
  `CallerContext.from_user/2`; capability is the `"read" in caps` check
  `Access` applies.

  ## Blast-radius containment — READ routes ONLY

  Mounted ONLY on the flat `/v1/data` read scope (query/doc/backlinks/search),
  NEVER on the shared `:api` pipeline. `CallerContext.from_conn/1` prefers an
  assigned `:caller_context` over an `:api_token`, so setting it on a WRITE or
  admin route could DOWNGRADE the caller. Keeping this plug off write/admin/
  auth/plugin routes is the guarantee that no write path is affected.

  Never halts: no Default seeded, no token, an unowned token, or no covering
  grant all pass the conn through unchanged.
  """

  import Plug.Conn

  alias Barkpark.Accounts.User
  alias Barkpark.Content.CallerContext
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  def init(opts), do: opts

  def call(conn, _opts) do
    workspace = conn.assigns[:current_workspace]
    token = conn.assigns[:api_token]
    user = conn.assigns[:current_user]

    # Only ever narrows a non-member owned-token grantee on the Default flat
    # path. Anything else is a pass-through.
    if is_map(workspace) and match?(%User{}, user) and not member?(token, user, workspace.id) do
      case grant_read_ctx(user, workspace.id) do
        %CallerContext{} = ctx ->
          conn
          |> assign(:caller_context, ctx)
          |> assign(:grant_scoped_read, true)

        _ ->
          conn
      end
    else
      conn
    end
  end

  # MEMBERSHIP first, unchanged — a member's decision (token OR user role) is
  # byte-identical to before and NEVER carries the grant flag.
  defp member?(token, %User{} = user, workspace_id) do
    TenancyAuth.authorize(token, workspace_id, :read) == :ok or
      TenancyAuth.authorize(user, workspace_id, :read) == :ok
  end

  # Build a grant-bearing CallerContext for `user` and admit it ONLY if some
  # ACTIVE grant COVERS this workspace with a read capability. Returns the ctx
  # (Layer-2 `scope_to_grants` narrows the actual rows) or nil. Fail-closed: no
  # covering grant → nil. from_user/2 already filters to ACTIVE grants (not
  # revoked/expired, single-use not spent) in-query.
  defp grant_read_ctx(%User{id: uid}, workspace_id) when is_binary(uid) do
    ctx = CallerContext.from_user(uid)

    if Enum.any?(ctx.grants, &covers_workspace_read?(&1, workspace_id)) do
      ctx
    end
  end

  defp grant_read_ctx(_user, _workspace_id), do: nil

  # Coverage test mirroring `Content.Scope.covers_workspace?/2` (the same gate
  # Layer-2 narrowing keys on) plus the `"read" in caps` capability check
  # `Barkpark.Access` applies — so admission and row-narrowing agree on which
  # grants count.
  defp covers_workspace_read?(%{workspace_id: ws, capabilities: caps}, workspace_id)
       when is_list(caps),
       do: ws == workspace_id and "read" in caps

  defp covers_workspace_read?(_grant, _workspace_id), do: false
end
