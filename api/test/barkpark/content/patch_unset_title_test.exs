defmodule Barkpark.Content.PatchUnsetTitleTest do
  @moduledoc """
  `patch {unset: ["title"]}` clears the title (task-a50bcf53bee78a53). The title
  is a row column, not only a content key, and the patch kept the stored column
  unless `set` named a new one, so Sanity-style clients that unset an emptied
  field could not clear a title. `set {title: ""}` always worked; unset now
  matches it, on a plain document and on one with a bound title block.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Mutations

  @ds "patch_unset_title_test"

  setup do
    for {name, layout} <- [
          {"note", nil},
          {"post",
           [%{"kind" => "field", "name" => "title"}, %{"kind" => "region", "name" => "body"}]}
        ] do
      schema = %{
        "name" => name,
        "title" => name,
        "visibility" => "public",
        "fields" => [%{"name" => "title", "type" => "string"}]
      }

      {:ok, _} =
        Content.upsert_schema(
          if(layout, do: Map.put(schema, "layout", layout), else: schema),
          @ds
        )
    end

    :ok
  end

  for type <- ["note", "post"] do
    test "unset title clears it (#{type})" do
      type = unquote(type)
      id = "#{type}-#{System.unique_integer([:positive])}"
      {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "Old title"}, @ds)

      {:ok, _} =
        Mutations.apply_mutations(
          [%{"patch" => %{"id" => "drafts." <> id, "type" => type, "unset" => ["title"]}}],
          @ds
        )

      {:ok, doc} = Content.get_document("drafts." <> id, type, @ds)
      assert doc.title in [nil, ""], "row title kept: #{inspect(doc.title)}"
      assert Map.get(doc.content, "title") in [nil, ""]

      for %{"fieldName" => "title"} = block <- doc.content["blocks"] || [] do
        assert block["value"] in [nil, ""], "bound title block kept its value"
      end
    end
  end

  test "set wins over unset of the same field in one patch" do
    id = "note-#{System.unique_integer([:positive])}"
    {:ok, _} = Content.create_document("note", %{"doc_id" => id, "title" => "Old"}, @ds)

    {:ok, _} =
      Mutations.apply_mutations(
        [
          %{
            "patch" => %{
              "id" => "drafts." <> id,
              "type" => "note",
              "set" => %{"title" => "New"},
              "unset" => ["title"]
            }
          }
        ],
        @ds
      )

    {:ok, doc} = Content.get_document("drafts." <> id, "note", @ds)
    assert doc.title == "New"
  end
end
