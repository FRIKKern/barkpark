defmodule BarkparkWeb.StudioComponents.ModalsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias BarkparkWeb.StudioComponents.Modals

  describe "delete_modal/1 — clean vs. ref-blocked paths" do
    test "renders nothing when show_delete is false" do
      html =
        render_component(&Modals.delete_modal/1, %{
          show_delete: false,
          delete_refs: [],
          editor_doc: %{title: "My Doc"}
        })

      refute html =~ "Delete document"
    end

    test "renders simple delete confirmation when no incoming refs" do
      html =
        render_component(&Modals.delete_modal/1, %{
          show_delete: true,
          delete_refs: [],
          editor_doc: %{title: "My Doc"}
        })

      assert html =~ "Delete document"
      assert html =~ "My Doc"
      assert html =~ ~s(phx-click="confirm-delete")
      # Should NOT show the disconnect path
      refute html =~ "Disconnect references"
    end

    test "renders disconnect+delete path when refs exist" do
      refs = [
        %{title: "Related Post", type: "post", field: "author"},
        %{title: nil, type: "page", field: "hero"}
      ]

      html =
        render_component(&Modals.delete_modal/1, %{
          show_delete: true,
          delete_refs: refs,
          editor_doc: %{title: "Target Doc"}
        })

      assert html =~ "Disconnect references and delete"
      assert html =~ ~s(phx-value-disconnect="true")
      assert html =~ "Related Post"
      # nil title falls back to "Untitled"
      assert html =~ "Untitled"
      # Ref count should appear
      assert html =~ "2"
    end
  end

  describe "discard_modal/1" do
    test "renders nothing when show_discard is false" do
      html =
        render_component(&Modals.discard_modal/1, %{
          show_discard: false,
          editor_doc: %{title: "Draft"}
        })

      refute html =~ "Discard draft"
    end

    test "renders confirmation with doc title when show_discard is true" do
      html =
        render_component(&Modals.discard_modal/1, %{
          show_discard: true,
          editor_doc: %{title: "My Draft"}
        })

      assert html =~ "Discard draft"
      assert html =~ "My Draft"
      assert html =~ ~s(phx-click="confirm-discard")
    end
  end

  describe "dialog a11y semantics" do
    test "delete_modal exposes dialog role, labelled title, and escape-close" do
      html =
        render_component(&Modals.delete_modal/1, %{
          show_delete: true,
          delete_refs: [],
          editor_doc: %{title: "Doomed"}
        })

      assert html =~ ~s(role="dialog")
      assert html =~ ~s(aria-modal="true")
      assert html =~ ~s(aria-labelledby="delete-modal-title")
      assert html =~ ~s(id="delete-modal-title")
      assert html =~ ~s(phx-window-keydown="close-delete")
      assert html =~ ~s(aria-label="Close")
    end

    test "discard_modal exposes dialog role and escape-close" do
      html =
        render_component(&Modals.discard_modal/1, %{
          show_discard: true,
          editor_doc: %{title: "My Draft"}
        })

      assert html =~ ~s(role="dialog")
      assert html =~ ~s(aria-labelledby="discard-modal-title")
      assert html =~ ~s(phx-window-keydown="close-discard")
      assert html =~ ~s(aria-label="Close")
    end
  end
end
