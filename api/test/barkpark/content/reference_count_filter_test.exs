defmodule Barkpark.Content.ReferenceCountFilterTest do
  @moduledoc """
  Gyldendal parity E9 — the two desk lists Sanity writes as a correlated count.

    _type == "category" && count(*[_type == "publication" && references(^._id)]) > 0
    _type == "category" && count(*[_type == "publication" && references(^._id)]) == 0

  `referencedBy` and `notReferencedBy` answer EXISTENCE, which is the whole of
  what those lists ask. This pins the pair as complements, the tenancy
  correlation (a neighbour workspace's publication never counts), the draft
  twin (it does count, like Sanity's desk), the plugin edge (it does not), and
  the refusal of a blank type name.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.CallerContext
  alias Barkpark.Tenancy

  @dataset "production"

  defp member_ctx,
    do: %CallerContext{
      principal_type: :api_token,
      token_id: Ecto.UUID.generate(),
      roles: ["read", "write", "admin"],
      is_admin: true
    }

  defp workspace(slug) do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "#{slug}-#{suffix}", name: slug})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    {ws, proj, [workspace_id: ws.id, project_id: proj.id, caller_context: member_ctx()]}
  end

  defp schema!(name, scope) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => name,
          "title" => String.capitalize(name),
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "category",
              "title" => "Category",
              "type" => "reference",
              "to" => ["category"]
            },
            %{
              "name" => "illustrators",
              "title" => "Illustrators",
              "type" => "arrayOf",
              "of" => %{"type" => "reference", "to" => ["category"]}
            }
          ]
        },
        @dataset,
        scope
      )
  end

  defp doc!(type, id, attrs, scope) do
    {:ok, d} =
      Content.upsert_document(
        type,
        Map.merge(%{"doc_id" => id, "status" => "published"}, attrs),
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    d
  end

  defp titles(type, filter, scope) do
    type
    |> Content.list_documents(@dataset, [filter_map: filter] ++ scope)
    |> Enum.map(& &1.title)
    |> Enum.sort()
  end

  @used %{"_id" => %{"referencedBy" => "publication"}}
  @unused %{"_id" => %{"notReferencedBy" => "publication"}}

  setup do
    {_ws_a, _proj_a, a} = workspace("e9-a")
    {_ws_b, _proj_b, b} = workspace("e9-b")

    for scope <- [a, b] do
      schema!("category", scope)
      schema!("publication", scope)
    end

    doc!("category", "cat-used", %{"title" => "Krim"}, a)
    doc!("category", "cat-unused", %{"title" => "Poesi"}, a)
    doc!("category", "cat-b", %{"title" => "Krim B"}, b)

    doc!(
      "publication",
      "pub-a",
      %{"title" => "Nordic Noir", "content" => %{"category" => "cat-used"}},
      a
    )

    # B's publication points at ITS OWN category, and nothing in A.
    doc!(
      "publication",
      "pub-b",
      %{"title" => "Southern Noir", "content" => %{"category" => "cat-b"}},
      b
    )

    {:ok, a: a, b: b}
  end

  test "the two ops are complements over the same corpus", %{a: a} do
    assert titles("category", @used, a) == ["Krim"]
    assert titles("category", @unused, a) == ["Poesi"]
  end

  test "a neighbour workspace's publication never counts", %{a: a, b: b} do
    # B's category is referenced in B and nowhere else; A's unused category
    # stays unused even though a publication elsewhere carries the same shape.
    assert titles("category", @used, b) == ["Krim B"]
    assert titles("category", @unused, b) == []
    assert titles("category", @unused, a) == ["Poesi"]
  end

  test "a referencing DRAFT twin counts, like Sanity's desk", %{a: a} do
    doc!(
      "publication",
      "drafts.pub-draft",
      %{"title" => "Unsaved", "content" => %{"category" => "cat-unused"}, "status" => "draft"},
      a
    )

    assert titles("category", @used, a) == ["Krim", "Poesi"]
    assert titles("category", @unused, a) == []
  end

  test "an arrayOf reference field counts too", %{a: a} do
    doc!(
      "publication",
      "pub-arr",
      %{"title" => "Anthology", "content" => %{"illustrators" => ["cat-unused"]}},
      a
    )

    assert titles("category", @used, a) == ["Krim", "Poesi"]
  end

  test "a type with no schema is a refusal, not two plausible-looking lists", %{a: a} do
    assert_raise Barkpark.Content.InvalidFilterError, fn ->
      Content.list_documents(
        "category",
        @dataset,
        [filter_map: %{"_id" => %{"referencedBy" => "publicaton"}}] ++ a
      )
    end
  end

  test "a blank or non-binary type name is a refusal, never an unfiltered set", %{a: a} do
    for bad <- ["", "   ", 7, nil] do
      assert_raise Barkpark.Content.InvalidFilterError, fn ->
        Content.list_documents(
          "category",
          @dataset,
          [filter_map: %{"_id" => %{"referencedBy" => bad}}] ++ a
        )
      end
    end
  end

  test "the ops are builder-only: they are refused on any field but the id columns", %{a: a} do
    assert_raise Barkpark.Content.InvalidFilterError, fn ->
      Content.list_documents(
        "category",
        @dataset,
        [filter_map: %{"title" => %{"referencedBy" => "publication"}}] ++ a
      )
    end
  end
end
