# API Docs + Playground Pane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `/studio/:dataset/api-tester` into a three-column docs + playground for every `/v1` endpoint — one data structure describes the entire API, and the LiveView renders form-driven playgrounds + reference docs from it. Replaces the 13 hand-written test cases with a generative architecture.

**Architecture:** New `Barkpark.ApiTester.Endpoints` module is the single source of truth — each entry carries method, path template, auth level, description, typed param list, example body, response shape, and possible errors. `Runner.build_request/3` consumes an endpoint spec + form state + config to produce a concrete `{method, url, headers, body}` request; `Runner.run/1` is unchanged. The LiveView grows from two columns to three (nav / docs+playground / response), renders per-endpoint form fields from the param list, adds a token field in the pane topbar, and gains a "Copy as curl" button that builds the command client-side from the current form state.

**Tech Stack:** Elixir 1.18, Phoenix LiveView 1.0, `Req` (already in deps). No new deps.

**Scope note:** This plan entirely replaces `Barkpark.ApiTester.TestCases` with `Barkpark.ApiTester.Endpoints`. The test file `api/test/barkpark/api_tester/test_cases_test.exs` is renamed to `endpoints_test.exs`. Schema write endpoints (`POST /v1/schemas/:dataset`, `DELETE /v1/schemas/:dataset/:name`) are **docs-only** — no playground Run button, because a bad click would wreck the running Studio's schema state. Same for SSE listen. Envelope / error codes / known limitations are docs-only reference entries.

**Worktree:** Create a fresh isolated worktree at `.worktrees/api-docs-playground` from `main`. Do not touch `/root/barkpark` directly during implementation.

**Golden rule:** Every task ends with a green full test suite. No task "passes" if `MIX_ENV=test mix test` has even one failure.

---

## File Structure

### New files

| File | Responsibility |
|---|---|
| `api/lib/barkpark/api_tester/endpoints.ex` | Single source of truth — ~20 endpoint specs covering every `/v1` route, 8 mutation kinds, and 3 reference pages (envelope, errors, limitations). Pure data + `all/1` and `find/2` helpers. |
| `api/test/barkpark/api_tester/endpoints_test.exs` | Unit tests for `Endpoints.all/1` and `Endpoints.find/2`, replaces the old `test_cases_test.exs`. |

### Modified files

| File | Change |
|---|---|
| `api/lib/barkpark/api_tester/runner.ex` | Add `build_request/3` that takes an endpoint spec + form state + config, returns a map `{method, url, headers, body_text}`. Keep `run/2` as-is — it already accepts a "case map" and the LiveView can pass a built request through it. |
| `api/lib/barkpark_web/live/studio/api_tester_live.ex` | Full rewrite of `render/1` to three-column layout. `mount/3` loads endpoints, seeds initial form state for the selected endpoint, tracks `token` and `form_state_by_id` assigns. New handlers: `form-change`, `run`, `copy-curl-clicked`, `token-change`. Runner remains the execution path. |

### Deleted files

- `api/lib/barkpark/api_tester/test_cases.ex` (replaced by `endpoints.ex`)
- `api/test/barkpark/api_tester/test_cases_test.exs` (replaced by `endpoints_test.exs`)

### Files touched but behavior unchanged

`router.ex`, `app.html.heex`, `nav.ex`, `dataset_switcher.ex`, all other Studio LiveViews — **do not edit**. The api-tester route and nav tab are already live from the dataset-switcher plan.

---

## Phase 1 — Data layer

### Task 1: `Endpoints` module — skeleton + first 3 endpoints

**Files:**
- Create: `api/lib/barkpark/api_tester/endpoints.ex`
- Create: `api/test/barkpark/api_tester/endpoints_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
defmodule Barkpark.ApiTester.EndpointsTest do
  use ExUnit.Case, async: true
  alias Barkpark.ApiTester.Endpoints

  test "all/1 returns endpoints for the given dataset" do
    endpoints = Endpoints.all("staging")
    assert is_list(endpoints)
    assert length(endpoints) >= 3
  end

  test "find/2 returns the query-list endpoint with a dataset-interpolated path" do
    ep = Endpoints.find("staging", "query-list")
    assert ep.kind == :endpoint
    assert ep.method == "GET"
    assert ep.path_template == "/v1/data/query/{dataset}/{type}"
    assert ep.auth == :public
    assert ep.category == "Query"
  end

  test "find/2 returns nil for unknown id" do
    assert Endpoints.find("staging", "bogus") == nil
  end

  test "query-single endpoint has path and doc_id params" do
    ep = Endpoints.find("production", "query-single")
    param_names = Enum.map(ep.path_params, & &1.name)
    assert "dataset" in param_names
    assert "type" in param_names
    assert "doc_id" in param_names
  end

  test "mutate-create is under Mutate category and has token auth" do
    ep = Endpoints.find("production", "mutate-create")
    assert ep.category == "Mutate"
    assert ep.auth == :token
    assert ep.method == "POST"
    assert is_map(ep.body_example)
  end
end
```

- [ ] **Step 2: Run — expect fail**

```bash
cd api && MIX_ENV=test mix test test/barkpark/api_tester/endpoints_test.exs
```
Expected: FAIL — `Endpoints is undefined`.

- [ ] **Step 3: Implement the module with 3 endpoints**

Create `api/lib/barkpark/api_tester/endpoints.ex`:

```elixir
defmodule Barkpark.ApiTester.Endpoints do
  @moduledoc """
  Single source of truth for the Studio API Docs + Playground pane.

  Each entry describes an endpoint (or a reference page) with enough
  metadata to render both the documentation column AND the interactive
  playground form: method, path template, auth level, typed params,
  example body, response shape, and possible errors.

  The `Barkpark.ApiTester.Runner` consumes this together with form
  state from the LiveView to build concrete HTTP requests.

  ## Spec shape

      %{
        id:            "query-list",              # stable slug
        category:      "Query",                   # nav group heading
        label:         "List documents",          # short name in nav
        kind:          :endpoint | :reference,    # :endpoint has a playground
        auth:          :public | :token | :admin, # controls token badge in docs
        method:        "GET" | "POST" | ...,
        path_template: "/v1/data/query/{dataset}/{type}",
        description:   "Short paragraph (< 200 chars).",
        path_params:   [param_spec()],
        query_params:  [param_spec()],
        body_example:  nil | map(),               # JSON body seed for the form
        response_shape: "```json\\n{ ... }\\n```",  # abbreviated example
        possible_errors: [atom()],                # matches Errors.to_envelope codes
        expect:        {integer(), atom()} | nil  # verdict predicate (see Runner)
      }

  Reference entries set `kind: :reference` and carry a `render_key`
  atom instead of params/body; the LiveView has a clause per render_key.

  ## Param spec

      %{
        name:     "limit",
        type:     :string | :integer | :select | :json,
        default:  "10",
        options:  [...]     # for :select
        notes:    "Integer, min 1, max 1000"
      }
  """

  @spec all(String.t()) :: [map()]
  def all(dataset) when is_binary(dataset) do
    [
      query_list(dataset),
      query_single(dataset),
      mutate_create(dataset)
    ]
  end

  @spec find(String.t(), String.t()) :: map() | nil
  def find(dataset, id) when is_binary(dataset) and is_binary(id) do
    Enum.find(all(dataset), &(&1.id == id))
  end

  # ── Query endpoints ──────────────────────────────────────────────────

  defp query_list(dataset) do
    %{
      id: "query-list",
      category: "Query",
      label: "List documents",
      kind: :endpoint,
      auth: :public,
      method: "GET",
      path_template: "/v1/data/query/{dataset}/{type}",
      description:
        "List documents of a given type. Returns 404 if the schema's visibility is \"private\".",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"},
        %{name: "type", type: :string, default: "post", notes: "Document type name"}
      ],
      query_params: [
        %{
          name: "perspective",
          type: :select,
          default: "published",
          options: ["published", "drafts", "raw"],
          notes: "published (default) / drafts / raw"
        },
        %{name: "limit", type: :integer, default: "10", notes: "Integer, min 1, max 1000"},
        %{name: "offset", type: :integer, default: "0", notes: "Integer, min 0"},
        %{
          name: "order",
          type: :select,
          default: "_updatedAt:desc",
          options: [
            "_updatedAt:desc",
            "_updatedAt:asc",
            "_createdAt:desc",
            "_createdAt:asc"
          ],
          notes: "Sort key and direction"
        },
        %{name: "filter[title]", type: :string, default: "", notes: "Optional exact-match on title"}
      ],
      body_example: nil,
      response_shape: """
      {
        "perspective": "published",
        "documents": [ /* envelope, ... */ ],
        "count": 3,
        "limit": 10,
        "offset": 0
      }
      """,
      possible_errors: [:not_found],
      expect: {200, :envelope_has_reserved_keys}
    }
  end

  defp query_single(dataset) do
    %{
      id: "query-single",
      category: "Query",
      label: "Get single document",
      kind: :endpoint,
      auth: :public,
      method: "GET",
      path_template: "/v1/data/doc/{dataset}/{type}/{doc_id}",
      description:
        "Fetch a single document by id. Returns the envelope at the top level. 404 if missing or schema is private.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"},
        %{name: "type", type: :string, default: "post", notes: "Document type name"},
        %{name: "doc_id", type: :string, default: "p1", notes: "Full document id (may include drafts. prefix)"}
      ],
      query_params: [],
      body_example: nil,
      response_shape: """
      {
        "_id": "p1",
        "_type": "post",
        "_rev": "a3f8c2d1...",
        "_draft": false,
        "_publishedId": "p1",
        "_createdAt": "2026-04-12T09:11:20Z",
        "_updatedAt": "2026-04-12T10:03:45Z",
        "title": "Hello World"
      }
      """,
      possible_errors: [:not_found],
      expect: {200, :envelope_top_level}
    }
  end

  # ── Mutate endpoints ─────────────────────────────────────────────────

  defp mutate_create(dataset) do
    %{
      id: "mutate-create",
      category: "Mutate",
      label: "create",
      kind: :endpoint,
      auth: :token,
      method: "POST",
      path_template: "/v1/data/mutate/{dataset}",
      description:
        "Create a new draft. Errors with code \"conflict\" if a draft already exists at the given id.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}
      ],
      query_params: [],
      body_example: %{
        "mutations" => [
          %{
            "create" => %{
              "_type" => "post",
              "_id" => "playground-create-1",
              "title" => "From the playground",
              "body" => "Hello from docs + playground"
            }
          }
        ]
      },
      response_shape: """
      {
        "transactionId": "d4e5f6a7...",
        "results": [
          { "id": "drafts.playground-create-1", "operation": "create", "document": { /* envelope */ } }
        ]
      }
      """,
      possible_errors: [:conflict, :validation_failed, :unauthorized, :malformed],
      expect: {200, :mutate_result_has_envelope}
    }
  end
end
```

- [ ] **Step 4: Run tests — expect pass**

```bash
cd api && MIX_ENV=test mix test test/barkpark/api_tester/endpoints_test.exs
```
Expected: 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add api/lib/barkpark/api_tester/endpoints.ex api/test/barkpark/api_tester/endpoints_test.exs
git commit -m "feat(api-tester): Endpoints module — query+mutate-create seeds"
```

---

### Task 2: Fill out the 7 remaining mutation kinds

**Files:**
- Modify: `api/lib/barkpark/api_tester/endpoints.ex`
- Modify: `api/test/barkpark/api_tester/endpoints_test.exs`

- [ ] **Step 1: Add failing tests for each kind**

Append to `endpoints_test.exs`:

```elixir
  test "all 8 mutation kinds are registered" do
    ids = Endpoints.all("production") |> Enum.map(& &1.id)

    for kind <- ~w(create createOrReplace createIfNotExists patch publish unpublish discardDraft delete) do
      assert "mutate-#{kind}" in ids, "missing mutate-#{kind}"
    end
  end

  test "mutate-patch body example includes ifRevisionID reserved slot" do
    ep = Endpoints.find("production", "mutate-patch")
    [patch_mutation] = ep.body_example["mutations"]
    patch_body = patch_mutation["patch"]
    assert Map.has_key?(patch_body, "ifRevisionID")
    assert Map.has_key?(patch_body, "set")
  end

  test "mutate-publish expects operation publish" do
    ep = Endpoints.find("production", "mutate-publish")
    [pub] = ep.body_example["mutations"]
    assert Map.has_key?(pub, "publish")
    assert pub["publish"]["type"] == "post"
  end
```

- [ ] **Step 2: Run — expect fail**

```bash
cd api && MIX_ENV=test mix test test/barkpark/api_tester/endpoints_test.exs
```
Expected: 3 new failures, 5 existing passes.

- [ ] **Step 3: Add the 7 remaining mutation kinds to `all/1`**

In `api/lib/barkpark/api_tester/endpoints.ex`, update `all/1` to include them, then add the private helper functions. Replace the `all/1` function body:

```elixir
def all(dataset) when is_binary(dataset) do
  [
    query_list(dataset),
    query_single(dataset),
    mutate_create(dataset),
    mutate_create_or_replace(dataset),
    mutate_create_if_not_exists(dataset),
    mutate_patch(dataset),
    mutate_publish(dataset),
    mutate_unpublish(dataset),
    mutate_discard_draft(dataset),
    mutate_delete(dataset)
  ]
end
```

Add these 7 private helpers at the bottom of the Mutate section:

```elixir
defp mutate_create_or_replace(dataset) do
  %{
    id: "mutate-createOrReplace",
    category: "Mutate",
    label: "createOrReplace",
    kind: :endpoint,
    auth: :token,
    method: "POST",
    path_template: "/v1/data/mutate/{dataset}",
    description:
      "Upsert. Creates a new draft or overwrites the existing draft at the given id.",
    path_params: [%{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}],
    query_params: [],
    body_example: %{
      "mutations" => [
        %{
          "createOrReplace" => %{
            "_type" => "post",
            "_id" => "playground-upsert-1",
            "title" => "Upserted",
            "body" => "This overwrites if it already exists"
          }
        }
      ]
    },
    response_shape: """
    {
      "transactionId": "...",
      "results": [
        { "id": "drafts.playground-upsert-1", "operation": "createOrReplace", "document": { /* envelope */ } }
      ]
    }
    """,
    possible_errors: [:validation_failed, :unauthorized, :malformed],
    expect: {200, :mutate_result_has_envelope}
  }
end

defp mutate_create_if_not_exists(dataset) do
  %{
    id: "mutate-createIfNotExists",
    category: "Mutate",
    label: "createIfNotExists",
    kind: :endpoint,
    auth: :token,
    method: "POST",
    path_template: "/v1/data/mutate/{dataset}",
    description:
      "Create only if no draft exists at the given id. If one already exists, returns it with operation \"noop\".",
    path_params: [%{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}],
    query_params: [],
    body_example: %{
      "mutations" => [
        %{
          "createIfNotExists" => %{
            "_type" => "post",
            "_id" => "playground-ifne-1",
            "title" => "Create once"
          }
        }
      ]
    },
    response_shape: """
    {
      "transactionId": "...",
      "results": [
        { "id": "drafts.playground-ifne-1", "operation": "create" | "noop", "document": { /* envelope */ } }
      ]
    }
    """,
    possible_errors: [:validation_failed, :unauthorized, :malformed],
    expect: {200, :mutate_result_has_envelope}
  }
end

defp mutate_patch(dataset) do
  %{
    id: "mutate-patch",
    category: "Mutate",
    label: "patch",
    kind: :endpoint,
    auth: :token,
    method: "POST",
    path_template: "/v1/data/mutate/{dataset}",
    description:
      "Merge `set` fields into an existing document. Optional `ifRevisionID` enforces optimistic concurrency — a stale rev returns 409 rev_mismatch. Result operation is \"update\".",
    path_params: [%{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}],
    query_params: [],
    body_example: %{
      "mutations" => [
        %{
          "patch" => %{
            "id" => "drafts.playground-upsert-1",
            "type" => "post",
            "ifRevisionID" => "",
            "set" => %{"title" => "Revised title", "status" => "draft"}
          }
        }
      ]
    },
    response_shape: """
    {
      "transactionId": "...",
      "results": [
        { "id": "drafts.playground-upsert-1", "operation": "update", "document": { /* envelope */ } }
      ]
    }
    """,
    possible_errors: [:not_found, :rev_mismatch, :validation_failed, :unauthorized, :malformed],
    expect: {200, :mutate_result_has_envelope}
  }
end

defp mutate_publish(dataset) do
  %{
    id: "mutate-publish",
    category: "Mutate",
    label: "publish",
    kind: :endpoint,
    auth: :token,
    method: "POST",
    path_template: "/v1/data/mutate/{dataset}",
    description: "Copy `drafts.<id>` to `<id>` and delete the draft.",
    path_params: [%{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}],
    query_params: [],
    body_example: %{
      "mutations" => [
        %{"publish" => %{"id" => "playground-upsert-1", "type" => "post"}}
      ]
    },
    response_shape: """
    {
      "transactionId": "...",
      "results": [
        { "id": "playground-upsert-1", "operation": "publish", "document": { /* envelope, _draft=false */ } }
      ]
    }
    """,
    possible_errors: [:not_found, :unauthorized, :malformed],
    expect: {200, :mutate_result_has_envelope}
  }
end

defp mutate_unpublish(dataset) do
  %{
    id: "mutate-unpublish",
    category: "Mutate",
    label: "unpublish",
    kind: :endpoint,
    auth: :token,
    method: "POST",
    path_template: "/v1/data/mutate/{dataset}",
    description: "Move `<id>` back to `drafts.<id>`.",
    path_params: [%{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}],
    query_params: [],
    body_example: %{
      "mutations" => [
        %{"unpublish" => %{"id" => "playground-upsert-1", "type" => "post"}}
      ]
    },
    response_shape: """
    {
      "transactionId": "...",
      "results": [
        { "id": "drafts.playground-upsert-1", "operation": "unpublish", "document": { /* envelope, _draft=true */ } }
      ]
    }
    """,
    possible_errors: [:not_found, :unauthorized, :malformed],
    expect: {200, :mutate_result_has_envelope}
  }
end

defp mutate_discard_draft(dataset) do
  %{
    id: "mutate-discardDraft",
    category: "Mutate",
    label: "discardDraft",
    kind: :endpoint,
    auth: :token,
    method: "POST",
    path_template: "/v1/data/mutate/{dataset}",
    description: "Delete `drafts.<id>` without touching the published document.",
    path_params: [%{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}],
    query_params: [],
    body_example: %{
      "mutations" => [
        %{"discardDraft" => %{"id" => "playground-upsert-1", "type" => "post"}}
      ]
    },
    response_shape: """
    {
      "transactionId": "...",
      "results": [
        { "id": "drafts.playground-upsert-1", "operation": "discardDraft", "document": { /* envelope of deleted draft */ } }
      ]
    }
    """,
    possible_errors: [:not_found, :unauthorized, :malformed],
    expect: {200, :mutate_result_has_envelope}
  }
end

defp mutate_delete(dataset) do
  %{
    id: "mutate-delete",
    category: "Mutate",
    label: "delete",
    kind: :endpoint,
    auth: :token,
    method: "POST",
    path_template: "/v1/data/mutate/{dataset}",
    description: "Delete both `<id>` and `drafts.<id>` if they exist.",
    path_params: [%{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}],
    query_params: [],
    body_example: %{
      "mutations" => [
        %{"delete" => %{"id" => "playground-upsert-1", "type" => "post"}}
      ]
    },
    response_shape: """
    {
      "transactionId": "...",
      "results": [
        { "id": "playground-upsert-1", "operation": "delete", "document": { /* envelope before delete */ } }
      ]
    }
    """,
    possible_errors: [:not_found, :unauthorized, :malformed],
    expect: {200, :mutate_result_has_envelope}
  }
end
```

- [ ] **Step 2: Run tests — expect pass**

```bash
cd api && MIX_ENV=test mix test test/barkpark/api_tester/endpoints_test.exs
```
Expected: 8 tests, 0 failures.

- [ ] **Step 3: Commit**

```bash
git add api/lib/barkpark/api_tester/endpoints.ex api/test/barkpark/api_tester/endpoints_test.exs
git commit -m "feat(api-tester): 8 mutation kinds in Endpoints"
```

---

### Task 3: SSE + Schema endpoints + 3 reference pages

**Files:**
- Modify: `api/lib/barkpark/api_tester/endpoints.ex`
- Modify: `api/test/barkpark/api_tester/endpoints_test.exs`

- [ ] **Step 1: Failing tests**

Append to `endpoints_test.exs`:

```elixir
  test "listen-sse is docs-only (no playground, still :endpoint kind)" do
    ep = Endpoints.find("production", "listen-sse")
    assert ep.category == "Real-time"
    assert ep.auth == :token
    assert ep.method == "GET"
    assert ep.kind == :endpoint
    assert ep.expect == nil, "listen has no verdict predicate"
  end

  test "schemas-list and schemas-show both require admin auth" do
    list_ep = Endpoints.find("production", "schemas-list")
    show_ep = Endpoints.find("production", "schemas-show")
    assert list_ep.auth == :admin
    assert show_ep.auth == :admin
  end

  test "reference pages use :reference kind with a render_key" do
    envelope = Endpoints.find("production", "ref-envelope")
    errors = Endpoints.find("production", "ref-errors")
    limits = Endpoints.find("production", "ref-limits")

    for ep <- [envelope, errors, limits] do
      assert ep.kind == :reference
      assert is_atom(ep.render_key)
      assert ep.category == "Reference"
    end

    assert envelope.render_key == :envelope
    assert errors.render_key == :error_codes
    assert limits.render_key == :known_limitations
  end
```

- [ ] **Step 2: Run — expect fail**

```bash
cd api && MIX_ENV=test mix test test/barkpark/api_tester/endpoints_test.exs
```

- [ ] **Step 3: Extend `all/1` and add helpers**

Update `all/1`:

```elixir
def all(dataset) when is_binary(dataset) do
  [
    ref_envelope(),
    ref_error_codes(),
    ref_known_limitations(),
    query_list(dataset),
    query_single(dataset),
    mutate_create(dataset),
    mutate_create_or_replace(dataset),
    mutate_create_if_not_exists(dataset),
    mutate_patch(dataset),
    mutate_publish(dataset),
    mutate_unpublish(dataset),
    mutate_discard_draft(dataset),
    mutate_delete(dataset),
    listen_sse(dataset),
    schemas_list(dataset),
    schemas_show(dataset)
  ]
end
```

Add these helpers at the bottom of the module (above `end`):

```elixir
# ── Real-time ────────────────────────────────────────────────────────

defp listen_sse(dataset) do
  %{
    id: "listen-sse",
    category: "Real-time",
    label: "SSE listen",
    kind: :endpoint,
    auth: :token,
    method: "GET",
    path_template: "/v1/data/listen/{dataset}",
    description:
      "Server-Sent Events stream of mutations. Supply Last-Event-ID for resume. Docs-only here — the playground does not stream; use curl -N to try it from the command line.",
    path_params: [%{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}],
    query_params: [
      %{name: "lastEventId", type: :integer, default: "", notes: "Resume cursor (or use Last-Event-ID header)"}
    ],
    body_example: nil,
    response_shape: """
    event: welcome
    data: {"type":"welcome"}

    id: 42
    event: mutation
    data: {"eventId":42,"mutation":"create","type":"post","documentId":"drafts.hello","rev":"...","previousRev":null,"result":{...envelope...}}
    """,
    possible_errors: [:unauthorized],
    expect: nil
  }
end

# ── Schemas ──────────────────────────────────────────────────────────

defp schemas_list(dataset) do
  %{
    id: "schemas-list",
    category: "Schemas",
    label: "List schemas",
    kind: :endpoint,
    auth: :admin,
    method: "GET",
    path_template: "/v1/schemas/{dataset}",
    description:
      "Admin list of every schema in the dataset. Response carries _schemaVersion: 1.",
    path_params: [%{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}],
    query_params: [],
    body_example: nil,
    response_shape: """
    {
      "_schemaVersion": 1,
      "schemas": [
        { "name": "post", "title": "Post", "icon": "file-text", "visibility": "public", "fields": [ ... ] }
      ]
    }
    """,
    possible_errors: [:unauthorized, :forbidden],
    expect: {200, :schema_version_1}
  }
end

defp schemas_show(dataset) do
  %{
    id: "schemas-show",
    category: "Schemas",
    label: "Show schema",
    kind: :endpoint,
    auth: :admin,
    method: "GET",
    path_template: "/v1/schemas/{dataset}/{name}",
    description: "Admin fetch of a single schema by name.",
    path_params: [
      %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"},
      %{name: "name", type: :string, default: "post", notes: "Schema name"}
    ],
    query_params: [],
    body_example: nil,
    response_shape: """
    {
      "_schemaVersion": 1,
      "schema": {
        "name": "post", "title": "Post", "icon": "file-text",
        "visibility": "public", "fields": [ ... ]
      }
    }
    """,
    possible_errors: [:not_found, :unauthorized, :forbidden],
    expect: {200, :schema_version_1_show}
  }
end

# ── Reference pages (docs-only) ──────────────────────────────────────

defp ref_envelope do
  %{
    id: "ref-envelope",
    category: "Reference",
    label: "Document envelope",
    kind: :reference,
    render_key: :envelope,
    description: "Every document is returned as a flat JSON object with 7 reserved _-prefixed keys plus arbitrary user fields."
  }
end

defp ref_error_codes do
  %{
    id: "ref-errors",
    category: "Reference",
    label: "Error codes",
    kind: :reference,
    render_key: :error_codes,
    description: "All errors return {\"error\": {\"code\": \"...\", \"message\": \"...\"}} — 9 codes total."
  }
end

defp ref_known_limitations do
  %{
    id: "ref-limits",
    category: "Reference",
    label: "Known limitations",
    kind: :reference,
    render_key: :known_limitations,
    description: "6 quirks of v1 that may bite real clients."
  }
end
```

- [ ] **Step 4: Run tests — expect pass**

```bash
cd api && MIX_ENV=test mix test test/barkpark/api_tester/endpoints_test.exs
```
Expected: 11 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add api/lib/barkpark/api_tester/endpoints.ex api/test/barkpark/api_tester/endpoints_test.exs
git commit -m "feat(api-tester): SSE, schema list/show, reference pages"
```

---

## Phase 2 — Runner glue

### Task 4: `Runner.build_request/3`

**Files:**
- Modify: `api/lib/barkpark/api_tester/runner.ex`
- Create: `api/test/barkpark/api_tester/runner_build_test.exs`

- [ ] **Step 1: Failing test**

```elixir
defmodule Barkpark.ApiTester.RunnerBuildTest do
  use ExUnit.Case, async: true
  alias Barkpark.ApiTester.{Endpoints, Runner}

  test "build_request interpolates path_params and appends query_params" do
    ep = Endpoints.find("staging", "query-list")

    form_state = %{
      "dataset" => "staging",
      "type" => "post",
      "perspective" => "drafts",
      "limit" => "5",
      "offset" => "0",
      "order" => "_updatedAt:desc",
      "filter[title]" => "hello world"
    }

    req = Runner.build_request(ep, form_state, %{token: "tk", base: "http://localhost:4000"})

    assert req.method == "GET"
    assert String.starts_with?(req.url, "http://localhost:4000/v1/data/query/staging/post?")
    assert String.contains?(req.url, "perspective=drafts")
    assert String.contains?(req.url, "limit=5")
    assert String.contains?(req.url, "filter%5Btitle%5D=hello+world") or
             String.contains?(req.url, "filter%5Btitle%5D=hello%20world")
    assert req.body_text in [nil, ""]
  end

  test "build_request drops empty query_params" do
    ep = Endpoints.find("production", "query-list")
    form_state = %{"dataset" => "production", "type" => "post", "filter[title]" => ""}
    req = Runner.build_request(ep, form_state, %{token: "tk", base: "http://x"})
    refute String.contains?(req.url, "filter")
  end

  test "build_request attaches Authorization for :token and :admin endpoints" do
    create = Endpoints.find("production", "mutate-create")
    req =
      Runner.build_request(
        create,
        %{"dataset" => "production", "_body_text" => Jason.encode!(create.body_example)},
        %{token: "dev-tok", base: "http://x"}
      )

    assert {"Authorization", "Bearer dev-tok"} in req.headers
    assert {"Content-Type", "application/json"} in req.headers
    assert req.method == "POST"
    assert req.body_text == Jason.encode!(create.body_example)
  end

  test "build_request does NOT attach Authorization for :public endpoints" do
    list = Endpoints.find("production", "query-list")
    req = Runner.build_request(list, %{"dataset" => "production", "type" => "post"}, %{token: "dev-tok", base: "http://x"})
    refute Enum.any?(req.headers, fn {k, _} -> k == "Authorization" end)
  end
end
```

- [ ] **Step 2: Run — expect fail**

```bash
cd api && MIX_ENV=test mix test test/barkpark/api_tester/runner_build_test.exs
```
Expected: `Runner.build_request/3 is undefined`.

- [ ] **Step 3: Implement `build_request/3` in Runner**

Add to `api/lib/barkpark/api_tester/runner.ex` (at the top of the module, after `@default_base`):

```elixir
@doc """
Build a concrete HTTP request from an endpoint spec + form state + config.

Returns a map: %{method, url, headers, body_text}. Pass this directly to
run/1 (wrapped as a pseudo test-case map) or use the fields to render a
curl command.

- Path params are interpolated into `path_template` via `{name}` tokens.
- Query params with non-empty values become URL-encoded query string.
- `:token` / `:admin` endpoints get an Authorization header when
  `config.token` is non-empty.
- POST endpoints read `form_state["_body_text"]` (the raw JSON the
  playground textarea holds) and attach it as the body with a
  Content-Type: application/json header.
"""
@spec build_request(map(), map(), %{token: String.t(), base: String.t()}) :: map()
def build_request(endpoint, form_state, config) do
  base = Map.get(config, :base, @default_base)
  token = Map.get(config, :token, "")

  path = interpolate_path(endpoint.path_template, endpoint.path_params, form_state)
  query = build_query_string(endpoint.query_params || [], form_state)
  url = base <> path <> if(query == "", do: "", else: "?" <> query)

  headers =
    []
    |> maybe_add_auth(endpoint.auth, token)
    |> maybe_add_content_type(endpoint.method)

  body_text =
    if endpoint.method == "POST" do
      Map.get(form_state, "_body_text", "")
    else
      nil
    end

  %{method: endpoint.method, url: url, headers: headers, body_text: body_text}
end

defp interpolate_path(template, path_params, form_state) do
  Enum.reduce(path_params, template, fn %{name: name}, acc ->
    value = Map.get(form_state, name, "")
    String.replace(acc, "{#{name}}", URI.encode(value))
  end)
end

defp build_query_string(query_params, form_state) do
  query_params
  |> Enum.map(fn %{name: name} -> {name, Map.get(form_state, name, "")} end)
  |> Enum.reject(fn {_, v} -> v == "" end)
  |> URI.encode_query()
end

defp maybe_add_auth(headers, auth, token) when auth in [:token, :admin] and token not in [nil, ""] do
  [{"Authorization", "Bearer " <> token} | headers]
end
defp maybe_add_auth(headers, _, _), do: headers

defp maybe_add_content_type(headers, "POST"), do: [{"Content-Type", "application/json"} | headers]
defp maybe_add_content_type(headers, _), do: headers
```

- [ ] **Step 4: Run tests — expect pass**

```bash
cd api && MIX_ENV=test mix test test/barkpark/api_tester/runner_build_test.exs
```
Expected: 4 tests, 0 failures.

- [ ] **Step 5: Full suite sanity**

```bash
cd api && MIX_ENV=test mix test
```
Expected: all tests still green. The existing `Runner.run/2` API is unchanged, so nothing else should break.

- [ ] **Step 6: Commit**

```bash
git add api/lib/barkpark/api_tester/runner.ex api/test/barkpark/api_tester/runner_build_test.exs
git commit -m "feat(api-tester): Runner.build_request/3 for playground"
```

---

## Phase 3 — LiveView rewrite

### Task 5: Delete `TestCases`, migrate LiveView to load from `Endpoints`

**Files:**
- Delete: `api/lib/barkpark/api_tester/test_cases.ex`
- Delete: `api/test/barkpark/api_tester/test_cases_test.exs`
- Modify: `api/lib/barkpark_web/live/studio/api_tester_live.ex`

This task is a MECHANICAL swap — `TestCases` becomes `Endpoints`. Rendering stays largely the same; the three-column layout lands in Task 6. The goal here is to unship `TestCases` without breaking anything.

- [ ] **Step 1: Delete `test_cases.ex` and its test file**

```bash
rm api/lib/barkpark/api_tester/test_cases.ex
rm api/test/barkpark/api_tester/test_cases_test.exs
```

- [ ] **Step 2: Update `api_tester_live.ex`**

Replace every `TestCases` reference with `Endpoints`. Specifically:

1. Change `alias Barkpark.ApiTester.{Runner, TestCases}` → `alias Barkpark.ApiTester.{Endpoints, Runner}`.

2. In `mount/3`, replace `TestCases.all(dataset)` with `Endpoints.all(dataset)`.

3. In `handle_event("select", ...)`, replace `TestCases.find(socket.assigns.dataset, id)` with `Endpoints.find(socket.assigns.dataset, id)`.

4. In `handle_event("run", ...)`, same replacement.

5. In the HEEx template, replace `TestCases.find(@dataset, @selected_id)` with `Endpoints.find(@dataset, @selected_id)`.

6. In the HEEx template, the existing "rendering tc.method, tc.path, tc.description, tc.headers, tc.body" code needs a **minimal** tweak: `Endpoints` entries do not have a `path` field — they have `path_template` + `path_params` + `query_params`. For this task ONLY, render `@endpoint.path_template` in place of the old `tc.path`, and skip header/body rendering entirely (they'll return in Task 6). This keeps the pane visually stripped down for one commit.

7. The existing "Run" button in this task should call `Runner.run(endpoint)` — but endpoints no longer have the right shape. Introduce a temporary helper in the LiveView:

   ```elixir
   defp ep_to_legacy_case(endpoint, dataset, token) do
     req =
       Runner.build_request(endpoint, %{"dataset" => dataset, "type" => "post", "_body_text" => Jason.encode!(endpoint.body_example || %{})}, %{
         token: token,
         base: "http://localhost:4000"
       })

     %{
       id: endpoint.id,
       method: req.method,
       path: String.replace_prefix(req.url, "http://localhost:4000", ""),
       headers: req.headers,
       body: endpoint.body_example,
       expect: endpoint[:expect]
     }
   end
   ```

   This is a temporary bridge that Task 6 replaces with proper form-driven playground state.

8. `handle_event("run", ...)` becomes:

   ```elixir
   def handle_event("run", _, socket) do
     endpoint = Endpoints.find(socket.assigns.dataset, socket.assigns.selected_id)
     legacy = ep_to_legacy_case(endpoint, socket.assigns.dataset, "barkpark-dev-token")
     result = Runner.run(legacy)
     new_results = Map.put(socket.assigns.results_by_id, socket.assigns.selected_id, result)
     {:noreply, assign(socket, last_result: result, results_by_id: new_results)}
   end
   ```

9. `handle_event("run-all", ...)` iterates `socket.assigns.endpoints` (renamed from `cases`) and filters to `kind == :endpoint` (skip reference entries).

10. Rename `assigns[:cases]` to `assigns[:endpoints]`, `categories` unchanged but derived from endpoints.

- [ ] **Step 3: Compile + test**

```bash
cd api && MIX_ENV=dev mix compile 2>&1 | grep -iE "error|warning.*api_tester" | head
MIX_ENV=test mix test 2>&1 | tail -5
```

Expected: clean compile. Test suite still green (the `test_cases_test.exs` is gone; the new `endpoints_test.exs` covers its role).

- [ ] **Step 4: Smoke the pane**

Start dev phoenix, hit the pane, confirm it renders and no crashes.

```bash
# NOTE: systemd prod may already own port 4000 on the deploy server.
# If so, skip this step and rely on Task 9's end-to-end deploy smoke.
cd api && MIX_ENV=dev mix phx.server &
sleep 5
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:4000/studio/production/api-tester
kill %1 2>/dev/null
```
Expected: HTTP 200. If 500, read the server output for the stacktrace.

- [ ] **Step 5: Commit**

```bash
git add -u api/lib/barkpark_web/live/studio/api_tester_live.ex
git add -u api/lib/barkpark/api_tester/test_cases.ex api/test/barkpark/api_tester/test_cases_test.exs
git commit -m "refactor(api-tester): LiveView loads Endpoints, drop TestCases"
```

---

### Task 6: Three-column layout + form-driven playground

**Files:**
- Modify: `api/lib/barkpark_web/live/studio/api_tester_live.ex`

This is the biggest LiveView change in the plan. Read it twice before starting.

- [ ] **Step 1: Update assigns in `mount/3`**

Replace the existing `mount/3` with:

```elixir
@impl true
def mount(%{"dataset" => dataset}, _session, socket) do
  endpoints = Endpoints.all(dataset)
  selected = List.first(endpoints)

  {:ok,
   assign(socket,
     nav_section: :api_tester,
     dataset: dataset,
     endpoints: endpoints,
     categories: endpoints |> Enum.map(& &1.category) |> Enum.uniq(),
     selected_id: selected.id,
     token: "barkpark-dev-token",
     form_state_by_id: %{selected.id => initial_form_state(selected)},
     last_result_by_id: %{}
   )}
end

defp initial_form_state(%{kind: :reference}), do: %{}

defp initial_form_state(endpoint) do
  body_text =
    if endpoint.body_example, do: Jason.encode!(endpoint.body_example, pretty: true), else: ""

  path_values =
    Enum.into(endpoint.path_params || [], %{}, fn %{name: name, default: default} ->
      {name, to_string(default)}
    end)

  query_values =
    Enum.into(endpoint.query_params || [], %{}, fn %{name: name, default: default} ->
      {name, to_string(default)}
    end)

  path_values
  |> Map.merge(query_values)
  |> Map.put("_body_text", body_text)
end
```

- [ ] **Step 2: Add `handle_event` clauses for form interaction**

Add these handlers (keep the existing `run-all` handler; delete or update `body-edit` to use new form_state shape):

```elixir
@impl true
def handle_event("select", %{"id" => id}, socket) do
  endpoint = Endpoints.find(socket.assigns.dataset, id)

  form_state =
    Map.get_lazy(socket.assigns.form_state_by_id, id, fn -> initial_form_state(endpoint) end)

  new_form_state_by_id = Map.put(socket.assigns.form_state_by_id, id, form_state)

  {:noreply,
   assign(socket, selected_id: id, form_state_by_id: new_form_state_by_id)}
end

def handle_event("form-change", params, socket) do
  id = socket.assigns.selected_id
  current = Map.get(socket.assigns.form_state_by_id, id, %{})
  updated = Map.merge(current, params)
  new_form_state_by_id = Map.put(socket.assigns.form_state_by_id, id, updated)
  {:noreply, assign(socket, form_state_by_id: new_form_state_by_id)}
end

def handle_event("token-change", %{"token" => token}, socket) do
  {:noreply, assign(socket, token: token)}
end

def handle_event("run", _, socket) do
  endpoint = Endpoints.find(socket.assigns.dataset, socket.assigns.selected_id)

  if endpoint.kind == :reference do
    {:noreply, socket}
  else
    form_state = Map.get(socket.assigns.form_state_by_id, endpoint.id, %{})
    req = Runner.build_request(endpoint, form_state, %{token: socket.assigns.token, base: "http://localhost:4000"})

    legacy = %{
      id: endpoint.id,
      method: req.method,
      path: String.replace_prefix(req.url, "http://localhost:4000", ""),
      headers: req.headers,
      body: decode_body(req.body_text),
      expect: endpoint[:expect]
    }

    result = Runner.run(legacy)
    new_results = Map.put(socket.assigns.last_result_by_id, endpoint.id, result)
    {:noreply, assign(socket, last_result_by_id: new_results)}
  end
end

def handle_event("run-all", _, socket) do
  results =
    socket.assigns.endpoints
    |> Enum.filter(&(&1.kind == :endpoint && &1[:expect] != nil))
    |> Enum.reduce(%{}, fn ep, acc ->
      form_state = Map.get(socket.assigns.form_state_by_id, ep.id, initial_form_state(ep))
      req = Runner.build_request(ep, form_state, %{token: socket.assigns.token, base: "http://localhost:4000"})
      legacy = %{
        id: ep.id, method: req.method,
        path: String.replace_prefix(req.url, "http://localhost:4000", ""),
        headers: req.headers, body: decode_body(req.body_text), expect: ep.expect
      }
      Map.put(acc, ep.id, Runner.run(legacy))
    end)

  {:noreply, assign(socket, last_result_by_id: results)}
end

defp decode_body(""), do: nil
defp decode_body(nil), do: nil
defp decode_body(text) do
  case Jason.decode(text) do
    {:ok, decoded} -> decoded
    _ -> nil
  end
end
```

Remove the `ep_to_legacy_case/3` helper from Task 5 — it's now inlined into the handlers with real form state.

- [ ] **Step 3: Rewrite `render/1` for three-column layout**

Replace the existing `render/1` entirely:

```elixir
@impl true
def render(assigns) do
  assigns =
    assigns
    |> assign(:endpoint, Endpoints.find(assigns.dataset, assigns.selected_id))
    |> assign(:form_state, Map.get(assigns.form_state_by_id, assigns.selected_id, %{}))
    |> assign(:last_result, Map.get(assigns.last_result_by_id, assigns.selected_id))

  ~H"""
  <div class="tester-wrapper">
    <div class="tester-topbar">
      <div class="tester-topbar-title">API Docs + Playground — /v1 contract</div>
      <form phx-change="token-change" class="tester-token-form">
        <label class="tester-token-label">Token</label>
        <input type="text" name="token" value={@token} class="tester-token-input" phx-debounce="300" />
      </form>
      <button phx-click="run-all" class="tester-btn-primary">Run all</button>
    </div>

    <div class="tester-body">
      <aside class="tester-sidebar">
        <%= for category <- @categories do %>
          <div class="tester-category-title"><%= category %></div>
          <%= for ep <- Enum.filter(@endpoints, &(&1.category == category)) do %>
            <button
              phx-click="select"
              phx-value-id={ep.id}
              class={"tester-case-row #{if @selected_id == ep.id, do: "is-selected"}"}
            >
              <span class="tester-case-row-label"><%= ep.label %></span>
              <%= render_verdict_badge(Map.get(@last_result_by_id, ep.id)) %>
            </button>
          <% end %>
        <% end %>
      </aside>

      <section class="tester-docs">
        <%= if @endpoint.kind == :reference do %>
          <%= render_reference(assigns, @endpoint.render_key) %>
        <% else %>
          <.endpoint_docs endpoint={@endpoint} />
          <.endpoint_playground endpoint={@endpoint} form_state={@form_state} />
        <% end %>
      </section>

      <section class="tester-response">
        <%= if @last_result do %>
          <.response_view result={@last_result} />
        <% else %>
          <div class="tester-empty">No response yet. Click <strong>Run</strong>.</div>
        <% end %>
      </section>
    </div>
  </div>

  <style>
    .tester-wrapper { background: var(--bg); color: var(--fg); font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
    .tester-topbar { display: flex; gap: 16px; align-items: center; padding: 12px 20px; border-bottom: 1px solid var(--border); background: var(--bg-subtle); }
    .tester-topbar-title { font-weight: 600; font-size: 14px; flex: 1; }
    .tester-token-form { display: flex; gap: 6px; align-items: center; }
    .tester-token-label { font-size: 10px; text-transform: uppercase; letter-spacing: 0.5px; color: var(--fg-muted); font-weight: 600; }
    .tester-token-input { width: 260px; background: var(--bg); color: var(--fg); border: 1px solid var(--border); border-radius: 4px; padding: 4px 8px; font-size: 12px; font-family: "SF Mono", ui-monospace, monospace; }
    .tester-btn-primary { background: var(--primary); color: var(--primary-fg); border: none; padding: 6px 14px; border-radius: 4px; font-size: 13px; cursor: pointer; font-weight: 500; }
    .tester-btn-primary:hover { opacity: 0.9; }

    .tester-body { display: grid; grid-template-columns: 260px 1fr 1fr; min-height: calc(100vh - 110px); }
    .tester-sidebar { border-right: 1px solid var(--border); overflow-y: auto; padding: 8px 0; background: var(--bg-subtle); }
    .tester-category-title { font-size: 11px; font-weight: 600; color: var(--fg-muted); text-transform: uppercase; letter-spacing: 0.5px; padding: 12px 16px 6px; }
    .tester-case-row { display: flex; justify-content: space-between; align-items: center; width: 100%; background: none; border: none; text-align: left; padding: 8px 16px; font-size: 13px; color: var(--fg); cursor: pointer; gap: 8px; }
    .tester-case-row:hover { background: var(--bg-hover); }
    .tester-case-row.is-selected { background: var(--bg-active); color: var(--fg); font-weight: 500; }

    .tester-docs { border-right: 1px solid var(--border); padding: 24px 32px; overflow-y: auto; }
    .tester-response { padding: 24px 32px; overflow-y: auto; }

    .tester-method-row { display: flex; align-items: center; gap: 10px; font-family: "SF Mono", ui-monospace, monospace; margin-bottom: 10px; }
    .tester-method { padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 700; letter-spacing: 0.3px; }
    .tester-method-get { background: hsl(210 80% 90%); color: hsl(210 80% 30%); }
    .tester-method-post { background: hsl(140 60% 88%); color: hsl(140 60% 28%); }
    .tester-url { font-size: 13px; color: var(--fg); word-break: break-all; }
    .tester-auth-badge { display: inline-block; padding: 2px 8px; font-size: 10px; border-radius: 999px; letter-spacing: 0.4px; font-weight: 600; }
    .tester-auth-public { background: hsl(140 60% 90%); color: hsl(140 70% 28%); }
    .tester-auth-token { background: hsl(40 80% 88%); color: hsl(40 80% 30%); }
    .tester-auth-admin { background: hsl(280 60% 90%); color: hsl(280 60% 35%); }

    .tester-section-title { font-size: 11px; font-weight: 600; color: var(--fg-muted); text-transform: uppercase; letter-spacing: 0.5px; margin: 18px 0 8px; }

    .tester-param-table { width: 100%; border-collapse: collapse; font-size: 12px; }
    .tester-param-table th, .tester-param-table td { padding: 6px 8px; text-align: left; border-bottom: 1px solid var(--border); vertical-align: top; }
    .tester-param-table th { color: var(--fg-muted); text-transform: uppercase; letter-spacing: 0.4px; font-size: 10px; }
    .tester-param-table code { font-family: "SF Mono", ui-monospace, monospace; font-size: 11px; }

    .tester-playground { background: var(--bg-subtle); border: 1px solid var(--border); border-radius: 6px; padding: 14px 16px; margin: 16px 0; }
    .tester-playground-row { display: flex; gap: 8px; margin-bottom: 8px; align-items: center; }
    .tester-playground-row label { width: 140px; font-size: 11px; color: var(--fg-muted); font-family: "SF Mono", ui-monospace, monospace; }
    .tester-playground-row input, .tester-playground-row select { flex: 1; background: var(--bg); color: var(--fg); border: 1px solid var(--border); border-radius: 4px; padding: 4px 8px; font-size: 12px; font-family: inherit; }
    .tester-playground-body { width: 100%; min-height: 160px; font-family: "SF Mono", ui-monospace, monospace; font-size: 12px; background: var(--bg); color: var(--fg); border: 1px solid var(--border); border-radius: 4px; padding: 8px; resize: vertical; margin-top: 6px; }
    .tester-playground-actions { display: flex; gap: 10px; margin-top: 12px; }

    .tester-response-head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; }
    .tester-badge { padding: 2px 10px; border-radius: 10px; font-size: 11px; font-weight: 700; letter-spacing: 0.3px; }
    .tester-badge-pass { background: hsl(140 60% 90%); color: hsl(140 70% 25%); }
    .tester-badge-fail { background: hsl(0 70% 92%); color: hsl(0 70% 35%); }
    .tester-badge-error { background: hsl(40 80% 90%); color: hsl(40 70% 30%); }

    .tester-json-pre, .tester-shape-pre { background: var(--bg-subtle); border: 1px solid var(--border); border-radius: 4px; padding: 10px 14px; font-family: "SF Mono", ui-monospace, monospace; font-size: 12px; color: var(--fg); white-space: pre-wrap; word-break: break-all; max-height: 500px; overflow: auto; }

    .tester-ref-table { width: 100%; border-collapse: collapse; font-size: 12px; margin-top: 10px; }
    .tester-ref-table th, .tester-ref-table td { padding: 6px 10px; text-align: left; border-bottom: 1px solid var(--border); }
    .tester-ref-table th { font-size: 10px; text-transform: uppercase; color: var(--fg-muted); }
    .tester-ref-table code { font-family: "SF Mono", ui-monospace, monospace; font-size: 11px; background: var(--bg-subtle); padding: 1px 4px; border-radius: 3px; }

    .tester-empty { color: var(--fg-muted); padding: 40px; text-align: center; }
  </style>
  """
end
```

- [ ] **Step 4: Add the function components for docs + playground**

Add these below `render/1`:

```elixir
defp endpoint_docs(assigns) do
  ~H"""
  <div class="tester-method-row">
    <span class={"tester-method tester-method-#{String.downcase(@endpoint.method)}"}>
      <%= @endpoint.method %>
    </span>
    <span class="tester-url"><%= @endpoint.path_template %></span>
    <span class={"tester-auth-badge tester-auth-#{@endpoint.auth}"}><%= @endpoint.auth %></span>
  </div>

  <p><%= @endpoint.description %></p>

  <%= if @endpoint.path_params != [] do %>
    <div class="tester-section-title">Path params</div>
    <table class="tester-param-table">
      <thead><tr><th>Name</th><th>Type</th><th>Notes</th></tr></thead>
      <tbody>
        <%= for p <- @endpoint.path_params do %>
          <tr><td><code><%= p.name %></code></td><td><%= p.type %></td><td><%= p[:notes] || "" %></td></tr>
        <% end %>
      </tbody>
    </table>
  <% end %>

  <%= if @endpoint.query_params != [] do %>
    <div class="tester-section-title">Query params</div>
    <table class="tester-param-table">
      <thead><tr><th>Name</th><th>Default</th><th>Notes</th></tr></thead>
      <tbody>
        <%= for p <- @endpoint.query_params do %>
          <tr>
            <td><code><%= p.name %></code></td>
            <td><code><%= p.default %></code></td>
            <td><%= p[:notes] || "" %></td>
          </tr>
        <% end %>
      </tbody>
    </table>
  <% end %>

  <div class="tester-section-title">Response shape</div>
  <pre class="tester-shape-pre"><%= @endpoint.response_shape %></pre>

  <%= if @endpoint.possible_errors != [] do %>
    <div class="tester-section-title">Possible errors</div>
    <ul>
      <%= for code <- @endpoint.possible_errors do %>
        <li><code><%= code %></code></li>
      <% end %>
    </ul>
  <% end %>
  """
end

defp endpoint_playground(assigns) do
  ~H"""
  <div class="tester-section-title">Playground</div>
  <form phx-change="form-change" class="tester-playground">
    <%= for p <- @endpoint.path_params do %>
      <div class="tester-playground-row">
        <label><%= p.name %></label>
        <input type="text" name={p.name} value={Map.get(@form_state, p.name, to_string(p.default))} />
      </div>
    <% end %>

    <%= for p <- @endpoint.query_params do %>
      <div class="tester-playground-row">
        <label><%= p.name %></label>
        <%= case p.type do %>
          <% :select -> %>
            <select name={p.name}>
              <%= for opt <- p[:options] || [] do %>
                <option value={opt} selected={opt == Map.get(@form_state, p.name, to_string(p.default))}><%= opt %></option>
              <% end %>
            </select>
          <% _ -> %>
            <input type="text" name={p.name} value={Map.get(@form_state, p.name, to_string(p.default))} />
        <% end %>
      </div>
    <% end %>

    <%= if @endpoint.method == "POST" do %>
      <div class="tester-section-title">Request body (JSON)</div>
      <textarea name="_body_text" class="tester-playground-body" spellcheck="false"><%= Map.get(@form_state, "_body_text", "") %></textarea>
    <% end %>
  </form>

  <div class="tester-playground-actions">
    <button phx-click="run" class="tester-btn-primary">Run</button>
  </div>
  """
end

defp response_view(assigns) do
  ~H"""
  <div class="tester-response-head">
    <div class="tester-section-title" style="margin: 0;">Response</div>
    <div>
      <span class={"tester-badge tester-badge-#{@result.verdict}"}>
        <%= @result.verdict |> to_string() |> String.upcase() %>
      </span>
      HTTP <%= @result.status %> • <%= @result.duration_ms %>ms
    </div>
  </div>
  <div style="font-size: 11px; color: var(--fg-muted); margin-bottom: 8px; font-style: italic;">
    <%= @result.verdict_reason %>
  </div>

  <div class="tester-section-title">Response headers</div>
  <div class="tester-json-pre"><%= Enum.map_join(@result.headers, "\n", fn {k, v} -> "#{k}: #{v}" end) %></div>

  <div class="tester-section-title">Response body</div>
  <pre class="tester-json-pre"><%= format_body(@result) %></pre>
  """
end

defp format_body(%{body_json: json}) when is_map(json) or is_list(json), do: Jason.encode!(json, pretty: true)
defp format_body(%{body_text: text}), do: text
defp format_body(_), do: ""

defp render_verdict_badge(nil), do: ""
defp render_verdict_badge(%{verdict: verdict}) do
  symbol = case verdict do
    :pass -> "✓"
    :fail -> "✗"
    :error -> "!"
  end

  class = "tester-badge tester-badge-#{verdict}"
  assigns = %{symbol: symbol, class: class}

  ~H"""
  <span class={@class}><%= @symbol %></span>
  """
end
```

- [ ] **Step 5: Add the attrs declarations for the components**

Immediately before each component function, add the Phoenix.Component attribute declarations so HEEx compilation is strict:

```elixir
attr :endpoint, :map, required: true
defp endpoint_docs(assigns) do
  # ...
end

attr :endpoint, :map, required: true
attr :form_state, :map, required: true
defp endpoint_playground(assigns) do
  # ...
end

attr :result, :map, required: true
defp response_view(assigns) do
  # ...
end
```

- [ ] **Step 6: Leave `render_reference/2` as a stub for Task 7**

Add a stub:

```elixir
defp render_reference(assigns, _render_key) do
  ~H"""
  <div class="tester-empty">Reference page coming in Task 7.</div>
  """
end
```

- [ ] **Step 7: Compile + test**

```bash
cd api && MIX_ENV=dev mix compile 2>&1 | grep -iE "error|undefined" | head
MIX_ENV=test mix test 2>&1 | tail -5
```

Expected: clean compile, full suite green. If compile fails due to HEEx syntax, fix inline — `~H` blocks must be complete expressions.

- [ ] **Step 8: Commit**

```bash
git add -u api/lib/barkpark_web/live/studio/api_tester_live.ex
git commit -m "feat(api-tester): three-column layout + form-driven playground"
```

---

### Task 7: Reference pages — envelope, error codes, known limitations

**Files:**
- Modify: `api/lib/barkpark_web/live/studio/api_tester_live.ex`

Replace the `render_reference/2` stub with three real clauses.

- [ ] **Step 1: Replace the stub**

Find `defp render_reference(assigns, _render_key)` in `api_tester_live.ex` and replace with:

```elixir
defp render_reference(assigns, :envelope) do
  ~H"""
  <div class="tester-method-row">
    <span class="tester-url" style="font-weight: 600;">Document Envelope</span>
  </div>
  <p>Every document is returned as a flat JSON object. Reserved keys are always present; user content adds additional flat fields. User content cannot override reserved keys — they are silently dropped on write.</p>

  <div class="tester-section-title">Reserved keys</div>
  <table class="tester-ref-table">
    <thead><tr><th>Key</th><th>Type</th><th>Description</th></tr></thead>
    <tbody>
      <tr><td><code>_id</code></td><td>string</td><td>Full document id, including <code>drafts.</code> prefix when a draft</td></tr>
      <tr><td><code>_type</code></td><td>string</td><td>Document type (matches schema name)</td></tr>
      <tr><td><code>_rev</code></td><td>string</td><td>32-char hex; changes on every write</td></tr>
      <tr><td><code>_draft</code></td><td>boolean</td><td><code>true</code> when <code>_id</code> starts with <code>drafts.</code></td></tr>
      <tr><td><code>_publishedId</code></td><td>string</td><td>Id with <code>drafts.</code> prefix stripped</td></tr>
      <tr><td><code>_createdAt</code></td><td>string</td><td>ISO 8601 UTC, <code>Z</code> suffix</td></tr>
      <tr><td><code>_updatedAt</code></td><td>string</td><td>ISO 8601 UTC, <code>Z</code> suffix</td></tr>
    </tbody>
  </table>

  <div class="tester-section-title">Example</div>
  <pre class="tester-shape-pre">{
    "_id": "p1",
    "_type": "post",
    "_rev": "a3f8c2d1e9b04567f2a1c3e5d7890abc",
    "_draft": false,
    "_publishedId": "p1",
    "_createdAt": "2026-04-12T09:11:20Z",
    "_updatedAt": "2026-04-12T10:03:45Z",
    "title": "Hello World",
    "category": "Tech"
  }</pre>
  """
end

defp render_reference(assigns, :error_codes) do
  ~H"""
  <div class="tester-method-row">
    <span class="tester-url" style="font-weight: 600;">Error Codes</span>
  </div>
  <p>All errors return <code>{"error": {"code": "...", "message": "..."}}</code>. For <code>validation_failed</code>, a <code>details</code> map of field-level errors is included.</p>

  <table class="tester-ref-table">
    <thead><tr><th>Code</th><th>HTTP</th><th>Meaning</th></tr></thead>
    <tbody>
      <tr><td><code>not_found</code></td><td>404</td><td>Document or schema not found</td></tr>
      <tr><td><code>unauthorized</code></td><td>401</td><td>Missing or invalid token</td></tr>
      <tr><td><code>forbidden</code></td><td>403</td><td>Token lacks required permission</td></tr>
      <tr><td><code>schema_unknown</code></td><td>404</td><td>No schema registered for this type</td></tr>
      <tr><td><code>rev_mismatch</code></td><td>409</td><td><code>ifRevisionID</code> did not match current rev</td></tr>
      <tr><td><code>conflict</code></td><td>409</td><td>Document already exists (on <code>create</code>)</td></tr>
      <tr><td><code>malformed</code></td><td>400</td><td>Request body is malformed or missing <code>mutations</code> key</td></tr>
      <tr><td><code>validation_failed</code></td><td>422</td><td>Document failed validation; <code>details</code> map contains per-field errors</td></tr>
      <tr><td><code>internal_error</code></td><td>500</td><td>Unexpected server error</td></tr>
    </tbody>
  </table>
  """
end

defp render_reference(assigns, :known_limitations) do
  ~H"""
  <div class="tester-method-row">
    <span class="tester-url" style="font-weight: 600;">Known Limitations (v1.0)</span>
  </div>
  <p>Quirks of the v1 contract you should be aware of when building clients:</p>

  <ul>
    <li>Reference expansion (<code>?expand=</code>) is not implemented.</li>
    <li>Filter only supports exact-match on single values.</li>
    <li><code>previousRev</code> in SSE events is always <code>null</code>; full rev history lives in a separate revisions table that is not part of the v1 HTTP contract.</li>
    <li>Draft/published merging (<code>perspective=drafts</code>) happens after <code>LIMIT</code>/<code>OFFSET</code>, so a page can return fewer than <code>limit</code> rows.</li>
    <li>PubSub broadcasts fire even when a mutation transaction rolls back; the persistent events table is consistent, but the SSE stream may emit ghost events.</li>
    <li>Rate limiting is not enforced at the HTTP layer.</li>
  </ul>
  """
end
```

- [ ] **Step 2: Compile + test**

```bash
cd api && MIX_ENV=dev mix compile 2>&1 | grep -iE "error" | head
MIX_ENV=test mix test 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add -u api/lib/barkpark_web/live/studio/api_tester_live.ex
git commit -m "feat(api-tester): reference pages for envelope, errors, limits"
```

---

### Task 8: "Copy as curl" button

**Files:**
- Modify: `api/lib/barkpark_web/live/studio/api_tester_live.ex`

Build the curl command server-side in a helper, render a button that copies it via clipboard JS.

- [ ] **Step 1: Add the helper**

Add below `decode_body/1`:

```elixir
defp build_curl(endpoint, form_state, token, base \\ "http://localhost:4000") do
  req = Runner.build_request(endpoint, form_state, %{token: token, base: base})

  parts = ["curl -sS"]
  parts = if req.method == "GET", do: parts, else: parts ++ ["-X", req.method]

  header_parts =
    Enum.flat_map(req.headers, fn {k, v} -> ["-H", shell_escape("#{k}: #{v}")] end)

  parts = parts ++ header_parts

  parts =
    if req.body_text && req.body_text != "" do
      parts ++ ["-d", shell_escape(req.body_text)]
    else
      parts
    end

  parts = parts ++ [shell_escape(req.url)]

  Enum.join(parts, " ")
end

defp shell_escape(str), do: "'" <> String.replace(str, "'", ~S('\'')) <> "'"
```

- [ ] **Step 2: Add assign for the current curl and update playground render**

In `render/1`'s assign pipeline, add:

```elixir
  |> assign(:curl_command, if(assigns[:selected_id], do: build_curl(Endpoints.find(assigns.dataset, assigns.selected_id), Map.get(assigns.form_state_by_id, assigns.selected_id, %{}), assigns.token), else: ""))
```

Actually that's awkward — simpler: compute in `endpoint_playground/1` directly. Update that component:

```elixir
attr :endpoint, :map, required: true
attr :form_state, :map, required: true
attr :token, :string, required: true
defp endpoint_playground(assigns) do
  assigns = assign(assigns, :curl, build_curl(assigns.endpoint, assigns.form_state, assigns.token))

  ~H"""
  <!-- existing playground form unchanged -->

  <div class="tester-section-title">Copy as curl</div>
  <pre class="tester-curl-pre" id="tester-curl"><%= @curl %></pre>
  <div class="tester-playground-actions">
    <button phx-click="run" class="tester-btn-primary">Run</button>
    <button type="button" onclick="navigator.clipboard.writeText(document.getElementById('tester-curl').textContent); this.textContent='Copied ✓'; setTimeout(() => this.textContent='Copy curl', 1500)" class="tester-btn-secondary">Copy curl</button>
  </div>
  """
end
```

Also update the call site in `render/1`:

```heex
<.endpoint_playground endpoint={@endpoint} form_state={@form_state} token={@token} />
```

And add CSS to the `<style>` block:

```css
.tester-curl-pre { background: var(--bg-subtle); border: 1px solid var(--border); border-radius: 4px; padding: 10px 14px; font-family: "SF Mono", ui-monospace, monospace; font-size: 11px; color: var(--fg); white-space: pre-wrap; word-break: break-all; margin-top: 4px; max-height: 140px; overflow: auto; }
.tester-btn-secondary { background: var(--bg); color: var(--fg); border: 1px solid var(--border); padding: 6px 14px; border-radius: 4px; font-size: 13px; cursor: pointer; font-weight: 500; }
.tester-btn-secondary:hover { background: var(--bg-hover); }
```

- [ ] **Step 3: Remove the old playground actions block that doesn't have Copy curl**

Delete the earlier `<div class="tester-playground-actions">` outside the form if it duplicates — the Copy button is now inside the component.

- [ ] **Step 4: Compile + test**

```bash
cd api && MIX_ENV=dev mix compile 2>&1 | grep -iE "error" | head
MIX_ENV=test mix test 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add -u api/lib/barkpark_web/live/studio/api_tester_live.ex
git commit -m "feat(api-tester): Copy as curl button with shell escaping"
```

---

## Phase 4 — End-to-end verification + deploy

### Task 9: Smoke + deploy

**Files:** None.

- [ ] **Step 1: Run full ExUnit**

```bash
cd api && MIX_ENV=test mix test
```
Expected: all green, around 40+ tests.

- [ ] **Step 2: Merge the branch**

```bash
cd /root/barkpark && git checkout main && git merge --ff-only api-docs-playground 2>&1 | tail -5
git push origin main
```

- [ ] **Step 3: Deploy**

```bash
cd /opt/barkpark && git pull 2>&1 | tail -10
systemctl is-active barkpark
```
Expected: `[post-merge] Done. Service restarted.` and `active`.

- [ ] **Step 4: HTTP smoke against public IP**

```bash
B="http://89.167.28.206"

echo "=== Pane renders ==="
curl -s -o /dev/null -w "HTTP %{http_code}\n" "$B/studio/production/api-tester"

echo "=== Token input present ==="
curl -s "$B/studio/production/api-tester" | grep -oE 'tester-token-input' | head -1

echo "=== 3-column layout ==="
curl -s "$B/studio/production/api-tester" | grep -oE 'tester-docs|tester-response|tester-sidebar' | sort -u

echo "=== All 16 endpoint nav rows present ==="
curl -s "$B/studio/production/api-tester" | grep -c 'tester-case-row'

echo "=== Reference entries render ==="
curl -s "$B/studio/production/api-tester" | grep -oE 'Document envelope|Error codes|Known limitations' | sort -u
```

Expected:
- `HTTP 200`
- `tester-token-input` present
- `tester-docs`, `tester-response`, `tester-sidebar` all present
- 16+ `tester-case-row` elements (3 ref + 2 query + 8 mutate + 1 listen + 2 schema = 16)
- All three reference labels present

- [ ] **Step 5: Browser sanity check**

Open `http://89.167.28.206/studio/production/api-tester`. Verify:

1. Three columns render side-by-side (sidebar / docs+playground / response)
2. Token field visible in the pane topbar, pre-filled with `barkpark-dev-token`
3. Click "Document envelope" in the Reference section → reserved-keys table renders, no playground form, no Run button
4. Click "List documents" under Query → docs show the `GET /v1/data/query/{dataset}/{type}` path, params table, response shape, possible errors. Playground shows path/query param form fields. "Run" and "Copy curl" buttons visible.
5. Edit `limit` to `3`, click Run → response panel shows HTTP 200, JSON body with ≤3 documents
6. Click "Copy curl" → curl command appears below the form; clicking actually copies to clipboard
7. Switch to `sdktest` dataset via the topbar dropdown → URL becomes `/studio/sdktest/api-tester`, the form repopulates with `sdktest` as the path param default
8. Click "create" under Mutate → body textarea shows the example JSON, edit the `_id` to `browser-test-1`, click Run → 200 response with new envelope

If any of those fail, log the issue and dispatch a fix — do not call the plan complete.

- [ ] **Step 6: No-op if everything passes**

Nothing to commit — the plan is done.

---

## Self-Review

**1. Spec coverage** (from the brainstorm before this plan):

- One data structure drives docs + playground → Tasks 1–3 (Endpoints) ✓
- Three-column layout (nav / docs+playground / response) → Task 6 ✓
- Generated form fields per param → Task 6 ✓
- Token field in topbar → Task 6 ✓
- Copy as curl button → Task 8 ✓
- 8 mutation kinds as separate nav rows → Task 2 ✓
- Reference pages for envelope, errors, limitations → Tasks 3 + 7 ✓
- Docs-only for SSE listen, schema writes → Tasks 3 (listen + schemas-list/show) + stable `:endpoint` kind with `expect: nil` for SSE
- Delete `TestCases` → Task 5 ✓
- `Runner.build_request/3` → Task 4 ✓
- Still dataset-aware → carried forward from previous plan, Tasks 1–3 take dataset ✓

**Gap I'm accepting:** `POST /v1/schemas/:dataset` and `DELETE /v1/schemas/:dataset/:name` are NOT added as endpoints. They'd be too dangerous in a playground. If asked, easy addition in a later task.

**2. Placeholder scan:** No TBD/TODO/"similar to"/"handle edge cases" — every step has the code or command inline.

**3. Type consistency:**
- `Endpoints.all/1` and `Endpoints.find/2` signatures consistent across Tasks 1, 2, 3, 5, 6, 8.
- `Runner.build_request/3` signature (`endpoint, form_state, %{token, base}`) consistent between Task 4 (test), implementation, Task 5 bridge, Task 6 handlers, Task 8 curl builder.
- Form state shape (`%{"name" => string, "_body_text" => string}`) consistent across Tasks 4, 5, 6, 8.
- Endpoint spec shape with `path_params / query_params / body_example / expect / possible_errors / kind / auth / render_key` consistent everywhere.

---

## Execution

**Plan complete and saved to `docs/superpowers/plans/2026-04-14-api-docs-playground.md`.**

**Two execution options:**

1. **Subagent-Driven (recommended)** — 9 tasks, 3 phases, each task produces one commit. Phase 1 (Tasks 1–3) builds the data, Phase 2 (Task 4) adds the Runner glue, Phase 3 (Tasks 5–8) rewrites the LiveView in four separable steps, Phase 4 (Task 9) deploys and smokes.

2. **Inline Execution** — run in this session with checkpoints at each phase boundary.

Which approach?
