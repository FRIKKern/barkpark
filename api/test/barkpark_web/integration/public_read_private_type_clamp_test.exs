defmodule BarkparkWeb.Integration.PublicReadPrivateTypeClampTest do
  @moduledoc """
  The PRIVATE-VISIBILITY axis of the public-read clamp — the axis its sibling
  suite structurally cannot see.

  `public_read_search_matrix_test.exs` pins the DRAFTS axis and is green today.
  Its whole fixture corpus is seeded under ONE schema declared
  `"visibility" => "public"`, so a private-visibility document does not exist in
  it BY CONSTRUCTION: that suite stayed green through this defect and stays
  green through its fix, and is therefore NOT the oracle for anything below.
  This file seeds a PRIVATE-visibility type and is.

  ## The defect this file was written to fail on

  `DocumentsRetriever.restrict_anonymous_to_public_types/3` used to bypass the
  schema-visibility allowlist for `principal_type in [:api_token, :user]` — a
  test of "is authenticated", never of permission tier. A public-read token is
  an `:api_token`, so the browser-shipped site credential read EVERY private
  type through the scoped search door. Its parity partner
  `QueryController.authed?/1` (`not is_nil(conn.assigns[:api_token])`) had the
  same shape and stayed reachable on the SCOPED PREVIEW block, which rides bare
  `:scoped_api` with no `Plugs.PublicRead`.

  Both halves are keyed on the PERMISSION now — `"public-read" in permissions`,
  MEMBERSHIP and never list equality, so the real-world `["public-read","read"]`
  mint cannot walk past it.

  ## What is deliberately NOT done here

  `Plugs.PublicRead` is NOT mounted on `:scoped_api`. Its `allowed_route?/1`
  whitelists only GET query/doc/graph while 21 routes ride bare `:scoped_api`
  (scoped search, scoped federated search, suggestions/interaction/correction,
  the six preview reads and the whole scoped media surface) — mounting it would
  403 all of them and take the live flagship dark (search-template D49). The
  clamp filters; it never denies.

  ## The tier ladder has TWO rungs, not three

  The old bypass carried no permission test at all, so a `{read}` token behaved
  identically to `{admin}` BY DESIGN. Both are minted below as NON-REGRESSION
  controls — proof the clamp moved exactly one tier — not to measure a boundary
  that is a constant.

  ## Every clamped assertion carries a CONTROL

  An admin token asserts the same route DOES serve the private-type row, so a
  green public-read case means the clamp held, not that the seed was invisible
  to everyone.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content}

  import Barkpark.TenancyFixtures

  @dataset "production"

  # A nonsense term that matches BOTH seeded rows and nothing else in the tree.
  @probe "zarquonclamp"

  defp bearer(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp mint!(label, perms, ws_id) do
    raw = "#{label}-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, label, @dataset, perms, ws_id)
    raw
  end

  defp scoped(ws, proj, suffix), do: "/w/#{ws.slug}/p/#{proj.slug}#{suffix}"

  # Search ids at 200 — the status assertion is load-bearing: the clamp must
  # FILTER a public-read caller, never 403 it (D49).
  defp search_ids(conn, path) do
    body = conn |> get(path) |> json_response(200)
    Enum.map(body["documents"], & &1["_id"])
  end

  defp federated_ids(conn, path) do
    body = conn |> get(path) |> json_response(200)

    body
    |> get_in(["results", "documents", "hits"])
    |> Kernel.||([])
    |> Enum.map(& &1["_id"])
  end

  setup do
    ws = create_workspace!("prpt-ws")
    proj = create_project!(ws, "prpt-proj")
    scope = [workspace_id: ws.id, project_id: proj.id]

    # PUBLIC type — the site's own content. Must survive the clamp untouched.
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    # PRIVATE type — the leak surface. This is the row the sibling suite cannot
    # express: its fixture schema is visibility:public, full stop.
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "ledger", "title" => "Ledger", "visibility" => "private", "fields" => []},
        @dataset,
        scope
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "prpt-public", "title" => "Zarquonclamp Public Row"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("prpt-public", "post", @dataset, scope)

    {:ok, _} =
      Content.create_document(
        "ledger",
        %{"_id" => "prpt-private", "title" => "Zarquonclamp Private Row"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("prpt-private", "ledger", @dataset, scope)

    %{
      ws: ws,
      proj: proj,
      # The load-bearing real-world shape: TokenController allowlists
      # ~w(public-read read) and returns the list VERBATIM and UNORDERED, so a
      # `permissions == ["public-read"]` equality pin is escapable by mint.
      mixed: mint!("prpt-mixed", ["public-read", "read"], ws.id),
      singleton: mint!("prpt-singleton", ["public-read"], ws.id),
      read: mint!("prpt-read", ["read"], ws.id),
      admin: mint!("prpt-admin", ["read", "write", "admin"], ws.id)
    }
  end

  describe "scoped search — the browser-shipped door" do
    test "CONTROL: an admin token DOES read the private-type row (the seed is leak-observable)",
         %{conn: conn, ws: ws, proj: proj, admin: admin} do
      ids =
        conn
        |> bearer(admin)
        |> search_ids(scoped(ws, proj, "/v1/data/search/#{@dataset}?q=#{@probe}"))

      assert "prpt-private" in ids,
             "seed is not leak-observable: admin did not surface the private-type row, so a " <>
               "green public-read case below would prove nothing"

      assert "prpt-public" in ids
    end

    test "NON-REGRESSION CONTROL: a {read}-only token is UNAFFECTED by the clamp", %{
      conn: conn,
      ws: ws,
      proj: proj,
      read: read
    } do
      ids =
        conn
        |> bearer(read)
        |> search_ids(scoped(ws, proj, "/v1/data/search/#{@dataset}?q=#{@probe}"))

      assert "prpt-private" in ids,
             "the clamp moved more than one tier: a plain {read} token lost the private type"

      assert "prpt-public" in ids
    end

    test "CANARY: a mixed public-read token gets the public row and NOT the private one", %{
      conn: conn,
      ws: ws,
      proj: proj,
      mixed: mixed
    } do
      ids =
        conn
        |> bearer(mixed)
        |> search_ids(scoped(ws, proj, "/v1/data/search/#{@dataset}?q=#{@probe}"))

      refute "prpt-private" in ids,
             "public-read token read a PRIVATE-visibility document through the scoped search door"

      # FILTERS, never DENIES: 200 (asserted by search_ids) with the public row
      # still present. A 403 here would be the D49 regression.
      assert "prpt-public" in ids
    end

    test "CANARY: a singleton public-read token is clamped identically", %{
      conn: conn,
      ws: ws,
      proj: proj,
      singleton: singleton
    } do
      ids =
        conn
        |> bearer(singleton)
        |> search_ids(scoped(ws, proj, "/v1/data/search/#{@dataset}?q=#{@probe}"))

      refute "prpt-private" in ids
      assert "prpt-public" in ids
    end

    test "the clamp also seals the ?type= narrowing — asking for the private type by name " <>
           "yields an empty 200, never its rows",
         %{conn: conn, ws: ws, proj: proj, mixed: mixed, admin: admin} do
      path = scoped(ws, proj, "/v1/data/search/#{@dataset}?q=#{@probe}&type=ledger")

      assert "prpt-private" in (conn |> bearer(admin) |> search_ids(path)),
             "seed is not leak-observable under ?type=ledger"

      assert conn |> bearer(mixed) |> search_ids(path) == []
    end

    test "count and facets are clamped too, not just the rows", %{
      conn: conn,
      ws: ws,
      proj: proj,
      mixed: mixed
    } do
      body =
        conn
        |> bearer(mixed)
        |> get(scoped(ws, proj, "/v1/data/search/#{@dataset}?q=#{@probe}"))
        |> json_response(200)

      assert body["count"] == 1,
             "count leaked the private-type row even though the documents list did not"

      labels =
        body
        |> get_in(["facets", "type"])
        |> Kernel.||([])
        |> Enum.map(& &1["label"])

      refute "ledger" in labels, "the type facet leaked the private type's existence"
    end
  end

  describe "scoped federated search — the same retriever, a second transport" do
    test "CONTROL: an admin token DOES read the private-type row", %{
      conn: conn,
      ws: ws,
      proj: proj,
      admin: admin
    } do
      ids =
        conn
        |> bearer(admin)
        |> federated_ids(
          scoped(ws, proj, "/v1/search/#{@dataset}?q=#{@probe}&surfaces=documents")
        )

      assert "prpt-private" in ids
    end

    test "CANARY: a mixed public-read token is clamped on the federated door too", %{
      conn: conn,
      ws: ws,
      proj: proj,
      mixed: mixed
    } do
      ids =
        conn
        |> bearer(mixed)
        |> federated_ids(
          scoped(ws, proj, "/v1/search/#{@dataset}?q=#{@probe}&surfaces=documents")
        )

      refute "prpt-private" in ids
      assert "prpt-public" in ids
    end
  end

  # ── The parity partner: QueryController.authed?/1 ──────────────────────────
  #
  # The SCOPED PREVIEW block (`router.ex` ~:2196) rides bare `:scoped_api` — no
  # `Plugs.PublicRead` — so `authed?/1` was the ONLY gate standing between a
  # public-read token and a private type on six reads. Shipping the retriever
  # half alone would have left this open one layer up.
  describe "scoped preview reads — QueryController's authed?/1 parity" do
    test "CONTROL: an admin token reads the private type through scoped preview query", %{
      conn: conn,
      ws: ws,
      proj: proj,
      admin: admin
    } do
      body =
        conn
        |> bearer(admin)
        |> get(scoped(ws, proj, "/v1/preview/query/#{@dataset}/ledger"))
        |> json_response(200)

      assert Enum.any?(body["result"]["documents"], &(&1["_id"] == "prpt-private"))
    end

    test "NON-REGRESSION CONTROL: a {read}-only token still reads the private type there", %{
      conn: conn,
      ws: ws,
      proj: proj,
      read: read
    } do
      body =
        conn
        |> bearer(read)
        |> get(scoped(ws, proj, "/v1/preview/query/#{@dataset}/ledger"))
        |> json_response(200)

      assert Enum.any?(body["result"]["documents"], &(&1["_id"] == "prpt-private"))
    end

    test "CANARY: a mixed public-read token gets 404 on the private type (existence-hiding)", %{
      conn: conn,
      ws: ws,
      proj: proj,
      mixed: mixed
    } do
      conn
      |> bearer(mixed)
      |> get(scoped(ws, proj, "/v1/preview/query/#{@dataset}/ledger"))
      |> json_response(404)
    end

    test "the PUBLIC type still reads for a public-read token — the clamp is not a shutdown", %{
      conn: conn,
      ws: ws,
      proj: proj,
      mixed: mixed
    } do
      body =
        conn
        |> bearer(mixed)
        |> get(scoped(ws, proj, "/v1/preview/query/#{@dataset}/post"))
        |> json_response(200)

      assert Enum.any?(body["result"]["documents"], &(&1["_id"] == "prpt-public"))
    end

    test "CANARY: the existence-hiding reads (tags/counts) 404 a public-read token while a " <>
           "{read} token keeps them",
         %{conn: conn, ws: ws, proj: proj, mixed: mixed, read: read} do
      tags = scoped(ws, proj, "/v1/preview/tags/#{@dataset}")

      conn |> bearer(mixed) |> get(tags) |> json_response(404)
      assert conn |> bearer(read) |> get(tags) |> json_response(200) |> Map.has_key?("result")
    end
  end
end
