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
  # azh-w6 (S14c) — `resurrect` is the portable-archive restore kind: recreate a
  # torn-down instance from an object-storage bundle. It rides the SAME step
  # machine as `provision` (charter D40 — no new step kind; the create→live chain
  # is provider-neutral) and the SAME claim/stale-recovery machinery, but is
  # claimed by a kind-filtered query so no provision worker grabs it. Its one
  # extra payload is `bundle_ref` — the archive to restore from (required when
  # kind == "resurrect", NULL for every other kind).
  #
  # PDF-D83 (Personal Dev Fleet MVP-0) — `provision_support` INVERTS support
  # provisioning into a CP job: a fleet SUPPORT box is created server-side by the
  # Go provisioner instead of from a local Hetzner token, so the browser journey
  # (create-main → add-support → offload) never needs a laptop credential. It
  # rides the SAME step machine as `provision` (@steps unchanged — a support job
  # emits create/secure/configure/content/verify/ready; `secure` joined the
  # support vocabulary when supports gained a full public identity — the url is
  # reserved at registration and the worker stands up DNS + Caddy/TLS exactly
  # like a main, so Open Studio works; only `freshen` stays main-only) and the
  # SAME claim/stale-recovery machinery, but is claimed by a kind-filtered query
  # (`POST /v1/internal/support-jobs/claim`) so no provision worker grabs it.
  #
  # PDF-D94 (`pdf-bl-console-key-custody`) — `push_agent_key` delivers a pasted
  # agent provider key (browser → CP → box env) to an ALREADY-LIVE support box:
  # rewrite one line of /etc/barkpark/fleet-listener.env over SSH + restart the
  # listener. The job row NEVER carries the key — the key rides the in-memory
  # `AgentKeyStash`, popped exactly once by the kind-filtered claim
  # (`POST /v1/internal/agent-key-jobs/claim`). No step vocabulary (it is one
  # SSH exec, not a create→live chain); succeed/fail flip the JOB ROW ONLY
  # (`succeed_agent_key_job/3` — a key push must never clobber the live row's
  # health/host the way a provision succeed does).
  #
  # isu-w5 (task-509f5fd02bc48f9c) — `enable_apply` retro-arms the self-update
  # executor on an ALREADY-LIVE managed box: append BARKPARK_SELF_UPDATE_APPLY=1
  # to the app env over SSH + restart. New boxes provision with the flag; this
  # is the retrofit rail for the pre-flag cohort, auto-enqueued when a box on
  # autoupdate is MEASURED unarmed (the admin's autoupdate opt-in is the
  # consent). One SSH plan, no step vocabulary; claimed by a kind-filtered query
  # (`POST /v1/internal/enable-apply-jobs/claim`); succeed/fail flip the JOB ROW
  # ONLY (`succeed_enable_apply_job/3` — same live-row protection as agent-key).
  @kinds ~w(provision deprovision attach_domain resurrect provision_support push_agent_key enable_apply)

  # dwb-14: the honest step vocabulary the Go worker reports as it walks the
  # create→live chain. Coarse-by-design (6 phases, not every SSH sub-step) so the
  # /new progress screen renders SERVER-confirmed transitions instead of a pure
  # client-side timer:
  #   * create    — the box is created + its fqdn identity stamped
  #   * freshen    — dwb-17: bring the box's baked snapshot up to origin/main before
  #     migrate (a working box on the CURRENT release). A FALLBACK, not a plan:
  #     warm boxes are freshened before entering the pool, so the worker narrates
  #     this step ONLY when it intervenes — "Updating Barkpark v0.42 → v0.45…" on a
  #     stale box, or a degrade caption when freshness couldn't be verified. A
  #     current box emits nothing (and the SPA hides the unreported step). A
  #     freshen that can't rebuild degrades to the baked release (rendered `done`
  #     with an honest caption, never a red `failed` — the box works, just behind).
  #   * secure    — DNS record + Caddy/TLS on the box
  #   * configure — migrate + admin-token install
  #   * content   — template bootstrap (skipped when the job carries no template)
  #   * verify    — golden-path probes (C2/D45): API answers, the auth stack
  #     cleanly rejects bad creds, Studio renders through the scoped redirect —
  #     a red probe fails the provision so a login-dead box is never declared up
  #   * ready     — health gate green, box live
  # A step-status is started | progress | done | failed. `at` is stamped
  # server-side. dwb-19: `progress` is the LIVE sub-caption channel — it does NOT
  # append a new entry; it UPDATES the in-flight `started` entry's `detail` in
  # place (see Registry.append_provision_step), so `steps` stays one entry per
  # real transition while the active step narrates what is happening right now.
  @steps ~w(create freshen secure configure content verify ready)
  @step_statuses ~w(started progress done failed)

  schema "provision_jobs" do
    field :status, :string, default: "pending"
    # Discriminates the go-live (provision) queue from the Remove (deprovision)
    # queue and the custom-domain (attach_domain) queue — the kinds share this
    # table + the claim/stale-recovery machinery but are claimed by separate,
    # kind-filtered queries so no worker loop grabs another's jobs.
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
    # azh-w6 (S14c): the object-storage archive this job restores from. Set ONLY
    # on `resurrect` jobs (required there, validated below); NULL for provision /
    # deprovision / attach_domain. Threaded into the worker's resurrect claim
    # payload (router `resurrect_claim_json`) so the Go worker knows which bundle
    # to pull and rehydrate onto the fresh box.
    field :bundle_ref, :string

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
      :bundle_ref,
      :barkpark_id
    ])
    |> validate_required([:status, :kind, :barkpark_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    # azh-w6 (S14c): a resurrect job is meaningless without the archive to restore
    # from, so `bundle_ref` is required exactly when kind == "resurrect". Every
    # other kind leaves it NULL (an accidental bundle_ref on a provision row is
    # harmless — the claim payload only reads it on the resurrect path).
    |> validate_resurrect_bundle_ref()
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
      message: "already has an active job of this kind"
    )
  end

  # azh-w6 (S14c): require `bundle_ref` on (and only on) a resurrect job. The kind
  # is read off the changeset (falling back to the struct for a partial update),
  # so a resurrect insert without the archive reference fails the shape gate
  # instead of enqueuing a job the worker can't run.
  defp validate_resurrect_bundle_ref(changeset) do
    if get_field(changeset, :kind) == "resurrect" do
      validate_required(changeset, [:bundle_ref])
    else
      changeset
    end
  end
end
