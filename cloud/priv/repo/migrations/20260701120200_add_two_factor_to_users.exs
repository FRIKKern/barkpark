defmodule BarkparkCloud.Repo.Migrations.AddTwoFactorToUsers do
  use Ecto.Migration

  # two-factor-auth (per-user, opt-in TOTP). Mirrors Coolify's 3-column add to
  # `users` — no new table, 2FA is a per-user attribute. (Coolify:
  # database/migrations/2014_10_12_200000_add_two_factor_columns_to_users_table.php.)
  # The three NULLable columns encode the three lifecycle states:
  #   * no 2FA            — all NULL.
  #   * enrolled, pending — secret set, confirmed_at NULL (inert; cannot log in
  #     with it yet — Fortify's `confirm => true` gate).
  #   * fully enabled     — secret + recovery codes + confirmed_at all set.
  # `two_factor_confirmed_at` is the single on/off switch.
  #
  # Storage (never plaintext):
  #   * two_factor_secret         — Registry.Vault.encrypt/1 of the raw TOTP
  #     secret (Base64 AES-256-GCM ciphertext).
  #   * two_factor_recovery_codes — Vault.encrypt/1 of a JSON array of the
  #     SHA-256 HASHES of each recovery code. Consumed codes are removed from
  #     the array; the plaintext is shown exactly once and is unrecoverable.
  #   * two_factor_last_step      — the RFC-6238 30s time-step index of the most
  #     recently ACCEPTED login OTP (bigint). The replay guard: a login code is
  #     accepted only when its step is strictly greater than this, so a valid
  #     OTP — replayable across its ±1 tolerance window by construction — can be
  #     spent exactly once. NULL until the first successful challenge.
  #
  # No FK (1:1 with the row), no index (always read via the already-loaded
  # %User{}). The short-lived "2fa_pending" challenge token rides the EXISTING
  # user_tokens.context column — no token migration needed.
  def change do
    alter table(:users) do
      add :two_factor_secret, :text
      add :two_factor_recovery_codes, :text
      add :two_factor_confirmed_at, :utc_datetime_usec
      add :two_factor_last_step, :bigint
    end
  end
end
