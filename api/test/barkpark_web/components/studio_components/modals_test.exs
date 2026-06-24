defmodule BarkparkWeb.StudioComponents.ModalsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias BarkparkWeb.StudioComponents.Modals

  describe "ref_picker_modal/1 — gate + filtering" do
    test "renders nothing when ref_picker_field is nil (gate closed)" do
      html =
        render_component(&Modals.ref_picker_modal/1, %{
          ref_picker_field: nil,
          ref_search: "",
          ref_candidates: [%{id: "doc-1", title: "Ignored"}]
        })

      refute html =~ "image-picker"
      refute html =~ "Select reference"
    end

    test "renders modal when ref_picker_field is set" do
      html =
        render_component(&Modals.ref_picker_modal/1, %{
          ref_picker_field: "author",
          ref_search: "",
          ref_candidates: []
        })

      assert html =~ "Select reference"
      assert html =~ "close-ref-picker"
    end

    test "shows all candidates when ref_search is empty string" do
      candidates = [
        %{id: "doc-1", title: "Alpha"},
        %{id: "doc-2", title: "Beta"}
      ]

      html =
        render_component(&Modals.ref_picker_modal/1, %{
          ref_picker_field: "author",
          ref_search: "",
          ref_candidates: candidates
        })

      assert html =~ "Alpha"
      assert html =~ "Beta"
    end

    test "filters candidates by title (case-insensitive)" do
      candidates = [
        %{id: "doc-1", title: "Phoenix Framework"},
        %{id: "doc-2", title: "Elixir Language"}
      ]

      html =
        render_component(&Modals.ref_picker_modal/1, %{
          ref_picker_field: "author",
          ref_search: "elixir",
          ref_candidates: candidates
        })

      assert html =~ "Elixir Language"
      refute html =~ "Phoenix Framework"
    end

    test "filters candidates by id (case-insensitive)" do
      candidates = [
        %{id: "post-abc-123", title: "Unrelated Title"},
        %{id: "doc-xyz-999", title: "Another Doc"}
      ]

      html =
        render_component(&Modals.ref_picker_modal/1, %{
          ref_picker_field: "ref",
          ref_search: "ABC",
          ref_candidates: candidates
        })

      assert html =~ "post-abc-123"
      refute html =~ "doc-xyz-999"
    end

    test "shows 'No documents found' when filter yields empty result" do
      candidates = [%{id: "doc-1", title: "Alpha"}]

      html =
        render_component(&Modals.ref_picker_modal/1, %{
          ref_picker_field: "author",
          ref_search: "zzz-no-match",
          ref_candidates: candidates
        })

      assert html =~ "No documents found"
      refute html =~ "Alpha"
    end
  end

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
end
