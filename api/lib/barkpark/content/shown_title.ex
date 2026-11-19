defmodule Barkpark.Content.ShownTitle do
  @moduledoc """
  The title a caller is shown for stored rows, in an answer that carries the
  rows' titles but not their `Envelope.render/3`: graph nodes, tag listings,
  backlinks, finder hits, search highlights.

  One rule for all of them: `Envelope.title/3` under the row's own tenant
  schema, the rule `Papers.reader_schema/4` holds a Paper to. Only a Paper can
  be shown a title other than its stored one (its reader title, when the
  caller's view hides the heading it was taken from), so every other row
  keeps its stored title and costs no read. A row that is not a full
  `%Document{}` has its content and tenant read, one query for all of them, by
  primary key.
  """

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Envelope, Schema}
  alias Barkpark.Repo

  @paper "paper"

  @doc """
  `rows` with each Paper's `:title` replaced by the one `caller_context` is
  shown. A row carries `:type` and `:title`, and its primary key under
  `pk_key` (default `:id`).
  """
  @spec put([map()], String.t() | nil, term(), atom()) :: [map()]
  def put(rows, dataset, caller_context, pk_key \\ :id) when is_list(rows) do
    shown(rows, dataset, caller_context, &Map.get(&1, pk_key), &documents(&1, pk_key))
  end

  @doc """
  As `put/4` for rows that carry no primary key: each is read by its
  `:doc_id` under `opts`, the same scope the answer read the rows with
  (`Content.get_documents_by_ids/3`).
  """
  @spec put_by_doc_id([map()], String.t(), keyword(), term()) :: [map()]
  def put_by_doc_id(rows, dataset, opts, caller_context) when is_list(rows) do
    load = fn papers ->
      papers
      |> Enum.map(& &1.doc_id)
      |> Enum.uniq()
      |> Content.get_documents_by_ids(dataset, opts)
    end

    shown(rows, dataset, caller_context, & &1.doc_id, load)
  end

  defp shown(rows, dataset, caller_context, key, load) do
    case Enum.filter(rows, &paper?/1) do
      [] ->
        rows

      papers ->
        docs = load.(papers)
        schemas = schemas(Map.values(docs), dataset)

        Enum.map(rows, fn row ->
          with true <- paper?(row),
               %{} = doc <- Map.get(docs, key.(row)) do
            schema = Map.get(schemas, tenant(doc, dataset))
            shown = Envelope.title(%{doc | title: row.title}, schema, caller_context)
            Map.put(row, :title, shown)
          else
            _ -> row
          end
        end)
    end
  end

  defp paper?(row), do: Map.get(row, :type) == @paper

  # The stored row behind each Paper: the row itself when it is one, else read.
  defp documents(papers, pk_key) do
    {loaded, ids} =
      Enum.reduce(papers, {%{}, []}, fn
        %Document{id: id} = doc, {acc, ids} -> {Map.put(acc, id, doc), ids}
        row, {acc, ids} -> {acc, [Map.get(row, pk_key) | ids]}
      end)

    case Enum.reject(ids, &is_nil/1) do
      [] ->
        loaded

      ids ->
        Document
        |> where([d], d.id in ^Enum.uniq(ids))
        |> select([d], %{
          id: d.id,
          doc_id: d.doc_id,
          type: d.type,
          title: d.title,
          content: d.content,
          dataset: d.dataset,
          workspace_id: d.workspace_id,
          project_id: d.project_id
        })
        |> Repo.all()
        |> Map.new(&{&1.id, &1})
        |> Map.merge(loaded)
    end
  end

  # The Paper schema of each row's own tenant and dataset, read once each.
  defp schemas(docs, dataset) do
    docs
    |> Enum.map(&tenant(&1, dataset))
    |> Enum.uniq()
    |> Map.new(fn {dataset, workspace_id, project_id} = key ->
      scope = [workspace_id: workspace_id, project_id: project_id]

      case Schema.get_schema_for_redaction(@paper, dataset, scope) do
        {:ok, schema} -> {key, schema}
        _ -> {key, nil}
      end
    end)
  end

  defp tenant(doc, dataset) do
    {Map.get(doc, :dataset) || dataset || "production", Map.get(doc, :workspace_id),
     Map.get(doc, :project_id)}
  end
end
