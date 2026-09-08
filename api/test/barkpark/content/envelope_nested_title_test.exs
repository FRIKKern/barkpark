defmodule Barkpark.Content.EnvelopeNestedTitleTest do
  @moduledoc """
  [title-collision] gh-13711 — the READ-path member of the envelope-key vs
  user-field-name collision class (siblings gh-6291 `content` and gh-6292
  `status`, both closed on the WRITE path in PR #13706).

  `Envelope.render/3` is the single field-visibility chokepoint, and `title` is
  the ONE key it emits from a COLUMN rather than from the document's content.
  An unconditional `Map.put("title", doc.title)` therefore shadowed a caller's
  own `content["title"]` on every read surface at once — the value was stored
  intact and unreadable by any means.

  These tests pin the DECISION, not just the fix: the column wins whenever it
  holds a value, and the content field is emitted only when the column would
  otherwise emit nothing. Both halves matter — the second half is what stops
  `Map.put_new` (the obvious one-word "fix") from regressing every blocks-bearing
  document whose bound title block projects `content["title"] => nil`.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{Envelope, Writer}

  defp create!(doc_id, attrs) do
    {:ok, doc} =
      Content.create_document("post", Map.put(attrs, "doc_id", doc_id), "test")

    doc
  end

  describe "the defect: a nested content.title with no column title" do
    test "reads back its stored value instead of the NULL column" do
      doc =
        create!("nt-1", %{
          "content" => %{"title" => "My own inner title", "body" => "b", "slug" => "s"}
        })

      # Precondition: the write path really stored it, and really left the
      # column empty. Without this the assertion below could pass vacuously on a
      # write that lifted the field into the column.
      assert doc.content["title"] == "My own inner title"
      assert doc.title in [nil, ""]

      env = Envelope.render(doc)

      # THIS is the assertion that reds on the tree before the fix (it saw nil).
      assert env["title"] == "My own inner title"
      assert env["body"] == "b"
      assert env["slug"] == "s"
    end

    test "the shape is reachable through the envelope coercion the API uses" do
      # Reachability control: `Writer.from_envelope/1` takes the CONTENT-PRESENT
      # branch for this payload and passes `content` through untouched, so
      # nothing lifts `title` out of it. The mixed-shape refusal's own message
      # tells callers to "Move them INSIDE `content`" — this is that payload.
      coerced = Writer.from_envelope(%{"_id" => "nt-2", "content" => %{"title" => "Inner"}})

      assert coerced["content"]["title"] == "Inner"
      refute is_binary(coerced["title"])
    end

    test "a blank column is treated as no column value" do
      doc = create!("nt-3", %{"title" => "   ", "content" => %{"title" => "Inner"}})

      assert Envelope.render(doc)["title"] == "Inner"
    end
  end

  describe "the decision: the column wins whenever it holds a value" do
    test "a set column shadows a colliding content.title" do
      doc = create!("nt-4", %{"title" => "Column title", "content" => %{"title" => "Inner"}})

      assert doc.content["title"] == "Inner"
      assert Envelope.render(doc)["title"] == "Column title"
    end

    test "content.title => nil never blanks a real column title" do
      # The `Map.put_new` regression, pinned. `Projection.project_bound_fields/3`
      # is the sole writer of `content[fieldName]` and does a verbatim
      # `Map.put(acc, fieldName, projected_value(block))`; a bound title block
      # with no "value" projects nil, leaving the key PRESENT and nil. `put_new`
      # keys on presence and would emit `title: nil` here.
      doc = create!("nt-5", %{"title" => "Real title", "content" => %{"title" => nil}})

      assert Map.has_key?(doc.content, "title")
      assert Envelope.render(doc)["title"] == "Real title"
    end

    test "a non-binary content.title is never emitted — title stays a string or nil" do
      # `projected_value/1` can be "a structured map/list for
      # composite/arrayOf/localizedText". Consumers (internal/apiclient's
      # scalarString, @barkpark/core's non-nullable `title`) assume a string.
      doc = create!("nt-6", %{"content" => %{"title" => %{"nb" => "Bokmal"}}})

      assert doc.content["title"] == %{"nb" => "Bokmal"}
      assert Envelope.render(doc)["title"] == nil
    end

    test "no content.title at all is byte-identical to the old behaviour" do
      doc = create!("nt-7", %{"title" => "Hello", "content" => %{"body" => "hi"}})

      env = Envelope.render(doc)
      assert env["title"] == "Hello"
      assert env["body"] == "hi"
    end

    test "the FLAT envelope round-trip is unchanged" do
      # writer.ex's own audit note: on the flat branch `title` is lifted to the
      # column and re-emitted by render/3, "so it ROUND-TRIPS. Not loss; do not
      # 'fix' it." The flat branch drops `title` from the fold, so content never
      # carries the key and this path cannot reach the new clause.
      coerced = Writer.from_envelope(%{"_id" => "nt-8", "title" => "Flat", "slug" => "s"})
      refute Map.has_key?(coerced["content"], "title")

      doc = create!("nt-8", %{"title" => "Flat", "content" => coerced["content"]})
      assert Envelope.render(doc)["title"] == "Flat"
    end
  end

  describe "class audit: the seven `_`-prefixed reserved keys" do
    @reserved ~w(_id _type _rev _draft _publishedId _createdAt _updatedAt)

    test "each is storable inside a nested content map and each is still shadowed on read" do
      # This is the CLASS check the row asks for, and its answer is deliberately
      # the OPPOSITE of `title`'s: these seven are declared reserved in the
      # moduledoc, they carry the document's identity/version/lifecycle, and
      # letting content win would let any caller forge `_id` / `_rev` / `_type`
      # in every read surface. The shadowing is the contract, not the defect.
      # `title` differs because it is declared nowhere, has no write-side
      # refusal, and is pure caller data.
      for key <- @reserved do
        doc = create!("nt-res-#{String.downcase(key)}", %{"content" => %{key => "HIJACK"}})

        assert doc.content[key] == "HIJACK", "#{key} was not stored — premise dead"
        refute Envelope.render(doc)[key] == "HIJACK", "#{key} leaked a caller value"
      end
    end

    test "`status` is not emitted by render at all, so it has no read-path shadow" do
      doc = create!("nt-status", %{"content" => %{"status" => "in_stock"}})

      # The gh-6292 sibling is a WRITE-path collision: render/3 never emits a
      # `status` key from the column, so a content field named `status` reads
      # back untouched. Nothing to fix here.
      assert Envelope.render(doc)["status"] == "in_stock"
    end
  end
end
