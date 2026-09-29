defmodule BarkparkCloud.Repo.Migrations.AddBoxUnreachableEpisodeStateToDeployRateAlertStates do
  @moduledoc """
  dr-w32-bl-box-unreachable-needs-an-episode-alarm — the edge state for the
  BOX_UNREACHABLE EPISODE alarm, carried on the row that already exists.

  `deploy_rate_alert_states` is already "one team's standing verdict on a deploy
  signal, kept so a notice can be edge-guarded", one row per team, unique on
  `team_id`, and it already carries a SECOND signal (the publish-waiting half)
  for exactly this reason. This is the third, on the same hourly tick, and a
  parallel table would be a parallel unique index, a parallel upsert and a
  parallel opportunity for two rows to disagree about which episode a team is in.

  Columns:

    * `unreachable_verdict` — `"episode"` / `"clear"` / `"unmeasured"`, the LAST
      reading. `unmeasured` never collapses into `clear`: a team whose site list
      could not be read has not been given a clean bill (charter D3), and
      clearing on one would send a RECOVERY message for an episode that may
      still be standing.
    * `unreachable_alerted_at` — THE LATCH, and the whole edge guard. Set when
      the notice goes out, cleared when the verdict leaves `episode`. It is what
      makes a 1h51m episode (the largest measured) exactly one email instead of
      two hourly ones.
    * `unreachable_peak_rows` / `unreachable_peak_sites` — the WORST shape seen
      during the episode, so the recovery message can name numbers it actually
      measured rather than recomputing them against a window the episode has
      already left. Same reason `waiting_longest_seconds` exists beside it.

  There is deliberately NO consecutive counter. The rate alert has one because a
  rolling percentage is noisy at its edge; this reading is a COUNT of rows over
  a pinned hour with a threshold (3 rows / 2 sites) derived to sit outside both
  the measured quiet baseline and the median episode, so the threshold debounces
  it already. A counter that can only ever be armed would be a field nothing
  reads.

  All four are NULLABLE with no backfill: a team that has never been read has no
  standing verdict, which is a different fact from `clear` and is stored as one.
  """
  use Ecto.Migration

  def change do
    alter table(:deploy_rate_alert_states) do
      add :unreachable_verdict, :string
      add :unreachable_alerted_at, :utc_datetime_usec
      add :unreachable_observed_at, :utc_datetime_usec
      add :unreachable_peak_rows, :integer
      add :unreachable_peak_sites, :integer
    end
  end
end
