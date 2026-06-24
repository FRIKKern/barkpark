defmodule Barkpark.Content.BacklinksTest do
  @moduledoc """
  `Content.Backlinks.backlinks_for/3` — the reverse-link index. Given a target
  paper, find every OTHER paper whose blocks carry a wikilink that resolves to
  it (precise id-pin OR fallback string match), excluding the target itself,
  deduped by slug, each carrying a context snippet.

  Mirrors the fixture style of `WikilinkResolveTest` (a `paper` schema with an
  `aliases` array; real published rows via create + publish).
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  @dataset "backlinks_test"

  setup do
    Content.upsert_schema(
      %{
        "name" => "paper",
        "title" => "Paper",
        "visibility" => "public",
        "fields" => [
          %{"name" => "aliases", "type" => "arrayOf", "of" => %{"type" => "string"}},
          %{"name" => "blocks", "type" => "arrayOf", "of" => %{"type" => "object"}}
        ]
      },
      @dataset
    )

    :ok
  end

  # Create + publish a paper. `blocks` (when given) land under content["blocks"].
  defp paper!(id, title, blocks \\ nil, attrs \\ %{}) do
    base = %{"_id" => id, "title" => title}
    base = if blocks, do: Map.put(base, "blocks", blocks), else: base

    {:ok, _} = Content.create_document("paper", Map.merge(base, attrs), @dataset)
    {:ok, doc} = Content.publish_document(id, "paper", @dataset)
    doc
  end

  # A paragraph block whose content holds `lead` text, a wikilink (extra attrs
  # merged onto the node), then `tail` text — so the block snippet is non-trivial.
  defp para_with_wikilink(lead, wikilink_attrs, tail \\ "") do
    %{
      "id" => "b-#{System.unique_integer([:positive])}",
      "type" => "paragraph",
      "content" =>
        [%{"type" => "text", "value" => lead}] ++
          [Map.merge(%{"type" => "wikilink", "children" => []}, wikilink_attrs)] ++
          if(tail == "", do: [], else: [%{"type" => "text", "value" => tail}])
    }
  end

  describe "match modes" do
    test "PRECISE — a wikilink whose docId === the target id is a backlink" do
      target = paper!("p-target", "Target Paper")

      paper!("p-src", "Source Paper", [
        para_with_wikilink("see ", %{"docId" => "p-target", "target" => "anything at all"},
          " for more")
      ])

      assert [%{slug: "p-src", title: "Source Paper", contexts: contexts}] =
               Content.backlinks_for(target, @dataset)

      assert [%{match: :precise, text: snippet}] = contexts
      assert snippet =~ "see"
      assert snippet =~ "for more"
    end

    test "FALLBACK — a no-id wikilink whose target string == the paper TITLE matches" do
      target = paper!("p-target", "Target Paper")

      paper!("p-src", "Source Paper", [
        para_with_wikilink("named ", %{"target" => "target paper"})
      ])

      assert [%{slug: "p-src", contexts: [%{match: :fallback}]}] =
               Content.backlinks_for(target, @dataset)
    end

    test "FALLBACK — a no-id wikilink whose target string == the paper SLUG matches" do
      target = paper!("p-target", "Totally Different Title")

      paper!("p-src", "Source Paper", [
        para_with_wikilink("by slug ", %{"target" => "p-target"})
      ])

      assert [%{slug: "p-src", contexts: [%{match: :fallback}]}] =
               Content.backlinks_for(target, @dataset)
    end

    test "does NOT match a wikilink that points at a DIFFERENT paper" do
      target = paper!("p-target", "Target Paper")
      _other = paper!("p-other", "Other Paper")

      # Precise pin to a DIFFERENT paper + a typed link naming a different paper.
      paper!("p-src", "Source Paper", [
        para_with_wikilink("a ", %{"docId" => "p-other", "target" => "Other Paper"}),
        para_with_wikilink("b ", %{"target" => "Some Unrelated Title"})
      ])

      assert Content.backlinks_for(target, @dataset) == []
    end

    test "a shared title WORD is not a fallback match (exact title only)" do
      target = paper!("p-target", "Design", [])

      paper!("p-src", "Source Paper", [
        para_with_wikilink("see ", %{"target" => "Design Patterns"})
      ])

      assert Content.backlinks_for(target, @dataset) == []
    end

    test "an id-pinned wikilink to a DIFFERENT paper does not fall back on its target string" do
      # Even though target string "Target Paper" would fallback-match, the link
      # is pinned to p-other → we honour the pin, no false positive.
      target = paper!("p-target", "Target Paper")
      _other = paper!("p-other", "Other Paper")

      paper!("p-src", "Source Paper", [
        para_with_wikilink("x ", %{"docId" => "p-other", "target" => "Target Paper"})
      ])

      assert Content.backlinks_for(target, @dataset) == []
    end
  end

  describe "self-exclusion + dedup + empties" do
    test "EXCLUDES the target itself (a self-link is not a backlink)" do
      target =
        paper!("p-target", "Target Paper", [
          para_with_wikilink("I link ", %{"docId" => "p-target"}),
          para_with_wikilink("myself ", %{"target" => "Target Paper"})
        ])

      assert Content.backlinks_for(target, @dataset) == []
    end

    test "DEDUPS a paper that links twice → ONE entry, TWO contexts" do
      target = paper!("p-target", "Target Paper")

      paper!("p-src", "Source Paper", [
        para_with_wikilink("first mention ", %{"docId" => "p-target"}),
        para_with_wikilink("second mention ", %{"target" => "Target Paper"})
      ])

      assert [%{slug: "p-src", contexts: contexts}] = Content.backlinks_for(target, @dataset)
      assert length(contexts) == 2
      texts = Enum.map(contexts, & &1.text)
      assert Enum.any?(texts, &(&1 =~ "first mention"))
      assert Enum.any?(texts, &(&1 =~ "second mention"))
    end

    test "empty when nothing links to the target" do
      target = paper!("p-target", "Target Paper")
      _unrelated = paper!("p-other", "Other Paper", [%{"type" => "paragraph", "content" => []}])

      assert Content.backlinks_for(target, @dataset) == []
    end

    test "contexts carry a sensible trimmed snippet of the linking block" do
      target = paper!("p-target", "Target Paper")

      paper!("p-src", "Source Paper", [
        para_with_wikilink("  As discussed in   ", %{"docId" => "p-target"},
          "  the prior work,   it follows.  ")
      ])

      assert [%{contexts: [%{text: text}]}] = Content.backlinks_for(target, @dataset)
      # whitespace collapsed + trimmed
      refute text =~ "  "
      assert text =~ "As discussed in"
      assert text =~ "it follows."
    end

    test "multiple distinct linkers → one entry each, title-ordered" do
      target = paper!("p-target", "Target Paper")

      paper!("p-zed", "Zed Paper", [para_with_wikilink("z ", %{"docId" => "p-target"})])
      paper!("p-abe", "Abe Paper", [para_with_wikilink("a ", %{"target" => "Target Paper"})])

      assert [%{title: "Abe Paper"}, %{title: "Zed Paper"}] =
               Content.backlinks_for(target, @dataset)
    end

    test "accepts a slug string for the target (resolves the paper)" do
      paper!("p-target", "Target Paper")
      paper!("p-src", "Source Paper", [para_with_wikilink("x ", %{"docId" => "p-target"})])

      assert [%{slug: "p-src"}] = Content.backlinks_for("p-target", @dataset)
      assert Content.backlinks_for("does-not-exist", @dataset) == []
    end
  end

  describe "nested wikilink discovery" do
    test "finds a wikilink nested inside a mark inside a list item" do
      target = paper!("p-target", "Target Paper")

      blocks = [
        %{
          "id" => "b-list",
          "type" => "list",
          "ordered" => false,
          "items" => [
            [
              %{
                "type" => "strong",
                "children" => [
                  %{"type" => "wikilink", "docId" => "p-target", "children" => []}
                ]
              }
            ]
          ]
        }
      ]

      paper!("p-src", "Source Paper", blocks)

      assert [%{slug: "p-src", contexts: [%{match: :precise}]}] =
               Content.backlinks_for(target, @dataset)
    end
  end
end
