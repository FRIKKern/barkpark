defmodule BarkparkCloud.Accounts.ExternalIdentity do
  @moduledoc """
  Binds a Cloud `User` to an identity at an external IdP (GitHub, Google) — the
  schema behind "Continue with GitHub / Google".

  The durable link is `(provider, provider_uid) -> user_id`, **NOT** email.
  Linking on the IdP's STABLE subject id (GitHub's numeric `id`, Google's OIDC
  `sub`) — never the email — is what avoids Coolify's email-only
  account-reconstruction footgun: Coolify's `app/Http/Controllers/OauthController.php`
  resolves the account with `User::whereEmail($email)->first()`, so ANY provider
  asserting an existing user's email lands on that user's account (account
  takeover by a second IdP that lets you set an arbitrary email). Here `email` is
  stored for display/audit only — it is never the join key.

  A User MAY link several providers; the composite UNIQUE on
  `(provider, provider_uid)` guarantees one IdP identity maps to AT MOST one
  user. YAGNI, matching Coolify's "store nothing" scope minus the unsafe linking:
  no access/refresh tokens stored, no profile sync, no avatar — only the durable
  link persists.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # The two consumer providers this beta ships. A new provider is one row in this
  # list + one strategy module — no schema change. Deliberately NOT a per-team
  # admin-configured set (that is post-beta enterprise SSO).
  @providers ~w(github google)

  schema "external_identities" do
    field :provider, :string
    field :provider_uid, :string
    field :email, :string

    belongs_to :user, BarkparkCloud.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The providers this build accepts (`[\"github\", \"google\"]`)."
  def providers, do: @providers

  @doc """
  Changeset for linking an external identity to a user.

  Requires `provider`, `provider_uid`, and `user_id`; `email` is optional
  (GitHub may withhold a verified primary email — the link still stands on the
  uid). The composite unique constraint is the integrity guard: one IdP identity
  maps to one user, full stop.
  """
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:provider, :provider_uid, :email, :user_id])
    |> validate_required([:provider, :provider_uid, :user_id])
    |> validate_inclusion(:provider, @providers)
    |> assoc_constraint(:user)
    |> unique_constraint([:provider, :provider_uid],
      name: :external_identities_provider_uid_unique_idx,
      message: "is already linked to an account"
    )
  end
end
