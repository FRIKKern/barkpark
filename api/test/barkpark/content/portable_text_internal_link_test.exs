defmodule Barkpark.Content.PortableTextInternalLinkTest do
  @moduledoc """
  task-088575052b459f3e: the Classic rich-text editor's link row chooses a
  document for an internal link, and the editor links the text to
  `#internal:<id>`. A save stores that as the twin's Sanity bodies store a
  document link and its site renders one: a `linkAnnotation` with `linkType`
  internal and an `internalLink` reference. Before, `#internal:<id>` was saved
  as an external link whose url is the literal text `#internal:<id>`.

  The fixture holds two real article bodies from the twin workspace.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{Forms, PortableText}

  @ds "pt-internal-link"
  @fixture "test/fixtures/portable_text/twin_article_bodies.json"
  @selvfolelse "8091b74f-d97c-44b3-8806-69b931b280ed"

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
          "name" => "ptlinkarticle",
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
        "ptlinkarticle",
        %{"doc_id" => id, "title" => "T", "content" => %{"body" => body}},
        @ds
      )

    doc
  end

  defp save!(doc, form) do
    {:ok, saved, _} = Content.upsert_draft(doc, "ptlinkarticle", @schema, form, @ds)
    saved
  end

  defp internal(id), do: %{"_type" => "reference", "_ref" => id}

  test "text linked to a document in a twin body saves as an internal linkAnnotation",
       %{bodies: bodies} do
    doc = doc!("new-internal", bodies[@selvfolelse])
    form = Forms.doc_to_form(doc, @schema)

    edited =
      String.replace(
        form["body"],
        "<h2>Følelser og behov hos barnet</h2>",
        ~s(<h2>Følelser og <a href="#internal:onix.product-66d89e9b7e29df089e915b60">behov</a> hos barnet</h2>)
      )

    saved = save!(doc, Map.put(form, "body", edited)).content["body"]
    block = Enum.find(saved, &(&1["_key"] == "f915050d5c69"))

    assert [%{"_key" => k} = def] = block["markDefs"]

    assert def == %{
             "_key" => k,
             "_type" => "linkAnnotation",
             "linkType" => "internal",
             "internalLink" => internal("onix.product-66d89e9b7e29df089e915b60")
           }

    assert Enum.any?(block["children"], &(&1["marks"] == [k] and &1["text"] == "behov"))

    # The editor shows it again as the same document link.
    assert PortableText.to_html([block]) =~
             ~s(href="#internal:onix.product-66d89e9b7e29df089e915b60")
  end

  test "a document link in a body with no links yet is a linkAnnotation too" do
    [block] =
      PortableText.from_html(~s(<p>Se <a href="#internal:article-1">artikkelen</a>.</p>))

    assert [
             %{
               "_type" => "linkAnnotation",
               "linkType" => "internal",
               "internalLink" => %{"_type" => "reference", "_ref" => "article-1"}
             }
           ] = block["markDefs"]
  end

  test "choosing another document for an internal link keeps the link's other fields",
       %{bodies: bodies} do
    body = bodies[@selvfolelse]
    doc = doc!("retarget", body)
    form = Forms.doc_to_form(doc, @schema)

    edited =
      String.replace(
        form["body"],
        ~s(href="#internal:onix.contributor-33544"),
        ~s(href="#internal:onix.contributor-40261")
      )

    saved = save!(doc, Map.put(form, "body", edited)).content["body"]
    block = Enum.find(saved, &(&1["_key"] == "abc5cbd028ea"))
    def = Enum.find(block["markDefs"], &(&1["_key"] == "05f7a0756b7d"))

    assert def == %{
             "_key" => "05f7a0756b7d",
             "_type" => "linkAnnotation",
             "linkType" => "internal",
             "internalLink" => internal("onix.contributor-40261"),
             "openInNewTab" => true
           }

    # The other internal link in the block is untouched.
    stored = Enum.find(body, &(&1["_key"] == "abc5cbd028ea"))

    assert Enum.find(block["markDefs"], &(&1["_key"] == "3fd8bd9984a5")) ==
             Enum.find(stored["markDefs"], &(&1["_key"] == "3fd8bd9984a5"))
  end

  test "an external link turned internal drops its url, and linkParams go with a changed target" do
    stored = [
      %{
        "_type" => "block",
        "_key" => "b1",
        "style" => "normal",
        "markDefs" => [
          %{
            "_type" => "linkAnnotation",
            "_key" => "ext",
            "linkType" => "external",
            "url" => "https://example.test/",
            "openInNewTab" => true
          },
          %{
            "_type" => "linkAnnotation",
            "_key" => "int",
            "linkType" => "internal",
            "internalLink" => internal("page-1"),
            "linkParams" => "format=Lydbok"
          }
        ],
        "children" => [
          %{"_type" => "span", "_key" => "s0", "text" => "Ut", "marks" => ["ext"]},
          %{"_type" => "span", "_key" => "s1", "text" => " og ", "marks" => []},
          %{"_type" => "span", "_key" => "s2", "text" => "inn", "marks" => ["int"]}
        ]
      }
    ]

    html =
      stored
      |> PortableText.to_html()
      |> String.replace(~s(href="https://example.test/"), ~s(href="#internal:product-9"))
      |> String.replace(~s(href="#internal:page-1"), ~s(href="#internal:page-2"))

    [block] = PortableText.from_html(html, stored)
    defs = Map.new(block["markDefs"], &{&1["_key"], &1})

    assert defs["ext"] == %{
             "_type" => "linkAnnotation",
             "_key" => "ext",
             "linkType" => "internal",
             "internalLink" => internal("product-9"),
             "openInNewTab" => true
           }

    assert defs["int"] == %{
             "_type" => "linkAnnotation",
             "_key" => "int",
             "linkType" => "internal",
             "internalLink" => internal("page-2")
           }
  end

  test "a plain link given a document becomes a linkAnnotation" do
    stored = [
      %{
        "_type" => "block",
        "_key" => "b1",
        "style" => "normal",
        "markDefs" => [%{"_type" => "link", "_key" => "l1", "href" => "https://example.test/"}],
        "children" => [%{"_type" => "span", "_key" => "s0", "text" => "Les", "marks" => ["l1"]}]
      }
    ]

    html = ~s(<p><a href="#internal:article-7">Les</a></p>)
    [block] = PortableText.from_html(html, stored)

    assert [
             %{
               "_type" => "linkAnnotation",
               "linkType" => "internal",
               "internalLink" => %{"_ref" => "article-7"}
             }
           ] = block["markDefs"]
  end
end
