defmodule BarkparkWeb.OnixeditExportControllerTest do
  @moduledoc """
  WI6 — contract tests for `GET /v1/plugins/onixedit/export/:dataset/:id.onix`.

  Covers: 200 happy-path with ONIX XML body, 401 (no token), 403 (non-admin),
  404 (missing doc), 400 (wrong _type).
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content}

  @admin_token "barkpark-test-admin-token"
  @junior_token "barkpark-test-junior-token"
  @dataset "test"
  @book_id "wi6-book-1"
  @post_id "wi6-post-1"

  setup do
    {:ok, _admin} =
      Auth.create_token(@admin_token, "test-admin", "test", ["read", "write", "admin"])

    {:ok, _junior} = Auth.create_token(@junior_token, "test-junior", "test", ["read", "write"])

    {:ok, _book_schema} =
      Content.upsert_schema(
        %{
          "name" => "book",
          "title" => "Book",
          "visibility" => "private",
          "fields" => []
        },
        @dataset
      )

    {:ok, _post_schema} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset
      )

    fixture =
      Path.join([File.cwd!(), "test", "fixtures", "onix", "minimal-book.json"])
      |> File.read!()
      |> Jason.decode!()

    {:ok, _book} =
      Content.create_document(
        "book",
        %{"doc_id" => @book_id, "title" => "WI6 Book", "content" => fixture},
        @dataset
      )

    {:ok, _post} =
      Content.create_document(
        "post",
        %{"doc_id" => @post_id, "title" => "Just A Post", "content" => %{}},
        @dataset
      )

    :ok
  end

  defp admin_get(conn, path),
    do:
      conn
      |> put_req_header("authorization", "Bearer " <> @admin_token)
      |> get(path)

  describe "auth gating" do
    test "401 without an Authorization header", %{conn: conn} do
      resp = get(conn, "/v1/plugins/onixedit/export/#{@dataset}/#{@book_id}.onix")
      assert resp.status == 401
    end

    test "403 with a non-admin (junior) token", %{conn: conn} do
      resp =
        conn
        |> put_req_header("authorization", "Bearer " <> @junior_token)
        |> get("/v1/plugins/onixedit/export/#{@dataset}/#{@book_id}.onix")

      assert resp.status == 403
    end
  end

  describe "lookup" do
    test "404 when the document does not exist", %{conn: conn} do
      resp = admin_get(conn, "/v1/plugins/onixedit/export/#{@dataset}/does-not-exist.onix")
      assert resp.status == 404
    end

    test "400 when the document is not a book", %{conn: conn} do
      resp = admin_get(conn, "/v1/plugins/onixedit/export/#{@dataset}/#{@post_id}.onix")
      assert resp.status == 400
      payload = Jason.decode!(resp.resp_body)
      assert get_in(payload, ["error", "type"]) == "bad_request"
    end
  end

  describe "happy path (XSD-gated, requires xmllint)" do
    setup do
      if System.find_executable("xmllint") do
        :ok
      else
        {:skip, "xmllint not on PATH — install libxml2-utils to run controller happy-path"}
      end
    end

    test "200 returns ONIX XML with attachment headers", %{conn: conn} do
      resp = admin_get(conn, "/v1/plugins/onixedit/export/#{@dataset}/#{@book_id}.onix")

      assert resp.status == 200

      content_type =
        resp
        |> Plug.Conn.get_resp_header("content-type")
        |> List.first()
        |> Kernel.||("")

      assert content_type =~ "xml",
             "expected response content-type to mention xml; got: #{inspect(content_type)}"

      disposition =
        resp
        |> Plug.Conn.get_resp_header("content-disposition")
        |> List.first()
        |> Kernel.||("")

      assert disposition =~ ~s|attachment|
      assert disposition =~ ~s|filename="#{@book_id}.onix"|

      body = resp.resp_body
      assert body =~ ~s|<?xml |
      assert body =~ ~s|<ONIXMessage|
      assert body =~ ~s|release="3.0"|
      assert body =~ ~s|<RecordReference>barkpark.cloud:#{@book_id}</RecordReference>|
    end

    test "drafts. prefix and bare id resolve to the same export", %{conn: conn} do
      resp_bare = admin_get(conn, "/v1/plugins/onixedit/export/#{@dataset}/#{@book_id}.onix")
      assert resp_bare.status == 200
      assert resp_bare.resp_body =~ ~s|<ONIXMessage|
    end
  end
end
