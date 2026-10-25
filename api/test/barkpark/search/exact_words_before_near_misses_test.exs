defmodule Barkpark.Search.ExactWordsBeforeNearMissesTest do
  @moduledoc """
  A search widened to near misses keeps the documents that hold the words
  themselves first. Pensum's "helseøkonomi" had one exact hit, a book whose
  description says it; the thin-results pass widened it, and 32 titles that
  merely looked like the word ("Kommuneøkonomi", "Mikroøkonomi") ranked above
  that book, so a caller reading the first 10 never saw it.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Search.{QueryPipeline, SurfaceConfigs}

  @ds "exact-before-near"

  setup do
    SurfaceConfigs.seed_defaults!()

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @ds
    )

    publish = fn id, content ->
      Content.create_document("post", Map.put(content, "doc_id", "drafts." <> id), @ds)
      Content.publish_document(id, "post", @ds)
    end

    publish.("held", %{
      "title" => "Prioritering i helsetjenesten",
      "description" => "Vi gir en innføring i helseøkonomi for prioritering."
    })

    for {title, i} <-
          Enum.with_index(~w(Kommuneøkonomi Mikroøkonomi Rettsøkonomi Nasjonaløkonomi)) do
      publish.("near-#{i}", %{"title" => title, "description" => "Lærebok."})
    end

    :ok
  end

  test "the one document holding the word ranks before the near misses the widened pass adds" do
    assert {:ok, result} =
             QueryPipeline.search(
               "documents",
               @ds,
               %{query: "helseøkonomi", filters: %{}, offset: 0},
               perspective: :published,
               limit: 10
             )

    assert result.recovery == "typo_widen"
    assert result.total > 1
    assert hd(result.hits).doc_id == "held"
  end
end
