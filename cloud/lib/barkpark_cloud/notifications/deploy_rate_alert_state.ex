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

  schema "deploy_rate_alert_states" do
    field :verdict, :string
    field :consecutive_red, :integer, default: 0
    field :alerted_at, :utc_datetime_usec
    field :observed_at, :utc_datetime_usec
    field :last_pct, :float
    field :last_sample, :integer

    belongs_to :team, BarkparkCloud.Accounts.Team

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The verdict words this row accepts."
  def verdicts, do: @verdicts

  def changeset(state, attrs) do
    state
    |> cast(attrs, [
      :team_id,
      :verdict,
      :consecutive_red,
      :alerted_at,
      :observed_at,
      :last_pct,
      :last_sample
    ])
    |> validate_required([:team_id, :verdict])
    |> validate_inclusion(:verdict, @verdicts)
    |> validate_number(:consecutive_red, greater_than_or_equal_to: 0)
    |> assoc_constraint(:team)
    |> unique_constraint(:team_id)
  end
end
