defmodule BarkparkWeb.Studio.StudioLive.Handlers.ItemShare do
  @moduledoc """
  Item (per-document) share popover (P7) + jump-to-user. Same admin gate as the
  section panel, re-checked per handler. Behaviour-preserving extraction.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Sharing.Links
  alias Barkpark.Structure
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.PaneBuilder
  alias BarkparkWeb.Studio.StudioLive.Shared

  def item_share_open(%{"kind" => kind} = params, socket) do
    if Caps.admin?(socket) do
      # Was an inline `String.replace_prefix/3` — the ONLY place this rule
      # existed, which is precisely why the HTTP mint never had it. It is one
      # shared function now; this call is kept so the pane shows the published
      # id, and `Links.create/1` enforces it regardless.
      ref_id = params["ref-id"] |> to_string() |> Links.published_ref_id()

      item = %{
        kind: kind,
        ref_type: params["ref-type"],
        ref_id: ref_id,
        title: params["title"] || ref_id
      }

      # The fresh-token map is per-ITEM and is CLEARED on open: a raw token
      # minted for a different item (or for this one in an earlier popover
      # session) must not be re-shown. Only what this socket mints from here on
      # has a URL — the row itself no longer carries one.
      {:noreply,
       assign(socket,
         item_share_open: true,
         item_share: item,
         item_share_error: nil,
         item_share_fresh: %{},
         item_share_links: Shared.load_item_links(socket, item, %{})
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

      # THE UNBOUND-MINT REFUSAL (task-2da739b78e938be0). `Shared.item_link_attrs/3`
      # spells project_id as `socket.assigns[:current_project] && …`, so a socket
      # with no project mints a link bound to no project — and a link bound to no
      # project matches no `(workspace, project, dataset)` triple, so
      # `Links.revoke_scope/3` (the cascade `Sharing.remove_share/3` fires) can
      # never revoke it. The AUTHORITATIVE refusal is `ShareLink.changeset/2`,
      # which requires both scope ids at the one changeset BOTH mint doors cross;
      # this arm exists so the operator gets the REASON instead of the generic
      # "Could not create the link." Deliberately NOT a fallback to a default
      # project: which project the item belongs to is not this handler's to guess.
      is_nil(socket.assigns[:current_project]) ->
        {:noreply,
         assign(socket,
           item_share_error: "No project in context — open the desk under a project to share."
         )}

      true ->
        case Barkpark.Sharing.Links.create(Shared.item_link_attrs(socket, item, access)) do
          # `create/1`'s `{raw, link}` is the ONE place the plaintext token
          # exists — it is not persisted. Hold it in socket assigns so THIS
          # popover can show and copy the link it just minted; every other row
          # renders without a URL.
          {:ok, {raw, link}} ->
            fresh = Map.put(socket.assigns[:item_share_fresh] || %{}, link.id, raw)

            {:noreply,
             assign(socket,
               item_share_fresh: fresh,
               item_share_links: Shared.load_item_links(socket, item, fresh),
               item_share_error: nil
             )}

          {:error, _} ->
            {:noreply, assign(socket, item_share_error: "Could not create the link.")}
        end
    end
  end

  # RECEIPT LAW (pds w39) — the LiveView half (`pds-w40-bl-item-share-silent-noop`).
  #
  # This handler used to call `Links.revoke/1` as a BARE STATEMENT and discard
  # its return on BOTH paths: the operator clicked Revoke and was told nothing
  # at all, success or failure — a `silent_no_op`, structurally invisible to any
  # lens keyed on receipt TEXT because there was no text. The FAILURE half was
  # bound by the tenancy-confinement sibling
  # (`arpss-item-share-revoke-unscoped-revoke`, the comment block below); this
  # binds the SUCCESS half.
  #
  # The rule is the one the HTTP twin already states verbatim at
  # `ShareLinkController.revoke/2` — "RECEIPT LAW (pds w39): `Links.revoke/1`
  # returns the UPDATED link" — where `revoked`/`revoked_at` both descend from
  # the returned row's own stamp, a value the request never carries. The two
  # doors onto this surface are now the SAME rule: what the operator is told
  # DESCENDS FROM THE WRITE RETURN, never from the `phx-value-id` they clicked
  # and never from the re-read list (`Shared.load_item_links/3` below is a fresh
  # STORE READ and is not, on its own, a receipt for anything).
  #
  # Success is a FLASH and failure stays `item_share_error` on purpose: the
  # popover renders `@error` in place (`StudioComponents.Modals`, which has no
  # notice slot and is not this slice's file), and a success message belongs
  # where it survives the row disappearing from the list it describes.
  def item_share_revoke(%{"id" => id}, socket) do
    if Caps.admin?(socket) do
      {error, receipt} =
        case revoke_scoped(socket, id) do
          {:ok, link} -> {nil, revoked_receipt(link)}
          _ -> {"Could not revoke the link.", nil}
        end

      socket =
        assign(socket,
          item_share_links:
            Shared.load_item_links(
              socket,
              socket.assigns[:item_share],
              socket.assigns[:item_share_fresh] || %{}
            ),
          item_share_error: error
        )

      {:noreply, if(receipt, do: put_flash(socket, :info, receipt), else: socket)}
    else
      {:noreply, put_flash(socket, :error, "Admin access required to share items.")}
    end
  end

  # The sentence the operator reads, derived from the ROW `revoke/1` returned.
  # The second clause is the LiveView spelling of the HTTP twin's
  # `revoked: not is_nil(revoked.revoked_at)`: an `{:ok, row}` whose stamp did
  # not land is reported as what it is, rather than being rounded up to
  # "revoked" by the mere fact that the call did not error.
  defp revoked_receipt(%{revoked_at: %DateTime{} = at}),
    do: "Link revoked #{DateTime.to_iso8601(at)}. It no longer opens."

  defp revoked_receipt(_link),
    do: "Revoke returned a link that is not marked revoked — it may still open."

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
  # Authorize-and-revoke now lives at the CONTEXT boundary
  # (`Sharing.Links.revoke_scoped/2`), shared with the HTTP half instead of
  # mirrored into it — `arpss-w8-bl-links-context-boundary-predicate`. The
  # totality reasoning, the denial shape, and the ruling that the predicate is
  # `workspace_admin?/2` (the membership ROLE) and never `authorize/3` moved
  # WITH the code and are stated there.
  #
  # BOTH principal kinds a Studio socket can carry are passed, because either
  # can legitimately hold the seat: an api_token session and a logged-in
  # account. Extracting them is socket work and stays here; the context takes
  # the list and tries them in order.
  defp revoke_scoped(socket, id),
    do: Links.revoke_scoped(principals(socket), id)

  defp principals(socket),
    do: [socket.assigns[:api_token], socket.assigns[:current_user]]

  def jump_to_user(%{"type" => type, "doc-id" => doc_id}, socket) do
    structure = Structure.build(socket.assigns.dataset, ScopeHelpers.scope_opts(socket))
    path = PaneBuilder.find_doc_path(structure, type, doc_id)
    {:noreply, push_patch(socket, to: Shared.studio_path(socket, path, socket.assigns.dataset))}
  end
end
