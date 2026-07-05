defmodule Barkpark.Accounts.Webauthn do
  @moduledoc """
  WebAuthn / passkey ceremonies, wrapping the vetted `wax` FIDO2 library — no
  hand-rolled attestation, COSE, or signature verification.

  Two ceremonies, each a two-step round-trip:

    * **registration** — `registration_challenge/1` mints a challenge; the browser's
      `navigator.credentials.create()` returns an attestation object which
      `verify_registration/5` checks (via `Wax.register/3`) and persists as a
      `WebauthnCredential`.
    * **authentication** — `authentication_challenge/1` mints a challenge; the
      browser's `navigator.credentials.get()` returns an assertion which
      `verify_authentication/6` checks (via `Wax.authenticate/6`), enforcing the
      monotonic signature counter (clone detection).

  Only the challenge *bytes* need to survive between the two steps (store them in
  the session or a short-lived signed token). The relying-party id and expected
  origin come from `config :barkpark, :webauthn` (defaults suit local dev), and
  are overridable per call for tests.
  """
  import Ecto.Query, warn: false

  alias Barkpark.Repo
  alias Barkpark.Accounts.{User, WebauthnCredential}

  @doc "Relying-party id — the registrable host the passkey is scoped to."
  @spec rp_id(keyword()) :: String.t()
  def rp_id(opts \\ []), do: opts[:rp_id] || cfg(:rp_id) || "localhost"

  @doc "Expected client origin (or list) for WebAuthn ceremonies."
  @spec origin(keyword()) :: String.t() | [String.t()]
  def origin(opts \\ []), do: opts[:origin] || cfg(:origin) || "http://localhost:4000"

  defp cfg(key), do: Application.get_env(:barkpark, :webauthn, [])[key]

  # ── Registration ────────────────────────────────────────────────────────────

  @doc """
  Mint a registration challenge. Persist `challenge.bytes` (send the base64url
  bytes to the browser); pass them back to `verify_registration/5`.
  """
  @spec registration_challenge(keyword()) :: Wax.Challenge.t()
  def registration_challenge(opts \\ []) do
    Wax.new_registration_challenge(rp_id: rp_id(opts), origin: origin(opts))
  end

  @doc """
  Verify a registration response and persist the new credential for `user`.
  `challenge_bytes` are the raw bytes from the mint step.
  """
  @spec verify_registration(User.t(), binary(), binary(), binary(), keyword()) ::
          {:ok, WebauthnCredential.t()} | {:error, term()}
  def verify_registration(%User{} = user, attestation_object, client_data_json, challenge_bytes, opts \\ []) do
    challenge =
      Wax.new_registration_challenge(rp_id: rp_id(opts), origin: origin(opts), bytes: challenge_bytes)

    with {:ok, {auth_data, _attestation}} <-
           Wax.register(attestation_object, client_data_json, challenge) do
      acd = auth_data.attested_credential_data

      %WebauthnCredential{}
      |> WebauthnCredential.changeset(%{
        user_id: user.id,
        credential_id: acd.credential_id,
        cose_key: :erlang.term_to_binary(acd.credential_public_key),
        sign_count: auth_data.sign_count || 0,
        nickname: opts[:nickname]
      })
      |> Repo.insert()
    end
  end

  # ── Authentication ──────────────────────────────────────────────────────────

  @doc "Mint an authentication challenge. Persist `challenge.bytes`."
  @spec authentication_challenge(keyword()) :: Wax.Challenge.t()
  def authentication_challenge(opts \\ []) do
    Wax.new_authentication_challenge(rp_id: rp_id(opts), origin: origin(opts))
  end

  @doc """
  Verify an assertion for the credential named by `credential_id`. On success
  advances the stored signature counter and returns the credential + its owning
  user. Fails closed on an unknown credential or a non-increasing counter (clone
  signal).
  """
  @spec verify_authentication(binary(), binary(), binary(), binary(), binary(), keyword()) ::
          {:ok, WebauthnCredential.t()} | {:error, term()}
  def verify_authentication(credential_id, auth_data_bin, sig, client_data_json, challenge_bytes, opts \\ []) do
    challenge =
      Wax.new_authentication_challenge(rp_id: rp_id(opts), origin: origin(opts), bytes: challenge_bytes)

    case Repo.get_by(WebauthnCredential, credential_id: credential_id) do
      nil ->
        {:error, :unknown_credential}

      %WebauthnCredential{} = cred ->
        cose_key = load_cose(cred)

        with {:ok, auth_data} <-
               Wax.authenticate(credential_id, auth_data_bin, sig, client_data_json, challenge, [
                 {credential_id, cose_key}
               ]),
             :ok <- counter_ok?(cred.sign_count, auth_data.sign_count) do
          advance_counter(cred, auth_data.sign_count)
        end
    end
  end

  # Both-zero authenticators don't implement a counter — accept. Otherwise the
  # new counter MUST strictly exceed the stored one, else it's a clone signal.
  defp counter_ok?(0, 0), do: :ok
  defp counter_ok?(stored, new) when is_integer(new) and new > stored, do: :ok
  defp counter_ok?(_stored, _new), do: {:error, :sign_count_not_increasing}

  defp advance_counter(cred, new_count) do
    cred
    |> WebauthnCredential.changeset(%{
      sign_count: new_count,
      last_used_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
    })
    |> Repo.update()
  end

  defp load_cose(%WebauthnCredential{cose_key: bin}), do: :erlang.binary_to_term(bin)

  # ── Management ──────────────────────────────────────────────────────────────

  @doc "A user's registered credentials, newest first."
  @spec list_credentials(User.t()) :: [WebauthnCredential.t()]
  def list_credentials(%User{id: uid}) do
    Repo.all(from c in WebauthnCredential, where: c.user_id == ^uid, order_by: [desc: c.inserted_at])
  end

  @doc "True when `user` has at least one passkey — i.e. it can serve as a factor."
  @spec has_passkey?(User.t()) :: boolean()
  def has_passkey?(%User{id: uid}) do
    Repo.exists?(from c in WebauthnCredential, where: c.user_id == ^uid)
  end

  @doc "Delete one of `user`'s credentials by id (scoped — can't touch another user's)."
  @spec delete_credential(User.t(), binary()) :: :ok | {:error, :not_found}
  def delete_credential(%User{id: uid}, id) do
    case Repo.get_by(WebauthnCredential, id: id, user_id: uid) do
      nil -> {:error, :not_found}
      cred -> Repo.delete(cred) |> then(fn {:ok, _} -> :ok end)
    end
  end
end
