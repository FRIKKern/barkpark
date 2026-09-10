defmodule BarkparkCloud.Notifications.DeployRateAlertState do
  @moduledoc """
  dr-bl-rate-notice — one team's standing verdict on the deploy failure RATE,
  carried across ticks so the notice can be edge-guarded.

  ## Why this is a table and not a derivation

  `DeployLedger.census/3` reads a ROLLING window. Comparing this tick's window
  against the previous tick's window therefore cannot express "the fleet WENT
  red": on a fleet that has been red all day both windows are red, and on the
  first hour of an incident the prior window is usually below `min_sample` and
  refuses — so a data-derived edge fires on every tick of a long incident and
  again on every tick of a quiet one. That is a per-deployment producer with a
  percentage printed on it, which is the thing charter D14 forbids.

  So the edge is STATE, exactly as `Registry`'s heartbeat keeps
  `unreachable_count` rather than re-deriving "has it been down three times" from
  the beat table, and exactly as the webhook auto-disable keeps a consecutive
  failure counter.

  ## The three fields that do the work

    * `verdict` — `"red"` / `"clear"` / `"unmeasured"`, the LAST reading.
      `unmeasured` is its own word and never collapses into `clear`: a sample
      below `DeployLedger.min_sample/0` means nobody knows, and a fleet that
      goes quiet must not read as a fleet that got better (charter D3).
    * `consecutive_red` — how many CONSECUTIVE ticks have read red. Reset to
      zero by ANY non-red reading, `unmeasured` included: a run of red
      interrupted by an hour nobody could measure is not a run.
    * `alerted_at` — the LATCH. Set when the notice goes out, cleared when the
      verdict leaves red. It is what makes a four-hour incident one email
      instead of four.

  `last_pct` / `last_sample` are the reading the verdict was taken from, stored
  so the row can never say "red" without the numbers that made it red — the same
  rule the rate node itself enforces one level down.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @verdicts ~w(red clear unmeasured)

  # The waiting alert's own vocabulary. `unmeasured` is shared with the rate
  # alert and means the same thing in both — nobody could read it — but `red`
  # and `waiting` are NOT synonyms and must not be interchangeable: a red rate
  # is an outcome, a wait is an unfinished one.
  @waiting_verdicts ~w(waiting clear unmeasured)

  # The BOX_UNREACHABLE episode alarm's own vocabulary. `unmeasured` is shared
  # with both siblings and means the same thing in all three — nobody could read
  # it. `episode` is deliberately NOT spelled `red`: a red RATE is a settled
  # outcome about deploys that ran, while an episode of the box being
  # unreachable is a DELIVERY failure about deploys that never started, and the
  # two must not become interchangeable words on one row.
  @unreachable_verdicts ~w(episode clear unmeasured)

  schema "deploy_rate_alert_states" do
    field :verdict, :string
    field :consecutive_red, :integer, default: 0
    field :alerted_at, :utc_datetime_usec
    field :observed_at, :utc_datetime_usec
    field :last_pct, :float
    field :last_sample, :integer

    # dr-w11-s5-waiting-alert — THE SECOND SIGNAL ON THE SAME ROW. The publish
    # WAITING notice is edge-guarded the same way and against the same team, so
    # it shares this row rather than opening a parallel table that could hold a
    # second, disagreeing answer to "which episode is this team in".
    #
    # It needs no consecutive counter: the rate alert has one because a rolling
    # percentage is noisy at the edge, while a wait past a fixed one-hour
    # threshold is debounced by the threshold itself. `waiting_alerted_at` alone
    # IS the edge guard — set when the notice goes out, cleared the moment the
    # verdict leaves `waiting`.
    field :waiting_verdict, :string
    field :waiting_alerted_at, :utc_datetime_usec
    field :waiting_observed_at, :utc_datetime_usec
    field :waiting_longest_seconds, :float

    # dr-w32-bl-box-unreachable-needs-an-episode-alarm — THE THIRD SIGNAL ON THE
    # SAME ROW, edge-guarded the same way, against the same team, on the same
    # hourly tick.
    #
    # It needs no consecutive counter either, and for its own reason: the
    # reading is a COUNT over a pinned hour against a threshold (3 rows across
    # 2 sites) derived to sit outside both the measured quiet baseline and the
    # median episode, so the threshold is the debounce.
    #
    # The two peak columns exist because the RECOVERY message fires when the
    # window no longer contains the episode: the numbers it quotes cannot be
    # recomputed at that moment and must have been kept.
    field :unreachable_verdict, :string
    field :unreachable_alerted_at, :utc_datetime_usec
    field :unreachable_observed_at, :utc_datetime_usec
    field :unreachable_peak_rows, :integer
    field :unreachable_peak_sites, :integer

    belongs_to :team, BarkparkCloud.Accounts.Team

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The verdict words this row accepts."
  def verdicts, do: @verdicts

  @doc "The verdict words the publish-waiting half of this row accepts."
  def waiting_verdicts, do: @waiting_verdicts

  @doc "The verdict words the BOX_UNREACHABLE episode half of this row accepts."
  def unreachable_verdicts, do: @unreachable_verdicts

  def changeset(state, attrs) do
    state
    |> cast(attrs, [
      :team_id,
      :verdict,
      :consecutive_red,
      :alerted_at,
      :observed_at,
      :last_pct,
      :last_sample,
      :waiting_verdict,
      :waiting_alerted_at,
      :waiting_observed_at,
      :waiting_longest_seconds,
      :unreachable_verdict,
      :unreachable_alerted_at,
      :unreachable_observed_at,
      :unreachable_peak_rows,
      :unreachable_peak_sites
    ])
    |> validate_required([:team_id, :verdict])
    |> validate_inclusion(:verdict, @verdicts)
    |> validate_inclusion(:waiting_verdict, @waiting_verdicts)
    |> validate_inclusion(:unreachable_verdict, @unreachable_verdicts)
    |> validate_number(:consecutive_red, greater_than_or_equal_to: 0)
    |> assoc_constraint(:team)
    |> unique_constraint(:team_id)
  end
end
