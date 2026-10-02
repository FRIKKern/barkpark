defmodule BarkparkWeb.Plugs.DeriveWorkspaceFromToken do
  @moduledoc """
  Token → workspace derivation for the flat `:media_mutate` pipeline
  (perfect-plan-build, `bpb-flat-media-quota-hole` / charter D14, D30).

  The flat media routes (`/media/*`, `/v1/media/:dataset/*`) carry no
  `/w/:workspace_slug` in the path, so they never run `ResolveWorkspace`. Before
  this plug the pipeline fell straight to `AssignDefaultScope`, which stamps the
  seeded singleton Default Workspace — so every flat media write was attributed
  to (and would be quota-metered against) that ONE workspace regardless of the
  caller's token. That is the documented `bpb-flat-media-quota-hole` (D14).

  `RequireBearerOrSessionToken` runs BEFORE this plug and assigns the full
  `%Barkpark.Auth.ApiToken{}`, so we derive `:current_workspace` from
  `api_token.workspace_id` (D30 — TOKEN-derive, decisively NOT the `dataset`
  slug: a slug is unique only per-project, so a `dataset`→workspace map is
  cross-workspace ambiguous and would force an SDK change). `AssignDefaultScope`
  (next in the pipeline) no-ops once `:current_workspace` is set, so a token that
  carries a workspace lands on its OWN workspace and `RequireWithinQuota` meters
  the flat media write correctly.

  Fail-soft — never halts, never a hard error:

    * `:current_workspace` already set (a resolver ran, or this plug ran on a
      scoped pipeline) → untouched.
    * no `:api_token` assign → untouched (the auth gate ran first; a missing
      token is its problem, not ours).
    * `workspace_id` is nil (a pre-backfill / global token) → untouched, so
      `AssignDefaultScope` keeps today's Default-Workspace behavior — no
      regression on the nil-token path.
    * `workspace_id` matches no row → untouched. The `api_tokens.workspace_id`
      FK is `on_delete: :delete_all`, so no LIVE token points at a dead
      workspace; still fail-soft rather than 500.

  ## The one halt: the token's workspace is ARCHIVED (task-55474a106554e65a)

  An archived workspace is inert but not gone, and its tokens survive the
  archive (nothing is deleted). Fail-soft here would be a TENANT SWAP: the
  plug would leave `:current_workspace` unset and `AssignDefaultScope` would
  stamp the Default workspace, so a token bound to the archived workspace
  would read and write ANOTHER tenant's data. So this arm halts with 409
  `workspace_archived` instead.

  The workspace-management verbs a restore depends on opt out per ROUTE with
  `private: %{barkpark_archived_workspace_exempt: true}` in the
  router (`GET /api/workspaces`, archive, restore) — otherwise RESTORE, called
  with a token bound to the archived workspace, would be refused by the very
  guard it lifts.
  """

  import Plug.Conn

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Workspace

  def init(opts), do: opts

  # A resolver (or a prior run) already set the scope — leave it alone.
  def call(%Plug.Conn{assigns: %{current_workspace: ws}} = conn, _opts)
      when not is_nil(ws),
      do: conn

  # task-e816e87770cd69ce: an OWNER-BOUND token with no workspace is a PAT a
  # user minted while a member of nothing (`AuthController` resolves
  # `{nil, nil}` and `Auth.create_personal_access_token/3` mints it
  # workspace-less ON PURPOSE — see access_token_identity_test case 10). The
  # nil-workspace fall-through below exists for PRE-TENANCY GLOBAL tokens, which
  # carry no owner. Letting an owner-bound one through made
  # `AssignDefaultScope` stamp the Default workspace, so anyone who could sign
  # up read Default's documents, drafts, exports and task ledger on every flat
  # route. It is refused here exactly as the scoped route refuses it (403, not
  # a member), UNLESS its owner may read Default anyway: a Default member, or a
  # GRANTEE whose active read grant covers Default (the flat routes then narrow
  # them via `AssignGrantScope`, as before).
  def call(
        %Plug.Conn{assigns: %{api_token: %ApiToken{workspace_id: nil, owner_user_id: uid}}} = conn,
        _opts
      )
      when is_binary(uid) do
    cond do
      conn.private[workspaceless_ok_key()] == true -> conn
      owner_may_read_default?(uid) -> conn
      true -> refuse_no_workspace(conn)
    end
  end

  def call(conn, _opts) do
    with %ApiToken{workspace_id: ws_id} when is_binary(ws_id) <- conn.assigns[:api_token],
         %Workspace{} = ws <- Tenancy.get_workspace_by_id(ws_id) do
      if Workspace.archived?(ws) and not archived_workspace_exempt?(conn) do
        refuse_archived(conn, ws)
      else
        assign(conn, :current_workspace, ws)
      end
    else
      _ -> conn
    end
  end

  @doc "The route-private key that exempts a workspace-management route from the archive halt."
  def archived_ok_key, do: :barkpark_archived_workspace_exempt

  @doc """
  The route-private key that lets an owner-bound, workspace-less token through
  (the `/api/workspaces` switcher/create scope, which does its own membership
  reasoning and never reads Default).
  """
  def workspaceless_ok_key, do: :barkpark_workspaceless_token_allowed

  defp archived_workspace_exempt?(conn), do: conn.private[archived_ok_key()] == true

  defp owner_may_read_default?(uid) do
    with %Workspace{id: default_id} <- Tenancy.get_default_workspace(),
         %Barkpark.Accounts.User{} = user <- Barkpark.Accounts.get_user(uid) do
      Barkpark.Tenancy.Auth.authorize(user, default_id, :read) == :ok or
        BarkparkWeb.Plugs.AssignGrantScope.grant_covers_read?(user, default_id)
    else
      # No Default seeded: AssignDefaultScope stamps nothing, so there is
      # nothing to leak. A vanished owner reads nothing.
      nil -> is_nil(Tenancy.get_default_workspace())
    end
  end

  defp refuse_no_workspace(conn) do
    env = Barkpark.Content.Errors.to_envelope({:error, :forbidden_membership}, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end

  defp refuse_archived(conn, ws) do
    env = Barkpark.Content.Errors.to_envelope({:error, {:workspace_archived, ws.slug}}, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end
end
