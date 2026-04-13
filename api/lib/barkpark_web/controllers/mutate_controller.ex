defmodule BarkparkWeb.MutateController do
  use BarkparkWeb, :controller

  alias Barkpark.Content

  action_fallback BarkparkWeb.FallbackController

  @doc """
  Process an array of mutations. Supports:

    - `create`           — create a new draft document
    - `createOrReplace`  — upsert a document (same as create)
    - `publish`          — copy draft to published, delete draft
    - `unpublish`        — move published back to draft
    - `discardDraft`     — delete draft, keep published
    - `patch`            — update fields on existing doc
    - `delete`           — delete both draft and published
  """
  def mutate(conn, %{"dataset" => dataset, "mutations" => mutations}) when is_list(mutations) do
    results = Enum.map(mutations, &process_mutation(&1, dataset))
    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      docs = Enum.map(results, fn {:ok, doc} -> doc end)

      json(conn, %{
        results:
          Enum.map(docs, fn doc ->
            %{id: doc.doc_id, operation: "mutate"}
          end)
      })
    else
      conn
      |> put_status(:bad_request)
      |> json(%{error: "some mutations failed", details: inspect(errors)})
    end
  end

  def mutate(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "expected {\"mutations\": [...]}"})
  end

  # ── Create: always creates a draft ─────────────────────────────────────────

  defp process_mutation(%{"create" => attrs}, dataset) do
    type = Map.get(attrs, "_type") || Map.get(attrs, "type")
    doc_id = Map.get(attrs, "_id") || Map.get(attrs, "doc_id")

    Content.create_document(type, %{
      "doc_id" => doc_id,
      "title" => Map.get(attrs, "title"),
      "status" => Map.get(attrs, "status", "draft"),
      "content" => Map.drop(attrs, ["_type", "_id", "type", "doc_id", "title", "status"])
    }, dataset)
  end

  defp process_mutation(%{"createOrReplace" => attrs}, dataset) do
    process_mutation(%{"create" => attrs}, dataset)
  end

  # ── Publish: draft → published ─────────────────────────────────────────────

  defp process_mutation(%{"publish" => %{"id" => doc_id, "type" => type}}, dataset) do
    Content.publish_document(doc_id, type, dataset)
  end

  # ── Unpublish: published → draft ───────────────────────────────────────────

  defp process_mutation(%{"unpublish" => %{"id" => doc_id, "type" => type}}, dataset) do
    Content.unpublish_document(doc_id, type, dataset)
  end

  # ── Discard draft: delete draft only ───────────────────────────────────────

  defp process_mutation(%{"discardDraft" => %{"id" => doc_id, "type" => type}}, dataset) do
    Content.discard_draft(doc_id, type, dataset)
  end

  # ── Patch: update fields on existing doc ───────────────────────────────────

  defp process_mutation(%{"patch" => %{"id" => doc_id, "type" => type, "set" => fields}}, dataset) do
    case Content.get_document(doc_id, type, dataset) do
      {:ok, doc} ->
        new_attrs = %{
          "doc_id" => doc_id,
          "title" => Map.get(fields, "title", doc.title),
          "status" => Map.get(fields, "status", doc.status),
          "content" => Map.merge(doc.content || %{}, Map.drop(fields, ["title", "status"]))
        }

        Content.upsert_document(type, new_attrs, dataset)

      error ->
        error
    end
  end

  # ── Delete: removes both draft and published ───────────────────────────────

  defp process_mutation(%{"delete" => %{"id" => doc_id, "type" => type}}, dataset) do
    Content.delete_document(doc_id, type, dataset)
  end

  defp process_mutation(_, _dataset) do
    {:error, "unknown mutation format"}
  end
end
