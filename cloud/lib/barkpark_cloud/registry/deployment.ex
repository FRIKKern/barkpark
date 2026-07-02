defmodule BarkparkCloud.Registry.Deployment do
  @moduledoc """
  One build-and-release of a `Site`. The Deployment row IS the build job — the
  off-box builder (P2) atomically claims rows where `status = "queued"` and
  walks them through:

      queued → building → pushing → live      (happy path)
      queued → building → failed              (with failure_reason)

  Claim fencing mirrors the bp task substrate: `claim_worker` + `claimed_at` +
  `claim_epoch` are stamped on claim; the epoch bumps on every claim, and close
  is a CAS on the observed epoch (a stale-but-alive worker writing after its
  lease was swept fails the CAS).

  `image_tag` is the artifact identity once built. `build_log_url` is opaque to
  the control plane — the builder writes the log somewhere accessible (e.g. blob
  storage) and stores the URL.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(queued building pushing live failed cancelled)

  # gh-6: which slot this deployment targets. "production" (the default — every
  # pre-gh-6 row + every push to the connected branch) drives the Site's live
  # pointer; "preview" is a branch preview that answers on its own host/container
  # and NEVER touches `sites.current_deployment_id` / `sites.port`.
  @environments ~w(production preview)

  # The legal from → to status graph the moduledoc promises. `live`, `failed`,
  # and `cancelled` are terminal (no outgoing edges). A same-status write is
  # always legal (see `legal_transition?/2`) so field-only updates — image_tag,
  # build_log_url, failure_reason — keep passing. This is the from-status guard
  # that `validate_inclusion(:status, …)` alone can't express; the fenced writers
  # in `BarkparkCloud.Registry` consult it before `Repo.update`.
  #
  # queued → failed is a legitimate edge: a queued row can fail *validation*
  # before any build claim — the reaper terminates a no-build-source row (no
  # artifact AND no connected repo) it can prove will never build.
  @transitions %{
    "queued" => ["building", "failed", "cancelled"],
    "building" => ["pushing", "failed", "cancelled"],
    "pushing" => ["live", "failed", "cancelled"],
    "live" => [],
    "failed" => [],
    "cancelled" => []
  }

  schema "deployments" do
    field :status, :string, default: "queued"
    field :git_ref, :string
    field :artifact_url, :string

    # dwb-18: GitHub's X-GitHub-Delivery header — unique per redelivery-chain.
    # Cast on CREATE only (never on a transition) and backed by a partial unique
    # index so a redelivered push mints at most one Deployment even under a race.
    field :delivery_id, :string
    field :image_tag, :string
    field :build_log_url, :string
    field :failure_reason, :string

    # gh-6: branch-preview identity. `environment` is "production" (default) or
    # "preview". For a preview: `branch` is the git branch it was cut from,
    # `preview_slug` is the sanitized+hashed DNS label, and `preview_host` is the
    # full `<preview_slug>.<base_domain>` it answers on (what the runtime keys its
    # Caddy block on and what `/v1/tls/ask` allowlists). Null on production rows.
    field :environment, :string, default: "production"
    field :branch, :string
    field :preview_slug, :string
    field :preview_host, :string

    field :claim_worker, :string
    field :claimed_at, :utc_datetime_usec
    field :claim_epoch, :integer, default: 0

    # gh-5: append-only LIVE build console — the builder's claim → fetch source →
    # build → artifact → activate narration lines (already redacted worker-side).
    # Each element is %{"line", "at"}. Capped server-side (oldest dropped) so a
    # runaway build can't grow the row unbounded. Surfaced on the deployment JSON
    # (:console) so the site-detail deploy row renders a live console. Best-effort
    # telemetry — a missing/late line never blocks the build.
    field :console, {:array, :map}, default: []

    field :became_live_at, :utc_datetime_usec

    belongs_to :site, BarkparkCloud.Registry.Site

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def statuses, do: @statuses

  @doc "The valid deployment environments."
  def environments, do: @environments

  @doc "The legal from → to status transition graph."
  def transitions, do: @transitions

  @doc """
  Whether a Deployment may move from `from` to `to`. A same-status write is
  always legal (field-only updates), otherwise `to` must be an outgoing edge of
  `from` in `@transitions`.
  """
  def legal_transition?(from, to), do: to == from or to in Map.get(@transitions, from, [])

  @doc """
  Changeset for creating a Deployment. `site_id` is required; `status` is not
  castable — creation always takes the schema default `queued`. The
  transition_changeset is the only status mutator. Fencing fields are not
  castable from public callers either.
  """
  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [:git_ref, :artifact_url, :site_id, :delivery_id])
    |> validate_required([:site_id])
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:site)
    # dwb-18: the DB idempotency backstop. A lost race (concurrent redelivery, or
    # a second active build of the same commit) surfaces as a changeset error the
    # router turns into a 200 duplicate — never a raised Ecto.ConstraintError.
    |> unique_constraint(:delivery_id, name: :deployments_delivery_id_index)
    |> unique_constraint(:git_ref,
      name: :deployments_active_site_ref_index,
      message: "active deployment already exists"
    )
  end

  @doc """
  gh-6: changeset for creating a branch-PREVIEW deployment. Same base shape as
  `changeset/2` plus the preview identity (`environment`, `branch`,
  `preview_slug`, `preview_host`) and the dwb-18 `delivery_id` idempotency key.
  `environment` is validated against `@environments`; `branch` is required (a
  preview is always cut from a branch). The preview columns are set by the
  control plane (`create_preview_deployment/4`), never accepted from a public
  request body.
  """
  def preview_changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [
      :git_ref,
      :artifact_url,
      :site_id,
      :delivery_id,
      :environment,
      :branch,
      :preview_slug,
      :preview_host
    ])
    |> validate_required([:site_id, :branch, :preview_slug, :preview_host])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:environment, @environments)
    |> assoc_constraint(:site)
    # dwb-18 twins for the preview path: the same globally-unique delivery_id
    # index, plus at most one ACTIVE preview build per (site, branch) — the DB
    # backstop for replace-per-branch under concurrent pushes. A lost race
    # surfaces as a changeset error the router recovers into a 200 duplicate.
    |> unique_constraint(:delivery_id, name: :deployments_delivery_id_index)
    |> unique_constraint(:branch,
      name: :deployments_active_preview_branch_index,
      message: "active preview already exists for this branch"
    )
  end

  @doc """
  Narrow changeset for the builder's status transitions (image_tag, log url,
  failure reason, became_live_at) plus the gh-5 live-console append. Cannot move
  the deployment between sites.
  """
  def transition_changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [
      :status,
      :image_tag,
      :build_log_url,
      :failure_reason,
      :became_live_at,
      :console,
      :claim_worker,
      :claimed_at,
      :claim_epoch
    ])
    |> validate_inclusion(:status, @statuses)
  end
end
