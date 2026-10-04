defmodule Barkpark.Accounts.WebauthnChallengeReplay do
  @moduledoc """
  The one-time-use ledger for passkey authentication challenges (owner ruling
  #34 item 2, 2026-10-03). A login or step-up challenge is a signed
  `Phoenix.Token` valid for five minutes. For an authenticator that always
  reports sign count 0 (synced passkeys), the clone check in
  `Barkpark.Accounts.Webauthn` cannot tell a replay from a fresh use, so a
  captured assertion body used to mint a new session every time it was POSTed
  inside that window.

  `claim/2` records the challenge's digest until the token expires and answers
  `:ok` the first time and `{:error, :challenge_spent}` after. It runs only
  after the assertion verified, so junk requests write nothing. Expired rows
  are swept on each claim; an expired challenge token fails `Phoenix.Token`'s
  own `max_age` check before this ledger is consulted.
  """
  use Ecto.Schema
  import Ecto.Query

  alias Barkpark.Repo

  @primary_key {:digest, :string, autogenerate: false}
  schema "webauthn_challenge_replays" do
    field :expires_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  @doc "Record `challenge_bytes` until `expires_at`. `:ok` once, then `{:error, :challenge_spent}`."
  @spec claim(binary(), DateTime.t()) :: :ok | {:error, :challenge_spent}
  def claim(challenge_bytes, %DateTime{} = expires_at) when is_binary(challenge_bytes) do
    now = DateTime.utc_now()

    Repo.delete_all(from(r in __MODULE__, where: r.expires_at < ^now))

    row = %{
      digest: :sha256 |> :crypto.hash(challenge_bytes) |> Base.encode16(case: :lower),
      expires_at: expires_at,
      inserted_at: now
    }

    case Repo.insert_all(__MODULE__, [row], on_conflict: :nothing, conflict_target: :digest) do
      {1, _} -> :ok
      {0, _} -> {:error, :challenge_spent}
    end
  end
end
