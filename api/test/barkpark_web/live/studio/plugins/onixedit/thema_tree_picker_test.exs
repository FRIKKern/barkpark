defmodule BarkparkWeb.Studio.Plugins.OnixEdit.BookEditor.ThemaTreePickerTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Content.Codelists

  @dataset "production"
  @doc_id "book-thema-test"

  # Minimal Thema-shaped fixture: 3 roots (F, J, Y), F has children FB → FBA,
  # J has children JF → JFC. ~10 nodes total, 3 levels deep.
  @fixture %{
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
              },
              %{
                code: "FBC",
                translations: [%{language: "eng", label: "Classic fiction"}]
              }
            ]
          },
          %{
            code: "FF",
            translations: [%{language: "eng", label: "Crime & mystery"}],
            children: [
              %{
                code: "FFC",
                translations: [%{language: "eng", label: "Detective fiction"}]
              }
            ]
          }
        ]
      },
      %{
        code: "J",
        translations: [%{language: "eng", label: "Society & social sciences"}],
        children: [
          %{
            code: "JF",
            translations: [%{language: "eng", label: "Society & culture: general"}]
          }
        ]
      },
      %{
        code: "Y",
        translations: [%{language: "eng", label: "Children's, Teenage & Educational"}]
      }
    ]
  }

  setup %{conn: conn} do
    {:ok, _codelist} = Codelists.register("onixedit", "onixedit:thema", @fixture)

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
        %{"doc_id" => @doc_id, "title" => "Test Book Subjects"},
        @dataset
      )

    {:ok, conn: conn}
  end

  defp open_subjects_tab(conn) do
    {:ok, view, _html} = live(conn, "/studio/#{@dataset}/onixedit/book/#{@doc_id}?tab=subjects")

    view
  end

  describe "initial render" do
    test "shows root Thema codes collapsed", %{conn: conn} do
      view = open_subjects_tab(conn)

      assert has_element?(view, ~s|[data-test-id="thema-tree-picker"]|)
      assert has_element?(view, ~s|[data-test-id="thema-node-F"]|)
      assert has_element?(view, ~s|[data-test-id="thema-node-J"]|)
      assert has_element?(view, ~s|[data-test-id="thema-node-Y"]|)

      # Children of unexpanded roots are NOT in the DOM.
      refute has_element?(view, ~s|[data-test-id="thema-node-FB"]|)
      refute has_element?(view, ~s|[data-test-id="thema-node-FBA"]|)
    end

    test "renders the search input", %{conn: conn} do
      view = open_subjects_tab(conn)
      assert has_element?(view, ~s|input[data-test-id="thema-picker-search"]|)
    end
  end

  describe "expand / collapse" do
    test "clicking the chevron expands a node and reveals children", %{conn: conn} do
      view = open_subjects_tab(conn)

      view
      |> element(~s|[data-test-id="thema-toggle-F"]|)
      |> render_click()

      assert has_element?(view, ~s|[data-test-id="thema-node-FB"]|)
      assert has_element?(view, ~s|[data-test-id="thema-node-FF"]|)
      # Grandchildren still hidden until FB is also expanded.
      refute has_element?(view, ~s|[data-test-id="thema-node-FBA"]|)
    end

    test "clicking the chevron a second time collapses", %{conn: conn} do
      view = open_subjects_tab(conn)

      view |> element(~s|[data-test-id="thema-toggle-F"]|) |> render_click()
      assert has_element?(view, ~s|[data-test-id="thema-node-FB"]|)

      view |> element(~s|[data-test-id="thema-toggle-F"]|) |> render_click()
      refute has_element?(view, ~s|[data-test-id="thema-node-FB"]|)
    end
  end

  describe "search" do
    test "narrows visible nodes to matches and their ancestors", %{conn: conn} do
      view = open_subjects_tab(conn)

      view
      |> element(~s|input[data-test-id="thema-picker-search"]|)
      |> render_keyup(%{"value" => "detective"})

      # Match (FFC) and its ancestor chain (F, FF) are visible.
      assert has_element?(view, ~s|[data-test-id="thema-node-FFC"]|)
      assert has_element?(view, ~s|[data-test-id="thema-node-FF"]|)
      assert has_element?(view, ~s|[data-test-id="thema-node-F"]|)

      # Unrelated roots are hidden.
      refute has_element?(view, ~s|[data-test-id="thema-node-J"]|)
      refute has_element?(view, ~s|[data-test-id="thema-node-Y"]|)

      # The matched leaf carries the highlight marker.
      assert has_element?(view, ~s|[data-test-id="thema-node-FFC"][data-matched="true"]|)
    end

    test "Escape clears the search and restores roots", %{conn: conn} do
      view = open_subjects_tab(conn)

      view
      |> element(~s|input[data-test-id="thema-picker-search"]|)
      |> render_keyup(%{"value" => "detective"})

      refute has_element?(view, ~s|[data-test-id="thema-node-Y"]|)

      view
      |> element(~s|[data-test-id="thema-tree-picker"]|)
      |> render_keydown(%{"key" => "Escape"})

      assert has_element?(view, ~s|[data-test-id="thema-node-Y"]|)
    end
  end

  describe "multi-select + pill bar" do
    test "checkbox click selects a node and emits a pill", %{conn: conn} do
      view = open_subjects_tab(conn)

      view |> element(~s|[data-test-id="thema-toggle-F"]|) |> render_click()
      view |> element(~s|[data-test-id="thema-toggle-FB"]|) |> render_click()
      view |> element(~s|[data-test-id="thema-checkbox-FBA"]|) |> render_click()

      assert has_element?(view, ~s|[data-test-id="thema-pill-FBA"]|)
      assert has_element?(view, ~s|[data-test-id="thema-node-FBA"][data-selected="true"]|)
    end

    test "removing a pill deselects the node", %{conn: conn} do
      view = open_subjects_tab(conn)

      view |> element(~s|[data-test-id="thema-toggle-F"]|) |> render_click()
      view |> element(~s|[data-test-id="thema-toggle-FB"]|) |> render_click()
      view |> element(~s|[data-test-id="thema-checkbox-FBA"]|) |> render_click()
      view |> element(~s|[data-test-id="thema-checkbox-FBC"]|) |> render_click()

      assert has_element?(view, ~s|[data-test-id="thema-pill-FBA"]|)
      assert has_element?(view, ~s|[data-test-id="thema-pill-FBC"]|)

      view
      |> element(~s|[data-test-id="thema-pill-remove-FBA"]|)
      |> render_click()

      refute has_element?(view, ~s|[data-test-id="thema-pill-FBA"]|)
      assert has_element?(view, ~s|[data-test-id="thema-pill-FBC"]|)
    end
  end

  describe "keyboard navigation" do
    test "ArrowDown moves focus to the next visible node", %{conn: conn} do
      view = open_subjects_tab(conn)

      # Focus starts on the first root (F). ArrowDown → J.
      view
      |> element(~s|[data-test-id="thema-tree-picker"]|)
      |> render_keydown(%{"key" => "ArrowDown"})

      assert has_element?(view, ~s|[data-test-id="thema-node-J"][data-focused="true"]|)
    end

    test "Enter on focused node toggles selection", %{conn: conn} do
      view = open_subjects_tab(conn)

      view
      |> element(~s|[data-test-id="thema-tree-picker"]|)
      |> render_keydown(%{"key" => "Enter"})

      # Focus default = first root = F. Enter selects it.
      assert has_element?(view, ~s|[data-test-id="thema-pill-F"]|)
      assert has_element?(view, ~s|[data-test-id="thema-node-F"][data-selected="true"]|)
    end

    test "ArrowRight expands the focused node", %{conn: conn} do
      view = open_subjects_tab(conn)

      view
      |> element(~s|[data-test-id="thema-tree-picker"]|)
      |> render_keydown(%{"key" => "ArrowRight"})

      # F now expanded → its children (FB, FF) appear.
      assert has_element?(view, ~s|[data-test-id="thema-node-FB"]|)
    end

    test "ArrowLeft collapses an expanded focused node", %{conn: conn} do
      view = open_subjects_tab(conn)

      view |> element(~s|[data-test-id="thema-toggle-F"]|) |> render_click()
      assert has_element?(view, ~s|[data-test-id="thema-node-FB"]|)

      view
      |> element(~s|[data-test-id="thema-tree-picker"]|)
      |> render_keydown(%{"key" => "ArrowLeft"})

      refute has_element?(view, ~s|[data-test-id="thema-node-FB"]|)
    end
  end

  describe "selection emission contract" do
    test "BookEditor parent receives :thema_selection_changed and mirrors into assigns",
         %{conn: conn} do
      view = open_subjects_tab(conn)

      # Drill down + select FBA.
      view |> element(~s|[data-test-id="thema-toggle-F"]|) |> render_click()
      view |> element(~s|[data-test-id="thema-toggle-FB"]|) |> render_click()
      view |> element(~s|[data-test-id="thema-checkbox-FBA"]|) |> render_click()

      # The parent BookEditor mirrors the picker's selection into @subjects_thema
      # via handle_info({:thema_selection_changed, _}, …). Re-rendering the picker
      # with the parent's selection (passed back via the live_component selected={…}
      # assign) must keep the pill in place — proving the round-trip works.
      assert has_element?(view, ~s|[data-test-id="thema-pill-FBA"]|)

      # Add another and assert both remain selected after the parent re-renders.
      view |> element(~s|[data-test-id="thema-checkbox-FBC"]|) |> render_click()
      assert has_element?(view, ~s|[data-test-id="thema-pill-FBA"]|)
      assert has_element?(view, ~s|[data-test-id="thema-pill-FBC"]|)
    end
  end
end
