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
  """

  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.TasksController.Params

  @spec of(Plug.Conn.t()) :: keyword()
  def of(%Plug.Conn{params: params} = conn) do
    dataset =
      case params do
        %{"dataset" => d} when is_binary(d) and d != "" -> d
        _ -> nil
      end

    Params.put_opt(ScopeHelpers.scope_opts(conn), :dataset, dataset)
  end
end
