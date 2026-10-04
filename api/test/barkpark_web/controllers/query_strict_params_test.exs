defmodule BarkparkWeb.QueryStrictParamsTest do
  @moduledoc """
  Owner ruling #53 (2026-10-03; task-cf3ace9b87b9f98d, task-e47dff813dab414f):
  the document read routes refuse a non-integer `?limit` / `?offset` and an
  `?expand` naming a field that is not a reference field, with the §9
  `malformed` 400 naming the parameter. Before the ruling each answered 200 —
  `?limit=abc` with the default page, `?expand=bogus` with nothing expanded.

  Out-of-range INTEGERS are still clamped as documented; those arms prove the
  fix did not over-tighten.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content

  @ds "query_strict_params_test"

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "author", "title" => "Author", "visibility" => "public", "fields" => []},
        @ds
      )

    {:ok, _} =
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
        @ds
      )

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "secret", "title" => "Secret", "visibility" => "private", "fields" => []},
        @ds
      )

    {:ok, _} = Content.create_document("author", %{"_id" => "a1", "name" => "Knut"}, @ds)
    {:ok, _} = Content.publish_document("a1", "author", @ds)

    {:ok, _} =
      Content.create_document("post", %{"_id" => "p1", "title" => "Hello", "author" => "a1"}, @ds)

    {:ok, _} = Content.publish_document("p1", "post", @ds)
    :ok
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer barkpark-dev-token")

  defp error!(resp, status) do
    body = json_response(resp, status)
    body["error"]
  end

  describe "?limit / ?offset on GET /v1/data/query" do
    test "a non-integer limit is a 400 naming the parameter", %{conn: conn} do
      err = conn |> get("/v1/data/query/#{@ds}/post?limit=abc") |> error!(400)
      assert err["code"] == "malformed"
      assert err["details"]["parameter"] == "limit"
      assert err["details"]["received"] == "abc"
      assert err["message"] =~ "limit"
    end

    test "a non-integer offset is a 400 naming the parameter", %{conn: conn} do
      err = conn |> get("/v1/data/query/#{@ds}/post?offset=abc") |> error!(400)
      assert err["details"]["parameter"] == "offset"
    end

    test "a decimal, a trailing-junk number and a list-shaped limit are refused", %{conn: conn} do
      for q <- ["limit=1.5", "limit=10abc", "limit[]=1", "limit="] do
        err = conn |> get("/v1/data/query/#{@ds}/post?#{q}") |> error!(400)
        assert err["details"]["parameter"] == "limit", "#{q} was not refused"
      end
    end

    test "out-of-range integers are still clamped, not refused", %{conn: conn} do
      assert %{"result" => %{"limit" => 1}} =
               conn |> get("/v1/data/query/#{@ds}/post?limit=0") |> json_response(200)

      assert %{"result" => %{"limit" => 1000}} =
               conn |> get("/v1/data/query/#{@ds}/post?limit=5000") |> json_response(200)

      assert %{"result" => %{"offset" => 0}} =
               conn |> get("/v1/data/query/#{@ds}/post?offset=-5") |> json_response(200)
    end

    test "an anonymous caller on a private type still gets 404, not the 400", %{conn: conn} do
      assert conn |> get("/v1/data/query/#{@ds}/secret?limit=abc") |> json_response(404)
    end
  end

  describe "?expand on GET /v1/data/query and /v1/data/doc" do
    test "a named reference field still expands", %{conn: conn} do
      body = conn |> get("/v1/data/query/#{@ds}/post?expand=author") |> json_response(200)
      [doc] = body["result"]["documents"]
      assert is_map(doc["author"])
      assert doc["author"]["_id"] == "a1"

      body = conn |> get("/v1/data/doc/#{@ds}/post/p1?expand=author") |> json_response(200)
      assert is_map(body["result"]["author"])
    end

    test "true and false are unchanged", %{conn: conn} do
      assert conn |> get("/v1/data/query/#{@ds}/post?expand=true") |> json_response(200)
      assert conn |> get("/v1/data/query/#{@ds}/post?expand=false") |> json_response(200)
    end

    test "an unknown field is a 400 naming it and listing the expandable fields", %{conn: conn} do
      err = conn |> get("/v1/data/query/#{@ds}/post?expand=bogus") |> error!(400)
      assert err["code"] == "malformed"
      assert err["details"]["parameter"] == "expand"
      assert err["details"]["unknown"] == ["bogus"]
      assert err["details"]["expandable"] == ["author"]
      assert err["message"] =~ ~s("bogus")
    end

    test "a field that exists but is not a reference is refused too", %{conn: conn} do
      err = conn |> get("/v1/data/query/#{@ds}/post?expand=author,title") |> error!(400)
      assert err["details"]["unknown"] == ["title"]
    end

    test "the doc route refuses the same way", %{conn: conn} do
      err = conn |> get("/v1/data/doc/#{@ds}/post/p1?expand=bogus") |> error!(400)
      assert err["details"]["parameter"] == "expand"
      assert err["details"]["unknown"] == ["bogus"]
    end

    test "a list-shaped expand is a 400, never a 500 or a silent 200", %{conn: conn} do
      err = conn |> get("/v1/data/query/#{@ds}/post", %{"expand" => ["author"]}) |> error!(400)
      assert err["details"]["parameter"] == "expand"
    end
  end

  describe "?limit / ?offset on GET /v1/data/history" do
    test "a non-integer limit or offset is a 400 naming the parameter", %{conn: conn} do
      for {q, param} <- [
            {"limit=abc", "limit"},
            {"offset=abc", "offset"},
            {"offset[]=1", "offset"}
          ] do
        err = conn |> authed() |> get("/v1/data/history/#{@ds}/post/p1?#{q}") |> error!(400)
        assert err["code"] == "malformed"
        assert err["details"]["parameter"] == param, "#{q} was not refused"
      end
    end

    test "out-of-range integers are still clamped", %{conn: conn} do
      assert %{"limit" => 1} =
               conn
               |> authed()
               |> get("/v1/data/history/#{@ds}/post/p1?limit=0")
               |> json_response(200)

      assert %{"offset" => 0} =
               conn
               |> authed()
               |> get("/v1/data/history/#{@ds}/post/p1?offset=-7")
               |> json_response(200)
    end
  end
end
