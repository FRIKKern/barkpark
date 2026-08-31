defmodule Barkpark.ApiTester.Endpoints.History do
  @moduledoc """
  History / revision catalog endpoints for the Studio API Docs + Playground
  pane. Split out of `Barkpark.ApiTester.Endpoints` (the facade) — each
  entry is moved verbatim; see that module's @moduledoc for the spec shape.

  `entries/1` returns this category's slice of the full catalog, in the
  exact order the facade concatenates it.
  """

  @doc "History endpoints (list / show / restore), in catalog order, with the dataset interpolated."
  @spec entries(String.t()) :: [map()]
  def entries(dataset) do
    [
      history_list(dataset),
      history_show(dataset),
      history_restore(dataset)
    ]
  end

  defp history_list(dataset) do
    %{
      id: "history-list",
      category: "History",
      label: "List revisions",
      kind: :endpoint,
      auth: :token,
      method: "GET",
      path_template: "/v1/data/history/{dataset}/{type}/{doc_id}",
      description:
        "List revision snapshots for a document, newest first. Each mutation (create, update, publish, unpublish, delete, patch) creates a revision. Returns the published document ID — do not include the drafts. prefix.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"},
        %{name: "type", type: :string, default: "post", notes: "Document type"},
        %{
          name: "doc_id",
          type: :string,
          default: "p1",
          notes:
            "Published document ID (without drafts. prefix). Each revision is stored under the published ID."
        }
      ],
      query_params: [
        %{name: "limit", type: :integer, default: "50", notes: "1–200, default 50"}
      ],
      body_example: nil,
      response_shape: """
      {
        "revisions": [
          {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "action": "publish",
            "title": "My Post Title",
            "status": "published",
            "timestamp": "2026-04-16T12:00:00Z"
          }
        ],
        "count": 3
      }
      """,
      possible_errors: [:unauthorized, :not_found],
      expect: {200, :ok},
      runnable: true,
      scenarios: [
        %{
          label: "lists revisions",
          path_overrides: %{},
          query_overrides: %{},
          body: nil,
          expect: {200, :has_revisions_list}
        },
        %{
          label: "no auth → 401",
          path_overrides: %{},
          query_overrides: %{},
          body: nil,
          expect: {401, :error_code_unauthorized},
          no_auth: true
        }
      ]
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
      description:
        "Fetch a single revision by UUID. Returns the full content snapshot as it existed at that point in time. Use this to inspect what changed between revisions.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"},
        %{
          name: "id",
          type: :string,
          default: "",
          notes: "Revision UUID (from the list revisions endpoint)"
        }
      ],
      query_params: [],
      body_example: nil,
      response_shape: """
      {
        "revision": {
          "id": "550e8400-e29b-41d4-a716-446655440000",
          "doc_id": "p1",
          "type": "post",
          "dataset": "production",
          "action": "publish",
          "title": "My Post Title",
          "status": "published",
          "content": {"category": "Tech", "body": "..."},
          "timestamp": "2026-04-16T12:00:00Z"
        }
      }
      """,
      possible_errors: [:unauthorized, :not_found],
      # wb-api-tester-unverified-badge: no real revision id is available without
      # a prior history-list round-trip, so the default ("") `id` never reaches
      # this controller's own "revision not found" logic — verified live: it
      # falls through to the unrelated generic-document 404 envelope instead (a
      # route mismatch, not this endpoint's contract). Asserting that accidental
      # shape would be exactly the kind of check-that-isn't-a-check this task
      # removes. runnable: false is the honest choice.
      expect: nil,
      runnable: false
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
      description:
        "Restore a document to a previous revision. Creates or updates the draft at drafts.{doc_id} with the revision's content. The published version is not affected — you must publish separately.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"},
        %{name: "id", type: :string, default: "", notes: "Revision UUID to restore"}
      ],
      query_params: [],
      body_example: %{"type" => "post"},
      response_shape: """
      {
        "restored": true,
        "document": {
          "_id": "drafts.p1",
          "_type": "post",
          "_rev": "new-rev-hash...",
          "_draft": true,
          "_publishedId": "p1",
          "_createdAt": "2026-04-16T12:30:00Z",
          "_updatedAt": "2026-04-16T12:30:00Z",
          "title": "Restored Title"
        }
      }
      """,
      possible_errors: [:unauthorized, :not_found],
      # wb-api-tester-unverified-badge: same as history-show — the default ("")
      # `id` doesn't reach this controller's "revision not found" logic, it hits
      # an unrelated generic-document 404 via route mismatch (verified live).
      # This endpoint is also a WRITE (restores a draft) — doubly not something
      # to auto-run with a fabricated id. runnable: false is the honest choice.
      expect: nil,
      runnable: false
    }
  end
end
