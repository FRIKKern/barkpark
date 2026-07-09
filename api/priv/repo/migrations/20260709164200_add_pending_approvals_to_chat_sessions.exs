defmodule Barkpark.Repo.Migrations.AddPendingApprovalsToChatSessions do
  use Ecto.Migration

  @moduledoc """
  Studio Claude chat — persist approval state so a pending-at-exit approval no
  longer vanishes on reopen (epic studio-claude-chat, wave 2, slice
  scc-w2-approvals).

  `pending_approvals` is a DENORMALISED counter on `chat_sessions`: the sidebar
  reads it directly to raise a "needs you" pill without scanning `chat_messages`.
  It is bumped in the same paths that move an approval's lifecycle —

    * +1 when an approval row is appended (an ask is always pending at creation),
    * −1 when that approval resolves (allow / deny),
    * zeroed when the shared teardown cancels every dangling approval (a crash /
      reopen can never deliver a control-response, so a pending card is canceled).

  The approval's OWN terminal state lives in the `chat_messages.metadata` jsonb
  (`approval_status`: pending | allowed | denied | canceled) — this column is the
  fast sidebar aggregate of it. NOT-NULL default 0 so existing rows are correct.
  """

  def change do
    alter table(:chat_sessions) do
      add :pending_approvals, :integer, null: false, default: 0
    end
  end
end
