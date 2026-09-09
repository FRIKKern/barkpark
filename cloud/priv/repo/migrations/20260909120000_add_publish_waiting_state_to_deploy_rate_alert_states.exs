defmodule BarkparkCloud.Repo.Migrations.AddPublishWaitingStateToDeployRateAlertStates do
  @moduledoc """
  dr-w11-s5-waiting-alert — the edge state for the SITE PUBLISH WAITING notice,
  carried on the row that already exists rather than in a second table.

  `deploy_rate_alert_states` is already "one team's standing verdict on a deploy
  signal, kept so a notice can be edge-guarded", one row per team, unique on
  `team_id`. The waiting alert needs exactly that and nothing else, so it gets
  columns here instead of a parallel table with a parallel unique index, a
  parallel upsert and a parallel opportunity for the two to disagree about which
  episode a team is in.

  Columns, and the waiting alert needs FEWER than the rate alert does:

    * `waiting_verdict` — `"waiting"` / `"clear"` / `"unmeasured"`, the LAST
      reading. `unmeasured` never collapses into `clear`: a truncated site list
      means nobody knows, and a fleet that went unreadable must not read as a
      fleet whose content shipped.
    * `waiting_alerted_at` — THE LATCH, and the whole edge guard. Set when the
      notice goes out, cleared when the verdict leaves `waiting`. It is what
      makes three sweeps over one stalled site exactly one email.
    * `waiting_longest_seconds` — the longest wait seen during the episode, so
      the RECOVERY message can name a duration it actually measured rather than
      recomputing one against a cohort that has since emptied.

  There is deliberately NO `consecutive_waiting` counter. The rate alert needs
  one because a rolling percentage is noisy at the edge; a wait past a fixed
  one-hour threshold is already debounced by the threshold itself, and a counter
  that can only ever be armed would be a field nothing reads.

  All three are NULLABLE with no backfill: a team that has never been read has
  no standing verdict, which is a different fact from `clear` and is stored as
  one. `advance/4` writes the row on first sight.
  """
  use Ecto.Migration

  def change do
    alter table(:deploy_rate_alert_states) do
      add :waiting_verdict, :string
      add :waiting_alerted_at, :utc_datetime_usec
      add :waiting_observed_at, :utc_datetime_usec
      add :waiting_longest_seconds, :float
    end
  end
end
