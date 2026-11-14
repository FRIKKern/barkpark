defmodule BarkparkWeb.TasksController.CountScope do
  @moduledoc """
  The scope the task-list card counts run under: the caller's workspace and
  project scope plus the dataset the request is held to.

  `ScopeHelpers.scope_opts/1` carries no dataset, so the child counts on a list
  card (`Params.batch_child_counts/2`, `batch_live_child_counts/2`,
  `batch_live_parents/2`) spanned every dataset of the workspace. A
  dataset-bound token always has `params["dataset"]`
  (`BarkparkWeb.Plugs.BoundDataset` fills it), so its cards count only its own
  dataset's rows. A caller naming no dataset keeps the workspace-wide count.

  Task edges had the same hole one table over (task-0a3dcbd61d618a00): a
  `task_edges` row joins two documents by primary key and carries no dataset,
  so `GET /v1/tasks/:id/edges` and `Params.batch_edge_counts/1` handed a
  dataset-bound token the row at the far end of an edge (title, doc_id,
  dataset) and a count about it. `held/2` and `edge_counts/2` keep only the
  far ends that live in the dataset the request is held to. They are
  projections only: the ready query and the claim door read the edges
  themselves, so a blocker in another dataset still blocks.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tasks.Edge
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.TasksController.Params

  @spec of(Plug.Conn.t()) :: keyword()
  def of(%Plug.Conn{} = conn) do
    Params.put_opt(ScopeHelpers.scope_opts(conn), :dataset, dataset(conn))
  end

  @doc """
  The edge-end documents the request may read: all of them for a caller
  naming no dataset, only the held dataset's rows otherwise.
  """
  @spec held([Document.t()], Plug.Conn.t()) :: [Document.t()]
  def held(docs, %Plug.Conn{} = conn) when is_list(docs) do
    case dataset(conn) do
      nil -> docs
      dataset -> Enum.filter(docs, &(&1.dataset == dataset))
    end
  end

  @doc """
  `%{doc.id => {dependency_count, dependent_count}}` for a page of cards:
  `Params.batch_edge_counts/1` for a caller naming no dataset, and the same
  two grouped counts over the held dataset's far ends otherwise.
  """
  @spec edge_counts([Document.t()], Plug.Conn.t()) :: map()
  def edge_counts([], _conn), do: %{}

  def edge_counts(docs, %Plug.Conn{} = conn) do
    case dataset(conn) do
      nil -> Params.batch_edge_counts(docs)
      dataset -> held_edge_counts(docs, dataset)
    end
  end

  defp held_edge_counts(docs, dataset) do
    ids = Enum.map(docs, & &1.id)

    out =
      from(e in Edge,
        join: far in Document,
        on: far.id == e.to_id,
        where: e.from_id in ^ids and far.dataset == ^dataset,
        group_by: e.from_id,
        select: {e.from_id, count(e.id)}
      )
      |> Repo.all()
      |> Map.new()

    inbound =
      from(e in Edge,
        join: far in Document,
        on: far.id == e.from_id,
        where: e.to_id in ^ids and far.dataset == ^dataset,
        group_by: e.to_id,
        select: {e.to_id, count(e.id)}
      )
      |> Repo.all()
      |> Map.new()

    Map.new(docs, fn d -> {d.id, {Map.get(out, d.id, 0), Map.get(inbound, d.id, 0)}} end)
  end

  defp dataset(%Plug.Conn{params: %{"dataset" => d}}) when is_binary(d) and d != "", do: d
  defp dataset(%Plug.Conn{}), do: nil
end
