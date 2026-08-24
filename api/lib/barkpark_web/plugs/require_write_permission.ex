defmodule BarkparkWeb.Plugs.RequireWritePermission do
  @moduledoc """
  Write-gate for the mutation path. Halts the conn with HTTP 403 unless the
  caller's token carries a write-capable permission ("write" or "admin"),
  BEFORE the request reaches the controller and `Content.apply_mutations`.

  Pipeline: must run AFTER `BarkparkWeb.Plugs.RequireToken` so
  `conn.assigns[:api_token]` is set. Permission satisfaction is delegated to
  `Barkpark.Tenancy.Auth.permits?/2` (the `:write` action ← "write"/"admin").

  This is the enforcement-first slice of the tenancy retrofit. Workspace-scoped
  authorization (`Barkpark.Tenancy.Auth.authorize/3`) landed and is supplied by
  `Plugs.ResolveWorkspace` (`authorize(token_or_user, workspace.id, :read)`) —
  but ONLY on the SCOPED `/w/:workspace_slug/p/:project_slug` pipelines that
  plug runs on. An unscoped `[:api, :require_token, :require_write]` route
  (e.g. `/v1/data/mutate`, `/v1/data/revision/:dataset/:id/restore`, legacy
  `/api/documents`) carries no `ResolveWorkspace` and this plug alone does not
  supply a workspace-membership check either — those routes answer tenancy
  through dataset-scoped `scope_opts` in their controllers instead, a
  different mechanism from workspace-slug membership (see
  arpss-w10-bl-readonly-member-creates-projects, which found and fixed a
  workspace-slug route with neither this plug nor ResolveWorkspace on its
  pipeline: `WorkspaceController.create_project/2`).
  """

  import Plug.Conn
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @doc """
  The assign this plug stamps when — and only when — it GRANTS the write.

  A controller that wants to re-assert "the write gate ran and said yes"
  reads this through `granted?/1` instead of re-deriving the judgment from
  `conn.assigns[:api_token]`. See `granted?/1` for why.
  """
  def granted_assign, do: :write_permission_granted

  def init(opts), do: opts

  def call(conn, _opts) do
    # P5: a scoped-share edit token already proved its right to write THIS scope
    # in RequireShareEditToken (opaque perm + live :edit-share + byte-exact
    # scope). It deliberately holds no global :write perm, so let `share_writer`
    # short-circuit the permits?/2 check. Set ONLY by RequireShareEditToken.
    if conn.assigns[:share_writer] == true do
      grant(conn)
    else
      with %{api_token: token} <- conn.assigns,
           true <- TenancyAuth.permits?(token, :write) do
        grant(conn)
      else
        _ -> account_write?(conn)
      end
    end
  end

  @doc """
  Did THIS plug grant the write on THIS conn?

  ## Why this exists (task-6e22b3922dc42e8c)

  `V1.MediaController` and `V1.MediaCollectionsController` each carried their
  own `require_write/1` that RE-DERIVED this judgment from
  `conn.assigns[:api_token]`. Two implementations of one judgment have to be
  maintained in lockstep, and they had already drifted apart in two ways:

    * **A principal the gate ADMITS, the controller REFUSED.** `call/2` falls
      THROUGH a failing token arm into `account_write?/1`; the controllers
      RETURNED from theirs. So a request carrying a read-only `:api_token`
      alongside a `:current_user` who is a write-capable member of the resolved
      workspace was granted here (account arm) and then answered 403 (media) or
      401 (collections) by the controller — the gate's yes overturned downstream.
    * **Two status codes for one condition.** This plug answers 403 for every
      refusal; the controllers answered 401 from their token-absent arm.

  The controller arms are NOT deleted, because deleting them would make a route
  that ever loses this plug from its pipeline silently writable. They now read
  THIS verdict instead of forming their own. That inverts the failure mode: an
  ungated route has no grant assign, so `granted?/1` is false and the write is
  REFUSED. Fail-closed by construction, and it costs no second `authorize/3`
  query — the account arm's DB read already happened here.

  Every route reaching those controllers' write actions runs this plug today
  (`:media_mutate`, `:scoped_media_mutate`, and `[:scoped_api, :media_mutate]`),
  so no live route changes its answer; what changes is the two divergences above.
  """
  def granted?(%Plug.Conn{} = conn), do: conn.assigns[granted_assign()] == true

  defp grant(conn), do: assign(conn, granted_assign(), true)

  defp forbidden(conn) do
    env = Barkpark.Content.Errors.to_envelope({:error, :forbidden}, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end

  # The ACCOUNT arm (gfr-w1-account-session-bearer-gap). A `user_session`
  # principal carries no api_token, so the token branch above cannot answer for
  # it — and its `with` FAILS CLOSED, which is why the gate arm alone would
  # still have 403'd a legitimate member.
  #
  # Authority comes from the MEMBERSHIP ROLE on the workspace already resolved
  # from the URL, through the same `Tenancy.Auth.authorize/3` every other
  # account-principal check uses. No new role vocabulary: `@builtin_role_actions`
  # already answers this — "admin" => read/write/admin, "member" => read/write —
  # so a plain member writes, a custom role answers from its own rows, and
  # anything else falls through to the 403 below.
  #
  # Fail-closed by construction: a missing user, a missing workspace, or a role
  # without `write` all land on `forbidden/1`.
  defp account_write?(conn) do
    with %Barkpark.Accounts.User{} = user <- conn.assigns[:current_user],
         %{id: ws_id} when is_binary(ws_id) <- conn.assigns[:current_workspace],
         :ok <- TenancyAuth.authorize(user, ws_id, :write) do
      grant(conn)
    else
      _ -> forbidden(conn)
    end
  end
end
