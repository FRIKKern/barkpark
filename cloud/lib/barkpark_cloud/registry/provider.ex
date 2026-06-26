defmodule BarkparkCloud.Registry.Provider do
  @moduledoc """
  A connected cloud account a Team links so the control plane can provision
  Barkparks into it (e.g. a Hetzner project's API token). Belongs to one Team.

  ## The token is encrypted at rest

  `encrypted_token` NEVER holds the plaintext API token. The context
  (`Registry.connect_provider/3`) runs the plaintext through
  `BarkparkCloud.Registry.Vault.encrypt/1` (AES-256-GCM) before it reaches the
  changeset, and the field is `redact: true` so it stays out of logs / inspect.
  Decryption happens on demand in the context, never as a stored column.

  Real key management (rotation, KMS, per-tenant keys) is a later/human concern;
  see `BarkparkCloud.Registry.Vault` for the seam. What ships now is the
  encrypt-at-rest guarantee plus redaction.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # The provider kinds we know how to provision into. Kept as a list (not a free
  # string) so a typo can't silently create a dead provider row; grow it when a
  # second backend actually lands (YAGNI).
  @kinds ~w(hetzner)

  schema "providers" do
    field :kind, :string
    field :label, :string
    # Ciphertext (Base64 of Vault.encrypt/1 output) — never the plaintext token.
    field :encrypted_token, :string, redact: true

    belongs_to :team, BarkparkCloud.Accounts.Team

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def kinds, do: @kinds

  @doc """
  Changeset for a connected provider. `kind`, `team_id`, and `encrypted_token`
  are required; `encrypted_token` is expected to ALREADY be ciphertext — the
  context encrypts the plaintext before building the changeset.
  """
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [:kind, :label, :encrypted_token, :team_id])
    |> validate_required([:kind, :team_id, :encrypted_token])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:label, max: 255)
    |> assoc_constraint(:team)
  end
end
