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
    * **workspace / project** — the flat `/v1/tasks` routes run
      `DeriveWorkspaceFromToken` then `AssignDefaultScope`; the chat surfaces
      read the seeded Default here. That is the arity-zero read
      task-180a07e9d178d6a8 questions, and it is left EXACTLY as it was: a
      disposition of that row is a change inside `resolve/0` (plus its callers
      passing the viewer), and nowhere else.
  """

  alias Barkpark.Tenancy

  @task_dataset "production"

  @type t :: %{
          workspace_id: String.t() | nil,
          project_id: String.t() | nil,
          dataset: String.t()
        }

  @doc """
  The workspace, project and dataset the task ledger is written in.

  Never raises: a missing Default workspace/project yields `nil` ids (the
  callers' reads are fail-closed on a nil workspace, and the subscription then
  joins only the global shared-layer topic).
  """
  @spec resolve() :: t()
  def resolve do
    %{
      workspace_id: default_id(&Tenancy.get_default_workspace/0),
      project_id: default_id(&Tenancy.get_default_project/0),
      dataset: @task_dataset
    }
  end

  defp default_id(fetch) do
    case fetch.() do
      %{id: id} when is_binary(id) -> id
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
