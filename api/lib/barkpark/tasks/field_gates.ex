defmodule Barkpark.Tasks.FieldGates do
  @moduledoc """
  A task field-visibility gate for each workspace and project, for a view
  that shows tasks from more than one of them: the Tasks board, its peek and
  its list, on the operator's flat mount and inside a workspace
  (task-b3d338cd0745b310, task-2c4baa77701785b3).

  `Barkpark.Tasks.Board.field_visibility_gate/2` judges one scope by its own
  task schema, the read `/v1/tasks` uses. A board or list can hold tasks
  from several workspaces (the flat mount) or several projects of one
  workspace, each with its own task schema. So each row is judged by the
  gate of its own `{workspace_id, project_id}` (`pick/2`). What belongs to no
  single row, such as a filter, a sort header or the target lookup, is
  allowed only when every gate allows it (`all/1`): fail closed, so a value
  one scope hides cannot be found by narrowing the count.

  A gate set is one gate (a view of one scope) or a map from
  `{workspace_id, project_id}` to gate, where nil is an absent key. A row
  whose scope the map does not hold shows no gated field.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tasks.Board

  @type gate :: (String.t() -> boolean())
  @type key :: {String.t() | nil, String.t() | nil}
  @type t :: gate() | %{optional(key()) => gate()}

  @doc "The scope a task row is gated by: `{workspace_id, project_id}`."
  @spec key(map()) :: key()
  def key(row), do: {Map.get(row, :workspace_id), Map.get(row, :project_id)}

  @doc "A gate for each scope in `keys`, one schema read each."
  @spec for_keys(String.t(), [key()]) :: %{optional(key()) => gate()}
  def for_keys(dataset, keys) do
    keys
    |> Enum.uniq()
    |> Map.new(fn {ws_id, project_id} = key ->
      {key, Board.field_visibility_gate(dataset, workspace_id: ws_id, project_id: project_id)}
    end)
  end

  @doc "A gate for each scope `rows` hold."
  @spec for_rows(String.t(), [map()]) :: %{optional(key()) => gate()}
  def for_rows(dataset, rows), do: for_keys(dataset, Enum.map(rows, &key/1))

  @doc """
  A gate for each scope that holds a task in `dataset`: in one workspace, or
  in every workspace when `workspace_id` is nil.
  """
  @spec for_dataset(String.t(), String.t() | nil) :: %{optional(key()) => gate()}
  def for_dataset(dataset, workspace_id \\ nil) do
    query =
      from(d in Document,
        where: d.type == "task" and d.dataset == ^dataset,
        distinct: true,
        select: {d.workspace_id, d.project_id}
      )

    query =
      if workspace_id, do: from(d in query, where: d.workspace_id == ^workspace_id), else: query

    for_keys(dataset, Repo.all(query))
  end

  @doc "The gate for a task row (any map with `:workspace_id` and `:project_id`)."
  @spec pick(t(), map()) :: gate()
  def pick(gate, _row) when is_function(gate, 1), do: gate
  def pick(gates, row) when is_map(gates), do: Map.get(gates, key(row), &closed/1)

  @doc "A gate that lets a field through only when every gate in the set does."
  @spec all(t()) :: gate()
  def all(gate) when is_function(gate, 1), do: gate

  def all(gates) when is_map(gates) do
    gates = Map.values(gates)
    fn field -> Enum.all?(gates, & &1.(field)) end
  end

  defp closed(_field), do: false
end
