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
end
