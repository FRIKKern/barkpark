defmodule BarkparkWeb.Studio.Plugins.OnixEdit.BookEditorTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Content.Codelists

  @dataset "production"
  @doc_id "book-test-1"

  # Minimal Thema-shaped fixture used by WI3 Subjects-tab persistence tests.
  # Mirrors the shape `Codelists.register/3` expects (issue, name, values).
  @thema_fixture %{
    issue: "73",
    name: "ONIX Thema 73 (test fixture)",
    values: [
      %{
        code: "F",
        translations: [%{language: "eng", label: "Fiction & Related items"}],
        children: [
          %{
            code: "FB",
            translations: [%{language: "eng", label: "Fiction: general & literary"}],
            children: [
              %{
                code: "FBA",
                translations: [%{language: "eng", label: "Modern & contemporary fiction"}]
              }
            ]
          }
        ]
      },
      %{
        code: "J",
        translations: [%{language: "eng", label: "Society & social sciences"}]
      }
    ]
  }

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "book",
          "title" => "Book (ONIX 3.0)",
          "icon" => "book",
          "visibility" => "private",
          "fields" => []
        },
        @dataset
      )

    {:ok, _doc} =
      Content.create_document(
        "book",
        %{"doc_id" => @doc_id, "title" => "Test Book"},
        @dataset
      )

    {:ok, conn: conn}
  end

  describe "shell + tab routing" do
    test "mounts and defaults to Identity tab", %{conn: conn} do
      {:ok, view, html} = live(conn, "/studio/#{@dataset}/onixedit/book/#{@doc_id}")

      assert html =~ "Test Book"
      assert html =~ ~s|data-test-id="book-editor-tabs"|

      assert has_element?(view, ~s|[data-tab-body="identity"]|, "Identity tab")
      refute has_element?(view, ~s|[data-tab-body="title"]|)
    end

    test "?tab=title renders the Title placeholder", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}/onixedit/book/#{@doc_id}?tab=title")

      assert has_element?(view, ~s|[data-tab-body="title"]|)
      refute has_element?(view, ~s|[data-tab-body="identity"]|)
    end

    test "patching between tabs swaps the body without remounting", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}/onixedit/book/#{@doc_id}")

      assert has_element?(view, ~s|[data-tab-body="identity"]|)

      view
      |> element(~s|a[data-tab="contributors"]|)
      |> render_click()

      assert has_element?(view, ~s|[data-tab-body="contributors"]|)
      refute has_element?(view, ~s|[data-tab-body="identity"]|)

      view
      |> element(~s|a[data-tab="subjects"]|)
      |> render_click()

      assert has_element?(view, ~s|[data-tab-body="subjects"]|)
    end

    test "unknown ?tab= falls back to Identity and flashes an error", %{conn: conn} do
      {:ok, view, html} = live(conn, "/studio/#{@dataset}/onixedit/book/#{@doc_id}?tab=bogus")

      assert html =~ "Unknown tab"
      assert has_element?(view, ~s|[data-tab-body="identity"]|)
    end

    test "renders all 8 tab links in order", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/studio/#{@dataset}/onixedit/book/#{@doc_id}")

      for {_atom, label} <- BarkparkWeb.Studio.Plugins.OnixEdit.BookEditor.tabs() do
        assert html =~ label, "missing tab label: #{label}"
      end
    end
  end

  describe "Subjects tab — Thema persistence (WI3)" do
    setup do
      {:ok, _codelist} = Codelists.register("onixedit", "onixedit:thema", @thema_fixture)
      :ok
    end

    test "subjects tab embeds the ThemaTreePicker LiveComponent", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}/onixedit/book/#{@doc_id}?tab=subjects")

      assert has_element?(view, ~s|[data-tab-body="subjects"]|)
      assert has_element?(view, ~s|[data-test-id="thema-tree-picker"]|)
      assert has_element?(view, ~s|[data-test-id="thema-node-F"]|)
    end

    test "selecting a code persists to draft.content[\"themaSubjectCategory\"]",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}/onixedit/book/#{@doc_id}?tab=subjects")

      view |> element(~s|[data-test-id="thema-checkbox-F"]|) |> render_click()

      {:ok, draft} = Content.get_document("drafts.#{@doc_id}", "book", @dataset)
      assert Map.get(draft.content, "themaSubjectCategory") == ["F"]

      # Pill bar reflects the persisted selection on the same view (round-trip
      # via parent re-render of the live_component).
      assert has_element?(view, ~s|[data-test-id="thema-pill-F"]|)
      assert has_element?(view, ~s|[data-test-id="thema-node-F"][data-selected="true"]|)
    end

    test "deselecting a code rewrites the persisted list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}/onixedit/book/#{@doc_id}?tab=subjects")

      view |> element(~s|[data-test-id="thema-checkbox-F"]|) |> render_click()
      view |> element(~s|[data-test-id="thema-checkbox-J"]|) |> render_click()

      {:ok, after_two} = Content.get_document("drafts.#{@doc_id}", "book", @dataset)
      assert Enum.sort(Map.fetch!(after_two.content, "themaSubjectCategory")) == ["F", "J"]

      view |> element(~s|[data-test-id="thema-checkbox-F"]|) |> render_click()

      {:ok, after_remove} = Content.get_document("drafts.#{@doc_id}", "book", @dataset)
      assert Map.fetch!(after_remove.content, "themaSubjectCategory") == ["J"]
    end

    test "round-trip: mount → edit → re-mount preserves the selection",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}/onixedit/book/#{@doc_id}?tab=subjects")
      view |> element(~s|[data-test-id="thema-checkbox-F"]|) |> render_click()

      # Drop the LiveView and re-mount via a fresh conn. The new mount must
      # rehydrate `subjects_thema` from `doc.content["themaSubjectCategory"]`.
      {:ok, view2, _html} =
        live(build_conn(), "/studio/#{@dataset}/onixedit/book/#{@doc_id}?tab=subjects")

      assert has_element?(view2, ~s|[data-test-id="thema-pill-F"]|)
      assert has_element?(view2, ~s|[data-test-id="thema-node-F"][data-selected="true"]|)
    end

    test "round-trip: persisted selection seeds the picker even on the Identity tab",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}/onixedit/book/#{@doc_id}?tab=subjects")
      view |> element(~s|[data-test-id="thema-checkbox-F"]|) |> render_click()

      # Mounting on a non-Subjects tab still rehydrates the assign; switching
      # to Subjects then must show the selection without a re-fetch.
      {:ok, view2, _html} =
        live(build_conn(), "/studio/#{@dataset}/onixedit/book/#{@doc_id}?tab=identity")

      view2 |> element(~s|a[data-tab="subjects"]|) |> render_click()

      assert has_element?(view2, ~s|[data-test-id="thema-pill-F"]|)
    end
  end
end
