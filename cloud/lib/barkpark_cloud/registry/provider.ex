defmodule BarkparkCloud.Registry.Provider do
  @moduledoc """
  A connected cloud account a Team links so the control plane can provision
  Barkparks into it. Belongs to one Team. Three kinds ship today:

    * `hetzner`    — the account's Hetzner Cloud API token (a bare string).
    * `azure`      — a service principal, stored as a JSON blob of
      `{tenant_id, client_id, client_secret, subscription_id}`.
    * `cloudflare` — a free-superpower account, stored as EITHER a bare API
      token OR a JSON blob `{api_token, account_id?, zone_id?}`.

  ## One credential home — `encrypted_token`

  `encrypted_token` is the SINGLE credential column for BOTH kinds (there is no
  second store, no per-kind column). It NEVER holds plaintext — it holds the
  Base64 of `BarkparkCloud.Registry.Vault.encrypt/1` (AES-256-GCM), and the
  field is `redact: true` so it stays out of logs / inspect. For `hetzner` the
  encrypted plaintext is the token string; for `azure` it is the JSON blob.
  Decryption happens on demand in the context, never as a stored column.

  ## Per-kind credential-shape validation

  The changeset validates the credential SHAPE through a virtual `:credential`
  field (the plaintext the context is about to encrypt) — so a malformed
  credential is rejected before it is ever stored, while the stored column stays
  purely ciphertext. `hetzner` demands a non-blank token string; `azure` demands
  a JSON object carrying all four service-principal fields.

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
  # backend actually lands (YAGNI).
  @kinds ~w(hetzner azure cloudflare)

  # The four fields an azure service-principal credential blob must carry. The
  # control plane exchanges these for a token and lists a tagged resource before
  # it ever persists the row (verified-connect, see Registry + Web.Router).
  @azure_fields ~w(tenant_id client_id client_secret subscription_id)

  schema "providers" do
    field :kind, :string
    field :label, :string
    # Ciphertext (Base64 of Vault.encrypt/1 output) — never the plaintext token.
    field :encrypted_token, :string, redact: true
    # The plaintext credential, VALIDATED then encrypted by the context. Never
    # persisted (virtual) and never logged (redact) — the shape gate only.
    field :credential, :string, virtual: true, redact: true

    belongs_to :team, BarkparkCloud.Accounts.Team

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def kinds, do: @kinds

  @doc "The fields an azure service-principal credential blob must carry."
  def azure_fields, do: @azure_fields

  @doc """
  Changeset for a connected provider. `kind`, `team_id`, and `encrypted_token`
  are required; `encrypted_token` is expected to ALREADY be ciphertext — the
  context encrypts the plaintext before building the changeset. When the
  plaintext is passed as `:credential`, its per-kind SHAPE is validated (a
  non-blank token for hetzner; the four-field JSON blob for azure).
  """
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [:kind, :label, :encrypted_token, :team_id])
    # The credential is cast with empty_values: [] so a blank/whitespace-only
    # value REACHES the per-kind shape gate (default cast trims + drops it as
    # "missing", which would silently skip the gate on an empty token).
    |> cast(attrs, [:credential], empty_values: [])
    |> validate_required([:kind, :team_id, :encrypted_token])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:label, max: 255)
    |> validate_credential_shape()
    |> assoc_constraint(:team)
  end

  # Per-kind credential-shape gate. Only runs when a plaintext `:credential` was
  # supplied (the context always supplies it; a changeset built without one — a
  # relabel, say — skips the gate). Fails on the virtual field so the error
  # attaches to the credential the caller sent, never the ciphertext column.
  defp validate_credential_shape(changeset) do
    case get_field(changeset, :credential) do
      nil -> changeset
      credential -> validate_credential_shape(changeset, get_field(changeset, :kind), credential)
    end
  end

  defp validate_credential_shape(changeset, "hetzner", credential) do
    if is_binary(credential) and String.trim(credential) != "" do
      changeset
    else
      add_error(changeset, :credential, "can't be blank — a Hetzner API token is required")
    end
  end

  defp validate_credential_shape(changeset, "azure", credential) do
    with true <- is_binary(credential),
         {:ok, blob} when is_map(blob) <- Jason.decode(credential),
         [] <- Enum.reject(@azure_fields, &present_field?(blob, &1)) do
      changeset
    else
      _ ->
        add_error(
          changeset,
          :credential,
          "must be Azure JSON carrying #{Enum.join(@azure_fields, ", ")}"
        )
    end
  end

  # Cloudflare accepts EITHER a bare API-token string OR a JSON blob
  # `{api_token, account_id?, zone_id?}` (a pasted token is the common case; the
  # blob carries the optional account/zone scope). Both ride the same
  # `encrypted_token` column. The only hard requirement is a non-blank token: if
  # the credential is a JSON object it MUST carry a non-blank `api_token`;
  # otherwise a non-blank string is enough.
  defp validate_credential_shape(changeset, "cloudflare", credential) do
    cond do
      not is_binary(credential) or String.trim(credential) == "" ->
        add_error(changeset, :credential, "can't be blank — a Cloudflare API token is required")

      cloudflare_blob_missing_token?(credential) ->
        add_error(changeset, :credential, "must carry api_token when supplied as JSON")

      true ->
        changeset
    end
  end

  # Unknown kind: validate_inclusion already flags it; don't double-error the
  # credential.
  defp validate_credential_shape(changeset, _kind, _credential), do: changeset

  # True only when the credential parses as a JSON object that lacks a non-blank
  # `api_token`. A bare token (not valid JSON, or non-object JSON) is not a blob
  # and passes — the non-blank check above already guards it.
  defp cloudflare_blob_missing_token?(credential) do
    case Jason.decode(credential) do
      {:ok, blob} when is_map(blob) -> not present_field?(blob, "api_token")
      _ -> false
    end
  end

  defp present_field?(blob, field) do
    case Map.get(blob, field) do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end
end
