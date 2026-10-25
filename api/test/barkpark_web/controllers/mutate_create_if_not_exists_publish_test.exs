defmodule BarkparkWeb.MutateCreateIfNotExistsPublishTest do
  @moduledoc """
  task-a093bebe46ea3dbb: `createIfNotExists` then `publish` in one request, on a
  document that is already published with no draft, is a no-op as in Sanity.
  The twin's ONIX import sends that pair for every product; it used to answer
  404 `not_found` for the ones that already existed.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth

  @dataset "test"

  setup do
    token = "cine-publish-#{System.unique_integer([:positive])}"

    Auth.create_token(
      token,
      "dev",
      @dataset,
      ["read", "write", "admin"],
      Barkpark.TenancyFixtures.default_workspace_id!()
    )

    %{token: token, id: "cine-#{System.unique_integer([:positive])}"}
  end

  defp mutate(token, mutations) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp pair(id, title) do
    [
      %{"createIfNotExists" => %{"_id" => id, "_type" => "post", "title" => title}},
      %{"publish" => %{"id" => id, "type" => "post"}}
    ]
  end

  # Every row of `id` (published and draft), as {_id, _rev, title}.
  defp rows(token, id) do
    conn =
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/v1/data/query/#{@dataset}/post?perspective=raw&limit=100")

    # The type has no rows at all yet: the query door answers 404.
    if conn.status == 404,
      do: [],
      else: conn |> json_response(200) |> get_in(["result", "documents"]) |> filter_rows(id)
  end

  defp filter_rows(docs, id) do
    docs
    |> Enum.filter(&(&1["_id"] in [id, "drafts." <> id]))
    |> Enum.map(&{&1["_id"], &1["_rev"], &1["title"]})
    |> Enum.sort()
  end

  defp ops(conn),
    do: conn |> json_response(200) |> Map.fetch!("results") |> Enum.map(& &1["operation"])

  test "the pair creates and publishes a new document, then is a no-op once it is published",
       %{token: token, id: id} do
    assert ops(mutate(token, pair(id, "First"))) == ["create", "publish"]

    results = mutate(token, pair(id, "Second")) |> json_response(200) |> Map.fetch!("results")
    assert Enum.map(results, & &1["operation"]) == ["noop", "noop"]
    # The published document keeps its content: the pair wrote nothing.
    assert Enum.map(
             results,
             &(&1["document"]["title"] || get_in(&1, ["document", "content", "title"]))
           ) ==
             ["First", "First"]
  end

  test "a publish with no draft on its own is still not_found", %{token: token, id: id} do
    assert ops(mutate(token, pair(id, "First"))) == ["create", "publish"]

    conn = mutate(token, [%{"publish" => %{"id" => id, "type" => "post"}}])
    assert conn.status == 404
  end

  test "a pending draft is still published by the pair", %{token: token, id: id} do
    assert ops(mutate(token, pair(id, "First"))) == ["create", "publish"]

    conn =
      mutate(token, [
        %{
          "createOrReplace" => %{"_id" => "drafts." <> id, "_type" => "post", "title" => "Edited"}
        }
      ])

    assert conn.status == 200
    assert ops(mutate(token, pair(id, "Ignored"))) == ["noop", "publish"]
  end

  test "a real first create plus publish is unchanged: one published row, no draft",
       %{token: token, id: id} do
    assert ops(mutate(token, pair(id, "First"))) == ["create", "publish"]
    assert [{^id, _rev, "First"}] = rows(token, id)
  end

  test "the other order, publish then createIfNotExists, is unchanged: the publish finds no draft",
       %{token: token, id: id} do
    reversed = fn title -> Enum.reverse(pair(id, title)) end

    # A new id: nothing to publish yet, and the request writes nothing.
    assert mutate(token, reversed.("New")).status == 404
    assert rows(token, id) == []

    # Already published: still 404, and the published row keeps its rev.
    assert ops(mutate(token, pair(id, "First"))) == ["create", "publish"]
    before = rows(token, id)
    assert mutate(token, reversed.("Second")).status == 404
    assert rows(token, id) == before
  end

  test "ifRevisionID still holds on the createIfNotExists of the pair", %{token: token, id: id} do
    assert ops(mutate(token, pair(id, "First"))) == ["create", "publish"]
    [{^id, rev, "First"}] = before = rows(token, id)

    [cine, publish] = pair(id, "Second")
    stale = [put_in(cine, ["createIfNotExists", "ifRevisionID"], "not-the-rev"), publish]
    conn = mutate(token, stale)
    assert conn.status == 412
    assert json_response(conn, 412)["error"]["code"] == "precondition_failed"
    assert rows(token, id) == before

    current = [put_in(cine, ["createIfNotExists", "ifRevisionID"], rev), publish]
    assert ops(mutate(token, current)) == ["noop", "noop"]
    assert rows(token, id) == before
  end

  test "the no-op covers only the id its createIfNotExists named", %{token: token, id: id} do
    other = id <> "-other"
    assert ops(mutate(token, pair(id, "First"))) == ["create", "publish"]
    assert ops(mutate(token, pair(other, "Other"))) == ["create", "publish"]

    [cine, _] = pair(id, "Second")
    conn = mutate(token, [cine, %{"publish" => %{"id" => other, "type" => "post"}}])
    assert conn.status == 404
  end
end
