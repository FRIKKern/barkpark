defmodule Barkpark.Content.PortableTextShapeTest do
  @moduledoc """
  Owner ruling #44 (task-db56e998e0a5ab3b): Portable Text blocks are
  canonical for plain rich text.

  Studio Classic stored HTML while `bp seed`, the make skeleton, codegen and
  the React renderer used Portable Text, so starter sites rendered
  Studio-written text as empty. Studio now converts at its boundary: blocks
  show as HTML in the editor and the posted HTML is saved as blocks. Stored
  HTML is still read, and converts on its next save. Tests load both shapes.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{Forms, PortableText}
  alias Barkpark.Content.ShapeMigrations.HtmlRichText

  @ds "pt-shape"
  @schema %{
    fields: [
      %{"name" => "title", "type" => "string"},
      %{"name" => "excerpt", "type" => "richText"}
    ]
  }

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "ptpost",
          "title" => "Post",
          "visibility" => "public",
          "fields" => @schema.fields
        },
        @ds
      )

    :ok
  end

  defp doc!(id, content) do
    {:ok, doc} =
      Content.create_document(
        "ptpost",
        %{"doc_id" => id, "title" => "T", "content" => content},
        @ds
      )

    doc
  end

  defp save!(doc, params) do
    {:ok, saved, _} = Forms.upsert_draft(doc, "ptpost", @schema, params, @ds)
    saved
  end

  describe "from_html/1" do
    test "paragraphs, decorators, links and line breaks" do
      [b0, b1] =
        PortableText.from_html(
          ~s(<p>Hello <strong>bold</strong> &amp; <a href="https://x.test/?a=1&amp;b=2">link</a></p><div>line<br>two</div>)
        )

      assert b0["style"] == "normal"
      assert [%{"href" => "https://x.test/?a=1&b=2", "_key" => link_key}] = b0["markDefs"]

      assert Enum.map(b0["children"], &{&1["text"], &1["marks"]}) == [
               {"Hello ", []},
               {"bold", ["strong"]},
               {" & ", []},
               {"link", [link_key]}
             ]

      assert [%{"text" => "line\ntwo"}] = b1["children"]
    end

    test "headings, quotes and lists" do
      blocks =
        PortableText.from_html(
          "<h2>Head</h2><blockquote>Q</blockquote><ul><li>a</li><li>b</li></ul><ol><li>c</li></ol>"
        )

      assert Enum.map(blocks, &{&1["style"], &1["listItem"]}) == [
               {"h2", nil},
               {"blockquote", nil},
               {"normal", "bullet"},
               {"normal", "bullet"},
               {"normal", "number"}
             ]
    end

    test "plain text and empty markup" do
      assert [%{"children" => [%{"text" => "just text"}]}] = PortableText.from_html("just text")
      assert PortableText.from_html("<p> </p><div><br></div>") == []
    end

    test "to_html/1 then from_html/1 gives the same blocks" do
      blocks =
        PortableText.from_html(
          ~s(<h3>T</h3><p>a <em>b</em> <a href="/x">c</a></p><ul><li>one</li><li>two</li></ul>)
        )

      assert blocks |> PortableText.to_html() |> PortableText.from_html() == blocks
    end
  end

  # task-949d59ae90b95cef: the editor has no UI for a decorator or markDef
  # outside its own set (a `highlight`, an `internalLink` annotation), so the
  # HTML it edits used to carry none of them, and an edit anywhere in the field
  # rebuilt every block without them and renumbered every `_key`.
  describe "marks the editor has no UI for" do
    @marked %{
      "_type" => "block",
      "_key" => "k7Qa",
      "style" => "normal",
      "markDefs" => [
        %{"_type" => "internalLink", "_key" => "ref1", "reference" => %{"_ref" => "doc-ibsen"}},
        %{"_type" => "link", "_key" => "lnk1", "href" => "/peer"}
      ],
      "children" => [
        %{"_type" => "span", "_key" => "s1", "text" => "Read ", "marks" => []},
        %{"_type" => "span", "_key" => "s2", "text" => "Ibsen", "marks" => ["highlight", "ref1"]},
        %{"_type" => "span", "_key" => "s3", "text" => " and ", "marks" => ["strong"]},
        %{"_type" => "span", "_key" => "s4", "text" => "Peer", "marks" => ["lnk1", "smallcaps"]}
      ]
    }
    @plain %{
      "_type" => "block",
      "_key" => "k9Zb",
      "style" => "normal",
      "markDefs" => [],
      "children" => [%{"_type" => "span", "_key" => "s5", "text" => "Second", "marks" => []}]
    }

    test "an untouched block keeps its unknown marks, markDefs and keys when another block is saved" do
      doc = doc!("pt-unknown-other", %{"excerpt" => [@marked, @plain]})
      html = Forms.doc_to_form(doc, @schema)["excerpt"]
      edited = String.replace(html, "Second", "Second, edited")

      saved = save!(doc, %{"title" => "T", "excerpt" => edited})

      assert [@marked, second] = saved.content["excerpt"]
      assert [%{"text" => "Second, edited"}] = second["children"]
    end

    test "an edit in the same block keeps its unknown decorators and markDefs" do
      doc = doc!("pt-unknown-same", %{"excerpt" => [@marked, @plain]})
      html = Forms.doc_to_form(doc, @schema)["excerpt"]
      edited = String.replace(html, "Read ", "Now read ")

      saved = save!(doc, %{"title" => "T", "excerpt" => edited})

      assert [block, @plain] = saved.content["excerpt"]

      assert [
               {"Now read ", []},
               {"Ibsen", ["highlight", "ref1"]},
               {" and ", ["strong"]},
               {"Peer", [link_key, "smallcaps"]}
             ] = Enum.map(block["children"], &{&1["text"], &1["marks"]})

      assert hd(@marked["markDefs"]) in block["markDefs"]

      assert %{"_type" => "link", "href" => "/peer"} =
               Enum.find(block["markDefs"], &(&1["_key"] == link_key))
    end

    test "from_html/2 rebuilds the stored blocks from their own HTML" do
      blocks = [@marked, @plain]
      assert blocks |> PortableText.to_html() |> PortableText.from_html(blocks) == blocks
    end
  end

  test "a Studio rich-text edit is saved as Portable Text blocks" do
    saved =
      save!(doc!("pt-new", %{}), %{"title" => "T", "excerpt" => "<p>Hello <em>you</em></p>"})

    assert [%{"_type" => "block", "children" => children}] = saved.content["excerpt"]
    assert Enum.map(children, & &1["text"]) == ["Hello ", "you"]
  end

  test "stored blocks are edited as HTML and kept byte for byte when untouched" do
    stored = [
      %{
        "_type" => "block",
        "_key" => "seedblock1",
        "style" => "normal",
        "markDefs" => [],
        "children" => [
          %{"_type" => "span", "_key" => "seedspan1", "text" => "Seeded", "marks" => []}
        ]
      }
    ]

    doc = doc!("pt-seeded", %{"excerpt" => stored})
    form = Forms.doc_to_form(doc, @schema)
    assert form["excerpt"] == "<p>Seeded</p>"

    assert save!(doc, Map.put(form, "title", "After")).content["excerpt"] == stored
  end

  test "stored HTML is read as is and converts to blocks on the next save" do
    doc = doc!("pt-html", %{"excerpt" => "<p>Old HTML</p>"})
    form = Forms.doc_to_form(doc, @schema)
    assert form["excerpt"] == "<p>Old HTML</p>"

    assert [%{"children" => [%{"text" => "Old HTML"}]}] =
             save!(doc, Map.put(form, "title", "After")).content["excerpt"]
  end

  test "the census counts HTML values; the dry run writes nothing" do
    doc!("pt-census-html", %{"excerpt" => "<p>x</p>"})
    doc!("pt-census-blocks", %{"excerpt" => PortableText.from_html("<p>y</p>")})

    assert %{type: "ptpost", field: "excerpt", documents: 1} in HtmlRichText.census()
    row = Enum.find(HtmlRichText.dry_run(), &(&1.doc_id == "drafts.pt-census-html"))
    assert [%{"_type" => "block"}] = row.to

    assert {:ok, %{content: %{"excerpt" => "<p>x</p>"}}} =
             Content.get_document("drafts.pt-census-html", "ptpost", @ds)
  end

  test "run(apply: true) converts HTML values and leaves blocks alone" do
    html = doc!("pt-apply-html", %{"excerpt" => "<p>Hello <strong>there</strong></p>"})
    blocks = doc!("pt-apply-blocks", %{"excerpt" => PortableText.from_html("<p>y</p>")})

    assert HtmlRichText.run(apply: true).applied?

    {:ok, after_html} = Content.get_document("drafts.pt-apply-html", "ptpost", @ds)

    assert after_html.content["excerpt"] ==
             PortableText.from_html("<p>Hello <strong>there</strong></p>")

    assert after_html.rev != html.rev

    {:ok, after_blocks} = Content.get_document("drafts.pt-apply-blocks", "ptpost", @ds)
    assert after_blocks.content == blocks.content
    assert after_blocks.rev == blocks.rev
    assert HtmlRichText.census() |> Enum.filter(&(&1.type == "ptpost")) == []
  end

  test "a plugin-owned type keeps its stored rich-text shape; the convert skips it" do
    fields = [
      %{"name" => "title", "type" => "string"},
      %{"name" => "excerpt", "type" => "richText"}
    ]

    schema = %{fields: fields}

    {:ok, _} =
      Content.upsert_schema(%{"name" => "ability", "title" => "Ability", "fields" => fields}, @ds)

    {:ok, html_doc} =
      Content.create_document(
        "ability",
        %{"doc_id" => "pt-frt-html", "title" => "T", "content" => %{"excerpt" => "<p>a</p>"}},
        @ds
      )

    {:ok, saved, _} =
      Forms.upsert_draft(
        html_doc,
        "ability",
        schema,
        %{"title" => "T", "excerpt" => "<p>b</p>"},
        @ds
      )

    assert saved.content["excerpt"] == "<p>b</p>"
    refute Enum.any?(HtmlRichText.dry_run(), &(&1.doc_id == "drafts.pt-frt-html"))

    stored_blocks = PortableText.from_html("<p>c</p>")

    {:ok, blocks_doc} =
      Content.create_document(
        "ability",
        %{
          "doc_id" => "pt-frt-blocks",
          "title" => "T",
          "content" => %{"excerpt" => stored_blocks}
        },
        @ds
      )

    {:ok, edited, _} =
      Forms.upsert_draft(
        blocks_doc,
        "ability",
        schema,
        %{"title" => "T", "excerpt" => "<p>d</p>"},
        @ds
      )

    assert edited.content["excerpt"] == PortableText.from_html("<p>d</p>")
  end
end
