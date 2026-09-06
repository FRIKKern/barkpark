defmodule BarkparkCloud.Notifications.DigestRun do
  @moduledoc """
  ONE ROW PER DIGEST RUN — the counted loss, on a sink a deploy cannot delete.

  ## The defect this closes (dr-w27)

  `dr-w18-s3` made the fleet digest unable to succeed at sending nothing
  unobserved: `deliver_fleet_digest/1` accounts every run, and the run that lost
  somebody accounts it at WARNING. The count was real. Its SINK was not.

  It was written to `Logger` and nowhere else, and the control plane is a docker
  container with the `json-file` log driver. That driver's state lives under
  `/var/lib/docker/containers/<id>/` and is deleted WITH THE CONTAINER, which
  `deploy/cp-deploy.sh`'s `compose_up_repair` recreates on any image or config
  change. Measured on 2026-08-09: the digest DID deliver at 06:00Z — four
  `notification_deliveries` rows prove it — and the accounting grep the code
  told an operator to run returned zero lines, on every container on the host,
  because a recreate at 07:31/07:33 had taken the day's logs with it.

  The read affordance the code named was worse than lossy, it was fictional:
  `journalctl -u barkpark-cloud` names a systemd unit that has never existed on
  that box (`systemctl list-units --all | grep -c barkpark-cloud` → 0). Both
  promises are corrected at their sites in `Notifications`.

  ## Why a ROW and not a better log

  Durability is the criterion, and a Postgres row is durable for a reason no log
  configuration is: it does not live in the container. The control plane's
  database is the one thing on that host a recreate is DEFINED not to touch —
  every `notification_deliveries` row from 2026-08-09 survived the recreate that
  erased the log line describing them. Pointing the container's log driver at a
  named volume (the `postfix_log` precedent from `dr-w26`) would also survive,
  but it makes the accounting durable without making it QUERYABLE, and it is a
  change to every log this container writes rather than to this record.

  The `Logger` line STAYS. It is the on-box grep, it is what a human tailing a
  deploy reads, and nothing about a row makes it worse. What changes is that it
  is no longer the only copy.

  ## What this row is NOT

  It is not a `Delivery`. `Delivery.changeset/2` requires a `recipient` and
  charter D362 forbids inventing one, so the ZERO-RECIPIENT arm — the exact loss
  this record exists to preserve — cannot be represented there at all. It is not
  an `audit_events` row either: that table's `team_id` is NOT NULL and cascades
  with the team, and a fleet digest run is not team-scoped.

  It is also not a recipient list. The measurements are counts; no address is
  stored. A cross-team operator record that named addresses would be a
  disclosure the digest's own per-team tenancy ruling exists to prevent.

  ## Reading it back

  `Notifications.list_digest_runs/2`. The operator command that replaces the
  dead `journalctl` recipe is in that function's doc.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # ONE MEMBER TODAY. Declared as a list anyway, because the second digest is a
  # word on this row and not a second table — and because an unvalidated free
  # string is how an accounting table stops being groupable.
  @events ~w(fleet_digest)

  # `:settled` matches the telemetry event name and the log line's `phase=`.
  @phases ~w(settled)

  schema "digest_runs" do
    field :event, :string
    field :phase, :string
    field :recipients, :integer
    field :sent, :integer
    field :instances, :integer
    field :covered, :integer
    field :reason, :string
    field :withheld, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc "The digest events this table accounts for."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc "The accounting phases this table records."
  @spec phases() :: [String.t()]
  def phases, do: @phases

  @doc """
  The insert changeset. There is no update changeset: an accounting record that
  is rewritten stops being one.

  `reason` and `withheld` are optional and their NULLs are meaningful — no
  reason means the run lost nobody, and an absent `withheld` means this branch
  never funnelled through the withhold vocabulary at all (the log line omits the
  key for the same reason, so absence is never rendered as a zero).
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :event,
      :phase,
      :recipients,
      :sent,
      :instances,
      :covered,
      :reason,
      :withheld
    ])
    |> validate_required([:event, :phase, :recipients, :sent, :instances, :covered])
    |> validate_inclusion(:event, @events)
    |> validate_inclusion(:phase, @phases)
    |> validate_number(:recipients, greater_than_or_equal_to: 0)
    |> validate_number(:sent, greater_than_or_equal_to: 0)
    |> validate_number(:instances, greater_than_or_equal_to: 0)
    |> validate_number(:covered, greater_than_or_equal_to: 0)
  end

  @doc """
  TRUE when this run lost somebody — nobody was mailed, or somebody was not.

  The same predicate `log_fleet_digest/2` uses to pick WARNING over INFO, named
  once so the row and the log line can never disagree about which runs are the
  losses.
  """
  @spec lost?(t()) :: boolean()
  def lost?(%__MODULE__{recipients: recipients, sent: sent}),
    do: sent < recipients or recipients == 0
end
