defmodule BarkparkWeb.StudioModalFocusTest do
  @moduledoc """
  task-0ad7fed4370a5978 — every Studio dialog takes focus.

  Each `role="dialog"` in `StudioComponents.Modals` was aria-modal yet never
  took focus, so Tab walked the page behind it. Each now mounts
  `Hooks.ModalFocus` (root.html.heex; its jsdom test covers the behaviour).
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.StudioComponents.Modals

  @source File.read!("lib/barkpark_web/components/studio_components/modals.ex")

  test "every role=dialog in the module mounts ModalFocus under a unique id" do
    # Each dialog's opening tag, from `role="dialog"` to its closing `>`.
    tags = Regex.scan(~r/role="dialog"[^>]*>/s, @source) |> Enum.map(&hd/1)
    assert length(tags) == 10, "found #{length(tags)} dialogs; the count is the control"

    for tag <- tags do
      assert tag =~ ~s(phx-hook="ModalFocus"), "dialog without the focus hook: #{tag}"
    end

    ids = Enum.map(tags, &(Regex.run(~r/\bid="([^"]+)"/, &1) |> List.last()))
    assert Enum.uniq(ids) == ids, "a LiveView hook needs a unique id: #{inspect(ids)}"
  end

  test "the reference picker opens on its search field" do
    assert @source =~ ~r/<input[^>]*phx-keyup="ref-search"[^>]*data-modal-focus/
  end

  test "the share sheet opens on its recipient email field" do
    html = render_component(&Modals.airdrop_sheet/1, show: true, caps: ["read"])
    assert html =~ ~s(id="airdrop-sheet-dialog")
    assert [_] = Regex.scan(~r/<input[^>]*name="grantee_email"[^>]*data-modal-focus/s, html)
  end

  test "the delete dialog opens on Cancel, not on Delete" do
    html =
      render_component(&Modals.delete_modal/1,
        show_delete: true,
        delete_refs: [],
        editor_doc: %{title: "Doc", id: "doc-1"}
      )

    assert html =~ ~s(id="delete-modal-dialog")
    assert html =~ ~s(phx-hook="ModalFocus")
    [marked] = Regex.scan(~r/<button[^>]*data-modal-focus[^>]*>([^<]*)</, html)
    assert List.last(marked) =~ "Cancel"
  end
end
