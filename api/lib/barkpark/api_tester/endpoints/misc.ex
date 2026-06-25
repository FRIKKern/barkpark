defmodule Barkpark.ApiTester.Endpoints.Misc do
  @moduledoc """
  Singleton catalog endpoints with no sibling — Analytics (dataset stats)
  and Real-time (SSE listen) — for the Studio API Docs + Playground pane.
  Folded together to keep the module count lean (YAGNI). Split out of
  `Barkpark.ApiTester.Endpoints` (the facade) — each entry is moved
  verbatim; see that module's @moduledoc for the spec shape.

  `entries/1` returns these entries in the exact order the facade
  concatenates them (analytics then listen-sse).
  """

  @doc "Analytics + Real-time entries, in catalog order, with the dataset interpolated."
  @spec entries(String.t()) :: [map()]
  def entries(dataset) do
    [
      analytics_overview(dataset),
      listen_sse(dataset)
    ]
  end

  defp analytics_overview(dataset) do
    %{
      id: "analytics-overview",
      category: "Analytics",
      label: "Dataset stats",
      kind: :endpoint,
      auth: :token,
      method: "GET",
      path_template: "/v1/data/analytics/{dataset}",
      description:
        "Dataset overview: total document count, per-type breakdown (total/published/drafts), and the 50 most recent mutation events. Counts include both published and draft documents.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}
      ],
      query_params: [],
      body_example: nil,
      response_shape: """
      {
        "dataset": "production",
        "total_documents": 121,
        "types": [
          {"type": "post", "total": 65, "published": 19, "drafts": 46},
          {"type": "author", "total": 8, "published": 4, "drafts": 4}
        ],
        "recent_activity": [
          {
            "id": 1561,
            "type": "post",
            "doc_id": "drafts.my-post",
            "mutation": "create",
            "timestamp": "2026-04-16T22:52:27Z"
          }
        ]
      }
      """,
      possible_errors: [:unauthorized],
      expect: {200, :ok},
      runnable: true,
      scenarios: [
        %{
          label: "returns stats",
          path_overrides: %{},
          query_overrides: %{},
          body: nil,
          expect: {200, :analytics_has_types}
        },
        %{
          label: "empty dataset",
          path_overrides: %{"dataset" => "nonexistent"},
          query_overrides: %{},
          body: nil,
          expect: {200, :analytics_empty}
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
        %{
          name: "lastEventId",
          type: :integer,
          default: "",
          notes: "Resume cursor (or use Last-Event-ID header)"
        }
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
end
