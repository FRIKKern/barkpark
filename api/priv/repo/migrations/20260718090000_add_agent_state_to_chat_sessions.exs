defmodule Barkpark.Repo.Migrations.AddAgentStateToChatSessions do
  @moduledoc """
  Herd layer wave 1 (chat-tui charter D40): persist the Recorder's wave-5
  activity derivation as cold truth on the session row.

  `agent_state` is the four-state semantic axis every fleet surface reads —
  `working | blocked | idle | unknown` (`needs_you` maps to `blocked`; there is
  deliberately NO `done` and NO read/seen tracking). NOT NULL default `'idle'`,
  NO backfill: a pre-herd row is honestly "idle" until its next flip.

  `agent_state_at` is the liveness stamp for the D42h staleness sweep: written
  on every flip and at most every 60s while working/blocked. Nullable — a
  pre-herd row has no heartbeat, and the sweeper treats a NULL-stamped
  working/blocked row as stale.
  """
  use Ecto.Migration

  def change do
    alter table(:chat_sessions) do
      add :agent_state, :string, null: false, default: "idle"
      add :agent_state_at, :utc_datetime_usec
    end

    create constraint(:chat_sessions, :chat_sessions_agent_state_check,
             check: "agent_state IN ('working','blocked','idle','unknown')"
           )
  end
end
