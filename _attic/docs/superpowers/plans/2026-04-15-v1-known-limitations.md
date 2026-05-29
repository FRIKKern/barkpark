# v1 Known Limitations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the four remaining v1.0 known limitations — reference expansion, filter operators, SQL-level draft merge, and HTTP rate limiting — so `docs/api-v1.md § Known Limitations` shrinks from six entries to zero (two were already fixed in commit `62d20bc`: `previousRev` threading and broadcast-after-commit).

**Architecture:** Each limitation is an independent feature with its own phase. Phase 1 adds reference expansion via a new `Content.Expand` module called from `QueryController` when `?expand=` is present. Phase 2 extends `Content.apply_filter_map/2` to recognize operator maps (`%{"eq" => v, "in" => [...]}`) and teaches `QueryController.index` to parse bracket-nested `filter[field][op]=value` params. Phase 3 rewrites `list_documents`'s draft-merge path to use a PostgreSQL `DISTINCT ON` subquery wrapped in the user's ORDER BY/LIMIT/OFFSET, so merging happens server-side before pagination. Phase 4 adds a new `Barkpark.RateLimiter` ETS-backed token bucket plus a `RateLimit` plug on `/v1/*` routes, and a new `rate_limited` error code in the v1 envelope. Phase 5 merges everything, deploys, updates `docs/api-v1.md`, and sweeps the Studio API Tester's Known Limitations reference page.

**Tech Stack:** Elixir 1.18, Phoenix 1.8, Ecto 3.13 + Postgres (DISTINCT ON subquery), existing `Req` dep for contract tests, new ETS table (no new deps), existing `Plug.Conn` for rate-limit plug.

**Scope note:** This plan covers **four independent features**. Each phase produces working, shippable software on its own — if you stop after Phase 1, you have working reference expansion. Each phase ships one commit per task and ends with its own smoke test. If anything feels too big to execute, phases can be split into their own separate plans.

**Worktree:** Create a fresh isolated worktree at `.worktrees/v1-known-limitations` from `main`.

**Golden rule:** Every task ends with `MIX_ENV=test mix test` green AND no regression in the Runner battery against live prod (the 12/12 pass state from commit `62d20bc` must hold).

---

## File Structure

### New files

| File | Responsibility |
|---|---|
| `api/lib/barkpark/content/expand.ex` | Reference expansion: takes a list of envelopes + expand spec + dataset, returns envelopes with ref fields inlined. One module, one public function, one depth. |
| `api/lib/barkpark/rate_limiter.ex` | ETS-backed token bucket. Public API: `check/1` takes a key, returns `:ok` or `:rate_limited`. Managed by the Application supervisor. |
| `api/lib/barkpark_web/plugs/rate_limit.ex` | Plug that derives a rate-limit key from the conn (token if present, remote_ip otherwise), calls `RateLimiter.check/1`, and either passes through or halts with a structured `rate_limited` error envelope + `Retry-After: 60`. |
| `api/test/barkpark/content/expand_test.exs` | Unit tests for `Expand.expand/3`. |
| `api/test/barkpark/rate_limiter_test.exs` | Unit tests for token-bucket math. |
| `api/test/barkpark_web/contract/expand_test.exs` | Contract test: `?expand=author` inlines the referenced doc. |
| `api/test/barkpark_web/contract/filter_ops_test.exs` | Contract test: `filter[title][eq]=`, `[in]=`, `[contains]=`. |
| `api/test/barkpark_web/contract/rate_limit_test.exs` | Contract test: burst N+1 requests, expect 429 on the overflow. |

### Modified files

| File | Change |
|---|---|
| `api/lib/barkpark/content.ex` | Extend `apply_filter_map/2` to recognize operator maps (eq/in/contains/gt/gte/lt/lte). Rewrite the `:drafts` perspective branch of `list_documents/3` to use a `DISTINCT ON` subquery instead of post-query `maybe_merge_drafts`. Remove or retain `maybe_merge_drafts` only for the `:raw` perspective if it's still needed (it isn't — verify and delete). |
| `api/lib/barkpark/content/errors.ex` | Add `rate_limited` → `{429, "rate limit exceeded", 429}` clause. |
| `api/lib/barkpark_web/controllers/query_controller.ex` | Parse `?expand=true|field1,field2` param and call `Content.Expand.expand/3` on the query result. Parse nested `filter[field][op]=value` into a map of `%{"field" => %{"op" => value}}` and pass to `list_documents/3`. |
| `api/lib/barkpark_web/router.ex` | Pipe the `:api` pipeline through the new `RateLimit` plug, so every `/v1/*` route is rate-limited. |
| `api/lib/barkpark/application.ex` | Start the `RateLimiter` ETS table at app boot. |
| `docs/api-v1.md` | Remove the 4 closed limitations from § Known Limitations. Add a § Reference Expansion section, extend § Query params to document the new filter operators, add a § Rate Limiting section, update § Error Codes with `rate_limited`. |
| `api/lib/barkpark/api_tester/endpoints.ex` | Update `ref_known_limitations` entry's markdown to reflect the remaining (zero) limitations. Add a new test case `query-filter-operators` demonstrating `?filter[title][eq]=x`. Add a new test case `query-expand` demonstrating `?expand=author`. |
| `api/lib/barkpark_web/live/studio/api_tester_live.ex` | Update `render_reference(assigns, :known_limitations)` clause — the list shrinks. |

### Files touched but behavior unchanged

`root.html.heex`, every StudioLive file, every other LiveView, every v1 controller except `QueryController` and the plug wiring.

---

## Phase 1 — Reference expansion

### Task 1: `Content.Expand` module

**Files:**
- Create: `api/lib/barkpark/content/expand.ex`
- Create: `api/test/barkpark/content/expand_test.exs`

- [ ] **Step 1: Write failing tests**

Create `api/test/barkpark/content/expand_test.exs`:

```elixir
defmodule Barkpark.Content.ExpandTest do
  use Barkpark.DataCase, async: true
  alias Barkpark.Content
  alias Barkpark.Content.{Envelope, Expand}

  setup do
    Content.upsert_schema(
      %{
        "name" => "author",
        "title" => "Author",
        "visibility" => "public",
        "fields" => [%{"name" => "title", "type" => "string"}]
      },
      "exp"
    )

    Content.upsert_schema(
      %{
        "name" => "post",
        "title" => "Post",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "author", "type" => "reference", "refType" => "author"}
        ]
      },
      "exp"
    )

    {:ok, _} =
      Content.create_document("author", %{"_id" => "a1", "title" => "Jane"}, "exp")

    {:ok, _} = Content.publish_document("a1", "author", "exp")

    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "p1", "title" => "Hello", "author" => "a1"},
        "exp"
      )

    {:ok, _} = Content.publish_document("p1", "post", "exp")

    :ok
  end

  test "expand/3 with :all resolves every reference field in the docs" do
    [post] =
      Content.list_documents("post", "exp", perspective: :published)
      |> Enum.map(&Envelope.render/1)
      |> Expand.expand(:all, "exp")

    assert post["title"] == "Hello"
    assert is_map(post["author"])
    assert post["author"]["_id"] == "a1"
    assert post["author"]["_type"] == "author"
    assert post["author"]["title"] == "Jane"
  end

  test "expand/3 with a field list only resolves those fields" do
    docs =
      Content.list_documents("post", "exp", perspective: :published)
      |> Enum.map(&Envelope.render/1)

    [post_none] = Expand.expand(docs, [], "exp")
    assert post_none["author"] == "a1"

    [post_author] = Expand.expand(docs, ["author"], "exp")
    assert is_map(post_author["author"])
    assert post_author["author"]["title"] == "Jane"
  end

  test "expand/3 leaves unresolved refs as raw strings" do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "p2", "title" => "Orphan", "author" => "does-not-exist"},
        "exp"
      )

    {:ok, _} = Content.publish_document("p2", "post", "exp")

    docs =
      Content.list_documents("post", "exp", perspective: :published, filter_map: %{"title" => "Orphan"})
      |> Enum.map(&Envelope.render/1)

    [expanded] = Expand.expand(docs, :all, "exp")
    # Missing refs keep the raw id — clients can decide what to render.
    assert expanded["author"] == "does-not-exist"
  end

  test "expand/3 is shallow — referenced docs don't themselves get expanded" do
    Content.upsert_schema(
      %{
        "name" => "category",
        "title" => "Category",
        "visibility" => "public",
        "fields" => [%{"name" => "title", "type" => "string"}]
      },
      "exp"
    )

    Content.upsert_schema(
      %{
        "name" => "author",
        "title" => "Author",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "category", "type" => "reference", "refType" => "category"}
        ]
      },
      "exp"
    )

    {:ok, _} = Content.create_document("category", %{"_id" => "c1", "title" => "Cat"}, "exp")
    {:ok, _} = Content.publish_document("c1", "category", "exp")

    {:ok, _} =
      Content.create_document(
        "author",
        %{"_id" => "a2", "title" => "Nested", "category" => "c1"},
        "exp"
      )

    {:ok, _} = Content.publish_document("a2", "author", "exp")

    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "p3", "title" => "Deep", "author" => "a2"},
        "exp"
      )

    {:ok, _} = Content.publish_document("p3", "post", "exp")

    docs =
      Content.list_documents("post", "exp", perspective: :published, filter_map: %{"title" => "Deep"})
      |> Enum.map(&Envelope.render/1)

    [post] = Expand.expand(docs, :all, "exp")
    # author is expanded (depth 1), but author.category stays as the raw id
    assert is_map(post["author"])
    assert post["author"]["title"] == "Nested"
    assert post["author"]["category"] == "c1"
  end
end
```

Run — expect fail:

```bash
cd api && MIX_ENV=test mix test test/barkpark/content/expand_test.exs
```

- [ ] **Step 2: Implement `Content.Expand`**

Create `api/lib/barkpark/content/expand.ex`:

```elixir
defmodule Barkpark.Content.Expand do
  @moduledoc """
  Reference expansion for v1 query responses.

  Given a list of envelopes and an expand spec, resolves any reference
  fields to the full envelope of the referenced document. Expansion is
  strictly **depth 1**: a referenced doc's own reference fields stay as
  raw id strings. This keeps the response shape bounded and avoids
  cycle detection. Clients that want deeper expansion issue multiple
  queries.

  ## Expand spec

    * `:all` — expand every reference field in the doc's schema
    * `[field_name, ...]` — expand only these fields (list of strings)
    * `[]` — no expansion (passthrough)

  ## Behaviour

    * Reference fields are detected via the document type's schema
      (`Content.list_schemas/1`).
    * Missing referenced docs stay as the raw id string — the caller
      can tell them apart from expanded refs because expanded refs
      are maps and unexpanded refs are strings.
    * Reference resolution prefers the published perspective; if no
      published doc exists, the draft is used instead.
  """

  alias Barkpark.Content
  alias Barkpark.Content.Envelope

  @type spec :: :all | [String.t()]

  @spec expand([map()], spec(), String.t()) :: [map()]
  def expand([], _spec, _dataset), do: []
  def expand(docs, [], _dataset), do: docs

  def expand(docs, spec, dataset) do
    # Group by type so we fetch each type's schema once, not per doc.
    docs_by_type = Enum.group_by(docs, & &1["_type"])
    schemas = load_schemas(Map.keys(docs_by_type), dataset)

    Enum.map(docs, fn doc ->
      type = doc["_type"]
      schema = Map.get(schemas, type)

      case ref_fields_for(schema, spec) do
        [] ->
          doc

        fields ->
          Enum.reduce(fields, doc, fn %{"name" => field_name, "refType" => ref_type}, acc ->
            case Map.get(acc, field_name) do
              ref_id when is_binary(ref_id) and ref_id != "" ->
                case resolve_ref(ref_id, ref_type, dataset) do
                  nil -> acc
                  resolved -> Map.put(acc, field_name, resolved)
                end

              _ ->
                acc
            end
          end)
      end
    end)
  end

  defp load_schemas(types, dataset) do
    types
    |> Enum.map(fn type ->
      case Content.get_schema(type, dataset) do
        {:ok, schema} -> {type, schema}
        _ -> {type, nil}
      end
    end)
    |> Map.new()
  end

  defp ref_fields_for(nil, _spec), do: []

  defp ref_fields_for(schema, :all) do
    schema.fields
    |> Enum.filter(&(&1["type"] == "reference" && &1["refType"]))
  end

  defp ref_fields_for(schema, fields) when is_list(fields) do
    schema.fields
    |> Enum.filter(fn f ->
      f["type"] == "reference" && f["refType"] && f["name"] in fields
    end)
  end

  defp resolve_ref(ref_id, ref_type, dataset) do
    # Try published first, then draft
    case Content.get_document(ref_id, ref_type, dataset) do
      {:ok, doc} ->
        Envelope.render(doc)

      _ ->
        case Content.get_document("drafts." <> ref_id, ref_type, dataset) do
          {:ok, doc} -> Envelope.render(doc)
          _ -> nil
        end
    end
  end
end
```

- [ ] **Step 3: Run tests — expect pass**

```bash
cd api && MIX_ENV=test mix test test/barkpark/content/expand_test.exs
```
Expected: 4 tests, 0 failures.

- [ ] **Step 4: Full suite**

```bash
cd api && MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: 76 tests (72 baseline + 4 new), 0 failures.

- [ ] **Step 5: Commit**

```bash
git add api/lib/barkpark/content/expand.ex api/test/barkpark/content/expand_test.exs
git commit -m "feat(content): Content.Expand resolves reference fields depth-1"
```

---

### Task 2: Wire `?expand=` into `QueryController`

**Files:**
- Modify: `api/lib/barkpark_web/controllers/query_controller.ex`
- Create: `api/test/barkpark_web/contract/expand_test.exs`

- [ ] **Step 1: Write failing contract test**

```elixir
defmodule BarkparkWeb.Contract.ExpandTest do
  use BarkparkWeb.ConnCase, async: false
  alias Barkpark.Content

  setup do
    Content.upsert_schema(
      %{
        "name" => "author",
        "title" => "Author",
        "visibility" => "public",
        "fields" => [%{"name" => "title", "type" => "string"}]
      },
      "ctest"
    )

    Content.upsert_schema(
      %{
        "name" => "post",
        "title" => "Post",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "author", "type" => "reference", "refType" => "author"}
        ]
      },
      "ctest"
    )

    {:ok, _} = Content.create_document("author", %{"_id" => "ct-a1", "title" => "Jane"}, "ctest")
    {:ok, _} = Content.publish_document("ct-a1", "author", "ctest")

    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "ct-p1", "title" => "Hi", "author" => "ct-a1"},
        "ctest"
      )

    {:ok, _} = Content.publish_document("ct-p1", "post", "ctest")
    :ok
  end

  test "GET /v1/data/query/:ds/:type without expand returns raw ref ids", %{conn: conn} do
    %{"documents" => [post | _]} =
      conn
      |> get("/v1/data/query/ctest/post?filter[title]=Hi")
      |> json_response(200)

    assert post["author"] == "ct-a1"
  end

  test "GET /v1/data/query/:ds/:type?expand=true expands all reference fields", %{conn: conn} do
    %{"documents" => [post | _]} =
      conn
      |> get("/v1/data/query/ctest/post?filter[title]=Hi&expand=true")
      |> json_response(200)

    assert is_map(post["author"])
    assert post["author"]["_id"] == "ct-a1"
    assert post["author"]["title"] == "Jane"
  end

  test "GET /v1/data/query/:ds/:type?expand=author expands only that field", %{conn: conn} do
    %{"documents" => [post | _]} =
      conn
      |> get("/v1/data/query/ctest/post?filter[title]=Hi&expand=author")
      |> json_response(200)

    assert is_map(post["author"])
    assert post["author"]["title"] == "Jane"
  end

  test "GET /v1/data/doc/:ds/:type/:id?expand=true expands refs on single doc", %{conn: conn} do
    post =
      conn
      |> get("/v1/data/doc/ctest/post/ct-p1?expand=true")
      |> json_response(200)

    assert is_map(post["author"])
    assert post["author"]["title"] == "Jane"
  end
end
```

Run — expect fail:

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/contract/expand_test.exs
```

- [ ] **Step 2: Update `QueryController` to parse and apply expand**

Open `api/lib/barkpark_web/controllers/query_controller.ex`. Find the `index/2` action and extend it to parse and apply expand. Add a private `parse_expand/1` helper and a call to `Content.Expand.expand/3`:

```elixir
  alias Barkpark.Content.Expand

  def index(conn, %{"dataset" => dataset, "type" => type} = params) do
    unless Content.schema_public?(type, dataset) do
      {:error, :not_found}
    else
      perspective = parse_perspective(Map.get(params, "perspective", "published"))
      limit = parse_int(params["limit"], 100)
      offset = parse_int(params["offset"], 0)
      order = parse_order(params["order"])
      filter_map = Map.get(params, "filter") || %{}
      expand_spec = parse_expand(params["expand"])

      docs =
        Content.list_documents(type, dataset,
          perspective: perspective,
          filter_map: filter_map,
          limit: limit,
          offset: offset,
          order: order
        )

      envelopes =
        docs
        |> Envelope.render_many()
        |> Expand.expand(expand_spec, dataset)

      json(conn, %{
        perspective: to_string(perspective),
        documents: envelopes,
        count: length(envelopes),
        limit: limit,
        offset: offset
      })
    end
  end

  def show(conn, %{"dataset" => dataset, "type" => type, "doc_id" => doc_id} = params) do
    unless Content.schema_public?(type, dataset) do
      {:error, :not_found}
    else
      expand_spec = parse_expand(params["expand"])

      with {:ok, doc} <- Content.get_document(doc_id, type, dataset) do
        envelope =
          doc
          |> Envelope.render()
          |> List.wrap()
          |> Expand.expand(expand_spec, dataset)
          |> List.first()

        json(conn, envelope)
      end
    end
  end

  # ──────────────────────────────────────────────────────────────
  # parse_expand/1: turn a URL param into the Expand spec.
  #
  #   "true"               → :all    (expand every ref field)
  #   "author,category"    → ["author", "category"]
  #   nil / "" / "false"   → []      (no expansion)
  defp parse_expand(nil), do: []
  defp parse_expand(""), do: []
  defp parse_expand("false"), do: []
  defp parse_expand("true"), do: :all

  defp parse_expand(csv) when is_binary(csv) do
    csv
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
```

- [ ] **Step 3: Run tests — expect pass**

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/contract/expand_test.exs
MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: 4 new contract tests passing, full suite 80 tests 0 failures.

- [ ] **Step 4: Commit**

```bash
git add api/lib/barkpark_web/controllers/query_controller.ex api/test/barkpark_web/contract/expand_test.exs
git commit -m "feat(query): ?expand=true|field1,field2 reference expansion"
```

---

### Task 3: Update docs + API Tester for reference expansion

**Files:**
- Modify: `docs/api-v1.md`
- Modify: `api/lib/barkpark/api_tester/endpoints.ex`

- [ ] **Step 1: Remove the "reference expansion not implemented" bullet and add docs**

Open `docs/api-v1.md`. In `## Known Limitations`, **delete** the line:

```
- Reference expansion (`?expand=`) is not implemented.
```

In `## 4. GET /v1/data/query/:dataset/:type [public]` extend the query params table with a new row:

```
| `expand` | — | `true` (expand all refs) \| comma list `field1,field2` (expand named fields). Depth 1 only. |
```

Add a new section after § 5 (`GET /v1/data/doc/`) titled `## 5a. Reference expansion`:

```markdown
### 5a. Reference Expansion

When a query or doc request carries `?expand=true` (or `?expand=author,category`), reference fields in the returned envelope are inlined with the full referenced document. Expansion is always **depth 1** — a referenced doc's own reference fields stay as raw id strings.

**Example request:**

    curl "localhost:4000/v1/data/query/production/post?limit=1&expand=true"

**Example response (abbreviated):**

```json
{
  "documents": [
    {
      "_id": "p1",
      "_type": "post",
      "title": "Hello",
      "author": {
        "_id": "a1",
        "_type": "author",
        "title": "Jane",
        "category": "c1"  // NOT expanded — depth 1 only
      }
    }
  ]
}
```

Missing references (the referenced document does not exist in the dataset) stay as the raw id string so clients can tell them apart from expanded refs: maps vs. strings.
```

- [ ] **Step 2: Add `query-expand` test case to the Endpoints module**

Open `api/lib/barkpark/api_tester/endpoints.ex`. Find `defp query_single(dataset) do` and add a new helper below it:

```elixir
  defp query_expand(dataset) do
    %{
      id: "query-expand",
      category: "Query",
      label: "Expand references",
      kind: :endpoint,
      auth: :public,
      method: "GET",
      path_template: "/v1/data/query/{dataset}/{type}",
      description:
        "Depth-1 reference expansion. Pass ?expand=true to inline all reference fields, or ?expand=field1,field2 for a named subset.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"},
        %{name: "type", type: :string, default: "post", notes: "Document type"}
      ],
      query_params: [
        %{name: "limit", type: :integer, default: "3", notes: "How many docs to fetch"},
        %{name: "expand", type: :string, default: "true", notes: "true | comma-list of field names"}
      ],
      body_example: nil,
      response_shape: """
      {
        "documents": [
          {
            "_id": "p1",
            "author": {
              "_id": "a1",
              "_type": "author",
              "title": "Jane"
            }
          }
        ]
      }
      """,
      possible_errors: [:not_found],
      expect: {200, :envelope_has_reserved_keys}
    }
  end
```

Update `all/1` to include it:

```elixir
  def all(dataset) when is_binary(dataset) do
    [
      ref_envelope(),
      ref_error_codes(),
      ref_known_limitations(),
      query_list(dataset),
      query_single(dataset),
      query_expand(dataset),       # ← add this line
      mutate_create(dataset),
      # ...rest unchanged
```

- [ ] **Step 3: Run tests**

```bash
cd api && MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: 80 tests still passing (the new test case doesn't add ExUnit tests — it's just a new entry in `Endpoints.all/1`, and no existing test asserts on the exact entry count).

- [ ] **Step 4: Commit**

```bash
git add docs/api-v1.md api/lib/barkpark/api_tester/endpoints.ex
git commit -m "docs(v1): document ?expand= reference expansion"
```

---

## Phase 2 — Filter operators

### Task 4: Extend `Content.apply_filter_map/2` to recognize operator maps

**Files:**
- Modify: `api/lib/barkpark/content.ex`
- Create: `api/test/barkpark/content_filter_ops_test.exs`

- [ ] **Step 1: Failing tests**

Create `api/test/barkpark/content_filter_ops_test.exs`:

```elixir
defmodule Barkpark.ContentFilterOpsTest do
  use Barkpark.DataCase, async: true
  alias Barkpark.Content

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "fops"
    )

    for {id, title, status, count} <- [
          {"fo-1", "Alpha", "published", 3},
          {"fo-2", "Beta", "draft", 5},
          {"fo-3", "Gamma", "published", 7},
          {"fo-4", "Delta", "draft", 2}
        ] do
      {:ok, _} =
        Content.create_document(
          "post",
          %{"_id" => id, "title" => title, "status" => status, "count" => to_string(count)},
          "fops"
        )

      {:ok, _} = Content.publish_document(id, "post", "fops")
    end

    :ok
  end

  test "eq operator matches exact value" do
    docs =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"title" => %{"eq" => "Alpha"}}
      )

    assert length(docs) == 1
    assert hd(docs).title == "Alpha"
  end

  test "in operator matches any value in the list" do
    docs =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"title" => %{"in" => ["Alpha", "Gamma"]}}
      )

    titles = Enum.map(docs, & &1.title) |> Enum.sort()
    assert titles == ["Alpha", "Gamma"]
  end

  test "contains operator matches substring on top-level fields" do
    docs =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"title" => %{"contains" => "a"}}
      )

    # Alpha, Beta, Gamma, Delta all contain "a" (case-sensitive)
    titles = Enum.map(docs, & &1.title) |> Enum.sort()
    assert titles == ["Alpha", "Beta", "Delta", "Gamma"]
  end

  test "gte/lte operators match on content fields stringly" do
    # Content fields are stored as strings in JSONB, so lexicographic.
    docs =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"count" => %{"gte" => "5"}}
      )

    counts = Enum.map(docs, fn d -> d.content["count"] end) |> Enum.sort()
    assert counts == ["5", "7"]
  end

  test "bare value (no operator map) still works as eq" do
    docs =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"title" => "Beta"}
      )

    assert length(docs) == 1
    assert hd(docs).title == "Beta"
  end
end
```

Run — expect fail:

```bash
cd api && MIX_ENV=test mix test test/barkpark/content_filter_ops_test.exs
```

- [ ] **Step 2: Extend `apply_filter_map/2`**

Open `api/lib/barkpark/content.ex`. Find `defp apply_filter_map(query, map)` and replace it with:

```elixir
  defp apply_filter_map(query, map) when map_size(map) == 0, do: query

  defp apply_filter_map(query, map) do
    Enum.reduce(map, query, fn
      {field, %{} = ops}, q -> apply_field_ops(q, field, ops)
      {field, value}, q -> apply_field_op(q, field, "eq", value)
    end)
  end

  # Apply every operator in an operator map to a single field.
  defp apply_field_ops(query, field, ops) do
    Enum.reduce(ops, query, fn {op, value}, q ->
      apply_field_op(q, field, op, value)
    end)
  end

  # Dispatch one {field, op, value} triple. Top-level fields (title,
  # status) are special-cased; everything else walks d.content JSONB.
  defp apply_field_op(query, "title", "eq", v), do: where(query, [d], d.title == ^v)
  defp apply_field_op(query, "title", "in", vs) when is_list(vs), do: where(query, [d], d.title in ^vs)
  defp apply_field_op(query, "title", "contains", v), do: where(query, [d], ilike(d.title, ^"%#{v}%"))
  defp apply_field_op(query, "title", "gt", v), do: where(query, [d], d.title > ^v)
  defp apply_field_op(query, "title", "gte", v), do: where(query, [d], d.title >= ^v)
  defp apply_field_op(query, "title", "lt", v), do: where(query, [d], d.title < ^v)
  defp apply_field_op(query, "title", "lte", v), do: where(query, [d], d.title <= ^v)

  defp apply_field_op(query, "status", "eq", v), do: where(query, [d], d.status == ^v)
  defp apply_field_op(query, "status", "in", vs) when is_list(vs), do: where(query, [d], d.status in ^vs)

  defp apply_field_op(query, field, "eq", v),
    do: where(query, [d], fragment("?->>? = ?", d.content, ^field, ^v))

  defp apply_field_op(query, field, "in", vs) when is_list(vs),
    do: where(query, [d], fragment("?->>? = ANY(?)", d.content, ^field, ^vs))

  defp apply_field_op(query, field, "contains", v),
    do: where(query, [d], fragment("?->>? ILIKE ?", d.content, ^field, ^"%#{v}%"))

  defp apply_field_op(query, field, "gt", v),
    do: where(query, [d], fragment("?->>? > ?", d.content, ^field, ^v))

  defp apply_field_op(query, field, "gte", v),
    do: where(query, [d], fragment("?->>? >= ?", d.content, ^field, ^v))

  defp apply_field_op(query, field, "lt", v),
    do: where(query, [d], fragment("?->>? < ?", d.content, ^field, ^v))

  defp apply_field_op(query, field, "lte", v),
    do: where(query, [d], fragment("?->>? <= ?", d.content, ^field, ^v))

  # Unknown operators are silently ignored — returning an error from a
  # filter function would cascade badly through list_documents callers.
  # Adding a validation step is a Phase-6 follow-up.
  defp apply_field_op(query, _field, _op, _value), do: query
```

- [ ] **Step 3: Run tests — expect pass**

```bash
cd api && MIX_ENV=test mix test test/barkpark/content_filter_ops_test.exs
MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: 5 new tests passing, full suite 85 tests 0 failures.

- [ ] **Step 4: Commit**

```bash
git add api/lib/barkpark/content.ex api/test/barkpark/content_filter_ops_test.exs
git commit -m "feat(content): filter operators (eq/in/contains/gt/gte/lt/lte)"
```

---

### Task 5: Wire filter operators into `QueryController` + contract test

**Files:**
- Modify: `api/lib/barkpark_web/controllers/query_controller.ex`
- Create: `api/test/barkpark_web/contract/filter_ops_test.exs`

- [ ] **Step 1: Write failing contract test**

```elixir
defmodule BarkparkWeb.Contract.FilterOpsTest do
  use BarkparkWeb.ConnCase, async: false
  alias Barkpark.Content

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "fops_http"
    )

    for {id, title} <- [{"f1", "Alpha"}, {"f2", "Beta"}, {"f3", "Gamma"}] do
      {:ok, _} = Content.create_document("post", %{"_id" => id, "title" => title}, "fops_http")
      {:ok, _} = Content.publish_document(id, "post", "fops_http")
    end

    :ok
  end

  test "filter[title][eq]=Alpha matches one", %{conn: conn} do
    body =
      conn
      |> get("/v1/data/query/fops_http/post?filter%5Btitle%5D%5Beq%5D=Alpha")
      |> json_response(200)

    assert body["count"] == 1
    assert hd(body["documents"])["title"] == "Alpha"
  end

  test "filter[title][in]=Alpha,Gamma matches two", %{conn: conn} do
    # The `in` operator expects a repeated param or a comma-separated
    # list — we use the comma form since that's what bracket-nested
    # URL encoding produces naturally.
    body =
      conn
      |> get("/v1/data/query/fops_http/post?filter%5Btitle%5D%5Bin%5D=Alpha,Gamma")
      |> json_response(200)

    assert body["count"] == 2
    titles = Enum.map(body["documents"], & &1["title"]) |> Enum.sort()
    assert titles == ["Alpha", "Gamma"]
  end

  test "filter[title][contains]=a is case-insensitive", %{conn: conn} do
    body =
      conn
      |> get("/v1/data/query/fops_http/post?filter%5Btitle%5D%5Bcontains%5D=a")
      |> json_response(200)

    assert body["count"] == 3
  end

  test "bare filter[title]=Alpha still works (sugar for eq)", %{conn: conn} do
    body =
      conn
      |> get("/v1/data/query/fops_http/post?filter%5Btitle%5D=Alpha")
      |> json_response(200)

    assert body["count"] == 1
  end
end
```

Run — expect fail:

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/contract/filter_ops_test.exs
```

- [ ] **Step 2: Normalize the filter_map param in `QueryController.index/2`**

Phoenix parses `filter[field][op]=value` into `%{"filter" => %{"field" => %{"op" => "value"}}}` — almost what we want, EXCEPT `[in]` values need splitting from `"Alpha,Gamma"` into `["Alpha", "Gamma"]` before reaching `apply_field_op/4`.

In `api/lib/barkpark_web/controllers/query_controller.ex`, inside `index/2`, replace:

```elixir
filter_map = Map.get(params, "filter") || %{}
```

with:

```elixir
filter_map = params |> Map.get("filter", %{}) |> normalize_filter_map()
```

And add the helper below the existing private helpers:

```elixir
  # Normalize bracket-nested filter params:
  #   %{"title" => "Alpha"}                   →  %{"title" => "Alpha"}
  #   %{"title" => %{"eq" => "Alpha"}}         →  same
  #   %{"title" => %{"in" => "A,B"}}           →  %{"title" => %{"in" => ["A","B"]}}
  #
  # Only the `in` op expects a list — Phoenix's query parser only
  # produces maps and strings, so we split the string into a list here.
  defp normalize_filter_map(map) when is_map(map) do
    Enum.into(map, %{}, fn
      {field, %{} = ops} -> {field, Enum.into(ops, %{}, &normalize_filter_op/1)}
      {field, value} -> {field, value}
    end)
  end

  defp normalize_filter_map(_), do: %{}

  defp normalize_filter_op({"in", csv}) when is_binary(csv) do
    {"in", csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1)}
  end

  defp normalize_filter_op(pair), do: pair
```

- [ ] **Step 3: Run tests — expect pass**

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/contract/filter_ops_test.exs
MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: 4 new contract tests passing, full suite 89 tests 0 failures.

- [ ] **Step 4: Commit**

```bash
git add api/lib/barkpark_web/controllers/query_controller.ex api/test/barkpark_web/contract/filter_ops_test.exs
git commit -m "feat(query): bracket-nested filter operators (eq/in/contains/gt/gte/lt/lte)"
```

---

### Task 6: Update docs for filter operators

**Files:**
- Modify: `docs/api-v1.md`
- Modify: `api/lib/barkpark/api_tester/endpoints.ex`

- [ ] **Step 1: Extend the filter param docs**

In `docs/api-v1.md`, find the `## 4. GET /v1/data/query/...` section's query param table and replace the `filter[<field>]` row with:

```
| `filter[<field>]` | — | Exact-match shorthand: `filter[title]=Alpha` |
| `filter[<field>][<op>]` | — | Operator form. `op` is one of `eq`, `in`, `contains`, `gt`, `gte`, `lt`, `lte`. `in` takes a comma-separated list: `filter[title][in]=A,B,C` |
```

Remove from § Known Limitations the line:

```
- Filter only supports exact-match on single values.
```

- [ ] **Step 2: Add a new test case for the operator form**

In `api/lib/barkpark/api_tester/endpoints.ex`, add below the existing `query_list/1`:

```elixir
  defp query_filter_ops(dataset) do
    %{
      id: "query-filter-ops",
      category: "Query",
      label: "Filter operators",
      kind: :endpoint,
      auth: :public,
      method: "GET",
      path_template: "/v1/data/query/{dataset}/{type}",
      description:
        "Operator-form filters: filter[title][eq]=, filter[title][in]=a,b, filter[title][contains]=. Top-level shorthand filter[title]=x is equivalent to [eq].",
      path_params: [
        %{name: "dataset", type: :string, default: dataset},
        %{name: "type", type: :string, default: "post"}
      ],
      query_params: [
        %{name: "filter[title][contains]", type: :string, default: "smoke", notes: "Substring match, case-insensitive"},
        %{name: "limit", type: :integer, default: "5"}
      ],
      body_example: nil,
      response_shape: """
      {
        "documents": [ /* envelopes whose title contains the substring */ ],
        "count": N
      }
      """,
      possible_errors: [:not_found],
      expect: {200, :ok}
    }
  end
```

Update `all/1` to include it right after `query_list(dataset)`:

```elixir
      query_list(dataset),
      query_filter_ops(dataset),  # ← add this line
      query_single(dataset),
      query_expand(dataset),
```

- [ ] **Step 3: Run tests**

```bash
cd api && MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: 89 tests, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add docs/api-v1.md api/lib/barkpark/api_tester/endpoints.ex
git commit -m "docs(v1): document filter operators"
```

---

## Phase 3 — SQL-level draft merge

### Task 7: Rewrite `:drafts` perspective as a `DISTINCT ON` subquery

**Files:**
- Modify: `api/lib/barkpark/content.ex`
- Create: `api/test/barkpark/content_drafts_pagination_test.exs`

- [ ] **Step 1: Write failing test**

Create `api/test/barkpark/content_drafts_pagination_test.exs`:

```elixir
defmodule Barkpark.ContentDraftsPaginationTest do
  use Barkpark.DataCase, async: true
  alias Barkpark.Content

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "dp"
    )

    # 10 docs with drafts only
    for i <- 1..10 do
      {:ok, _} =
        Content.create_document(
          "post",
          %{"_id" => "dp-#{i}", "title" => "Doc #{i}"},
          "dp"
        )
    end

    # Publish every other one (1, 3, 5, 7, 9) — now both draft and
    # published exist for those, and `:drafts` perspective should
    # prefer the draft for each. But docs 1, 3, 5, 7, 9 only have
    # published now because publishing deletes the draft.
    for i <- [1, 3, 5, 7, 9] do
      {:ok, _} = Content.publish_document("dp-#{i}", "post", "dp")
    end

    # Now reintroduce drafts on 1, 3, 5, 7, 9 by editing them (via upsert)
    # so they have BOTH a draft and a published with the same pub_id.
    for i <- [1, 3, 5, 7, 9] do
      {:ok, _} =
        Content.upsert_document("post", %{"_id" => "dp-#{i}", "title" => "Doc #{i} (edited)"}, "dp")
    end

    :ok
  end

  test "drafts perspective with limit=5 returns exactly 5 rows" do
    docs =
      Content.list_documents("post", "dp", perspective: :drafts, limit: 5)

    assert length(docs) == 5
  end

  test "drafts perspective with limit=100 returns 10 merged rows (not 15)" do
    # Without the SQL-level merge, the inner query returns 15 rows
    # (10 drafts + 5 published), pagination limits to 100, then the
    # post-merge collapses to 10. With SQL-level merge, the inner
    # query already collapses to 10 before limit is applied.
    docs =
      Content.list_documents("post", "dp", perspective: :drafts, limit: 100)

    ids = Enum.map(docs, & Content.published_id(&1.doc_id)) |> Enum.sort()
    assert length(docs) == 10
    assert ids == Enum.sort(Enum.map(1..10, &"dp-#{&1}"))
  end

  test "drafts perspective honors user-provided order_by across the merge" do
    docs =
      Content.list_documents("post", "dp",
        perspective: :drafts,
        limit: 10,
        order: :created_at_asc
      )

    # Oldest first
    first_id = hd(docs).doc_id |> Content.published_id()
    last_id = List.last(docs).doc_id |> Content.published_id()
    assert first_id == "dp-1"
    assert last_id == "dp-10"
  end
end
```

Run — expect at least the `limit=5` test to fail on the current post-merge implementation (it may return fewer than 5 rows since the merge happens after LIMIT).

```bash
cd api && MIX_ENV=test mix test test/barkpark/content_drafts_pagination_test.exs
```

- [ ] **Step 2: Rewrite `list_documents/3` draft branch**

Open `api/lib/barkpark/content.ex`. Find `list_documents/3`. Replace its body with the subquery version:

```elixir
  def list_documents(type, dataset, opts \\ []) do
    perspective = Keyword.get(opts, :perspective, :raw)
    filter_map = Keyword.get(opts, :filter_map, %{})
    limit = opts |> Keyword.get(:limit, 100) |> min(1000) |> max(1)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)
    order = Keyword.get(opts, :order, :updated_at_desc)

    base =
      Document
      |> where([d], d.type == ^type and d.dataset == ^dataset)
      |> apply_filter_map(filter_map)

    case perspective do
      :drafts -> list_with_drafts_merged(base, order, limit, offset)
      other -> list_linear(base, other, order, limit, offset)
    end
  end

  # Published / raw: straightforward filter + order + paginate.
  defp list_linear(query, perspective, order, limit, offset) do
    query
    |> apply_perspective(perspective)
    |> apply_order(order)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  # :drafts perspective: use a DISTINCT ON subquery to collapse each
  # pair of (drafts.X, X) into one row — preferring the draft — BEFORE
  # applying the user's ORDER BY / LIMIT / OFFSET. Without this, the
  # merge happened in Elixir after pagination, so `limit=10` could
  # return fewer than 10 rows when drafts and published overlapped.
  defp list_with_drafts_merged(query, order, limit, offset) do
    inner =
      from(d in query,
        distinct:
          fragment("regexp_replace(?, '^drafts\\.', '')", d.doc_id),
        order_by: [
          fragment("regexp_replace(?, '^drafts\\.', '')", d.doc_id),
          # drafts sort first within each published_id group so
          # DISTINCT ON picks them preferentially
          fragment("CASE WHEN ? LIKE 'drafts.%' THEN 0 ELSE 1 END", d.doc_id)
        ]
      )

    from(d in subquery(inner))
    |> apply_order(order)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end
```

Delete the now-dead `maybe_merge_drafts/2` function and its `maybe_merge_drafts(docs, _)` fallback clause — they are no longer called.

- [ ] **Step 3: Run tests — expect pass**

```bash
cd api && MIX_ENV=test mix test test/barkpark/content_drafts_pagination_test.exs
MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: 3 new tests passing, full suite 92 tests 0 failures.

If an existing test that exercised the `:drafts` perspective breaks (ordering of merged rows changed), update its assertions — the new SQL-level merge produces a strict ordering by `regexp_replace(doc_id, 'drafts.', '')` ASC on the inner query, then the outer ORDER BY re-sorts. Old behavior used Elixir's `Enum.group_by` which produced different tie-breaking.

- [ ] **Step 4: Commit**

```bash
git add api/lib/barkpark/content.ex api/test/barkpark/content_drafts_pagination_test.exs
git commit -m "feat(content): SQL-level draft/published merge via DISTINCT ON subquery"
```

---

### Task 8: Update docs for SQL-level draft merge

**Files:**
- Modify: `docs/api-v1.md`

- [ ] **Step 1: Remove the bullet**

In `docs/api-v1.md` § Known Limitations, delete the line:

```
- Draft/published merging (`perspective=drafts`) happens after `LIMIT`/`OFFSET`, so a page can return fewer than `limit` rows.
```

- [ ] **Step 2: Commit**

```bash
git add docs/api-v1.md
git commit -m "docs(v1): drop fixed pagination-before-merge limitation"
```

---

## Phase 4 — Rate limiting

### Task 9: `Barkpark.RateLimiter` ETS token bucket

**Files:**
- Create: `api/lib/barkpark/rate_limiter.ex`
- Create: `api/test/barkpark/rate_limiter_test.exs`
- Modify: `api/lib/barkpark/application.ex`

- [ ] **Step 1: Failing tests**

Create `api/test/barkpark/rate_limiter_test.exs`:

```elixir
defmodule Barkpark.RateLimiterTest do
  use ExUnit.Case, async: false
  alias Barkpark.RateLimiter

  setup do
    # Fresh table for each test so counts are deterministic
    :ets.delete_all_objects(:barkpark_rate_limiter)
    :ok
  end

  test "first request for a new key is allowed and creates a bucket" do
    assert RateLimiter.check({:token, "new-key"}, capacity: 5, refill_per_sec: 1.0) == :ok
  end

  test "capacity requests are allowed in a burst, N+1 is rate-limited" do
    key = {:token, "burst-test"}

    for _ <- 1..5 do
      assert RateLimiter.check(key, capacity: 5, refill_per_sec: 1.0) == :ok
    end

    assert RateLimiter.check(key, capacity: 5, refill_per_sec: 1.0) == :rate_limited
  end

  test "different keys have independent buckets" do
    assert RateLimiter.check({:token, "a"}, capacity: 1, refill_per_sec: 0.0) == :ok
    assert RateLimiter.check({:token, "a"}, capacity: 1, refill_per_sec: 0.0) == :rate_limited
    assert RateLimiter.check({:token, "b"}, capacity: 1, refill_per_sec: 0.0) == :ok
  end

  test "bucket refills over time" do
    key = {:token, "refill-test"}
    # Capacity 2, refill 100/sec → after 20ms we should get 2 more tokens
    assert RateLimiter.check(key, capacity: 2, refill_per_sec: 100.0) == :ok
    assert RateLimiter.check(key, capacity: 2, refill_per_sec: 100.0) == :ok
    assert RateLimiter.check(key, capacity: 2, refill_per_sec: 100.0) == :rate_limited

    :timer.sleep(30)

    assert RateLimiter.check(key, capacity: 2, refill_per_sec: 100.0) == :ok
  end
end
```

- [ ] **Step 2: Implement the ETS token bucket**

Create `api/lib/barkpark/rate_limiter.ex`:

```elixir
defmodule Barkpark.RateLimiter do
  @moduledoc """
  Token-bucket rate limiter backed by an ETS table.

  One bucket per `key` (e.g. `{:token, "abc"}` or `{:ip, "1.2.3.4"}`).
  Each bucket holds up to `capacity` tokens and refills at
  `refill_per_sec` tokens per second. Each request consumes one token;
  if the bucket is empty, the request is rate-limited.

  The ETS table is created at application boot via `start_link/1` and
  lives for the process lifetime. Operations are lock-free reads +
  `:ets.insert/2` writes — there's a small race window where two
  requests might both read a bucket with ≥1 tokens and both succeed,
  over-spending by one. For the purpose of throttling abusive clients
  this is acceptable; tightening would require `:ets.update_counter/3`
  with integer buckets.

  Use the default `capacity` / `refill_per_sec` in production; tests
  pass explicit options to keep assertions deterministic.
  """

  @table :barkpark_rate_limiter

  @default_capacity 200
  # 200 tokens per minute → ~3.33 per second
  @default_refill_per_sec 200.0 / 60.0

  def start_link(_opts \\ []) do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        :ok
    end

    # Return a valid child spec result so Application's supervisor
    # accepts this as a child.
    {:ok, self()}
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @type key :: {:token, String.t()} | {:ip, String.t()}
  @type opts :: [capacity: pos_integer(), refill_per_sec: float()]

  @spec check(key(), opts()) :: :ok | :rate_limited
  def check(key, opts \\ []) do
    capacity = Keyword.get(opts, :capacity, @default_capacity)
    refill = Keyword.get(opts, :refill_per_sec, @default_refill_per_sec)
    now_ms = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [] ->
        :ets.insert(@table, {key, capacity - 1.0, now_ms})
        :ok

      [{^key, tokens, last_ms}] ->
        elapsed_s = (now_ms - last_ms) / 1000
        refilled = min(capacity * 1.0, tokens + elapsed_s * refill)

        if refilled >= 1.0 do
          :ets.insert(@table, {key, refilled - 1.0, now_ms})
          :ok
        else
          :rate_limited
        end
    end
  end
end
```

- [ ] **Step 3: Register the ETS table in the Application supervisor**

Open `api/lib/barkpark/application.ex`. Find the children list and add `Barkpark.RateLimiter` as the first child (it has no deps on other supervised processes):

```elixir
  def start(_type, _args) do
    children = [
      Barkpark.RateLimiter,           # ← add this line
      BarkparkWeb.Telemetry,
      Barkpark.Repo,
      # ...rest
    ]
    # ...
  end
```

- [ ] **Step 4: Run tests — expect pass**

```bash
cd api && MIX_ENV=test mix test test/barkpark/rate_limiter_test.exs
MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: 4 new tests passing, full suite 96 tests 0 failures.

- [ ] **Step 5: Commit**

```bash
git add api/lib/barkpark/rate_limiter.ex api/lib/barkpark/application.ex api/test/barkpark/rate_limiter_test.exs
git commit -m "feat(limiter): Barkpark.RateLimiter ETS token bucket"
```

---

### Task 10: `RateLimit` plug + `rate_limited` error code + contract test

**Files:**
- Create: `api/lib/barkpark_web/plugs/rate_limit.ex`
- Modify: `api/lib/barkpark/content/errors.ex`
- Modify: `api/lib/barkpark_web/router.ex`
- Create: `api/test/barkpark_web/contract/rate_limit_test.exs`

- [ ] **Step 1: Add `rate_limited` to `Content.Errors`**

In `api/lib/barkpark/content/errors.ex`, add a clause to `to_envelope/1`:

```elixir
  def to_envelope({:error, :rate_limited}),
    do: %{code: "rate_limited", message: "rate limit exceeded", status: 429}
```

Place it near the other error-atom clauses.

- [ ] **Step 2: Create the `RateLimit` plug**

Create `api/lib/barkpark_web/plugs/rate_limit.ex`:

```elixir
defmodule BarkparkWeb.Plugs.RateLimit do
  @moduledoc """
  HTTP rate-limit plug for `/v1/*` routes.

  Derives a bucket key from the request: `{:token, <value>}` if an
  `Authorization: Bearer` header is present, otherwise `{:ip, <remote>}`.
  Calls `Barkpark.RateLimiter.check/2`; on `:ok` passes through, on
  `:rate_limited` halts with the v1 structured error envelope, HTTP
  429, and a `Retry-After: 60` header.

  Configuration via plug opts: `capacity` and `refill_per_sec` override
  the library defaults (200 req/min). Routes that need different
  limits can use a separate pipeline with different opts.
  """

  import Plug.Conn

  alias Barkpark.{Content.Errors, RateLimiter}

  def init(opts), do: opts

  def call(conn, opts) do
    key = conn_key(conn)

    case RateLimiter.check(key, opts) do
      :ok ->
        conn

      :rate_limited ->
        env = Errors.to_envelope({:error, :rate_limited})

        conn
        |> put_resp_header("retry-after", "60")
        |> put_status(env.status)
        |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
        |> halt()
    end
  end

  defp conn_key(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:token, token}
      _ -> {:ip, conn.remote_ip |> :inet.ntoa() |> to_string()}
    end
  end
end
```

- [ ] **Step 3: Plug it into the `:api` pipeline**

In `api/lib/barkpark_web/router.ex`, find the `pipeline :api do` block and add the plug. If there's no pipeline `:api` yet, look for `pipe_through :api` — the pipeline is defined at the top. Add:

```elixir
  pipeline :api do
    plug :accepts, ["json"]
    plug BarkparkWeb.Plugs.RateLimit
  end
```

- [ ] **Step 4: Contract test**

Create `api/test/barkpark_web/contract/rate_limit_test.exs`:

```elixir
defmodule BarkparkWeb.Contract.RateLimitTest do
  use BarkparkWeb.ConnCase, async: false

  setup do
    # Flush the limiter so earlier test runs don't affect us
    :ets.delete_all_objects(:barkpark_rate_limiter)
    :ok
  end

  test "burst of 201 requests hits the 429 on the 201st", %{conn: _conn} do
    # ConnCase's `conn` has a fresh remote_ip per test — use a shared
    # conn to keep the same bucket key.
    base_conn = Phoenix.ConnTest.build_conn()

    # Hit a public endpoint 200 times (default capacity) — all should pass.
    # Use a path that 404s cheaply (schema won't exist) so we don't
    # actually query docs.
    for _ <- 1..200 do
      resp = get(base_conn, "/v1/data/query/ratelimit_test/nosuch")
      # Either 200 or 404 is fine — we're testing that we got PAST the
      # rate-limit plug. 429 would mean we got blocked early.
      refute resp.status == 429
    end

    # 201st request should be rate-limited
    resp = get(base_conn, "/v1/data/query/ratelimit_test/nosuch")
    assert resp.status == 429
    assert get_resp_header(resp, "retry-after") == ["60"]
    body = Jason.decode!(resp.resp_body)
    assert body["error"]["code"] == "rate_limited"
  end
end
```

Run — expect fail:

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/contract/rate_limit_test.exs
```

- [ ] **Step 5: Run the full suite**

```bash
cd api && MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: 97 tests, 0 failures.

If tests in other files start failing because they're now rate-limited, the ETS bucket is shared across tests. Fix by adding `:ets.delete_all_objects(:barkpark_rate_limiter)` to the `setup` of any other contract test that makes many requests. The RateLimiterTest already does this.

- [ ] **Step 6: Commit**

```bash
git add api/lib/barkpark/content/errors.ex api/lib/barkpark_web/plugs/rate_limit.ex api/lib/barkpark_web/router.ex api/test/barkpark_web/contract/rate_limit_test.exs
git commit -m "feat(api): rate_limit plug on /v1/* routes + rate_limited error code"
```

---

### Task 11: Update docs + API Tester for rate limiting

**Files:**
- Modify: `docs/api-v1.md`
- Modify: `api/lib/barkpark/api_tester/endpoints.ex`
- Modify: `api/lib/barkpark_web/live/studio/api_tester_live.ex`

- [ ] **Step 1: Update error codes table in docs**

In `docs/api-v1.md`, find the `## Error Codes` table and add a new row at the bottom:

```
| `rate_limited` | 429 | Too many requests from this token/IP. Retry after the `Retry-After` header's value |
```

Add a new section `## Rate Limiting` near the end:

```markdown
## Rate Limiting

All `/v1/*` endpoints are rate-limited per token (when present) or per IP. Default limit: **200 requests per minute** with a token-bucket replenishment model. When a client exceeds the limit, the response is:

    HTTP/1.1 429 Too Many Requests
    Content-Type: application/json
    Retry-After: 60

    {
      "error": {
        "code": "rate_limited",
        "message": "rate limit exceeded"
      }
    }

Clients should honor the `Retry-After` header and back off. The `@barkpark/client` SDK retries `rate_limited` automatically with exponential backoff (TODO: add this).
```

Remove from § Known Limitations the line:

```
- Rate limiting is not enforced at the HTTP layer.
```

- [ ] **Step 2: Update the Known Limitations reference page in the API Tester**

Open `api/lib/barkpark_web/live/studio/api_tester_live.ex`. Find `defp render_reference(assigns, :known_limitations) do` and replace its body. Since the only remaining "quirk" is the shallow reference expansion depth, replace the bullet list with just that one item:

```elixir
  defp render_reference(assigns, :known_limitations) do
    ~H"""
    <p class="api-description">The v1 contract as shipped. Future limitations may be added to this list as they're discovered.</p>

    <div class="api-section">v1.0 quirks</div>
    <ul class="api-quirks-list">
      <li>Reference expansion is <strong>depth 1 only</strong>: a referenced doc's own reference fields stay as raw id strings. Issue multiple queries for deeper chains.</li>
    </ul>
    <style>
      .api-quirks-list {
        list-style: disc; padding-left: 20px; margin: 0;
        font-size: 13px; color: var(--fg-muted); line-height: 1.7;
      }
      .api-quirks-list li { margin-bottom: 4px; }
    </style>
    """
  end
```

- [ ] **Step 3: Run tests**

```bash
cd api && MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: 97 tests, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add docs/api-v1.md api/lib/barkpark/api_tester/endpoints.ex api/lib/barkpark_web/live/studio/api_tester_live.ex
git commit -m "docs(v1): rate limiting documented; shrink known limitations to 1 item"
```

---

## Phase 5 — Merge + deploy + verify

### Task 12: Final smoke + deploy

**Files:** None.

- [ ] **Step 1: Full test suite**

```bash
cd api && MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: 97 tests, 0 failures.

- [ ] **Step 2: Merge branch**

```bash
cd /root/barkpark && git checkout main && git merge --ff-only v1-known-limitations 2>&1 | tail -5
git push origin main
```

- [ ] **Step 3: Deploy**

```bash
cd /opt/barkpark && git pull 2>&1 | tail -10
systemctl is-active barkpark
```

- [ ] **Step 4: Runner battery against live prod**

```bash
cd /opt/barkpark/api && export PATH="/root/.asdf/bin:/root/.asdf/shims:$PATH" && set -a && source /opt/barkpark/.env && set +a && MIX_ENV=prod mix run -e '
alias Barkpark.ApiTester.{Endpoints, Runner}
endpoints = Endpoints.all("production") |> Enum.filter(&(&1.kind == :endpoint && &1[:runnable] != false && &1[:expect] != nil))
IO.puts("")
for ep <- endpoints do
  path_values = for p <- ep.path_params, into: %{}, do: {p.name, to_string(p.default)}
  query_values = for p <- ep.query_params, into: %{}, do: {p.name, to_string(p.default)}
  body_text = if ep[:body_example], do: Jason.encode!(ep.body_example), else: ""
  form_state = Map.merge(path_values, query_values) |> Map.put("_body_text", body_text)
  req = Runner.build_request(ep, form_state, %{token: "barkpark-dev-token", base: "http://localhost:4000"})
  legacy = %{id: ep.id, method: req.method, path: String.replace_prefix(req.url, "http://localhost:4000", ""), headers: req.headers, body: (case req.body_text do "" -> nil; nil -> nil; txt -> case Jason.decode(txt) do {:ok, d} -> d; _ -> nil end end), expect: ep[:expect]}
  result = Runner.run(legacy)
  IO.puts("[#{result.verdict |> to_string |> String.upcase |> String.pad_trailing(5)}] HTTP #{String.pad_leading(Integer.to_string(result.status), 3)} #{String.pad_leading(Integer.to_string(result.duration_ms), 4)}ms  #{ep.label}")
end
' 2>&1 | grep -E "PASS|FAIL|ERROR"
```
Expected: **14/14** PASS (the 12 previously green + 2 new: `Expand references`, `Filter operators`).

- [ ] **Step 5: Manual smoke of the new features against public IP**

```bash
B="http://89.167.28.206"

echo "=== Reference expansion (depth 1) ==="
curl -s "$B/v1/data/query/production/post?limit=1&expand=true" | python3 -m json.tool | head -20

echo
echo "=== Filter operator: contains ==="
curl -s "$B/v1/data/query/production/post?filter%5Btitle%5D%5Bcontains%5D=post&limit=3" | python3 -c "import sys,json; d=json.load(sys.stdin); print('count:', d['count'])"

echo
echo "=== Rate limit header ==="
curl -sI "$B/v1/data/query/production/post?limit=1" | grep -i retry-after || echo "  (no retry-after — under limit, good)"
```

- [ ] **Step 6: Browser sanity check**

Open `http://89.167.28.206/studio/production/api-tester`:
1. Click "Query → Expand references" → run → response shows inlined author/category objects
2. Click "Query → Filter operators" → run → response shows filtered docs
3. Click "Reference → Known limitations" → the list should show just 1 item (reference expansion depth)

- [ ] **Step 7: No commit if smoke passes**

---

## Self-Review

**1. Spec coverage:**

- Reference expansion (`?expand=true|field1,field2`) → Tasks 1, 2, 3 ✓
- Filter operators (eq/in/contains/gt/gte/lt/lte) → Tasks 4, 5, 6 ✓
- SQL-level draft merge → Task 7, 8 ✓
- HTTP rate limiting (per-token + per-IP bucket, 200/min, 429 + Retry-After, rate_limited error code) → Tasks 9, 10, 11 ✓
- Docs updated across all four → Tasks 3, 6, 8, 11 ✓
- API Tester updated → Tasks 3, 6, 11 ✓
- Merge + deploy + live verification → Task 12 ✓

**Gaps I'm explicitly accepting:**
- Expansion is depth 1 only; deeper chains require multiple queries. Documented in the Known Limitations reference page and `docs/api-v1.md`.
- Filter operator validation: unknown operators (`[bogus]=x`) are silently ignored rather than returning `validation_failed`. Adding a validation layer is a Phase-6 follow-up.
- Rate limiter race window: bursts under the capacity might over-spend by a handful of tokens. Acceptable for throttling abusive clients; would need `update_counter` with integer math for strict correctness.
- SDK retry-on-429 is mentioned in the docs as a TODO — `@barkpark/client` doesn't yet auto-retry rate-limited responses.

**2. Placeholder scan:** No TBD / TODO / "similar to" / "handle edge cases" in implementation steps. Every step has the actual code or command.

**3. Type consistency:**
- `Content.Expand.expand/3` signature consistent across Task 1 (definition), Task 2 (call site in QueryController).
- `Content.apply_filter_map/2` (now supporting operator maps) consistent across Task 4 (implementation) and Task 5 (caller in QueryController).
- `Barkpark.RateLimiter.check/2` signature consistent across Task 9 (definition), Task 10 (plug caller). Options keyword (`capacity`, `refill_per_sec`) consistent.
- `rate_limited` error code name consistent across Task 10 (Errors module, plug, test), Task 11 (docs).
- `filter_map` value shape: Task 4's tests use `%{"title" => %{"eq" => "x"}}`; Task 5's `normalize_filter_map/1` produces the same shape; Task 4's `apply_filter_map/2` consumes it. ✓

---

## Execution

**Plan complete and saved to `docs/superpowers/plans/2026-04-15-v1-known-limitations.md`.**

**Two execution options:**

1. **Subagent-Driven (recommended)** — 12 tasks across 5 phases, one commit per task. Each phase is independently shippable — Phase 1 alone closes reference expansion, Phase 4 alone closes rate limiting, etc. If something goes wrong mid-plan, everything up to that point is already merged.

2. **Inline Execution** — run in this session with checkpoints at each phase boundary.

Which approach?
