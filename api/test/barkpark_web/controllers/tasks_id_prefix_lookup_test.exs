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
      assert indexdef =~ "WHERE (type = 'task'::text)"
    end

    test "the lookup's predicate CAN ride that index (seq scans disabled)" do
      # REACHABILITY, not a today-speedup — the same framing the trgm and
      # ready-queue index migrations use. On a handful of test rows the planner
      # correctly prefers a seq scan; forcing it off proves the predicate is
      # index-ELIGIBLE, which is exactly what `text_pattern_ops` buys and what a
      # DEFAULT-collation btree could not do for `LIKE 'x%'` at all.
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
end
