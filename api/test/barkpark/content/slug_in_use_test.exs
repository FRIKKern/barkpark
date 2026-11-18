defmodule Barkpark.Content.SlugInUseTest do
  @moduledoc """
  `Content.SlugInUse.taken?/6`: another document of the type, draft or
  published, in either slug shape; the document's own versions do not count;
  one query per ask.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.SlugInUse

  @dataset "production"

  setup do
    n = System.unique_integer([:positive])
    type = "slugrule_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Slug rule",
          "visibility" => "public",
          "fields" => [%{"name" => "slug", "title" => "Slug", "type" => "slug"}]
        },
        @dataset
      )

    {:ok, type: type, n: n}
  end

  defp make(type, id, slug),
    do: {:ok, _} = Content.create_document(type, %{"doc_id" => id, "slug" => slug}, @dataset)

  test "the document's own draft and published versions do not take its slug", c do
    make(c.type, "own-#{c.n}", "mine")
    {:ok, _} = Content.publish_document("own-#{c.n}", c.type, @dataset)
    make(c.type, "own-#{c.n}", "mine")

    refute SlugInUse.taken?(c.type, "slug", "mine", "own-#{c.n}", @dataset, [])
    refute SlugInUse.taken?(c.type, "slug", "mine", "drafts.own-#{c.n}", @dataset, [])
    assert SlugInUse.taken?(c.type, "slug", "mine", "someone-#{c.n}", @dataset, [])
  end

  test "a draft holds its slug, in either shape", c do
    make(c.type, "a-#{c.n}", "plain")
    make(c.type, "b-#{c.n}", %{"_type" => "slug", "current" => "sanity"})

    assert SlugInUse.taken?(c.type, "slug", "plain", "x-#{c.n}", @dataset, [])
    assert SlugInUse.taken?(c.type, "slug", "sanity", "x-#{c.n}", @dataset, [])
    refute SlugInUse.taken?(c.type, "slug", "free", "x-#{c.n}", @dataset, [])
    refute SlugInUse.taken?(c.type, "slug", "", "x-#{c.n}", @dataset, [])
  end

  test "one ask is one query", c do
    make(c.type, "q-#{c.n}", "counted")
    me = self()
    handler = "slug-in-use-#{c.n}"

    :telemetry.attach(
      handler,
      [:barkpark, :repo, :query],
      fn _event, _measure, %{source: source}, _ -> send(me, {:query, source}) end,
      nil
    )

    try do
      assert SlugInUse.taken?(c.type, "slug", "counted", "other-#{c.n}", @dataset, [])
    after
      :telemetry.detach(handler)
    end

    assert_received {:query, "documents"}
    refute_received {:query, "documents"}
  end

  test "the text of either shape" do
    assert SlugInUse.text("a") == "a"
    assert SlugInUse.text(%{"_type" => "slug", "current" => "b"}) == "b"
    assert SlugInUse.text("") == nil
    assert SlugInUse.text(%{"current" => nil}) == nil
    assert SlugInUse.text(nil) == nil
  end
end
