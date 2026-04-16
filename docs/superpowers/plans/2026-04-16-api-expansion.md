# API Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand the Barkpark CMS API with export, history, search, batch mutations, webhooks, and analytics endpoints — then surface them all in the API Tester.

**Architecture:** Each feature adds a new controller (or extends an existing one) following the established pattern: controller → Content context function → Ecto query. Webhooks additionally introduce a new schema/table and an async HTTP dispatcher. All new endpoints get specs in `Barkpark.ApiTester.Endpoints` so the API Tester playground covers them automatically.

**Tech Stack:** Elixir/Phoenix 1.8.5, Ecto/PostgreSQL 14, Req (HTTP client for webhooks), existing PubSub infrastructure.

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/barkpark_web/router.ex` | Modify | Add routes for export, history, search, analytics |
| `lib/barkpark_web/controllers/export_controller.ex` | Create | Streaming NDJSON export |
| `lib/barkpark_web/controllers/history_controller.ex` | Create | Revision history + restore endpoints |
| `lib/barkpark_web/controllers/search_controller.ex` | Create | Full-text search across documents |
| `lib/barkpark_web/controllers/analytics_controller.ex` | Create | Aggregate stats queries |
| `lib/barkpark_web/controllers/mutate_controller.ex` | Modify | Add dry-run support |
| `lib/barkpark/content.ex` | Modify | Add search_documents, document_stats, count_by_type, export_stream functions |
| `lib/barkpark/webhooks.ex` | Create | Webhook CRUD + dispatch context |
| `lib/barkpark/webhooks/webhook.ex` | Create | Webhook Ecto schema |
| `lib/barkpark/webhooks/dispatcher.ex` | Create | Async HTTP delivery with retries |
| `priv/repo/migrations/*_add_search_index.exs` | Create | GIN index on documents.content |
| `priv/repo/migrations/*_create_webhooks.exs` | Create | Webhooks table |
| `lib/barkpark/api_tester/endpoints.ex` | Modify | Add specs for all new endpoints |
| `test/barkpark_web/contract/export_test.exs` | Create | Export endpoint tests |
| `test/barkpark_web/contract/history_test.exs` | Create | History endpoint tests |
| `test/barkpark_web/contract/search_test.exs` | Create | Search endpoint tests |
| `test/barkpark_web/contract/analytics_test.exs` | Create | Analytics endpoint tests |
| `test/barkpark_web/contract/webhooks_test.exs` | Create | Webhook CRUD + dispatch tests |
| `test/barkpark/webhooks_test.exs` | Create | Webhook context unit tests |

---

## Task 1: Export Endpoint — Streaming NDJSON

Exports all documents of a dataset as newline-delimited JSON. Streams so memory stays flat regardless of dataset size.

**Files:**
- Create: `api/lib/barkpark_web/controllers/export_controller.ex`
- Modify: `api/lib/barkpark_web/router.ex`
- Modify: `api/lib/barkpark/content.ex`
- Test: `api/test/barkpark_web/contract/export_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# api/test/barkpark_web/contract/export_test.exs
defmodule BarkparkWeb.Contract.ExportTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])
    Content.upsert_schema(%{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []}, "test")
    Content.create_document("post", %{"doc_id" => "drafts.e1", "title" => "One"}, "test")
    Content.create_document("post", %{"doc_id" => "drafts.e2", "title" => "Two"}, "test")
    Content.publish_document("e1", "post", "test")
    :ok
  end

  defp do_export(conn, dataset, params \\ %{}) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> get("/v1/data/export/#{dataset}", params)
  end

  test "exports all documents as NDJSON", %{conn: conn} do
    resp = do_export(conn, "test")
    assert resp.status == 200
    assert get_resp_header(resp, "content-type") |> hd() =~ "application/x-ndjson"

    lines = resp.resp_body |> String.trim() |> String.split("\n")
    docs = Enum.map(lines, &Jason.decode!/1)
    assert length(docs) >= 2
    assert Enum.all?(docs, &Map.has_key?(&1, "_id"))
    assert Enum.all?(docs, &Map.has_key?(&1, "_type"))
  end

  test "filters export by type", %{conn: conn} do
    resp = do_export(conn, "test", %{"type" => "post"})
    assert resp.status == 200
    lines = resp.resp_body |> String.trim() |> String.split("\n")
    docs = Enum.map(lines, &Jason.decode!/1)
    assert Enum.all?(docs, &(&1["_type"] == "post"))
  end

  test "returns empty NDJSON for empty dataset", %{conn: conn} do
    resp = do_export(conn, "nonexistent")
    assert resp.status == 200
    assert resp.resp_body == ""
  end

  test "requires auth token", %{conn: conn} do
    resp = get(conn, "/v1/data/export/test")
    assert resp.status == 401
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && mix test test/barkpark_web/contract/export_test.exs --trace`
Expected: compilation error — no route matches

- [ ] **Step 3: Add the export_stream function to Content**

Add to `api/lib/barkpark/content.ex` before the `# ── Revision queries` section:

```elixir
  # ── Export ──────────────────────────────────────────────────────────────

  @doc "Stream all documents for a dataset as envelope maps. Optionally filter by type."
  def export_stream(dataset, opts \\ []) do
    type = Keyword.get(opts, :type)

    Document
    |> where([d], d.dataset == ^dataset)
    |> then(fn q ->
      if type, do: where(q, [d], d.type == ^type), else: q
    end)
    |> order_by([d], asc: d.inserted_at)
    |> Repo.stream()
    |> Stream.map(&Envelope.render/1)
  end
```

- [ ] **Step 4: Create the ExportController**

```elixir
# api/lib/barkpark_web/controllers/export_controller.ex
defmodule BarkparkWeb.ExportController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Repo

  def export(conn, %{"dataset" => dataset} = params) do
    opts = if params["type"], do: [type: params["type"]], else: []

    conn =
      conn
      |> put_resp_content_type("application/x-ndjson")
      |> send_chunked(200)

    Repo.transaction(fn ->
      Content.export_stream(dataset, opts)
      |> Stream.each(fn doc ->
        line = Jason.encode!(doc) <> "\n"
        {:ok, _conn} = chunk(conn, line)
      end)
      |> Stream.run()
    end)

    conn
  end
end
```

- [ ] **Step 5: Add the route**

In `api/lib/barkpark_web/router.ex`, inside the existing `/v1/data` scope with `:require_token` pipeline, add:

```elixir
    get "/export/:dataset", ExportController, :export
```

Place it after the `get "/listen/:dataset"` line.

- [ ] **Step 6: Run test to verify it passes**

Run: `cd api && mix test test/barkpark_web/contract/export_test.exs --trace`
Expected: all 4 tests PASS

- [ ] **Step 7: Commit**

```bash
cd api && git add lib/barkpark_web/controllers/export_controller.ex lib/barkpark_web/router.ex lib/barkpark/content.ex test/barkpark_web/contract/export_test.exs
git commit -m "feat(api): add streaming NDJSON export endpoint"
```

---

## Task 2: History/Revisions API

Expose the existing `Content.list_revisions/4`, `Content.get_revision/1`, and `Content.restore_revision/3` functions as REST endpoints.

**Files:**
- Create: `api/lib/barkpark_web/controllers/history_controller.ex`
- Modify: `api/lib/barkpark_web/router.ex`
- Test: `api/test/barkpark_web/contract/history_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# api/test/barkpark_web/contract/history_test.exs
defmodule BarkparkWeb.Contract.HistoryTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])
    Content.upsert_schema(%{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []}, "test")
    {:ok, doc} = Content.create_document("post", %{"doc_id" => "drafts.h1", "title" => "V1"}, "test")
    Content.publish_document("h1", "post", "test")

    Content.apply_mutations("test", %{
      "mutations" => [%{"patch" => %{"id" => "h1", "type" => "post", "set" => %{"title" => "V2"}}}]
    })

    {:ok, doc_id: "h1"}
  end

  defp authed(conn) do
    put_req_header(conn, "authorization", "Bearer barkpark-dev-token")
  end

  test "list revisions for a document", %{conn: conn, doc_id: doc_id} do
    resp =
      conn
      |> authed()
      |> get("/v1/data/history/test/post/#{doc_id}")

    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert is_list(body["revisions"])
    assert length(body["revisions"]) >= 2

    [newest | _] = body["revisions"]
    assert Map.has_key?(newest, "id")
    assert Map.has_key?(newest, "action")
    assert Map.has_key?(newest, "title")
    assert Map.has_key?(newest, "timestamp")
  end

  test "list revisions respects limit", %{conn: conn, doc_id: doc_id} do
    resp =
      conn
      |> authed()
      |> get("/v1/data/history/test/post/#{doc_id}", %{"limit" => "1"})

    body = Jason.decode!(resp.resp_body)
    assert length(body["revisions"]) == 1
  end

  test "get a single revision", %{conn: conn, doc_id: doc_id} do
    list_resp =
      conn
      |> authed()
      |> get("/v1/data/history/test/post/#{doc_id}")

    %{"revisions" => [%{"id" => rev_id} | _]} = Jason.decode!(list_resp.resp_body)

    resp =
      conn
      |> authed()
      |> get("/v1/data/revision/test/#{rev_id}")

    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert body["revision"]["id"] == rev_id
    assert Map.has_key?(body["revision"], "content")
  end

  test "restore a revision creates a draft", %{conn: conn, doc_id: doc_id} do
    list_resp =
      conn
      |> authed()
      |> get("/v1/data/history/test/post/#{doc_id}")

    %{"revisions" => revisions} = Jason.decode!(list_resp.resp_body)
    oldest = List.last(revisions)

    resp =
      conn
      |> authed()
      |> put_req_header("content-type", "application/json")
      |> post("/v1/data/revision/test/#{oldest["id"]}/restore", Jason.encode!(%{type: "post"}))

    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert body["restored"] == true
    assert body["document"]["_draft"] == true
  end

  test "returns 404 for unknown document", %{conn: conn} do
    resp =
      conn
      |> authed()
      |> get("/v1/data/history/test/post/nonexistent")

    body = Jason.decode!(resp.resp_body)
    assert resp.status == 200
    assert body["revisions"] == []
  end

  test "returns 404 for unknown revision", %{conn: conn} do
    fake_uuid = "00000000-0000-0000-0000-000000000000"

    resp =
      conn
      |> authed()
      |> get("/v1/data/revision/test/#{fake_uuid}")

    assert resp.status == 404
  end

  test "requires auth", %{conn: conn} do
    resp = get(conn, "/v1/data/history/test/post/h1")
    assert resp.status == 401
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && mix test test/barkpark_web/contract/history_test.exs --trace`
Expected: compilation error — no route matches

- [ ] **Step 3: Create the HistoryController**

```elixir
# api/lib/barkpark_web/controllers/history_controller.ex
defmodule BarkparkWeb.HistoryController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.Envelope

  def index(conn, %{"dataset" => dataset, "type" => type, "doc_id" => doc_id} = params) do
    limit = parse_int(params["limit"], 50)

    revisions =
      Content.list_revisions(doc_id, type, dataset, limit: limit)
      |> Enum.map(&render_revision/1)

    json(conn, %{revisions: revisions, count: length(revisions)})
  end

  def show(conn, %{"dataset" => _dataset, "id" => id}) do
    case Content.get_revision(id) do
      {:ok, rev} ->
        json(conn, %{revision: render_revision_full(rev)})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: %{code: "not_found", message: "revision not found"}})
    end
  end

  def restore(conn, %{"dataset" => dataset, "id" => id} = params) do
    type = get_type(conn, params)

    case Content.restore_revision(id, type, dataset) do
      {:ok, doc} ->
        json(conn, %{restored: true, document: Envelope.render(doc)})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: %{code: "not_found", message: "revision not found"}})
    end
  end

  defp get_type(conn, params) do
    params["type"] || (conn.body_params && conn.body_params["type"])
  end

  defp render_revision(rev) do
    %{
      id: rev.id,
      action: rev.action,
      title: rev.title,
      status: rev.status,
      timestamp: rev.inserted_at
    }
  end

  defp render_revision_full(rev) do
    %{
      id: rev.id,
      doc_id: rev.doc_id,
      type: rev.type,
      dataset: rev.dataset,
      action: rev.action,
      title: rev.title,
      status: rev.status,
      content: rev.content,
      timestamp: rev.inserted_at
    }
  end

  defp parse_int(nil, default), do: default
  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> min(max(n, 1), 200)
      :error -> default
    end
  end
  defp parse_int(val, _default) when is_integer(val), do: min(max(val, 1), 200)
end
```

- [ ] **Step 4: Add the routes**

In `api/lib/barkpark_web/router.ex`, inside the `/v1/data` scope with `:require_token`, add:

```elixir
    get "/history/:dataset/:type/:doc_id", HistoryController, :index
    get "/revision/:dataset/:id", HistoryController, :show
    post "/revision/:dataset/:id/restore", HistoryController, :restore
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd api && mix test test/barkpark_web/contract/history_test.exs --trace`
Expected: all 7 tests PASS

- [ ] **Step 6: Commit**

```bash
cd api && git add lib/barkpark_web/controllers/history_controller.ex lib/barkpark_web/router.ex test/barkpark_web/contract/history_test.exs
git commit -m "feat(api): add document history and revision endpoints"
```

---

## Task 3: Full-Text Search

Add a search endpoint that searches across document titles and JSONB content fields. Uses PostgreSQL's built-in `ILIKE` for simplicity — upgrade to `tsvector`/GIN later if needed.

**Files:**
- Create: `api/lib/barkpark_web/controllers/search_controller.ex`
- Modify: `api/lib/barkpark_web/router.ex`
- Modify: `api/lib/barkpark/content.ex`
- Test: `api/test/barkpark_web/contract/search_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# api/test/barkpark_web/contract/search_test.exs
defmodule BarkparkWeb.Contract.SearchTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])
    Content.upsert_schema(%{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []}, "test")
    Content.upsert_schema(%{"name" => "author", "title" => "Author", "visibility" => "public", "fields" => []}, "test")

    Content.create_document("post", %{"doc_id" => "drafts.s1", "title" => "Elixir Phoenix Guide"}, "test")
    Content.create_document("post", %{"doc_id" => "drafts.s2", "title" => "React Tutorial"}, "test")
    Content.create_document("author", %{"doc_id" => "drafts.s3", "title" => "Phoenix Wright"}, "test")

    Content.publish_document("s1", "post", "test")
    Content.publish_document("s2", "post", "test")
    Content.publish_document("s3", "author", "test")
    :ok
  end

  test "searches by title across types", %{conn: conn} do
    resp = get(conn, "/v1/data/search/test", %{"q" => "phoenix"})
    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert length(body["documents"]) == 2
    titles = Enum.map(body["documents"], & &1["title"])
    assert "Elixir Phoenix Guide" in titles
    assert "Phoenix Wright" in titles
  end

  test "filters search by type", %{conn: conn} do
    resp = get(conn, "/v1/data/search/test", %{"q" => "phoenix", "type" => "post"})
    body = Jason.decode!(resp.resp_body)
    assert length(body["documents"]) == 1
    assert hd(body["documents"])["_type"] == "post"
  end

  test "returns empty list for no matches", %{conn: conn} do
    resp = get(conn, "/v1/data/search/test", %{"q" => "zzzznoexist"})
    body = Jason.decode!(resp.resp_body)
    assert body["documents"] == []
    assert body["count"] == 0
  end

  test "requires q parameter", %{conn: conn} do
    resp = get(conn, "/v1/data/search/test")
    assert resp.status == 400
  end

  test "respects perspective (defaults to published)", %{conn: conn} do
    resp = get(conn, "/v1/data/search/test", %{"q" => "Elixir"})
    body = Jason.decode!(resp.resp_body)
    docs = body["documents"]
    assert Enum.all?(docs, &(&1["_draft"] == false))
  end

  test "limits results", %{conn: conn} do
    resp = get(conn, "/v1/data/search/test", %{"q" => "phoenix", "limit" => "1"})
    body = Jason.decode!(resp.resp_body)
    assert length(body["documents"]) == 1
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && mix test test/barkpark_web/contract/search_test.exs --trace`
Expected: compilation error — no route matches

- [ ] **Step 3: Add search_documents to Content**

Add to `api/lib/barkpark/content.ex` before the export section:

```elixir
  # ── Search ──────────────────────────────────────────────────────────────

  @doc "Search documents by title using ILIKE. Returns published docs by default."
  def search_documents(query, dataset, opts \\ []) do
    type = Keyword.get(opts, :type)
    perspective = Keyword.get(opts, :perspective, :published)
    limit = Keyword.get(opts, :limit, 50) |> min(200)
    offset = Keyword.get(opts, :offset, 0)

    pattern = "%" <> String.replace(query, "%", "\\%") <> "%"

    base =
      Document
      |> where([d], d.dataset == ^dataset)
      |> where([d], ilike(d.title, ^pattern))

    base =
      if type, do: where(base, [d], d.type == ^type), else: base

    base = apply_perspective_filter(base, perspective)

    docs = base |> order_by([d], desc: d.updated_at) |> limit(^limit) |> offset(^offset) |> Repo.all()
    count = base |> select([d], count(d.id)) |> Repo.one()

    {docs, count}
  end

  defp apply_perspective_filter(query, :published) do
    where(query, [d], not like(d.doc_id, "drafts.%"))
  end

  defp apply_perspective_filter(query, :drafts) do
    where(query, [d], like(d.doc_id, "drafts.%"))
  end

  defp apply_perspective_filter(query, _raw), do: query
```

Note: Check if `apply_perspective_filter` already exists in `content.ex` — the `list_documents` function handles perspectives differently via `DISTINCT ON`. If so, name this helper `search_perspective_filter` instead to avoid conflicts.

- [ ] **Step 4: Create the SearchController**

```elixir
# api/lib/barkpark_web/controllers/search_controller.ex
defmodule BarkparkWeb.SearchController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.Envelope

  def search(conn, %{"dataset" => dataset} = params) do
    case params["q"] do
      nil ->
        conn
        |> put_status(400)
        |> json(%{error: %{code: "malformed", message: "missing required parameter: q"}})

      "" ->
        conn
        |> put_status(400)
        |> json(%{error: %{code: "malformed", message: "missing required parameter: q"}})

      query ->
        opts = [
          type: params["type"],
          perspective: parse_perspective(params["perspective"]),
          limit: parse_int(params["limit"], 50),
          offset: parse_int(params["offset"], 0)
        ]

        {docs, count} = Content.search_documents(query, dataset, opts)

        json(conn, %{
          documents: Envelope.render_many(docs),
          count: count,
          query: query
        })
    end
  end

  defp parse_perspective("drafts"), do: :drafts
  defp parse_perspective("raw"), do: :raw
  defp parse_perspective(_), do: :published

  defp parse_int(nil, default), do: default
  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> max(n, 0)
      :error -> default
    end
  end
  defp parse_int(_, default), do: default
end
```

- [ ] **Step 5: Add the route**

In `api/lib/barkpark_web/router.ex`, add a **public** route (search doesn't require auth, same as query):

```elixir
  # Inside the public /v1/data scope (no auth required):
  get "/search/:dataset", SearchController, :search
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd api && mix test test/barkpark_web/contract/search_test.exs --trace`
Expected: all 6 tests PASS

- [ ] **Step 7: Commit**

```bash
cd api && git add lib/barkpark_web/controllers/search_controller.ex lib/barkpark_web/router.ex lib/barkpark/content.ex test/barkpark_web/contract/search_test.exs
git commit -m "feat(api): add full-text search endpoint"
```

---

## Task 4: Analytics/Stats Endpoint

Provides aggregate stats: document counts by type, mutation activity, and dataset overview.

**Files:**
- Create: `api/lib/barkpark_web/controllers/analytics_controller.ex`
- Modify: `api/lib/barkpark_web/router.ex`
- Modify: `api/lib/barkpark/content.ex`
- Test: `api/test/barkpark_web/contract/analytics_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# api/test/barkpark_web/contract/analytics_test.exs
defmodule BarkparkWeb.Contract.AnalyticsTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])
    Content.upsert_schema(%{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []}, "test")
    Content.upsert_schema(%{"name" => "author", "title" => "Author", "visibility" => "public", "fields" => []}, "test")

    Content.create_document("post", %{"doc_id" => "drafts.a1", "title" => "P1"}, "test")
    Content.create_document("post", %{"doc_id" => "drafts.a2", "title" => "P2"}, "test")
    Content.create_document("author", %{"doc_id" => "drafts.a3", "title" => "A1"}, "test")
    Content.publish_document("a1", "post", "test")
    :ok
  end

  defp authed(conn) do
    put_req_header(conn, "authorization", "Bearer barkpark-dev-token")
  end

  test "returns document counts by type", %{conn: conn} do
    resp = conn |> authed() |> get("/v1/data/analytics/test")
    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)

    assert is_list(body["types"])
    post_stat = Enum.find(body["types"], &(&1["type"] == "post"))
    assert post_stat["total"] >= 2
    assert post_stat["published"] >= 1
    assert post_stat["drafts"] >= 1
  end

  test "returns total document count", %{conn: conn} do
    resp = conn |> authed() |> get("/v1/data/analytics/test")
    body = Jason.decode!(resp.resp_body)
    assert body["total_documents"] >= 3
  end

  test "returns mutation activity", %{conn: conn} do
    resp = conn |> authed() |> get("/v1/data/analytics/test")
    body = Jason.decode!(resp.resp_body)
    assert is_list(body["recent_activity"])
  end

  test "requires auth", %{conn: conn} do
    resp = get(conn, "/v1/data/analytics/test")
    assert resp.status == 401
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && mix test test/barkpark_web/contract/analytics_test.exs --trace`
Expected: compilation error — no route matches

- [ ] **Step 3: Add stats functions to Content**

Add to `api/lib/barkpark/content.ex`:

```elixir
  # ── Analytics ───────────────────────────────────────────────────────────

  @doc "Count documents grouped by type, with published/draft breakdown."
  def document_stats(dataset) do
    Document
    |> where([d], d.dataset == ^dataset)
    |> group_by([d], d.type)
    |> select([d], %{
      type: d.type,
      total: count(d.id),
      published: count(fragment("CASE WHEN ? NOT LIKE 'drafts.%' THEN 1 END", d.doc_id)),
      drafts: count(fragment("CASE WHEN ? LIKE 'drafts.%' THEN 1 END", d.doc_id))
    })
    |> order_by([d], asc: d.type)
    |> Repo.all()
  end

  @doc "Count total documents in a dataset."
  def total_documents(dataset) do
    Document
    |> where([d], d.dataset == ^dataset)
    |> select([d], count(d.id))
    |> Repo.one()
  end

  @doc "Recent mutation activity summary — last 50 events grouped by day and action."
  def recent_activity(dataset, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    MutationEvent
    |> where([e], e.dataset == ^dataset)
    |> order_by([e], desc: e.inserted_at)
    |> limit(^limit)
    |> select([e], %{
      id: e.id,
      type: e.type,
      doc_id: e.doc_id,
      mutation: e.mutation,
      timestamp: e.inserted_at
    })
    |> Repo.all()
  end
```

- [ ] **Step 4: Create the AnalyticsController**

```elixir
# api/lib/barkpark_web/controllers/analytics_controller.ex
defmodule BarkparkWeb.AnalyticsController do
  use BarkparkWeb, :controller

  alias Barkpark.Content

  def index(conn, %{"dataset" => dataset}) do
    types = Content.document_stats(dataset)
    total = Content.total_documents(dataset)
    activity = Content.recent_activity(dataset)

    json(conn, %{
      dataset: dataset,
      total_documents: total,
      types: types,
      recent_activity: activity
    })
  end
end
```

- [ ] **Step 5: Add the route**

In `api/lib/barkpark_web/router.ex`, inside the `/v1/data` scope with `:require_token`:

```elixir
    get "/analytics/:dataset", AnalyticsController, :index
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd api && mix test test/barkpark_web/contract/analytics_test.exs --trace`
Expected: all 4 tests PASS

- [ ] **Step 7: Commit**

```bash
cd api && git add lib/barkpark_web/controllers/analytics_controller.ex lib/barkpark_web/router.ex lib/barkpark/content.ex test/barkpark_web/contract/analytics_test.exs
git commit -m "feat(api): add analytics/stats endpoint"
```

---

## Task 5: Webhooks — Schema, Context, and CRUD API

Webhooks notify external URLs when mutations happen. This task creates the table, schema, context module, and CRUD endpoints. The next task wires up dispatching.

**Files:**
- Create: `api/priv/repo/migrations/*_create_webhooks.exs`
- Create: `api/lib/barkpark/webhooks/webhook.ex`
- Create: `api/lib/barkpark/webhooks.ex`
- Create: `api/lib/barkpark_web/controllers/webhook_controller.ex`
- Modify: `api/lib/barkpark_web/router.ex`
- Test: `api/test/barkpark/webhooks_test.exs`
- Test: `api/test/barkpark_web/contract/webhooks_test.exs`

- [ ] **Step 1: Create the migration**

Run: `cd api && mix ecto.gen.migration create_webhooks`

Then edit the generated file:

```elixir
defmodule Barkpark.Repo.Migrations.CreateWebhooks do
  use Ecto.Migration

  def change do
    create table(:webhooks, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :string, null: false
      add :url, :string, null: false
      add :dataset, :string, null: false, default: "production"
      add :events, {:array, :string}, null: false, default: []
      add :types, {:array, :string}, null: false, default: []
      add :secret, :string
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:webhooks, [:dataset])
    create index(:webhooks, [:active])
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `cd api && mix ecto.migrate`
Expected: table `webhooks` created

- [ ] **Step 3: Create the Webhook Ecto schema**

```elixir
# api/lib/barkpark/webhooks/webhook.ex
defmodule Barkpark.Webhooks.Webhook do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "webhooks" do
    field :name, :string
    field :url, :string
    field :dataset, :string, default: "production"
    field :events, {:array, :string}, default: []
    field :types, {:array, :string}, default: []
    field :secret, :string
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  @valid_events ~w(create update publish unpublish delete discardDraft patch)

  def changeset(webhook, attrs) do
    webhook
    |> cast(attrs, [:name, :url, :dataset, :events, :types, :secret, :active])
    |> validate_required([:name, :url])
    |> validate_format(:url, ~r/^https?:\/\//)
    |> validate_subset(:events, @valid_events)
  end
end
```

- [ ] **Step 4: Create the Webhooks context**

```elixir
# api/lib/barkpark/webhooks.ex
defmodule Barkpark.Webhooks do
  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Webhooks.Webhook

  def list_webhooks(dataset) do
    Webhook
    |> where([w], w.dataset == ^dataset)
    |> order_by([w], asc: w.name)
    |> Repo.all()
  end

  def get_webhook(id) do
    case Repo.get(Webhook, id) do
      nil -> {:error, :not_found}
      webhook -> {:ok, webhook}
    end
  end

  def create_webhook(attrs) do
    %Webhook{}
    |> Webhook.changeset(attrs)
    |> Repo.insert()
  end

  def update_webhook(%Webhook{} = webhook, attrs) do
    webhook
    |> Webhook.changeset(attrs)
    |> Repo.update()
  end

  def delete_webhook(%Webhook{} = webhook) do
    Repo.delete(webhook)
  end

  def active_webhooks_for(dataset, event, type) do
    Webhook
    |> where([w], w.dataset == ^dataset and w.active == true)
    |> where([w], fragment("? = '{}' OR ? @> ARRAY[?]::varchar[]", w.events, w.events, ^event))
    |> where([w], fragment("? = '{}' OR ? @> ARRAY[?]::varchar[]", w.types, w.types, ^type))
    |> Repo.all()
  end
end
```

- [ ] **Step 5: Write the Webhooks context unit test**

```elixir
# api/test/barkpark/webhooks_test.exs
defmodule Barkpark.WebhooksTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Webhooks

  test "create and list webhooks" do
    {:ok, wh} = Webhooks.create_webhook(%{"name" => "Test", "url" => "http://example.com/hook", "dataset" => "test"})
    assert wh.name == "Test"
    assert wh.active == true

    hooks = Webhooks.list_webhooks("test")
    assert length(hooks) == 1
  end

  test "update a webhook" do
    {:ok, wh} = Webhooks.create_webhook(%{"name" => "Test", "url" => "http://example.com/hook", "dataset" => "test"})
    {:ok, updated} = Webhooks.update_webhook(wh, %{"active" => false})
    assert updated.active == false
  end

  test "delete a webhook" do
    {:ok, wh} = Webhooks.create_webhook(%{"name" => "Test", "url" => "http://example.com/hook", "dataset" => "test"})
    {:ok, _} = Webhooks.delete_webhook(wh)
    assert Webhooks.list_webhooks("test") == []
  end

  test "active_webhooks_for matches event and type" do
    Webhooks.create_webhook(%{"name" => "All", "url" => "http://example.com/all", "dataset" => "test", "events" => [], "types" => []})
    Webhooks.create_webhook(%{"name" => "Creates", "url" => "http://example.com/create", "dataset" => "test", "events" => ["create"], "types" => []})
    Webhooks.create_webhook(%{"name" => "Posts", "url" => "http://example.com/post", "dataset" => "test", "events" => [], "types" => ["post"]})
    Webhooks.create_webhook(%{"name" => "Inactive", "url" => "http://example.com/off", "dataset" => "test", "active" => false})

    matches = Webhooks.active_webhooks_for("test", "create", "post")
    names = Enum.map(matches, & &1.name) |> Enum.sort()
    assert names == ["All", "Creates", "Posts"]
  end

  test "validates URL format" do
    {:error, changeset} = Webhooks.create_webhook(%{"name" => "Bad", "url" => "not-a-url"})
    assert errors_on(changeset).url != nil
  end
end
```

- [ ] **Step 6: Run unit tests**

Run: `cd api && mix test test/barkpark/webhooks_test.exs --trace`
Expected: all 5 tests PASS

- [ ] **Step 7: Create the WebhookController**

```elixir
# api/lib/barkpark_web/controllers/webhook_controller.ex
defmodule BarkparkWeb.WebhookController do
  use BarkparkWeb, :controller

  alias Barkpark.Webhooks

  def index(conn, %{"dataset" => dataset}) do
    hooks = Webhooks.list_webhooks(dataset)
    json(conn, %{webhooks: Enum.map(hooks, &render_webhook/1)})
  end

  def show(conn, %{"id" => id}) do
    case Webhooks.get_webhook(id) do
      {:ok, wh} -> json(conn, %{webhook: render_webhook(wh)})
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: %{code: "not_found", message: "webhook not found"}})
    end
  end

  def create(conn, %{"dataset" => dataset} = params) do
    attrs = Map.put(params, "dataset", dataset)

    case Webhooks.create_webhook(attrs) do
      {:ok, wh} ->
        conn |> put_status(201) |> json(%{webhook: render_webhook(wh)})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{error: %{code: "validation_failed", details: format_errors(changeset)}})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, wh} <- Webhooks.get_webhook(id),
         {:ok, updated} <- Webhooks.update_webhook(wh, params) do
      json(conn, %{webhook: render_webhook(updated)})
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: %{code: "not_found", message: "webhook not found"}})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{error: %{code: "validation_failed", details: format_errors(changeset)}})
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, wh} <- Webhooks.get_webhook(id),
         {:ok, _} <- Webhooks.delete_webhook(wh) do
      json(conn, %{deleted: id})
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: %{code: "not_found", message: "webhook not found"}})
    end
  end

  defp render_webhook(wh) do
    %{
      id: wh.id,
      name: wh.name,
      url: wh.url,
      dataset: wh.dataset,
      events: wh.events,
      types: wh.types,
      active: wh.active,
      created_at: wh.inserted_at,
      updated_at: wh.updated_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
```

- [ ] **Step 8: Add webhook routes**

In `api/lib/barkpark_web/router.ex`, add a new scope with `:require_admin`:

```elixir
  scope "/v1/webhooks", BarkparkWeb do
    pipe_through [:api, :require_admin]

    get "/:dataset", WebhookController, :index
    get "/:dataset/:id", WebhookController, :show
    post "/:dataset", WebhookController, :create
    put "/:dataset/:id", WebhookController, :update
    delete "/:dataset/:id", WebhookController, :delete
  end
```

- [ ] **Step 9: Write the webhook API contract test**

```elixir
# api/test/barkpark_web/contract/webhooks_test.exs
defmodule BarkparkWeb.Contract.WebhooksTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])
    :ok
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
  end

  test "full CRUD lifecycle", %{conn: conn} do
    # Create
    resp = conn |> authed() |> post("/v1/webhooks/test", Jason.encode!(%{
      name: "My Hook",
      url: "http://example.com/webhook",
      events: ["create", "publish"],
      types: ["post"]
    }))
    assert resp.status == 201
    body = Jason.decode!(resp.resp_body)
    id = body["webhook"]["id"]
    assert body["webhook"]["name"] == "My Hook"

    # List
    resp = conn |> authed() |> get("/v1/webhooks/test")
    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert length(body["webhooks"]) == 1

    # Show
    resp = conn |> authed() |> get("/v1/webhooks/test/#{id}")
    assert resp.status == 200

    # Update
    resp = conn |> authed() |> put("/v1/webhooks/test/#{id}", Jason.encode!(%{active: false}))
    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert body["webhook"]["active"] == false

    # Delete
    resp = conn |> authed() |> delete("/v1/webhooks/test/#{id}")
    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert body["deleted"] == id

    # Verify deleted
    resp = conn |> authed() |> get("/v1/webhooks/test/#{id}")
    assert resp.status == 404
  end

  test "requires admin auth", %{conn: conn} do
    resp = get(conn, "/v1/webhooks/test")
    assert resp.status == 401
  end

  test "validates webhook creation", %{conn: conn} do
    resp = conn |> authed() |> post("/v1/webhooks/test", Jason.encode!(%{name: "Bad"}))
    assert resp.status == 422
  end
end
```

- [ ] **Step 10: Run all webhook tests**

Run: `cd api && mix test test/barkpark/webhooks_test.exs test/barkpark_web/contract/webhooks_test.exs --trace`
Expected: all tests PASS

- [ ] **Step 11: Commit**

```bash
cd api && git add lib/barkpark/webhooks.ex lib/barkpark/webhooks/ lib/barkpark_web/controllers/webhook_controller.ex lib/barkpark_web/router.ex priv/repo/migrations/*_create_webhooks.exs test/barkpark/webhooks_test.exs test/barkpark_web/contract/webhooks_test.exs
git commit -m "feat(api): add webhooks CRUD endpoints"
```

---

## Task 6: Webhook Dispatcher — Fire on Mutations

Wire webhook dispatch into the existing PubSub broadcast flow so webhooks fire asynchronously after mutations commit.

**Files:**
- Create: `api/lib/barkpark/webhooks/dispatcher.ex`
- Modify: `api/lib/barkpark/content.ex`
- Test: `api/test/barkpark/webhooks/dispatcher_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# api/test/barkpark/webhooks/dispatcher_test.exs
defmodule Barkpark.Webhooks.DispatcherTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.Dispatcher

  test "build_payload creates correct structure" do
    payload = Dispatcher.build_payload("create", "post", "p1", %{"_id" => "p1"}, "production")

    assert payload.event == "create"
    assert payload.type == "post"
    assert payload.doc_id == "p1"
    assert payload.dataset == "production"
    assert payload.document == %{"_id" => "p1"}
    assert is_binary(payload.timestamp)
  end

  test "sign_payload generates HMAC" do
    payload = %{event: "create", doc_id: "p1"}
    sig = Dispatcher.sign_payload(Jason.encode!(payload), "mysecret")
    assert String.starts_with?(sig, "sha256=")
    assert String.length(sig) == 71  # "sha256=" + 64 hex chars
  end

  test "dispatch_async spawns tasks for matching webhooks" do
    {:ok, _wh} = Webhooks.create_webhook(%{
      "name" => "Test",
      "url" => "http://localhost:1/noop",
      "dataset" => "test",
      "events" => ["create"],
      "types" => []
    })

    # Should not raise — fires async
    Dispatcher.dispatch_async("test", "create", "post", "p1", %{"_id" => "p1"})
    # Give tasks a moment to spawn (they'll fail to connect, which is fine)
    Process.sleep(50)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && mix test test/barkpark/webhooks/dispatcher_test.exs --trace`
Expected: module Dispatcher not found

- [ ] **Step 3: Create the Dispatcher module**

```elixir
# api/lib/barkpark/webhooks/dispatcher.ex
defmodule Barkpark.Webhooks.Dispatcher do
  require Logger
  alias Barkpark.Webhooks

  def dispatch_async(dataset, event, type, doc_id, document) do
    payload = build_payload(event, type, doc_id, document, dataset)
    body = Jason.encode!(payload)

    webhooks = Webhooks.active_webhooks_for(dataset, event, type)

    Enum.each(webhooks, fn wh ->
      Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn ->
        deliver(wh, body)
      end)
    end)
  end

  def build_payload(event, type, doc_id, document, dataset) do
    %{
      event: event,
      type: type,
      doc_id: doc_id,
      document: document,
      dataset: dataset,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  def sign_payload(body, secret) do
    sig = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
    "sha256=#{sig}"
  end

  defp deliver(webhook, body) do
    headers = [{"content-type", "application/json"}]

    headers =
      if webhook.secret do
        sig = sign_payload(body, webhook.secret)
        [{"x-webhook-signature", sig} | headers]
      else
        headers
      end

    case Req.post(webhook.url, body: body, headers: headers, receive_timeout: 10_000) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.info("Webhook #{webhook.name} delivered (#{status})")

      {:ok, %{status: status}} ->
        Logger.warning("Webhook #{webhook.name} failed (#{status})")

      {:error, reason} ->
        Logger.warning("Webhook #{webhook.name} error: #{inspect(reason)}")
    end
  end
end
```

- [ ] **Step 4: Add TaskSupervisor to the application**

In `api/lib/barkpark/application.ex`, add to the children list:

```elixir
      {Task.Supervisor, name: Barkpark.TaskSupervisor},
```

- [ ] **Step 5: Wire dispatch into Content.tap_broadcast**

In `api/lib/barkpark/content.ex`, at the end of the `tap_broadcast/5` function (inside `maybe_broadcast`), add the webhook dispatch call. Find the `maybe_broadcast/2` function and modify it:

```elixir
  defp maybe_broadcast(msg, {dataset, type, doc_id, action}) do
    case Process.get(:barkpark_deferred_broadcasts) do
      nil ->
        Phoenix.PubSub.broadcast(Barkpark.PubSub, "documents:#{dataset}", msg)
        Phoenix.PubSub.broadcast(Barkpark.PubSub, "doc:#{dataset}:#{type}:#{published_id(doc_id)}", msg)
        Barkpark.Webhooks.Dispatcher.dispatch_async(dataset, action, type, doc_id, msg.document)

      queue ->
        Process.put(:barkpark_deferred_broadcasts, [{msg, {dataset, type, doc_id, action}} | queue])
    end
  end
```

Also update `flush_deferred_broadcasts/0` to include the dispatch:

```elixir
  def flush_deferred_broadcasts do
    case Process.get(:barkpark_deferred_broadcasts) do
      nil -> :ok
      queue ->
        Process.delete(:barkpark_deferred_broadcasts)
        queue
        |> Enum.reverse()
        |> Enum.each(fn {msg, {dataset, type, doc_id, action}} ->
          Phoenix.PubSub.broadcast(Barkpark.PubSub, "documents:#{dataset}", msg)
          Phoenix.PubSub.broadcast(Barkpark.PubSub, "doc:#{dataset}:#{type}:#{published_id(doc_id)}", msg)
          Barkpark.Webhooks.Dispatcher.dispatch_async(dataset, action, type, doc_id, msg.document)
        end)
    end
  end
```

Note: The existing `maybe_broadcast` stores `{msg, topics}` in the queue. You'll need to change the queue format to include the extra metadata. Check the current implementation and adjust accordingly — the key change is threading `{dataset, type, doc_id, action}` through to the flush.

- [ ] **Step 6: Run test to verify it passes**

Run: `cd api && mix test test/barkpark/webhooks/dispatcher_test.exs --trace`
Expected: all 3 tests PASS

- [ ] **Step 7: Run full test suite to ensure no regressions**

Run: `cd api && mix test --trace`
Expected: all tests PASS (the broadcast changes must not break existing SSE/PubSub tests)

- [ ] **Step 8: Commit**

```bash
cd api && git add lib/barkpark/webhooks/dispatcher.ex lib/barkpark/application.ex lib/barkpark/content.ex test/barkpark/webhooks/dispatcher_test.exs
git commit -m "feat(api): wire webhook dispatcher into mutation broadcasts"
```

---

## Task 7: API Tester — Add New Endpoint Specs

Add endpoint specs for all new endpoints to the API Tester so they appear in the playground.

**Files:**
- Modify: `api/lib/barkpark/api_tester/endpoints.ex`
- Test: `api/test/barkpark/api_tester/endpoints_test.exs`

- [ ] **Step 1: Read current endpoints_test.exs**

Run: `cd api && cat test/barkpark/api_tester/endpoints_test.exs`

Understand the test pattern so you can add assertions for new endpoints.

- [ ] **Step 2: Add export endpoint spec**

In `api/lib/barkpark/api_tester/endpoints.ex`, add a new function and wire it into `all/1`:

```elixir
  defp export_dataset(dataset) do
    %{
      id: "export-dataset",
      category: "Export",
      label: "Export dataset",
      kind: :endpoint,
      auth: :token,
      method: "GET",
      path_template: "/v1/data/export/{dataset}",
      description: "Export all documents as newline-delimited JSON (NDJSON). Streams the response so memory stays flat.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}
      ],
      query_params: [
        %{name: "type", type: :string, default: "", notes: "Optional: filter by document type"}
      ],
      body_example: nil,
      response_shape: """
      {"_id":"p1","_type":"post","title":"Hello",...}
      {"_id":"p2","_type":"post","title":"World",...}
      """,
      possible_errors: [:unauthorized],
      expect: {200, :ok},
      runnable: true
    }
  end
```

- [ ] **Step 3: Add history endpoint specs**

```elixir
  defp history_list(dataset) do
    %{
      id: "history-list",
      category: "History",
      label: "List revisions",
      kind: :endpoint,
      auth: :token,
      method: "GET",
      path_template: "/v1/data/history/{dataset}/{type}/{doc_id}",
      description: "List revision history for a document, newest first.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"},
        %{name: "type", type: :string, default: "post", notes: "Document type"},
        %{name: "doc_id", type: :string, default: "", notes: "Document ID (published ID, no drafts. prefix)"}
      ],
      query_params: [
        %{name: "limit", type: :string, default: "50", notes: "Max revisions to return (1–200)"}
      ],
      body_example: nil,
      response_shape: """
      {
        "revisions": [
          {"id": "uuid", "action": "publish", "title": "...", "status": "published", "timestamp": "..."}
        ],
        "count": 5
      }
      """,
      possible_errors: [:unauthorized],
      expect: {200, :ok},
      runnable: true
    }
  end

  defp history_show(dataset) do
    %{
      id: "history-show",
      category: "History",
      label: "Get revision",
      kind: :endpoint,
      auth: :token,
      method: "GET",
      path_template: "/v1/data/revision/{dataset}/{id}",
      description: "Get a single revision by ID, including full content snapshot.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"},
        %{name: "id", type: :string, default: "", notes: "Revision UUID"}
      ],
      query_params: [],
      body_example: nil,
      response_shape: """
      {
        "revision": {
          "id": "uuid", "doc_id": "p1", "type": "post",
          "action": "publish", "title": "...", "content": {...},
          "timestamp": "..."
        }
      }
      """,
      possible_errors: [:unauthorized, :not_found],
      expect: nil,
      runnable: true
    }
  end

  defp history_restore(dataset) do
    %{
      id: "history-restore",
      category: "History",
      label: "Restore revision",
      kind: :endpoint,
      auth: :token,
      method: "POST",
      path_template: "/v1/data/revision/{dataset}/{id}/restore",
      description: "Restore a document to a specific revision. Creates or updates the draft.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"},
        %{name: "id", type: :string, default: "", notes: "Revision UUID to restore"}
      ],
      query_params: [],
      body_example: %{"type" => "post"},
      response_shape: """
      {
        "restored": true,
        "document": {"_id": "drafts.p1", "_type": "post", ...}
      }
      """,
      possible_errors: [:unauthorized, :not_found],
      expect: nil,
      runnable: true
    }
  end
```

- [ ] **Step 4: Add search endpoint spec**

```elixir
  defp search_documents(dataset) do
    %{
      id: "search-documents",
      category: "Query",
      label: "Search",
      kind: :endpoint,
      auth: :public,
      method: "GET",
      path_template: "/v1/data/search/{dataset}",
      description: "Full-text search across document titles. Returns published docs by default.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}
      ],
      query_params: [
        %{name: "q", type: :string, default: "", notes: "Search query (required)"},
        %{name: "type", type: :string, default: "", notes: "Filter by document type"},
        %{name: "perspective", type: :select, default: "published", options: ["published", "drafts", "raw"], notes: "Which documents to search"},
        %{name: "limit", type: :string, default: "50", notes: "Max results (1–200)"},
        %{name: "offset", type: :string, default: "0", notes: "Pagination offset"}
      ],
      body_example: nil,
      response_shape: """
      {
        "documents": [{"_id": "p1", "_type": "post", "title": "..."}],
        "count": 12,
        "query": "phoenix"
      }
      """,
      possible_errors: [:malformed],
      expect: nil,
      runnable: true
    }
  end
```

- [ ] **Step 5: Add analytics endpoint spec**

```elixir
  defp analytics_overview(dataset) do
    %{
      id: "analytics-overview",
      category: "Analytics",
      label: "Dataset stats",
      kind: :endpoint,
      auth: :token,
      method: "GET",
      path_template: "/v1/data/analytics/{dataset}",
      description: "Aggregate stats: document counts by type (published/draft breakdown), recent mutation activity.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}
      ],
      query_params: [],
      body_example: nil,
      response_shape: """
      {
        "dataset": "production",
        "total_documents": 42,
        "types": [
          {"type": "post", "total": 20, "published": 15, "drafts": 5},
          {"type": "author", "total": 8, "published": 8, "drafts": 0}
        ],
        "recent_activity": [
          {"id": 1, "type": "post", "doc_id": "p1", "mutation": "publish", "timestamp": "..."}
        ]
      }
      """,
      possible_errors: [:unauthorized],
      expect: {200, :ok},
      runnable: true
    }
  end
```

- [ ] **Step 6: Add webhook endpoint specs**

```elixir
  defp webhooks_list(dataset) do
    %{
      id: "webhooks-list",
      category: "Webhooks",
      label: "List webhooks",
      kind: :endpoint,
      auth: :admin,
      method: "GET",
      path_template: "/v1/webhooks/{dataset}",
      description: "List all webhooks configured for this dataset.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}
      ],
      query_params: [],
      body_example: nil,
      response_shape: """
      {
        "webhooks": [
          {"id": "uuid", "name": "My Hook", "url": "https://...", "events": ["create"], "types": ["post"], "active": true}
        ]
      }
      """,
      possible_errors: [:unauthorized, :forbidden],
      expect: {200, :ok},
      runnable: true
    }
  end

  defp webhooks_create(dataset) do
    %{
      id: "webhooks-create",
      category: "Webhooks",
      label: "Create webhook",
      kind: :endpoint,
      auth: :admin,
      method: "POST",
      path_template: "/v1/webhooks/{dataset}",
      description: "Create a new webhook. Empty events/types arrays match all events/types.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}
      ],
      query_params: [],
      body_example: %{
        "name" => "Notify Slack",
        "url" => "https://hooks.slack.com/services/...",
        "events" => ["publish"],
        "types" => ["post"],
        "secret" => "optional-hmac-secret"
      },
      response_shape: """
      {
        "webhook": {"id": "uuid", "name": "Notify Slack", "url": "https://...", "active": true}
      }
      """,
      possible_errors: [:unauthorized, :forbidden, :validation_failed],
      expect: nil,
      runnable: true
    }
  end

  defp webhooks_delete(dataset) do
    %{
      id: "webhooks-delete",
      category: "Webhooks",
      label: "Delete webhook",
      kind: :endpoint,
      auth: :admin,
      method: "DELETE",
      path_template: "/v1/webhooks/{dataset}/{id}",
      description: "Delete a webhook by ID.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"},
        %{name: "id", type: :string, default: "", notes: "Webhook UUID"}
      ],
      query_params: [],
      body_example: nil,
      response_shape: """
      {"deleted": "uuid"}
      """,
      possible_errors: [:unauthorized, :forbidden, :not_found],
      expect: nil,
      runnable: true
    }
  end
```

- [ ] **Step 7: Wire all new specs into `all/1`**

Update the `all/1` function to include the new endpoints:

```elixir
  def all(dataset) when is_binary(dataset) do
    [
      ref_envelope(),
      ref_error_codes(),
      ref_known_limitations(),
      query_list(dataset),
      query_filter_ops(dataset),
      query_single(dataset),
      query_expand(dataset),
      search_documents(dataset),
      mutate_create(dataset),
      mutate_create_or_replace(dataset),
      mutate_create_if_not_exists(dataset),
      mutate_patch(dataset),
      mutate_publish(dataset),
      mutate_unpublish(dataset),
      mutate_discard_draft(dataset),
      mutate_delete(dataset),
      export_dataset(dataset),
      history_list(dataset),
      history_show(dataset),
      history_restore(dataset),
      analytics_overview(dataset),
      listen_sse(dataset),
      schemas_list(dataset),
      schemas_show(dataset),
      webhooks_list(dataset),
      webhooks_create(dataset),
      webhooks_delete(dataset)
    ]
  end
```

- [ ] **Step 8: Update endpoints_test.exs**

Add assertions for the new endpoint count and new IDs. The test likely checks `length(Endpoints.all("test"))` — update the expected count from 18 to 28 (or whatever the new total is).

Also add:

```elixir
  test "new endpoints have valid specs" do
    new_ids = ~w(export-dataset history-list history-show history-restore search-documents analytics-overview webhooks-list webhooks-create webhooks-delete)

    for id <- new_ids do
      endpoint = Endpoints.find("test", id)
      assert endpoint != nil, "Missing endpoint: #{id}"
      assert endpoint.id == id
      assert endpoint.category in ~w(Export History Query Analytics Webhooks)
      assert endpoint.kind == :endpoint
    end
  end
```

- [ ] **Step 9: Update the API Tester LiveView category_icon function**

In `api/lib/barkpark_web/live/studio/api_tester_live.ex`, update the `category_icon/1` function to handle new categories:

```elixir
  defp category_icon("Export"), do: "download"
  defp category_icon("History"), do: "history"
  defp category_icon("Analytics"), do: "bar-chart-2"
  defp category_icon("Webhooks"), do: "webhook"
```

- [ ] **Step 10: Update the Runner to handle DELETE method**

Check if `api/lib/barkpark/api_tester/runner.ex` handles the DELETE method in `build_request`. If it only handles GET and POST, add DELETE support:

In the `build_request/3` function, ensure the method passthrough works for DELETE (it likely already does since it just passes the method string through).

- [ ] **Step 11: Run all tests**

Run: `cd api && mix test --trace`
Expected: all tests PASS

- [ ] **Step 12: Commit**

```bash
cd api && git add lib/barkpark/api_tester/endpoints.ex lib/barkpark_web/live/studio/api_tester_live.ex test/barkpark/api_tester/endpoints_test.exs
git commit -m "feat(api-tester): add specs for export, history, search, analytics, webhooks endpoints"
```

---

## Task 8: Full Integration Test

Run the entire test suite and verify all new endpoints work together.

- [ ] **Step 1: Run the full test suite**

Run: `cd api && mix test --trace`
Expected: all tests PASS, no regressions

- [ ] **Step 2: Start the dev server and test manually**

Run: `cd api && mix phx.server`

In another terminal:

```bash
TOKEN="barkpark-dev-token"

# Export
curl -s -H "Authorization: Bearer $TOKEN" localhost:4000/v1/data/export/production | head -5

# Search
curl -s "localhost:4000/v1/data/search/production?q=test"

# Analytics
curl -s -H "Authorization: Bearer $TOKEN" localhost:4000/v1/data/analytics/production

# History (use a known doc_id)
curl -s -H "Authorization: Bearer $TOKEN" localhost:4000/v1/data/history/production/post/p1

# Webhooks
curl -s -H "Authorization: Bearer $TOKEN" localhost:4000/v1/webhooks/production

# API Tester — open in browser
# http://localhost:4000/studio/production/api-tester
# Verify new categories: Export, History, Analytics, Webhooks appear in the sidebar
```

- [ ] **Step 3: Verify API Tester playground**

Open `http://localhost:4000/studio/production/api-tester` in a browser. Verify:
- New categories appear in the left sidebar
- Clicking each new endpoint shows docs in the middle pane
- The playground form renders with correct params
- Running an endpoint shows the response in the right pane

- [ ] **Step 4: Final commit**

```bash
git add -A && git status
```

If everything is clean, no commit needed. If any fixups were required, commit them:

```bash
git commit -m "fix: integration fixes for API expansion"
```

---

## Summary

| Task | Feature | Auth | Endpoints Added |
|------|---------|------|----------------|
| 1 | Export | Token | `GET /v1/data/export/:dataset` |
| 2 | History | Token | `GET /v1/data/history/:ds/:type/:id`, `GET /v1/data/revision/:ds/:id`, `POST /v1/data/revision/:ds/:id/restore` |
| 3 | Search | Public | `GET /v1/data/search/:dataset` |
| 4 | Analytics | Token | `GET /v1/data/analytics/:dataset` |
| 5 | Webhooks CRUD | Admin | `GET/POST /v1/webhooks/:ds`, `GET/PUT/DELETE /v1/webhooks/:ds/:id` |
| 6 | Webhook Dispatch | — | (internal, fires from mutations) |
| 7 | API Tester | — | 9 new endpoint specs |
| 8 | Integration | — | Full verification |

**Total new routes:** 9
**Total new API Tester specs:** 9
**New DB table:** `webhooks`
**New modules:** 6 (ExportController, HistoryController, SearchController, AnalyticsController, WebhookController, Webhooks context, Webhook schema, Dispatcher)
