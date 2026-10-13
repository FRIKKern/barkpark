defmodule Barkpark.Search.PublicSearchVectorTest do
  @moduledoc """
  Owner ruling #20 (task-3c68de39a19285c4): the full-text index a non-admin
  caller searches holds public fields only.

  A public type that declares a private field used to match an anonymous
  search for a word that occurs ONLY in that field, and the hit count told the
  caller what the hidden field holds. `documents.public_search_vector`
  (migration 20261003200000) is the vector over the content with every
  restricted field removed; the retriever reads it for every caller that is
  not an admin.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.CallerContext
  alias Barkpark.Repo

  @ds "public-search-vector-test"

  defp scope! do
    ws = create_workspace!()
    proj = create_project!(ws)
    [workspace_id: ws.id, project_id: proj.id]
  end

  defp schema!(scope, fields, name \\ "memo") do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => name, "title" => "Memo", "visibility" => "public", "fields" => fields},
        @ds,
        scope
      )
  end

  defp doc!(scope, id, content, type \\ "memo") do
    {:ok, _} =
      Content.create_document(
        type,
        Map.merge(%{"doc_id" => id, "title" => "Memo #{id}"}, content),
        @ds,
        scope
      )

    {:ok, _} = Content.publish_document(id, type, @ds, scope)
  end

  defp search(scope, q, ctx), do: Content.search_documents(q, @ds, [caller_context: ctx] ++ scope)

  defp public_vector(id) do
    %{rows: [[v]]} =
      Repo.query!(
        "SELECT public_search_vector::text FROM documents WHERE doc_id = $1 AND dataset = $2",
        [id, @ds]
      )

    v
  end

  @admin %CallerContext{principal_type: :api_token, is_admin: true}
  @reader %CallerContext{principal_type: :api_token, token_id: "t-r", roles: ["read"]}

  test "anonymous search for a word only in a private field returns no hit and no count" do
    scope = scope!()

    schema!(scope, [
      %{"name" => "notes", "type" => "text", "private" => true},
      %{"name" => "summary", "type" => "text"}
    ])

    doc!(scope, "m1", %{"notes" => "quixotical secret", "summary" => "harmless overview"})

    assert {[], 0, _} = search(scope, "quixotical", CallerContext.anonymous())
    assert {[], 0, _} = search(scope, "quixotical", nil)
    assert {[], 0, _} = search(scope, "quixotical", @reader)
    # A quoted phrase rides the phrase arm — same index.
    assert {[], 0, _} = search(scope, ~s("quixotical secret"), CallerContext.anonymous())

    # The public field of the same document still matches for anonymous.
    assert {[_], 1, _} = search(scope, "harmless", CallerContext.anonymous())
    # An admin still finds the private word.
    assert {[_], 1, _} = search(scope, "quixotical", @admin)
  end

  test "an exclusion term cannot probe a private field either" do
    scope = scope!()
    schema!(scope, [%{"name" => "notes", "type" => "text", "private" => true}])
    doc!(scope, "m1", %{"notes" => "quixotical", "body" => "zephyrine"})

    # If the exclude arm read the full vector, `-quixotical` would drop m1 and
    # reveal that its private field holds the word.
    assert {[_], 1, _} = search(scope, "zephyrine -quixotical", CallerContext.anonymous())
  end

  test "owner_only, visibility: private, readable_by and nested private kids are all left out" do
    scope = scope!()

    schema!(scope, [
      %{"name" => "a", "type" => "string", "visibility" => "owner_only"},
      %{"name" => "b", "type" => "string", "visibility" => "private"},
      %{"name" => "c", "type" => "string", "readable_by" => ["someone"]},
      %{
        "name" => "meta",
        "type" => "object",
        "fields" => [%{"name" => "hidden", "type" => "string", "private" => true}]
      },
      %{
        "name" => "rows",
        "type" => "array",
        "of" => %{"fields" => [%{"name" => "secret", "type" => "string", "private" => true}]}
      }
    ])

    doc!(scope, "m1", %{
      "a" => "alphaword",
      "b" => "bravoword",
      "c" => "charlieword",
      "meta" => %{"hidden" => "deltaword", "shown" => "echoword"},
      "rows" => [%{"secret" => "foxtrotword", "label" => "golfword"}]
    })

    for w <- ~w(alphaword bravoword charlieword deltaword foxtrotword) do
      {_, anon_count, _} = search(scope, w, CallerContext.anonymous())
      assert anon_count == 0, "#{w} leaked"
      assert {[_], 1, _} = search(scope, w, @admin)
    end

    for w <- ~w(echoword golfword) do
      {_, anon_count, _} = search(scope, w, CallerContext.anonymous())
      assert anon_count == 1, "#{w} lost"
    end
  end

  test "a type with no restricted field keeps a NULL public vector and searches as before" do
    scope = scope!()
    schema!(scope, [%{"name" => "summary", "type" => "text"}])
    doc!(scope, "m1", %{"summary" => "zephyrine"})

    assert public_vector("m1") == nil
    assert {[_], 1, _} = search(scope, "zephyrine", CallerContext.anonymous())
  end

  test "making a field private after the fact reindexes the stored documents" do
    scope = scope!()
    schema!(scope, [%{"name" => "notes", "type" => "text"}])
    doc!(scope, "m1", %{"notes" => "quixotical"})
    assert {[_], 1, _} = search(scope, "quixotical", CallerContext.anonymous())

    schema!(scope, [%{"name" => "notes", "type" => "text", "private" => true}])
    assert {[], 0, _} = search(scope, "quixotical", CallerContext.anonymous())

    # And turning it public again restores the match.
    schema!(scope, [%{"name" => "notes", "type" => "text"}])
    assert {[_], 1, _} = search(scope, "quixotical", CallerContext.anonymous())
  end

  test "editing a document keeps its public vector current" do
    scope = scope!()
    schema!(scope, [%{"name" => "notes", "type" => "text", "private" => true}])
    doc!(scope, "m1", %{"notes" => "quixotical", "summary" => "first"})

    {:ok, _} =
      Content.create_document(
        "memo",
        %{
          "doc_id" => "m1",
          "title" => "Memo m1",
          "notes" => "quixotical",
          "summary" => "zephyrine"
        },
        @ds,
        scope
      )

    {:ok, _} = Content.publish_document("m1", "memo", @ds, scope)

    assert {[_], 1, _} = search(scope, "zephyrine", CallerContext.anonymous())
    assert {[], 0, _} = search(scope, "quixotical", CallerContext.anonymous())
  end

  test "census counts rows written without the trigger, and reindex repairs exactly those" do
    scope = scope!()
    schema!(scope, [%{"name" => "notes", "type" => "text", "private" => true}])
    doc!(scope, "m1", %{"notes" => "quixotical"})

    assert Barkpark.Search.PublicIndex.census(type: "memo") == []

    # Simulate a row restored with triggers off: the public vector is gone,
    # so the full vector stands in and the private word matches again.
    Repo.query!("UPDATE documents SET public_search_vector = NULL WHERE dataset = $1", [@ds])
    assert {[_], 1, _} = search(scope, "quixotical", CallerContext.anonymous())

    assert [%{type: "memo", stale: 1}] = Barkpark.Search.PublicIndex.census(type: "memo")
    assert Barkpark.Search.PublicIndex.reindex(type: "memo") == 1
    assert Barkpark.Search.PublicIndex.census(type: "memo") == []
    assert {[], 0, _} = search(scope, "quixotical", CallerContext.anonymous())
  end
end
