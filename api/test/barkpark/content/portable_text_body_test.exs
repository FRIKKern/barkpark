defmodule Barkpark.Content.PortableTextBodyTest do
  @moduledoc """
  task-5fe67fc396077304: a `body` richText that holds Portable Text, as an
  imported Sanity body does, opens in the Classic rich-text editor and saves
  back as Portable Text.

  The gyldendal.no twin keeps its Sanity bodies as Portable Text (twin decision
  0007). Studio read a `body` list as a PortableDoc block list, so every block
  rendered as "invalid block", and a Classic save kept the stored list and
  dropped the edit. The fixture holds two real article bodies from the twin
  workspace: headings, bullet lists, italic text, internal and DAM links, and
  the custom blocks mediaModule, quote, inlineFeaturedProducts, featureModule
  and anchorPoint.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{Forms, PortableText}

  @ds "pt-body"
  @fixture "test/fixtures/portable_text/twin_article_bodies.json"
  @selvfolelse "8091b74f-d97c-44b3-8806-69b931b280ed"
  @genser "5e7a1c02-0000-4000-8000-000000000003"

  @schema %{
    fields: [
      %{"name" => "title", "type" => "string"},
      %{"name" => "body", "type" => "richText", "title" => "Innhold"}
    ]
  }

  setup_all do
    articles = @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("articles")
    %{bodies: Map.new(articles, fn {id, a} -> {id, a["body"]} end)}
  end

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "ptarticle",
          "title" => "Article",
          "visibility" => "public",
          "fields" => @schema.fields
        },
        @ds
      )

    :ok
  end

  defp doc!(id, body) do
    {:ok, doc} =
      Content.create_document(
        "ptarticle",
        %{"doc_id" => id, "title" => "T", "content" => %{"body" => body}},
        @ds
      )

    doc
  end

  defp save!(doc, params) do
    {:ok, saved, _} = Forms.upsert_draft(doc, "ptarticle", @schema, params, @ds)
    saved
  end

  defp text(block), do: Enum.map_join(block["children"] || [], &(&1["text"] || ""))

  describe "loading a twin article body" do
    test "every block shows as text or a labelled custom block, never as an invalid block",
         %{bodies: bodies} do
      for {id, body} <- bodies do
        html = Forms.doc_to_form(doc!("load-" <> id, body), @schema)["body"]

        assert is_binary(html)
        refute html =~ "invalid block"
        refute html =~ "Unsupported block"

        for %{"_type" => type, "_key" => key} <- body, type != "block" do
          assert html =~ ~s(data-pt-block="#{key}" data-pt-type="#{type}")
        end
      end
    end

    test "headings, lists, marks and links show as editor HTML", %{bodies: bodies} do
      html = Forms.doc_to_form(doc!("marks", bodies[@selvfolelse]), @schema)["body"]

      assert html =~ "<h2>Er det forskjell på selvtillit og selvfølelse?</h2>"
      assert html =~ "<ul><li>det som er inni barnet – følelser og behov</li>"
      assert html =~ "<em>"

      assert html =~
               ~s(<a href="#internal:onix.product-66d89e9b7e29df089e915b60" data-pt-def="3fd8bd9984a5" data-new-tab="true">)

      genser = Forms.doc_to_form(doc!("genser", bodies[@genser]), @schema)["body"]
      assert genser =~ "<h3>"
      assert genser =~ "<h4>"

      assert genser =~
               ~s(href="https://cdn.sanity.io/files/zl2pw2j0/production/eaa81e8c98f24ac4209c671ac33991dfd3ca6c38.pdf" data-pt-def="k29b7ffa8")
    end

    test "a custom block shows its type and a readable summary", %{bodies: bodies} do
      html = PortableText.to_html(bodies[@genser])

      assert html =~ ~s(<strong>anchorPoint</strong> Plaggets mål</div>)
      assert html =~ ~s(<strong>mediaModule</strong> Høstbladgenseren</div>)
      assert html =~ ~s(contenteditable="false")
    end
  end

  describe "saving a twin article body" do
    test "the editor HTML converts back to the stored body byte for byte", %{bodies: bodies} do
      for {_id, body} <- bodies do
        assert PortableText.from_html(PortableText.to_html(body), body) == body
      end
    end

    test "the HTML a browser posts back for an untouched body converts to the stored body",
         %{bodies: bodies} do
      assert PortableText.to_html(bodies[@selvfolelse]) =~ "\u00A0"

      for {_id, body} <- bodies do
        # innerHTML writes a no-break space as &nbsp; and a quote as is.
        posted =
          body
          |> PortableText.to_html()
          |> String.replace("\u00A0", "&nbsp;")

        assert PortableText.from_html(posted, body) == body
      end
    end

    test "an untouched body is kept as stored when another field is saved", %{bodies: bodies} do
      doc = doc!("untouched", bodies[@selvfolelse])
      form = Forms.doc_to_form(doc, @schema)

      assert save!(doc, Map.put(form, "title", "Ny tittel")).content["body"] ==
               bodies[@selvfolelse]
    end

    test "editing one span saves Portable Text in the same shape", %{bodies: bodies} do
      body = bodies[@selvfolelse]
      doc = doc!("edit-span", body)
      form = Forms.doc_to_form(doc, @schema)

      edited =
        String.replace(
          form["body"],
          "Hva er bevisst foreldreskap?",
          "Hva er et bevisst foreldreskap?"
        )

      assert edited != form["body"]
      saved = save!(doc, Map.put(form, "body", edited)).content["body"]

      assert length(saved) == length(body)
      assert Enum.map(saved, & &1["_key"]) == Enum.map(body, & &1["_key"])
      assert Enum.map(saved, & &1["_type"]) == Enum.map(body, & &1["_type"])

      {changed, same} =
        saved |> Enum.zip(body) |> Enum.split_with(fn {s, b} -> s != b end)

      assert [{heading, stored_heading}] = changed
      assert heading["_key"] == stored_heading["_key"]
      assert heading["style"] == "h2"
      assert heading["markDefs"] == []
      assert text(heading) == "Hva er et bevisst foreldreskap?"
      assert [%{"_type" => "span", "_key" => _, "marks" => []}] = heading["children"]
      assert length(same) == length(body) - 1
    end

    test "editing a block with internal links keeps its link annotations", %{bodies: bodies} do
      body = bodies[@selvfolelse]
      doc = doc!("edit-links", body)
      form = Forms.doc_to_form(doc, @schema)
      edited = String.replace(form["body"], "Utdrag fra boken", "Et utdrag fra boken")
      saved = save!(doc, Map.put(form, "body", edited)).content["body"]

      stored = Enum.find(body, &(&1["_key"] == "abc5cbd028ea"))
      block = Enum.find(saved, &(&1["_key"] == "abc5cbd028ea"))

      assert block["markDefs"] == stored["markDefs"]
      assert text(block) =~ "Et utdrag fra boken"

      linked = for %{"marks" => marks} <- block["children"], m <- marks, do: m
      assert "3fd8bd9984a5" in linked
      assert "05f7a0756b7d" in linked
      assert "em" in linked
    end

    test "a changed link address becomes an external link annotation", %{bodies: bodies} do
      body = bodies[@selvfolelse]
      doc = doc!("edit-href", body)
      form = Forms.doc_to_form(doc, @schema)

      edited =
        String.replace(
          form["body"],
          ~s(href="#internal:onix.contributor-33544"),
          ~s(href="https://www.gyldendal.no/forfattere/guro-oiestad")
        )

      saved = save!(doc, Map.put(form, "body", edited)).content["body"]
      block = Enum.find(saved, &(&1["_key"] == "abc5cbd028ea"))
      def = Enum.find(block["markDefs"], &(&1["_key"] == "05f7a0756b7d"))

      assert def == %{
               "_key" => "05f7a0756b7d",
               "_type" => "linkAnnotation",
               "linkType" => "external",
               "url" => "https://www.gyldendal.no/forfattere/guro-oiestad",
               "openInNewTab" => true
             }
    end

    test "a new link in a twin body is a linkAnnotation", %{bodies: bodies} do
      body = bodies[@selvfolelse]
      doc = doc!("new-link", body)
      form = Forms.doc_to_form(doc, @schema)

      edited =
        String.replace(
          form["body"],
          "<h2>Følelser og behov hos barnet</h2>",
          ~s(<h2>Følelser og <a href="https://example.test/behov">behov</a> hos barnet</h2>)
        )

      saved = save!(doc, Map.put(form, "body", edited)).content["body"]
      block = Enum.find(saved, &(&1["_key"] == "f915050d5c69"))

      assert [%{"_type" => "linkAnnotation", "_key" => k, "linkType" => "external"} = def] =
               block["markDefs"]

      assert def["url"] == "https://example.test/behov"
      assert Enum.any?(block["children"], &(&1["marks"] == [k] and &1["text"] == "behov"))
    end

    test "a paragraph turned into a heading keeps its key", %{bodies: bodies} do
      body = bodies[@selvfolelse]
      doc = doc!("restyle", body)
      form = Forms.doc_to_form(doc, @schema)
      stored = Enum.find(body, &(&1["_key"] == "e7412dc2d2a7"))
      para = "<p>" <> text(stored) <> "</p>"
      assert form["body"] =~ para

      edited = String.replace(form["body"], para, "<h3>" <> text(stored) <> "</h3>")
      saved = save!(doc, Map.put(form, "body", edited)).content["body"]

      assert %{"style" => "h3"} = Enum.find(saved, &(&1["_key"] == "e7412dc2d2a7"))
      assert length(saved) == length(body)
    end

    test "a removed custom block is gone and its neighbours stay", %{bodies: bodies} do
      body = bodies[@selvfolelse]
      doc = doc!("remove-block", body)
      form = Forms.doc_to_form(doc, @schema)

      [_, rest] = String.split(form["body"], ~s(<div data-pt-block="a11bc9226269"), parts: 2)
      [_, after_quote] = String.split(rest, "</div>", parts: 2)
      [before, _] = String.split(form["body"], ~s(<div data-pt-block="a11bc9226269"), parts: 2)

      saved = save!(doc, Map.put(form, "body", before <> after_quote)).content["body"]

      assert saved == Enum.reject(body, &(&1["_key"] == "a11bc9226269"))
    end

    test "a forged custom block key adds nothing", %{bodies: bodies} do
      body = bodies[@genser]

      forged =
        PortableText.to_html(body) <>
          ~s(<div data-pt-block="not-stored" contenteditable="false"><strong>x</strong></div>)

      assert PortableText.from_html(forged, body) == body
    end
  end

  describe "nested list items" do
    defp item(key, text, list_item, level) do
      %{
        "_type" => "block",
        "_key" => key,
        "style" => "normal",
        "listItem" => list_item,
        "level" => level,
        "markDefs" => [],
        "children" => [
          %{"_type" => "span", "_key" => key <> "s", "text" => text, "marks" => []}
        ]
      }
    end

    defp nested do
      [
        %{
          "_type" => "block",
          "_key" => "intro",
          "style" => "normal",
          "markDefs" => [],
          "children" => [
            %{"_type" => "span", "_key" => "introS", "text" => "Liste:", "marks" => []}
          ]
        },
        item("l1a", "Garn", "bullet", 1),
        item("l2a", "Alpakka", "bullet", 2),
        item("l3a", "Tweed", "number", 3),
        item("l2b", "Ull", "bullet", 2),
        item("l1b", "Pinner", "bullet", 1)
      ]
    end

    test "the editor HTML nests lists by level and reads them back" do
      html = PortableText.to_html(nested())

      assert html ==
               "<p>Liste:</p><ul><li>Garn<ul><li>Alpakka<ol><li>Tweed</li></ol></li>" <>
                 "<li>Ull</li></ul></li><li>Pinner</li></ul>"

      assert PortableText.from_html(html, nested()) == nested()
    end

    test "editing the text of a level-2 item keeps its level, listItem and key" do
      doc = doc!("nested-edit", nested())
      form = Forms.doc_to_form(doc, @schema)
      edited = String.replace(form["body"], "Alpakka", "Alpakka Tweed")
      assert edited != form["body"]

      saved = save!(doc, Map.put(form, "body", edited)).content["body"]

      assert Enum.map(saved, &{&1["_key"], &1["listItem"], &1["level"]}) ==
               Enum.map(nested(), &{&1["_key"], &1["listItem"], &1["level"]})

      block = Enum.find(saved, &(&1["_key"] == "l2a"))
      assert text(block) == "Alpakka Tweed"
      assert block["level"] == 2
      assert block["listItem"] == "bullet"

      assert Enum.reject(saved, &(&1["_key"] == "l2a")) ==
               Enum.reject(nested(), &(&1["_key"] == "l2a"))
    end

    test "editing a level-3 numbered item keeps level 3 and number" do
      html = String.replace(PortableText.to_html(nested()), "Tweed", "Tweed, brun")
      saved = PortableText.from_html(html, nested())

      assert %{"level" => 3, "listItem" => "number", "_key" => "l3a"} =
               Enum.find(saved, &(text(&1) == "Tweed, brun"))
    end
  end

  test "a PortableDoc body list is still read as PortableDoc blocks" do
    refute PortableText.value?([%{"id" => "b1", "type" => "paragraph", "text" => "x"}])
  end
end
