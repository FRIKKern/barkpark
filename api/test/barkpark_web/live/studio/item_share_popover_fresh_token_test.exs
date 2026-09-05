defmodule BarkparkWeb.Studio.ItemSharePopoverFreshTokenTest do
  @moduledoc """
  The Studio half of `arpss-w8-bl-share-link-raw-token-at-rest` (RULED
  2026-09-02: retire the plaintext token column).

  The item-share popover used to show a readonly URL input + Copy button for
  EVERY listed link, because `Shared.load_item_links/2` read the raw token off
  the row. With the column retired there is no token to read, so the popover
  has exactly two arms and both are pinned here:

    * JUST MINTED — `ItemShare.item_share_create/2` holds `create/1`'s raw in
      `socket.assigns.item_share_fresh` (`%{link_id => raw}`), never in the
      database, so the link the operator just made IS copyable in the session
      that made it. This is what keeps the feature usable.
    * RE-OPENED / PRE-EXISTING — a link this socket did not just mint has
      `url: nil`, and the popover renders "Link is active. Regenerate to copy a
      new URL." with the Revoke affordance instead of an input whose value it
      cannot fill. `item_share_open/2` CLEARS the fresh map, so re-opening the
      popover on the same item drops back to this arm — a raw token does not
      survive the popover that minted it.

  The render assertions go through `render_component/2` on the real
  `item_share_popover/1`, so a template that stops honouring `link.url` reds
  here rather than in a screenshot.
  """
  use Barkpark.DataCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.StudioComponents.Modals
  alias BarkparkWeb.Studio.StudioLive.Handlers.ItemShare
  alias BarkparkWeb.Studio.StudioLive.Shared

  @dataset "production"

  setup do
    uniq = System.unique_integer([:positive])
    ws = create_workspace!("popover-ws-#{uniq}")
    proj = create_project!(ws, "popover-proj-#{uniq}")

    {:ok, token} =
      Auth.create_token(
        "popover-admin-#{uniq}",
        "item share popover",
        @dataset,
        ["read", "write", "admin"]
      )

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "admin")

    item = %{kind: "doc", ref_type: "paper", ref_id: "popover-doc-#{uniq}", title: "A Paper"}

    %{ws: ws, proj: proj, token: token, item: item}
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

  defp popover(links),
    do:
      render_component(&Modals.item_share_popover/1, %{
        show: true,
        admin?: true,
        title: "A Paper",
        links: links,
        error: nil
      })

  # ── ARM 1: just minted — copyable ─────────────────────────────────────────

  test "the link the operator JUST minted carries a url, and the popover offers Copy", ctx do
    {:noreply, socket} = ItemShare.item_share_create(%{"access" => "read"}, socket(ctx))

    assert [%{id: id, url: url}] = socket.assigns.item_share_links
    assert is_binary(url)
    assert url =~ "/s/"

    # The raw is held in ASSIGNS, keyed by the link it belongs to — not on the row.
    assert Map.has_key?(socket.assigns.item_share_fresh, id)
    assert url =~ socket.assigns.item_share_fresh[id]

    html = popover(socket.assigns.item_share_links)
    assert html =~ ~s(value="#{url}")
    assert html =~ "Copy"
    refute html =~ "Regenerate to copy a new URL"
  end

  # ── ARM 2: re-opened — not copyable, honest, still revocable ──────────────

  test "re-opening the popover clears the fresh token: the link has no url and says so", ctx do
    {:noreply, minted} = ItemShare.item_share_create(%{"access" => "read"}, socket(ctx))
    [%{id: id}] = minted.assigns.item_share_links

    params = %{
      "kind" => ctx.item.kind,
      "ref-type" => ctx.item.ref_type,
      "ref-id" => ctx.item.ref_id,
      "title" => ctx.item.title
    }

    {:noreply, reopened} = ItemShare.item_share_open(params, minted)

    # POSITIVE CONTROL: the SAME link is still listed — it was not revoked, it
    # simply has no URL to re-display.
    assert [%{id: ^id, url: nil}] = reopened.assigns.item_share_links
    assert reopened.assigns.item_share_fresh == %{}

    html = popover(reopened.assigns.item_share_links)
    assert html =~ "Link is active. Regenerate to copy a new URL."
    refute html =~ ~s(class="form-input item-share-url")
    refute html =~ ~s(data-url=)
    refute html =~ ">Copy<"

    # The operator is not stranded: Revoke is still there, which is the whole
    # "regenerate" path (revoke, then mint again).
    assert html =~ "item-share-revoke"
  end

  test "a link loaded fresh from the database — nobody's mint in this session — has no url",
       ctx do
    {:noreply, minted} = ItemShare.item_share_create(%{"access" => "read"}, socket(ctx))
    [%{id: id}] = minted.assigns.item_share_links

    # A brand new socket, as a page reload or a second admin's browser gives.
    loaded = Shared.load_item_links(socket(ctx), ctx.item)

    assert [%{id: ^id, url: nil}] = loaded
  end
end
