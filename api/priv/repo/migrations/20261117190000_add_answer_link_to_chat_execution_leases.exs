defmodule Barkpark.Repo.Migrations.AddAnswerLinkToChatExecutionLeases do
  @moduledoc """
  task-746c02d760f26ce7: an approval answer's lease records which ask it
  answers. `approval_id` is the answered approval, and `asked_lease_id` is the
  run that asked it, as `ChatHosts.AskingLease` named it at dispatch. Until
  now that link lived only on the in-memory queued command, which is dropped
  when the lease completes. So when the host refused the answer, the server
  could not tell which of two same-id asks (Codex numbers asks per process)
  the refusal was about.

  Additive only. Two nullable columns with no default, so Postgres adds them
  without rewriting the table. Every existing row and every non-answer lease
  reads NULL. No backfill, and no existing row is touched. No foreign key: a
  refusal that names a lease since deleted simply finds no ask.
  """
  use Ecto.Migration

  def change do
    alter table(:chat_execution_leases) do
      add :approval_id, :string
      add :asked_lease_id, :binary_id
    end
  end
end
