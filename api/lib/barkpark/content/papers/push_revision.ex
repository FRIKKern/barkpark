defmodule Barkpark.Content.Papers.PushRevision do
  @moduledoc """
  The two revisions a block-op batch records of a Paper when its caller asks
  with `push_revisions: true`, as the BPML push does: one of the Paper as it
  stood before the batch (action `"bpml-push"`), one as the batch left it
  (action `"bpml-push-after"`). Each push that writes leaves both, so the
  content and rev it started from and the content and rev it wrote are both
  stored.

  Each row is an ordinary `revisions` row (`Broadcast.save_revision/6`): the
  Paper's `doc_id`, `type`, `dataset`, `dataset_id`, `workspace_id` and
  `project_id`, so every history read finds it by the Paper and scopes it as
  it scopes any other revision. Its `document_id` is NULL, as a delete's is,
  so the database's revision binding leaves the document's
  `current_revision_id` where it was, as on a push before these rows.

  Both are written in the batch's transaction right after the rev-fenced
  update. The push route always opens one (it passes `before_commit`), so the
  before row, the write and the after row land together or not at all: a
  batch the fence or the `before_commit` check refuses leaves neither, and a
  row that fails to insert rolls the write back with it. A batch that writes
  nothing leaves neither. Outside a transaction the write has already landed,
  so a failed row is logged, as for other history rows.

  `actions/0` is the one list of these bookkeeping actions. Every reader that
  leaves push rows out reads it: `Revisions.get_revision_by_rev/3` returns
  neither row, so the "unchanged since ifRev" checks in `BlockOps` and
  `Mutations` answer as they would without them, and a write anchored on the
  rev a push started from or wrote is refused as stale once the Paper moved.
  """

  require Logger

  alias Barkpark.Content.{Broadcast, CallerContext, Document}
  alias Barkpark.Repo

  @before_push "bpml-push"
  @after_push "bpml-push-after"

  @doc "The action of the row holding the Paper before a BPML push."
  @spec before_action() :: String.t()
  def before_action, do: @before_push

  @doc "The action of the row holding the Paper as a BPML push left it."
  @spec after_action() :: String.t()
  def after_action, do: @after_push

  @doc "Every action a BPML push records under: the one list readers leave out."
  @spec actions() :: [String.t()]
  def actions, do: [@before_push, @after_push]

  @doc """
  Records `before` and `saved` when `opts` holds `push_revisions: true`.
  Inside a transaction, a row that fails to insert rolls the transaction back
  with `{:push_revision_failed, action}`.
  """
  @spec record(Document.t(), Document.t(), String.t(), keyword()) :: :ok
  def record(%Document{} = before, %Document{} = saved, dataset, opts) do
    if Keyword.get(opts, :push_revisions) == true do
      with :ok <- save(before, @before_push, dataset, opts),
           do: save(saved, @after_push, dataset, opts)
    else
      :ok
    end
  end

  defp save(doc, action, dataset, opts) do
    case Broadcast.save_revision(
           %Document{doc | id: nil},
           "paper",
           dataset,
           action,
           Keyword.get(opts, :actor_user_id),
           CallerContext.actor_stamp_from_opts(opts)
         ) do
      {:ok, _row} -> :ok
      {:error, _changeset} -> failed(action)
    end
  end

  defp failed(action) do
    if Repo.in_transaction?() do
      Repo.rollback({:push_revision_failed, action})
    else
      Logger.error("push revision #{action} not recorded; the write stands")
      :ok
    end
  end
end
