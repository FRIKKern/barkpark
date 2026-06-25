defmodule Barkpark.ApiTester.Endpoints.Webhooks do
  @moduledoc """
  Webhook catalog endpoints (list / create / delete) for the Studio API
  Docs + Playground pane. Split out of `Barkpark.ApiTester.Endpoints` (the
  facade) — each entry is moved verbatim; see that module's @moduledoc for
  the spec shape.

  `entries/1` returns this category's slice of the full catalog, in the
  exact order the facade concatenates it.
  """

  @doc "Webhook endpoints (list / create / delete), in catalog order, dataset interpolated."
  @spec entries(String.t()) :: [map()]
  def entries(dataset) do
    [
      webhooks_list(dataset),
      webhooks_create(dataset),
      webhooks_delete(dataset)
    ]
  end

  defp webhooks_list(dataset) do
    %{
      id: "webhooks-list",
      category: "Webhooks",
      label: "List webhooks",
      kind: :endpoint,
      auth: :admin,
      method: "GET",
      path_template: "/v1/webhooks/{dataset}",
      description: "List all webhook subscriptions for a dataset. Requires admin token.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}
      ],
      query_params: [],
      body_example: nil,
      response_shape: """
      {
        "webhooks": [
          {
            "id": "550e8400-...",
            "name": "Notify Slack",
            "url": "https://hooks.slack.com/...",
            "dataset": "production",
            "events": ["publish"],
            "types": ["post"],
            "active": true,
            "created_at": "2026-04-16T12:00:00Z",
            "updated_at": "2026-04-16T12:00:00Z"
          }
        ]
      }
      """,
      possible_errors: [:unauthorized, :forbidden],
      expect: {200, :ok},
      runnable: true,
      scenarios: [
        %{
          label: "lists webhooks",
          path_overrides: %{},
          query_overrides: %{},
          body: nil,
          expect: {200, :has_webhooks_list}
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

  defp webhooks_create(dataset) do
    %{
      id: "webhooks-create",
      category: "Webhooks",
      label: "Create webhook",
      kind: :endpoint,
      auth: :admin,
      method: "POST",
      path_template: "/v1/webhooks/{dataset}",
      description:
        "Register a webhook subscription. The webhook fires asynchronously on matching mutations. Empty events array matches ALL mutation types. Empty types array matches ALL document types. Requires admin token. Returns 201 on success. Valid events: create, update, publish, unpublish, delete, discardDraft, patch.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"}
      ],
      query_params: [],
      body_example: %{
        "name" => "Notify Slack",
        "url" => "https://hooks.slack.com/services/...",
        "events" => ["publish"],
        "types" => ["post"],
        "secret" => "optional-hmac-secret"
      },
      response_shape: """
      {
        "webhook": {
          "id": "550e8400-...",
          "name": "Notify Slack",
          "url": "https://hooks.slack.com/...",
          "dataset": "production",
          "events": ["publish"],
          "types": ["post"],
          "active": true,
          "created_at": "2026-04-16T12:00:00Z",
          "updated_at": "2026-04-16T12:00:00Z"
        }
      }
      """,
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
      description:
        "Permanently remove a webhook subscription. Pending deliveries for this webhook are cancelled. Requires admin token.",
      path_params: [
        %{name: "dataset", type: :string, default: dataset, notes: "Dataset name"},
        %{
          name: "id",
          type: :string,
          default: "",
          notes: "Webhook UUID (from the list webhooks endpoint)"
        }
      ],
      query_params: [],
      body_example: nil,
      response_shape: "{\"deleted\": \"uuid\"}",
      possible_errors: [:unauthorized, :forbidden, :not_found],
      expect: nil,
      runnable: true
    }
  end
end
