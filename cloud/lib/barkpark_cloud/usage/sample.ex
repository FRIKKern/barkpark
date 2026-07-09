defmodule BarkparkCloud.Usage.Sample do
  @moduledoc """
  A cached usage snapshot for one instance (cloud-console wave 3). The fleet
  usage-sampler worker writes ONE row per checkable instance every ~15 minutes,
  storing the FULL `Usage.compose/1` envelope verbatim (jsonb) beside the wall
  clock time it was measured. `GET /v1/usage/summary` then answers the fleet
  meter strip from the LATEST row per instance — a pure DB read with ZERO
  instance HTTP on the request path, so the ~15s live fan-out never blocks the
  Overview.

  A row is written on EVERY tick, even for an unreachable box: the envelope's
  instance-sourced meters degrade to `"unmetered"` (never a fake zero) while the
  control-plane meters (seats) still carry truth, and `measured_at` is always a
  real timestamp — so the console can honestly say "as of Xs ago" for any box.

  Retention: `AgentRetentionWorker` prunes rows older than 14 days (the same
  window the metrics table keeps). The `barkpark_id + measured_at` index backs
  both the latest-per-instance read and the age-based prune. The FK cascades
  `on_delete: :delete_all`, so removing an instance drops its samples in the
  same statement.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "usage_samples" do
    # The full `Usage.compose/1` output — `%{meters: %{…}}` — stored verbatim so
    # the summary read needs no re-shaping. NEVER contains an admin token (the
    # gather keeps it in the request header only).
    field :envelope, :map
    field :measured_at, :utc_datetime_usec

    belongs_to :barkpark, BarkparkCloud.Registry.Barkpark

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(sample, attrs) do
    sample
    |> cast(attrs, [:barkpark_id, :envelope, :measured_at])
    |> validate_required([:barkpark_id, :envelope, :measured_at])
    |> foreign_key_constraint(:barkpark_id)
  end
end
