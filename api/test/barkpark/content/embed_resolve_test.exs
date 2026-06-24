defmodule Barkpark.Content.EmbedResolveTest do
  @moduledoc """
  `Content.resolve_embeds_in_blocks/3` — the note-embed (`![[note]]`) target →
  prerendered-HTML authority that powers Studio view-mode transclusion. The
  render-only mirror of `resolve_wikilinks_in_blocks/3`: it deep-collects every
  distinct `target` from a top-level `"type" => "embed"` BLOCK, resolves each
  via the SAME title-or-alias authority wikilinks use, renders that target
  paper's blocks to one HTML string, and returns `%{target => html}`.

  Covers: a resolved embed transcludes the target's prose; a NON-existent target
  is DROPPED (absent from the map → walker shows the fallback); and a `B → A`
  embed inside a transcluded note does NOT recurse (B renders with an EMPTY
  embed map, so B's embed of A is a fallback, never a re-render of A) — the
  one-level + cycle-proof guarantee.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  @dataset "embed_resolve_test"

  setup do
    Content.upsert_schema(
      %{
        "name" => "paper",
        "title" => "Paper",
        "visibility" => "public",
        "fields" => [%{"name" => "aliases", "type" => "arrayOf", "of" => %{"type" => "string"}}]
      },
      @dataset
    )

    :ok
  end

  # Seed a published paper carrying `blocks` as its portable-doc source of truth.
  defp paper!(id, title, blocks, attrs \\ %{}) do
    {:ok, _} =
      Content.create_document(
        "paper",
        Map.merge(
          %{"_id" => id, "title" => title, "blocks" => blocks},
          attrs
        ),
        @dataset
      )

    {:ok, doc} = Content.publish_document(id, "paper", @dataset)
    doc
  end

  defp prose(value) do
    %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => value}]}
  end

  defp embed(target), do: %{"type" => "embed", "target" => target}

  test "resolves an embed target to the transcluded HTML of the target's prose" do
    paper!("p-b", "B Note", [prose("the unmistakable B prose")])
    # A transcludes B by title.
    a_blocks = [prose("intro"), embed("B Note")]

    map = Content.resolve_embeds_in_blocks(a_blocks, @dataset)

    assert Map.has_key?(map, "B Note")
    html = map["B Note"]
    assert is_binary(html)
    # the transcluded string is B's RENDERED prose.
    assert html =~ "the unmistakable B prose"
  end

  test "a non-existent embed target is dropped (absent from the map)" do
    paper!("p-b", "B Note", [prose("B prose")])

    a_blocks = [embed("B Note"), embed("Does Not Exist")]

    map = Content.resolve_embeds_in_blocks(a_blocks, @dataset)

    assert Map.has_key?(map, "B Note")
    refute Map.has_key?(map, "Does Not Exist")
    assert map_size(map) == 1
  end

  test "dedups a repeated target and resolves it once" do
    paper!("p-b", "B Note", [prose("B prose")])

    a_blocks = [embed("B Note"), prose("mid"), embed("B Note")]

    map = Content.resolve_embeds_in_blocks(a_blocks, @dataset)

    assert map_size(map) == 1
    assert Map.has_key?(map, "B Note")
  end

  test "B→A embed inside a transcluded note does NOT recurse (one-level, cycle-proof)" do
    # A's distinctive prose must NEVER leak into B's transcluded HTML: B is
    # rendered with an EMPTY embed map, so B's `![[A]]` is a fallback, not a
    # re-render of A. This makes an A→B→A cycle impossible by construction.
    paper!("p-a", "A Note", [prose("the A prose marker")])
    paper!("p-b", "B Note", [prose("B body"), embed("A Note")])

    # The HOST (A) transcludes B.
    a_blocks = [embed("B Note")]

    map = Content.resolve_embeds_in_blocks(a_blocks, @dataset)

    assert Map.has_key?(map, "B Note")
    b_html = map["B Note"]

    # B's own prose is present…
    assert b_html =~ "B body"
    # …but A's prose is NOT — B's nested embed of A fell back, did not recurse.
    refute b_html =~ "the A prose marker"
    # The whole map is one entry: only the host's direct embed of B.
    assert map_size(map) == 1
  end

  test "a self-embed (A embeds A) does not infinite-loop" do
    # A transcludes ITSELF. The host map renders A's blocks with an empty embed
    # map, so the nested self-embed falls back instead of recursing — finite.
    paper!("p-a", "A Note", [prose("A solo prose"), embed("A Note")])

    a_blocks = [embed("A Note")]

    map = Content.resolve_embeds_in_blocks(a_blocks, @dataset)

    assert Map.has_key?(map, "A Note")
    html = map["A Note"]
    # The transcluded copy carries A's prose…
    assert html =~ "A solo prose"
    # …and terminates: the map has a single entry, no runaway expansion.
    assert map_size(map) == 1
  end
end
