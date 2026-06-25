defmodule Barkpark.ApiTester.Endpoints.Mutate do
  @moduledoc """
  Mutate catalog endpoints (the 8 mutation kinds) for the Studio API Docs
  + Playground pane. Split out of `Barkpark.ApiTester.Endpoints` (the
  facade) — each entry is moved verbatim; see that module's @moduledoc for
  the spec shape.

  `entries/1` returns this category's slice of the full catalog, in the
  exact order the facade concatenates it.
  """

  @doc "The 8 mutation endpoints (create … delete), in catalog order, with the dataset interpolated."
  @spec entries(String.t()) :: [map()]
  def entries(dataset) do
    [
      mutate_create(dataset),
      mutate_create_or_replace(dataset),
      mutate_create_if_not_exists(dataset),
      mutate_patch(dataset),
      mutate_publish(dataset),
      mutate_unpublish(dataset),
      mutate_discard_draft(dataset),
      mutate_delete(dataset)
    ]
  end

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
end
