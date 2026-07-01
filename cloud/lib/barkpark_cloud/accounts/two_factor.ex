defmodule BarkparkCloud.Accounts.TwoFactor do
  @moduledoc """
  TOTP + recovery-code primitives for two-factor-auth — the Elixir stand-in for
  the slice of Laravel Fortify that Coolify mounted for free
  (`config/fortify.php:138`, `app/Models/User.php` `TwoFactorAuthenticatable`).

  Pure functions only: secret generation, the `otpauth://` provisioning URI,
  RFC-6238 time-step verification (via `:nimble_totp`), and recovery-code
  minting/hashing. The `Accounts` context wires these to the Vault + Repo; this
  module owns the crypto so the context stays orchestration-only — the same
  split as `UserToken.hash_token/1` owning the token-hash scheme.

  Storage discipline (the columns never hold plaintext):

    * the raw TOTP secret is encrypted with `Registry.Vault.encrypt/1`.
    * recovery codes are SHA-256 hashed, the hash array is JSON-encoded, and the
      JSON is encrypted with `Registry.Vault.encrypt/1`. The plaintext code is
      shown to the user exactly once and is unrecoverable thereafter.
  """
  alias BarkparkCloud.Registry.Vault

  @issuer "Barkpark Cloud"
  @recovery_code_count 8

  @doc "A fresh raw TOTP secret (20 random bytes — NimbleTOTP's default)."
  @spec gen_secret() :: binary()
  def gen_secret, do: NimbleTOTP.secret()

  @doc """
  The `otpauth://` URI an authenticator app consumes (rendered to a QR client
  side). `label` is the user's email; the issuer is the product name so the app
  shows "Barkpark Cloud (user@example.com)".
  """
  @spec otpauth_uri(binary(), String.t()) :: String.t()
  def otpauth_uri(secret, label) when is_binary(secret) and is_binary(label) do
    NimbleTOTP.otpauth_uri("#{@issuer}:#{label}", secret, issuer: @issuer)
  end

  @doc "Base32 of the secret — what the SPA shows under the QR for manual entry."
  @spec base32(binary()) :: String.t()
  def base32(secret) when is_binary(secret), do: Base.encode32(secret, padding: false)

  @doc """
  True iff `otp` is a valid 6-digit code for `secret` right now, tolerating ±1
  30-second step of clock skew (the conservative default Coolify inherits from
  Fortify). The previous/next steps are checked explicitly so enroll-confirm and
  the login challenge can never drift on tolerance.
  """
  @spec valid_otp?(binary(), String.t()) :: boolean()
  def valid_otp?(secret, otp) when is_binary(secret) and is_binary(otp) do
    code = String.trim(otp)
    now = System.os_time(:second)

    Enum.any?([-1, 0, 1], fn step ->
      time = now + step * 30
      NimbleTOTP.valid?(secret, code, time: time)
    end)
  end

  def valid_otp?(_secret, _otp), do: false

  @doc """
  Like `valid_otp?/2`, but returns the RFC-6238 30-second time-step index the
  code matched at (`{:ok, step}`) rather than a bare boolean, or `:error` when
  no step in the ±1 window matches. The step index is `div(time, 30)`, so it is
  monotonic in wall-clock time — the `Accounts` context persists the last
  consumed step and rejects any code whose step is <= it, which is what turns
  the inherently-replayable ±1 tolerance window into a single-use verification
  (a valid OTP can be spent exactly once, even within its 90-second validity).

  `now` is injectable for deterministic tests; production always passes the real
  clock. Steps are scanned oldest-first so a code straddling two steps resolves
  to its earliest matching step (the conservative choice for replay).
  """
  @spec matching_step(binary(), String.t(), integer()) :: {:ok, integer()} | :error
  def matching_step(secret, otp, now \\ System.os_time(:second))

  def matching_step(secret, otp, now) when is_binary(secret) and is_binary(otp) do
    code = String.trim(otp)

    Enum.find_value([-1, 0, 1], :error, fn offset ->
      time = now + offset * 30
      if NimbleTOTP.valid?(secret, code, time: time), do: {:ok, div(time, 30)}
    end)
  end

  def matching_step(_secret, _otp, _now), do: :error

  @doc """
  Mint `#{@recovery_code_count}` recovery codes. Returns a list of
  `{plaintext, sha256_hash}` pairs — the plaintext is shown to the user once,
  only the hash is persisted.
  """
  @spec gen_recovery_codes() :: [{String.t(), String.t()}]
  def gen_recovery_codes do
    for _ <- 1..@recovery_code_count do
      plain =
        :crypto.strong_rand_bytes(5)
        |> Base.encode32(padding: false)
        |> String.downcase()

      {plain, hash_code(plain)}
    end
  end

  @doc "SHA-256 hex of a recovery code (same scheme idea as `UserToken.hash_token/1`)."
  @spec hash_code(String.t()) :: String.t()
  def hash_code(code) when is_binary(code) do
    :crypto.hash(:sha256, String.trim(code)) |> Base.encode16(case: :lower)
  end

  ## Vault round-trips — secret + the code-hash array live encrypted at rest.

  @doc "Encrypt the raw TOTP secret for the `two_factor_secret` column."
  @spec encrypt_secret(binary()) :: String.t()
  def encrypt_secret(secret) when is_binary(secret), do: Vault.encrypt(secret)

  @doc "Decrypt the stored secret back to its raw bytes; `{:ok, raw} | :error`."
  @spec decrypt_secret(String.t()) :: {:ok, binary()} | :error
  def decrypt_secret(enc) when is_binary(enc), do: Vault.decrypt(enc)
  def decrypt_secret(_), do: :error

  @doc "Encrypt the JSON array of recovery-code hashes for storage."
  @spec encrypt_codes([String.t()]) :: String.t()
  def encrypt_codes(hashes) when is_list(hashes), do: Vault.encrypt(Jason.encode!(hashes))

  @doc """
  Decrypt the stored recovery-code hash array back to a list. Any failure (no
  codes, undecryptable, bad JSON) is a empty list — fail closed, never crash.
  """
  @spec decrypt_codes(String.t() | nil) :: [String.t()]
  def decrypt_codes(nil), do: []

  def decrypt_codes(enc) when is_binary(enc) do
    with {:ok, json} <- Vault.decrypt(enc),
         {:ok, list} when is_list(list) <- Jason.decode(json) do
      list
    else
      _ -> []
    end
  end

  @doc "How many recovery codes a fresh set holds."
  @spec recovery_code_count() :: pos_integer()
  def recovery_code_count, do: @recovery_code_count
end
