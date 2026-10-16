defmodule Barkpark.Content.FormsFieldGapsTest do
  @moduledoc """
  The save half of three Studio field gaps (docs/studio-parity.md in the
  gyldendal.no twin, 2026-10-16).

    * task-cf45242ef3477fba: an edited datetime keeps the stored format (a
      value Sanity wrote carries milliseconds), and a `date` keeps its text.
    * task-b8bce68623e758ae: the checkbox list of an array of select values
      posts `[""]` plus the ticked values; the save stores the values only, in
      the posted order, and an empty selection stores `[]`.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Forms

  @dataset "production"
  @schema %{
    fields: [
      %{"name" => "title", "type" => "string"},
      %{"name" => "date", "type" => "datetime"},
      %{"name" => "day", "type" => "date"},
      %{
        "name" => "kinds",
        "type" => "arrayOf",
        "of" => %{"type" => "select", "options" => ["article", "event", "page"]}
      }
    ]
  }

  setup do
    {:ok, doc} =
      Content.upsert_document(
        "widget",
        %{
          "doc_id" => "drafts.field-gaps-#{System.unique_integer([:positive])}",
          "title" => "Before",
          "status" => "draft",
          "content" => %{
            "date" => "2026-10-29T14:00:00.000Z",
            "day" => "2026-10-29",
            "kinds" => ["article", "page"]
          }
        },
        @dataset
      )

    %{doc: doc}
  end

  defp save(doc, changes) do
    params = Map.merge(Forms.doc_to_form(doc, @schema), changes)
    {:ok, saved, _} = Forms.upsert_draft(doc, "widget", @schema, params, @dataset)
    saved.content
  end

  test "untouched date, datetime and checkbox list survive a title edit byte-identical",
       %{doc: doc} do
    content =
      save(doc, %{"title" => "After", "kinds" => ["", "article", "page"], "day" => "2026-10-29"})

    assert content["date"] == "2026-10-29T14:00:00.000Z"
    assert content["day"] == "2026-10-29"
    assert content["kinds"] == ["article", "page"]
  end

  test "an edited datetime keeps the stored milliseconds", %{doc: doc} do
    # The picker posts the UTC instant of Oslo 14:30 on 29 October.
    assert save(doc, %{"date" => "2026-10-29T13:30:00Z"})["date"] == "2026-10-29T13:30:00.000Z"
  end

  test "an edited datetime stored without milliseconds stays without them", %{doc: doc} do
    {:ok, doc} =
      Content.upsert_document(
        "widget",
        %{
          "doc_id" => doc.doc_id,
          "title" => doc.title,
          "status" => "draft",
          "content" => Map.put(doc.content, "date", "2026-10-29T14:00:00Z")
        },
        @dataset
      )

    assert save(doc, %{"date" => "2026-10-29T13:30:00Z"})["date"] == "2026-10-29T13:30:00Z"
  end

  test "an edited date is stored as the picker's day", %{doc: doc} do
    assert save(doc, %{"day" => "2026-11-02"})["day"] == "2026-11-02"
  end

  test "ticking and unticking boxes stores the values in posted order", %{doc: doc} do
    assert save(doc, %{"kinds" => ["", "article", "event", "page"]})["kinds"] ==
             ["article", "event", "page"]
  end

  test "unticking every box stores an empty list", %{doc: doc} do
    assert save(doc, %{"kinds" => [""]})["kinds"] == []
  end
end
