defmodule BarkparkWeb.GraphControllerTest do
  @moduledoc """
  Goal ges/graph-edge-seam Phase 4 — contract tests for the `/v1/graph/*`
  surface (`graph_show`, `graph_orphans`, `graph_dangling` on
  `BarkparkWeb.TasksController`).

  The headline test is the ROUTE-PRESENCE assertion: `GET /v1/graph/<id>` MUST
  NOT 404. Because `register_routes/1` is read at MACRO EXPANSION via
  `Registry.collect_routes/1`, a STALE router beam yields a 404 identical to a
  missing route. This test is the trip-wire that catches a future stale beam —
  the Phase-4 verify recipe nukes the test router beam before compiling
  precisely so this passes.

    * route presence: GET /v1/graph/<id> is NOT 404 (the stale-beam guard).
    * graph_show roots on a NON-task content doc (gap #4 generic root).
    * graph_show 404s for an unknown id.
    * graph_orphans returns 200 with an `orphans` list.
    * graph_dangling returns 200 with a `dangling` list.
    * auth: 401 without a token.
  """

  use BarkparkWeb.ConnCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.{Auth, Content, QueryCounter, Repo, Tasks, TenancyFixtures}
  alias Barkpark.EdgeProjector.ProjectorWorker

  @token "barkpark-test-graph-token"
  @dataset "production"

  setup do
    # E3 tag registry: the fixture weighted tags (fixture-tag-N) these tests
    # publish must resolve to PUBLISHED type:tag docs in the dataset scope.
    Barkpark.LabelFixtures.register_tags!(@dataset)

    {:ok, _} = Auth.create_token(@token, "test-graph", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    # A plain non-task content schema so we prove graph_show roots on ANY type
    # (gap #4) — NOT just tasks.
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    %{scope: scope}
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp mk_post!(doc_id, scope) do
    {:ok, doc} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => %{}},
        @dataset,
        scope
      )

    doc
  end

  # The corpus endpoint reads with perspective: :published, so a fixture that
  # only creates a DRAFT contributes no node and no edge — and would make the
  # query-cost guard below silently vacuous (nothing to fold over).
  defp mk_published_post!(doc_id, scope) do
    _draft = mk_post!(doc_id, scope)
    {:ok, doc} = Content.publish_document(doc_id, "post", @dataset, scope)
    doc
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "auth gating" do
    test "GET /v1/graph/orphans returns 401 without a token", %{conn: conn} do
      resp = get(conn, "/v1/graph/orphans")
      assert resp.status == 401
    end
  end

  describe "route presence (stale-router-beam guard)" do
    test "GET /v1/graph/<id> is NOT 404 — the route is mounted", %{conn: conn, scope: scope} do
      doc_id = uniq("graph-route")
      # Published: the default perspective resolves ONLY a published root
      # (graph_draft_leak_test.exs — the draft-only fallback was a title leak).
      _post = mk_published_post!(doc_id, scope)

      resp = conn |> authed() |> get("/v1/graph/#{doc_id}")

      # The CARDINAL assertion: a NET-NEW route read at macro-expansion is only
      # live if the router beam was recompiled. A stale beam → 404. We assert the
      # route resolves (200), which can ONLY happen if the route is mounted.
      refute resp.status == 404,
             "GET /v1/graph/:id 404ed — router beam is STALE (recompile required)"

      assert resp.status == 200
    end
  end

  describe "GET /v1/graph/:id" do
    test "roots on a NON-task content doc (gap #4 generic root)", %{conn: conn, scope: scope} do
      doc_id = uniq("graph-post")
      _post = mk_published_post!(doc_id, scope)

      resp = conn |> authed() |> get("/v1/graph/#{doc_id}")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true
      assert body["root"] == doc_id
      assert is_list(body["nodes"])
      assert is_list(body["edges"])
      assert is_list(body["dependents"])
      assert Map.has_key?(body, "truncated")
      assert Map.has_key?(body, "truncation_reason")
    end

    test "404s for an unknown id", %{conn: conn} do
      resp =
        conn |> authed() |> get("/v1/graph/no-such-doc-#{System.unique_integer([:positive])}")

      assert resp.status == 404
    end
  end

  describe "GET /v1/graph/orphans" do
    test "returns 200 with an orphans list", %{conn: conn, scope: scope} do
      _orphan = mk_post!(uniq("orphan"), scope)

      resp = conn |> authed() |> get("/v1/graph/orphans?dataset=#{@dataset}")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true
      assert is_list(body["orphans"])
    end
  end

  describe "GET /v1/graph/dangling" do
    test "returns 200 with a dangling list", %{conn: conn} do
      resp = conn |> authed() |> get("/v1/graph/dangling?dataset=#{@dataset}")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true
      assert is_list(body["dangling"])
    end
  end

  # ── GET /v1/graph/:id/tasks — the expectation reverse view (lvw-t8) ────────

  describe "GET /v1/graph/:id/tasks" do
    # The REAL task schemas (edge extraction is schema-declared; the
    # `design_doc` reference field must be the genuine article).
    defp register_task_schemas!(scope) do
      for schema_def <- Tasks.schema_definitions(@dataset) do
        attrs =
          schema_def
          |> Map.from_struct()
          |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
          |> Map.new(fn {k, v} -> {to_string(k), v} end)

        {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
      end
    end

    defp publish_task_citing!(paper_doc_id, task_doc_id, scope, content_extra) do
      content =
        %{"kind" => "task", "lifecycle_status" => "open", "design_doc" => paper_doc_id}
        |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
        |> Map.merge(content_extra)

      {:ok, _} =
        Content.create_document(
          "task",
          %{"doc_id" => task_doc_id, "title" => task_doc_id, "content" => content},
          @dataset,
          scope
        )

      # Dedup wrinkle (lvw-t11-followup-dedup): drop pending rebuilds so this
      # publish enqueues its own `types: ["task"]` job (see expectations_test).
      Repo.delete_all(Oban.Job)

      {:ok, doc} = Content.publish_document(task_doc_id, "task", @dataset, scope)
      doc
    end

    defp drain_projector! do
      for job <- all_enqueued(worker: ProjectorWorker) do
        perform_job(ProjectorWorker, job.args)
      end

      :ok
    end

    test "lists a published citing task with its expectation state",
         %{conn: conn, scope: scope} do
      register_task_schemas!(scope)
      paper_id = uniq("rv-root")
      task_id = uniq("rv-task")
      mk_published_post!(paper_id, scope)

      publish_task_citing!(paper_id, task_id, scope, %{
        "acceptance_criteria" => [
          %{"criterion" => "claim under test", "met" => true, "evidence" => "PR #1"},
          %{"criterion" => "still open", "met" => false}
        ]
      })

      drain_projector!()

      resp = conn |> authed() |> get("/v1/graph/#{paper_id}/tasks")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true
      assert body["root"] == paper_id
      assert body["count"] == 1
      assert body["truncated"] == false

      assert [task] = body["tasks"]
      assert task["doc_id"] == task_id
      assert task["lifecycle_status"] == "open"
      assert "design_doc" in task["via"]
      assert task["criteria_progress"] == %{"met" => 1, "total" => 2}
      assert task["satisfied"] == false

      assert [
               %{"criterion" => "claim under test", "met" => true, "evidence" => "PR #1"},
               %{"criterion" => "still open", "met" => false, "evidence" => nil}
             ] = task["criteria"]
    end

    test "criteria_progress is OMITTED for a criteria-less task (never 0/0)",
         %{conn: conn, scope: scope} do
      register_task_schemas!(scope)
      paper_id = uniq("rv-nocrit-root")
      task_id = uniq("rv-nocrit-task")
      mk_published_post!(paper_id, scope)
      publish_task_citing!(paper_id, task_id, scope, %{})
      drain_projector!()

      resp = conn |> authed() |> get("/v1/graph/#{paper_id}/tasks")
      assert resp.status == 200

      assert [task] = Jason.decode!(resp.resp_body)["tasks"]
      assert task["doc_id"] == task_id
      refute Map.has_key?(task, "criteria_progress")
      assert task["satisfied"] == false
      assert task["criteria"] == []
    end

    test "a root nothing cites returns an empty list", %{conn: conn, scope: scope} do
      doc_id = uniq("rv-lonely")
      mk_published_post!(doc_id, scope)

      resp = conn |> authed() |> get("/v1/graph/#{doc_id}/tasks")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["tasks"] == []
      assert body["count"] == 0
      assert body["truncated"] == false
    end

    test "404s for an unknown root id", %{conn: conn} do
      resp =
        conn
        |> authed()
        |> get("/v1/graph/no-such-doc-#{System.unique_integer([:positive])}/tasks")

      assert resp.status == 404
    end

    test "401 without a token", %{conn: conn} do
      resp = get(conn, "/v1/graph/anything/tasks")
      assert resp.status == 401
    end
  end

  # ── GET /v1/graph — the whole-dataset corpus graph (first-ever coverage) ────
  #
  # stw9-backlog-graph-server-honesty: types= validation, BOTH-ceilings
  # truncation truth (per_type_cap + node_budget), and the post-budget edge
  # filter. Assertions are RELATIONSHIPS (subset/closure/cap arithmetic over
  # seeded docs), never absolute live counts — the corpus drifts daily.
  # Ceilings are config-overridden per test (restored on exit) so an
  # over-budget corpus is a handful of seeded docs, not thousands.

  describe "GET /v1/graph (corpus)" do
    # A schema with a real scalar reference field so corpus edges (and dangling
    # refs → phantom nodes) exist. `refType` deliberately absent: existence
    # resolves type-agnostically, the `post` targets stay resolvable.
    defp register_note_schema!(scope) do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "note",
            "title" => "Note",
            "visibility" => "public",
            "fields" => [%{"name" => "rel", "type" => "reference"}]
          },
          @dataset,
          scope
        )
    end

    # The corpus reads the :published perspective, so fixtures must be
    # published — a bare create only mints the draft twin.
    defp mk_pub_post!(doc_id, scope) do
      mk_post!(doc_id, scope)
      {:ok, doc} = Content.publish_document(doc_id, "post", @dataset, scope)
      doc
    end

    defp mk_note!(doc_id, rel, scope) do
      content = if rel, do: %{"rel" => rel}, else: %{}

      {:ok, _} =
        Content.create_document(
          "note",
          %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
          @dataset,
          scope
        )

      {:ok, doc} = Content.publish_document(doc_id, "note", @dataset, scope)
      doc
    end

    defp override_env!(key, value) do
      previous = Application.fetch_env(:barkpark, key)
      Application.put_env(:barkpark, key, value)

      on_exit(fn ->
        case previous do
          {:ok, v} -> Application.put_env(:barkpark, key, v)
          :error -> Application.delete_env(:barkpark, key)
        end
      end)
    end

    defp corpus!(conn, qs) do
      resp = conn |> authed() |> get("/v1/graph?dataset=#{@dataset}#{qs}")
      assert resp.status == 200
      Jason.decode!(resp.resp_body)
    end

    defp node_ids(body), do: MapSet.new(body["nodes"], & &1["id"])

    # The closure invariant: no edge endpoint may be missing from nodes.
    defp assert_edges_closed!(body) do
      ids = node_ids(body)

      for edge <- body["edges"] do
        assert MapSet.member?(ids, edge["from_id"]),
               "edge from_id #{edge["from_id"]} missing from nodes"

        assert MapSet.member?(ids, edge["to_id"]),
               "edge to_id #{edge["to_id"]} missing from nodes"
      end
    end

    test "401 without a token — the corpus route is token-gated", %{conn: conn} do
      resp = get(conn, "/v1/graph")
      assert resp.status == 401
    end

    test "types= narrows the corpus to the requested schemas", %{conn: conn, scope: scope} do
      register_note_schema!(scope)
      post_id = uniq("corpus-post")
      note_id = uniq("corpus-note")
      mk_pub_post!(post_id, scope)
      mk_note!(note_id, post_id, scope)

      unfiltered = corpus!(conn, "")
      filtered = corpus!(conn, "&types=post")

      # The unfiltered corpus carries both seeded docs…
      assert MapSet.member?(node_ids(unfiltered), post_id)
      assert MapSet.member?(node_ids(unfiltered), note_id)

      # …the filtered one only the requested type: every real node is a post,
      # the note (and its outbound edge) is gone, and the filtered node set is
      # a subset of the unfiltered one.
      assert filtered["ok"] == true
      real_types = filtered["nodes"] |> Enum.reject(& &1["phantom"]) |> Enum.map(& &1["type"])
      assert real_types != []
      assert Enum.all?(real_types, &(&1 == "post"))
      refute MapSet.member?(node_ids(filtered), note_id)
      refute Enum.any?(filtered["edges"], &(&1["from_id"] == note_id))
      assert MapSet.subset?(node_ids(filtered), node_ids(unfiltered))
    end

    test "an unknown type returns 400 rather than being silently ignored", %{conn: conn} do
      resp = conn |> authed() |> get("/v1/graph?dataset=#{@dataset}&types=post,no-such-type")

      assert resp.status == 400
      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == false
      assert body["reason"] == "bad_request"
      assert body["message"] =~ "no-such-type"
    end

    test "small corpus: truncated:false, nil reason, edges closed (incl. the phantom)",
         %{conn: conn, scope: scope} do
      register_note_schema!(scope)
      post_id = uniq("closed-post")
      note_real = uniq("closed-note-real")
      note_dangling = uniq("closed-note-dangling")
      ghost_id = uniq("closed-ghost")
      mk_pub_post!(post_id, scope)
      mk_note!(note_real, post_id, scope)
      mk_note!(note_dangling, ghost_id, scope)

      body = corpus!(conn, "")

      assert body["truncated"] == false
      assert body["truncation_reason"] == nil

      # The dangling ref materialised as a phantom node, and every edge
      # endpoint — real or phantom — is present in nodes.
      ghost = Enum.find(body["nodes"], &(&1["id"] == ghost_id))
      assert ghost["phantom"] == true

      assert Enum.any?(
               body["edges"],
               &(&1["from_id"] == note_dangling and &1["to_id"] == ghost_id)
             )

      assert Enum.any?(body["edges"], &(&1["from_id"] == note_real and &1["to_id"] == post_id))
      assert_edges_closed!(body)
    end

    test "per-type cap fired → truncated:true AND reason per_type_cap (the flag is load-bearing)",
         %{conn: conn, scope: scope} do
      override_env!(:graph_corpus_per_type_limit, 3)
      for _ <- 1..5, do: mk_pub_post!(uniq("cap-post"), scope)

      body = corpus!(conn, "&types=post")

      post_nodes = Enum.filter(body["nodes"], &(&1["type"] == "post"))
      assert length(post_nodes) == 3

      # graph.ts:193 discards the reason unless truncated is true — both must
      # be set together or the truncation is invisible client-side.
      assert body["truncated"] == true
      assert body["truncation_reason"] == "per_type_cap"
    end

    test "a type with EXACTLY cap-many docs is not reported truncated (COUNT confirms the ceiling)",
         %{conn: conn, scope: scope} do
      override_env!(:graph_corpus_per_type_limit, 3)
      for _ <- 1..3, do: mk_pub_post!(uniq("atcap-post"), scope)

      body = corpus!(conn, "&types=post")

      assert length(body["nodes"]) == 3
      assert body["truncated"] == false
      assert body["truncation_reason"] == nil
    end

    test "node budget: edges filtered to the surviving set, phantoms not wholesale-dropped",
         %{conn: conn, scope: scope} do
      register_note_schema!(scope)
      # 4 real notes, each referencing a distinct dangling target → 4 phantoms.
      # Budget 6 keeps all 4 real + 2 phantom nodes.
      for _ <- 1..4, do: mk_note!(uniq("budget-note"), uniq("budget-ghost"), scope)
      override_env!(:graph_corpus_node_budget, 6)

      body = corpus!(conn, "&types=note")

      assert body["truncated"] == true
      assert body["truncation_reason"] == "node_budget"
      assert length(body["nodes"]) == 6

      # Phantoms survive the take (the old code's real++phantom tail-drop kept
      # them only by luck of the budget; the edge filter is what must hold)…
      assert Enum.count(body["nodes"], & &1["phantom"]) == 2
      # …and ONLY edges into surviving phantoms remain — no orphaned edge
      # outlives its dropped node.
      assert length(body["edges"]) == 2
      assert_edges_closed!(body)
    end

    test "both ceilings fired → the reason names both", %{conn: conn, scope: scope} do
      register_note_schema!(scope)
      for _ <- 1..4, do: mk_note!(uniq("both-note"), uniq("both-ghost"), scope)
      override_env!(:graph_corpus_per_type_limit, 2)
      override_env!(:graph_corpus_node_budget, 3)

      body = corpus!(conn, "&types=note")

      assert body["truncated"] == true
      assert body["truncation_reason"] == "per_type_cap+node_budget"
      assert length(body["nodes"]) == 3
      assert_edges_closed!(body)
    end
  end

  # ── /v1/graph corpus: the derivation must not scale queries with documents ──
  #
  # The corpus endpoint used to issue a schema-list query PER DOCUMENT (via
  # extract_edges/2) and read every type's documents TWICE (once for nodes, once
  # inside corpus_edges/3). On the live flagship corpus (4096 docs / 16 types)
  # that was a 34s first paint and a >120s timeout under a concurrent build.
  #
  # This guard is DIFFERENTIAL, so it cannot be satisfied by a fast machine: it
  # measures the SQL the endpoint issues at two corpus sizes and asserts the
  # count barely moves.
  #
  # WHAT IT DOES AND DOES NOT COVER (measured, not assumed). Restoring the
  # per-document schema read reds it: 88 queries at 4 posts -> 110 at 28, +22
  # for +24 documents. Restoring the duplicated per-type document scan does NOT
  # red it — that scan costs ONE query per type, so it is constant in query
  # count however large the corpus grows, and a differential-count guard cannot
  # see it by construction (it doubles rows transferred, not statements issued).
  # The scan fix is covered by the edges/phantom test below, which proves the
  # same graph comes out when the fold is fed already-read documents.
  describe "GET /v1/graph query cost" do
    # LINEAGE-SCOPED, via the shared `Barkpark.QueryCounter`. This file's own
    # copy was the ORIGINAL of the shape (the reader baseline copied it) and
    # was node-global: an unscoped `:telemetry.attach/4` counts statements from
    # the application's background processes too — `async: false` fences
    # sibling TEST processes, not the supervision tree. The differential the
    # guard below measures is small, so one stray sweeper statement inside a
    # measured window moves it. See `Barkpark.QueryCounterTest`.
    defp count_repo_queries(fun) do
      {_, count} = QueryCounter.count(fun)
      count
    end

    test "the corpus derivation does not issue a query per document", %{
      conn: conn,
      scope: scope
    } do
      # Reference-free posts: edges are empty either way, so what this measures
      # is exactly the per-document schema read + the duplicated document scan.
      for _ <- 1..4, do: mk_published_post!(uniq("cost-small"), scope)

      small =
        count_repo_queries(fn ->
          resp = conn |> authed() |> get("/v1/graph")
          assert resp.status == 200
        end)

      for _ <- 1..24, do: mk_published_post!(uniq("cost-large"), scope)

      large =
        count_repo_queries(fn ->
          resp = conn |> authed() |> get("/v1/graph")
          assert resp.status == 200
        end)

      # 24 further documents may cost a few more queries (paging), but NOT one
      # (or two) apiece. Pre-fix this grew by ~24; post-fix it does not grow.
      assert large - small <= 4,
             """
             /v1/graph query count scales with the number of documents:
               #{small} queries at 4 posts -> #{large} at 28 (+#{large - small}).
             The per-document schema read or the duplicated document scan is back.
             """
    end

    test "corpus edges and phantom nodes still resolve after the prefetch", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "linked",
            "title" => "Linked",
            "visibility" => "public",
            "fields" => [%{"name" => "related", "type" => "reference"}]
          },
          @dataset,
          scope
        )

      target = mk_published_post!(uniq("edge-target"), scope)
      missing = uniq("edge-missing")

      src_id = uniq("edge-source")

      {:ok, _} =
        Content.create_document(
          "linked",
          %{"doc_id" => src_id, "title" => "source", "content" => %{"related" => target.doc_id}},
          @dataset,
          scope
        )

      {:ok, _} = Content.publish_document(src_id, "linked", @dataset, scope)

      dangling_id = uniq("edge-dangling")

      {:ok, _} =
        Content.create_document(
          "linked",
          %{"doc_id" => dangling_id, "title" => "dangling", "content" => %{"related" => missing}},
          @dataset,
          scope
        )

      {:ok, _} = Content.publish_document(dangling_id, "linked", @dataset, scope)

      resp = conn |> authed() |> get("/v1/graph")
      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      to_ids = Enum.map(body["edges"], & &1["to_id"])
      assert target.doc_id in to_ids, "the real reference edge disappeared"
      assert missing in to_ids, "the dangling reference edge disappeared"

      phantoms = body["nodes"] |> Enum.filter(& &1["phantom"]) |> Enum.map(& &1["id"])
      assert missing in phantoms, "the referenced-but-absent target lost its phantom node"
    end
  end

  # ── /v1/graph for the PUBLIC-READ tier ────────────────────────────────────
  #
  # Three properties, end-to-end through the REAL router (so the PublicRead
  # mount on `:require_token` is part of what is proven, not assumed):
  #
  #   1. the route is ADMITTED for a public-read token (it used to 403, which
  #      shipped statically-built sites with an empty corpus), and admission does
  #      not 500 on the missing `:type` path segment;
  #   2. its corpus honours schema VISIBILITY per caller — a private type's
  #      titles never reach that tier, while an admin token still sees them;
  #   3. the graph SIBLINGS and every non-graph read stay denied.
  describe "GET /v1/graph — public-read tier" do
    @public_read_token "barkpark-test-graph-public-read"

    setup %{scope: scope} do
      {:ok, _} =
        Auth.create_token(@public_read_token, "test-graph-public-read", @dataset, ["public-read"])

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "weapon", "title" => "Weapon", "visibility" => "private", "fields" => []},
          @dataset,
          scope
        )

      :ok
    end

    defp public_read(conn) do
      conn
      |> put_req_header("authorization", "Bearer " <> @public_read_token)
      |> put_req_header("content-type", "application/json")
    end

    defp titles(body), do: Enum.map(body["nodes"], & &1["title"])

    defp publish!(type, doc_id, title, scope) do
      {:ok, _} =
        Content.create_document(
          type,
          %{"doc_id" => doc_id, "title" => title, "content" => %{}},
          @dataset,
          scope
        )

      {:ok, doc} = Content.publish_document(doc_id, type, @dataset, scope)
      doc
    end

    defp corpus_body!(conn, authfun) do
      resp = conn |> authfun.() |> get("/v1/graph?dataset=#{@dataset}")
      assert resp.status == 200
      Jason.decode!(resp.resp_body)
    end

    test "the route is admitted (200, not 403 and not a 500 on the missing :type segment)",
         %{conn: conn} do
      resp = conn |> public_read() |> get("/v1/graph?dataset=#{@dataset}")

      assert resp.status == 200,
             "public-read got #{resp.status} on /v1/graph: #{resp.resp_body}"

      assert Jason.decode!(resp.resp_body)["ok"] == true
    end

    test "MUTATION PROOF: a published private-type title is absent for public-read, present for admin, and gone from both after delete",
         %{conn: conn, scope: scope} do
      secret_id = uniq("weapon")
      secret_title = "SECRET-#{secret_id}"
      public_id = uniq("open-post")
      public_title = "OPEN-#{public_id}"

      publish!("weapon", secret_id, secret_title, scope)
      publish!("post", public_id, public_title, scope)

      pub = corpus_body!(conn, &public_read/1)
      adm = corpus_body!(conn, &authed/1)

      # The private type is invisible to the public tier — by title AND by node.
      refute secret_title in titles(pub)
      refute MapSet.member?(node_ids(pub), secret_id)
      refute Enum.any?(pub["nodes"], &(&1["type"] == "weapon"))
      # …while the public type it was published alongside still comes through,
      # so this is a visibility filter and not an empty response.
      assert public_title in titles(pub)

      # The admin tier is unchanged: it sees both.
      assert secret_title in titles(adm)
      assert public_title in titles(adm)

      # Delete → the title is gone from BOTH tiers (the corpus is read at read
      # time, never from a cached or hardcoded type list).
      {:ok, _} = Content.delete_document(secret_id, "weapon", @dataset, scope)

      pub_after = corpus_body!(conn, &public_read/1)
      adm_after = corpus_body!(conn, &authed/1)

      refute secret_title in titles(pub_after)
      refute secret_title in titles(adm_after)
      assert Enum.count(pub_after["nodes"], &(&1["title"] == secret_title)) == 0
      assert Enum.count(adm_after["nodes"], &(&1["title"] == secret_title)) == 0
    end

    test "types= cannot re-open a private type for public-read", %{conn: conn, scope: scope} do
      secret_id = uniq("weapon-explicit")
      publish!("weapon", secret_id, "SECRET-#{secret_id}", scope)

      resp = conn |> public_read() |> get("/v1/graph?dataset=#{@dataset}&types=weapon")

      # Unknown-to-this-caller type → the existing 400 contract, never a 200
      # carrying the private corpus.
      assert resp.status == 400
      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == false
      refute body["nodes"]
    end

    test "a schema flipped to public becomes visible on the NEXT read (read-time, not hardcoded)",
         %{conn: conn, scope: scope} do
      doc_id = uniq("weapon-flip")
      title = "FLIP-#{doc_id}"
      publish!("weapon", doc_id, title, scope)

      refute title in titles(corpus_body!(conn, &public_read/1))

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "weapon", "title" => "Weapon", "visibility" => "public", "fields" => []},
          @dataset,
          scope
        )

      assert title in titles(corpus_body!(conn, &public_read/1))
    end

    test "the graph SIBLINGS and non-graph reads stay denied for public-read", %{conn: conn} do
      for path <- [
            "/v1/graph/orphans",
            "/v1/graph/dangling",
            "/v1/graph/some-doc-id",
            "/v1/graph/some-doc-id/tasks",
            "/v1/data/export/#{@dataset}",
            "/v1/data/analytics/#{@dataset}",
            "/v1/data/revision/#{@dataset}/some-doc-id",
            "/v1/data/history/#{@dataset}/post/some-doc-id"
          ] do
        resp = conn |> public_read() |> get(path)

        assert resp.status == 403,
               "#{path} returned #{resp.status} for a public-read token — expected 403"
      end
    end

    test "an admin token is unaffected by the tier filter (every type still visible)",
         %{conn: conn, scope: scope} do
      doc_id = uniq("weapon-admin")
      title = "ADMIN-#{doc_id}"
      publish!("weapon", doc_id, title, scope)

      assert title in titles(corpus_body!(conn, &authed/1))
    end
  end

  # ── the admission cap (the BOX bound, not the payload bound) ──────────────
  #
  # `graph_corpus/2` holds a pool connection for the whole derivation; concurrent
  # site builds exhausted POOL_SIZE=10 and 500-ed unrelated requests. The cap
  # sheds beyond N concurrent derivations rather than queueing on the pool.
  #
  # This test FAILS WITHOUT THE BOUND: with no cap the second request is a plain
  # 200, so the 503 assertion is the bound's tripwire.
  describe "GET /v1/graph admission cap" do
    test "beyond the concurrency cap the request is shed 503 + Retry-After, and recovers on release",
         %{conn: conn, scope: scope} do
      previous = Application.fetch_env(:barkpark, :graph_corpus_max_concurrency)
      Application.put_env(:barkpark, :graph_corpus_max_concurrency, 1)

      on_exit(fn ->
        case previous do
          {:ok, v} -> Application.put_env(:barkpark, :graph_corpus_max_concurrency, v)
          :error -> Application.delete_env(:barkpark, :graph_corpus_max_concurrency)
        end
      end)

      mk_published_post!(uniq("cap-shed"), scope)

      # Hold the single slot from the test process, exactly as an in-flight
      # derivation would.
      {:ok, slot} = BarkparkWeb.TasksController.__acquire_graph_corpus_slot_for_test__()

      shed = conn |> authed() |> get("/v1/graph?dataset=#{@dataset}")
      assert shed.status == 503
      body = Jason.decode!(shed.resp_body)
      assert body["ok"] == false
      assert body["reason"] == "graph_corpus_busy"

      # THE SHED MUST NOT INVITE THE CLIENT BACK MID-DERIVATION. A slot is held
      # for a whole derivation — measured live at 10.18-10.76s each for four
      # concurrent reads on guerrilla — so the `retry-after: 1` this header used
      # to carry told every retrying client to come back while all four slots
      # were still held. search-starter's SSR obeyed it, burned all three
      # attempts inside the first 3.7s, rendered an empty `bp-doc-id` and failed
      # the deploy HEALTH gate. The assertion is a FLOOR, not an equality: the
      # value may be tuned upward, but it may never sink back under a saturated
      # derivation. See `stw10-backlog-flagship-health-pool`.
      [retry_after] = Plug.Conn.get_resp_header(shed, "retry-after")
      assert {seconds, ""} = Integer.parse(retry_after)

      assert seconds >= 11,
             "retry-after is #{seconds}s, which lands inside the ~10.8s a saturated derivation holds its slot"

      # The same number rides the JSON body, so a client that never reads
      # headers (or a proxy that strips them) still gets the truth.
      assert body["retry_after"] == seconds
      assert body["message"] =~ "retry in #{seconds}s"

      # Releasing the slot restores service on the very next request — the cap
      # sheds load, it does not latch the route off.
      BarkparkWeb.TasksController.__release_graph_corpus_slot_for_test__(slot)

      ok = conn |> authed() |> get("/v1/graph?dataset=#{@dataset}")
      assert ok.status == 200
      assert Jason.decode!(ok.resp_body)["ok"] == true
    end

    # THE BOUND MUST OUTLIVE THE REQUESTS IT BOUNDS. An ETS table is owned by
    # the process that created it and dies with it, so a lazily-created slot
    # table would be owned by whichever request arrived first — and would be
    # destroyed the instant that request finished. Under concurrency that is
    # not merely a reset bound: a sibling still holding a slot would raise
    # ArgumentError on insert/delete, turning the guard against 500s into a
    # source of them. The table is therefore created in
    # `Barkpark.Application.start/2`.
    #
    # FAILS WITHOUT THE FIX: with only lazy creation the table's owner here is
    # either the (now dead) task — `:ets.whereis/1` ⇒ `:undefined` — or this
    # very test process, both of which this test rejects.
    test "the slot table outlives the process that used it (owned at boot, not by a request)" do
      table = :barkpark_graph_corpus_slots

      task =
        Task.async(fn ->
          {:ok, slot} = BarkparkWeb.TasksController.__acquire_graph_corpus_slot_for_test__()
          BarkparkWeb.TasksController.__release_graph_corpus_slot_for_test__(slot)
          self()
        end)

      task_pid = Task.await(task)
      refute Process.alive?(task_pid)

      assert :ets.whereis(table) != :undefined,
             "the slot table died with the request process that used it"

      owner = :ets.info(table, :owner)
      assert Process.alive?(owner)
      refute owner == self(), "the slot table is owned by a transient caller, not by the app"
      refute owner == task_pid
    end

    test "under the cap, back-to-back derivations all succeed (no slot leak)", %{
      conn: conn,
      scope: scope
    } do
      mk_published_post!(uniq("cap-noleak"), scope)

      for _ <- 1..5 do
        resp = conn |> authed() |> get("/v1/graph?dataset=#{@dataset}")

        assert resp.status == 200,
               "a slot leaked: a sequential request was shed with #{resp.status}"
      end
    end
  end
end
