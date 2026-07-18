defmodule Barkpark.ContentDocumentBlockOpSourceTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Content

  test "generic document BlockOp cannot implicitly replace an HTML-only Paper" do
    slug = "generic-html-fence-#{System.unique_integer([:positive])}"
    html = "<h1>Authored source</h1><p>Must survive byte-for-byte.</p>"

    {:ok, before} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: slug, dataset: "test", body_html: html})
      )

    op = %{
      "op" => "append-block",
      "block" => %{"id" => "replacement", "type" => "paragraph", "text" => "replacement"}
    }

    assert {:error, {:halted, message}} =
             Content.apply_document_block_op(slug, "paper", op, "test")

    assert message =~ "HTML-only papers are read-only"
    assert Content.get_paper(slug, "test") == before
  end
end
