defmodule Barkpark.Content.PreviewTextTest do
  @moduledoc """
  `list_preview.subtitle` (task-f3203617ae4cf03e): a referenced title in the
  subtitle, a formatted date, a fallback when empty — the Agency previews — and
  the desk row that shows them.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.PreviewText
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "preview-text-#{System.unique_integer([:positive])}"

  defp nobody, do: fn _id -> nil end

  describe "format/3" do
    test "a path, a date and a fallback" do
      targets = %{"kari" => %{"name" => "Kari"}}
      root = %{"author" => %{"_ref" => "kari"}}
      assert PreviewText.format("author.name", root, &targets[&1]) == "Kari"

      date = %{"parts" => ["publishedAt|date"], "empty" => "Ingen dato"}
      assert PreviewText.format(date, %{"publishedAt" => "2026-10-08"}, nobody()) == "08.10.2026"

      assert PreviewText.format(date, %{"publishedAt" => "2026-10-08T23:30:00Z"}, nobody()) ==
               "08.10.2026"

      assert PreviewText.format(date, %{}, nobody()) == "Ingen dato"
      assert PreviewText.format(date, %{"publishedAt" => "not a date"}, nobody()) == "Ingen dato"
    end

    test "parts join, empty parts drop out" do
      spec = %{"parts" => ["kicker", "author.name"], "join" => " — "}
      deref = fn "a" -> %{"name" => "A"} end
      assert PreviewText.format(spec, %{"kicker" => "K", "author" => "a"}, deref) == "K — A"
      assert PreviewText.format(spec, %{"kicker" => " ", "author" => "a"}, deref) == "A"
      assert PreviewText.format(spec, %{}, nobody()) == nil
    end

    test "a nested path, a list index, alternatives and a template" do
      root = %{
        "isbn" => "9788205627765",
        "onix" => %{"productFormatTitle" => "Bok", "formats" => [%{"code" => "BB"}]},
        "slug" => %{"_type" => "slug", "current" => "om-oss"}
      }

      spec = %{"parts" => ["isbn", "onix.productFormatTitle"], "empty" => "Ingen ISBN"}
      assert PreviewText.format(spec, root, nobody()) == "9788205627765 · Bok"
      assert PreviewText.format(spec, %{}, nobody()) == "Ingen ISBN"
      assert PreviewText.format("onix.formats.0.code", root, nobody()) == "BB"
      assert PreviewText.format(["onix.missing", "isbn"], root, nobody()) == "9788205627765"
      assert PreviewText.format("/{slug}", root, nobody()) == "/om-oss"
      assert PreviewText.format("/{nope}", root, nobody()) == nil
    end

    test "each joins a field from every item of an array of references, capped, with a tail" do
      targets = %{
        "c1" => %{"title" => "Kari Nord"},
        "c2" => %{"title" => "Ola Sør"},
        "c3" => %{"title" => "Per Vest"},
        "r1" => %{"title" => "Forfatter"},
        "r2" => %{"title" => "Illustratør"}
      }

      deref = &targets[&1]

      item = fn c, r ->
        %{"contributor" => %{"_ref" => c, "_type" => "reference"}, "role" => %{"_ref" => r}}
      end

      spec = %{
        "each" => "onix.contributors",
        "show" => ["{contributor.title} ({role.title|lower})", "contributor.title"],
        "max" => 2,
        "join" => ", ",
        "more" => " med flere"
      }

      two = %{"onix" => %{"contributors" => [item.("c1", "r1"), item.("c2", "r2")]}}

      assert PreviewText.format(spec, two, deref) ==
               "Kari Nord (forfatter), Ola Sør (illustratør)"

      three = %{"onix" => %{"contributors" => two["onix"]["contributors"] ++ [item.("c3", "r9")]}}

      assert PreviewText.format(spec, three, deref) ==
               "Kari Nord (forfatter), Ola Sør (illustratør) med flere"

      # an item that IS a reference reads its target
      refs = %{"contributors" => [%{"_ref" => "c1"}, "c2", %{"_ref" => "gone"}]}
      assert PreviewText.format(%{"each" => "contributors"}, refs, deref) == "Kari Nord, Ola Sør"
      assert PreviewText.format(%{"each" => "contributors"}, %{}, deref) == nil
    end

    test "an event subtitle: conditional text, a parent title, a date and literal fallbacks" do
      spec = %{
        "parts" => [
          %{
            "when" => %{"field" => "eventStatus", "operator" => "eq", "value" => "EventCancelled"},
            "show" => %{"text" => "Avlyst"}
          },
          [
            %{
              "when" => %{"field" => "isSeriesParent", "operator" => "eq", "value" => true},
              "show" => %{"text" => "Hovedarrangement"}
            },
            "Del av: {parentEvent.title}"
          ],
          %{
            "parts" => [
              ["date|date", %{"text" => "Ingen dato"}],
              ["location", %{"text" => "Sted ikke angitt"}]
            ],
            "join" => " • "
          }
        ],
        "join" => " — "
      }

      deref = fn "parent" -> %{"title" => "Litteraturfestivalen"} end

      child = %{
        "date" => "2026-10-29T14:00:00Z",
        "location" => "Gyldendalhuset",
        "parentEvent" => %{"_ref" => "parent"}
      }

      assert PreviewText.format(spec, child, deref) ==
               "Del av: Litteraturfestivalen — 29.10.2026 • Gyldendalhuset"

      parent = %{"isSeriesParent" => true, "eventStatus" => "EventCancelled"}

      assert PreviewText.format(spec, parent, deref) ==
               "Avlyst — Hovedarrangement — Ingen dato • Sted ikke angitt"

      assert PreviewText.ref_ids(spec, child) == ["parent"]
    end

    test "a stored value shown by its label" do
      spec = %{
        "parts" => [
          "/{slug}",
          %{"path" => "pageType", "map" => %{"landingPage" => "Landingsside"}}
        ]
      }

      root = %{"slug" => %{"current" => "om-oss"}, "pageType" => "landingPage"}
      assert PreviewText.format(spec, root, nobody()) == "/om-oss · Landingsside"

      assert PreviewText.format(spec, %{root | "pageType" => "other"}, nobody()) ==
               "/om-oss · other"
    end

    test "a second reference on one path is not followed" do
      targets = %{"a" => %{"parent" => %{"_ref" => "b"}}, "b" => %{"title" => "B"}}
      assert PreviewText.format("parent.parent.title", %{"parent" => "a"}, &targets[&1]) == nil
    end

    test "|count shows the number of items in a list" do
      root = %{"questions" => [%{"q" => "a"}, %{"q" => "b"}, %{"q" => "c"}], "rules" => []}

      assert PreviewText.format("questions|count", root, nobody()) == "3"
      assert PreviewText.format("{questions|count} questions", root, nobody()) == "3 questions"
      assert PreviewText.format("{rules|count} rules", root, nobody()) == "0 rules"
      assert PreviewText.format("{missing|count} rules", root, nobody()) == "0 rules"
      assert PreviewText.format("{questions.0.q|count} rules", root, nobody()) == nil

      spec = %{"parts" => ["title", "{questions|count} questions"], "join" => " · "}

      assert PreviewText.format(spec, Map.put(root, "title", "Help"), nobody()) ==
               "Help · 3 questions"

      # Counting a list of references loads none of them.
      assert PreviewText.ref_ids("items|count", %{"items" => ["a", %{"_ref" => "b"}]}) == []
    end

    test "ref_ids names the ids a page of rows must load" do
      spec = %{"parts" => ["parent.title", "date|date", "parent.slug"]}
      assert PreviewText.ref_ids(spec, %{"parent" => %{"_ref" => "drafts.top"}}) == ["top"]
      assert PreviewText.ref_ids("title", %{"title" => "x"}) == []
      assert PreviewText.ref_ids(nil, %{}) == []

      each = %{"each" => "onix.contributors", "show" => "{contributor.title} ({role.title})"}

      root = %{
        "onix" => %{"contributors" => [%{"contributor" => "c1", "role" => %{"_ref" => "r1"}}]}
      }

      assert Enum.sort(PreviewText.ref_ids([each, nil], root)) == ["c1", "r1"]

      assert PreviewText.ref_ids(%{"each" => "refs"}, %{"refs" => ["x", %{"_ref" => "y"}]}) == [
               "x",
               "y"
             ]
    end
  end

  describe "media/3" do
    test "the first path that holds an image URL" do
      root = %{"onix" => %{"thumbnail" => "null", "coverImage" => "https://cdn.example/c.jpg"}}

      assert PreviewText.media(["onix.thumbnail", "onix.coverImage"], root, nobody()) ==
               "https://cdn.example/c.jpg"

      assert PreviewText.media("cover", %{"cover" => %{"url" => "/media/x.jpg"}}, nobody()) ==
               "/media/x.jpg"

      assert PreviewText.media("cover", %{"cover" => %{"assetId" => "a1"}}, nobody()) == nil
      assert PreviewText.media(nil, root, nobody()) == nil
    end
  end

  test "a desk row's subtitle follows the declaration, through one reference" do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "category",
          "title" => "Category",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "parent",
              "title" => "Parent",
              "type" => "reference",
              "to" => ["category"]
            }
          ],
          "list_preview" => %{"subtitle" => %{"parts" => ["parent.title"], "empty" => "Toppnivå"}}
        },
        @dataset
      )

    {:ok, schema} = Content.get_schema("category", @dataset)
    assert Content.serialize_schema_for_sdk(schema).listPreview["subtitle"]["empty"] == "Toppnivå"

    for {id, title, content} <- [
          {"top", "Fiction", %{}},
          {"child", "Crime", %{"parent" => %{"_ref" => "top", "_type" => "reference"}}}
        ] do
      {:ok, _} =
        Content.create_document(
          "category",
          %{"doc_id" => id, "title" => title, "content" => content},
          @dataset
        )

      {:ok, _} = Content.publish_document(id, "category", @dataset)
    end

    {panes, _editor} = PaneBuilder.build(@dataset, ["category"])

    rows =
      for %{type: :doc} = item <- List.last(panes).items, into: %{}, do: {item.title, item.meta}

    assert rows["Crime"] == "Fiction"
    assert rows["Fiction"] == "Toppnivå"
  end

  test "a desk row's subtitle counts the items of a list" do
    dataset = "#{@dataset}-count"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "faq_set",
          "title" => "FAQ set",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "questions",
              "title" => "Questions",
              "type" => "array",
              "of" => [%{"type" => "string"}]
            }
          ],
          "list_preview" => %{"subtitle" => "{questions|count} questions"}
        },
        dataset
      )

    for {id, title, content} <- [
          {"faq-a", "Shipping", %{"questions" => ["one", "two"]}},
          {"faq-b", "Returns", %{}}
        ] do
      {:ok, _} =
        Content.create_document(
          "faq_set",
          %{"doc_id" => id, "title" => title, "content" => content},
          dataset
        )
    end

    {panes, _editor} = PaneBuilder.build(dataset, ["faq_set"])

    rows =
      for %{type: :doc} = item <- List.last(panes).items, into: %{}, do: {item.title, item.meta}

    assert rows["Shipping"] == "2 questions"
    assert rows["Returns"] == "0 questions"
  end

  test "a product row shows the ONIX cover, ISBN · format and the first two contributors" do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "contributor",
          "title" => "Bidragsyter",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Navn", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "role",
          "title" => "Rolle",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Tittel", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "product",
          "title" => "Produkt",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{"name" => "isbn", "title" => "ISBN", "type" => "string"},
            %{"name" => "onix", "title" => "ONIX", "type" => "json"}
          ],
          "list_preview" => %{
            "subtitle" => %{
              "parts" => ["isbn", "onix.productFormatTitle"],
              "empty" => "Ingen ISBN"
            },
            "description" => %{
              "each" => "onix.contributors",
              "show" => ["{contributor.title} ({role.title|lower})", "contributor.title"],
              "max" => 2,
              "more" => " med flere"
            },
            "media" => ["onix.thumbnail", "onix.coverImage"]
          }
        },
        @dataset
      )

    for {type, id, title} <- [
          {"contributor", "c1", "Kari Nord"},
          {"contributor", "c2", "Ola Sør"},
          {"contributor", "c3", "Per Vest"},
          {"role", "r1", "Forfatter"},
          {"role", "r2", "Illustratør"}
        ] do
      {:ok, _} =
        Content.create_document(
          type,
          %{"doc_id" => id, "title" => title, "content" => %{}},
          @dataset
        )

      {:ok, _} = Content.publish_document(id, type, @dataset)
    end

    contributor = fn c, r ->
      %{
        "contributor" => %{"_ref" => c, "_type" => "reference"},
        "role" => %{"_ref" => r, "_type" => "reference"}
      }
    end

    for {id, onix, isbn} <- [
          {"p-book",
           %{
             "productFormatTitle" => "Bok",
             "thumbnail" => "https://media.example/book_thumb.jpg",
             "contributors" => [
               contributor.("c1", "r1"),
               contributor.("c2", "r2"),
               contributor.("c3", "r1")
             ]
           }, "9788205627765"},
          {"p-ebook",
           %{
             "productFormatTitle" => "E-bok",
             "thumbnail" => "null",
             "coverImage" => "https://media.example/ebook.jpg",
             "contributors" => [contributor.("c1", "r1")]
           }, "9788205627772"},
          {"p-bare", %{}, nil}
        ] do
      {:ok, _} =
        Content.create_document(
          "product",
          %{
            "doc_id" => id,
            "title" => "Eventyrnettene",
            "content" => %{"isbn" => isbn, "onix" => onix}
          },
          @dataset
        )

      {:ok, _} = Content.publish_document(id, "product", @dataset)
    end

    {panes, _editor} = PaneBuilder.build(@dataset, ["product"])
    rows = for %{type: :doc} = item <- List.last(panes).items, into: %{}, do: {item.id, item}

    assert rows["p-book"].meta == "9788205627765 · Bok"
    assert rows["p-book"].description == "Kari Nord (forfatter), Ola Sør (illustratør) med flere"
    assert rows["p-book"].media == "https://media.example/book_thumb.jpg"

    assert rows["p-ebook"].meta == "9788205627772 · E-bok"
    assert rows["p-ebook"].description == "Kari Nord (forfatter)"
    assert rows["p-ebook"].media == "https://media.example/ebook.jpg"

    assert rows["p-bare"].meta == "Ingen ISBN"
    assert rows["p-bare"].description == nil
    assert rows["p-bare"].media == nil
    assert rows["p-bare"].media_slot
  end
end
