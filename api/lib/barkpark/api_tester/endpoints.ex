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
