defmodule Barkpark.ApiTester.Endpoints.Query do
  @moduledoc """
  Query + Search catalog endpoints for the Studio API Docs + Playground
  pane. Split out of `Barkpark.ApiTester.Endpoints` (the facade) — each
  entry is moved verbatim; see that module's @moduledoc for the spec shape.

  `entries/1` returns this category's slice of the full catalog, in the
  exact order the facade concatenates it. (Search is categorised "Query"
  in the nav, so it lives here too.)
  """

  @doc "Query + Search entries, in catalog order, with the dataset interpolated into path params."
  @spec entries(String.t()) :: [map()]
  def entries(dataset) do
    [
      query_list(dataset),
      query_filter_ops(dataset),
      query_single(dataset),
      query_expand(dataset),
      search_documents(dataset)
    ]
  end

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
        "List documents of a given type with pagination, ordering, and optional filters. Perspective controls draft visibility: 'published' (default) shows only published documents, 'drafts' shows the most recent version (draft overlay if exists, published otherwise), 'raw' shows all rows including both draft and published versions. Returns 404 if the schema's visibility is 'private' and no auth token is provided.",
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
        %{name: "limit", type: :integer, default: "10", notes: "1–1000, default 100 (server)"},
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
        %{
          name: "filter[title]",
          type: :string,
          default: "",
          notes:
            "Exact-match filter. Also supports operator form: filter[field][eq], filter[field][in]=a,b, filter[field][contains], filter[field][gt], filter[field][gte], filter[field][lt], filter[field][lte]"
        }
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
      expect: {200, :envelope_has_reserved_keys},
      scenarios: [
        %{
          label: "lists published docs",
          path_overrides: %{},
          query_overrides: %{},
          body: nil,
          expect: {200, :envelope_has_reserved_keys}
        },
        %{
          label: "nonexistent type → 404",
          path_overrides: %{"type" => "zzzzz"},
          query_overrides: %{},
          body: nil,
          expect: {404, :error_code_not_found}
        }
      ]
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
        %{
          name: "filter[title][contains]",
          type: :string,
          default: "smoke",
          notes: "Substring match, case-insensitive"
        },
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
        %{
          name: "doc_id",
          type: :string,
          default: "p1",
          notes: "Full document id (may include drafts. prefix)"
        }
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
      expect: {200, :envelope_top_level},
      scenarios: [
        %{
          label: "gets document p1",
          path_overrides: %{},
          query_overrides: %{},
          body: nil,
          expect: {200, :envelope_top_level}
        },
        %{
          label: "missing doc → 404",
          path_overrides: %{"doc_id" => "nonexistent"},
          query_overrides: %{},
          body: nil,
          expect: {404, :error_code_not_found}
        }
      ]
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
        %{
          name: "expand",
          type: :string,
          default: "true",
          notes: "true | comma-list of field names"
        }
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

  defp search_documents(dataset) do
    %{
      id: "search-documents",
      category: "Query",
      label: "Search",
      kind: :endpoint,
      auth: :public,
      method: "GET",
      path_template: "/v1/data/search/{dataset}",
      description:
        "Case-insensitive title search using ILIKE. Defaults to published perspective. Returns matched documents with total count. Public — no auth required.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}
      ],
      query_params: [
        %{
          name: "q",
          type: :string,
          default: "",
          notes:
            "Required. Case-insensitive substring match on title. Empty or missing returns 400 malformed."
        },
        %{
          name: "type",
          type: :string,
          default: "",
          notes: "Exact match filter by document type (e.g., 'post', 'author')"
        },
        %{
          name: "perspective",
          type: :select,
          default: "published",
          options: ["published", "drafts", "raw"],
          notes: "published = no drafts. prefix; drafts = only drafts.; raw = all documents"
        },
        %{name: "limit", type: :integer, default: "50", notes: "1–200, default 50"},
        %{name: "offset", type: :integer, default: "0", notes: "Pagination offset, default 0"}
      ],
      body_example: nil,
      response_shape: """
      {
        "documents": [
          {
            "_id": "p1",
            "_type": "post",
            "_rev": "a3f8...",
            "_draft": false,
            "_publishedId": "p1",
            "_createdAt": "2026-04-12T09:11:20Z",
            "_updatedAt": "2026-04-13T10:03:45Z",
            "title": "Getting Started with Content"
          }
        ],
        "count": 12,
        "query": "content"
      }
      """,
      possible_errors: [:malformed],
      expect: nil,
      runnable: true,
      scenarios: [
        %{
          label: "search with results",
          path_overrides: %{},
          # Title substring that matches at least one seeded post.
          # Generic terms like "post" don't appear in titles.
          query_overrides: %{"q" => "GROQ"},
          body: nil,
          expect: {200, :search_has_results}
        },
        %{
          label: "search no matches",
          path_overrides: %{},
          query_overrides: %{"q" => "zzzzzznoexist"},
          body: nil,
          expect: {200, :search_empty}
        },
        %{
          label: "missing q → 400",
          path_overrides: %{},
          query_overrides: %{},
          body: nil,
          expect: {400, :error_code_malformed}
        },
        %{
          label: "search with type filter",
          path_overrides: %{},
          query_overrides: %{"q" => "a", "type" => "post"},
          body: nil,
          expect: {200, :search_type_match}
        }
      ]
    }
  end
end
