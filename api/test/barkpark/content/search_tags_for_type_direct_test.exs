defmodule Barkpark.Content.SearchTagsForTypeDirectTest do
  @moduledoc """
  Direct boundary test for `Content.search_tags_for_type/5` — the `#tag`
  autocomplete candidate reader (studio_live.ex:490 → handlers/paper.ex:527 →
  query.ex:935). Per charter D18 it is the ONLY live-wired Elixir tag reader
  (`docs_with_tag`/`papers_with_tag` are test-only, zero live callers), yet
  before this file it had NO direct named test of its own: it was exercised
  only transitively through the LiveView `paper_tag_search/2` handler. This
  file pins the function the wish names at its own boundary.

  DUAL-SHAPE (authoring-excellence D10/D19): a weighted
  `{tag, strength, rationale}` member must read as its tag NAME — never the
  serialized JSON blob, never a rationale-text ILIKE false positive — while a
  legacy flat string reads as itself, and both shapes are findable
  side-by-side. Type `post` is used deliberately: the reader's SQL is
  type-agnostic (only `d.type == ^type` filters; the COALESCE dual-shape logic
  never branches on type), so a non-walled type exercises the exact
  `COALESCE(e->>'tag', e #>> '{}')` unnest that a paper/task would, with the
  smallest fixture. E3 tag registration still runs unconditionally for `post`
  (charter D25), so the weighted member is registered first.

  ANTI-VACUOUS CONTROL: revert query.ex:1032's `COALESCE(e->>'tag', e #>> '{}')`
  to a flat-only `e #>> '{}'` and BOTH tests FAIL — the weighted member then
  unnests as its serialized JSON object (leaking the blob AND ILIKE-matching
  the `rationale` token) instead of the clean tag name.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.TagRegistry

  @dataset "search_tags_direct_test"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset
      )

    # Registers the core `tag` schema for this dataset so `register_tag!/1` can
    # publish type:tag docs (the canonical E3 registration act).
    TagRegistry.register!(@dataset)
    :ok
  end

  # Register a tag the canonical way (mirrors tag_registry_test.exs): publish a
  # type:tag doc whose _id is the tag name.
  defp register_tag!(name) do
    {:ok, _} = Content.create_document("tag", %{"doc_id" => name, "title" => name}, @dataset, [])
    {:ok, _} = Content.publish_document(name, "tag", @dataset, [])
    name
  end

  # A weighted label whose rationale carries a DISTINCTIVE token
  # ("provenance-…") absent from the tag NAME — a query for it proves the
  # reader never leaks rationale text as an autocomplete candidate.
  defp weighted(tag, strength) do
    %{
      "tag" => tag,
      "strength" => strength,
      "rationale" => "provenance-#{tag}: why this label was chosen for the doc."
    }
  end

  # Create → publish a `post` through the REAL publish path (Content wall / E3).
  defp publish_post!(doc_id, content) do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        []
      )

    {:ok, doc} = Content.publish_document(doc_id, "post", @dataset, [])
    doc
  end

  describe "search_tags_for_type/5 direct boundary (D10/D19)" do
    test "returns the weighted tag NAME — never the {tag,strength,rationale} blob or rationale token" do
      register_tag!("distributed-systems")
      publish_post!("post-weighted", %{"tags" => [weighted("distributed-systems", 90)]})

      # The tag NAME resolves cleanly for a name-substring query …
      assert Content.search_tags_for_type("distributed", "post", @dataset) ==
               ["distributed-systems"]

      # … the blank-query top list is the clean name, with no serialized-object
      # noise (a flat-only reader would surface `{"rationale":…,"tag":…}` here).
      results = Content.search_tags_for_type("", "post", @dataset)
      assert results == ["distributed-systems"]
      refute Enum.any?(results, &String.contains?(&1, "{"))

      # … and a query hitting ONLY the rationale text yields [] — the old
      # flat-only reader unnested the raw blob, so `provenance` ILIKE-matched
      # the rationale and surfaced a phantom candidate.
      assert Content.search_tags_for_type("provenance", "post", @dataset) == []
    end

    test "a legacy flat-string tag is findable SIDE-BY-SIDE with a weighted tag" do
      register_tag!("distributed-systems")
      publish_post!("post-weighted", %{"tags" => [weighted("distributed-systems", 90)]})

      # Legacy flat strings are not E3-gated (E3 self-scopes to weighted
      # members), so this pre-wall shape publishes as-is on the non-walled
      # `post` type — no registration, no exemption needed.
      publish_post!("post-legacy", %{"tags" => ["monolith-legacy"]})

      # Each shape answers its own name-substring query …
      assert Content.search_tags_for_type("monolith", "post", @dataset) == ["monolith-legacy"]

      assert Content.search_tags_for_type("distributed", "post", @dataset) ==
               ["distributed-systems"]

      # … and the blank-query top list carries BOTH clean names (name-ordered,
      # distinct), no blob noise. Under a flat-only COALESCE the weighted name
      # leaks its JSON object here — this assertion is the anti-vacuous control
      # for the mixed corpus.
      assert Content.search_tags_for_type("", "post", @dataset) ==
               ["distributed-systems", "monolith-legacy"]
    end
  end
end
