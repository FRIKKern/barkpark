defmodule BarkparkWeb.GraphDerivedReadsTest do
  @moduledoc """
  `/v1/graph/orphans` and `/v1/graph/dangling` — the two DERIVED corpus reads.

  They emit a document's `type` and `title`, so they answer the same question
  `/v1/graph` answers ("what lives in this corpus?") and owe the same two
  contracts. Before this file they owed neither:

    1. SCHEMA VISIBILITY. `/v1/graph` clamps its type list through
       `Content.Schema.visible_schemas/2` (the canonical owner). These two read
       `scoped_docs_query/1` directly — tenancy- and owner-scoped, drafts
       excluded in SQL, but with NO type clamp at all. Both now pass the
       surviving type NAMES down as `:types`, and the narrowing fails CLOSED on
       an empty allowlist.

       HONEST SCOPE: the observable delta for a LIVE tier is ~zero, and
       deliberately so. Both routes are `:require_token`, and
       `PublicRead.allowed_route?/1` admits only the EXACT two-segment
       `/v1/graph` — so the one tier `visible_schemas/2` narrows (public-read)
       is already 403 here, asserted below. The clamp is defense-in-depth: it
       makes the derived reads safe the moment the route gate widens, and it
       removes the hand-rolled second answer to a question that has one owner.

    2. AN HONEST BOUND. The 5,000-row scan ceiling was already enforced inside
       `Content.Graph`, but both actions shipped a BARE LIST — a response that
       stopped at the ceiling was byte-indistinguishable from a complete
       answer. Both now carry `count`, `limit` and `truncated`, measured with a
       `limit + 1` probe row rather than guessed.

  MUTATION PROOFS, per describe block, are stated inline.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, TenancyFixtures}
  alias Barkpark.Content.Graph

  @admin_token "barkpark-test-graph-derived-admin"
  @public_read_token "barkpark-test-graph-derived-public"
  @dataset "production"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

    {:ok, _} =
      Auth.create_token(@admin_token, "graph-derived-admin", @dataset, ["read", "write", "admin"])

    {:ok, _} =
      Auth.create_token(@public_read_token, "graph-derived-public", @dataset, ["public-read"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for {name, visibility} <- [{"post", "public"}, {"secret", "private"}] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => name,
            "title" => String.capitalize(name),
            "visibility" => visibility,
            "fields" => []
          },
          @dataset,
          scope
        )
    end

    %{scope: scope, ws: ws, project: project}
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # A PUBLISHED, edge-free document — an orphan by construction.
  defp mk_orphan!(type, scope) do
    doc_id = uniq("derived-#{type}")

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => doc_id, "title" => "TITLE-#{doc_id}", "content" => %{}},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(doc_id, type, @dataset, scope)
    doc_id
  end

  describe "schema visibility on the derived reads (C3)" do
    # MUTATION PROOF: delete the `maybe_scope_to_types/2` call from
    # `Content.Graph.scoped_docs_query/1` (or make its empty-list clause a
    # no-op) and the two fail-closed arms below red — an unclamped caller gets
    # the private-type orphan back.
    test "the :types allowlist narrows orphans to the listed types", %{scope: scope} do
      public_id = mk_orphan!("post", scope)
      private_id = mk_orphan!("secret", scope)

      opts = [dataset: @dataset] ++ scope

      unclamped = Graph.orphans(opts) |> Enum.map(& &1.doc_id)
      assert public_id in unclamped
      assert private_id in unclamped, "fixture is not an orphan — the test would be vacuous"

      clamped = Graph.orphans(Keyword.put(opts, :types, ["post"])) |> Enum.map(& &1.doc_id)
      assert public_id in clamped
      refute private_id in clamped, "a private-type orphan survived the :types allowlist"
    end

    test "an EMPTY allowlist fails CLOSED — no types means no rows, never all rows", %{
      scope: scope
    } do
      mk_orphan!("post", scope)

      opts = [dataset: @dataset, types: []] ++ scope

      assert Graph.orphans(opts) == [],
             "an empty type allowlist returned rows — the clamp failed OPEN"

      assert Graph.dangling(opts) == [],
             "an empty type allowlist returned dangling rows — the clamp failed OPEN"
    end

    test "nil :types is 'no clamp requested', NOT 'no types' (every kernel caller)", %{
      scope: scope
    } do
      public_id = mk_orphan!("post", scope)

      rows = Graph.orphans([dataset: @dataset, types: nil] ++ scope) |> Enum.map(& &1.doc_id)
      assert public_id in rows
    end

    test "an admin token still sees BOTH type families over HTTP — the clamp does not over-narrow",
         %{conn: conn, scope: scope} do
      public_id = mk_orphan!("post", scope)
      private_id = mk_orphan!("secret", scope)

      resp = conn |> bearer(@admin_token) |> get("/v1/graph/orphans")
      assert resp.status == 200

      ids = Jason.decode!(resp.resp_body)["orphans"] |> Enum.map(& &1["doc_id"])
      assert public_id in ids
      assert private_id in ids, "the visibility clamp narrowed an ADMIN read"
    end

    test "public-read is 403 at both derived routes — the route gate, not the clamp, is the live seal",
         %{conn: conn} do
      for path <- ["/v1/graph/orphans", "/v1/graph/dangling"] do
        resp = conn |> bearer(@public_read_token) |> get(path)

        assert resp.status == 403,
               "#{path} returned #{resp.status} for public-read — expected 403 at the route"
      end
    end
  end

  describe "the bound is REPORTED, not merely enforced (C3)" do
    # MUTATION PROOF: drop the `+ 1` probe row from `orphans_bounded/1` and the
    # truncation arm below reds — `truncated` goes false on a corpus that IS
    # truncated, which is exactly the dishonesty the bare list shipped.
    setup do
      prev = Application.get_env(:barkpark, :graph_corpus_scan_limit)
      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:barkpark, :graph_corpus_scan_limit),
          else: Application.put_env(:barkpark, :graph_corpus_scan_limit, prev)
      end)

      :ok
    end

    test "an UNDER-bound corpus reports truncated: false and the real limit", %{
      conn: conn,
      scope: scope
    } do
      mk_orphan!("post", scope)

      resp = conn |> bearer(@admin_token) |> get("/v1/graph/orphans")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["truncated"] == false
      assert body["limit"] == Graph.corpus_scan_limit()
      assert body["count"] == length(body["orphans"])
    end

    test "an OVER-bound corpus is capped at the limit and says so", %{conn: conn, scope: scope} do
      for _ <- 1..3, do: mk_orphan!("post", scope)

      Application.put_env(:barkpark, :graph_corpus_scan_limit, 2)

      resp = conn |> bearer(@admin_token) |> get("/v1/graph/orphans")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)

      assert length(body["orphans"]) == 2,
             "the scan bound did not cap the row list (got #{length(body["orphans"])})"

      assert body["count"] == 2
      assert body["limit"] == 2

      assert body["truncated"] == true,
             "a corpus larger than the bound reported truncated: false — the probe row " <>
               "is not being read, so the response is indistinguishable from a complete one"
    end

    test "/v1/graph/dangling carries the same four keys", %{conn: conn, scope: scope} do
      mk_orphan!("post", scope)

      resp = conn |> bearer(@admin_token) |> get("/v1/graph/dangling")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)

      for key <- ["dangling", "count", "limit", "truncated"] do
        assert Map.has_key?(body, key), "/v1/graph/dangling dropped the #{key} key"
      end

      assert body["limit"] == Graph.corpus_scan_limit()
    end
  end
end
