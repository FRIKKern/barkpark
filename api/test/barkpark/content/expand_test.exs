defmodule Barkpark.Content.ExpandTest do
  use Barkpark.DataCase, async: true
  alias Barkpark.Content
  alias Barkpark.Content.{Envelope, Expand}

  setup do
    Content.upsert_schema(
      %{
        "name" => "author",
        "title" => "Author",
        "visibility" => "public",
        "fields" => [%{"name" => "title", "type" => "string"}]
      },
      "exp"
    )

    Content.upsert_schema(
      %{
        "name" => "post",
        "title" => "Post",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "author", "type" => "reference", "refType" => "author"}
        ]
      },
      "exp"
    )

    {:ok, _} =
      Content.create_document("author", %{"_id" => "a1", "title" => "Jane"}, "exp")

    {:ok, _} = Content.publish_document("a1", "author", "exp")

    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "p1", "title" => "Hello", "author" => "a1"},
        "exp"
      )

    {:ok, _} = Content.publish_document("p1", "post", "exp")

    :ok
  end

  test "expand/3 with :all resolves every reference field in the docs" do
    [post] =
      Content.list_documents("post", "exp", perspective: :published)
      |> Enum.map(&Envelope.render/1)
      |> Expand.expand(:all, "exp")

    assert post["title"] == "Hello"
    assert is_map(post["author"])
    assert post["author"]["_id"] == "a1"
    assert post["author"]["_type"] == "author"
    assert post["author"]["title"] == "Jane"
  end

  test "expand/3 with a field list only resolves those fields" do
    docs =
      Content.list_documents("post", "exp", perspective: :published)
      |> Enum.map(&Envelope.render/1)

    [post_none] = Expand.expand(docs, [], "exp")
    assert post_none["author"] == "a1"

    [post_author] = Expand.expand(docs, ["author"], "exp")
    assert is_map(post_author["author"])
    assert post_author["author"]["title"] == "Jane"
  end

  test "expand/3 leaves unresolved refs as raw strings" do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "p2", "title" => "Orphan", "author" => "does-not-exist"},
        "exp"
      )

    {:ok, _} = Content.publish_document("p2", "post", "exp")

    docs =
      Content.list_documents("post", "exp",
        perspective: :published,
        filter_map: %{"title" => "Orphan"}
      )
      |> Enum.map(&Envelope.render/1)

    [expanded] = Expand.expand(docs, :all, "exp")
    assert expanded["author"] == "does-not-exist"
  end

  test "expand/3 is shallow — referenced docs don't themselves get expanded" do
    Content.upsert_schema(
      %{
        "name" => "category",
        "title" => "Category",
        "visibility" => "public",
        "fields" => [%{"name" => "title", "type" => "string"}]
      },
      "exp"
    )

    Content.upsert_schema(
      %{
        "name" => "author",
        "title" => "Author",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "category", "type" => "reference", "refType" => "category"}
        ]
      },
      "exp"
    )

    {:ok, _} = Content.create_document("category", %{"_id" => "c1", "title" => "Cat"}, "exp")
    {:ok, _} = Content.publish_document("c1", "category", "exp")

    {:ok, _} =
      Content.create_document(
        "author",
        %{"_id" => "a2", "title" => "Nested", "category" => "c1"},
        "exp"
      )

    {:ok, _} = Content.publish_document("a2", "author", "exp")

    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "p3", "title" => "Deep", "author" => "a2"},
        "exp"
      )

    {:ok, _} = Content.publish_document("p3", "post", "exp")

    docs =
      Content.list_documents("post", "exp",
        perspective: :published,
        filter_map: %{"title" => "Deep"}
      )
      |> Enum.map(&Envelope.render/1)

    [post] = Expand.expand(docs, :all, "exp")
    assert is_map(post["author"])
    assert post["author"]["title"] == "Nested"
    assert post["author"]["category"] == "c1"
  end
end
