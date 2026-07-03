defmodule BarkparkCloud.Accounts.AuditEvent do
  @moduledoc """
  One append-only entry in a Team's audit trail — a security/account-relevant
  action and WHO did it: a member invited or removed, a role changed, an
  invitation revoked or accepted, a subscription activated or canceled, an agent
  token minted or revoked, a site or instance created or deleted, a Barkpark
  taken live.

  Append-only: there is `inserted_at`, never `updated_at`. An audit event is a
  fact at a point in time — written once, never mutated (contrast Coolify's
  `activity_log`, whose `description` row is a live streaming SSH-process buffer
  that `updated_at`-advances on every stdout chunk). Enforced two ways: the
  schema drops `updated_at` (below), and the migration installs a BEFORE
  UPDATE/DELETE trigger so a raw SQL mutation is rejected at the DB, not just by
  Ecto. `metadata` is a free jsonb map so each `action` carries its own context
  (the email invited, old/new role, plan, IP) with no per-action migration.

  `actor_user_id` is NULLABLE: system / webhook-driven actions (e.g. a
  Stripe-fired subscription change) have no human actor, and an actor's account
  deletion must not erase the audit fact — only nilify its FK (see the
  migration's `on_delete: :nilify_all`).

  Modeled field-for-field on the append-only `Registry.AgentEvent` (binary_id
  PK, jsonb map, `updated_at: false`), but tenant-scoped to a `Team` and
  carrying an actor — improving on Coolify's JSON `properties->team_id` with a
  real `team_id` FK.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # The closed verb vocabulary. Dotted `<noun>.<verb>` so the UI can group by
  # noun and a typo is a changeset error (validate_inclusion), not a silent new
  # category. Extend here as new audited call-sites land — the routes wired today
  # are the member / invitation / token / subscription / site / barkpark seams;
  # the env_var / twofa / oauth / email verbs are reserved for the PR-#680
  # feature seams (onboarding, 2FA, SSO, shared secrets, email verification) as
  # those call-sites gain audit wiring.
  @actions ~w(
    member.invited member.role_changed member.removed
    invitation.revoked invitation.accepted
    subscription.activated subscription.canceled
    token.minted token.revoked
    site.created site.deleted
    deployment.promoted
    barkpark.go_live barkpark.deleted
    env_var.created env_var.deleted
    twofa.enabled twofa.disabled
    oauth.linked email.verified
  )

  # Append-only stream: stamp inserted_at, never updated_at (mirrors AgentEvent).
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "audit_events" do
    field :action, :string
    # Loose string target — the polymorphic subject may be a Site, a Barkpark, a
    # Subscription, a TeamMembership, or an AgentToken (mixed PK types). No FK on
    # the target: it is a reference LABEL, and the target row may be deleted (a
    # `site.deleted` event must outlive the site it records).
    field :target_type, :string
    field :target_id, :string
    field :metadata, :map, default: %{}

    belongs_to :team, BarkparkCloud.Accounts.Team
    belongs_to :actor_user, BarkparkCloud.Accounts.User

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "The closed `action` vocabulary — the only verbs `changeset/2` accepts."
  def actions, do: @actions

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:action, :target_type, :target_id, :metadata, :team_id, :actor_user_id])
    |> validate_required([:action, :team_id])
    |> validate_inclusion(:action, @actions)
    |> assoc_constraint(:team)
    |> assoc_constraint(:actor_user)
  end
end
