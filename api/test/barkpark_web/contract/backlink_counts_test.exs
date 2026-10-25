defmodule BarkparkWeb.Contract.BacklinkCountsTest do
  @moduledoc """
  task-881bbea8c99b1599 — `GET /v1/data/backlink-counts/:dataset?ids=…`: how
  many documents reference each id through a schema-declared field, without
  reading them. Tag, category and author pages need "N books by this author".
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  @ds "test"
  @token "barkpark-test-backlink-counts"

  defp ref(name), do: %{"name" => name, "type" => "reference", "refType" => "bccontrib"}

  defp doc(type, id, content, publish? \\ true) do
    {:ok, _} =
      Content.create_document(type, Map.merge(%{"_id" => id, "title" => id}, content), @ds)

    if publish?, do: {:ok, _} = Content.publish_document(id, type, @ds)
  end

  setup do
    Content.upsert_schema(
      %{
        "name" => "bccontrib",
        "title" => "C",
        "visibility" => "public",
        "fields" => [%{"name" => "name", "type" => "string"}]
      },
      @ds
    )

    Content.upsert_schema(
      %{
        "name" => "bcproduct",
        "title" => "P",
        "visibility" => "public",
        "fields" => [
          ref("author"),
          %{
            "name" => "contributors",
            "type" => "arrayOf",
            "of" => %{"type" => "reference", "refType" => "bccontrib"}
          },
          %{"name" => "seo", "type" => "composite", "fields" => [ref("reviewer")]},
          Map.put(ref("secretRef"), "private", true),
          %{"name" => "cover", "type" => "image"}
        ]
      },
      @ds
    )

    for id <- ~w(k1 k2 k3), do: doc("bccontrib", id, %{"name" => id})
    # Both arms at once: a bare author and a {_ref} in an array.
    doc("bcproduct", "p1", %{
      "author" => "k1",
      "contributors" => [%{"_key" => "a", "_ref" => "k1"}]
    })

    doc("bcproduct", "p2", %{
      "contributors" => [%{"_key" => "a", "_ref" => "k1"}, %{"_key" => "b", "_ref" => "k2"}]
    })

    # A reference nested in an object, published and in a newer draft.
    doc("bcproduct", "p3", %{
      "seo" => %{"reviewer" => "k2"},
      "cover" => %{"asset" => %{"_ref" => "asset-x"}}
    })

    {:ok, _} =
      Content.create_document(
        "bcproduct",
        %{"_id" => "p3", "title" => "p3", "seo" => %{"reviewer" => "k2"}},
        @ds
      )

    # A private field: the caller cannot read it, so it never counts.
    doc("bcproduct", "p4", %{"secretRef" => "k3"})
    # Never published: counts for a token caller, who reads drafts.
    doc("bcproduct", "p5", %{"author" => %{"_ref" => "k1"}}, false)

    {:ok, _} =
      Barkpark.Auth.create_token(
        @token,
        "backlink-counts",
        @ds,
        ["read"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    :ok
  end

  defp counts(conn, query) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> get("/v1/data/backlink-counts/#{@ds}?" <> query)
    |> json_response(200)
    |> Map.fetch!("result")
  end

  test "each id counts its referrers once, across fields, nesting and versions", %{conn: conn} do
    r = counts(conn, "ids=k1,k2,k3,asset-x,nobody")
    assert r["byId"] == %{"k1" => 3, "k2" => 2, "k3" => 0, "asset-x" => 1, "nobody" => 0}
    assert r["source"] == "schema"
    assert r["note"] =~ "plugin edges are not counted"
  end

  test "type narrows to one referring type", %{conn: conn} do
    assert counts(conn, "ids=k1&type=bccontrib")["byId"] == %{"k1" => 0}
    assert counts(conn, "ids=k1&type=bcproduct")["byId"] == %{"k1" => 3}
  end

  test "a top-level count equals the length of the backlinks list", %{conn: conn} do
    backlinks =
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> get("/v1/data/backlinks/#{@ds}/k1")
      |> json_response(200)
      |> get_in(["result", "backlinks"])

    assert length(backlinks) == counts(conn, "ids=k1")["byId"]["k1"]
  end

  test "no token is a 404, and the id list is bounded", %{conn: conn} do
    assert conn |> get("/v1/data/backlink-counts/#{@ds}?ids=k1") |> json_response(404)

    many = Enum.map_join(1..101, ",", &"x#{&1}")

    assert conn
           |> put_req_header("authorization", "Bearer " <> @token)
           |> get("/v1/data/backlink-counts/#{@ds}?ids=" <> many)
           |> json_response(422)
  end
end
