defmodule Barkpark.Content.PortableTextLinkFieldsTest do
  @moduledoc """
  task-025d7af119d6f0b8: the Classic rich-text editor's link row sets an
  email link, a link to an uploaded file, the query parameters of a document
  link and the new-tab switch of an address link. The editor carries the
  fields beside the address as attributes on the `<a>`, and a save stores them
  on the `linkAnnotation` the way a Sanity body holds them.

  Synthetic fixtures only.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.PortableText

  defp block(defs, children) do
    %{
      "_type" => "block",
      "_key" => "k1",
      "style" => "normal",
      "markDefs" => defs,
      "children" => children
    }
  end

  defp span(key, text, marks \\ []),
    do: %{"_type" => "span", "_key" => key, "text" => text, "marks" => marks}

  describe "a new link" do
    test "an email link in a value of linkAnnotations has linkType email" do
      stored = [
        block(
          [
            %{
              "_type" => "linkAnnotation",
              "_key" => "m0",
              "linkType" => "external",
              "url" => "https://a.test/"
            }
          ],
          [span("s0", "x", ["m0"])]
        )
      ]

      [b] =
        PortableText.from_html(
          ~s(<p>Write <a href="mailto:someone@example.test">us</a></p>),
          stored
        )

      assert [
               %{
                 "_type" => "linkAnnotation",
                 "linkType" => "email",
                 "email" => "someone@example.test"
               } = d
             ] =
               b["markDefs"]

      refute Map.has_key?(d, "url")
    end

    test "a file link is a linkAnnotation with linkType dam, damFileUrl and damFileName" do
      html =
        ~s(<p>Get <a href="https://files.example.test/a/brochure.pdf" data-link-kind="dam" data-file-name="brochure.pdf">the file</a></p>)

      [b] = PortableText.from_html(html)

      assert [d] = b["markDefs"]

      assert Map.delete(d, "_key") == %{
               "_type" => "linkAnnotation",
               "linkType" => "dam",
               "damFileUrl" => "https://files.example.test/a/brochure.pdf",
               "damFileName" => "brochure.pdf"
             }

      assert PortableText.to_html([b]) =~
               ~s(href="https://files.example.test/a/brochure.pdf" data-pt-def="#{d["_key"]}" data-link-kind="dam" data-file-name="brochure.pdf")
    end

    test "a file link in a value of plain links is still a linkAnnotation" do
      stored = [
        block([%{"_type" => "link", "_key" => "m0", "href" => "https://a.test/"}], [
          span("s0", "x", ["m0"])
        ])
      ]

      [b] =
        PortableText.from_html(
          ~s(<p><a href="https://a.test/">x</a> <a href="https://f.test/f.pdf" data-link-kind="dam">f</a></p>),
          stored
        )

      types = b["markDefs"] |> Enum.map(&{&1["_type"], &1["linkType"]}) |> Enum.sort()
      assert types == [{"link", nil}, {"linkAnnotation", "dam"}]
    end

    test "a document link carries linkParams" do
      [b] =
        PortableText.from_html(
          ~s(<p>See <a href="#internal:list-page-1" data-link-params="tags=a,b&amp;sort=name-asc">the list</a></p>)
        )

      assert [
               %{
                 "linkType" => "internal",
                 "internalLink" => %{"_ref" => "list-page-1"},
                 "linkParams" => "tags=a,b&sort=name-asc"
               }
             ] = b["markDefs"]

      assert PortableText.to_html([b]) =~ ~s(data-link-params="tags=a,b&amp;sort=name-asc")
    end

    test "an address link carries openInNewTab" do
      [b] =
        PortableText.from_html(
          ~s(<p><a href="https://a.test/" data-new-tab="true">a</a> <a href="#internal:doc-1">b</a></p>)
        )

      [ext, int] = b["markDefs"]
      assert %{"linkType" => "external", "url" => "https://a.test/", "openInNewTab" => true} = ext
      refute Map.has_key?(int, "openInNewTab")
      assert PortableText.to_html([b]) =~ ~s(data-new-tab="true")
    end

    test "two links to one address with different fields get two definitions" do
      [b] =
        PortableText.from_html(
          ~s(<p><a href="#internal:doc-1">a</a> <a href="#internal:doc-1" data-link-params="x=1">b</a></p>)
        )

      assert [d1, d2] = b["markDefs"]
      refute Map.has_key?(d1, "linkParams")
      assert d2["linkParams"] == "x=1"
    end

    test "linkParams on an address link is not stored" do
      [b] =
        PortableText.from_html(
          ~s(<p><a href="#internal:doc-1">a</a> <a href="https://a.test/" data-link-params="x=1">b</a></p>)
        )

      assert Enum.all?(
               b["markDefs"],
               &(not Map.has_key?(&1, "linkParams") or &1["linkType"] == "internal")
             )

      refute Enum.any?(
               b["markDefs"],
               &(&1["linkType"] == "external" and Map.has_key?(&1, "linkParams"))
             )
    end
  end

  describe "a stored link" do
    setup do
      defs = [
        %{
          "_type" => "linkAnnotation",
          "_key" => "d1",
          "linkType" => "internal",
          "internalLink" => %{"_type" => "reference", "_ref" => "doc-1"},
          "linkParams" => "page=2"
        },
        %{
          "_type" => "linkAnnotation",
          "_key" => "d2",
          "linkType" => "external",
          "url" => "https://a.test/",
          "openInNewTab" => false,
          "noopener" => true
        },
        %{
          "_type" => "linkAnnotation",
          "_key" => "d3",
          "linkType" => "dam",
          "damFileUrl" => "https://files.example.test/f.pdf",
          "damFileName" => "f.pdf"
        }
      ]

      stored = [
        block(defs, [
          span("s0", "one", ["d1"]),
          span("s1", " "),
          span("s2", "two", ["d2"]),
          span("s3", " "),
          span("s4", "three", ["d3"])
        ])
      ]

      %{stored: stored, html: PortableText.to_html(stored)}
    end

    test "renders every field and an untouched save keeps the value", %{
      stored: stored,
      html: html
    } do
      assert html =~ ~s(href="#internal:doc-1" data-pt-def="d1" data-link-params="page=2")
      assert html =~ ~s(href="https://a.test/" data-pt-def="d2" data-new-tab="false")

      assert html =~
               ~s(href="https://files.example.test/f.pdf" data-pt-def="d3" data-link-kind="dam" data-file-name="f.pdf")

      assert PortableText.from_html(html, stored) == stored
    end

    test "changed fields save on the definition and keep its other fields", %{
      stored: stored,
      html: html
    } do
      edited =
        html
        |> String.replace(~s(data-link-params="page=2"), ~s(data-link-params="page=3"))
        |> String.replace(~s(data-new-tab="false"), ~s(data-new-tab="true"))

      [b] = PortableText.from_html(edited, stored)
      defs = Map.new(b["markDefs"], &{&1["_key"], &1})

      assert defs["d1"]["linkParams"] == "page=3"
      assert defs["d1"]["internalLink"]["_ref"] == "doc-1"
      assert defs["d2"]["openInNewTab"] == true
      assert defs["d2"]["noopener"] == true
      assert defs["d3"] == Enum.at(hd(stored)["markDefs"], 2)
    end

    test "an empty data-link-params removes linkParams", %{stored: stored, html: html} do
      [b] =
        PortableText.from_html(
          String.replace(html, ~s(data-link-params="page=2"), ~s(data-link-params="")),
          stored
        )

      refute Map.has_key?(Enum.find(b["markDefs"], &(&1["_key"] == "d1")), "linkParams")
    end

    test "an address link turned into an email link stores linkType email", %{
      stored: stored,
      html: html
    } do
      [b] =
        PortableText.from_html(
          String.replace(html, ~s(href="https://a.test/"), ~s(href="mailto:a@example.test")),
          stored
        )

      d2 = Enum.find(b["markDefs"], &(&1["_key"] == "d2"))
      assert d2["linkType"] == "email"
      assert d2["email"] == "a@example.test"
      refute Map.has_key?(d2, "url")
    end

    test "a file link given another file stores the new url and name", %{
      stored: stored,
      html: html
    } do
      edited =
        html
        |> String.replace("https://files.example.test/f.pdf", "https://files.example.test/g.pdf")
        |> String.replace(~s(data-file-name="f.pdf"), ~s(data-file-name="g.pdf"))

      [b] = PortableText.from_html(edited, stored)

      assert Enum.find(b["markDefs"], &(&1["_key"] == "d3")) == %{
               "_type" => "linkAnnotation",
               "_key" => "d3",
               "linkType" => "dam",
               "damFileUrl" => "https://files.example.test/g.pdf",
               "damFileName" => "g.pdf"
             }
    end

    test "a file link turned into an address link drops the file fields", %{
      stored: stored,
      html: html
    } do
      edited = String.replace(html, ~s( data-link-kind="dam" data-file-name="f.pdf"), "")
      [b] = PortableText.from_html(edited, stored)
      d3 = Enum.find(b["markDefs"], &(&1["_key"] == "d3"))
      assert d3["linkType"] == "external"
      assert d3["url"] == "https://files.example.test/f.pdf"
      refute Map.has_key?(d3, "damFileUrl")
      refute Map.has_key?(d3, "damFileName")
    end
  end
end
