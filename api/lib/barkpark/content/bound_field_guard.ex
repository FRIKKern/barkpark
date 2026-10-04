defmodule Barkpark.Content.BoundFieldGuard do
  @moduledoc """
  A document body may not bind a field its schema keeps from public readers
  (owner ruling #21, 2026-10-03, task-9a7298f03aad0c42).

  A bound block (`field-*` and friends carrying `"fieldName"`, see
  `Barkpark.PortableDoc.Projection`) holds its value inside `content["blocks"]`,
  and the body is the public artifact: the paper reader, `body_html` and the
  API's `blocks` print it. `Envelope` redacts `content[fieldName]` for a caller
  who may not read the field, but the block itself still carried the value, so a
  private field bound into the body was published by the binding.

  The rule is enforced at WRITE time: a block list that binds a field the type's
  schema declares `private`, `visibility: private | owner_only`, or a non-empty
  `readable_by` is refused with `{:error, {:private_field_bound, names}}`, a 422
  `private_field_bound` on the wire. "Restricted" is exactly what
  `Envelope.field_readable?/3` answers for the anonymous reader, so the write
  rule and the read redaction cannot disagree. Nested blocks (a `section`'s
  children) are checked too.

  Called on every author write path that persists blocks: the paper block ops
  and whole-paper upserts/ingest (`Papers.BlockOps`), suggestion acceptance
  (`Papers.Proposals`), and the generic document writer (`Content.Writer`),
  which document block ops and `/v1/data/mutate` reach.
  """

  alias Barkpark.Content.{CallerContext, Envelope, Schema}

  @doc """
  `:ok`, or `{:error, {:private_field_bound, field_names}}` when `blocks`
  (or `content["blocks"]`) binds a restricted field of `type`'s schema.

  `scope` is `[workspace_id:, project_id:]` (nil values ignored) or a bare
  workspace id. The schema is the one the read side redacts with. A type
  with no schema, or a block list that binds nothing, is always `:ok`.
  """
  @spec check(map() | list(), String.t(), String.t(), keyword() | binary() | nil) ::
          :ok | {:error, {:private_field_bound, [String.t()]}}
  def check(%{"blocks" => blocks}, type, dataset, scope), do: check(blocks, type, dataset, scope)

  def check(blocks, type, dataset, scope)
      when is_list(blocks) and is_binary(type) and is_binary(dataset) do
    case bound_names(blocks) do
      [] ->
        :ok

      names ->
        case schema_for_write(type, dataset, scope_opts(scope)) do
          {:ok, schema} ->
            anonymous = CallerContext.anonymous()

            names
            |> Enum.reject(&Envelope.field_readable?(schema, &1, anonymous))
            |> case do
              [] -> :ok
              restricted -> {:error, {:private_field_bound, restricted}}
            end

          _ ->
            :ok
        end
    end
  end

  def check(_content, _type, _dataset, _scope), do: :ok

  @doc "The refusal message the editor and the API show for `names`."
  @spec message([String.t()]) :: String.t()
  def message(names) when is_list(names) do
    list = Enum.map_join(names, ", ", &"\"#{&1}\"")

    "The body binds #{list}, which the schema keeps private. The body is public, " <>
      "so a private field cannot be bound into it. Unbind the block, or make the field public."
  end

  @doc """
  For editors that already render a lifecycle halt as a banner: turn this
  refusal into `{:error, {:halted, message}}`. Any other result passes through.
  """
  @spec as_halt(term()) :: term()
  def as_halt({:error, {:private_field_bound, names}}) when is_list(names),
    do: {:error, {:halted, message(names)}}

  def as_halt(result), do: result

  # Every distinct fieldName bound anywhere in the block tree, in first-seen order.
  defp bound_names(blocks) do
    blocks
    |> collect([])
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp collect(blocks, acc) when is_list(blocks), do: Enum.reduce(blocks, acc, &collect_block/2)
  defp collect(_other, acc), do: acc

  defp collect_block(%{} = block, acc) do
    acc =
      case Map.get(block, "fieldName") do
        name when is_binary(name) and name != "" -> [name | acc]
        _ -> acc
      end

    collect(Map.get(block, "blocks"), acc)
  end

  defp collect_block(_other, acc), do: acc

  defp scope_opts(ws) when is_binary(ws), do: [workspace_id: ws]

  defp scope_opts(opts) when is_list(opts) do
    opts
    |> Keyword.take([:workspace_id, :project_id])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp scope_opts(_), do: []

  # The schema the READ side redacts this type with
  # (`Schema.get_schema_for_redaction/3`: exact scope, then the shared layer),
  # so the write refuses exactly what an anonymous read would hide.
  defp schema_for_write(type, dataset, scope_opts) do
    case Schema.get_schema_for_redaction(type, dataset, scope_opts) do
      {:ok, schema} -> {:ok, schema}
      _ -> {:error, :not_found}
    end
  end
end
