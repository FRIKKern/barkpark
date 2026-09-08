defmodule Barkpark.Content.PaperTableSourceTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.PortableDoc.Render

  test "a cell edit preserves untouched admitted header, cell and inline metadata sources" do
    slug = "table-source-#{System.unique_integer([:positive])}"

    table = %{
      "id" => "source-table",
      "type" => "table",
      "head" => [
        [%{"type" => "text", "value" => "Name"}],
        [%{"type" => "text", "value" => "Count"}]
      ],
      "rows" => [
        [
          [%{"type" => "text", "value" => "Alpha"}],
          %{"content" => [%{"type" => "text", "value" => "42"}], "qa" => "cell"}
        ],
        [[%{"type" => "text", "value" => "Beta", "qa" => %{"keep" => true}}], []]
      ],
      "qa" => %{"origin" => "source-preservation"}
    }

    assert {:ok, _} =
             Content.upsert_paper(
               Barkpark.LabelFixtures.paper_attrs(%{
                 slug: slug,
                 style: "article",
                 blocks: [table]
               })
             )

    before = Content.get_paper(slug)
    assert before.content["blocks"] == [table]

    rows = [
      [
        [%{"type" => "text", "value" => "Alpha edited"}],
        get_in(table, ["rows", Access.at(0), Access.at(1)])
      ],
      Enum.at(table["rows"], 1)
    ]

    assert {:ok, result} =
             Content.apply_paper_block_ops(
               slug,
               [%{"op" => "patch-block", "id" => table["id"], "patch" => %{"rows" => rows}}],
               "production",
               if_rev: before.content["rev"]
             )

    after_edit = Content.get_paper(slug)
    expected = Map.put(table, "rows", rows)
    assert after_edit.content["blocks"] == [expected]
    assert result.rev == before.content["rev"] + 1
    assert after_edit.content["rev"] == result.rev

    for style <- [:article, :email] do
      html = Render.render_blocks([expected], %{style: style})
      assert html =~ "Alpha edited"
      assert html =~ "Beta"
      assert html =~ "42"
    end

    # A deliberate header removal is distinct from an omitted header patch.
    assert {:ok, removed} =
             Content.apply_paper_block_ops(
               slug,
               [%{"op" => "patch-block", "id" => table["id"], "patch" => %{"head" => []}}],
               "production",
               if_rev: result.rev
             )

    assert removed.rev == result.rev + 1
    assert Content.get_paper(slug).content["blocks"] == [Map.put(expected, "head", [])]
  end

  test "unsupported numeric and null cells still fail the publish boundary" do
    for value <- [42, nil] do
      assert {:error, {:invalid_paper_structure, _}} =
               Content.upsert_paper(
                 Barkpark.LabelFixtures.paper_attrs(%{
                   slug: "table-refused-#{System.unique_integer([:positive])}",
                   style: "article",
                   blocks: [%{"id" => "table", "type" => "table", "rows" => [[value]]}]
                 })
               )
    end
  end
end
