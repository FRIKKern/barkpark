defmodule BarkparkCloud.Registry.ContentPublish do
  @moduledoc """
  deploy-reliability W11 (charter D162) — one row per HMAC-VERIFIED content-publish
  delivery: the instant the control plane learned a human published.

  ## Why this table exists

  Every time-to-web number this fleet has ever published starts at a
  `deployments.inserted_at`, which is when the control plane ENQUEUED an attempt.
  That clock is late by construction (`AutoDeployWorker` debounces 60s, D44) and,
  worse, it is ABSENT for a publish that coalesces onto an in-flight build —
  `Sites.Deploy.enqueue/6` recovers the conflict and mints no row at all. Measured
  over a pinned window, 26-35% of paper publishes get no deployment row within 90s.
  A publish with no row is invisible in both the numerator and the denominator of
  every instrument this epic has built: it cannot be slow, because it does not exist.

  This is the row that always exists. It is written on the receiver's verified
  arm, before anything else happens, so the population it records is *every
  delivery the control plane accepted* — including the ones that never become a
  deployment.

  ## Append-only, and non-blocking by construction

  A row is inserted once and never rewritten (`received_at` never moves; the only
  later write is the receiver stamping `enqueued` onto its OWN row inside the same
  request). There is no updated_at.

  `record/3` and `mark_enqueued/2` NEVER raise into their caller — the caller is a
  webhook that must answer 202 whether or not this bookkeeping succeeded. A
  telemetry row that can fail a delivery is worse than no telemetry row: the box
  would retry a publish that was in fact accepted. Both functions return tagged
  tuples for every outcome, including a database that is unreachable or a table
  that does not exist yet (the migration is applied by the lead, not by a deploy).
  """
  use Ecto.Schema
  import Ecto.Changeset

  require Logger

  alias BarkparkCloud.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Append-only stream: stamp inserted_at, never updated_at.
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @default_source "content-webhook"

  schema "content_publishes" do
    # The clock this epic has never started: when the receiver verified the HMAC.
    field :received_at, :utc_datetime_usec

    # Echoed from the delivery payload when it carries a `type`; nil otherwise.
    # NEVER invented — an unknown doc type must read as unknown, not as a guess.
    field :doc_type, :string

    field :source, :string, default: @default_source

    # False = this publish coalesced onto a rebuild someone else's publish owns.
    field :enqueued, :boolean, default: false

    belongs_to :site, BarkparkCloud.Registry.Site

    timestamps()
  end

  @type t :: %__MODULE__{}

  def default_source, do: @default_source

  @doc false
  def changeset(publish, attrs) do
    publish
    |> cast(attrs, [:site_id, :received_at, :doc_type, :source, :enqueued])
    |> validate_required([:site_id, :received_at])
    |> validate_length(:doc_type, max: 255)
    |> assoc_constraint(:site)
  end

  @doc """
  Append the publish instant for `site_id`.

  `received_at` is the caller's clock — the instant the delivery was accepted,
  NOT the instant this row was written and emphatically not the instant a
  deployment was enqueued.

  `attrs` may carry `:doc_type` (echoed from the payload; nil when the payload
  carries none) and `:source` (defaults to `"content-webhook"`).

  Returns `{:ok, row}` or `{:error, reason}`. It NEVER raises: a caller may be a
  webhook whose 202 must not depend on this write, so every failure mode —
  invalid attrs, an unknown site, a missing table, an unreachable database —
  comes back as a value. The rescue below is load-bearing; removing it lets a
  Postgrex error out of here and into an HTTP response.
  """
  @spec record(binary(), DateTime.t(), map()) :: {:ok, t()} | {:error, term()}
  def record(site_id, %DateTime{} = received_at, attrs \\ %{}) when is_binary(site_id) do
    attrs =
      attrs
      |> Map.new()
      |> Map.merge(%{site_id: site_id, received_at: received_at})

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc """
  Stamp whether the publish actually enqueued a rebuild, from `AutoDeployWorker.enqueue/1`'s
  own return: `{:ok, %Oban.Job{conflict?: false}}` is a fresh job, a conflict is a
  coalesce onto a rebuild another publish already owns, and anything else is a
  failed insert (also "no rebuild of mine").

  Tolerant of `nil` (the record never landed) and never raises, for the same
  reason `record/3` does not. Returns `:ok` on every path the caller can act on;
  `{:error, reason}` is informational only.
  """
  @spec mark_enqueued(t() | nil, term()) :: :ok | {:error, term()}
  def mark_enqueued(nil, _enqueue_result), do: :ok

  def mark_enqueued(%__MODULE__{} = publish, enqueue_result) do
    case Repo.update(change(publish, enqueued: enqueued?(enqueue_result))) do
      {:ok, _row} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc """
  Did this `Oban.insert/1` result actually schedule a NEW job?

  A unique-conflict insert comes back `{:ok, job}` with `conflict?: true` — the
  same success shape as a fresh insert, which is exactly how a coalesced publish
  becomes invisible. Pattern-matched structurally (no Oban compile-time dep).
  """
  @spec enqueued?(term()) :: boolean()
  def enqueued?({:ok, %{conflict?: true}}), do: false
  def enqueued?({:ok, %{conflict?: _}}), do: true
  def enqueued?(_other), do: false
end
