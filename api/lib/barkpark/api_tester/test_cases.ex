defmodule Barkpark.ApiTester.TestCases do
  @moduledoc """
  Canonical v1 HTTP contract test cases for the in-browser API Tester pane.

  Each case is a map with:
    - `id`          — stable slug used by the LiveView
    - `category`    — group heading in the UI
    - `label`       — short human name
    - `description` — one-liner shown above the request preview
    - `method`      — "GET" | "POST" | ...
    - `path`        — request path (relative to BASE_URL)
    - `headers`     — list of {name, value} tuples
    - `body`        — nil or a map; encoded to JSON at run-time
    - `expect`      — optional {status, predicate_name} — predicates in
                      `Runner.check/2`. Used to colour the response
                      green/red after running.

  Bodies are rendered in the UI before running, so users can edit them
  (the LiveView passes any edits back to Runner.run/2).
  """

  @token "barkpark-dev-token"
  @auth {"Authorization", "Bearer " <> @token}

  @spec all() :: [map()]
  def all, do: [
    # ── Query ─────────────────────────────────────────────────────────
    %{
      id: "query-flat-envelope",
      category: "Query",
      label: "Envelope shape",
      description: "Public read — confirms reserved _-keys and flat field layout",
      method: "GET",
      path: "/v1/data/query/production/post?limit=1",
      headers: [],
      body: nil,
      expect: {200, :envelope_has_reserved_keys}
    },
    %{
      id: "query-pagination",
      category: "Query",
      label: "Pagination (limit+offset)",
      description: "Second page is disjoint from the first",
      method: "GET",
      path: "/v1/data/query/production/post?limit=2&offset=2",
      headers: [],
      body: nil,
      expect: {200, :ok}
    },
    %{
      id: "query-order-asc",
      category: "Query",
      label: "Order _createdAt:asc",
      description: "Chronological order, oldest first",
      method: "GET",
      path: "/v1/data/query/production/post?order=_createdAt:asc&limit=5",
      headers: [],
      body: nil,
      expect: {200, :order_ascending}
    },
    %{
      id: "query-filter",
      category: "Query",
      label: "Filter by title",
      description: "Exact-match filter on a top-level field",
      method: "GET",
      path: "/v1/data/query/production/post?filter%5Btitle%5D=prod%20smoke%20v1%20patched",
      headers: [],
      body: nil,
      expect: {200, :ok}
    },
    %{
      id: "doc-missing-404",
      category: "Query",
      label: "404 on missing doc (structured error)",
      description: "Expected: {error: {code: 'not_found', message: ...}}",
      method: "GET",
      path: "/v1/data/doc/production/post/does-not-exist-xyz",
      headers: [],
      body: nil,
      expect: {404, :error_code_not_found}
    },

    # ── Schemas ───────────────────────────────────────────────────────
    %{
      id: "schemas-no-auth",
      category: "Schemas",
      label: "Schemas without auth → 401 structured",
      description: "Confirms the auth plug emits the v1 envelope",
      method: "GET",
      path: "/v1/schemas/production",
      headers: [],
      body: nil,
      expect: {401, :error_code_unauthorized}
    },
    %{
      id: "schemas-list",
      category: "Schemas",
      label: "/v1/schemas/:dataset",
      description: "Admin list — _schemaVersion: 1 + schemas array",
      method: "GET",
      path: "/v1/schemas/production",
      headers: [@auth],
      body: nil,
      expect: {200, :schema_version_1}
    },

    # ── Mutations ─────────────────────────────────────────────────────
    %{
      id: "mutate-malformed",
      category: "Mutations",
      label: "Malformed body → 400",
      description: "Missing `mutations` key surfaces the malformed error",
      method: "POST",
      path: "/v1/data/mutate/production",
      headers: [@auth, {"Content-Type", "application/json"}],
      body: %{"not_mutations" => []},
      expect: {400, :error_code_malformed}
    },
    %{
      id: "mutate-create",
      category: "Mutations",
      label: "createOrReplace returns envelope",
      description: "Round-trips through Envelope.render — verify _rev is 32 hex chars",
      method: "POST",
      path: "/v1/data/mutate/production",
      headers: [@auth, {"Content-Type", "application/json"}],
      body: %{
        "mutations" => [
          %{
            "createOrReplace" => %{
              "_id" => "tester-1",
              "_type" => "post",
              "title" => "Tester created this",
              "body" => "hello from the tester pane"
            }
          }
        ]
      },
      expect: {200, :mutate_result_has_envelope}
    },
    %{
      id: "mutate-atomic-rollback",
      category: "Mutations",
      label: "Atomic rollback on partial failure",
      description: "create+publish where publish fails → create rolls back",
      method: "POST",
      path: "/v1/data/mutate/production",
      headers: [@auth, {"Content-Type", "application/json"}],
      body: %{
        "mutations" => [
          %{
            "create" => %{
              "_id" => "tester-rollback",
              "_type" => "post",
              "title" => "should not persist"
            }
          },
          %{"publish" => %{"id" => "tester-nonexistent", "type" => "post"}}
        ]
      },
      expect: {404, :error_code_not_found}
    },
    %{
      id: "mutate-conflict",
      category: "Mutations",
      label: "Duplicate create → 409 conflict",
      description: "Run twice back-to-back — the second call conflicts",
      method: "POST",
      path: "/v1/data/mutate/production",
      headers: [@auth, {"Content-Type", "application/json"}],
      body: %{
        "mutations" => [
          %{
            "create" => %{
              "_id" => "tester-conflict",
              "_type" => "post",
              "title" => "first"
            }
          }
        ]
      },
      expect: {200, :ok}
    },

    # ── Auth ──────────────────────────────────────────────────────────
    %{
      id: "mutate-no-auth",
      category: "Auth",
      label: "Mutate without token → 401 structured",
      description: "Verifies RequireToken plug emits v1 error envelope",
      method: "POST",
      path: "/v1/data/mutate/production",
      headers: [{"Content-Type", "application/json"}],
      body: %{"mutations" => []},
      expect: {401, :error_code_unauthorized}
    },

    # ── Legacy ────────────────────────────────────────────────────────
    %{
      id: "legacy-deprecation",
      category: "Legacy",
      label: "/api/schemas carries Deprecation headers",
      description: "Response body is legacy shape; headers announce sunset",
      method: "GET",
      path: "/api/schemas",
      headers: [],
      body: nil,
      expect: {200, :legacy_deprecation_headers}
    }
  ]

  @spec find(String.t()) :: map() | nil
  def find(id), do: Enum.find(all(), &(&1.id == id))
end
