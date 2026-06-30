defmodule Barkpark.Content.Export do
  @moduledoc """
  Streaming document export.

  Leaf concern — streams all documents for a dataset as envelope maps,
  optionally filtered by type. Read-only; must be consumed inside a
  `Repo.transaction` (uses `Repo.stream`).

  Extracted from `Barkpark.Content`, which keeps a thin delegating facade.

  Dataset scope mirrors `Barkpark.Content`'s private `scope_to_dataset/3`
  (concern K, still on the facade): resolved via the still-on-facade public
  `resolve_read_dataset_id/2`, then the NULL-tolerant legacy-string OR.
  Workspace scope rides the shared
  `Barkpark.Content.Scope.scope_to_workspace_or_global/3`.
  """

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.{Document, Envelope}

  import Barkpark.Content.Scope, only: [scope_to_workspace_or_global: 3]

  @doc """
  Stream all documents for a dataset as envelope maps. Optionally filter by type.

  Field-visibility redaction rides the same `Envelope.render/3` chokepoint as
  every other read surface: `opts[:caller_context]` (threaded by `scope_opts/1`)
  and the per-`type` schema are passed through so a `private` / `owner_only` /
  allowlisted field is dropped for a non-authorized caller. An admin export
  passes an admin caller_context ⇒ `render/3` is a no-op (full content); a
  no-caller (nil) export now FAILS CLOSED through `render/3` (public-only) and
  is byte-identical to the legacy stream ONLY when the type declares no
  private / encrypted fields. A trusted internal full-content export must pass
  the explicit `:internal` sentinel — never nil. The schema is resolved once
  per distinct `type` and memoised across the (lazy) stream via `Stream.transform`.
  """
  def export_stream(dataset, opts \\ []) do
    type = Keyword.get(opts, :type)
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    caller_context = Keyword.get(opts, :caller_context)

    Document
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> then(fn q ->
      if type, do: where(q, [d], d.type == ^type), else: q
    end)
    |> order_by([d], asc: d.inserted_at)
    |> Repo.stream()
    |> Stream.transform(%{}, fn doc, schema_cache ->
      {schema, schema_cache} = fetch_schema(schema_cache, doc.type, dataset, opts)
      {[Envelope.render(doc, schema, caller_context)], schema_cache}
    end)
  end

  # Resolve (and memoise) the `%SchemaDefinition{}` for a type within one export.
  # A cursor (DECLARE CURSOR) backs `Repo.stream`, so interleaving this scoped
  # `get_schema` read inside the streaming transaction is safe. A missing schema
  # caches nil — `Envelope.render/3` still applies the encrypted-ciphertext guard
  # with no schema, so a marked field never leaks even on an unknown type.
  defp fetch_schema(cache, type, dataset, opts) do
    case Map.fetch(cache, type) do
      {:ok, schema} ->
        {schema, cache}

      :error ->
        schema =
          case Content.get_schema(type, dataset, opts) do
            {:ok, s} -> s
            _ -> nil
          end

        {schema, Map.put(cache, type, schema)}
    end
  end

  # Mirrors `Barkpark.Content`'s private `scope_to_dataset/3` (concern K, still
  # on the facade). Resolves the read dataset_id through the facade's public
  # `resolve_read_dataset_id/2`, then applies the NULL-tolerant legacy-string OR.
  defp scope_to_dataset(query, dataset, opts) do
    case Content.resolve_read_dataset_id(dataset, opts) do
      id when is_binary(id) ->
        where(query, [x], x.dataset_id == ^id or (is_nil(x.dataset_id) and x.dataset == ^dataset))

      _ ->
        where(query, [x], x.dataset == ^dataset)
    end
  end
end
