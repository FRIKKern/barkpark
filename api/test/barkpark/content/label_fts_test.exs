defmodule Barkpark.Content.LabelFtsTest do
  @moduledoc """
  FTS shape-safety for weighted tags (authoring-excellence D8).

  The generated `documents.search_vector` folds all *string* leaves of `content`
  into a tsvector via `jsonb_to_tsvector('english', content, '["string"]')`. The
  `["string"]` filter means only JSON string values are indexed — a weighted tag
  object's `tag` and `rationale` strings land in the vector, while its numeric
  `strength` is skipped. No migration or column change is needed for the flat →
  weighted tags flip; this test is the protective proof.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Repo

  @dataset "label_fts_test"

  setup do
    Content.upsert_schema(
      %{
        "name" => "paper",
        "title" => "Paper",
        "visibility" => "public",
        "fields" => [
          %{
            "name" => "tags",
            "type" => "arrayOf",
            "of" => %{
              "type" => "composite",
              "fields" => [
                %{"name" => "tag", "type" => "string"},
                %{"name" => "strength", "type" => "number"},
                %{"name" => "rationale", "type" => "string"}
              ]
            }
          }
        ]
      },
      @dataset
    )

    :ok
  end

  test "search_vector indexes the tag lexeme and skips the strength number" do
    content = %{
      "_id" => "p-weighted",
      "title" => "Weighted Tags Paper",
      # The S2 publish wall also requires a description; the assertions below
      # stay about the TAG lexemes and the skipped strength integers.
      "description" => "Proves the search vector indexes tag lexemes only.",
      "tags" => [
        %{"tag" => "obsidian", "strength" => 80, "rationale" => "Central to the workflow here."},
        %{
          "tag" => "findability",
          "strength" => 45,
          "rationale" => "Secondary supporting concept."
        }
      ]
    }

    {:ok, _} = Content.create_document("paper", content, @dataset)
    {:ok, _} = Content.publish_document("p-weighted", "paper", @dataset)

    %{rows: [[vector]]} =
      Repo.query!(
        "SELECT search_vector::text FROM documents WHERE doc_id = $1 AND dataset = $2 AND status = 'published'",
        ["p-weighted", @dataset]
      )

    # Tag string leaves ARE indexed (band D — the jsonb string bucket).
    # ('english' stems the lexemes: "findability" → "findabl".)
    assert vector =~ "obsidian"
    assert vector =~ "findabl"
    # A rationale word is indexed too (confirms the string filter reaches
    # nested object values, not just top-level strings).
    assert vector =~ "central" or vector =~ "workflow"

    # Strength NUMBERS are NOT indexed — the '["string"]' filter skips them.
    # The lexeme "80" / "45" must be absent (chosen so no indexed word contains
    # them as a substring).
    refute vector =~ "80"
    refute vector =~ "45"
  end
end
