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
        response_shape: "abbreviated JSON example",
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
              # Fresh id per call so Run all stays idempotent across sessions.
              # Edit the id in the playground textarea to trigger a conflict.
              "_id" => "playground-create-#{:erlang.unique_integer([:positive])}",
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
          { "id": "drafts.playground-create-<n>", "operation": "create", "document": { /* envelope */ } }
        ]
      }
      """,
      possible_errors: [:conflict, :validation_failed, :unauthorized, :malformed],
      expect: {200, :mutate_result_has_envelope}
    }
  end

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
            "createOrReplace" => %{
              "_type" => "post",
              "_id" => "playground-patch-1",
              "title" => "Before patch"
            }
          },
          %{
            "patch" => %{
              "id" => "drafts.playground-patch-1",
              "type" => "post",
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
          %{
            "createOrReplace" => %{
              "_type" => "post",
              "_id" => "playground-publish-1",
              "title" => "Publish me"
            }
          },
          %{"publish" => %{"id" => "playground-publish-1", "type" => "post"}}
        ]
      },
      response_shape: """
      {
        "transactionId": "...",
        "results": [
          { "id": "drafts.playground-publish-1", "operation": "createOrReplace", "document": { /* envelope */ } },
          { "id": "playground-publish-1", "operation": "publish", "document": { /* envelope, _draft=false */ } }
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
          %{
            "createOrReplace" => %{
              "_type" => "post",
              "_id" => "playground-unpublish-1",
              "title" => "Unpublish me"
            }
          },
          %{"publish" => %{"id" => "playground-unpublish-1", "type" => "post"}},
          %{"unpublish" => %{"id" => "playground-unpublish-1", "type" => "post"}}
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
          %{
            "createOrReplace" => %{
              "_type" => "post",
              "_id" => "playground-discard-1",
              "title" => "Discard this draft"
            }
          },
          %{"discardDraft" => %{"id" => "playground-discard-1", "type" => "post"}}
        ]
      },
      response_shape: """
      {
        "transactionId": "...",
        "results": [
          { "id": "drafts.playground-discard-1", "operation": "createOrReplace", "document": { /* envelope */ } },
          { "id": "drafts.playground-discard-1", "operation": "discardDraft", "document": { /* envelope of deleted draft */ } }
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
          %{
            "createOrReplace" => %{
              "_type" => "post",
              "_id" => "playground-delete-1",
              "title" => "To be deleted"
            }
          },
          %{"delete" => %{"id" => "playground-delete-1", "type" => "post"}}
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

  # ── Export endpoints ─────────────────────────────────────────────────

  defp export_dataset(dataset) do
    %{
      id: "export-dataset",
      category: "Export",
      label: "Export dataset",
      kind: :endpoint,
      auth: :token,
      method: "GET",
      path_template: "/v1/data/export/{dataset}",
      description: "Export all documents as newline-delimited JSON (NDJSON). Streams the response.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}
      ],
      query_params: [
        %{name: "type", type: :string, default: "", notes: "Optional: filter by document type"}
      ],
      body_example: nil,
      response_shape: "{\"_id\":\"p1\",\"_type\":\"post\",\"title\":\"Hello\",...}\n{\"_id\":\"p2\",\"_type\":\"post\",\"title\":\"World\",...}",
      possible_errors: [:unauthorized],
      expect: {200, :ok},
      runnable: true
    }
  end

  # ── Search endpoints ─────────────────────────────────────────────────

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
        %{name: "limit", type: :string, default: "50", notes: "Max results (1-200)"},
        %{name: "offset", type: :string, default: "0", notes: "Pagination offset"}
      ],
      body_example: nil,
      response_shape: "{\n  \"documents\": [{\"_id\": \"p1\", \"_type\": \"post\", \"title\": \"...\"}],\n  \"count\": 12,\n  \"query\": \"phoenix\"\n}",
      possible_errors: [:malformed],
      expect: nil,
      runnable: true
    }
  end

  # ── History endpoints ────────────────────────────────────────────────

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
        %{name: "doc_id", type: :string, default: "p1", notes: "Document ID (published, no drafts. prefix)"}
      ],
      query_params: [
        %{name: "limit", type: :string, default: "50", notes: "Max revisions (1-200)"}
      ],
      body_example: nil,
      response_shape: "{\n  \"revisions\": [\n    {\"id\": \"uuid\", \"action\": \"publish\", \"title\": \"...\", \"timestamp\": \"...\"}\n  ],\n  \"count\": 5\n}",
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
      response_shape: "{\n  \"revision\": {\n    \"id\": \"uuid\", \"doc_id\": \"p1\", \"type\": \"post\",\n    \"action\": \"publish\", \"content\": {...}, \"timestamp\": \"...\"\n  }\n}",
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
      response_shape: "{\n  \"restored\": true,\n  \"document\": {\"_id\": \"drafts.p1\", \"_type\": \"post\", ...}\n}",
      possible_errors: [:unauthorized, :not_found],
      expect: nil,
      runnable: true
    }
  end

  # ── Analytics endpoints ──────────────────────────────────────────────

  defp analytics_overview(dataset) do
    %{
      id: "analytics-overview",
      category: "Analytics",
      label: "Dataset stats",
      kind: :endpoint,
      auth: :token,
      method: "GET",
      path_template: "/v1/data/analytics/{dataset}",
      description: "Aggregate stats: document counts by type with published/draft breakdown, recent mutation activity.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}
      ],
      query_params: [],
      body_example: nil,
      response_shape: "{\n  \"dataset\": \"production\",\n  \"total_documents\": 42,\n  \"types\": [{\"type\": \"post\", \"total\": 20, \"published\": 15, \"drafts\": 5}],\n  \"recent_activity\": [{\"mutation\": \"publish\", \"doc_id\": \"p1\", ...}]\n}",
      possible_errors: [:unauthorized],
      expect: {200, :ok},
      runnable: true
    }
  end

  # ── Webhook endpoints ────────────────────────────────────────────────

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
      response_shape: "{\n  \"webhooks\": [\n    {\"id\": \"uuid\", \"name\": \"My Hook\", \"url\": \"https://...\", \"active\": true}\n  ]\n}",
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
      description: "Create a new webhook. Empty events/types arrays match all.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}
      ],
      query_params: [],
      body_example: %{
        "name" => "Notify Slack",
        "url" => "https://hooks.slack.com/services/...",
        "events" => ["publish"],
        "types" => ["post"]
      },
      response_shape: "{\n  \"webhook\": {\"id\": \"uuid\", \"name\": \"Notify Slack\", \"active\": true}\n}",
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
      response_shape: "{\"deleted\": \"uuid\"}",
      possible_errors: [:unauthorized, :forbidden, :not_found],
      expect: nil,
      runnable: true
    }
  end

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
      expect: nil,
      runnable: false
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
end
