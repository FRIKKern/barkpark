defmodule BarkparkCloud.GitHub.Installation do
  @moduledoc """
  A team's connected GitHub App installation (gh-2). Records that a team linked
  its GitHub account by installing the Barkpark App, so the control plane can act
  on the team's repos (create a repo from a template, push files, register a
  push webhook). ONE installation per team for v1 (unique on `team_id`).

  ## The installation id is encrypted at rest

  `installation_id_encrypted` NEVER holds the plaintext installation handle — the
  context (`GitHub.record_installation/2`) runs it through
  `BarkparkCloud.Registry.Vault.encrypt/1` (AES-256-GCM) before the changeset,
  and the field is `redact: true` so it stays out of logs / inspect. The handle
  is the capability GitHub scopes installation tokens to, so it is treated like
  the provider token in `Registry.Provider` — the same encrypt-at-rest seam.
  `account_login` is a non-secret DISPLAY value (kept plaintext so the dashboard
  can show "Connected as <login>" without a decrypt).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "github_installations" do
    # Ciphertext (Base64 of Vault.encrypt/1 output) — never the plaintext id.
    field :installation_id_encrypted, :string, redact: true
    # Non-secret display login of the installed account (org/user).
    field :account_login, :string

    belongs_to :team, BarkparkCloud.Accounts.Team

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc """
  Changeset for a connected installation. `team_id` and `installation_id_encrypted`
  are required; the ciphertext is expected to ALREADY be encrypted (the context
  encrypts the plaintext before building the changeset). The `team_id` unique
  constraint enforces one installation per team (v1).
  """
  def changeset(installation, attrs) do
    installation
    |> cast(attrs, [:installation_id_encrypted, :account_login, :team_id])
    |> validate_required([:installation_id_encrypted, :team_id])
    |> validate_length(:account_login, max: 255)
    |> assoc_constraint(:team)
    |> unique_constraint(:team_id, name: :github_installations_team_id_index)
  end
end
