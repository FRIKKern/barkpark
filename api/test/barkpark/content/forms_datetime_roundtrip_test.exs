defmodule Barkpark.Content.FormsDatetimeRoundtripTest do
  @moduledoc """
  A stored datetime survives a Classic edit of ANOTHER field.

  Stranger walk (2026-09-30): `publishedAt: "2026-01-01T12:00:00Z"` — the ISO
  shape `bp seed`, the API and the SDK write — showed an EMPTY `datetime-local`
  input (it accepts only `YYYY-MM-DDTHH:MM`), and since a posted `""` means
  "cleared", typing one character into the title erased it.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Forms

  @dataset "production"
  @schema %{
    fields: [
      %{"name" => "title", "type" => "string"},
      %{"name" => "publishedAt", "type" => "datetime"}
    ]
  }

  describe "datetime_form_value/1 (what the datetime-local input shows)" do
    # Owner ruling #46: an instant rides to the hidden input as its UTC
    # instant; the browser hook shows it in local time.
    test "renders every ISO shape the API accepts" do
      assert Forms.datetime_form_value("2026-01-01T12:00:00Z") == "2026-01-01T12:00:00Z"
      assert Forms.datetime_form_value("2026-01-01T14:00:00+02:00") == "2026-01-01T12:00:00Z"
      assert Forms.datetime_form_value("2026-01-01T12:00:30.123Z") == "2026-01-01T12:00:30Z"
      assert Forms.datetime_form_value("2026-01-01T12:00:00") == "2026-01-01T12:00"
      assert Forms.datetime_form_value("2026-10-01T09:30") == "2026-10-01T09:30"
      assert Forms.datetime_form_value("2026-01-01") == "2026-01-01T00:00"
    end

    test "shows empty for nothing and for what the input cannot represent" do
      assert Forms.datetime_form_value(nil) == ""
      assert Forms.datetime_form_value("") == ""
      assert Forms.datetime_form_value("next tuesday") == ""
    end

    test "doc_to_form hands the input the representable value" do
      doc = %{title: "T", status: "draft", content: %{"publishedAt" => "2026-01-01T12:00:00Z"}}
      assert Forms.doc_to_form(doc, @schema)["publishedAt"] == "2026-01-01T12:00:00Z"
    end
  end

  describe "a Classic save of another field" do
    setup do
      {:ok, doc} =
        Content.upsert_document(
          "widget",
          %{
            "doc_id" => "drafts.dt-roundtrip-#{System.unique_integer([:positive])}",
            "title" => "Before",
            "status" => "draft",
            "content" => %{"publishedAt" => "2026-01-01T12:00:30Z", "odd" => "x"}
          },
          @dataset
        )

      %{doc: doc}
    end

    test "keeps the stored datetime byte-identical when the input posts back what it showed",
         %{doc: doc} do
      form = Forms.doc_to_form(doc, @schema)
      params = Map.put(form, "title", "After")

      assert {:ok, saved, _} = Forms.upsert_draft(doc, "widget", @schema, params, @dataset)
      assert saved.title == "After"

      assert saved.content["publishedAt"] == "2026-01-01T12:00:30Z",
             "an untouched datetime must keep its offset and seconds"
    end

    test "keeps a stored datetime the input cannot represent (it showed empty)", %{doc: doc} do
      {:ok, odd} =
        Content.upsert_document(
          "widget",
          %{
            "doc_id" => doc.doc_id,
            "title" => "Before",
            "status" => "draft",
            "content" => %{"publishedAt" => "next tuesday"}
          },
          @dataset
        )

      params = odd |> Forms.doc_to_form(@schema) |> Map.put("title", "After")
      assert params["publishedAt"] == ""

      assert {:ok, saved, _} = Forms.upsert_draft(odd, "widget", @schema, params, @dataset)
      assert saved.content["publishedAt"] == "next tuesday"
    end

    test "an optional select whose stored value matches no option keeps it on an unrelated edit" do
      schema = %{
        fields: [
          %{"name" => "title", "type" => "string"},
          %{"name" => "status2", "type" => "select", "options" => ["draft", "live"]}
        ]
      }

      {:ok, doc} =
        Content.upsert_document(
          "widget",
          %{
            "doc_id" => "drafts.select-keep-#{System.unique_integer([:positive])}",
            "title" => "Before",
            "status" => "draft",
            "content" => %{"status2" => "archived"}
          },
          @dataset
        )

      # The "Select…" placeholder is what renders — and what posts: "".
      params = %{"title" => "After", "status2" => ""}
      assert {:ok, saved, _} = Forms.upsert_draft(doc, "widget", schema, params, @dataset)
      assert saved.content["status2"] == "archived"
    end

    test "a number or boolean stored in a string-control field keeps its type on an unrelated edit" do
      schema = %{
        fields: [
          %{"name" => "title", "type" => "string"},
          %{"name" => "slug", "type" => "slug"},
          %{"name" => "body", "type" => "text"},
          %{"name" => "rank", "type" => "number"}
        ]
      }

      {:ok, doc} =
        Content.upsert_document(
          "widget",
          %{
            "doc_id" => "drafts.types-keep-#{System.unique_integer([:positive])}",
            "title" => "Types",
            "status" => "draft",
            "content" => %{"slug" => 42, "body" => true, "rank" => 7}
          },
          @dataset
        )

      # What the Classic inputs show — and post back untouched: the string form.
      params = %{"title" => "Types!", "slug" => "42", "body" => "true", "rank" => "8"}
      assert {:ok, saved, _} = Forms.upsert_draft(doc, "widget", schema, params, @dataset)

      assert saved.content["slug"] === 42, "an untouched 42 must not become \"42\""
      assert saved.content["body"] === true, "an untouched true must not become \"true\""
      assert saved.content["rank"] === 8, "an EDITED number still coerces to the new value"
    end

    test "an EDITED datetime is stored as the input's value", %{doc: doc} do
      params = doc |> Forms.doc_to_form(@schema) |> Map.put("publishedAt", "2026-02-03T04:05")

      assert {:ok, saved, _} = Forms.upsert_draft(doc, "widget", @schema, params, @dataset)
      assert saved.content["publishedAt"] == "2026-02-03T04:05"
    end
  end
end
