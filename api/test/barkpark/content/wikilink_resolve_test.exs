defmodule Barkpark.Content.WikilinkResolveTest do
  @moduledoc """
  `Content.resolve_wikilink/3` — the wikilink `target` → `%{id, title}` authority
  that powers navigable wikilinks (the `[[` autocomplete picks a target; this
  turns the stored string into a doc on render).

  Covers the NEW resolution logic: case-insensitive TITLE match, exact ALIAS
  match (JSONB scalar containment over `content["aliases"]`), title-beats-alias
  PRECEDENCE on a collision, and blank/miss → nil. The dataset + workspace leak
  guard is inherited verbatim from `get_document/4` (already covered elsewhere).
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  @dataset "wikilink_resolve_test"

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

  defp paper!(id, title, attrs \\ %{}) do
    {:ok, _} =
      Content.create_document(
        "paper",
        Map.merge(%{"_id" => id, "title" => title}, attrs),
        @dataset
      )

    {:ok, doc} = Content.publish_document(id, "paper", @dataset)
    doc
  end

  test "resolves by title, case-insensitively" do
    paper!("p-intro", "Intro to X")

    assert %{id: "p-intro", title: "Intro to X"} =
             Content.resolve_wikilink("Intro to X", @dataset)

    assert %{id: "p-intro"} = Content.resolve_wikilink("intro to x", @dataset)
    assert %{id: "p-intro"} = Content.resolve_wikilink("INTRO TO X", @dataset)
  end

  test "resolves by alias (exact scalar containment over content.aliases)" do
    paper!("p-setup", "Getting Started", %{"aliases" => ["setup", "install"]})

    assert %{id: "p-setup"} = Content.resolve_wikilink("setup", @dataset)
    assert %{id: "p-setup"} = Content.resolve_wikilink("install", @dataset)
    # alias match is EXACT — the @> form cannot case-fold.
    assert Content.resolve_wikilink("Setup", @dataset) == nil
  end

  test "title outranks an alias-only match on a collision" do
    paper!("p-title", "Overview")
    paper!("p-alias", "Other", %{"aliases" => ["Overview"]})

    # "Overview" is p-title's TITLE and p-alias's ALIAS → the title wins.
    assert %{id: "p-title"} = Content.resolve_wikilink("Overview", @dataset)
  end

  test "returns nil on no match and on blank/whitespace target" do
    paper!("p-x", "Something")

    assert Content.resolve_wikilink("does-not-exist", @dataset) == nil
    assert Content.resolve_wikilink("   ", @dataset) == nil
    assert Content.resolve_wikilink("", @dataset) == nil
  end
end
