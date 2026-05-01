defmodule Barkpark.Repo.Migrations.PromoteBpExportStatus do
  @moduledoc """
  Phase 8 WI1 — promotes `documents.content["bp_export_status"]` from a
  string field (Phase 7 stored a JSON-encoded map inside the string) to a
  native composite map, and default-fills any missing composite subfields.

  Idempotent: running this migration twice yields the same composite shape.
  Reversible: `down/0` collapses the composite back to a plain string
  containing just the `state` value.
  """

  use Ecto.Migration

  @default_fields %{
    "state" => "pending",
    "submission_id" => nil,
    "submitted_at" => nil,
    "staged_at" => nil,
    "polling_at" => nil,
    "accepted_at" => nil,
    "rejected_at" => nil,
    "retry_at" => nil,
    "attempt_count" => 0,
    "signed_off" => false,
    "last_error" => nil
  }

  def up, do: forward(&to_composite/1, repo())
  def down, do: forward(&to_state_string/1, repo())

  @doc """
  Applies the up-transformation to every documents row that has
  `bp_export_status`. Exposed for tests; production callers go through
  `up/0`.
  """
  def apply_up(repo \\ Barkpark.Repo), do: forward(&to_composite/1, repo)

  @doc """
  Applies the down-transformation. Exposed for tests; production callers go
  through `down/0`.
  """
  def apply_down(repo \\ Barkpark.Repo), do: forward(&to_state_string/1, repo)

  defp forward(transform, repo) do
    %{rows: rows} =
      repo.query!("SELECT id, content::text FROM documents WHERE content ? 'bp_export_status'")

    Enum.each(rows, fn [id, content_json] ->
      content = Jason.decode!(content_json)
      existing = Map.get(content, "bp_export_status")
      new_content = Map.put(content, "bp_export_status", transform.(existing))

      repo.query!(
        "UPDATE documents SET content = $1 WHERE id = $2",
        [new_content, id]
      )
    end)
  end

  defp to_composite(nil), do: @default_fields
  defp to_composite(""), do: @default_fields

  defp to_composite(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = map} -> merge_defaults(map)
      _ -> merge_defaults(%{"state" => value})
    end
  end

  defp to_composite(%{} = map), do: merge_defaults(map)
  defp to_composite(_), do: @default_fields

  defp merge_defaults(map) do
    Map.merge(@default_fields, map)
  end

  defp to_state_string(nil), do: ""
  defp to_state_string(s) when is_binary(s), do: s
  defp to_state_string(%{"state" => s}) when is_binary(s), do: s
  defp to_state_string(_), do: ""
end
