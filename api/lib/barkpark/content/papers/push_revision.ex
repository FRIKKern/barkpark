defmodule Barkpark.Content.Papers.PushRevision do
  @moduledoc """
  The revision a block-op batch records of a Paper as it stood before the
  batch, when its caller asks with `before_revision: action`. The BPML push
  asks with `"bpml-push"`, so each push it writes leaves one revision holding
  the content and rev the push started from.

  The row is an ordinary `revisions` row (`Broadcast.save_revision/6`): the
  Paper's `doc_id`, `type`, `dataset`, `dataset_id`, `workspace_id` and
  `project_id`, so every history read finds it by the Paper and scopes it as
  it scopes any other revision. Its `document_id` is NULL, as a delete's is.
  With it set, the database's revision binding would demand the document hold
  this content now (it holds the pushed content) and would move the document's
  `current_revision_id` back to the state before the push.

  It is written in the batch's transaction after the rev-fenced update, so a
  batch the fence or the caller's `before_commit` check refuses leaves none. A
  batch that writes nothing leaves none either. Like the batch's other history
  rows it is best-effort: a failed insert is logged and the write stands.
  """

  alias Barkpark.Content.{Broadcast, CallerContext, Document}

  @spec record(Document.t(), String.t(), keyword()) :: :ok
  def record(%Document{} = before, dataset, opts) do
    case Keyword.get(opts, :before_revision) do
      action when is_binary(action) and action != "" ->
        Broadcast.save_revision(
          %Document{before | id: nil},
          "paper",
          dataset,
          action,
          Keyword.get(opts, :actor_user_id),
          CallerContext.actor_stamp_from_opts(opts)
        )

        :ok

      _ ->
        :ok
    end
  end
end
