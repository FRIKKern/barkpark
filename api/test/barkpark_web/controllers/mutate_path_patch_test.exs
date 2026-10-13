defmodule BarkparkWeb.MutatePathPatchTest do
  @moduledoc """
  task-bfb66a2ff491f6e7 — `patch` ops take Sanity-style paths (`seo.metaTitle`,
  `body[_key=="b1"].text`, `tags[-1]`) and an `insert` op, through the real
  `/v1/data/mutate` door. Plain keys keep their top-level meaning.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content

  setup do
    Barkpark.Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "test",
      ["read", "write", "admin"],
      Barkpark.TenancyFixtures.default_workspace_id!()
    )

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    {:ok, doc} =
      Content.create_document(
        "post",
        %{
          "doc_id" => "pp1",
          "title" => "t",
          "content" => %{
            "seo" => %{"metaTitle" => "old title", "metaDescription" => "old description"},
            "body" => [
              %{"_key" => "b1", "_type" => "block", "text" => "one"},
              %{"_key" => "b2", "_type" => "block", "text" => "two"}
            ],
            "views" => 1
          }
        },
        "test"
      )

    {:ok, rev: doc.rev}
  end

  defp mutate(conn, patch) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/data/mutate/test",
      Jason.encode!(%{
        "mutations" => [%{"patch" => Map.merge(%{"id" => "pp1", "type" => "post"}, patch)}]
      })
    )
  end

  defp content do
    {:ok, doc} = Content.get_document("drafts.pp1", "post", "test")
    doc.content
  end

  defp keys(list), do: Enum.map(list, & &1["_key"])

  test "set on a nested path changes only that key", %{conn: conn} do
    assert mutate(conn, %{"set" => %{"seo.metaTitle" => "new title"}}).status == 200

    assert content()["seo"] == %{
             "metaTitle" => "new title",
             "metaDescription" => "old description"
           }
  end

  test "set by _key selector edits one array item", %{conn: conn} do
    resp = mutate(conn, %{"set" => %{~s(body[_key=="b2"].text) => "TWO"}})
    assert resp.status == 200
    assert Enum.map(content()["body"], & &1["text"]) == ["one", "TWO"]
  end

  test "set creates missing intermediate objects", %{conn: conn} do
    assert mutate(conn, %{"set" => %{"meta.og.image" => "x.png"}}).status == 200
    assert content()["meta"] == %{"og" => %{"image" => "x.png"}}
  end

  test "setIfMissing on a path fills only an absent key", %{conn: conn} do
    patch = %{"setIfMissing" => %{"seo.metaTitle" => "nope", "seo.canonical" => "/pp1"}}
    assert mutate(conn, patch).status == 200
    assert content()["seo"]["metaTitle"] == "old title"
    assert content()["seo"]["canonical"] == "/pp1"
  end

  test "unset removes a nested key, and an array item by _key", %{conn: conn} do
    resp = mutate(conn, %{"unset" => ["seo.metaDescription", ~s(body[_key=="b1"])]})
    assert resp.status == 200
    assert content()["seo"] == %{"metaTitle" => "old title"}
    assert keys(content()["body"]) == ["b2"]
  end

  test "inc and dec work on nested numbers", %{conn: conn} do
    assert mutate(conn, %{"inc" => %{"stats.likes" => 3}}).status == 200
    assert mutate(conn, %{"dec" => %{"stats.likes" => 1}}).status == 200
    assert content()["stats"] == %{"likes" => 2}
  end

  test "insert before, after and replace by _key, and after [-1]", %{conn: conn} do
    new = fn k -> %{"_key" => k, "_type" => "block", "text" => k} end

    assert mutate(conn, %{"insert" => %{"before" => ~s(body[_key=="b1"]), "items" => [new.("a")]}}).status ==
             200

    assert mutate(conn, %{"insert" => %{"after" => ~s(body[_key=="b1"]), "items" => [new.("c")]}}).status ==
             200

    assert mutate(conn, %{"insert" => %{"after" => "body[-1]", "items" => [new.("z")]}}).status ==
             200

    assert keys(content()["body"]) == ["a", "b1", "c", "b2", "z"]

    assert mutate(conn, %{"insert" => %{"replace" => ~s(body[_key=="c"]), "items" => [new.("C")]}}).status ==
             200

    assert keys(content()["body"]) == ["a", "b1", "C", "b2", "z"]
  end

  test "a selector that matches nothing changes nothing and warns", %{conn: conn} do
    before = content()
    resp = mutate(conn, %{"set" => %{~s(body[_key=="gone"].text) => "x"}})
    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert "patch.path_unmatched" in Enum.map(body["warnings"] || [], & &1["code"])
    assert content() == before
  end

  test "a path that does not parse is refused 422 and writes nothing", %{conn: conn} do
    before = content()
    resp = mutate(conn, %{"set" => %{"body[_key=b1].text" => "x"}})
    assert resp.status == 422
    body = Jason.decode!(resp.resp_body)
    assert body["error"]["code"] == "validation_failed"
    assert [msg] = body["error"]["details"]["path"]
    assert msg =~ "body[_key=b1].text"
    assert content() == before
  end

  test "walking a key into a string is refused 422", %{conn: conn} do
    resp = mutate(conn, %{"set" => %{"seo.metaTitle.x" => "y"}})
    assert resp.status == 422
  end

  test "an insert anchored on a plain key is refused 422", %{conn: conn} do
    resp = mutate(conn, %{"insert" => %{"after" => "seo.metaTitle", "items" => [1]}})
    assert resp.status == 422
  end

  test "a path under a protected key is skipped like the plain key", %{conn: conn} do
    assert mutate(conn, %{"set" => %{"_id.x" => "y", "seo.metaTitle" => "ok"}}).status == 200
    refute Map.has_key?(content(), "_id")
    assert content()["seo"]["metaTitle"] == "ok"
  end

  test "path patches honour ifRevisionID", %{conn: conn, rev: rev} do
    {:ok, draft} = Content.get_document("drafts.pp1", "post", "test")
    assert draft.rev == rev

    stale = mutate(conn, %{"set" => %{"seo.metaTitle" => "a"}, "ifRevisionID" => "not-the-rev"})
    assert stale.status == 412
    assert content()["seo"]["metaTitle"] == "old title"

    fresh = mutate(conn, %{"set" => %{"seo.metaTitle" => "b"}, "ifRevisionID" => rev})
    assert fresh.status == 200
    assert content()["seo"]["metaTitle"] == "b"
  end

  test "plain keys keep their top-level meaning", %{conn: conn} do
    assert mutate(conn, %{"set" => %{"seo" => %{"only" => 1}}}).status == 200
    assert content()["seo"] == %{"only" => 1}
  end
end
