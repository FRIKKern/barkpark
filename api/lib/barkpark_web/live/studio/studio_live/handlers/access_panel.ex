defmodule BarkparkWeb.Studio.StudioLive.Handlers.AccessPanel do
  @moduledoc """
  The **Access panel** (airdrop-grants endgame, slice 3 UI) — an honest,
  live-active view of scoped access, the read/revoke sibling of the grantor-
  facing `Handlers.Airdrop` mint sheet.

  Two sections, two data sources — ZERO new query paths:

    * **Your access** — the caller's OWN inbound grants, straight from the
      `:access_grants` assign (`Access.list_active_grants_for_grantee/1`, loaded
      + expiry-refreshed by `StudioLive`). Each grant shows its scope, the
      capabilities it confers, and a live countdown chip. Nothing loaded here.
    * **Active grants in this workspace** — `Access.list_grants_for_workspace/1`,
      loaded on open ONLY when the caller is authorized to READ the workspace
      (the SAME gate `BarkparkWeb.AccessController.index/2` applies:
      `Tenancy.Auth.authorize(principal, ws_id, :read)`). A non-member grantee
      gets `[]` + `access_workspace_view: false`, so the section is hidden and
      they see only their own access.

  ## Revoke — server-authorized, idempotent

  `access-revoke` calls `Access.revoke/2`, which UUID-guards the id and
  re-authorizes GRANTOR-OR-ADMIN server-side — the Caps `:write` gate is only a
  first cosmetic filter, never the boundary. A member who is neither the grantor
  nor an admin gets `{:error, :forbidden}` → an inline error, and NO grant is
  revoked (the deny path). A revoked grant vanishes from the workspace list on
  the immediate re-list (it fails the in-query `active_where`): the panel is a
  live-active view, not a history log.

  A LiveComponent is deliberately NOT used — like `airdrop_sheet`, the panel is
  a function component reading PARENT-process assigns (`:access_grants` is a
  parent assign; a LiveComponent boundary would not carry it).
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Barkpark.Access
  alias Barkpark.Tenancy.Auth

  @doc """
  Open the panel. Loads the workspace section (membership-gated) and clears any
  stale error. The "Your access" section reads the existing `:access_grants`
  assign, so nothing is loaded for it.
  """
  def access_open(socket) do
    {grants, workspace_view} = workspace_grants(socket)

    {:noreply,
     assign(socket,
       access_open: true,
       access_workspace_grants: grants,
       access_workspace_view: workspace_view,
       access_error: nil
     )}
  end

  @doc "Close the panel and clear any inline error."
  def access_close(socket) do
    {:noreply, assign(socket, access_open: false, access_error: nil)}
  end

  @doc """
  Revoke a workspace grant by id. Server-authorized by `Access.revoke/2`
  (grantor-or-admin); a refusal is surfaced inline and revokes nothing. On
  success the workspace list is RE-LISTED, so the now-revoked row drops out
  (active_where excludes it).
  """
  def access_revoke(%{"id" => id}, socket) when is_binary(id) do
    principal = principal(socket)

    case Access.revoke(id, principal) do
      {:ok, _grant} ->
        {grants, workspace_view} = workspace_grants(socket)

        {:noreply,
         assign(socket,
           access_workspace_grants: grants,
           access_workspace_view: workspace_view,
           access_error: nil
         )}

      {:error, :forbidden} ->
        {:noreply,
         assign(socket,
           access_error: "Only the grantor or a workspace admin can revoke that grant."
         )}

      {:error, :not_found} ->
        # The grant is already gone (revoked/expired elsewhere). Re-list so the
        # panel reflects the live truth; surface a gentle notice, not an error.
        {grants, workspace_view} = workspace_grants(socket)

        {:noreply,
         socket
         |> assign(
           access_workspace_grants: grants,
           access_workspace_view: workspace_view,
           access_error: nil
         )
         |> put_flash(:info, "That grant is no longer active.")}
    end
  end

  def access_revoke(_params, socket), do: {:noreply, socket}

  # Load the workspace's ACTIVE grants, but ONLY when the caller is authorized to
  # read the workspace — the identical gate AccessController.index applies. A
  # caller with no workspace, no principal, or no :read authority (e.g. a bare
  # grantee) gets `{[], false}`, hiding the workspace section entirely.
  defp workspace_grants(socket) do
    ws = socket.assigns[:current_workspace]
    ws_id = ws && Map.get(ws, :id)
    principal = principal(socket)

    if is_binary(ws_id) and not is_nil(principal) and
         Auth.authorize(principal, ws_id, :read) == :ok do
      {Access.list_grants_for_workspace(ws_id), true}
    else
      {[], false}
    end
  end

  # Whichever authenticated principal the Studio mount carries — an account User
  # or an ApiToken. Both are valid `Access.revoke/2` / `Auth.authorize/3`
  # principals; nil for an anonymous socket (→ workspace section hidden).
  defp principal(socket) do
    socket.assigns[:current_user] || socket.assigns[:api_token]
  end
end
