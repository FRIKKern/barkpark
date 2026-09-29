defmodule Barkpark.SeedsCleanRemintAfterRevokeTest do
  @moduledoc """
  pds-bl-up-seed-remint-crash-after-revoke, c1: the MatchError path, REPRODUCED
  and then CONTAINED.

  THE DEFECT. `api_tokens.token_hash` is unique-indexed, and
  `Seeds.Clean.admin_token_present?/1` requires `revoked_at IS NULL`. So a FIXED
  `BARKPARK_SEED_ADMIN_TOKEN` — the `bp setup` path pastes one into
  `~/.barkpark/.env`, which `bin/barkpark`'s `load_env` sources wholesale — that
  is LATER REVOKED sends the next seed run down the mint branch carrying a raw
  token whose hash is already on a row. `Auth.create_token/5` declares
  `unique_constraint(:token_hash)`, so the insert comes back as
  `{:error, %Ecto.Changeset{}}`, and the old hard match in
  `mint_admin_token!/2` raised

      ** (MatchError) no match of right hand side value:
         {:error, #Ecto.Changeset<action: :insert,
           errors: [token_hash: {"has already been taken", ...constraint: :unique...}]>}

  out of a private function — killing `mix run priv/repo/seeds.exs` and, under
  `set -euo pipefail`, the shell verb that shelled out to it.

  THE SUBSTITUTION, STATED. The row says "reproduce on a scratch box". This
  suite reproduces the same collision against the REAL code path in-process —
  mint with a fixed raw token, revoke it, run the seed again with that same raw
  token in the env. Nothing here fakes the failure: the unique index does the
  refusing, and the pre-fix run really does raise MatchError (RED-BEFORE, PR
  body). What a scratch box would add is only the shell's exit code, which
  `mix run` propagates unchanged.

  WHAT IS NOT CHANGED. The refusal itself. The re-mint-after-revoke decision is
  already made on this row's c0 and stated at `bin/barkpark`'s `cmd_token`
  header: a revoked credential is a CLOSED GATE, recovery is the owner's
  explicit verb. Only the SHAPE of the failure changes — a named error with a
  cause and a remedy instead of a MatchError.

  async: false — the seed reads BARKPARK_SEED_ADMIN_TOKEN from the process env
  and the plugin Registry / Bootstrap tail is a shared singleton.
  """

  use Barkpark.DataCase, async: false

  import ExUnit.CaptureIO

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content.{Document, SchemaDefinition}
  alias Barkpark.Seeds

  @pinned_raw "bp_admin_pinned_in_dotenv_then_revoked"

  # A genuinely FRESH box inside the sandbox transaction: a developer's
  # `MIX_ENV=test mix ecto.reset` commits demo rows, and a leftover unrevoked
  # admin token would make the seed SKIP the mint and this suite measure
  # nothing. Memberships referencing tokens go first.
  setup do
    Repo.delete_all(
      from(m in Barkpark.Tenancy.Membership, where: m.principal_type == "api_token")
    )

    Repo.delete_all(ApiToken)
    Repo.delete_all(Document)
    Repo.delete_all(SchemaDefinition)

    System.put_env("BARKPARK_SEED_ADMIN_TOKEN", @pinned_raw)
    on_exit(fn -> System.delete_env("BARKPARK_SEED_ADMIN_TOKEN") end)
    :ok
  end

  defp run_clean, do: capture_io(fn -> Seeds.run(:clean) end)

  defp pinned_row, do: Repo.get_by(ApiToken, token_hash: ApiToken.hash_token(@pinned_raw))

  # PRECONDITION, asserted rather than assumed: the first run really minted the
  # pinned token, and the revoke really landed. Without both, the second run
  # would take the skip branch and the verdict below would be about nothing.
  defp mint_then_revoke! do
    first = run_clean()
    assert first =~ "Admin token installed from BARKPARK_SEED_ADMIN_TOKEN (not echoed)."

    minted = pinned_row()
    refute is_nil(minted)

    {:ok, revoked} = Auth.revoke_token(minted)
    refute is_nil(revoked.revoked_at)

    revoked
  end

  # THE DETECTOR. Reds on origin/main's clean.ex with the MatchError quoted in
  # the moduledoc; passes with the named error.
  test "a revoked pinned BARKPARK_SEED_ADMIN_TOKEN raises a NAMED error, not a MatchError" do
    revoked = mint_then_revoke!()

    err =
      assert_raise Barkpark.Seeds.AdminTokenMintError, fn ->
        capture_io(fn -> Seeds.run(:clean) end)
      end

    # The message must NAME the cause — a revoked token with the same hash —
    # and say what to do. A bare "mint failed" would be a renamed crash.
    assert err.message =~ "BARKPARK_SEED_ADMIN_TOKEN"
    assert err.message =~ "REVOKED"
    assert err.message =~ "token_hash is unique"
    assert err.message =~ "unset BARKPARK_SEED_ADMIN_TOKEN"
    assert err.message =~ "a DIFFERENT value"

    # It must NOT echo the credential it is talking about.
    refute err.message =~ @pinned_raw

    # And the gate stays CLOSED: no second row, the revoked one untouched.
    assert Repo.aggregate(ApiToken, :count, :id) == 1
    still = pinned_row()
    assert still.id == revoked.id
    assert still.revoked_at == revoked.revoked_at
  end

  # CONTROL 1 — the named error is specific to the collision, not the seed's
  # standing behaviour. With the SAME pinned env var and no revoke, the second
  # run takes the skip branch and raises nothing.
  test "CONTROL: an unrevoked pinned token still skips quietly — no error at all" do
    run_clean()

    second = run_clean()

    assert second =~ "Admin token already present — skipping token bootstrap."
    assert Repo.aggregate(ApiToken, :count, :id) == 1
  end

  # CONTROL 2 — the REMEDY the message prescribes actually works, so the error
  # is an exit and not a dead end. After the revoke, a DIFFERENT pinned value
  # mints cleanly.
  test "CONTROL: the prescribed remedy works — a different pinned value mints" do
    mint_then_revoke!()

    fresh = "bp_admin_a_different_value_entirely"
    System.put_env("BARKPARK_SEED_ADMIN_TOKEN", fresh)

    output = run_clean()

    assert output =~ "Admin token installed from BARKPARK_SEED_ADMIN_TOKEN (not echoed)."
    {:ok, token} = Auth.verify_token(fresh)
    assert Auth.has_permission?(token, "admin")
  end
end
