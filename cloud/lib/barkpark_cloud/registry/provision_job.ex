defmodule BarkparkCloud.Registry.ProvisionJob do
  @moduledoc """
  One unit of work in the provisioning queue that bridges the Elixir control
  plane and the Go warm-pool provisioner. Belongs to exactly one Barkpark.

  The lifecycle is a flat four-state machine with bounded stale-claim recovery
  (no backoff, no GC — YAGNI):

      pending ──claim──▶ claimed ──succeed──▶ succeeded
                          │  ▲  └────fail──────▶ failed
                          │  └──re-claim (stale, attempts < max)
                          └─────fail (stale, attempts ≥ max)──▶ failed

    * `pending`   — enqueued by go-live, waiting for a worker.
    * `claimed`   — a worker CAS-ed the oldest pending to itself, stamping
      `claim_token` + `claimed_at` and bumping `attempts`. The job is now that
      worker's to run. A claim that sits too long (the worker crashed, or its
      succeed/fail report failed in transit) is RE-CLAIMABLE: the next claim
      re-picks it past the staleness threshold so a fresh attempt runs.
    * `succeeded` — the worker provisioned a live host; `result_ip` carries its
      IP, and the owning Barkpark has been flipped to `up` at that host.
    * `failed`    — the worker hit an error (`error` carries the reason), OR the
      job exhausted its attempt budget while wedged in `claimed`. The Barkpark
      stays in its provisioning state (health_status: "unknown").

  `attempts` bounds the re-claim loop so a permanently-failing job stops looping
  instead of being re-handed-out forever.

  The status transitions are driven by `BarkparkCloud.Registry`
  (`enqueue_provision_job` / `claim_next_job` / `succeed_job` / `fail_job`), not
  by arbitrary changeset writes — this schema only validates the shape.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending claimed succeeded failed)
  @kinds ~w(provision deprovision)

  schema "provision_jobs" do
    field :status, :string, default: "pending"
    # Discriminates the go-live (provision) queue from the Remove (deprovision)
    # queue — the two share this table + the claim/stale-recovery machinery but
    # are claimed by separate, kind-filtered queries so neither worker loop grabs
    # the other's jobs.
    field :kind, :string, default: "provision"
    field :claim_token, :string
    field :claimed_at, :utc_datetime_usec
    field :result_ip, :string
    field :error, :string
    # How many times this row has been (re)claimed. Bumped on every claim — the
    # first claim is 1 — so the stale-claim reaper can fail a job that has burned
    # through its attempt budget instead of handing it out forever.
    field :attempts, :integer, default: 0

    belongs_to :barkpark, BarkparkCloud.Registry.Barkpark

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def statuses, do: @statuses
  def kinds, do: @kinds

  @doc """
  Changeset for enqueuing / updating a provision job. `barkpark_id` is required;
  `status` defaults to `pending` and is validated against the enumeration.
  """
  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :status,
      :kind,
      :claim_token,
      :claimed_at,
      :result_ip,
      :error,
      :attempts,
      :barkpark_id
    ])
    |> validate_required([:status, :kind, :barkpark_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> assoc_constraint(:barkpark)
  end
end
