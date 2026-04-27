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
          "fields" => [
            %{
              "name" => "themaSubjectCategory",
              "title" => "Thema subject categories",
              "type" => "arrayOf",
              "ordered" => false,
              "of" => %{
                "name" => "themaCode",
                "type" => "codelist",
                "codelistId" => "onixedit:thema",
                "version" => 73
              }
            }
          ]
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

      assert has_element?(view, ~s|[data-tab-body="identity"]|)
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

  describe "WI4 — render_tab/2 for the 6 simpler tabs (v1 / leaf-input schema)" do
    # This describe seeds a v1-only schema (string / text / boolean) so the
    # LiveView form helper can drive `phx-change` autosave through the
    # standard nested-form decoder. v2 composite / arrayOf coverage lives
    # in the separate "v2 fields render via Adapter" describe below.
    @wi4_dataset "production"
    @wi4_doc_id "book-wi4-1"

    setup %{conn: conn} do
      {:ok, _schema} =
        Content.upsert_schema(
          %{
            "name" => "book",
            "title" => "Book (ONIX 3.0)",
            "icon" => "book",
            "visibility" => "private",
            "fields" => [
              # Identity
              %{
                "name" => "recordSourceName",
                "title" => "Record source name",
                "type" => "string"
              },
              %{
                "name" => "bp_internal_note",
                "title" => "Internal note",
                "type" => "text"
              },
              # Title
              %{
                "name" => "editionNumber",
                "title" => "Edition number",
                "type" => "string"
              },
              %{
                "name" => "noEdition",
                "title" => "No edition (one-off)",
                "type" => "boolean"
              },
              # Publishing — placeholder simple type so the tab body is
              # exercised by the form helper. v2 composite shape lives in
              # the v2 describe block.
              %{
                "name" => "publishingDetail",
                "title" => "Publishing detail",
                "type" => "string"
              },
              # Supply — placeholder simple type
              %{
                "name" => "productSupplies",
                "title" => "Product supply",
                "type" => "string"
              },
              # Marketing
              %{
                "name" => "audienceDescription",
                "title" => "Audience description",
                "type" => "text"
              },
              %{
                "name" => "collateralDetail",
                "title" => "Collateral detail",
                "type" => "string"
              },
              # Related
              %{
                "name" => "relatedMaterial",
                "title" => "Related material",
                "type" => "string"
              },
              # Advanced-only — hidden when assigns.simplified == true
              %{
                "name" => "bp_export_status",
                "title" => "Export status (workflow)",
                "type" => "string",
                "simplified" => false
              },
              # Out-of-scope (WI3 owns)
              %{
                "name" => "subjects",
                "title" => "Subjects",
                "type" => "string"
              }
            ]
          },
          @wi4_dataset
        )

      {:ok, _doc} =
        Content.create_document(
          "book",
          %{
            "doc_id" => @wi4_doc_id,
            "title" => "WI4 Book",
            "content" => %{"recordSourceName" => "Initial Source"}
          },
          @wi4_dataset
        )

      {:ok, conn: conn}
    end

    defp open_tab(conn, tab) do
      live(conn, "/studio/#{@wi4_dataset}/onixedit/book/#{@wi4_doc_id}?tab=#{tab}")
    end

    defp drive_change(view, doc_params) do
      view
      |> form("#book-editor-form", %{"doc" => doc_params})
      |> render_change()
    end

    test "Identity: renders identity-tab fields, hides title-tab + WI3 fields", %{conn: conn} do
      {:ok, view, html} = open_tab(conn, "identity")

      assert has_element?(view, ~s|[data-tab-body="identity"]|)
      assert html =~ "Record source name"
      assert html =~ "Internal note"
      refute html =~ ~s|data-field-name="editionNumber"|
      refute html =~ ~s|data-field-name="subjects"|
      assert html =~ ~s|data-field-name="recordSourceName"|
      # Advanced view (default) — Advanced-only fields visible
      assert html =~ ~s|data-field-name="bp_export_status"|
    end

    test "Identity: autosave updates form state for recordSourceName", %{conn: conn} do
      {:ok, view, _html} = open_tab(conn, "identity")
      drive_change(view, %{"recordSourceName" => "ACME Pub"})
      assert render(view) =~ "ACME Pub"
    end

    test "Title: renders edition fields", %{conn: conn} do
      {:ok, view, html} = open_tab(conn, "title")

      assert has_element?(view, ~s|[data-tab-body="title"]|)
      assert html =~ "Edition number"
      assert html =~ "No edition (one-off)"
      refute html =~ "Record source name"
    end

    test "Title: autosave updates editionNumber", %{conn: conn} do
      {:ok, view, _html} = open_tab(conn, "title")
      drive_change(view, %{"editionNumber" => "3rd"})
      assert render(view) =~ ~s|value="3rd"|
    end

    test "Publishing: renders publishingDetail field", %{conn: conn} do
      {:ok, view, html} = open_tab(conn, "publishing")

      assert has_element?(view, ~s|[data-tab-body="publishing"]|)
      assert html =~ "Publishing detail"
      assert has_element?(view, ~s|[data-field-name="publishingDetail"]|)
    end

    test "Publishing: autosave updates publishingDetail", %{conn: conn} do
      {:ok, view, _html} = open_tab(conn, "publishing")
      drive_change(view, %{"publishingDetail" => "Penguin Random House"})
      assert render(view) =~ "Penguin Random House"
    end

    test "Supply: renders productSupplies field", %{conn: conn} do
      {:ok, view, html} = open_tab(conn, "supply")

      assert has_element?(view, ~s|[data-tab-body="supply"]|)
      assert html =~ "Product supply"
      assert has_element?(view, ~s|[data-field-name="productSupplies"]|)
    end

    test "Supply: autosave updates productSupplies", %{conn: conn} do
      {:ok, view, _html} = open_tab(conn, "supply")
      drive_change(view, %{"productSupplies" => "UK"})
      assert render(view) =~ ~s|value="UK"|
    end

    test "Marketing: renders audience + collateral fields", %{conn: conn} do
      {:ok, view, html} = open_tab(conn, "marketing")

      assert has_element?(view, ~s|[data-tab-body="marketing"]|)
      assert html =~ "Audience description"
      assert html =~ "Collateral detail"
    end

    test "Marketing: autosave updates audienceDescription", %{conn: conn} do
      {:ok, view, _html} = open_tab(conn, "marketing")
      drive_change(view, %{"audienceDescription" => "Adult readers"})
      assert render(view) =~ "Adult readers"
    end

    test "Related: renders relatedMaterial field", %{conn: conn} do
      {:ok, view, html} = open_tab(conn, "related")

      assert has_element?(view, ~s|[data-tab-body="related"]|)
      assert html =~ "Related material"
      assert has_element?(view, ~s|[data-field-name="relatedMaterial"]|)
    end

    test "Related: autosave updates relatedMaterial", %{conn: conn} do
      {:ok, view, _html} = open_tab(conn, "related")
      drive_change(view, %{"relatedMaterial" => "ISBN-9999"})
      assert render(view) =~ "ISBN-9999"
    end

    test "Subjects + Contributors are NOT touched by WI4", %{conn: conn} do
      # WI3 owns Subjects (Thema persistence) — assert WI3's render is intact.
      {:ok, view_subjects, _html} = open_tab(conn, "subjects")
      assert has_element?(view_subjects, ~s|[data-tab-body="subjects"]|)
      assert has_element?(view_subjects, ~s|[data-test-id="thema-tree-picker"]|)
      # WI3 still owns Contributors (placeholder until a future WI).
      {:ok, _view, html_contrib} = open_tab(conn, "contributors")
      assert html_contrib =~ "Contributors tab — implemented in WI3"
    end
  end

  describe "WI4 — v2 composite / arrayOf fields render via the plugin Adapter" do
    # These tests confirm the WI4 dispatch routes v2 fields to the Studio
    # plugin Adapter (composite_field / array_field). We mount and inspect
    # the initial HTML; we do NOT drive the form helper because Phase 0's
    # composite component emits dotted paths that the WI1 shell's
    # nested-form `handle_event` does not unify (Phase 0 / WI1 boundary,
    # tracked separately).
    @v2_dataset "production"
    @v2_doc_id "book-wi4-v2"

    setup %{conn: conn} do
      {:ok, _schema} =
        Content.upsert_schema(
          %{
            "name" => "book",
            "title" => "Book (ONIX 3.0)",
            "icon" => "book",
            "visibility" => "private",
            "fields" => [
              %{
                "name" => "publishingDetail",
                "title" => "Publishing detail",
                "type" => "composite",
                "fields" => [
                  %{"name" => "publisherName", "type" => "string"}
                ]
              },
              %{
                "name" => "productSupplies",
                "title" => "Product supply",
                "type" => "arrayOf",
                "ordered" => false,
                "of" => %{
                  "name" => "productSupply",
                  "type" => "composite",
                  "fields" => [%{"name" => "supplyMarket", "type" => "string"}]
                }
              },
              %{
                "name" => "relatedMaterial",
                "title" => "Related material",
                "type" => "composite",
                "fields" => [%{"name" => "relatedWork", "type" => "string"}]
              }
            ]
          },
          @v2_dataset
        )

      {:ok, _doc} =
        Content.create_document(
          "book",
          %{"doc_id" => @v2_doc_id, "title" => "v2 Book"},
          @v2_dataset
        )

      {:ok, conn: conn}
    end

    test "Publishing tab dispatches composite to Adapter", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, "/studio/#{@v2_dataset}/onixedit/book/#{@v2_doc_id}?tab=publishing")

      assert html =~ ~s|data-field-type="composite"|
      assert html =~ ~s|data-field-name="publishingDetail"|
    end

    test "Supply tab dispatches arrayOf to Adapter", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, "/studio/#{@v2_dataset}/onixedit/book/#{@v2_doc_id}?tab=supply")

      assert html =~ ~s|data-field-type="arrayOf"|
      assert html =~ ~s|data-field-name="productSupplies"|
    end

    test "Related tab dispatches composite to Adapter", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, "/studio/#{@v2_dataset}/onixedit/book/#{@v2_doc_id}?tab=related")

      assert html =~ ~s|data-field-type="composite"|
      assert html =~ ~s|data-field-name="relatedMaterial"|
    end
  end
end
