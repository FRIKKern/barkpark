defmodule Barkpark.ApiTester.Endpoints.Schemas do
  @moduledoc """
  Schema catalog endpoints (list / show) plus the live Schema-reference
  page for the Studio API Docs + Playground pane. Split out of
  `Barkpark.ApiTester.Endpoints` (the facade) — each entry is moved
  verbatim; see that module's @moduledoc for the spec shape.

  Note the `ref-schemas` reference page is categorised "Schemas" (not
  "Reference") in the nav, so it lives here, in catalog order after the two
  endpoint entries.

  `entries/1` returns this category's slice of the full catalog, in the
  exact order the facade concatenates it.
  """

  @doc "Schema endpoints + the schema-browser reference, in catalog order, dataset interpolated."
  @spec entries(String.t()) :: [map()]
  def entries(dataset) do
    [
      schemas_list(dataset),
      schemas_show(dataset),
      ref_schema_browser()
    ]
  end

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
      expect: {200, :schema_version_1},
      scenarios: [
        %{
          label: "lists schemas",
          path_overrides: %{},
          query_overrides: %{},
          body: nil,
          expect: {200, :schema_version_1}
        }
      ]
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
      expect: {200, :schema_version_1_show},
      scenarios: [
        %{
          label: "shows post schema",
          path_overrides: %{"name" => "post"},
          query_overrides: %{},
          body: nil,
          expect: {200, :schema_version_1_show}
        }
      ]
    }
  end

  # Phase 8 WI4 — live reference panel that data-drives off
  # `Content.list_schemas/1` so plugin schemas (e.g. book) auto-appear.
  defp ref_schema_browser do
    %{
      id: "ref-schemas",
      category: "Schemas",
      label: "Schema reference",
      kind: :reference,
      render_key: :schema_browser,
      description:
        "Live reference for every schema in this dataset — legacy seeds AND plugin-registered schemas. Updates automatically when schemas are added, edited, or removed via the Schema CRUD endpoints."
    }
  end
end
