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

  defp archived_workspace_exempt?(conn), do: conn.private[archived_ok_key()] == true

  defp refuse_archived(conn, ws) do
    env = Barkpark.Content.Errors.to_envelope({:error, {:workspace_archived, ws.slug}}, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end
end
