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
  THE ONLY OTP VERIFIER. Returns the RFC-6238 30-second time-step index the code
  matched at (`{:ok, step}`), or `:error` when no step in the ±1 window matches.
  `otp` is trimmed; a non-binary secret or code is `:error`.

  The ±1 step of clock-skew tolerance is the conservative default Coolify
  inherits from Fortify, and the previous/next steps are checked EXPLICITLY so
  enroll-confirm and the login challenge can never drift on tolerance. But a
  tolerance window is inherently REPLAYABLE — the same six digits stay valid for
  ~90 seconds — so a bare boolean "is this code valid right now?" is not a safe
  answer to hand a caller, and this module deliberately offers none.

  Returning the STEP instead is what closes that: the step index is `div(time,
  30)`, so it is monotonic in wall-clock time — the `Accounts` context persists
  the last consumed step and rejects any code whose step is <= it, which turns
  the replayable tolerance window into a single-use verification (a valid OTP
  can be spent exactly once, even within its 90-second validity).

  NO BOOLEAN TWIN, ON PURPOSE. A `valid_otp?/2` used to sit directly above this
  function running exactly the `Enum.any?` over `[-1, 0, 1]` that this one runs,
  minus the step — zero call sites and zero tests anywhere in `cloud/`, yet named
  so it read as the obvious thing to call while this one read as its variant
  ("Like `valid_otp?/2`, but…"). A public function raises no unused warning, and
  a zero-caller sweep could not see it either: its only reference in the whole
  tree was this `@doc`, which named it as the thing this one is "like". So
  nothing would have
  caught the next 2FA surface (step-up confirm, admin re-auth, a recovery flow)
  reaching for the shorter name and getting a replay-blind check.
  `two_factor_replay_door_test.exs` reds if a boolean OTP predicate reappears on
  this module, or if `NimbleTOTP.valid?` is called anywhere in `cloud/lib`
  outside this function.

  `now` is injectable for deterministic tests; production always passes the real
  clock. Steps are scanned oldest-first so a code straddling two steps resolves
  to its earliest matching step (the conservative choice for replay).
  """
  # ── CITED SAFE — class C done RIGHT, and the in-repo MODEL IDIOM
  # (clock-semantics wave, 2026-08-19). Read this before re-sourcing the clock.
  #
  # Provenance: this is the same family as the defect closed by #12628
  # (8598c4efe7), where a wall-clock-derived window was used as a BUCKET KEY, so
  # a caller holding a stale window could delete a newer bucket and reset the
  # budget (atomicity precedent: #12579, e45f1377bb). `div(time, 30)` below is a
  # genuine wall-clock quantiser and the step index IS a bucket key — persisted,
  # and a bound is enforced against it. Class C, correctly.
  #
  # (a) STRUCTURAL: the persisted key is guarded by a STRICT ORDERING PREDICATE
  #     in the WHERE, not by equality and not by a read-then-write —
  #     `(is_nil(u.two_factor_last_step) or u.two_factor_last_step < ^step)` at
  #     cloud/lib/barkpark_cloud/accounts.ex:Accounts.verify_two_factor_otp/2, in the same `update_all` that
  #     sets it. An out-of-order (rewound, replayed, or straddling) step
  #     therefore matches ZERO rows and is rejected. That is exactly #12628's
  #     remedy — tolerate out-of-order buckets by acting only on strictly-newer
  #     ones — applied here PROPHYLACTICALLY, before that defect was found
  #     anywhere. When a future site needs the class-C shape, copy this one.
  #
  # (b) The `[-1, 0, 1]` scan below is EARLIEST-FIRST and returns on first
  #     match, so a code straddling two steps resolves to its OLDEST matching
  #     step and is then rejected by the strict guard. A latest-first scan would
  #     have made the ±1 tolerance window replayable once per code — the
  #     ordering of that list is load-bearing, not cosmetic.
  #
  # CLOCK STEP, both directions: BACKWARD yields a lower `step`, which the
  # strict guard rejects — fail-CLOSED. FORWARD yields a higher `step`, which is
  # accepted and consumed, so the only cost is that some future steps are burned
  # early; a replay of an already-consumed code still fails. `now` is injectable
  # for tests but production always passes the real clock, and no request value
  # reaches it — an attacker cannot supply a time here.
  #
  # CENSUS NOTE worth one line, because it is how this quantiser hid: the
  # canonical census grep `div(System\.` CANNOT SEE IT — the `div` is applied to
  # the local variable `time`, not to a clock call. Any future sweep for
  # bucket-key sites must grep `div(` and follow the binding.
  #
  # WHAT THIS VERDICT DOES NOT REST ON: the moduledoc claim above that the step
  # "is monotonic in wall-clock time". Wall-clock time is NOT monotonic — that
  # is the whole premise of this wave. The verdict rests on the SQL guard at
  # accounts.ex:2186, which holds whether or not the clock behaves.
  #
  # THE MARKER IS THE POINT, not decoration. `aka:` carries `valid_otp` on
  # purpose: the deleted twin's name is the term a reader who learned 2FA from
  # the old code — or from a stale note, a cached search, an LLM's memory of
  # this file — will actually type. Grepping it must land HERE, on the door that
  # returns the step, rather than on nothing (which reads as "no such thing,
  # write your own"). A marker that only lists the surviving spelling protects
  # nobody, because nobody searches for the name they already found.
  # @canonical capability:totp-step-verification aka:otp,2fa,totp,valid_otp,verify_two_factor_otp
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
