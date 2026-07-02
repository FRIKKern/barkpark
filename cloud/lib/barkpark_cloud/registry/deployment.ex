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

  schema "deployments" do
    field :status, :string, default: "queued"
    field :git_ref, :string
    field :artifact_url, :string
    field :image_tag, :string
    field :build_log_url, :string
    field :failure_reason, :string

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

  @doc """
  Changeset for creating a Deployment. `site_id` is required; `status` defaults
  to `queued`. The fencing fields are not castable from public callers.
  """
  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [:status, :git_ref, :artifact_url, :site_id])
    |> validate_required([:site_id])
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:site)
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
