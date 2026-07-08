defmodule Barkpark.Access.Grant do
  @moduledoc """
  An **access grant** — a time-boxed, account-bound, scoped capability an
  existing principal (`grantor`) mints for a `grantee` (identified by email
  until claimed). This is the airdrop-grants substrate: a shareable link whose
  raw token is handed to the grantee out-of-band, exchanged once for a bound
  grant, then carried as a scoped authorization at read time.

  ## Fields

    * `grantor_id` — the minting principal (account-binding for audit/revoke).
    * `grantee_email` — who the link is FOR; the grant is claimed by a user
      whose account matches, at which point `grantee_user_id` + `claimed_at`
      are stamped.
    * `workspace_id` … `doc_id` — the SCOPE LADDER, from broad to narrow:
      `workspace → project → dataset → type → doc_id`. `workspace_id` is
      required (the tenant top); every level below is nullable, and a NULL at a
      level means "everything below is covered" (a workspace-only grant covers
      all projects/datasets/types/docs in that workspace).
    * `capabilities` — the actions the grant confers; v1 allows ONLY
      `read`/`write`/`admin` (fail-closed on anything else — `publish` is
      deferred because authz has no publish action).
    * `link_token_hash` — SHA-256 hex of the raw token. The raw token is NEVER
      stored; it is returned exactly once at mint.
    * `single_use` / `claimed_at` — a single-use grant is spent by its first
      claim; `expires_at` / `revoked_at` bound its life.

  ## Active is DERIVED, never a column

  A grant is ACTIVE iff:

      revoked_at IS NULL
        AND (expires_at IS NULL OR expires_at > now())
        AND (NOT single_use OR claimed_at IS NULL)

  This predicate lives IN the query (see `Barkpark.Access`), so there is no
  denormalised `active` boolean to drift out of sync.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # v1 capability vocabulary — the ONLY strings a grant may confer. Kept
  # identical to `Barkpark.Tenancy.Auth`'s action set. `publish` is deliberately
  # absent: authz has no publish action, so allowing it would mint a dead
  # capability. Fail-closed — anything outside this set is rejected.
  @capabilities ~w(read write admin)

  schema "access_grants" do
    field :grantor_id, :binary_id
    field :grantee_email, :string
    field :grantee_user_id, :binary_id

    # Scope ladder — broad (workspace) to narrow (doc_id). Only workspace_id is
    # required; a NULL below means "all of that level".
    field :project_id, :binary_id
    field :dataset, :string
    field :type, :string
    field :doc_id, :string

    field :capabilities, {:array, :string}
    field :link_token_hash, :string
    field :single_use, :boolean, default: false
    field :expires_at, :utc_datetime_usec
    field :claimed_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :workspace, Barkpark.Tenancy.Workspace

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The v1 capability vocabulary a grant may confer."
  @spec capabilities() :: [String.t()]
  def capabilities, do: @capabilities

  @doc """
  Changeset for minting a grant. Requires a workspace scope top, a grantee
  email, at least one capability, and a token hash. Every capability must be in
  the v1 vocabulary (`read`/`write`/`admin`) — an unknown capability fails the
  changeset (fail-closed).
  """
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [
      :grantor_id,
      :grantee_email,
      :grantee_user_id,
      :workspace_id,
      :project_id,
      :dataset,
      :type,
      :doc_id,
      :capabilities,
      :link_token_hash,
      :single_use,
      :expires_at,
      :claimed_at,
      :revoked_at
    ])
    |> validate_required([
      :grantor_id,
      :grantee_email,
      :workspace_id,
      :capabilities,
      :link_token_hash
    ])
    |> validate_length(:capabilities, min: 1)
    |> validate_capabilities()
    |> assoc_constraint(:workspace)
    |> unique_constraint(:link_token_hash)
  end

  # Reject any capability outside the v1 vocabulary. This is the fail-closed
  # gate: a grant can never confer a capability the authz layer doesn't
  # understand (which would be silently un-enforceable).
  defp validate_capabilities(changeset) do
    validate_change(changeset, :capabilities, fn :capabilities, caps ->
      case Enum.reject(caps, &(&1 in @capabilities)) do
        [] -> []
        bad -> [capabilities: "contains unsupported capabilities: #{Enum.join(bad, ", ")}"]
      end
    end)
  end
end
