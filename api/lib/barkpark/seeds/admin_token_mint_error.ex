defmodule Barkpark.Seeds.AdminTokenMintError do
  @moduledoc """
  The NAMED failure of the clean profile's admin-token mint
  (`Barkpark.Seeds.Clean`), raised in place of the `{:ok, _token} = …`
  MatchError that used to escape it.

  WHY THIS EXISTS. `api_tokens.token_hash` carries a unique index, and
  `Clean.admin_token_present?/1` requires `revoked_at IS NULL`. So a FIXED
  `BARKPARK_SEED_ADMIN_TOKEN` (the `bp setup` path pastes one into
  `~/.barkpark/.env`, which `bin/barkpark`'s `load_env` sources wholesale)
  that is LATER REVOKED sends the next seed down the mint branch with a raw
  token whose hash is already on a row. `Auth.create_token/5` declares
  `unique_constraint(:token_hash)`, so that comes back as
  `{:error, %Ecto.Changeset{}}` — which the old hard match turned into

      ** (MatchError) no match of right hand side value: {:error, #Ecto.Changeset<…>}

  inside `mint_admin_token!/2`, killing `mix run priv/repo/seeds.exs` and, with
  it, the shell verb that shelled out to it under `set -euo pipefail`. An
  operator got a stack trace naming a private function, and nothing that named
  the revoked token or said what to do next.

  WHAT THIS IS NOT. It is NOT a re-mint. The re-mint-after-revoke question is
  DECIDED (pds-bl-up-seed-remint-crash-after-revoke, and stated verbatim at
  `bin/barkpark`'s `cmd_token` header): a revoked credential is a CLOSED GATE,
  recovery is the owner's explicit verb. This exception contains the crash
  WITHOUT reopening that gate — the seed still refuses, it just now says why
  and how to proceed.
  """
  defexception [:message]
end
