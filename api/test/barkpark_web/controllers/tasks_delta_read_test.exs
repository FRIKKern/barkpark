defmodule BarkparkWeb.TasksDeltaReadTest do
  @moduledoc """
  task-a60d5a14346c43bb — `GET /v1/tasks?updated_since=<iso8601>`, the DELTA READ.

  THE DEFECT. The board's LAUNCH walk had no narrowing that could express "only
  what moved". The per-re-list half was solved client-side (cli lane r19,
  PR #18468: 97 MB → 0.61 MB by diffing against a corpus already in hand), but
  the first walk has no corpus to diff against, so it stayed at ~97 MB. That
  half is not reachable from a client at all — it needs the server to be able
  to answer with the rows that changed.

  THE PROPERTY THESE TESTS PIN, in three parts, because any one alone is
  passable by a broken implementation:

    1. A window over which NOTHING changed returns NO ROW BODIES. (A no-op
       filter fails this.)
    2. A window that covers the whole corpus returns EVERY row. (A filter that
       excludes unconditionally passes (1) and fails this.)
    3. A window that opens mid-history returns EXACTLY the rows touched after
       it. (Both of the above are satisfiable without this one.)

  THE MUTATION THAT REDS THEM. Collapse
  `Barkpark.Tasks.Query.maybe_filter_updated_since/2`'s `%DateTime{}` clause to
  `do: query` — the ONE line that turns the parsed instant into a WHERE clause.
  MEASURED against this file (2026-09-16): 4 of the 10 tests go red — both
  "an unchanged window" arms, "exactly the touched row", and the bracket-spelling
  arm. The four fail-closed parsing tests, the additive-envelope test and the
  "whole corpus" control stay GREEN, which is the point — parsing and the
  envelope are still correct under the mutation, and only the arms that compare
  ROWS can see it.

  A SECOND MUTATION, for the fail-closed half: make
  `Params.parse_updated_since/2` answer `{:ok, nil}` on a bad instant instead of
  `{:error, _}`. MEASURED: exactly the three 400 tests red; the other seven,
  including the four that compare rows, stay green. That is the
  difference between refusing a malformed delta poll and silently answering it
  with the FULL corpus under a 200 — the expensive page the caller believed was
  the cheap one.

  SCOPE NOTE: every test narrows by a per-run random `?label=` before asserting
  on rows. The tenant scope is shared with every other test in this suite, so a
  bare page carries other tests' rows; the label makes "the rows this test
  created" a decidable set without a `Repo.all` over the table.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}

  @token "barkpark-test-tasks-delta-token"
  @dataset "production"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-tasks-delta", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)

    label = "delta-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    %{scope: scope, label: label}
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

  # A RANDOM title (the cursor-test precedent): `create_document` runs a
  # near-duplicate guard over task titles, and a family of `delta-row-1`,
  # `delta-row-2`, … trips it — a seeding failure that would read as a delta bug.
  defp rand_title, do: "t-" <> Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)

  defp mk_task!(doc_id, scope, label) do
    content = %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "labels" => [label],
      "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
    }

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => rand_title(), "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # Re-stamp ONE row's `updated_at` by writing it again. This is what any task
  # mutation does; going through `upsert_document` keeps the test honest about
  # WHICH column the delta reads instead of poking the column directly.
  defp touch!(doc, scope, label) do
    content = %{
      "kind" => "task",
      # lifecycle_status STAYS "open": a document write may not mint a claim
      # (that is the claim primitive's fence), and this test is about
      # `updated_at`, not about lifecycle. The `priority` bump is the mutation.
      "lifecycle_status" => "open",
      "priority" => 2,
      "labels" => [label],
      "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
    }

    {:ok, updated} =
      Content.upsert_document(
        "task",
        %{"doc_id" => doc.doc_id, "title" => doc.title, "content" => content},
        @dataset,
        scope
      )

    updated
  end

  defp authed(conn) do
    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> @token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
  end

  defp get_json(conn, path) do
    resp = conn |> authed() |> get(path)
    {resp.status, Jason.decode!(resp.resp_body)}
  end

  defp ids(body), do: body["docs"] |> Enum.map(& &1["id"]) |> Enum.sort()

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # ── 1. ADDITIVE: a caller that never spells the key reads the old body ───
  describe "additive" do
    test "a bare GET carries no delta block", %{conn: conn, scope: scope, label: label} do
      mk_task!("delta-additive-#{label}", scope, label)

      {200, body} = get_json(conn, "/v1/tasks?label=#{label}")

      refute Map.has_key?(body, "delta")
      assert Map.keys(body) |> Enum.sort() == ["docs", "ok", "page"]
      assert length(body["docs"]) == 1
    end
  end

  # ── 2. THE CRITERION: an unchanged window returns NO ROW BODIES ──────────
  describe "an unchanged window" do
    test "returns zero rows for a watermark taken after the last write",
         %{conn: conn, scope: scope, label: label} do
      for i <- 1..3, do: mk_task!("delta-quiet-#{i}-#{label}", scope, label)

      # Every row in this corpus is now strictly older than this instant.
      watermark = now_iso()

      {200, body} = get_json(conn, "/v1/tasks?label=#{label}&updated_since=#{watermark}")

      assert body["docs"] == []
      assert body["page"]["returned"] == 0
    end

    test "the server's own as_of round-trips to an empty page",
         %{conn: conn, scope: scope, label: label} do
      for i <- 1..3, do: mk_task!("delta-asof-#{i}-#{label}", scope, label)

      # Poll one: take everything, and keep the watermark the SERVER minted.
      {200, first} =
        get_json(conn, "/v1/tasks?label=#{label}&updated_since=1970-01-01T00:00:00Z")

      assert length(first["docs"]) == 3
      as_of = first["delta"]["as_of"]
      assert {:ok, _, _} = DateTime.from_iso8601(as_of)

      # Poll two, over a window in which nothing was written.
      {200, second} = get_json(conn, "/v1/tasks?label=#{label}&updated_since=#{as_of}")

      assert second["docs"] == []
    end
  end

  # ── 3. THE CONTROL: the filter is not simply excluding everything ────────
  describe "a window covering the whole corpus" do
    test "returns every row", %{conn: conn, scope: scope, label: label} do
      created = for i <- 1..3, do: mk_task!("delta-all-#{i}-#{label}", scope, label)
      expected = created |> Enum.map(& &1.id) |> Enum.sort()

      {200, body} =
        get_json(conn, "/v1/tasks?label=#{label}&updated_since=1970-01-01T00:00:00Z")

      assert ids(body) == expected
    end
  end

  # ── 4. THE DELTA ITSELF: exactly the rows touched after the watermark ────
  describe "a window that opens mid-history" do
    test "returns exactly the touched row", %{conn: conn, scope: scope, label: label} do
      [a, _b, _c] =
        for i <- 1..3, do: mk_task!("delta-mid-#{i}-#{label}", scope, label)

      watermark = now_iso()
      touched = touch!(a, scope, label)

      {200, body} = get_json(conn, "/v1/tasks?label=#{label}&updated_since=#{watermark}")

      assert ids(body) == [touched.id]
    end
  end

  # ── 5. THE BRACKET SPELLING names the same narrowing ─────────────────────
  describe "filter[updated_since]" do
    test "narrows identically to the flat key", %{conn: conn, scope: scope, label: label} do
      [a, _b] = for i <- 1..2, do: mk_task!("delta-bracket-#{i}-#{label}", scope, label)

      watermark = now_iso()
      touched = touch!(a, scope, label)

      {200, body} =
        get_json(conn, "/v1/tasks?label=#{label}&filter[updated_since]=#{watermark}")

      assert ids(body) == [touched.id]
      assert body["delta"]["updated_since"] != nil
    end
  end

  # ── 6. FAIL-CLOSED: a malformed instant is a 400, never a full page ──────
  describe "fail-closed parsing" do
    test "a non-timestamp is refused", %{conn: conn, scope: scope, label: label} do
      mk_task!("delta-bad-#{label}", scope, label)

      {400, body} = get_json(conn, "/v1/tasks?label=#{label}&updated_since=yesterday")

      assert body["ok"] == false
      assert body["message"] =~ "updated_since"
      refute Map.has_key?(body, "docs")
    end

    test "a date with no time (and so no zone) is refused",
         %{conn: conn, scope: scope, label: label} do
      mk_task!("delta-dateonly-#{label}", scope, label)

      {400, body} = get_json(conn, "/v1/tasks?label=#{label}&updated_since=2026-09-16")

      assert body["message"] =~ "updated_since"
    end

    test "a naive instant with no zone is refused", %{conn: conn, scope: scope, label: label} do
      mk_task!("delta-naive-#{label}", scope, label)

      {400, body} =
        get_json(conn, "/v1/tasks?label=#{label}&updated_since=2026-09-16T07:45:00")

      assert body["message"] =~ "updated_since"
    end

    test "a blank value is a no-op, not a refusal", %{conn: conn, scope: scope, label: label} do
      mk_task!("delta-blank-#{label}", scope, label)

      {200, body} = get_json(conn, "/v1/tasks?label=#{label}&updated_since=")

      assert length(body["docs"]) == 1
      refute Map.has_key?(body, "delta")
    end
  end
end
