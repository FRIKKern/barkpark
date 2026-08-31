defmodule Barkpark.ApiTester.EndpointsCatalogBaseline do
  @moduledoc """
  AUTO-GENERATED parity fixture for `Barkpark.ApiTester.EndpointsTest`.

  Snapshot of the ORIGINAL (pre-split) static catalog —
  `Endpoints.all(\"production\")` with the dynamic `plugin-*` entries
  excluded (those come from the plugin Registry and are appended unchanged
  by the facade). The decomposition of `endpoints.ex` into per-category
  modules must keep `all/1` returning this exact list (same length, same
  order, same entry maps). `mutate-create`'s body `_id` is normalized to
  "<DYNAMIC>" (the original uses `:erlang.unique_integer/1`).

  Lives under `test/support` so it is COMPILED, not collected as a test
  file. Do NOT edit by hand — regenerate from the pre-split module.
  """

  @catalog [
    %{
      id: "ref-envelope",
      label: "Document envelope",
      description:
        "Every document is returned as a flat JSON object with 7 reserved _-prefixed keys plus arbitrary user fields.",
      category: "Reference",
      kind: :reference,
      render_key: :envelope
    },
    %{
      id: "ref-errors",
      label: "Error codes",
      description:
        "All errors return {\"error\": {\"code\": \"...\", \"message\": \"...\"}} — 9 codes total.",
      category: "Reference",
      kind: :reference,
      render_key: :error_codes
    },
    %{
      id: "ref-limits",
      label: "Known limitations",
      description: "6 quirks of v1 that may bite real clients.",
      category: "Reference",
      kind: :reference,
      render_key: :known_limitations
    },
    %{
      id: "query-list",
      label: "List documents",
      auth: :public,
      description:
        "List documents of a given type with pagination, ordering, and optional filters. Perspective controls draft visibility: 'published' (default) shows only published documents, 'drafts' shows the most recent version (draft overlay if exists, published otherwise), 'raw' shows all rows including both draft and published versions. Returns 404 if the schema's visibility is 'private' and no auth token is provided.",
      category: "Query",
      kind: :endpoint,
      method: "GET",
      body_example: nil,
      path_template: "/v1/data/query/{dataset}/{type}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        },
        %{
          default: "post",
          name: "type",
          type: :string,
          notes: "Document type name"
        }
      ],
      query_params: [
        %{
          default: "published",
          name: "perspective",
          type: :select,
          options: ["published", "drafts", "raw"],
          notes: "published (default) / drafts / raw"
        },
        %{
          default: "10",
          name: "limit",
          type: :integer,
          notes: "1–1000, default 100 (server)"
        },
        %{default: "0", name: "offset", type: :integer, notes: "Integer, min 0"},
        %{
          default: "_updatedAt:desc",
          name: "order",
          type: :select,
          options: ["_updatedAt:desc", "_updatedAt:asc", "_createdAt:desc", "_createdAt:asc"],
          notes: "Sort key and direction"
        },
        %{
          default: "",
          name: "filter[title]",
          type: :string,
          notes:
            "Exact-match filter. Also supports operator form: filter[field][eq], filter[field][in]=a,b, filter[field][contains], filter[field][gt], filter[field][gte], filter[field][lt], filter[field][lte]"
        }
      ],
      response_shape:
        "{\n  \"perspective\": \"published\",\n  \"documents\": [ /* envelope, ... */ ],\n  \"count\": 3,\n  \"limit\": 10,\n  \"offset\": 0\n}\n",
      possible_errors: [:not_found],
      expect: {200, :envelope_has_reserved_keys},
      scenarios: [
        %{
          label: "lists published docs",
          body: nil,
          expect: {200, :envelope_has_reserved_keys},
          path_overrides: %{},
          query_overrides: %{}
        },
        %{
          label: "nonexistent type → 404",
          body: nil,
          expect: {404, :error_code_not_found},
          path_overrides: %{"type" => "zzzzz"},
          query_overrides: %{}
        }
      ]
    },
    %{
      id: "query-filter-ops",
      label: "Filter operators",
      auth: :public,
      description:
        "Operator-form filters: filter[title][eq]=, filter[title][in]=a,b, filter[title][contains]=. Top-level shorthand filter[title]=x is equivalent to [eq].",
      category: "Query",
      kind: :endpoint,
      method: "GET",
      body_example: nil,
      path_template: "/v1/data/query/{dataset}/{type}",
      path_params: [
        %{default: "production", name: "dataset", type: :string},
        %{default: "post", name: "type", type: :string}
      ],
      query_params: [
        %{
          default: "smoke",
          name: "filter[title][contains]",
          type: :string,
          notes: "Substring match, case-insensitive"
        },
        %{default: "5", name: "limit", type: :integer}
      ],
      response_shape:
        "{\n  \"documents\": [ /* envelopes whose title contains the substring */ ],\n  \"count\": N\n}\n",
      possible_errors: [:not_found],
      expect: {200, :ok}
    },
    %{
      id: "query-single",
      label: "Get single document",
      auth: :public,
      description:
        "Fetch a single document by id. Returns the envelope at the top level. 404 if missing or schema is private.",
      category: "Query",
      kind: :endpoint,
      method: "GET",
      body_example: nil,
      path_template: "/v1/data/doc/{dataset}/{type}/{doc_id}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        },
        %{
          default: "post",
          name: "type",
          type: :string,
          notes: "Document type name"
        },
        %{
          default: "p1",
          name: "doc_id",
          type: :string,
          notes: "Full document id (may include drafts. prefix)"
        }
      ],
      query_params: [],
      response_shape:
        "{\n  \"_id\": \"p1\",\n  \"_type\": \"post\",\n  \"_rev\": \"a3f8c2d1...\",\n  \"_draft\": false,\n  \"_publishedId\": \"p1\",\n  \"_createdAt\": \"2026-04-12T09:11:20Z\",\n  \"_updatedAt\": \"2026-04-12T10:03:45Z\",\n  \"title\": \"Hello World\"\n}\n",
      possible_errors: [:not_found],
      expect: {200, :envelope_top_level},
      scenarios: [
        %{
          label: "gets document p1",
          body: nil,
          expect: {200, :envelope_top_level},
          path_overrides: %{},
          query_overrides: %{}
        },
        %{
          label: "missing doc → 404",
          body: nil,
          expect: {404, :error_code_not_found},
          path_overrides: %{"doc_id" => "nonexistent"},
          query_overrides: %{}
        }
      ]
    },
    %{
      id: "query-expand",
      label: "Expand references",
      auth: :public,
      description:
        "Depth-1 reference expansion. Pass ?expand=true to inline all reference fields, or ?expand=field1,field2 for a named subset.",
      category: "Query",
      kind: :endpoint,
      method: "GET",
      body_example: nil,
      path_template: "/v1/data/query/{dataset}/{type}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        },
        %{default: "post", name: "type", type: :string, notes: "Document type"}
      ],
      query_params: [
        %{
          default: "3",
          name: "limit",
          type: :integer,
          notes: "How many docs to fetch"
        },
        %{
          default: "true",
          name: "expand",
          type: :string,
          notes: "true | comma-list of field names"
        }
      ],
      response_shape:
        "{\n  \"documents\": [\n    {\n      \"_id\": \"p1\",\n      \"author\": {\n        \"_id\": \"a1\",\n        \"_type\": \"author\",\n        \"title\": \"Jane\"\n      }\n    }\n  ]\n}\n",
      possible_errors: [:not_found],
      expect: {200, :envelope_has_reserved_keys}
    },
    %{
      id: "search-documents",
      label: "Search",
      runnable: true,
      auth: :public,
      description:
        "Case-insensitive title search using ILIKE. Defaults to published perspective. Returns matched documents with total count. Public — no auth required.",
      category: "Query",
      kind: :endpoint,
      method: "GET",
      body_example: nil,
      path_template: "/v1/data/search/{dataset}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        }
      ],
      query_params: [
        %{
          default: "",
          name: "q",
          type: :string,
          notes:
            "Required. Case-insensitive substring match on title. Empty or missing returns 400 malformed."
        },
        %{
          default: "",
          name: "type",
          type: :string,
          notes: "Exact match filter by document type (e.g., 'post', 'author')"
        },
        %{
          default: "published",
          name: "perspective",
          type: :select,
          options: ["published", "drafts", "raw"],
          notes: "published = no drafts. prefix; drafts = only drafts.; raw = all documents"
        },
        %{
          default: "50",
          name: "limit",
          type: :integer,
          notes: "1–200, default 50"
        },
        %{
          default: "0",
          name: "offset",
          type: :integer,
          notes: "Pagination offset, default 0"
        }
      ],
      response_shape:
        "{\n  \"documents\": [\n    {\n      \"_id\": \"p1\",\n      \"_type\": \"post\",\n      \"_rev\": \"a3f8...\",\n      \"_draft\": false,\n      \"_publishedId\": \"p1\",\n      \"_createdAt\": \"2026-04-12T09:11:20Z\",\n      \"_updatedAt\": \"2026-04-13T10:03:45Z\",\n      \"title\": \"Getting Started with Content\"\n    }\n  ],\n  \"count\": 12,\n  \"query\": \"content\"\n}\n",
      possible_errors: [:malformed],
      expect: nil,
      scenarios: [
        %{
          label: "search with results",
          body: nil,
          expect: {200, :search_has_results},
          path_overrides: %{},
          query_overrides: %{"q" => "GROQ"}
        },
        %{
          label: "search no matches",
          body: nil,
          expect: {200, :search_empty},
          path_overrides: %{},
          query_overrides: %{"q" => "zzzzzznoexist"}
        },
        %{
          label: "missing q → 400",
          body: nil,
          expect: {400, :error_code_malformed},
          path_overrides: %{},
          query_overrides: %{}
        },
        %{
          label: "search with type filter",
          body: nil,
          expect: {200, :search_type_match},
          path_overrides: %{},
          query_overrides: %{"q" => "a", "type" => "post"}
        }
      ]
    },
    %{
      id: "mutate-create",
      label: "create",
      auth: :token,
      description:
        "Create a new draft. Errors with code \"conflict\" if a draft already exists at the given id.",
      category: "Mutate",
      kind: :endpoint,
      method: "POST",
      body_example: %{
        "mutations" => [
          %{
            "create" => %{
              "_id" => "<DYNAMIC>",
              "_type" => "post",
              "body" => "Hello from docs + playground",
              "title" => "From the playground"
            }
          }
        ]
      },
      path_template: "/v1/data/mutate/{dataset}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        }
      ],
      query_params: [],
      response_shape:
        "{\n  \"transactionId\": \"d4e5f6a7...\",\n  \"results\": [\n    { \"id\": \"drafts.playground-create-<n>\", \"operation\": \"create\", \"document\": { /* envelope */ } }\n  ]\n}\n",
      possible_errors: [:conflict, :validation_failed, :unauthorized, :malformed],
      expect: {200, :mutate_result_has_envelope}
    },
    %{
      id: "mutate-createOrReplace",
      label: "createOrReplace",
      auth: :token,
      description:
        "Upsert. Creates a new draft or overwrites the existing draft at the given id.",
      category: "Mutate",
      kind: :endpoint,
      method: "POST",
      body_example: %{
        "mutations" => [
          %{
            "createOrReplace" => %{
              "_id" => "playground-upsert-1",
              "_type" => "post",
              "body" => "This overwrites if it already exists",
              "title" => "Upserted"
            }
          }
        ]
      },
      path_template: "/v1/data/mutate/{dataset}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        }
      ],
      query_params: [],
      response_shape:
        "{\n  \"transactionId\": \"...\",\n  \"results\": [\n    { \"id\": \"drafts.playground-upsert-1\", \"operation\": \"createOrReplace\", \"document\": { /* envelope */ } }\n  ]\n}\n",
      possible_errors: [:validation_failed, :unauthorized, :malformed],
      expect: {200, :mutate_result_has_envelope}
    },
    %{
      id: "mutate-createIfNotExists",
      label: "createIfNotExists",
      auth: :token,
      description:
        "Create only if no draft exists at the given id. If one already exists, returns it with operation \"noop\".",
      category: "Mutate",
      kind: :endpoint,
      method: "POST",
      body_example: %{
        "mutations" => [
          %{
            "createIfNotExists" => %{
              "_id" => "playground-ifne-1",
              "_type" => "post",
              "title" => "Create once"
            }
          }
        ]
      },
      path_template: "/v1/data/mutate/{dataset}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        }
      ],
      query_params: [],
      response_shape:
        "{\n  \"transactionId\": \"...\",\n  \"results\": [\n    { \"id\": \"drafts.playground-ifne-1\", \"operation\": \"create\" | \"noop\", \"document\": { /* envelope */ } }\n  ]\n}\n",
      possible_errors: [:validation_failed, :unauthorized, :malformed],
      expect: {200, :mutate_result_has_envelope}
    },
    %{
      id: "mutate-patch",
      label: "patch",
      auth: :token,
      description:
        "Merge `set` fields into an existing document. Optional `ifRevisionID` enforces optimistic concurrency — a stale rev returns 409 rev_mismatch. Result operation is \"update\".",
      category: "Mutate",
      kind: :endpoint,
      method: "POST",
      body_example: %{
        "mutations" => [
          %{
            "createOrReplace" => %{
              "_id" => "playground-patch-1",
              "_type" => "post",
              "title" => "Before patch"
            }
          },
          %{
            "patch" => %{
              "id" => "drafts.playground-patch-1",
              "set" => %{"status" => "draft", "title" => "Revised title"},
              "type" => "post"
            }
          }
        ]
      },
      path_template: "/v1/data/mutate/{dataset}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        }
      ],
      query_params: [],
      response_shape:
        "{\n  \"transactionId\": \"...\",\n  \"results\": [\n    { \"id\": \"drafts.playground-upsert-1\", \"operation\": \"update\", \"document\": { /* envelope */ } }\n  ]\n}\n",
      possible_errors: [:not_found, :rev_mismatch, :validation_failed, :unauthorized, :malformed],
      expect: {200, :mutate_result_has_envelope}
    },
    %{
      id: "mutate-publish",
      label: "publish",
      auth: :token,
      description: "Copy `drafts.<id>` to `<id>` and delete the draft.",
      category: "Mutate",
      kind: :endpoint,
      method: "POST",
      body_example: %{
        "mutations" => [
          %{
            "createOrReplace" => %{
              "_id" => "playground-publish-1",
              "_type" => "post",
              "title" => "Publish me"
            }
          },
          %{"publish" => %{"id" => "playground-publish-1", "type" => "post"}}
        ]
      },
      path_template: "/v1/data/mutate/{dataset}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        }
      ],
      query_params: [],
      response_shape:
        "{\n  \"transactionId\": \"...\",\n  \"results\": [\n    { \"id\": \"drafts.playground-publish-1\", \"operation\": \"createOrReplace\", \"document\": { /* envelope */ } },\n    { \"id\": \"playground-publish-1\", \"operation\": \"publish\", \"document\": { /* envelope, _draft=false */ } }\n  ]\n}\n",
      possible_errors: [:not_found, :unauthorized, :malformed],
      expect: {200, :mutate_result_has_envelope}
    },
    %{
      id: "mutate-unpublish",
      label: "unpublish",
      auth: :token,
      description: "Move `<id>` back to `drafts.<id>`.",
      category: "Mutate",
      kind: :endpoint,
      method: "POST",
      body_example: %{
        "mutations" => [
          %{
            "createOrReplace" => %{
              "_id" => "playground-unpublish-1",
              "_type" => "post",
              "title" => "Unpublish me"
            }
          },
          %{"publish" => %{"id" => "playground-unpublish-1", "type" => "post"}},
          %{"unpublish" => %{"id" => "playground-unpublish-1", "type" => "post"}}
        ]
      },
      path_template: "/v1/data/mutate/{dataset}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        }
      ],
      query_params: [],
      response_shape:
        "{\n  \"transactionId\": \"...\",\n  \"results\": [\n    { \"id\": \"drafts.playground-upsert-1\", \"operation\": \"unpublish\", \"document\": { /* envelope, _draft=true */ } }\n  ]\n}\n",
      possible_errors: [:not_found, :unauthorized, :malformed],
      expect: {200, :mutate_result_has_envelope}
    },
    %{
      id: "mutate-discardDraft",
      label: "discardDraft",
      auth: :token,
      description: "Delete `drafts.<id>` without touching the published document.",
      category: "Mutate",
      kind: :endpoint,
      method: "POST",
      body_example: %{
        "mutations" => [
          %{
            "createOrReplace" => %{
              "_id" => "playground-discard-1",
              "_type" => "post",
              "title" => "Discard this draft"
            }
          },
          %{"discardDraft" => %{"id" => "playground-discard-1", "type" => "post"}}
        ]
      },
      path_template: "/v1/data/mutate/{dataset}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        }
      ],
      query_params: [],
      response_shape:
        "{\n  \"transactionId\": \"...\",\n  \"results\": [\n    { \"id\": \"drafts.playground-discard-1\", \"operation\": \"createOrReplace\", \"document\": { /* envelope */ } },\n    { \"id\": \"drafts.playground-discard-1\", \"operation\": \"discardDraft\", \"document\": { /* envelope of deleted draft */ } }\n  ]\n}\n",
      possible_errors: [:not_found, :unauthorized, :malformed],
      expect: {200, :mutate_result_has_envelope}
    },
    %{
      id: "mutate-delete",
      label: "delete",
      auth: :token,
      description: "Delete both `<id>` and `drafts.<id>` if they exist.",
      category: "Mutate",
      kind: :endpoint,
      method: "POST",
      body_example: %{
        "mutations" => [
          %{
            "createOrReplace" => %{
              "_id" => "playground-delete-1",
              "_type" => "post",
              "title" => "To be deleted"
            }
          },
          %{"delete" => %{"id" => "playground-delete-1", "type" => "post"}}
        ]
      },
      path_template: "/v1/data/mutate/{dataset}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        }
      ],
      query_params: [],
      response_shape:
        "{\n  \"transactionId\": \"...\",\n  \"results\": [\n    { \"id\": \"playground-upsert-1\", \"operation\": \"delete\", \"document\": { /* envelope before delete */ } }\n  ]\n}\n",
      possible_errors: [:not_found, :unauthorized, :malformed],
      expect: {200, :mutate_result_has_envelope}
    },
    %{
      id: "export-dataset",
      label: "Export dataset",
      runnable: true,
      auth: :token,
      description:
        "Stream all documents as newline-delimited JSON (NDJSON). Each line is a complete document envelope. Response uses Content-Type: application/x-ndjson and chunked transfer encoding. Memory-efficient for large datasets.",
      category: "Export",
      kind: :endpoint,
      method: "GET",
      body_example: nil,
      path_template: "/v1/data/export/{dataset}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        }
      ],
      query_params: [
        %{
          default: "",
          name: "type",
          type: :string,
          notes: "Exact match by document type (e.g., 'post'). Omit to export all types."
        }
      ],
      response_shape:
        "{\"_id\":\"p1\",\"_type\":\"post\",\"_rev\":\"a3f8...\",\"_draft\":false,\"title\":\"Hello\"}\n{\"_id\":\"drafts.p2\",\"_type\":\"post\",\"_rev\":\"b4c9...\",\"_draft\":true,\"title\":\"World\"}\n{\"_id\":\"a1\",\"_type\":\"author\",\"_rev\":\"c5d0...\",\"_draft\":false,\"title\":\"Jane\"}\n",
      possible_errors: [:unauthorized],
      expect: {200, :ok},
      scenarios: [
        %{
          label: "exports NDJSON",
          body: nil,
          expect: {200, :ndjson_response},
          path_overrides: %{},
          query_overrides: %{}
        },
        %{
          label: "export with type filter",
          body: nil,
          expect: {200, :ndjson_response},
          path_overrides: %{},
          query_overrides: %{"type" => "post"}
        },
        %{
          label: "no auth → 401",
          body: nil,
          no_auth: true,
          expect: {401, :error_code_unauthorized},
          path_overrides: %{},
          query_overrides: %{}
        }
      ]
    },
    %{
      id: "history-list",
      label: "List revisions",
      runnable: true,
      auth: :token,
      description:
        "List revision snapshots for a document, newest first. Each mutation (create, update, publish, unpublish, delete, patch) creates a revision. Returns the published document ID — do not include the drafts. prefix.",
      category: "History",
      kind: :endpoint,
      method: "GET",
      body_example: nil,
      path_template: "/v1/data/history/{dataset}/{type}/{doc_id}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        },
        %{default: "post", name: "type", type: :string, notes: "Document type"},
        %{
          default: "p1",
          name: "doc_id",
          type: :string,
          notes:
            "Published document ID (without drafts. prefix). Each revision is stored under the published ID."
        }
      ],
      query_params: [
        %{
          default: "50",
          name: "limit",
          type: :integer,
          notes: "1–200, default 50"
        }
      ],
      response_shape:
        "{\n  \"revisions\": [\n    {\n      \"id\": \"550e8400-e29b-41d4-a716-446655440000\",\n      \"action\": \"publish\",\n      \"title\": \"My Post Title\",\n      \"status\": \"published\",\n      \"timestamp\": \"2026-04-16T12:00:00Z\"\n    }\n  ],\n  \"count\": 3\n}\n",
      possible_errors: [:unauthorized, :not_found],
      expect: {200, :ok},
      scenarios: [
        %{
          label: "lists revisions",
          body: nil,
          expect: {200, :has_revisions_list},
          path_overrides: %{},
          query_overrides: %{}
        },
        %{
          label: "no auth → 401",
          body: nil,
          no_auth: true,
          expect: {401, :error_code_unauthorized},
          path_overrides: %{},
          query_overrides: %{}
        }
      ]
    },
    %{
      id: "history-show",
      label: "Get revision",
      runnable: false,
      auth: :token,
      description:
        "Fetch a single revision by UUID. Returns the full content snapshot as it existed at that point in time. Use this to inspect what changed between revisions.",
      category: "History",
      kind: :endpoint,
      method: "GET",
      body_example: nil,
      path_template: "/v1/data/revision/{dataset}/{id}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        },
        %{
          default: "",
          name: "id",
          type: :string,
          notes: "Revision UUID (from the list revisions endpoint)"
        }
      ],
      query_params: [],
      response_shape:
        "{\n  \"revision\": {\n    \"id\": \"550e8400-e29b-41d4-a716-446655440000\",\n    \"doc_id\": \"p1\",\n    \"type\": \"post\",\n    \"dataset\": \"production\",\n    \"action\": \"publish\",\n    \"title\": \"My Post Title\",\n    \"status\": \"published\",\n    \"content\": {\"category\": \"Tech\", \"body\": \"...\"},\n    \"timestamp\": \"2026-04-16T12:00:00Z\"\n  }\n}\n",
      possible_errors: [:unauthorized, :not_found],
      expect: nil
    },
    %{
      id: "history-restore",
      label: "Restore revision",
      runnable: false,
      auth: :token,
      description:
        "Restore a document to a previous revision. Creates or updates the draft at drafts.{doc_id} with the revision's content. The published version is not affected — you must publish separately.",
      category: "History",
      kind: :endpoint,
      method: "POST",
      body_example: %{"type" => "post"},
      path_template: "/v1/data/revision/{dataset}/{id}/restore",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        },
        %{
          default: "",
          name: "id",
          type: :string,
          notes: "Revision UUID to restore"
        }
      ],
      query_params: [],
      response_shape:
        "{\n  \"restored\": true,\n  \"document\": {\n    \"_id\": \"drafts.p1\",\n    \"_type\": \"post\",\n    \"_rev\": \"new-rev-hash...\",\n    \"_draft\": true,\n    \"_publishedId\": \"p1\",\n    \"_createdAt\": \"2026-04-16T12:30:00Z\",\n    \"_updatedAt\": \"2026-04-16T12:30:00Z\",\n    \"title\": \"Restored Title\"\n  }\n}\n",
      possible_errors: [:unauthorized, :not_found],
      expect: nil
    },
    %{
      id: "analytics-overview",
      label: "Dataset stats",
      runnable: true,
      auth: :token,
      description:
        "Dataset overview: total document count, per-type breakdown (total/published/drafts), and the 50 most recent mutation events. Counts include both published and draft documents.",
      category: "Analytics",
      kind: :endpoint,
      method: "GET",
      body_example: nil,
      path_template: "/v1/data/analytics/{dataset}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        }
      ],
      query_params: [],
      response_shape:
        "{\n  \"dataset\": \"production\",\n  \"total_documents\": 121,\n  \"types\": [\n    {\"type\": \"post\", \"total\": 65, \"published\": 19, \"drafts\": 46},\n    {\"type\": \"author\", \"total\": 8, \"published\": 4, \"drafts\": 4}\n  ],\n  \"recent_activity\": [\n    {\n      \"id\": 1561,\n      \"type\": \"post\",\n      \"doc_id\": \"drafts.my-post\",\n      \"mutation\": \"create\",\n      \"timestamp\": \"2026-04-16T22:52:27Z\"\n    }\n  ]\n}\n",
      possible_errors: [:unauthorized],
      expect: {200, :ok},
      scenarios: [
        %{
          label: "returns stats",
          body: nil,
          expect: {200, :analytics_has_types},
          path_overrides: %{},
          query_overrides: %{}
        },
        %{
          label: "empty dataset",
          body: nil,
          expect: {200, :analytics_empty},
          path_overrides: %{"dataset" => "nonexistent"},
          query_overrides: %{}
        },
        %{
          label: "no auth → 401",
          body: nil,
          no_auth: true,
          expect: {401, :error_code_unauthorized},
          path_overrides: %{},
          query_overrides: %{}
        }
      ]
    },
    %{
      id: "listen-sse",
      label: "SSE listen",
      runnable: false,
      auth: :token,
      description:
        "Server-Sent Events stream of mutations. Supply Last-Event-ID for resume. Docs-only here — the playground does not stream; use curl -N to try it from the command line.",
      category: "Real-time",
      kind: :endpoint,
      method: "GET",
      body_example: nil,
      path_template: "/v1/data/listen/{dataset}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        }
      ],
      query_params: [
        %{
          default: "",
          name: "lastEventId",
          type: :integer,
          notes: "Resume cursor (or use Last-Event-ID header)"
        }
      ],
      response_shape:
        "event: welcome\ndata: {\"type\":\"welcome\"}\n\nid: 42\nevent: mutation\ndata: {\"eventId\":42,\"mutation\":\"create\",\"type\":\"post\",\"documentId\":\"drafts.hello\",\"rev\":\"...\",\"previousRev\":null,\"result\":{...envelope...}}\n",
      possible_errors: [:unauthorized],
      expect: nil
    },
    %{
      id: "schemas-list",
      label: "List schemas",
      auth: :admin,
      description:
        "Admin list of every schema in the dataset. Response carries _schemaVersion: 1.",
      category: "Schemas",
      kind: :endpoint,
      method: "GET",
      body_example: nil,
      path_template: "/v1/schemas/{dataset}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        }
      ],
      query_params: [],
      response_shape:
        "{\n  \"_schemaVersion\": 1,\n  \"schemas\": [\n    { \"name\": \"post\", \"title\": \"Post\", \"icon\": \"file-text\", \"visibility\": \"public\", \"fields\": [ ... ] }\n  ]\n}\n",
      possible_errors: [:unauthorized, :forbidden],
      expect: {200, :schema_version_1},
      scenarios: [
        %{
          label: "lists schemas",
          body: nil,
          expect: {200, :schema_version_1},
          path_overrides: %{},
          query_overrides: %{}
        }
      ]
    },
    %{
      id: "schemas-show",
      label: "Show schema",
      auth: :admin,
      description: "Admin fetch of a single schema by name.",
      category: "Schemas",
      kind: :endpoint,
      method: "GET",
      body_example: nil,
      path_template: "/v1/schemas/{dataset}/{name}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        },
        %{default: "post", name: "name", type: :string, notes: "Schema name"}
      ],
      query_params: [],
      response_shape:
        "{\n  \"_schemaVersion\": 1,\n  \"schema\": {\n    \"name\": \"post\", \"title\": \"Post\", \"icon\": \"file-text\",\n    \"visibility\": \"public\", \"fields\": [ ... ]\n  }\n}\n",
      possible_errors: [:not_found, :unauthorized, :forbidden],
      expect: {200, :schema_version_1_show},
      scenarios: [
        %{
          label: "shows post schema",
          body: nil,
          expect: {200, :schema_version_1_show},
          path_overrides: %{"name" => "post"},
          query_overrides: %{}
        }
      ]
    },
    %{
      id: "ref-schemas",
      label: "Schema reference",
      description:
        "Live reference for every schema in this dataset — legacy seeds AND plugin-registered schemas. Updates automatically when schemas are added, edited, or removed via the Schema CRUD endpoints.",
      category: "Schemas",
      kind: :reference,
      render_key: :schema_browser
    },
    %{
      id: "webhooks-list",
      label: "List webhooks",
      runnable: true,
      auth: :admin,
      description: "List all webhook subscriptions for a dataset. Requires admin token.",
      category: "Webhooks",
      kind: :endpoint,
      method: "GET",
      body_example: nil,
      path_template: "/v1/webhooks/{dataset}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        }
      ],
      query_params: [],
      response_shape:
        "{\n  \"webhooks\": [\n    {\n      \"id\": \"550e8400-...\",\n      \"name\": \"Notify Slack\",\n      \"url\": \"https://hooks.slack.com/...\",\n      \"dataset\": \"production\",\n      \"events\": [\"publish\"],\n      \"types\": [\"post\"],\n      \"active\": true,\n      \"created_at\": \"2026-04-16T12:00:00Z\",\n      \"updated_at\": \"2026-04-16T12:00:00Z\"\n    }\n  ]\n}\n",
      possible_errors: [:unauthorized, :forbidden],
      expect: {200, :ok},
      scenarios: [
        %{
          label: "lists webhooks",
          body: nil,
          expect: {200, :has_webhooks_list},
          path_overrides: %{},
          query_overrides: %{}
        },
        %{
          label: "no auth → 401",
          body: nil,
          no_auth: true,
          expect: {401, :error_code_unauthorized},
          path_overrides: %{},
          query_overrides: %{}
        }
      ]
    },
    %{
      id: "webhooks-create",
      label: "Create webhook",
      runnable: true,
      auth: :admin,
      description:
        "Register a webhook subscription. The webhook fires asynchronously on matching mutations. Empty events array matches ALL mutation types. Empty types array matches ALL document types. Requires admin token. Returns 201 on success. Valid events: create, update, publish, unpublish, delete, discardDraft, patch.",
      category: "Webhooks",
      kind: :endpoint,
      method: "POST",
      body_example: %{
        "events" => ["publish"],
        "name" => "Notify Slack",
        "secret" => "optional-hmac-secret",
        "types" => ["post"],
        "url" => "https://hooks.slack.com/services/..."
      },
      path_template: "/v1/webhooks/{dataset}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        }
      ],
      query_params: [],
      response_shape:
        "{\n  \"webhook\": {\n    \"id\": \"550e8400-...\",\n    \"name\": \"Notify Slack\",\n    \"url\": \"https://hooks.slack.com/...\",\n    \"dataset\": \"production\",\n    \"events\": [\"publish\"],\n    \"types\": [\"post\"],\n    \"active\": true,\n    \"created_at\": \"2026-04-16T12:00:00Z\",\n    \"updated_at\": \"2026-04-16T12:00:00Z\"\n  }\n}\n",
      possible_errors: [:unauthorized, :forbidden, :validation_failed],
      expect: {201, :ok}
    },
    %{
      id: "webhooks-delete",
      label: "Delete webhook",
      runnable: false,
      auth: :admin,
      description:
        "Permanently remove a webhook subscription. Pending deliveries for this webhook are cancelled. Requires admin token.",
      category: "Webhooks",
      kind: :endpoint,
      method: "DELETE",
      body_example: nil,
      path_template: "/v1/webhooks/{dataset}/{id}",
      path_params: [
        %{
          default: "production",
          name: "dataset",
          type: :string,
          notes: "Dataset name"
        },
        %{
          default: "",
          name: "id",
          type: :string,
          notes: "Webhook UUID (from the list webhooks endpoint)"
        }
      ],
      query_params: [],
      response_shape: "{\"deleted\": \"uuid\"}",
      possible_errors: [:unauthorized, :forbidden, :not_found],
      expect: nil
    }
  ]

  @doc "The pre-split static catalog for dataset \"production\"."
  @spec catalog() :: [map()]
  def catalog, do: @catalog
end
