defmodule Mix.Tasks.Onix.ImportWithdrawalDbTest do
  @moduledoc """
  The withdrawal branch against a REAL document, not just the dry-run print.

  `mix onix.import`'s `handle_product/3` used to create a draft for every
  `<Product>` unconditionally. An ONIX withdrawal notice
  (`<NotificationType>05</NotificationType>`, or a non-empty
  `<DeletionText>`) therefore resurfaced a withdrawn ISBN as a brand-new
  draft on every sync — the opposite of what the notice asks for.

  Every assertion here is scoped to the doc_id this test created. The test
  database is shared across agents and `MIX_TEST_PARTITION` is unset, so
  nothing may assert over a whole table.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Plugins.OnixEdit.Importer
  alias Mix.Tasks.Onix.Import

  @dataset "production"

  defp unique_ref, do: "onix-wd-#{System.unique_integer([:positive])}"

  defp seed_book!(doc_id) do
    attrs = %{
      "doc_id" => doc_id,
      "title" => "A Withdrawn Book",
      "status" => "draft",
      "content" => %{"_publishedId" => doc_id}
    }

    {:ok, doc} = Content.create_document("book", attrs, @dataset, source: :cli)
    doc
  end

  defp present?(doc_id) do
    match?({:ok, _}, Content.get_document("drafts.#{doc_id}", "book", @dataset)) or
      match?({:ok, _}, Content.get_document(doc_id, "book", @dataset))
  end

  defp silently(fun) do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      fun.()
    after
      Mix.shell(previous)
    end
  end

  describe "a withdrawal notice removes the document instead of re-drafting it" do
    test "NotificationType=05 deletes the existing document" do
      doc_id = unique_ref()
      seed_book!(doc_id)
      assert present?(doc_id), "premise: the seeded document exists before the withdrawal"

      product = %{"_publishedId" => doc_id, "notificationType" => "05"}

      assert silently(fn -> Import.handle_product(product, @dataset, false) end) == :ok
      refute present?(doc_id)
    end

    test "a non-empty DeletionText deletes the existing document" do
      doc_id = unique_ref()
      seed_book!(doc_id)
      assert present?(doc_id)

      product = %{
        "_publishedId" => doc_id,
        "notificationType" => "03",
        "deletionText" => "Withdrawn by publisher"
      }

      assert silently(fn -> Import.handle_product(product, @dataset, false) end) == :ok
      refute present?(doc_id)
    end

    test "a NORMAL product still creates its draft — the branch is not a blanket delete" do
      doc_id = unique_ref()
      product = %{"_publishedId" => doc_id, "notificationType" => "03"}

      assert silently(fn -> Import.handle_product(product, @dataset, false) end) == :ok
      assert present?(doc_id)
    end

    test "withdrawing a record we never held is a no-op SUCCESS, not a failure" do
      doc_id = unique_ref()
      refute present?(doc_id), "premise: this doc_id was never created"

      product = %{"_publishedId" => doc_id, "notificationType" => "05"}

      assert silently(fn -> Import.handle_product(product, @dataset, false) end) == :ok
      refute present?(doc_id)
    end

    test "the whole path from ONIX XML: seed, then withdraw via a parsed feed" do
      doc_id = unique_ref()
      seed_book!(doc_id)
      assert present?(doc_id)

      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ONIXMessage>
        <Product>
          <RecordReference>acme.example.com:#{doc_id}</RecordReference>
          <NotificationType>05</NotificationType>
          <DeletionText>Withdrawn by publisher</DeletionText>
        </Product>
      </ONIXMessage>
      """

      {:ok, %{products: [product], skipped: 0}} = Importer.parse_feed(xml)
      assert Importer.doc_id_for(product) == doc_id

      assert silently(fn -> Import.handle_product(product, @dataset, false) end) == :ok
      refute present?(doc_id)
    end
  end
end
