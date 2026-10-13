defmodule BarkparkWeb.Components.DraftDiffTest do
  @moduledoc """
  Coverage for `BarkparkWeb.Components.DraftDiff` (Task `barkpark-uix`).

  Pins the four field-level statuses (`:unchanged`, `:added`, `:removed`,
  `:changed`) and the no-published fallback. The component is read-only
  output (no events, no streams) so we render once and assert against
  the resulting HTML — the data-test-id hooks on each row + status cell
  make assertions stable against CSS / markup churn.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Components.DraftDiff

  defp schema(field_names) do
    %{
      "name" => "test",
      "fields" => Enum.map(field_names, fn n -> %{"name" => n, "type" => "string"} end)
    }
  end

  defp doc(content), do: %{content: content}

  describe "draft_diff/1 — status computation" do
    test "all fields equal → 0 changes, every row :unchanged" do
      html =
        render_component(&DraftDiff.draft_diff/1, %{
          draft: doc(%{"title" => "Hello", "body" => "x"}),
          published: doc(%{"title" => "Hello", "body" => "x"}),
          schema: schema(["title", "body"])
        })

      assert html =~ ~s(data-test-id="draft-diff")
      assert html =~ ~s(0 changes)
      assert html =~ ~s(bp-diff-unchanged)
      refute html =~ ~s(bp-diff-changed)
      refute html =~ ~s(bp-diff-added)
      refute html =~ ~s(bp-diff-removed)
    end

    test "field present in draft, absent in published → :added" do
      html =
        render_component(&DraftDiff.draft_diff/1, %{
          draft: doc(%{"title" => "Hello", "body" => "new para"}),
          published: doc(%{"title" => "Hello"}),
          schema: schema(["title", "body"])
        })

      assert html =~ ~s(1 change)
      assert html =~ ~s(bp-diff-added)

      assert html =~
               ~s(data-test-id="draft-diff-status-body")
    end

    test "field present in published, absent in draft → :removed" do
      html =
        render_component(&DraftDiff.draft_diff/1, %{
          draft: doc(%{"title" => "Hello"}),
          published: doc(%{"title" => "Hello", "body" => "old para"}),
          schema: schema(["title", "body"])
        })

      assert html =~ ~s(1 change)
      assert html =~ ~s(bp-diff-removed)
    end

    test "field present on both sides with different values → :changed" do
      html =
        render_component(&DraftDiff.draft_diff/1, %{
          draft: doc(%{"title" => "Updated"}),
          published: doc(%{"title" => "Original"}),
          schema: schema(["title"])
        })

      assert html =~ ~s(1 change)
      assert html =~ ~s(bp-diff-changed)
      assert html =~ "Updated"
      assert html =~ "Original"
    end

    test "no published doc → every row collapses to :added, table still renders" do
      html =
        render_component(&DraftDiff.draft_diff/1, %{
          draft: doc(%{"title" => "Brand new", "body" => "first draft"}),
          published: nil,
          schema: schema(["title", "body"])
        })

      assert html =~ ~s(data-test-id="draft-diff")
      assert html =~ ~s(2 changes)
      assert html =~ ~s(bp-diff-added)
    end

    test "composite (map) values render as JSON in the column" do
      html =
        render_component(&DraftDiff.draft_diff/1, %{
          draft: doc(%{"meta" => %{"author" => "Alice", "tags" => ["a", "b"]}}),
          published: doc(%{"meta" => %{"author" => "Bob"}}),
          schema: schema(["meta"])
        })

      assert html =~ "Alice"
      assert html =~ "Bob"
      assert html =~ ~s(bp-diff-changed)
    end

    test "atom-keyed schema + struct-style doc (content map) work" do
      html =
        render_component(&DraftDiff.draft_diff/1, %{
          draft: %{content: %{"title" => "A"}},
          published: %{content: %{"title" => "B"}},
          schema: %{fields: [%{name: "title", type: "string"}]}
        })

      assert html =~ ~s(bp-diff-changed)
      assert html =~ "A"
      assert html =~ "B"
    end
  end

  describe "draft_diff/1 — pluralisation" do
    test "uses 'change' (singular) for exactly one diff" do
      html =
        render_component(&DraftDiff.draft_diff/1, %{
          draft: doc(%{"title" => "x"}),
          published: doc(%{"title" => "y"}),
          schema: schema(["title"])
        })

      assert html =~ "1 change"
      refute html =~ "1 changes"
    end

    test "uses 'changes' (plural) for zero or many diffs" do
      html =
        render_component(&DraftDiff.draft_diff/1, %{
          draft: doc(%{"a" => "1", "b" => "1"}),
          published: doc(%{"a" => "2", "b" => "2"}),
          schema: schema(["a", "b"])
        })

      assert html =~ "2 changes"
    end
  end

  # task-30d564b8b1219ab9: the Diff showed storage, not what the editor wrote.
  describe "draft_diff/1 — values read as words" do
    defp typed_schema do
      %{
        "fields" => [
          %{"name" => "title", "title" => "Tittel", "type" => "string"},
          %{
            "name" => "author",
            "title" => "Forfatter",
            "type" => "reference",
            "to" => [%{"type" => "author"}]
          },
          %{"name" => "cover", "title" => "Omslag", "type" => "image"},
          %{"name" => "body", "title" => "Tekst", "type" => "richText"}
        ]
      }
    end

    defp typed_doc(author, alt, text) do
      doc(%{
        "title" => "Fjellet",
        "author" => %{"_ref" => author},
        "cover" => %{
          "alt" => alt,
          "width" => 1200,
          "height" => 630,
          "assetId" => "a1e0",
          "lqip" => "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD"
        },
        "body" => [
          %{"_type" => "block", "children" => [%{"_type" => "span", "text" => text}]}
        ]
      })
    end

    test "labels, a resolved reference, an image without its data URI, rich text, word statuses" do
      titles = %{
        {"author-ness", "author"} => "Ingrid Ness",
        {"author-graff", "author"} => "Sverre Graff"
      }

      html =
        render_component(&DraftDiff.draft_diff/1, %{
          draft: typed_doc("author-graff", "Et snødekt fjell", "Ny tekst."),
          published: typed_doc("author-ness", "", "Gammel tekst."),
          schema: typed_schema(),
          ref_title: fn id, type -> Map.get(titles, {id, type}, id) end
        })

      assert html =~ "Tittel"
      assert html =~ "Forfatter"
      assert html =~ "Ingrid Ness"
      assert html =~ "Sverre Graff"
      refute html =~ "_ref"
      assert html =~ "Image 1200×630 · alt: Et snødekt fjell"
      assert html =~ "Image 1200×630 · no alt text"
      refute html =~ "data:image"
      refute html =~ "base64"
      assert html =~ "Ny tekst."
      assert html =~ "Gammel tekst."
      refute html =~ "children"
      assert html =~ "Unchanged"
      assert html =~ "Changed"
      refute html =~ "Δ"
    end

    test "without a resolver a reference shows its id, and a stray data URI in any composite is dropped" do
      html =
        render_component(&DraftDiff.draft_diff/1, %{
          draft:
            doc(%{
              "author" => %{"_ref" => "author-ness"},
              "meta" => %{"thumb" => "data:image/png;base64,AAA", "k" => "v"}
            }),
          published: nil,
          schema: %{
            "fields" => [
              %{"name" => "author", "type" => "reference"},
              %{"name" => "meta", "type" => "object"}
            ]
          }
        })

      assert html =~ "author-ness"
      assert html =~ ~s({&quot;k&quot;:&quot;v&quot;})
      refute html =~ "data:image"
    end
  end
end
