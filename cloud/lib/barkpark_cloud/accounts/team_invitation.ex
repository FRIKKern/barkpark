defmodule BarkparkCloud.Accounts.TeamInvitation do
  @moduledoc """
  A pending invitation for an email address to join a Team at a role — the
  Cloud adaptation of Coolify's `app/Models/TeamInvitation.php`.

  The acceptance secret is a random token stored ONLY as a SHA-256 hash (mirrors
  `Accounts.UserToken` / `Registry.AgentToken`): the plaintext is returned exactly
  once at mint time, ships in the accept URL, and is unrecoverable after. This
  DELIBERATELY rejects Coolify's `Crypt::encryptString("email@@@uuid@@@password")`
  magic-login link — that couples acceptance to the app key and auto-creates
  password-reset users. Here the token only attaches a membership; it is never a
  login credential.

  Single-use: `Accounts.accept_invitation/2` stamps `accepted_at` inside the same
  transaction that creates the membership, so a replayed token finds an
  already-accepted row and is rejected. One LIVE invite per (team, email) is
  enforced by a partial UNIQUE index `WHERE accepted_at IS NULL` — a fresh invite
  is allowed once a prior one has accepted.

  `accepted_at` is a soft audit trail (who-was-invited survives accept) instead of
  Coolify's hard delete, and it is what makes the token single-use without a
  separate `used` flag.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias BarkparkCloud.Accounts.{TeamMembership, UserToken}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles TeamMembership.roles()
  # Loose-but-real email shape — exactly one "@", no spaces. Mirrors User.@email_format.
  @email_format ~r/^[^\s@]+@[^\s@]+$/

  schema "team_invitations" do
    field :email, :string
    field :role, :string, default: "member"
    field :token_hash, :string
    field :expires_at, :utc_datetime_usec
    field :accepted_at, :utc_datetime_usec

    belongs_to :team, BarkparkCloud.Accounts.Team
    belongs_to :invited_by, BarkparkCloud.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The valid invitation roles — the same grant vocabulary as a membership."
  def roles, do: @roles

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [
      :email,
      :role,
      :token_hash,
      :expires_at,
      :accepted_at,
      :team_id,
      :invited_by_id
    ])
    |> validate_required([:email, :role, :token_hash, :expires_at, :team_id])
    |> validate_format(:email, @email_format, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
    # Canonicalize the email the same way User does, so a lookup by downcased
    # email matches what the invitee registered with.
    |> update_change(:email, &String.downcase/1)
    |> validate_inclusion(:role, @roles)
    |> assoc_constraint(:team)
    |> assoc_constraint(:invited_by)
    |> unique_constraint(:token_hash)
    |> unique_constraint([:team_id, :email],
      name: :team_invitations_team_email_pending_idx,
      message: "already has a pending invitation for this email"
    )
  end

  @doc """
  Hash a raw invite token for storage / lookup — the SAME scheme as `UserToken`
  (SHA-256, lowercase hex), so the invite-token discipline never drifts from the
  session-token one.
  """
  @spec hash_token(binary()) :: String.t()
  def hash_token(raw), do: UserToken.hash_token(raw)
end
