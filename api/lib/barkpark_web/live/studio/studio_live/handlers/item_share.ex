defmodule BarkparkWeb.Studio.StudioLive.Handlers.ItemShare do
  @moduledoc """
  Item (per-document) share popover (P7) + jump-to-user. Same admin gate as the
  section panel, re-checked per handler. Behaviour-preserving extraction.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Accounts.User
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Sharing.Links
  alias Barkpark.Sharing.ShareLink
  alias Barkpark.Structure
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.PaneBuilder
  alias BarkparkWeb.Studio.StudioLive.Shared

  def item_share_open(%{"kind" => kind} = params, socket) do
    if Caps.admin?(socket) do
      ref_id = params["ref-id"] |> to_string() |> String.replace_prefix("drafts.", "")

      item = %{
        kind: kind,
        ref_type: params["ref-type"],
        ref_id: ref_id,
        title: params["title"] || ref_id
      }

      {:noreply,
       assign(socket,
         item_share_open: true,
         item_share: item,
         item_share_error: nil,
         item_share_links: Shared.load_item_links(socket, item)
       )}
    else
      {:noreply, put_flash(socket, :error, "Admin access required to share items.")}
    end
  end

  def item_share_close(socket) do
    {:noreply, assign(socket, item_share_open: false, item_share_error: nil)}
  end

  def item_share_create(%{"access" => access}, socket) do
    item = socket.assigns[:item_share]

    cond do
      not Caps.admin?(socket) ->
        {:noreply, put_flash(socket, :error, "Admin access required to share items.")}

      is_nil(item) or is_nil(socket.assigns[:current_workspace]) ->
        {:noreply, assign(socket, item_share_error: "No item / workspace in context.")}

      true ->
        case Barkpark.Sharing.Links.create(Shared.item_link_attrs(socket, item, access)) do
          {:ok, _} ->
            {:noreply,
             assign(socket,
               item_share_links: Shared.load_item_links(socket, item),
               item_share_error: nil
             )}

          {:error, _} ->
            {:noreply, assign(socket, item_share_error: "Could not create the link.")}
        end
    end
  end

  def item_share_revoke(%{"id" => id}, socket) do
    if Caps.admin?(socket) do
      error =
        case revoke_scoped(socket, id) do
          {:ok, _link} -> nil
          _ -> "Could not revoke the link."
        end

      {:noreply,
       assign(socket,
         item_share_links: Shared.load_item_links(socket, socket.assigns[:item_share]),
         item_share_error: error
       )}
    else
      {:noreply, put_flash(socket, :error, "Admin access required to share items.")}
    end
  end

  # ── tenancy confinement on revoke (arpss-item-share-revoke-unscoped-revoke) ─
  #
  # `phx-value-id` is a RAW CLIENT STRING and `Links.revoke/1` is a bare
  # `Repo.get(ShareLink, uuid)` with no tenant predicate, so the id need not
  # belong to the mounted workspace. `Caps.admin?/1` — even on its post-#12695
  # workspace-scoped SEAT footing — certifies WHO the actor is on the workspace
  # it MOUNTED; it says nothing about WHICH row the id names. The target must
  # therefore be authorized against its OWN workspace.
  #
  # `socket.assigns.current_workspace` is deliberately NOT read here: that is
  # the mounted tenant, and the whole defect is that the id need not belong to
  # it (and `StudioChrome.default_scope_fallback/1` can pin it with no
  # membership check on flat surfaces).
  #
  # DENIAL SHAPE: a non-castable id, a missing row, a foreign row and a row with
  # a nil `workspace_id` ALL collapse to the same `{:error, :not_found}` and the
  # same rendered message — no existence oracle, and no 500 from an uncast
  # `:binary_id`. Mirrors `ShareLinkController.revoke_scoped/2` (the HTTP half,
  # #12569/#12700), whose sibling this is.
  #
  # `Links.revoke/1`'s arity is untouched ON PURPOSE: it has non-HTTP callers
  # with no actor to authorize, and its two admin callers hold different actor
  # shapes (a conn there, a socket here).
  defp revoke_scoped(socket, id) do
    with row_id when is_binary(row_id) <- Repo.uuid_or_nil(id),
         %ShareLink{workspace_id: ws_id} <- Repo.get(ShareLink, row_id),
         true <- workspace_admin?(socket, ws_id) do
      Links.revoke(row_id)
    else
      _ -> {:error, :not_found}
    end
  end

  # TOTALITY: bare `TenancyAuth.workspace_admin?/2` RAISES on the shapes that
  # can reach here — `FunctionClauseError` on a nil principal or a nil/non-UUID
  # workspace id — so both sides are narrowed first and ANYTHING unmatched is a
  # DENIAL. A nil `workspace_id` on the row is therefore NOT revocable through
  # this surface (no nil-permissive "platform admin" passthrough).
  #
  # Both principal kinds a Studio socket can carry are tried, because both can
  # legitimately hold a seat: an api_token session and a logged-in account. The
  # predicate is `workspace_admin?/2` (the membership ROLE), never
  # `authorize/3` — `authorize/3`'s api_token arm ORs the token's GLOBAL
  # `permissions[]` with membership, so a plain `member` of B holding global
  # `admin` perms would PASS it. That actor is exactly the attacker in the
  # committed cross-tenant test.
  defp workspace_admin?(socket, workspace_id) do
    case Repo.uuid_or_nil(workspace_id) do
      nil ->
        false

      ws_id ->
        [socket.assigns[:api_token], socket.assigns[:current_user]]
        |> Enum.any?(&principal_admin?(&1, ws_id))
    end
  end

  defp principal_admin?(%ApiToken{id: id} = token, ws_id) when is_binary(id),
    do: TenancyAuth.workspace_admin?(token, ws_id)

  defp principal_admin?(%User{id: id} = user, ws_id) when is_binary(id),
    do: TenancyAuth.workspace_admin?(user, ws_id)

  defp principal_admin?(_principal, _ws_id), do: false

  def jump_to_user(%{"type" => type, "doc-id" => doc_id}, socket) do
    structure = Structure.build(socket.assigns.dataset, ScopeHelpers.scope_opts(socket))
    path = PaneBuilder.find_doc_path(structure, type, doc_id)
    {:noreply, push_patch(socket, to: Shared.studio_path(socket, path, socket.assigns.dataset))}
  end
end
