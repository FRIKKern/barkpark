defmodule BarkparkWeb.Studio.PaperEditor.PropertiesControlsTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @doc_type "property-controls"
  @doc_id "properties-round-trip"
  @stored_id "drafts." <> @doc_id

  setup do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Property controls",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "accent", "title" => "Accent", "type" => "color"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ],
          "layout" => [
            %{"kind" => "field", "name" => "title", "max" => 1, "enforce" => true},
            %{"kind" => "field", "name" => "accent", "max" => 1, "enforce" => true},
            %{"kind" => "region", "name" => "body"}
          ]
        },
        @dataset
      )

    {:ok, _doc} =
      Content.create_document(
        @doc_type,
        %{"doc_id" => @doc_id, "title" => "Properties round trip"},
        @dataset
      )

    accent = Enum.find(stored_blocks(), &(&1["fieldName"] == "accent"))

    {:ok, _} =
      Content.apply_document_block_op(
        @stored_id,
        @doc_type,
        %{"op" => "remove-block", "id" => accent["id"]},
        @dataset
      )

    :ok
  end

  test "Add property and Unbind controls persist projection changes across reload", %{conn: conn} do
    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/#{@doc_type}/#{@doc_id}"))

    view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()

    assert has_element?(view, ~s([data-test-id="paper-add-property"] select[name="fieldName"]))

    view
    |> element(~s([data-test-id="paper-add-property"]))
    |> render_submit(%{
      "fieldName" => "accent",
      "if_rev" => current_rev(view)
    })

    added = Enum.find(stored_blocks(), &(&1["fieldName"] == "accent"))
    assert added["type"] == "field-color"
    assert added["label"] == "Accent"

    {:ok, saved_after_add} = Content.get_document(@stored_id, @doc_type, @dataset)
    assert saved_after_add.content["accent"] == "#000000"

    assert has_element?(
             view,
             ~s([data-prop-block-id="#{added["id"]}"] [data-test-id="paper-unbind-property"])
           )

    view
    |> element(~s([data-prop-block-id="#{added["id"]}"] [data-test-id="paper-unbind-property"]))
    |> render_click(%{"if_rev" => current_rev(view)})

    unbound = Enum.find(stored_blocks(), &(&1["id"] == added["id"]))
    assert unbound["fieldName"] == nil

    {:ok, saved_after_unbind} = Content.get_document(@stored_id, @doc_type, @dataset)
    refute Map.has_key?(saved_after_unbind.content, "accent")

    {:ok, reloaded, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/#{@doc_type}/#{@doc_id}"))

    reloaded |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()

    assert has_element?(reloaded, ~s([data-edit-block-id="#{added["id"]}"]))
    refute has_element?(reloaded, ~s([data-prop-block-id="#{added["id"]}"]))
  end

  defp stored_blocks do
    {:ok, doc} = Content.get_document(@stored_id, @doc_type, @dataset)
    doc.content["blocks"]
  end

  defp current_rev(view), do: :sys.get_state(view.pid).socket.assigns.editor_doc.rev
end
