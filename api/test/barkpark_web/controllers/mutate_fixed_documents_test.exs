defmodule BarkparkWeb.MutateFixedDocumentsTest do
  @moduledoc """
  task-f4c80d82cc25b19b: a type with a fixed set of documents
  (`fixedDocuments`, HSO's two side pages). No new document of the type is
  created and a listed one is not deleted, on every door; a type without the
  key behaves as before. `Barkpark.Content.FixedDocuments`.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content

  @listed ["side-om-oss", "side-hva-vi-jobber-med"]

  setup do
    dataset = "fixed_#{System.unique_integer([:positive])}"
    token = "barkpark-dev-token-fixed-#{System.unique_integer([:positive])}"
    ws = Barkpark.Tenancy.get_default_workspace()
    proj = Barkpark.Tenancy.get_default_project()
    Auth.create_token(token, "dev", dataset, ["read", "write", "admin"], ws.id)
    {:ok, ds} = Barkpark.Tenancy.create_dataset(proj, %{slug: dataset, name: dataset})
    scope = [workspace_id: ws.id, project_id: proj.id]
    type = "side_#{System.unique_integer([:positive])}"
    other = "page_#{System.unique_integer([:positive])}"

    for {name, extra} <- [{type, %{}}, {other, %{}}] do
      {:ok, _} =
        Content.upsert_schema(
          Map.merge(
            %{
              "name" => name,
              "title" => name,
              "fields" => [%{"name" => "body", "type" => "string"}]
            },
            extra
          ),
          dataset,
          scope
        )
    end

    %{token: token, dataset: dataset, ds: ds, scope: scope, type: type, other: other}
  end

  defp set_fixed(ctx, ids) do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => ctx.type, "fixedDocuments" => ids},
        ctx.dataset,
        ctx.scope
      )

    :ok
  end

  defp mutate(ctx, mutations) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> ctx.token)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{ctx.dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp doc(ctx, id, type \\ nil),
    do: %{"_id" => id, "_type" => type || ctx.type, "title" => id, "content" => %{"body" => "b"}}

  defp exists?(ctx, id, type \\ nil),
    do: match?({:ok, _}, Content.get_document(id, type || ctx.type, ctx.dataset, ctx.scope))

  defp refused?(resp, action) do
    resp.status == 409 and
      match?(
        %{"code" => "fixed_document", "details" => %{"action" => ^action}},
        json_response(resp, 409)["error"]
      )
  end

  # Seeds a document before the list is set, as the import does.
  defp seed(ctx, id, publish? \\ true) do
    assert mutate(ctx, [%{"create" => doc(ctx, id)}]).status == 200

    if publish?,
      do: assert(mutate(ctx, [%{"publish" => %{"id" => id, "type" => ctx.type}}]).status == 200)
  end

  test "no fixedDocuments: create, duplicate and delete are as before", ctx do
    seed(ctx, "a")
    assert mutate(ctx, [%{"create" => doc(ctx, "a-copy")}]).status == 200
    assert mutate(ctx, [%{"createIfNotExists" => doc(ctx, "b")}]).status == 200
    assert mutate(ctx, [%{"createOrReplace" => doc(ctx, "c")}]).status == 200
    assert mutate(ctx, [%{"delete" => %{"id" => "a", "type" => ctx.type}}]).status == 200
    refute exists?(ctx, "a")

    assert {:ok, nil} =
             {:ok, Barkpark.Content.FixedDocuments.fixed(ctx.type, ctx.dataset, ctx.scope)}
  end

  test "on a fixed type, a create of a new id is refused and a listed id is created", ctx do
    set_fixed(ctx, @listed)

    for verb <- ~w(create createIfNotExists createOrReplace) do
      resp = mutate(ctx, [%{verb => doc(ctx, "ny-side")}])
      assert refused?(resp, "create"), "#{verb}: #{resp.resp_body}"
      assert json_response(resp, 409)["error"]["message"] =~ ctx.type
    end

    refute exists?(ctx, "drafts.ny-side")
    # Direct publish and an id-less create are creates too.
    assert refused?(
             mutate(ctx, [%{"createOrReplace" => doc(ctx, "ny-side"), "publish" => true}]),
             "create"
           )

    assert refused?(mutate(ctx, [%{"create" => Map.delete(doc(ctx, "x"), "_id")}]), "create")

    # A listed id that does not exist yet: the first import, or a restore.
    assert mutate(ctx, [%{"create" => doc(ctx, "side-om-oss")}]).status == 200

    assert mutate(ctx, [
             %{"createOrReplace" => doc(ctx, "side-hva-vi-jobber-med"), "publish" => true}
           ]).status == 200

    # createOrReplace over a listed existing document is an edit.
    assert mutate(ctx, [
             %{"createOrReplace" => Map.put(doc(ctx, "side-om-oss"), "title", "Om oss")}
           ]).status == 200
  end

  test "a batch with one refused create writes nothing", ctx do
    set_fixed(ctx, @listed)

    resp =
      mutate(ctx, [%{"create" => doc(ctx, "side-om-oss")}, %{"create" => doc(ctx, "ny-side")}])

    assert refused?(resp, "create"), resp.resp_body
    refute exists?(ctx, "drafts.side-om-oss")
  end

  test "an empty list means nothing new may be created", ctx do
    seed(ctx, "gammel")
    set_fixed(ctx, [])
    assert refused?(mutate(ctx, [%{"create" => doc(ctx, "ny")}]), "create")
    # A document from before the list is still edited and deleted.
    assert mutate(ctx, [%{"createOrReplace" => doc(ctx, "gammel")}]).status == 200
    assert mutate(ctx, [%{"delete" => %{"id" => "gammel", "type" => ctx.type}}]).status == 200
  end

  test "a listed document is not deleted; drafts, publish, unpublish and patch work", ctx do
    seed(ctx, "side-om-oss")
    set_fixed(ctx, @listed)

    assert refused?(
             mutate(ctx, [%{"delete" => %{"id" => "side-om-oss", "type" => ctx.type}}]),
             "delete"
           )

    assert refused?(mutate(ctx, [%{"delete" => %{"id" => "side-om-oss"}}]), "delete")
    assert exists?(ctx, "side-om-oss")

    # Edit, discard, edit, publish, unpublish, publish: the document stays.
    patch = %{
      "patch" => %{"id" => "drafts.side-om-oss", "type" => ctx.type, "set" => %{"body" => "ny"}}
    }

    assert mutate(ctx, [%{"createOrReplace" => doc(ctx, "side-om-oss")}]).status == 200

    assert mutate(ctx, [%{"discardDraft" => %{"id" => "side-om-oss", "type" => ctx.type}}]).status ==
             200

    assert mutate(ctx, [%{"createOrReplace" => doc(ctx, "side-om-oss")}, patch]).status == 200

    # A delete of the draft id drops only the draft (task-47f8394f07b97f8b): allowed.
    assert mutate(ctx, [%{"delete" => %{"id" => "drafts.side-om-oss", "type" => ctx.type}}]).status ==
             200

    assert exists?(ctx, "side-om-oss")

    assert mutate(ctx, [%{"unpublish" => %{"id" => "side-om-oss", "type" => ctx.type}}]).status ==
             200

    assert mutate(ctx, [%{"publish" => %{"id" => "side-om-oss", "type" => ctx.type}}]).status ==
             200

    assert exists?(ctx, "side-om-oss")

    # A listed page that exists only as a draft: deleting the draft is discarding it
    # (no published document is removed), and the page can be created again.
    assert mutate(ctx, [%{"create" => doc(ctx, "side-hva-vi-jobber-med")}]).status == 200

    assert mutate(ctx, [
             %{"delete" => %{"id" => "drafts.side-hva-vi-jobber-med", "type" => ctx.type}}
           ]).status == 200

    assert mutate(ctx, [%{"create" => doc(ctx, "side-hva-vi-jobber-med")}]).status == 200

    # The Writer and Lifecycle doors (Studio, import), not only the mutate API.
    assert {:error, {:fixed_document, :delete, _, "side-om-oss"}} =
             Content.delete_document("drafts.side-om-oss", ctx.type, ctx.dataset, ctx.scope)

    assert {:error, {:fixed_document, :create, _, "kopi"}} =
             Content.create_document(
               ctx.type,
               %{"doc_id" => "kopi", "title" => "k"},
               ctx.dataset,
               ctx.scope
             )
  end

  test "an unlisted document left from before the list can still be deleted", ctx do
    seed(ctx, "gammel")
    set_fixed(ctx, @listed)
    assert mutate(ctx, [%{"delete" => %{"id" => "gammel", "type" => ctx.type}}]).status == 200
    refute exists?(ctx, "gammel")
  end

  test "a document cannot move into a fixed type under an unlisted id", ctx do
    set_fixed(ctx, @listed)
    assert mutate(ctx, [%{"create" => doc(ctx, "flytt", ctx.other)}]).status == 200
    # The id is (id, type): a write under the fixed type is a create of a new document.
    assert refused?(mutate(ctx, [%{"createOrReplace" => doc(ctx, "flytt")}]), "create")
    refute exists?(ctx, "drafts.flytt")
  end

  test "emptying the dataset removes fixed documents as before", ctx do
    seed(ctx, "side-om-oss")
    set_fixed(ctx, @listed)
    assert {:ok, _} = Barkpark.Tenancy.DatasetDelete.empty(ctx.ds)
    refute exists?(ctx, "side-om-oss")
  end

  test "fixedDocuments round-trips, null removes it, and a malformed list is refused", ctx do
    set_fixed(ctx, @listed ++ ["side-om-oss"])

    get = fn name ->
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> ctx.token)
      |> get("/v1/schemas/#{ctx.dataset}/#{name}")
      |> json_response(200)
      |> Map.fetch!("schema")
    end

    pulled = get.(ctx.type)
    assert pulled["fixedDocuments"] == @listed
    refute Map.has_key?(get.(ctx.other), "fixedDocuments")

    # Pull, then push back unchanged: same list, same hash.
    {:ok, _} =
      Content.upsert_schema(Map.drop(pulled, ["id", "schemaHash"]), ctx.dataset, ctx.scope)

    assert get.(ctx.type)["schemaHash"] == pulled["schemaHash"]

    for bad <- ["side-om-oss", [1], ["drafts.side-om-oss"], [""], %{"a" => 1}] do
      assert {:error, %Ecto.Changeset{}} =
               Content.upsert_schema(
                 %{"name" => ctx.type, "fixedDocuments" => bad},
                 ctx.dataset,
                 ctx.scope
               )
    end

    assert get.(ctx.type)["fixedDocuments"] == @listed

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => ctx.type, "fixedDocuments" => nil},
        ctx.dataset,
        ctx.scope
      )

    refute Map.has_key?(get.(ctx.type), "fixedDocuments")
    assert mutate(ctx, [%{"create" => doc(ctx, "ny")}]).status == 200
  end
end
