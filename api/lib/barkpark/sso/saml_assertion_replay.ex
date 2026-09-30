defmodule Barkpark.Sso.SamlAssertionReplay do
  @moduledoc """
  The ACS's one-time-use ledger for SAML bearer assertions
  (task-223e04ce556b1950). SAML Web Browser SSO (Profiles §4.1.4.5) requires a
  bearer assertion to be used once; `:esaml_sp.validate_assertion/2` checks
  nothing of the kind (its duplicate hook is a no-op), so a captured
  `SAMLResponse` minted a fresh session every time it was POSTed until it
  expired, after logout and after SLO alike.

  `claim/2` records the assertion's digest until its stale time and answers
  `:ok` the first time and `{:error, :duplicate_assertion}` after. The digest is
  of the SIGNED assertion (`xmerl_dsig:digest/1` strips the Signature and
  canonicalises), so re-wrapping the same assertion in a new, unsigned
  envelope does not make it new. Expired rows are swept on each claim; they
  are never needed again, since an expired assertion fails esaml's own
  conditions check before this ledger is consulted.
  """
  use Ecto.Schema
  import Ecto.Query

  alias Barkpark.Repo

  @primary_key {:digest, :string, autogenerate: false}
  schema "saml_assertion_replays" do
    field :expires_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  @doc "Record `digest` until `expires_at`. `:ok` once, then `{:error, :duplicate_assertion}`."
  @spec claim(binary(), DateTime.t()) :: :ok | {:error, :duplicate_assertion}
  def claim(digest, %DateTime{} = expires_at) when is_binary(digest) do
    now = DateTime.utc_now()

    Repo.delete_all(from(r in __MODULE__, where: r.expires_at < ^now))

    row = %{
      digest: Base.encode16(digest, case: :lower),
      expires_at: expires_at,
      inserted_at: now
    }

    case Repo.insert_all(__MODULE__, [row], on_conflict: :nothing, conflict_target: :digest) do
      {1, _} -> :ok
      {0, _} -> {:error, :duplicate_assertion}
    end
  end
end
