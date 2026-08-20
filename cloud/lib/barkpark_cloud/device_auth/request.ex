defmodule BarkparkCloud.DeviceAuth.Request do
  @moduledoc """
  The ledger row behind a device-authorization handshake (bp-login-ux).

  RFC-8628-shaped: the CLI holds a `device_code` (polls with it) and the human
  types a short `user_code` (`XXXX-XXXX`) into the browser to approve. Only the
  SHA-256 hex hash of each is stored (`BarkparkCloud.Accounts.UserToken.hash_token/1`),
  never the plaintext. `status` drives the lifecycle (`pending` → `approved`;
  a successful poll DELETEs the row); `expires_at` is a hard TTL enforced by
  every query in `BarkparkCloud.DeviceAuth`. The two hash unique indexes are the
  integrity guard against a CSPRNG collision and back the verify-by-hash lookup.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "device_auth_requests" do
    field :device_code_hash, :string
    field :user_code_hash, :string
    field :client_name, :string
    field :ip_address, :string
    field :user_agent, :string
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime_usec

    belongs_to :user, BarkparkCloud.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Changeset for minting a pending device-authorization request row."
  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :device_code_hash,
      :user_code_hash,
      :client_name,
      :ip_address,
      :user_agent,
      :status,
      :user_id,
      :expires_at
    ])
    |> validate_required([:device_code_hash, :user_code_hash, :status, :expires_at])
    |> validate_inclusion(:status, ["pending", "approved"])
    |> unique_constraint(:device_code_hash)
    |> unique_constraint(:user_code_hash)
    # FK-abort containment (Felix W18, cloud sibling of the api-side family).
    # `user_id` is a real Postgres FK (migration 20260709140000, default name
    # `device_auth_requests_user_id_fkey`). Without this, a changeset-path insert
    # (or `Repo.insert`) carrying a phantom user_id would RAISE Ecto.ConstraintError
    # instead of returning {:error, changeset}. NOTE: the hot approve path,
    # `BarkparkCloud.DeviceAuth.approve/2`, stamps user_id via `Repo.update_all`,
    # which BYPASSES changesets by construction — this translator does not (and
    # cannot) cover that path; it is left unchanged, and approve/2 only ever
    # writes a user_id it just resolved from a live session.
    |> assoc_constraint(:user)
  end
end
