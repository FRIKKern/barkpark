defmodule BarkparkWeb.Studio.HeldRichTextWholeFormWriteTest do
  @moduledoc """
  task-881a41cd3227e73c, for a held rich text (`RichTextRemote.hold/2`): an
  object's rich text and a row's, held under the banner with B's save
  stored. An array op, a tag press, a tree codelist pick or a slug Generate
  on another field (`BarkparkWeb.HeldWrites`) wrote the whole form, A's held
  view in it, over B's save. Each now writes its own field and keeps B's
  rich text stored and A's view, with the banner.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias BarkparkWeb.HeldWrites

  @moduletag :studio_live

  @banner ~s([data-test-id="doc-conflict-banner"])
  @row "doc[meta].rows[0].rt"

  setup %{conn: conn} do
    c = setup_doc(conn)
    rt = fn name -> %{"name" => name, "title" => name, "type" => "richText"} end

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => c.type,
          "title" => "Object rich text",
          "visibility" => "public",
          "fields" =>
            [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              rt.("body"),
              %{
                "name" => "meta",
                "title" => "Meta",
                "type" => "composite",
                "fields" => [
                  %{"name" => "label", "title" => "Label", "type" => "string"},
                  rt.("rt"),
                  rt.("rt2"),
                  %{
                    "name" => "rows",
                    "title" => "Rows",
                    "type" => "arrayOf",
                    "of" => [
                      %{
                        "type" => "composite",
                        "name" => "row",
                        "title" => "Row",
                        "fields" => [rt.("rt")]
                      }
                    ]
                  }
                ]
              }
            ] ++ HeldWrites.fields()
        },
        "production"
      )

    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{
          "doc_id" => "drafts." <> c.id,
          "title" => doc.title,
          "content" => Map.merge(doc.content, HeldWrites.content())
        },
        "production"
      )

    c
  end

  defp row_post(view, html, seen) do
    fields = %{
      "doc[meta].label" => "l0",
      "doc[meta].rows[0]._type" => "row",
      "doc[meta].rows[0]._key" => "r1",
      @row => html
    }

    fields = if seen, do: Map.put(fields, "_bp_rt_seen", ["#{@row}|#{seen}"]), else: fields
    send_post(view, @row, fields)
  end

  defp row_words(c), do: words(hd(stored(c)["meta"]["rows"])["rt"])

  for surface <- [:desk, :studio], path <- HeldWrites.paths() do
    test "#{surface} #{path} on another field while meta.rt is held: B's rich text stays, A's view and the banner too",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}
      held_by_clash(a, b, c)
      view = form(a)["meta"]["rt"]

      HeldWrites.run(a, c, unquote(path))

      HeldWrites.landed(c, unquote(path))
      # On main: A's held view was written over B's "one TWO".
      assert words(stored(c)["meta"]["rt"]) == ["one TWO", "B para"]
      assert form(a)["meta"]["rt"] == view
      assert has_element?(a, @banner)
    end

    test "#{surface} #{path} on another field while a row's rich text is held: B's row stays, A's view and the banner too",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}

      inside(a, fn -> row_post(b, "<p>rowtexB</p>", nil) end, fn ->
        row_post(a, "<p>rowtextA</p>", 0)
      end)

      assert row_words(c) == ["rowtexB"]
      view = hd(form(a)["meta"]["rows"])["rt"]

      HeldWrites.run(a, c, unquote(path))

      HeldWrites.landed(c, unquote(path))
      # On main: A's "rowtextA" was written over B's row.
      assert row_words(c) == ["rowtexB"]
      assert hd(form(a)["meta"]["rows"])["rt"] == view
      assert has_element?(a, @banner)
    end
  end
end
