defmodule BarkparkCloud.Registry.EnvVar do
  @moduledoc """
  A user-managed environment variable / secret, scoped on Barkpark Cloud's
  tenancy ladder and STORED for a Team's provisioned instances. The Cloud
  adaptation of Coolify's `SharedEnvironmentVariable` — collapsed from Coolify's
  four PaaS scopes (team/project/environment/server) onto the only two tenancy
  units Cloud actually has.

  Two scopes, most-specific-wins at resolve time:

    * `team`     — applies to EVERY Barkpark the Team owns (`barkpark_id` NULL).
    * `barkpark` — a per-instance override for one Barkpark (`barkpark_id` set).

  At provision-claim time `Registry.resolved_env_for_barkpark/1` merges the
  team-scoped rows with the instance's own overrides (instance shadows team for
  the same key) and decrypts them into the claim payload.

  RETRACTED ON REVIEW (wave 56): that sentence used to end "…so the values reach
  the box's runtime env". They do not. `internal/provisioner.JobSpec` declares no
  `env` field and every claim decode is a bare `json.Unmarshal`, so the `env` key
  the control plane sends is DROPPED on the floor — nothing running or newly
  provisioned reads it. The console's own panel copy has said so since cch-w53-s1
  ("Values are not delivered to any instance yet"); this moduledoc and
  `Registry.resolved_env_for_barkpark/1`'s `@doc` were the two places in `lib`
  still claiming delivery. Storage, encryption and tenancy scoping below are all
  real; DELIVERY is the part that does not exist, and building it is filed
  separately.

  ## The value is encrypted at rest

  `value_encrypted` NEVER holds the plaintext value: the context encrypts the
  plaintext through `BarkparkCloud.Registry.Vault.encrypt/1` (AES-256-GCM)
  before the changeset, the field is `redact: true` so it stays out of logs /
  inspect, and it is NEVER serialized in the API. Decryption happens on demand
  in the context — `Registry.resolved_env_for_barkpark/1`, the ONLY decrypting
  reader (its sole lib caller is the provision-claim payload builder) — never as a
  stored column. There is no reveal path: no route returns a value, and the
  per-row reveal helper that once implied one was deleted in wave 56.
  This is the exact seam `Provider.encrypted_token` and `Site.env_encrypted`
  already ride.

  ## Flags (mirroring Coolify)

    * `is_secret` (default true) — masked everywhere; metadata-only in list views.
    * `is_shown_once` (default false) — write-once: the only way to change it is
      delete + recreate (Coolify's `is_shown_once`), and it is never revealed.

  Real key management (rotation, KMS, per-tenant keys, value versioning) is a
  later concern — see `BarkparkCloud.Registry.Vault`. What ships now is
  encrypt-at-rest + redaction + the per-scope uniqueness integrity.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @scopes ~w(team barkpark)
  # Legal POSIX env-var name: leading letter/underscore, then alnum/underscore.
  @key_format ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  schema "env_vars" do
    field :key, :string
    # Ciphertext (Base64 of Vault.encrypt/1) — never the plaintext value.
    field :value_encrypted, :string, redact: true
    field :scope, :string, default: "team"
    field :is_secret, :boolean, default: true
    field :is_shown_once, :boolean, default: false
    field :comment, :string

    belongs_to :team, BarkparkCloud.Accounts.Team
    belongs_to :barkpark, BarkparkCloud.Registry.Barkpark

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def scopes, do: @scopes

  @doc """
  Changeset for an env var. `key`, `team_id`, `scope`, and `value_encrypted`
  (expected ALREADY-ciphertext — the context encrypts the plaintext first) are
  required. The scope discriminator is kept honest against `barkpark_id`:
  `scope: "barkpark"` REQUIRES a `barkpark_id`; `scope: "team"` FORBIDS one.
  """
  def changeset(env_var, attrs) do
    env_var
    |> cast(attrs, [
      :key,
      :value_encrypted,
      :scope,
      :is_secret,
      :is_shown_once,
      :comment,
      :team_id,
      :barkpark_id
    ])
    |> validate_required([:key, :value_encrypted, :scope, :team_id])
    |> validate_inclusion(:scope, @scopes)
    |> validate_format(:key, @key_format,
      message: "must be a valid env var name (letters, digits, _, not leading digit)"
    )
    |> validate_length(:key, max: 255)
    # cch-w22-s3: 255, NOT 1000. `comment` is `add :comment, :string` — a bare
    # varchar(255) (create_env_vars migration), and no migration in the tree ever
    # widened it. A 1000 cap therefore ACCEPTED a 256-char comment
    # (`valid?: true, errors: []`) and handed it to `Repo.insert_or_update`, which
    # raised `Postgrex.Error … 22001 string_data_right_truncation`. That raise is
    # not an `{:error, changeset}` tuple, so the POST /v1/env-vars case never
    # matched it and — with no `Plug.ErrorHandler` anywhere in this app — it
    # reached the person as a bare 500 under "Check the values and try again."
    # Capping at the column turns it into the 422 the form already renders.
    # `:key` above was always correct at 255; this is the same rule.
    |> validate_length(:comment, max: 255)
    |> validate_scope_shape()
    |> assoc_constraint(:team)
    |> assoc_constraint(:barkpark)
    |> unique_constraint([:key, :team_id],
      name: :env_vars_team_key_unique_idx,
      message: "is already taken by a team-scoped var"
    )
    |> unique_constraint([:key, :barkpark_id],
      name: :env_vars_barkpark_key_unique_idx,
      message: "is already taken by a var on this instance"
    )
  end

  # The scope discriminator must agree with barkpark_id presence — belt to the
  # migration's CHECK constraint (suspenders), so a bad write fails in the
  # changeset with a friendly error rather than a raw DB 23514.
  defp validate_scope_shape(changeset) do
    scope = get_field(changeset, :scope)
    barkpark_id = get_field(changeset, :barkpark_id)

    case {scope, barkpark_id} do
      {"barkpark", nil} ->
        add_error(changeset, :barkpark_id, "is required for a barkpark-scoped var")

      {"team", id} when not is_nil(id) ->
        add_error(changeset, :barkpark_id, "must be empty for a team-scoped var")

      _ ->
        changeset
    end
  end
end
