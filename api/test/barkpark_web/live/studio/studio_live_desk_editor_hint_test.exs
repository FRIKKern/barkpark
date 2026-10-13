defmodule BarkparkWeb.Studio.StudioLiveDeskEditorHintTest do
  @moduledoc """
  A type can declare its main editor (task-d80fe8cbfdc9cbcc): `desk.editor`
  `"freeform"` opens its documents in the block editor; `"classic"` or no hint
  keeps the schema form. The toggle still switches either way.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  defp schema(name, desk) do
    Content.upsert_schema(
      %{
        "name" => name,
        "title" => name,
        "visibility" => "public",
        "desk" => desk,
        "fields" => [
          %{"name" => "title", "title" => "Title", "type" => "string"},
          %{"name" => "body", "title" => "Body", "type" => "richText"}
        ],
        "layout" => [
          %{"kind" => "field", "name" => "title"},
          %{"kind" => "region", "name" => "body"}
        ]
      },
      @dataset
    )
  end

  test "a freeform type opens in the block editor", %{conn: conn} do
    {:ok, _} = schema("story", %{"editor" => "freeform"})

    {:ok, _} =
      Content.create_document("story", %{"doc_id" => "hint-story", "title" => "S"}, @dataset)

    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/story/hint-story"))
    assert html =~ ~s(data-test-id="studio-doc-beta-editor")

    classic = view |> element(~s([data-test-id="editor-mode-classic"])) |> render_click()
    refute classic =~ ~s(data-test-id="studio-doc-beta-editor")
  end

  test "no hint, or classic, keeps the form", %{conn: conn} do
    for {name, desk} <- [{"plainpost", %{}}, {"classicpost", %{"editor" => "classic"}}] do
      {:ok, _} = schema(name, desk)

      {:ok, _} =
        Content.create_document(name, %{"doc_id" => "hint-#{name}", "title" => "P"}, @dataset)

      {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/#{name}/hint-#{name}"))
      refute html =~ ~s(data-test-id="studio-doc-beta-editor"), name
    end
  end

  test "the schema read returns the hint, and an unknown editor is refused" do
    {:ok, _} = schema("story", %{"editor" => "freeform"})
    {:ok, stored} = Content.get_schema("story", @dataset)
    assert Content.serialize_schema_for_sdk(stored).desk["editor"] == "freeform"

    assert {:error, %Ecto.Changeset{}} = schema("story", %{"editor" => "wysiwyg"})
  end
end
