defmodule BarkparkWeb.GraphDraftsHybridTest do
  @moduledoc """
  THE HYBRID DRAFTS PATH (task `graph-endpoint-latency`, ruling recorded in
  `task-6ba71db1e7d115d2`).

  `Content.Graph.build_drafts_index/1` no longer live-extracts the whole
  corpus. Draft twins — and anything written inside the projector-lag window —
  are read WITH content and extracted; every other source's edges come from the
  materialised `content_edges` table; the phantom lens gets a content-free slug
  read.

  WHY: on guerrilla the old fold read ~150 MB of `content` jsonb per request
  (8,597 tasks at ~9.5 KB, 1,048 papers at ~62 KB) for a depth-2 graph. Live
  18.4 s, then 11.8 s after #17311. A projection cannot rescue it —
  `Plugins.Bulldocs.extract_edges/2` walks the whole content with no type guard
  — so the ROWS had to go: 882 of 10,528 documents (8.4%) have a `drafts.`
  twin.

  FOUR CONDITIONS, one test each. Every one of them FAILS on the pre-hybrid
  tree or under the named mutation; none of them is a restatement of another.

    1. `a DRAFT twin's dangling reference is still a dangling edge`
    2. `a PUBLISHED-ONLY doc's dangling reference is still a dangling edge`
       — the arm the row cut endangers, and the reason
       `recover_visited_dangling/4` keys on VISITED and not on twin status.
    3. `a document with no draft twin never joins the content read`
    4. `a document written inside the projector-lag window DOES` (+ the control
       outside it), so the window is a rule and not a coincidence.
  """

  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.{Auth, Content, TenancyFixtures, Repo}
  alias Barkpark.Content.Document

  @token "barkpark-test-graph-drafts-hybrid"
  @dataset "production"

  @test_timeout_ms 60_000

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

    {:ok, _} =
      Auth.create_token(@token, "graph-drafts-hybrid", @dataset, ["read", "write", "admin"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [%{"name" => "related", "type" => "reference", "refType" => "post"}]
        },
        @dataset,
        scope
      )

    %{scope: scope}
  end

  defp bearer(conn), do: put_req_header(conn, "authorization", "Bearer " <> @token)

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_draft!(doc_id, scope, content) do
    {:ok, doc} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # A PUBLISHED document with NO draft twin — the population the hybrid stops
  # live-extracting. `publish_document/4` promotes the draft row, so the
  # `drafts.` twin is gone afterwards.
  defp mk_published!(doc_id, scope, content) do
    mk_draft!(doc_id, scope, content)
    {:ok, doc} = Content.publish_document(doc_id, "post", @dataset, scope)
    doc
  end

  # Age a document out of the projector-lag window by backdating its row. The
  # window is a `updated_at >` predicate, so this is the only honest way to put
  # a document on the far side of it without sleeping.
  defp backdate!(doc_id, seconds) do
    then_ = DateTime.add(DateTime.utc_now(), -seconds, :second)
    twin = "drafts." <> doc_id

    {n, _} =
      Repo.update_all(
        from(d in Document, where: d.doc_id == ^doc_id or d.doc_id == ^twin),
        set: [updated_at: then_]
      )

    assert n > 0, "backdate! matched no row for #{doc_id} — the fixture is not what it claims"
    :ok
  end

  # Project the published corpus into `content_edges` synchronously. The worker
  # is async + debounced in production; a test that waited for it would be
  # testing Oban. This runs the SAME `Projector.rebuild_scope/3` the worker
  # calls, so the table the hybrid reads holds what the projector would put
  # there.
  defp project!(scope) do
    docs =
      Content.list_documents("post", @dataset, [perspective: :published, limit: 1000] ++ scope)

    {:ok, _} =
      Barkpark.EdgeProjector.Projector.rebuild_scope(@dataset, docs, [dataset: @dataset] ++ scope)

    :ok
  end

  defp graph(conn, root), do: conn |> bearer() |> get("/v1/graph/#{root}?drafts=true")

  defp body!(resp) do
    assert resp.status == 200, resp.resp_body
    Jason.decode!(resp.resp_body)
  end

  defp edge?(body, from, to),
    do: Enum.any?(body["edges"], fn e -> e["from_id"] == from and e["to_id"] == to end)

  defp phantom?(body, broken),
    do: Enum.any?(body["nodes"], fn n -> n["phantom"] == true and n["broken_id"] == broken end)

  # Sum the ROWS whose `content` the request actually pulled. ROWS, not
  # queries: the pre-hybrid fold read the whole corpus in the SAME number of
  # queries — one per ACL class — so a query counter cannot see this defect at
  # all, and a test built on one would pass on the code it is meant to reject.
  # (It did, until this was fixed: the whole-corpus mutation left the query
  # count untouched.) The slug read selects `doc_id`/`type` only, carries no
  # `"content"` in its SELECT list, and is deliberately not counted — it is the
  # cheap read the hybrid keeps.
  defp content_rows_read(fun) do
    me = self()
    counter = :counters.new(1, [:atomics])
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:barkpark, :repo, :query],
      fn _e, _m, meta, _cfg ->
        with true <- self() == me,
             true <- String.contains?(meta.query, ~s("content")),
             true <- String.contains?(meta.query, ~s(FROM "documents")),
             {:ok, %{num_rows: n}} when is_integer(n) <- meta.result do
          :counters.add(counter, 1, n)
        end
      end,
      nil
    )

    try do
      {fun.(), :counters.get(counter, 1)}
    after
      :telemetry.detach(handler_id)
    end
  end

  describe "phantom safety survives the row cut" do
    @tag timeout: @test_timeout_ms
    test "a DRAFT twin's dangling reference is still a dangling edge", %{conn: conn, scope: scope} do
      broken = uniq("hybrid-never-existed")
      root = uniq("hybrid-draft-root")
      mk_draft!(root, scope, %{"related" => broken})

      body = graph(conn, root) |> body!()

      assert edge?(body, root, broken),
             "the drafts graph lost a draft twin's broken reference: #{inspect(body["edges"])}"

      assert phantom?(body, broken),
             "the drafts graph lost the phantom for a draft twin's broken reference: " <>
               inspect(body["nodes"])
    end

    @tag timeout: @test_timeout_ms
    test "a PUBLISHED-ONLY doc's dangling reference is still a dangling edge",
         %{conn: conn, scope: scope} do
      # THE ARM THE ROW CUT ENDANGERS. `mid` is published, has NO draft twin,
      # and is aged out of the lag window — so the hybrid takes its edges from
      # content_edges, and content_edges CANNOT hold a dangling edge (the to_id
      # FK forbids it). The broken reference exists ONLY in `mid`'s content.
      # It survives because recover_visited_dangling/4 re-extracts the VISITED
      # documents, and `mid` is visited — the recovery keys on visited, never
      # on twin status.
      broken = uniq("hybrid-pub-never-existed")
      mid = uniq("hybrid-pub-mid")
      root = uniq("hybrid-pub-root")

      mk_published!(mid, scope, %{"related" => broken})
      mk_published!(root, scope, %{"related" => mid})
      project!(scope)
      backdate!(mid, 3600)
      backdate!(root, 3600)

      body = graph(conn, root) |> body!()

      assert edge?(body, root, mid),
             "the materialised arm lost a published doc's resolvable edge: #{inspect(body)}"

      assert edge?(body, mid, broken),
             "THE PHANTOM RECOVERY IS GONE. `#{mid}` is published with no draft twin, so its " <>
               "edges come from content_edges — which cannot store a dangling edge. Its broken " <>
               "reference to `#{broken}` exists only in its content, and only " <>
               "recover_visited_dangling/4 can put it back: #{inspect(body["edges"])}"

      assert phantom?(body, broken),
             "the broken reference is reported as an edge but its phantom node is missing — " <>
               "a consumer sees an edge to a node that is not in `nodes`: #{inspect(body)}"
    end
  end

  describe "the read tracks the drafts population, not the corpus" do
    @tag timeout: @test_timeout_ms
    test "a document with no draft twin never joins the content read",
         %{conn: conn, scope: scope} do
      root = uniq("hybrid-count-root")
      mk_draft!(root, scope, %{"related" => root})

      {resp, before_reads} = content_rows_read(fn -> graph(conn, root) end)
      body!(resp)

      # 30 PUBLISHED documents, no draft twins, all aged out of the lag window.
      # Under the pre-hybrid fold every one of them was read WITH content.
      published =
        for _ <- 1..30 do
          id = uniq("hybrid-count-published")
          mk_published!(id, scope, %{})
          id
        end

      project!(scope)
      Enum.each(published, &backdate!(&1, 3600))

      {resp2, after_reads} = content_rows_read(fn -> graph(conn, root) end)
      body!(resp2)

      assert after_reads <= before_reads,
             "adding 30 published-only documents took the content-bearing document ROWS from " <>
               "#{before_reads} to #{after_reads}. The hybrid must read `content` only for the " <>
               "live-extract set (draft twins + the lag window) and take everything else from " <>
               "content_edges — a count that grows with the PUBLISHED corpus is the 150 MB " <>
               "read coming back (task graph-endpoint-latency)."
    end
  end

  describe "the projector-lag window is a rule, in both directions" do
    @tag timeout: @test_timeout_ms
    test "a doc written INSIDE the window is live-extracted even with no draft twin",
         %{conn: conn, scope: scope} do
      # `mid` is published with no twin, and its reference was added AFTER the
      # projection ran — exactly the shape the async, debounced projector
      # leaves behind. Only the lag window can put it back in the graph.
      target = uniq("hybrid-lag-target")
      mid = uniq("hybrid-lag-mid")
      root = uniq("hybrid-lag-root")

      mk_published!(target, scope, %{})
      mk_published!(mid, scope, %{})
      mk_published!(root, scope, %{"related" => mid})
      project!(scope)

      # The write the projector has not seen. No re-projection follows.
      mk_draft!(mid, scope, %{"related" => target})
      {:ok, _} = Content.publish_document(mid, "post", @dataset, scope)
      backdate!(root, 3600)

      body = graph(conn, root) |> body!()

      assert edge?(body, mid, target),
             "`#{mid}` was written moments ago and its edge is NOT yet in content_edges, so the " <>
               "graph can only see it by live-extracting inside the projector-lag window. " <>
               "Content.Graph.projection_lag_window_s/0 is the bound: #{inspect(body["edges"])}"
    end

    @tag timeout: @test_timeout_ms
    test "a doc written OUTSIDE the window is NOT live-extracted (the control)",
         %{conn: conn, scope: scope} do
      # THE OTHER DIRECTION. Same shape, but the unprojected write is backdated
      # past the window. The graph must then show the PROJECTED state, not the
      # document's current content — otherwise the window is not a bound at all
      # and the first test passes for the wrong reason.
      target = uniq("hybrid-old-target")
      mid = uniq("hybrid-old-mid")
      root = uniq("hybrid-old-root")

      mk_published!(target, scope, %{})
      mk_published!(mid, scope, %{})
      mk_published!(root, scope, %{"related" => mid})
      project!(scope)

      mk_draft!(mid, scope, %{"related" => target})
      {:ok, _} = Content.publish_document(mid, "post", @dataset, scope)

      backdate!(root, 3600)
      backdate!(mid, 3600)
      backdate!(target, 3600)

      body = graph(conn, root) |> body!()

      refute edge?(body, mid, target),
             "`#{mid}`'s unprojected edge showed up even though the document was last written " <>
               "an hour ago — the lag window is not bounding anything, so the read is still " <>
               "the whole corpus: #{inspect(body["edges"])}"
    end
  end
end
