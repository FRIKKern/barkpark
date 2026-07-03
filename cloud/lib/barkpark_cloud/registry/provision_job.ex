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

  # dwb-14: the honest step vocabulary the Go worker reports as it walks the
  # create→live chain. Coarse-by-design (6 phases, not every SSH sub-step) so the
  # /new progress screen renders SERVER-confirmed transitions instead of a pure
  # client-side timer:
  #   * create    — the box is created + its fqdn identity stamped
  #   * secure    — DNS record + Caddy/TLS on the box
  #   * configure — migrate + admin-token install
  #   * content   — template bootstrap (skipped when the job carries no template)
  #   * verify    — golden-path probes: API answers, login responds without a 5xx,
  #     Studio renders through the scoped redirect (the #957 class becomes a failed
  #     probe, never a lying green)
  #   * ready      — health gate green, box live
  # A step-status is started | progress | done | failed. `at` is stamped
  # server-side. dwb-19: `progress` is the LIVE sub-caption channel — it does NOT
  # append a new entry; it UPDATES the in-flight `started` entry's `detail` in
  # place (see Registry.append_provision_step), so `steps` stays one entry per
  # real transition while the active step narrates what is happening right now.
  @steps ~w(create secure configure content verify ready)
  @step_statuses ~w(started progress done failed)

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
    # dwb-14: append-only narration of the create→live chain the worker reports.
    # Each element is %{"step", "status", "detail", "at"}. Surfaced on the
    # barkpark row json (:provision_steps) so /new renders honest, refresh-durable
    # progress. Best-effort telemetry — a missing/late step never blocks the job.
    field :steps, {:array, :map}, default: []
    # dwb-16: append-only LIVE console — the worker's create→live + bootstrap
    # narration lines (already redacted worker-side). Each element is
    # %{"line", "at"}. Capped server-side (oldest dropped) so a runaway worker
    # can't grow the row unbounded. Surfaced on the barkpark row json
    # (:provision_console) so /new renders a live console. Best-effort telemetry.
    field :console, {:array, :map}, default: []

    belongs_to :barkpark, BarkparkCloud.Registry.Barkpark

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def statuses, do: @statuses
  def kinds, do: @kinds
  def step_names, do: @steps
  def step_statuses, do: @step_statuses

  @doc """
  Validate a worker-reported step transition (dwb-14). Returns `{:ok, {step,
  status}}` for a known step + status (started | progress | done | failed),
  `:error` otherwise — the router 422s an unknown pair rather than persisting
  garbage into the narration array.
  """
  @spec validate_step(term(), term()) :: {:ok, {String.t(), String.t()}} | :error
  def validate_step(step, status)
      when is_binary(step) and is_binary(status) do
    if step in @steps and status in @step_statuses, do: {:ok, {step, status}}, else: :error
  end

  def validate_step(_, _), do: :error

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
      :steps,
      :console,
      :barkpark_id
    ])
    |> validate_required([:status, :kind, :barkpark_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> assoc_constraint(:barkpark)
    # dwb-11 money-path backstop: at most ONE ACTIVE (pending|claimed) job of each
    # kind per barkpark. Backed by the partial unique index
    # `provision_jobs_one_active_per_barkpark_kind_idx` (WHERE status IN
    # ('pending','claimed')). This makes a double-click Retry (or two concurrent
    # Removes) atomically safe: the loser's insert raises the unique violation the
    # context translates to `:already_provisioning` / `:already_deprovisioning`
    # instead of standing up (and billing) a second box. Terminal
    # succeeded/failed rows are outside the index, so a legitimate retry after a
    # failure still enqueues.
    |> unique_constraint([:barkpark_id, :kind],
      name: :provision_jobs_one_active_per_barkpark_kind_idx,
      message: "an active job of this kind already exists for this barkpark"
    )
  end
end
