defmodule Barkpark.ApiTester.Endpoints.Export do
  @moduledoc """
  Export catalog endpoint (NDJSON dataset export) for the Studio API Docs
  + Playground pane. Split out of `Barkpark.ApiTester.Endpoints` (the
  facade) — the entry is moved verbatim; see that module's @moduledoc for
  the spec shape.

  `entries/1` returns this category's slice of the full catalog, in the
  exact order the facade concatenates it.
  """

  @doc "Export endpoint(s), in catalog order, with the dataset interpolated."
  @spec entries(String.t()) :: [map()]
  def entries(dataset) do
    [
      export_dataset(dataset)
    ]
  end

  defp export_dataset(dataset) do
    %{
      id: "export-dataset",
      category: "Export",
      label: "Export dataset",
      kind: :endpoint,
      auth: :token,
      method: "GET",
      path_template: "/v1/data/export/{dataset}",
      description:
        "Stream all documents as newline-delimited JSON (NDJSON). Each line is a complete document envelope. Response uses Content-Type: application/x-ndjson and chunked transfer encoding. Memory-efficient for large datasets.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}
      ],
      query_params: [
        %{
          name: "type",
          type: :string,
          default: "",
          notes: "Exact match by document type (e.g., 'post'). Omit to export all types."
        }
      ],
      body_example: nil,
      response_shape: """
      {"_id":"p1","_type":"post","_rev":"a3f8...","_draft":false,"title":"Hello"}
      {"_id":"drafts.p2","_type":"post","_rev":"b4c9...","_draft":true,"title":"World"}
      {"_id":"a1","_type":"author","_rev":"c5d0...","_draft":false,"title":"Jane"}
      """,
      possible_errors: [:unauthorized],
      expect: {200, :ok},
      runnable: true,
      scenarios: [
        %{
          label: "exports NDJSON",
          path_overrides: %{},
          query_overrides: %{},
          body: nil,
          expect: {200, :ndjson_response}
        },
        %{
          label: "export with type filter",
          path_overrides: %{},
          query_overrides: %{"type" => "post"},
          body: nil,
          expect: {200, :ndjson_response}
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
end
