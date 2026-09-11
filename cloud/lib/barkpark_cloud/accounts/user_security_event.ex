defmodule BarkparkCloud.Accounts.UserSecurityEvent do
  @moduledoc """
  One append-only entry in a USER's own security trail: a sensitive change made
  to their identity or their sessions, with the device that made it.

  ## Why this is not `AuditEvent`

  `audit_events` is TEAM-scoped — `team_id` is `null: false` and every reader of
  that table (GET /v1/audit, the console's team trail, the per-resource history
  index) keys on a team. The auth self-service routes are USER-scoped and mostly
  pre-team: `Accounts.primary_team/1` returns nil for a membership-less user, so
  the team-keyed model cannot host them at all (the router's
  `audit_account_security/2` has a LOGGED SKIP arm for exactly that user). The
  alternative considered and rejected was relaxing `audit_events.team_id` to
  nullable, which would have made every team-keyed reader silently partial. Two
  total trails beat one partial one.

  ## The closed vocabulary

  `@actions` is a hand-list here, NOT derived from `cloud/priv/audit-actions.json`:
  that table is the TEAM register's vocabulary and it feeds the console's
  ACTION_LABELS emit. These five verbs are a different register with a different
  audience (the account owner, not a team admin), and folding them into the team
  table's allowlist would put them in the team trail's label pipeline and in the
  audit vocabulary census's producer count.

  The five are the security-sensitive subset the task names, one per producing
  route:

    * `password_changed`            — PUT    /v1/account/password
    * `two_factor_disabled`         — DELETE /v1/account/two-factor
    * `session_revoked`             — DELETE /v1/account/sessions/:id
    * `sessions_revoked_everywhere` — DELETE /v1/account/sessions
    * `email_changed`               — POST   /v1/account/email/confirm

  ## Secrets

  `metadata` is a free jsonb map and it MUST NOT carry a password, a token, a
  TOTP code, a recovery code, or an email-change confirmation code. What the
  shipped producers put there is a count (`revoked`), a revoked session's row id,
  and the previous email address — facts the user already holds. `ip` and
  `user_agent` are the same device metadata `UserToken` records, and
  `user_agent` is TRUNCATED (`@user_agent_max`) so a hostile header cannot
  balloon a row.

  Append-only: `inserted_at` only, no `updated_at`, plus a BEFORE UPDATE/DELETE
  trigger in the migration. There is no update or delete route, and no context
  function that writes one.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @actions ~w(
    password_changed
    two_factor_disabled
    session_revoked
    sessions_revoked_everywhere
    email_changed
  )

  # A User-Agent header is attacker-controlled and unbounded. 512 is well past
  # every real browser UA (the longest in the wild sit near 200) and short enough
  # that a row stays a row.
  @user_agent_max 512

  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "user_security_events" do
    field :action, :string
    field :ip, :string
    field :user_agent, :string
    field :metadata, :map, default: %{}

    belongs_to :user, BarkparkCloud.Accounts.User

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "The closed `action` vocabulary — the only verbs `changeset/2` accepts."
  def actions, do: @actions

  @doc "The stored `user_agent` ceiling, in characters."
  def user_agent_max, do: @user_agent_max

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:action, :ip, :user_agent, :metadata, :user_id])
    |> validate_required([:action, :user_id])
    |> validate_inclusion(:action, @actions)
    |> update_change(:user_agent, &truncate/1)
    |> assoc_constraint(:user)
  end

  defp truncate(nil), do: nil
  defp truncate(ua) when is_binary(ua), do: String.slice(ua, 0, @user_agent_max)
  defp truncate(other), do: other
end
