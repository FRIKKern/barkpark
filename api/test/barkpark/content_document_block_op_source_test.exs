defmodule Barkpark.ContentDocumentBlockOpSourceTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Content

  test "generic document BlockOp cannot implicitly replace an HTML-only Paper" do
    slug = "generic-html-fence-#{System.unique_integer([:positive])}"
    html = "<h1>Authored source</h1><p>Must survive byte-for-byte.</p>"

    {:ok, _written} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: slug, dataset: "test", body_html: html})
      )

    # Re-read the baseline from the DB rather than trusting the struct the write
    # RETURNED. A paper upsert now records a revision ([paper-upsert-unlogged-clobber]),
    # and the `bind_document_revision` trigger advances `documents.current_revision_id`
    # AFTER the returning struct was built — so the in-memory struct is stale in
    # exactly that one column. Comparing two fresh reads keeps this assertion's
    # meaning intact (the halted op changed nothing byte-for-byte) without
    # asserting against a value the write path never populated in memory.
    before = Content.get_paper(slug, "test")

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
