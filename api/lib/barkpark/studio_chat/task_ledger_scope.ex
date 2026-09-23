defmodule Barkpark.StudioChat.TaskLedgerScope do
  @moduledoc """
  The ONE answer to "which scope does the task writer use?" for the Studio chat
  surfaces (task-ff3ed7ae0a242160).

  Two chat surfaces ride the task ledger's document stream: `ChatLive`'s Doing
  strip (`subscribe_hand_tasks/1`) and the per-session `Recorder` (the live task
  transitions it re-broadcasts to `bp chat`). Both must subscribe to the stream
  the ledger is WRITTEN on, or no claim, pulse or release frame ever reaches
  them. Before this module the strip subscribed to `socket.assigns.dataset` —
  the FIRST entry of the sorted `Content.list_datasets/0` — so on any install
  holding a dataset that sorts before `"production"` (`"archive"`, `"blog"`, a
  leaked test dataset) the strip joined a stream no task write lands on.

  ## Where the writer's scope comes from

    * **dataset** — a `type:task` row lives in the dataset it was CREATED in,
      and every lifecycle write (claim, pulse, stage, close, release) mutates
      that row in place, so its frames broadcast on `documents:<that dataset>`.
      Rows are created by `bp task create`, which posts to
      `/v1/data/mutate/<ctx.Dataset>`; `ctx.Dataset` is `BARKPARK_DATASET` or
      the baked default `"production"` (internal/manifest/context.go), and the
      chat runtime sets no `BARKPARK_DATASET`. The server's own dataset
      defaults on the task routes agree (`TasksController.request_dataset/1`,
      `Tasks.task_schema/1`), as do the other ledger subscribers — the Tasks
      board LiveView's `@dataset "production"`. The ledger's home is therefore
      `"production"`, by definition, not by sort order.
    * **workspace / project** — the VIEWER's, passed in (task-180a07e9d178d6a8).
      The agent's task token is minted into the chat session's own workspace
      (`Provider.Claude.mint_workspace_id/2`, arm 1), and `ensure_session/1`
      stamps that from the socket's `:current_workspace`. The flat `/v1/tasks`
      routes run `DeriveWorkspaceFromToken` BEFORE `AssignDefaultScope`, so a
      token bound to workspace A writes every claim, pulse and create into A,
      not into the seeded Default. This used to be `resolve/0`, reading
      `Tenancy.get_default_workspace/0` for every caller: on the scoped mount
      (`{LiveAuth, :scoped_admin}`, a TARGET-workspace gate) an admin of A
      alone was shown the Default workspace's ready queue and claims, and never
      the claims its own agent took in A. A resolver that cannot see the viewer
      cannot scope to the viewer, so the workspace is an argument.

      The project follows `AssignDefaultScope`'s rule, because that is the
      project the writer's request resolves: the seeded Default project only
      when the workspace IS the Default workspace, and no project otherwise (a
      workspace-only filter). Pairing a non-Default workspace with the Default
      project would AND two tenants and match nothing.
  """

  alias Barkpark.Tenancy

  @task_dataset "production"

  @type t :: %{
          workspace_id: String.t() | nil,
          project_id: String.t() | nil,
          dataset: String.t()
        }

  @doc """
  The workspace, project and dataset the task ledger is written in, for a
  viewer acting in `workspace_id`.

  Callers pass the workspace the viewer is acting in: `ChatLive` its
  `:current_workspace` (the URL workspace on the scoped mount, the principal's
  own or the authorized Default on the flat one), the `Recorder` its session's
  `owner_workspace_id`. A `nil` workspace yields `nil` ids, never the Default:
  the callers' reads are fail-closed on a nil workspace, and the subscription
  then joins only the global shared-layer topic. Never raises.
  """
  @spec resolve(String.t() | nil) :: t()
  def resolve(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    %{workspace_id: workspace_id, project_id: project_for(workspace_id), dataset: @task_dataset}
  end

  def resolve(_workspace_id), do: %{workspace_id: nil, project_id: nil, dataset: @task_dataset}

  # `AssignDefaultScope.maybe_assign_default_project/1`'s rule: the Default
  # project belongs to the Default workspace and is paired with nothing else.
  defp project_for(workspace_id) do
    case Tenancy.get_default_project() do
      %{id: id, workspace_id: ^workspace_id} when is_binary(id) -> id
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
