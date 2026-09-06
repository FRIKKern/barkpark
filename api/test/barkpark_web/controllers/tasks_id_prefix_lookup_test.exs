defmodule BarkparkWeb.TasksIdPrefixLookupTest do
  @moduledoc """
  cchi-bl-task-get-needs-a-server-side-prefix-lookup —
  `GET /v1/tasks?id_prefix=…`, the ONE indexed query that replaces the CLI's
  nine-page client-side scan behind `bp task get <truncated-id>`.

  WHAT THE FILING GOT WRONG, recorded here because a test is where a stale
  premise gets caught: it says the client-side suggestion "can never complete
  inside an honest 404 latency". That was true when it was filed and is not true
  now — PR #14877's follow-up put four pages in flight and the scan completes in
  ~3.2-3.8s on the live ledger. So this route is a PERFORMANCE fix (3.5s and
  nine requests → one request), not the repair of a broken feature.

  Every assertion is scoped to rows this test creates: the test database is
  shared, so a bare count over the route would be someone else's measurement.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}

  @token "barkpark-test-id-prefix-lookup-token"
  @dataset "production"
  @index "documents_task_doc_id_prefix_idx"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-id-prefix", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_task!(doc_id, title, scope) do
    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => title,
          "content" => %{"kind" => "task", "lifecycle_status" => "open"}
        },
        @dataset,
        scope
      )

    doc.doc_id
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer " <> @token)
  defp body(resp), do: Jason.decode!(resp.resp_body)

  defp lookup(conn, prefix) do
    conn |> authed() |> get("/v1/tasks", %{"id_prefix" => prefix}) |> body()
  end

  describe "GET /v1/tasks?id_prefix=" do
    test "a ONE-HIT prefix names the id and carries doc_id + title and nothing else",
         %{conn: conn, scope: scope} do
      stem = uniq("idpfx-one")
      id = mk_task!(stem <> "-full-doc-id", "the only extension", scope)
      _decoy = mk_task!(uniq("idpfx-other"), "a decoy", scope)

      resp = lookup(conn, stem)

      assert resp["ok"] == true
      assert resp["count"] == 1
      assert resp["truncated"] == false
      assert [hit] = resp["matches"]
      assert hit["doc_id"] == id
      assert hit["title"] == "the only extension"

      # The projection is the criterion: doc_id + title ONLY. A row that also
      # carried `content` would be the 10.2 MB page this route exists to avoid.
      assert Map.keys(hit) |> Enum.sort() == ["doc_id", "title"]
    end

    test "a TWO-HIT prefix returns both, so the caller cannot claim uniqueness",
         %{conn: conn, scope: scope} do
      stem = uniq("idpfx-two")
      a = mk_task!(stem <> "-alpha", "alpha", scope)
      b = mk_task!(stem <> "-beta", "beta", scope)
      _decoy = mk_task!(uniq("idpfx-other"), "a decoy", scope)

      resp = lookup(conn, stem)

      assert resp["count"] == 2
      assert resp["matches"] |> Enum.map(& &1["doc_id"]) |> Enum.sort() == Enum.sort([a, b])
    end

    test "a ZERO-HIT prefix is an empty list, not the unfiltered page",
         %{conn: conn, scope: scope} do
      _present = mk_task!(uniq("idpfx-zero-present"), "present", scope)

      resp = lookup(conn, uniq("idpfx-nothing-extends-this"))

      assert resp["ok"] == true
      assert resp["count"] == 0
      assert resp["matches"] == []
    end

    test "the bracket spelling filter[id_prefix] names the same lookup",
         %{conn: conn, scope: scope} do
      stem = uniq("idpfx-bracket")
      id = mk_task!(stem <> "-x", "bracketed", scope)

      resp =
        conn
        |> authed()
        |> get("/v1/tasks", %{"filter" => %{"id_prefix" => stem}})
        |> body()

      assert resp["count"] == 1
      assert [%{"doc_id" => ^id}] = resp["matches"]
    end

    test "a LIKE metacharacter in the prefix is a LITERAL, never a wildcard",
         %{conn: conn, scope: scope} do
      stem = uniq("idpfx-esc")
      _real = mk_task!(stem <> "-real", "real", scope)

      # `%` would match everything under the stem if it reached LIKE unescaped;
      # escaped, it matches a doc_id that literally contains a percent sign —
      # of which there are none.
      resp = lookup(conn, stem <> "%")

      assert resp["count"] == 0
    end

    test "an unpaired drafts. shadow is found by the id the caller would type",
         %{conn: conn, scope: scope} do
      stem = uniq("idpfx-shadow")
      shadow = mk_task!("drafts." <> stem <> "-only", "a mutate-created row", scope)

      resp = lookup(conn, stem)

      assert resp["count"] == 1
      assert [%{"doc_id" => ^shadow}] = resp["matches"]
    end
  end

  describe "the index behind it" do
    test "documents_task_doc_id_prefix_idx exists" do
      %{rows: rows} =
        Repo.query!("SELECT indexdef FROM pg_indexes WHERE indexname = $1", [@index])

      assert [[indexdef]] = rows
      assert indexdef =~ "text_pattern_ops"
      assert indexdef =~ "((type)::text = 'task'::text)"
      assert indexdef =~ "regexp_replace"
    end

    test "the lookup's predicate CAN ride that index (seq scans disabled)" do
      # REACHABILITY, not a today-speedup — the same framing the trgm and
      # ready-queue index migrations use. Forcing seq scans off proves the
      # predicate is index-ELIGIBLE, which is exactly what `text_pattern_ops`
      # buys and what a DEFAULT-collation btree could not do for `LIKE 'x%'`.
      #
      # WHY THIS TEST SEEDS AND ANALYZES (it reddened main once already, at
      # 9fbc403e2, and stayed red for three consecutive Elixir-gate runs):
      # `enable_seqscan = off` does not leave the target index as the only
      # option — it leaves every OTHER index available. On a `documents` table
      # holding a handful of task rows the planner happily takes the broad
      # `documents_type_dataset_index` with a Filter, because at that size the
      # filter is free. The assertion then rests on a planner COST comparison
      # driven by table statistics, and `documents` is the SHARED test table
      # every concurrent test writes into: green on a branch, red on main, with
      # no code change between them.
      #
      # So the test now controls its own statistics. Inside this test's
      # (rolled-back) sandbox transaction it inserts a mass of `type = 'task'`
      # rows whose doc_ids spread across the whole byte range, keeps the probed
      # prefix genuinely selective (3 rows in ~2000), and ANALYZEs so the
      # planner costs the two candidates against THIS distribution rather than
      # against whatever another agent's test left behind. A broad `type`-
      # leading index must now read every task row; the prefix index reads three.
      seed_task_rows!()

      Repo.query!("SET LOCAL enable_seqscan = off")

      plan =
        Repo.query!("""
        EXPLAIN SELECT doc_id, title FROM documents
        WHERE type = 'task'
          AND regexp_replace(doc_id, '^drafts\\.', '') LIKE 'idpfx-plan-%' ESCAPE '\\'
        """)
        |> Map.fetch!(:rows)
        |> Enum.map_join("\n", &hd/1)

      assert plan =~ @index, "expected the prefix index in the plan, got:\n" <> plan
    end
  end

  # ~2000 `type = 'task'` rows, byte-spread doc_ids (md5 hex, so the btree
  # histogram covers the whole key space) plus exactly 3 rows under the probed
  # `idpfx-plan-` stem — a selectivity of ~0.15%, low enough that reading the
  # prefix index beats reading every task row through a type-leading index.
  # Raw SQL, not `Content.create_document/4`: this is fixture MASS, it must not
  # pay the write path, and it must skip the GENERATED ALWAYS columns.
  # Everything here dies with the sandbox transaction.
  defp seed_task_rows! do
    Repo.query!("""
    INSERT INTO documents (id, doc_id, type, dataset, title, status, content, rev, inserted_at, updated_at)
    SELECT gen_random_uuid(),
           'idpfxstat-' || md5(i::text) || '-' || i,
           'task', 'production', 'prefix-plan stats seed', 'published', '{}'::jsonb, 'seed-rev',
           now(), now()
      FROM generate_series(1, 2000) AS i
    """)

    Repo.query!("""
    INSERT INTO documents (id, doc_id, type, dataset, title, status, content, rev, inserted_at, updated_at)
    SELECT gen_random_uuid(),
           'idpfx-plan-' || i,
           'task', 'production', 'prefix-plan stats seed (a hit)', 'published', '{}'::jsonb, 'seed-rev',
           now(), now()
      FROM generate_series(1, 3) AS i
    """)

    Repo.query!("ANALYZE documents")
  end
end
