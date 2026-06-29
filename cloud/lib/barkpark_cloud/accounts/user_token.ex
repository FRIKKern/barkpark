defmodule BarkparkCloud.Accounts.UserToken do
  @moduledoc """
  A USER bearer credential — DUAL-PURPOSE, discriminated by `context`:

    * `context = "session"` — the login bearer a logged-in User presents on the
      control-plane HTTP API (cloud-12a) after `POST /v1/auth/login`. The
      web-layer twin of `Registry.AgentToken`: same hash-at-rest discipline,
      different principal (a human User instead of an on-box agent).
    * `context = "pat"` — a **Personal Access Token**: a named, scoped,
      revocable credential a user mints for programmatic API use (adapted from
      Coolify's `app/Models/PersonalAccessToken.php`). Carries an `abilities`
      array (`read`/`write`/`deploy`/`root`), an optional bounded `expires_at`,
      a `last_used_at` stamp, a `revoked_at` tombstone, and the `team_id` it was
      minted under.

  One table, one verify-by-hash path; the `context` column is the discriminator
  and every query is scoped by it so the session lifecycle never touches PAT
  rows and vice-versa.

  Both kinds share the hash-at-rest invariant:

    * Only a `token_hash` (SHA-256, lowercase hex) is stored — NEVER the
      plaintext. The plaintext is returned exactly once at mint time
      (`Accounts.create_user_session_token/2` for sessions /
      `Accounts.create_personal_access_token/3` for PATs) and is unrecoverable
      after.
    * `revoked_at` / `expires_at` gate validity; verify rejects a revoked or
      expired token. `revoked_at` is the kill switch / tombstone — stamped by
      `revoke_user_session_token/1` (single-device logout), `revoke_user_session/2`
      (one row by id), and `revoke_all_user_sessions/2` ("sign out everywhere" on
      a password change), and reused for PAT revocation and member-removal, exactly
      as `Registry.revoke_agent_token/1` stamps the agent-token twin.
    * `ip_address` / `user_agent` / `last_used_at` are device metadata captured
      at mint and refreshed on each verify, backing the active-sessions list UI.

  A lookup is by hash: hash the presented plaintext, find the row, then check it
  is neither revoked nor past `expires_at`. `hash_token/1` is the single source
  of the hashing scheme so mint and verify can never drift.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # How long a freshly minted session token stays valid. Sessions are cheap to
  # re-mint (just log in again), so a bounded lifetime is the safe default; a
  # "remember me" / refresh flow is a later concern (YAGNI).
  @default_validity_days 30

  # Default PAT validity, in days. A PAT is a higher-risk long-lived credential,
  # so it ALSO carries a finite default horizon (Coolify's bounded-expiry select
  # — app/Livewire/Security/ApiTokens.php). `nil` (the "never" choice) is
  # allowed but opt-in.
  @pat_default_validity_days 30

  # The PAT ability vocabulary — small, Coolify-shaped but CMS-flavoured:
  #   read   — baseline read of control-plane resources (the default).
  #   write  — mutating calls (create/deploy/env/domains/…).
  #   deploy — go-live / launch only (the exclusive deploy-token, like Coolify's
  #            `deploy` ability).
  #   root   — superset; bypasses every ability check. Exclusive at mint time.
  @abilities ~w(read write deploy root)

  schema "user_tokens" do
    field :token_hash, :string
    field :context, :string, default: "session"
    # PAT columns (personal-access-tokens)
    field :name, :string
    field :abilities, {:array, :string}, default: ["read"]
    # validity / kill-switch (shared by sessions + PATs)
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    # session device metadata (account-sessions)
    field :ip_address, :string
    field :user_agent, :string

    belongs_to :user, BarkparkCloud.Accounts.User
    belongs_to :team, BarkparkCloud.Accounts.Team

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Default session-token validity, in days."
  def default_validity_days, do: @default_validity_days

  @doc "Default PAT validity, in days."
  def pat_default_validity_days, do: @pat_default_validity_days

  @doc "The allowed PAT abilities (`read`/`write`/`deploy`/`root`)."
  def abilities, do: @abilities

  @doc """
  Changeset for a SESSION token. Deliberately unchanged from the original — the
  session path can never grow PAT-validation surprises. `context` is castable so
  a session row is written with `"session"` explicitly.
  """
  def changeset(token, attrs) do
    token
    |> cast(attrs, [
      :token_hash,
      :context,
      :expires_at,
      :revoked_at,
      :ip_address,
      :user_agent,
      :last_used_at,
      :user_id
    ])
    |> validate_required([:token_hash, :user_id])
    |> assoc_constraint(:user)
    |> unique_constraint(:token_hash)
  end

  @doc """
  Changeset for a PAT row. Forces `context = "pat"`, requires a name + owner,
  validates the abilities against the bounded vocabulary, and ENFORCES the
  exclusivity rules server-side (never trust the client) via
  `normalize_abilities/1`.
  """
  def pat_changeset(token, attrs) do
    token
    |> cast(attrs, [
      :token_hash,
      :name,
      :abilities,
      :expires_at,
      :revoked_at,
      :user_id,
      :team_id
    ])
    |> put_change(:context, "pat")
    |> validate_required([:token_hash, :name, :user_id])
    |> validate_length(:name, min: 3, max: 255)
    |> validate_subset(:abilities, @abilities)
    |> normalize_abilities()
    |> validate_length(:abilities, min: 1)
    |> assoc_constraint(:user)
    |> assoc_constraint(:team)
    |> unique_constraint(:token_hash)
  end

  # Enforce the exclusivity rules server-side, mirroring Coolify's
  # ApiTokens.updatedPermissions (app/Livewire/Security/ApiTokens.php):
  #   * `root` collapses to just ["root"] (a superset — every other ability is
  #     redundant);
  #   * `deploy` is the exclusive deploy-token, so it collapses to ["deploy"];
  #   * otherwise dedupe.
  # The client UI mirrors this for ergonomics, but THIS is the authority.
  defp normalize_abilities(changeset) do
    case get_change(changeset, :abilities) || get_field(changeset, :abilities) do
      abilities when is_list(abilities) ->
        cond do
          "root" in abilities -> put_change(changeset, :abilities, ["root"])
          "deploy" in abilities -> put_change(changeset, :abilities, ["deploy"])
          true -> put_change(changeset, :abilities, Enum.uniq(abilities))
        end

      _ ->
        changeset
    end
  end

  @doc "Hash a raw token string for storage / lookup (SHA-256, lowercase hex)."
  @spec hash_token(binary()) :: String.t()
  def hash_token(raw_token) when is_binary(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
  end
end
