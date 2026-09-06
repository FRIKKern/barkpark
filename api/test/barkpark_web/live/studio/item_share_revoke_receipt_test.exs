defmodule BarkparkWeb.Studio.ItemShareRevokeReceiptTest do
  @moduledoc """
  RECEIPT LAW (pds w39) for the Studio half of item-share revoke
  (`pds-w40-bl-item-share-silent-noop`).

  `ItemShare.item_share_revoke/2` used to call `Links.revoke/1` as a bare
  statement and discard the return on BOTH paths, so clicking Revoke re-rendered
  a fresh store read and said NOTHING — success or failure. A `silent_no_op`:
  the operator is not told a false thing, they are told nothing, which is why no
  lens keyed on receipt TEXT could see it.

  The FAILURE half was bound by the tenancy-confinement sibling
  (`arpss-item-share-revoke-unscoped-revoke`), which introduced
  `item_share_error`. No test drove it, so it is pinned here too. The SUCCESS
  half is the new behaviour: a sentence DERIVED FROM THE RETURNED ROW's own
  `revoked_at` stamp — the same rule the HTTP twin spells out at
  `ShareLinkController.revoke/2`, whose body emits `revoked_at` off the row
  `Links.revoke/1` gave back rather than echoing the `:id` it was handed.

  The derivation is proved, not assumed: the asserted timestamp is read back
  from the DATABASE row after the call, so a receipt built from anything the
  request carried (the clicked `phx-value-id`, a `DateTime.utc_now()` of its
  own) cannot satisfy it.

  DENIAL SHAPE is asserted unchanged: a non-castable id, a missing row and a
  foreign row all collapse to ONE message, so the popover is no existence
  oracle.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Repo
  alias Barkpark.Sharing.ShareLink
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Studio.StudioLive.Handlers.ItemShare

  @dataset "production"

  setup do
    uniq = System.unique_integer([:positive])
    ws = create_workspace!("revoke-ws-#{uniq}")
    proj = create_project!(ws, "revoke-proj-#{uniq}")

    {:ok, token} =
      Auth.create_token(
        "revoke-admin-#{uniq}",
        "item share revoke receipt",
        @dataset,
        ["read", "write", "admin"]
      )

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "admin")

    item = %{kind: "doc", ref_type: "paper", ref_id: "revoke-doc-#{uniq}", title: "A Paper"}

    %{ws: ws, proj: proj, token: token, item: item, uniq: uniq}
  end

  defp socket(%{token: token, ws: ws, proj: proj, item: item}) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        api_token: token,
        current_user: nil,
        current_workspace: ws,
        current_project: proj,
        dataset: @dataset,
        item_share: item,
        item_share_open: true,
        item_share_links: [],
        item_share_fresh: %{},
        item_share_error: nil
      }
    }
  end

  defp mint(ctx) do
    {:noreply, minted} = ItemShare.item_share_create(%{"access" => "read"}, socket(ctx))
    [%{id: id}] = minted.assigns.item_share_links
    {id, minted}
  end

  # ── SUCCESS: the receipt descends from the returned row ───────────────────

  test "revoking a link tells the operator so, in words taken from the row the write returned",
       ctx do
    {id, minted} = mint(ctx)

    {:noreply, out} = ItemShare.item_share_revoke(%{"id" => id}, minted)

    # The store's own answer, read back independently of the handler.
    stamped = Repo.get(ShareLink, id).revoked_at
    assert %DateTime{} = stamped

    receipt = out.assigns.flash["info"]
    assert is_binary(receipt), "revoking emitted no receipt at all — the silent no-op is back"
    assert receipt =~ "revoked"
    assert receipt =~ DateTime.to_iso8601(stamped)

    # A success is not also an error, and the list re-read still happened.
    assert out.assigns.item_share_error == nil
    assert out.assigns.item_share_links != []
  end

  # ── FAILURE: the operator is TOLD, and told the same thing every time ─────

  test "revoking a bogus id tells the operator, rather than silently re-rendering", ctx do
    {_id, minted} = mint(ctx)

    {:noreply, out} = ItemShare.item_share_revoke(%{"id" => "not-a-uuid"}, minted)

    assert out.assigns.item_share_error == "Could not revoke the link."
    # A failure must not be dressed as a success.
    assert out.assigns.flash["info"] == nil
  end

  test "a missing row and a foreign row give the SAME message as a bogus id — no existence oracle",
       ctx do
    {_id, minted} = mint(ctx)

    # A well-formed uuid naming nothing.
    {:noreply, missing} = ItemShare.item_share_revoke(%{"id" => Ecto.UUID.generate()}, minted)

    # A real row in a workspace this socket holds no seat on.
    other_ws = create_workspace!("revoke-other-ws-#{ctx.uniq}")
    other_proj = create_project!(other_ws, "revoke-other-proj-#{ctx.uniq}")

    {:ok, {_raw, foreign}} =
      Barkpark.Sharing.Links.create(%{
        workspace_id: other_ws.id,
        project_id: other_proj.id,
        dataset: @dataset,
        kind: "doc",
        ref_type: "paper",
        ref_id: "foreign-doc-#{ctx.uniq}",
        access: "read"
      })

    {:noreply, foreign_out} = ItemShare.item_share_revoke(%{"id" => foreign.id}, minted)

    assert missing.assigns.item_share_error == "Could not revoke the link."
    assert foreign_out.assigns.item_share_error == "Could not revoke the link."
    assert foreign_out.assigns.flash["info"] == nil

    # POSITIVE CONTROL: the foreign row was not touched.
    assert Repo.get(ShareLink, foreign.id).revoked_at == nil
  end
end
