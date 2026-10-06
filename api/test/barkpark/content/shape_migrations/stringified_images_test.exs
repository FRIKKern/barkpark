defmodule Barkpark.Content.ShapeMigrations.StringifiedImagesTest do
  @moduledoc """
  task-b44972b2869fb54a: image fields Beta stored as a JSON string before
  #21861 are counted and, on request, repaired to the map. Dry run by default.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.CanonicalShapes
  alias Barkpark.Content.ShapeMigrations.StringifiedImages

  @ds "stringified-img"
  @picker ~s({"url":"/media/a.jpg","assetId":"a1","alt":"Et fjell"})

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "simgpost",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "cover", "type" => "image"}
          ]
        },
        @ds
      )

    for {id, value} <- [
          {"str", @picker},
          {"url", "https://cdn.example/a.jpg"},
          {"map", %{"url" => "/media/b.jpg", "alt" => "B"}},
          {"arr", ~s([{"url":"/media/c.jpg"}])}
        ] do
      {:ok, _} =
        Content.create_document(
          "simgpost",
          %{"doc_id" => id, "title" => id, "content" => %{"cover" => value}},
          @ds
        )
    end

    # A string-typed field holding the same JSON is not an image: kept.
    {:ok, _} =
      Content.create_document(
        "simgpost",
        %{"doc_id" => "title-json", "title" => @picker, "content" => %{"title" => @picker}},
        @ds
      )

    :ok
  end

  defp cover(id) do
    {:ok, doc} = Content.get_document("drafts.#{id}", "simgpost", @ds)
    doc.content["cover"]
  end

  test "census counts only the JSON-object string in an image field" do
    assert %{type: "simgpost", field: "cover", documents: 1} in StringifiedImages.census()
    refute Enum.any?(StringifiedImages.census(), &(&1.type == "simgpost" and &1.field == "title"))
  end

  test "the dry run lists the repair and writes nothing; apply writes the map" do
    dry = StringifiedImages.run()
    assert dry.applied? == false
    rows = Enum.filter(dry.rows, &(&1.type == "simgpost"))
    assert [%{doc_id: "drafts.str", field: "cover", from: @picker, to: to}] = rows
    assert to == %{"url" => "/media/a.jpg", "assetId" => "a1", "alt" => "Et fjell"}
    assert cover("str") == @picker

    {:ok, before} = Content.get_document("drafts.str", "simgpost", @ds)
    kept = for id <- ~w(url map arr), into: %{}, do: {id, cover(id)}

    StringifiedImages.run(apply: true)

    assert cover("str") == to
    {:ok, after_apply} = Content.get_document("drafts.str", "simgpost", @ds)
    assert after_apply.rev != before.rev
    for {id, value} <- kept, do: assert(cover(id) == value, "#{id} must be kept as stored")
  end

  test "a repair does not wait on the canonical-shape flag" do
    before = Application.get_env(:barkpark, :canonical_shape_writes)
    on_exit(fn -> Application.put_env(:barkpark, :canonical_shape_writes, before) end)
    Application.put_env(:barkpark, :canonical_shape_writes, false)
    refute CanonicalShapes.writes_enabled?()
    assert %{applied?: true} = StringifiedImages.run(apply: true)
    assert %{"alt" => "Et fjell"} = cover("str")
  end
end
