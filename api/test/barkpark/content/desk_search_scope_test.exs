defmodule Barkpark.Content.DeskSearchScopeTest do
  @moduledoc """
  Gyldendal parity E8, tenancy half: `search_documents_across_types/4` is
  TYPELESS, so it carries the typeless batch read's whole guard stack. A hit
  from another workspace, a hit in another dataset, a draft twin, and — for a
  caller that does not bypass the visibility gate — a private type must all be
  absent.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.CallerContext
  alias Barkpark.Tenancy

  @dataset "production"

  defp workspace(slug) do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "#{slug}-#{suffix}", name: slug})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    {ws, proj, [workspace_id: ws.id, project_id: proj.id]}
  end

  defp schema!(name, visibility, scope) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => name,
          "title" => String.capitalize(name),
          "visibility" => visibility,
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset,
        scope
      )
  end

  defp doc!(type, id, title, scope) do
    {:ok, _} =
      Content.upsert_document(
        type,
        %{"doc_id" => id, "title" => title, "status" => "published"},
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {:ok, _} = Content.publish_document(id, type, @dataset, scope)
  end

  defp titles(hits), do: hits |> Enum.map(& &1.title) |> Enum.sort()

  # An authenticated member: `bypasses_visibility_gate?/1` is true, so private
  # types are in view — the Studio desk's own caller.
  defp member_ctx,
    do: %CallerContext{
      principal_type: :api_token,
      token_id: Ecto.UUID.generate(),
      roles: ["read", "write", "admin"],
      is_admin: true
    }

  # A public-read token: the one tier the visibility gate narrows.
  defp public_read_ctx,
    do: %CallerContext{
      principal_type: :api_token,
      token_id: Ecto.UUID.generate(),
      roles: ["public-read"]
    }

  setup do
    {_ws_a, _proj_a, scope_a} = workspace("desk-a")
    {_ws_b, _proj_b, scope_b} = workspace("desk-b")

    schema!("publication", "public", scope_a)
    schema!("secret", "private", scope_a)
    schema!("publication", "public", scope_b)

    doc!("publication", "a-nord", "Nordic Crime A", scope_a)
    doc!("secret", "a-secret", "Nordic Secret A", scope_a)
    doc!("publication", "b-nord", "Nordic Crime B", scope_b)

    {:ok, scope_a: scope_a, scope_b: scope_b}
  end

  test "a workspace sees only its own hits", %{scope_a: a, scope_b: b} do
    a = Keyword.put(a, :caller_context, member_ctx())
    b = Keyword.put(b, :caller_context, member_ctx())

    assert titles(Content.search_documents_across_types("Nordic", @dataset, a)) ==
             ["Nordic Crime A", "Nordic Secret A"]

    assert titles(Content.search_documents_across_types("Nordic", @dataset, b)) ==
             ["Nordic Crime B"]
  end

  test "an unresolved caller_context is fail-closed to public types", %{scope_a: a} do
    assert titles(Content.search_documents_across_types("Nordic", @dataset, a)) ==
             ["Nordic Crime A"]
  end

  test "a caller that does not bypass the visibility gate never sees a private type", %{
    scope_a: a
  } do
    opts = Keyword.put(a, :caller_context, public_read_ctx())

    titles = titles(Content.search_documents_across_types("Nordic", @dataset, opts))
    assert "Nordic Crime A" in titles
    refute "Nordic Secret A" in titles
  end

  test "a blank query is no query at all", %{scope_a: a} do
    a = Keyword.put(a, :caller_context, member_ctx())
    assert Content.search_documents_across_types("", @dataset, a) == []
    assert Content.search_documents_across_types("   ", @dataset, a) == []
  end

  test "the draft twin is not a second hit", %{scope_a: a} do
    a = Keyword.put(a, :caller_context, member_ctx())

    {:ok, _} =
      Content.upsert_document(
        "publication",
        %{"doc_id" => "drafts.a-nord", "title" => "Nordic Crime A", "status" => "draft"},
        @dataset,
        Keyword.put(a, :source, :api)
      )

    assert titles(Content.search_documents_across_types("Nordic Crime A", @dataset, a)) ==
             ["Nordic Crime A"]
  end

  test "the limit is honoured", %{scope_a: a} do
    a = Keyword.put(a, :caller_context, member_ctx())
    for i <- 1..5, do: doc!("publication", "lim-#{i}", "Limit Probe #{i}", a)

    assert length(Content.search_documents_across_types("Limit Probe", @dataset, a, 3)) == 3
  end
end
