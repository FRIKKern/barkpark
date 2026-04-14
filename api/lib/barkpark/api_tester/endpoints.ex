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
end
