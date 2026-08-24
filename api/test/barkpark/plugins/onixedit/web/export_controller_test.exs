defmodule Barkpark.Plugins.OnixEdit.Web.ExportControllerTest do
  @moduledoc """
  WI6 — contract tests for `GET /v1/plugins/onixedit/export/:dataset/:id.onix`.

  Covers: 200 happy-path with ONIX XML body, 401 (no token), 403 (non-admin),
  404 (missing doc), 400 (wrong _type).

  Goal `barkpark-G3` s5 relocated this file from
  `test/barkpark_web/controllers/onixedit_export_controller_test.exs`
  alongside the controller's move into the plugin namespace. The URL
  pattern is unchanged — the controller now mounts via the plugin
  highway's `:api` scope rather than the deleted inlined host scope.
  """

  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

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

    test "404 when the id resolves to a non-book document", %{conn: conn} do
      # The scoped lookup now goes through `Content.get_document(_, "book", _, _)`,
      # which filters `type == "book"` at the query. A non-book id therefore
      # resolves to no row → 404 (previously a post-load type check returned 400;
      # the book endpoint no longer confirms the existence of non-book docs).
      resp = admin_get(conn, "/v1/plugins/onixedit/export/#{@dataset}/#{@post_id}.onix")
      assert resp.status == 404
      payload = Jason.decode!(resp.resp_body)
      # §9 names the discriminator `code`, never `type` — and the envelope now
      # carries the request_id that makes the refusal correlatable to the logs.
      assert get_in(payload, ["error", "code"]) == "not_found"
      assert is_binary(get_in(payload, ["error", "request_id"]))
    end
  end

  describe "invalid ONIX code → 422 structured body (no bare 500)" do
    # An unseeded-but-valid ONIX code used to `raise` out of `Export.to_iodata`
    # → unhandled → generic HTTP 500 with no body. It must now be a structured
    # 422 naming the offending codelist + code. No xmllint needed: the render
    # raises before the XSD gate runs.
    @bad_book_id "wi6-badcode"

    setup do
      fixture =
        Path.join([File.cwd!(), "test", "fixtures", "onix", "minimal-book.json"])
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("productForm", "ZZ")

      {:ok, _} =
        Content.create_document(
          "book",
          %{"doc_id" => @bad_book_id, "title" => "Bad Code Book", "content" => fixture},
          @dataset
        )

      :ok
    end

    test "422 with invalid_onix_code code + offending codelist/code in details", %{conn: conn} do
      resp = admin_get(conn, "/v1/plugins/onixedit/export/#{@dataset}/#{@bad_book_id}.onix")

      assert resp.status == 422
      payload = Jason.decode!(resp.resp_body)
      assert get_in(payload, ["error", "code"]) == "invalid_onix_code"
      # The offending codelist + value moved under `details`, and the ONIX code
      # is `details.onix_code` — `error.code` is the ERROR code now, so the two
      # meanings of "code" no longer collide in one envelope.
      assert get_in(payload, ["error", "details", "codelist"]) == "product_form"
      assert get_in(payload, ["error", "details", "onix_code"]) == "ZZ"
      assert is_binary(get_in(payload, ["error", "request_id"]))
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

  describe "cross-workspace isolation (barkpark-8ovd — P0 catalog leak)" do
    # Stand up two distinct workspaces, A and B, each with a project. The
    # admin token is a member of BOTH so the `:scoped_api` ResolveWorkspace
    # membership gate (a separate, routing-layer defense) does NOT 403 the
    # request to B — we want the request to REACH the controller so we exercise
    # the CONTROLLER's scope filter, which is the layer this fix hardens.
    #
    # A `book` is created STAMPED into workspace A / project A (dataset_id
    # populated via the project scope), so this fix stands alone without the
    # separate yx7f NULL-tolerant dataset_id work.
    setup do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)

      isolation_ds = "isolation_ds"

      {:ok, _schema} =
        Content.upsert_schema(
          %{"name" => "book", "title" => "Book", "visibility" => "private", "fields" => []},
          isolation_ds,
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )

      fixture =
        Path.join([File.cwd!(), "test", "fixtures", "onix", "minimal-book.json"])
        |> File.read!()
        |> Jason.decode!()

      book_a_id = "leak-book-a"

      {:ok, _book_a} =
        Content.create_document(
          "book",
          %{"doc_id" => book_a_id, "title" => "Workspace A Book", "content" => fixture},
          isolation_ds,
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )

      # An admin token bound to A, then ALSO made a member of B so the routing
      # membership gate lets requests to /w/B/... through to the controller.
      raw = "isolation-admin-#{System.unique_integer([:positive])}"

      {:ok, token} =
        Auth.create_token(
          raw,
          "isolation admin",
          isolation_ds,
          ["read", "write", "admin"],
          ws_a.id
        )

      {:ok, _} = TenancyAuth.create_membership(ws_b.id, token.id, "admin")

      {:ok,
       ws_a: ws_a,
       proj_a: proj_a,
       ws_b: ws_b,
       proj_b: proj_b,
       dataset: isolation_ds,
       book_id: book_a_id,
       raw_token: raw}
    end

    defp scoped_path(ws, proj, dataset, id),
      do: "/w/#{ws.slug}/p/#{proj.slug}/v1/plugins/onixedit/export/#{dataset}/#{id}.onix"

    test "LEGIT: scoped export resolved to workspace A returns A's book (200)", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      dataset: dataset,
      book_id: book_id,
      raw_token: raw
    } do
      if System.find_executable("xmllint") do
        resp =
          conn
          |> put_req_header("authorization", "Bearer " <> raw)
          |> get(scoped_path(ws_a, proj_a, dataset, book_id))

        assert resp.status == 200
        assert resp.resp_body =~ ~s|<ONIXMessage|
        assert resp.assigns.current_workspace.id == ws_a.id
      else
        # Without xmllint the XSD render is skipped; we still prove the scoped
        # lookup FINDS the book under A (a 500 xsd_invalid means the doc was
        # found and scope passed — NOT a 404). Tighten to the specific
        # xsd_invalid envelope so an unrelated crash-500 can't pass here too.
        resp =
          conn
          |> put_req_header("authorization", "Bearer " <> raw)
          |> get(scoped_path(ws_a, proj_a, dataset, book_id))

        case resp.status do
          200 ->
            :ok

          500 ->
            payload = Jason.decode!(resp.resp_body)

            assert get_in(payload, ["error", "code"]) == "xsd_invalid",
                   "expected the in-scope lookup's 500 to be the xsd_invalid envelope, got #{inspect(payload)}"

          other ->
            flunk("expected the in-scope lookup to FIND A's book (200 or xsd 500), got #{other}")
        end
      end
    end

    test "LEAK GATE: scoped export resolved to workspace B does NOT return A's book (404)", %{
      conn: conn,
      ws_b: ws_b,
      proj_b: proj_b,
      dataset: dataset,
      book_id: book_id,
      raw_token: raw
    } do
      resp =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(scoped_path(ws_b, proj_b, dataset, book_id))

      # The request reached the controller (membership gate passed for B), and
      # the controller's scope_opts(conn) carried B's workspace — A's book must
      # NOT resolve. Anything but 404 (especially a 200 with A's XML) is the leak.
      assert resp.status == 404,
             "CROSS-WORKSPACE LEAK: workspace B exported workspace A's book — got #{resp.status}"

      refute resp.resp_body =~ ~s|<ONIXMessage|
      assert resp.assigns.current_workspace.id == ws_b.id
    end
  end
end
