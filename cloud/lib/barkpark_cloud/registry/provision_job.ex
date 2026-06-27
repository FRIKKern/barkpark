defmodule BarkparkCloud.Registry.ProvisionJob do
  @moduledoc """
  One unit of work in the provisioning queue that bridges the Elixir control
  plane and the Go warm-pool provisioner. Belongs to exactly one Barkpark.

  The lifecycle is a flat four-state machine — no retries, no backoff, no GC
  (YAGNI):

      pending ──claim──▶ claimed ──succeed──▶ succeeded
                              └────fail──────▶ failed

    * `pending`   — enqueued by go-live, waiting for a worker.
    * `claimed`   — a worker CAS-ed the oldest pending to itself, stamping
      `claim_token` + `claimed_at`. The job is now that worker's to run.
    * `succeeded` — the worker provisioned a live host; `result_ip` carries its
      IP, and the owning Barkpark has been flipped to `up` at that host.
    * `failed`    — the worker hit an error; `error` carries the reason and the
      Barkpark stays in its provisioning state (health_status: "unknown").

  The status transitions are driven by `BarkparkCloud.Registry`
  (`enqueue_provision_job` / `claim_next_job` / `succeed_job` / `fail_job`), not
  by arbitrary changeset writes — this schema only validates the shape.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending claimed succeeded failed)

  schema "provision_jobs" do
    field :status, :string, default: "pending"
    field :claim_token, :string
    field :claimed_at, :utc_datetime_usec
    field :result_ip, :string
    field :error, :string

    belongs_to :barkpark, BarkparkCloud.Registry.Barkpark

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def statuses, do: @statuses

  @doc """
  Changeset for enqueuing / updating a provision job. `barkpark_id` is required;
  `status` defaults to `pending` and is validated against the enumeration.
  """
  def changeset(job, attrs) do
    job
    |> cast(attrs, [:status, :claim_token, :claimed_at, :result_ip, :error, :barkpark_id])
    |> validate_required([:status, :barkpark_id])
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:barkpark)
  end
end
