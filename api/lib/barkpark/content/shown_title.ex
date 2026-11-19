defmodule Barkpark.Content.ShownTitle do
  @moduledoc """
  The title a caller is shown for stored rows, in an answer that carries the
  rows' titles but not their `Envelope.render/3`: graph nodes, tag listings,
  finder hits.

  One rule for all of them: `Envelope.title/3` under the row's own tenant
  schema, the rule `Papers.reader_schema/4` holds a Paper to. Only a Paper can
  be shown a title other than its stored one (its reader title, when the
  schema hides the heading it was taken from), so every other row keeps its
  stored title without a schema read. A row selected without its content has
  it read, one query for all such Papers, by primary key.
  """

  import Ecto.Query

  alias Barkpark.Content.{Document, Envelope, Schema}
  alias Barkpark.Repo

  @doc """
  `rows` with each `:title` replaced by the one `caller_context` is shown.
  A row is a map or struct with `:type`, `:doc_id` and `:title`, plus
  `:content` when it was read, or `:id` (the primary key) when it was not.
  """
  @spec put([map()], String.t() | nil, term()) :: [map()]
  def put(rows, dataset, caller_context) when is_list(rows) do
    titles = titles(rows, dataset, caller_context)
    Enum.map(rows, &put_title(&1, titles))
  end

  @doc "The title `caller_context` is shown for one row; see `put/3`."
  @spec of(map(), String.t() | nil, term()) :: String.t() | nil
  def of(row, dataset, caller_context) do
    [row] = put([row], dataset, caller_context)
    row.title
  end

  defp put_title(%{type: "paper"} = row, titles) do
    case Map.fetch(titles, key(row)) do
      {:ok, title} -> Map.put(row, :title, title)
      :error -> row
    end
  end

  defp put_title(row, _titles), do: row

  defp titles(rows, dataset, caller_context) do
    papers = Enum.filter(rows, &match?(%{type: "paper"}, &1))

    case papers do
      [] ->
        %{}

      _ ->
        {schemas, _} =
          Enum.map_reduce(papers, %{}, fn row, cache ->
            schema_key = {Map.get(row, :workspace_id), Map.get(row, :project_id)}

            case Map.fetch(cache, schema_key) do
              {:ok, schema} -> {{row, schema}, cache}
              :error -> schema(row, dataset) |> then(&{{row, &1}, Map.put(cache, schema_key, &1)})
            end
          end)

        contents = contents(papers)

        Map.new(schemas, fn {row, schema} ->
          row = Map.put(row, :content, content(row, contents))
          {key(row), Envelope.title(row, schema, caller_context)}
        end)
    end
  end

  defp schema(row, dataset) do
    scope = [workspace_id: Map.get(row, :workspace_id), project_id: Map.get(row, :project_id)]

    case Schema.get_schema_for_redaction("paper", dataset || "production", scope) do
      {:ok, schema} -> schema
      _ -> nil
    end
  end

  # The content of rows selected without it, read by primary key.
  defp contents(papers) do
    ids =
      for row <- papers, not is_map(Map.get(row, :content)), id = Map.get(row, :id), id != nil,
          do: id

    case ids do
      [] ->
        %{}

      ids ->
        Document
        |> where([d], d.id in ^ids)
        |> select([d], {d.id, d.content})
        |> Repo.all()
        |> Map.new()
    end
  end

  defp content(row, contents) do
    case Map.get(row, :content) do
      %{} = content -> content
      _ -> Map.get(contents, Map.get(row, :id), %{})
    end
  end

  defp key(row), do: {Map.get(row, :id), Map.get(row, :doc_id)}
end
