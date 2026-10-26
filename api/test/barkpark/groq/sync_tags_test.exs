defmodule Barkpark.Groq.SyncTagsTest do
  @moduledoc """
  task-d6566cbed9b7c33c: GROQ sync tags carry each readable tag's opaque twin
  (the live events stream sends only those), and an untyped scan carries
  `bp:ds:<dataset>:_all`, so `*[slug.current == $s][0]` for a page not created
  yet still has a tag to refresh on.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Groq
  alias Barkpark.Groq.SyncTag

  defp touched(opts),
    do:
      Map.merge(
        %{ids: MapSet.new(), types: MapSet.new(), id_types: %{}, untyped: false},
        Map.new(opts)
      )

  test "an opaque twin is s1: plus 11 url-safe chars, stable, and per project" do
    a = SyncTag.opaque("proj-a", "bp:ds:production:type:post")
    assert a =~ ~r/\As1:[A-Za-z0-9_-]{11}\z/
    assert a == SyncTag.opaque("proj-a", "bp:ds:production:type:post")
    refute a == SyncTag.opaque("proj-b", "bp:ds:production:type:post")
    refute a == SyncTag.opaque("proj-a", "bp:ds:production:type:page")
    refute a =~ "post"
  end

  test "every readable tag is followed by its twin, in the same order" do
    tags = Groq.sync_tags("ds", touched(types: MapSet.new(["post"])), "p1")
    assert tags == ["bp:ds:ds:type:post", SyncTag.opaque("p1", "bp:ds:ds:type:post")]
  end

  test "an untyped scan carries the dataset's all tag; a typed one does not" do
    assert "bp:ds:ds:_all" in Groq.sync_tags("ds", touched(untyped: true), "p1")
    refute "bp:ds:ds:_all" in Groq.sync_tags("ds", touched(types: MapSet.new(["post"])), "p1")
  end

  test "both halves fit 128: document tags collapse to type tags past 64" do
    ids = for i <- 1..64, do: "d#{i}"

    many =
      touched(
        ids: MapSet.new(ids),
        id_types: Map.new(ids, &{&1, "post"}),
        types: MapSet.new(["page"])
      )

    tags = Groq.sync_tags("ds", many, "p1")
    assert length(tags) <= 128

    assert Enum.filter(tags, &String.starts_with?(&1, "bp:")) == [
             "bp:ds:ds:type:page",
             "bp:ds:ds:type:post"
           ]
  end
end
