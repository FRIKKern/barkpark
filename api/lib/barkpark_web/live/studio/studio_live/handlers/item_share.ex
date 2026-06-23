defmodule BarkparkWeb.Studio.StudioLive.Handlers.ItemShare do
  @moduledoc """
  Item (per-document) share popover (P7) + jump-to-user. Same admin gate as the
  section panel, re-checked per handler. Behaviour-preserving extraction.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Structure
  alias BarkparkWeb.Studio.PaneBuilder
  alias BarkparkWeb.Studio.StudioLive.Shared

  def item_share_open(%{"kind" => kind} = params, socket) do
    if socket.assigns[:shares_admin?] do
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
      not socket.assigns[:shares_admin?] ->
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
    if socket.assigns[:shares_admin?] do
      Barkpark.Sharing.Links.revoke(id)

      {:noreply,
       assign(socket, item_share_links: Shared.load_item_links(socket, socket.assigns[:item_share]))}
    else
      {:noreply, put_flash(socket, :error, "Admin access required to share items.")}
    end
  end

  def jump_to_user(%{"type" => type, "doc-id" => doc_id}, socket) do
    structure = Structure.build(socket.assigns.dataset)
    path = PaneBuilder.find_doc_path(structure, type, doc_id)
    {:noreply, push_patch(socket, to: Shared.studio_path(socket, path, socket.assigns.dataset))}
  end
end
