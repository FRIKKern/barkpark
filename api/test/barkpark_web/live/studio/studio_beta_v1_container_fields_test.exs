defmodule BarkparkWeb.Studio.StudioBetaV1ContainerFieldsTest do
  @moduledoc """
  task-cd9aefaf2f6068d6: a v1 Sanity-style `array` field (`of: [%{type: string}]`)
  fell through `Synthesis.field_block_type/1` to `field-string`, so the Beta
  editor painted `tags: ["a","b"]` as one text input reading "ab", and one
  keystroke could write a string over the list.

  Now the array rides the arrayOf editor (one row per item) and edits write a
  list back; an array no editor can show truthfully (mixed member types) is
  left out of the block list and its stored value is untouched.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.PortableDoc.Synthesis

  @dataset "production"

  setup do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "tags",
              "title" => "Tags",
              "type" => "array",
              "of" => [%{"type" => "string"}]
            },
            %{
              "name" => "mixed",
              "title" => "Mixed",
              "type" => "array",
              "of" => [%{"type" => "string"}, %{"type" => "number"}]
            },
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ],
          "layout" => [
            %{"kind" => "field", "name" => "title"},
            %{"kind" => "field", "name" => "tags"},
            %{"kind" => "field", "name" => "mixed"},
            %{"kind" => "region", "name" => "body"}
          ]
        },
        @dataset
      )

    {:ok, _post} =
      Content.create_document(
        "post",
        %{
          "doc_id" => "v1-array-demo",
          "title" => "Arrays",
          "content" => %{"tags" => ["a", "b"], "mixed" => ["x", 1]}
        },
        @dataset
      )

    :ok
  end

  test "the mapping: v1 array/object never become field-string" do
    assert Synthesis.field_block_type("array") == "arrayOf"
    assert Synthesis.field_block_type("object") == "composite"
    refute Synthesis.field_block_type("array") == "field-string"

    fields = [
      %{"name" => "tags", "type" => "array", "of" => [%{"type" => "string"}]},
      %{"name" => "meta", "type" => "object", "fields" => [%{"name" => "k", "type" => "string"}]},
      %{
        "name" => "mixed",
        "type" => "array",
        "of" => [%{"type" => "string"}, %{"type" => "number"}]
      },
      %{"name" => "nums", "type" => "array", "of" => [%{"type" => "number"}]}
    ]

    layout = Enum.map(~w(tags meta mixed nums), &%{"kind" => "field", "name" => &1})

    content = %{
      "tags" => ["a", "b"],
      "meta" => %{"k" => "v"},
      "mixed" => ["x", 1],
      "nums" => [1, 2]
    }

    blocks = Synthesis.synthesize(layout, content, fields)
    by = Map.new(blocks, &{&1["fieldName"], &1})

    assert %{"type" => "arrayOf", "of" => %{"type" => "string"}, "value" => ["a", "b"]} =
             by["tags"]

    assert %{"type" => "composite", "value" => %{"k" => "v"}} = by["meta"]

    assert [%{"name" => "k", "type" => "string"}] =
             Enum.map(by["meta"]["fields"], &Map.take(&1, ~w(name type)))

    refute Map.has_key?(by, "mixed"),
           "a mixed-type array has no truthful editor — left out, value untouched"

    refute Map.has_key?(by, "nums"),
           "a number list edited as text rows would change its stored type"
  end

  test "Beta shows each tag as its own row, never 'ab', and an edit writes a list", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/v1-array-demo"))
    html = view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()

    {:ok, doc} = Content.get_document("drafts.v1-array-demo", "post", @dataset)
    tags = Enum.find(doc.content["blocks"], &(&1["fieldName"] == "tags"))
    assert tags["type"] == "arrayOf"
    refute Enum.any?(doc.content["blocks"], &(&1["fieldName"] == "mixed"))

    tree = LazyHTML.from_fragment(html)
    block = LazyHTML.query(tree, ~s([id="paper-fb-#{tags["id"]}"]))
    assert LazyHTML.attribute(block, "data-field-type") == ["arrayOf"]
    values = block |> LazyHTML.query("input") |> LazyHTML.attribute("value")
    assert "a" in values and "b" in values
    refute html =~ ~s(value="ab")
    refute html =~ ~s(value="x1")

    # An edit through the block's own form writes a LIST back, item by item.
    [first_name | _] = block |> LazyHTML.query("input") |> LazyHTML.attribute("name")

    view
    |> element(~s([id="paper-fb-#{tags["id"]}-form"]))
    |> render_change(%{first_name => "alpha"})

    # the block hands its patch to the LiveView as a message; let it land
    _ = render(view)

    {:ok, saved} = Content.get_document("drafts.v1-array-demo", "post", @dataset)
    assert saved.content["tags"] == ["alpha", "b"]
    assert saved.content["mixed"] == ["x", 1], "the unrepresentable field is untouched"
  end
end
