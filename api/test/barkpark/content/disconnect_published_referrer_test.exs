defmodule Barkpark.Content.DisconnectPublishedReferrerTest do
  @moduledoc """
  `disconnect_references/3` must strip the reference from EVERY stored row of a
  referencing document — the published row AND its draft — in both stored
  shapes (bare id and `{"_ref" => id}`), scalar and arrayOf.

  Routed to lane C from lane A's fixture (run 4): after an unpublish/delete
  with "disconnect references", a published referencer kept its reference.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  @dataset "disconnect_published_referrer_test"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "person", "title" => "Person", "visibility" => "public", "fields" => []},
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "article",
          "title" => "Article",
          "visibility" => "public",
          "fields" => [
            %{"name" => "author", "type" => "reference", "refType" => "person"},
            %{
              "name" => "editors",
              "type" => "arrayOf",
              "of" => %{"type" => "reference", "refType" => "person"}
            }
          ]
        },
        @dataset
      )

    :ok
  end

  defp publish!(type, id, attrs \\ %{}) do
    {:ok, _} =
      Content.create_document(type, Map.merge(%{"_id" => id, "title" => id}, attrs), @dataset)

    {:ok, doc} = Content.publish_document(id, type, @dataset)
    doc
  end

  defp ref(id), do: %{"_ref" => id, "_type" => "reference"}

  # The stored row, exactly — no perspective overlay.
  defp row(doc_id) do
    Repo.get_by!(Barkpark.Content.Document, doc_id: doc_id, dataset: @dataset)
  end

  defp reload_edges!(doc_id) do
    {:ok, doc} = Content.get_document(doc_id, "article", @dataset)
    {:ok, _} = Barkpark.EdgeProjector.Projector.upsert_record(doc)
  end

  for {label, author, editors} <- [
        {"bare id", "ada", ["ada", "bob"]},
        {"{_ref} object", %{"_ref" => "ada", "_type" => "reference"},
         [%{"_ref" => "ada", "_type" => "reference"}, "bob"]}
      ] do
    @author author
    @editors editors

    test "a published referrer WITH a draft is stripped in both rows (#{label})" do
      publish!("person", "ada")
      publish!("person", "bob")
      publish!("article", "art", %{"author" => @author, "editors" => @editors})

      # The author keeps editing after publishing: a draft twin that still
      # references the target sits beside the published row.
      {:ok, _} =
        Content.create_document(
          "article",
          %{
            "_id" => "drafts.art",
            "title" => "art (edited)",
            "author" => @author,
            "editors" => @editors
          },
          @dataset
        )

      reload_edges!("art")

      Content.disconnect_references("ada", @dataset)

      for id <- ["art", "drafts.art"] do
        content = row(id).content
        refute Map.has_key?(content, "author"), "#{id} still references ada: #{inspect(content)}"
        assert content["editors"] == ["bob"], "#{id} editors: #{inspect(content["editors"])}"
      end
    end
  end

  test "an arrayOf referrer is stripped even before the edge projector has run" do
    publish!("person", "ada")
    publish!("person", "bob")
    publish!("article", "fresh-arr", %{"editors" => [ref("ada"), "bob"]})
    # No reload_edges!/1: the materialised edges table has not caught up yet,
    # which is the normal state right after a write (the projector is async).

    Content.disconnect_references("ada", @dataset)

    assert row("fresh-arr").content["editors"] == ["bob"]
  end

  test "a published-only referrer is stripped ({_ref} shape, arrayOf only)" do
    publish!("person", "ada")
    publish!("article", "only-pub", %{"editors" => [ref("ada")]})
    reload_edges!("only-pub")

    Content.disconnect_references("ada", @dataset)

    assert row("only-pub").content["editors"] == []
  end
end
