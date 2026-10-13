defmodule Barkpark.Content.ShapeMigrations.NaiveDatetimesTest do
  @moduledoc """
  Owner ruling #46: zone-less datetimes written before Studio saved UTC
  instants are counted and, on request, rewritten. Dry run by default.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Forms
  alias Barkpark.Content.ShapeMigrations.NaiveDatetimes

  @ds "naive-dt"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "ndtpost",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "publishedAt", "type" => "datetime"}
          ]
        },
        @ds
      )

    for {id, value} <- [{"old", "2026-10-03T10:30"}, {"new", "2026-10-03T08:30:00Z"}] do
      {:ok, _} =
        Content.create_document(
          "ndtpost",
          %{"doc_id" => id, "title" => id, "content" => %{"publishedAt" => value}},
          @ds
        )
    end

    :ok
  end

  test "census counts only the zone-less value" do
    assert %{type: "ndtpost", field: "publishedAt", count: 1} in NaiveDatetimes.census()
  end

  test "the dry run lists the rewrite and writes nothing; apply writes the instant" do
    dry = NaiveDatetimes.run(offset: "+02:00")
    assert dry.applied? == false

    assert %{doc_id: "drafts.old", from: "2026-10-03T10:30", to: "2026-10-03T08:30:00Z"} =
             Enum.find(dry.rows, &(&1.doc_id == "drafts.old"))

    refute Enum.any?(dry.rows, &(&1.doc_id == "drafts.new"))

    assert {:ok, %{content: %{"publishedAt" => "2026-10-03T10:30"}}} =
             Content.get_document("drafts.old", "ndtpost", @ds)

    {:ok, before} = Content.get_document("drafts.old", "ndtpost", @ds)
    {:ok, untouched} = Content.get_document("drafts.new", "ndtpost", @ds)
    NaiveDatetimes.run(offset: "+02:00", apply: true)

    assert {:ok, %{content: %{"publishedAt" => "2026-10-03T08:30:00Z"}} = after_apply} =
             Content.get_document("drafts.old", "ndtpost", @ds)

    assert after_apply.rev != before.rev
    assert {:ok, ^untouched} = Content.get_document("drafts.new", "ndtpost", @ds)
  end

  test "both shapes load into the Studio form (tolerant read)" do
    assert Forms.datetime_form_value("2026-10-03T10:30") == "2026-10-03T10:30"
    assert Forms.datetime_form_value("2026-10-03T08:30:00Z") == "2026-10-03T08:30:00Z"
  end

  test "an offset that is not +HH:MM is refused" do
    assert_raise ArgumentError, fn -> NaiveDatetimes.run(offset: "Europe/Oslo") end
  end
end
