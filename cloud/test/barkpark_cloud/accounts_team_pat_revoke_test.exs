defmodule BarkparkCloud.AccountsTeamPatRevokeTest do
  @moduledoc """
  `Accounts.revoke_team_personal_access_token/2` — the admin-side kill switch
  for a team member's PAT — asserted AT THE CONTEXT LEVEL, on its return value
  and on the rows it did or did not touch.

  WHAT WAS AND WAS NOT ALREADY COVERED, stated plainly so this file is not read
  as closing a hole it does not close. The task that asked for this file
  (task-f35dda7bbecbcd35) measured `grep -rn 'revoke_team_personal_access_token'
  cloud/test/` -> 0 hits and read that as "ZERO tests of any kind". The grep is
  right and the reading is wrong: `web/router_team_tokens_test.exs` drives this
  function end to end through `DELETE /v1/teams/:id/tokens/:token_id` and never
  names it, so a NAME-keyed grep cannot see it. That file already pins the
  cross-team 404 + survival, the non-UUID 404, the session-context 404 and a
  two-call idempotent 200/200 — all at HTTP status granularity.

  So what this file adds is not "the first coverage", it is the granularity the
  route cannot give:

    * the REFUSAL SHAPE: a foreign token id returns byte-for-byte what a
      never-existed id returns, `{:error, :not_found}` — the route flattens both
      to the same 404, so a refusal that leaked (`{:error, :forbidden}`, or a
      distinguishable tuple) would not have reddened anything;
    * the SURVIVING ROW read back as a row: `revoked_at` still `nil`, not merely
      "a later request still 200s";
    * the CONTEXT fence standing ALONE: the route's session-token test shares
      nothing with the pat row but the user, and a session token carries
      `team_id: nil`, so `team_id:` alone already refuses it and deleting
      `context: "pat"` leaves that test green. The fixture here is a non-pat
      token minted ON THE TEAM, so `context:` is the only thing refusing;
    * IDEMPOTENCE as a TIMESTAMP, not a status: the second call must return
      `{:ok, _}` AND leave `revoked_at` exactly where the first call put it. Two
      200s prove the call did not crash; they do not prove the tombstone stayed
      put, and a re-stamp would be a silently rewritten audit fact;
    * the non-binary clause (`revoke_team_personal_access_token(_team, _token_id)`)
      which the route, whose `path_params` are always strings, can never reach.

  ONE CLAIM PER TEST, on purpose: ExUnit stops a test at its first failing
  assertion, so a single test leading with the return value would leave the
  destructive half — the half that matters — unproved under a mutation.

  TEAM-SCOPED ASSERTIONS ONLY, never a global `Repo.aggregate`: every agent in
  this repo shares one test database.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.UserToken
  alias BarkparkCloud.Repo

  @password "correct-horse-battery"

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  # THE TWO FIXTURES, field for field. Both PATs are minted by
  # `create_personal_access_token/3` from the SAME `@attrs` binding, by the SAME
  # holder (`holder`, made owner of BOTH teams on purpose so `user_id` and the
  # ability ceiling are not free variables either):
  #
  #   field             happy-path (team_a)   cross-team (team_b)   why
  #   name              "twin-key"            "twin-key"            same — one binding
  #   abilities         ["read"]              ["read"]              same — one binding
  #   user_id           holder.id             holder.id             same
  #   context           "pat"                 "pat"                 same — put_change/3
  #   revoked_at        nil                   nil                   same
  #   last_used_at      nil                   nil                   same
  #   ip_address        nil                   nil                   same
  #   user_agent        nil                   nil                   same
  #   origin            nil                   nil                   same
  #   session_token_id  nil                   nil                   same
  #   sent_to           nil                   nil                   same
  #   failed_attempts   0                     0                     same — schema default
  #   expiry_warned_at  nil                   nil                   same
  #   team_id           team_a.id             team_b.id             THE ONE VARIABLE
  #   id                uuid A                uuid B                FORCED: @primary_key
  #                                                                 {:id, :binary_id,
  #                                                                 autogenerate: true}
  #   token_hash        sha256(raw A)         sha256(raw B)         FORCED:
  #                                                                 do_create_personal_access_token/3
  #                                                                 mints a fresh
  #                                                                 `generate_token()` per row
  #                                                                 and stores only its hash
  #                                                                 (and token_hash is UNIQUE)
  #   expires_at        now_A + default days  now_B + default days  FORCED: derived from
  #                                                                 DateTime.utc_now() at mint
  #                                                                 time; differs by microseconds
  #   inserted_at/      two clock reads       two clock reads       FORCED: timestamps(type:
  #   updated_at                                                    :utc_datetime_usec)
  #
  # Nothing else differs. The IDENTICAL `name` is legal: nothing in
  # `pat_changeset/2` or the table constrains a PAT name to be unique, per team
  # or otherwise — which is exactly the collision the `team_id` fence must
  # survive without help from a name.
  @attrs %{name: "twin-key", abilities: ["read"]}

  defp twin_pats do
    holder = user_fixture()
    team_a = team_fixture()
    team_b = team_fixture()
    {:ok, _} = Accounts.add_member(team_a, holder, "owner")
    {:ok, _} = Accounts.add_member(team_b, holder, "owner")

    {:ok, _plain_a, pat_a} = Accounts.create_personal_access_token(holder, team_a, @attrs)
    {:ok, _plain_b, pat_b} = Accounts.create_personal_access_token(holder, team_b, @attrs)

    %{holder: holder, team_a: team_a, team_b: team_b, pat_a: pat_a, pat_b: pat_b}
  end

  # The fixture has to isolate `context:` from `team_id:`. A session token is
  # the obvious non-pat row and the WRONG one here: `create_user_session_token/2`
  # goes through `UserToken.changeset/2`, whose cast list has no `:team_id`, so
  # the row lands with `team_id: nil` and `team_id: tid` alone already refuses
  # it — deleting `context: "pat"` would leave such a test GREEN.
  #
  # So this row is minted ON THE TEAM: `team_id` is put on the STRUCT (the
  # generic changeset cannot cast it) and the context is "sse", a real context
  # of this table. Every field it shares with a PAT is shared; the ONE thing
  # standing between it and this door is `context: "pat"`.
  defp team_scoped_non_pat(team, user) do
    {:ok, row} =
      %UserToken{team_id: team.id}
      |> UserToken.changeset(%{
        user_id: user.id,
        context: "sse",
        token_hash: "not-a-pat-#{System.unique_integer([:positive])}",
        expires_at:
          DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.truncate(:microsecond)
      })
      |> Repo.insert()

    row
  end

  describe "revoke_team_personal_access_token/2 — the team_id fence" do
    test "the twins differ ONLY in team_id (plus the identity/secret/clock fields the schema forces)" do
      %{pat_a: a, pat_b: b, team_a: team_a, team_b: team_b} = twin_pats()

      # The free fields are equal...
      assert a.name == b.name
      assert a.abilities == b.abilities
      assert a.user_id == b.user_id
      assert a.context == b.context and a.context == "pat"
      assert a.revoked_at == nil and b.revoked_at == nil

      # ...the variable under test is not...
      assert a.team_id == team_a.id
      assert b.team_id == team_b.id
      refute a.team_id == b.team_id

      # ...and every REMAINING difference is one the schema or the mint forces,
      # named with the constraint that forces it. Anything not in this list is
      # asserted equal above.
      forced = [:id, :token_hash, :expires_at, :inserted_at, :updated_at, :team_id]

      differing =
        for f <- [
              :id,
              :token_hash,
              :context,
              :name,
              :abilities,
              :expires_at,
              :revoked_at,
              :last_used_at,
              :expiry_warned_at,
              :sent_to,
              :failed_attempts,
              :ip_address,
              :user_agent,
              :origin,
              :session_token_id,
              :user_id,
              :team_id,
              :inserted_at,
              :updated_at
            ],
            Map.get(a, f) != Map.get(b, f),
            do: f

      # Subset, not equality: two clock reads CAN land on the same microsecond,
      # so a forced field is ALLOWED to come out equal. What may never happen is
      # a difference this list does not name.
      assert differing -- forced == []
      assert :team_id in differing
    end

    test "[fence-a] another team's PAT id RETURNS exactly what an unknown id returns" do
      %{team_a: team_a, pat_a: pat_a, pat_b: pat_b} = twin_pats()

      assert {:error, :not_found} =
               Accounts.revoke_team_personal_access_token(team_a, pat_b.id)

      # Byte-for-byte identical to a NEVER-EXISTED id: the refusal leaks nothing
      # about whether the id is real, so an admin cannot probe another team's
      # token ids for existence.
      unknown = Ecto.UUID.generate()

      assert Accounts.revoke_team_personal_access_token(team_a, pat_b.id) ==
               Accounts.revoke_team_personal_access_token(team_a, unknown)

      # HAPPY-PATH CONTROL, in this body: the same call with the id's OWN team
      # succeeds, so the not_found above is the FENCE refusing rather than the
      # function being dead.
      assert {:ok, %UserToken{id: killed}} =
               Accounts.revoke_team_personal_access_token(team_a, pat_a.id)

      assert killed == pat_a.id
    end

    test "[fence-b] the other team's PAT row SURVIVES UNREVOKED (re-read from the database)" do
      %{team_a: team_a, pat_a: pat_a, pat_b: pat_b} = twin_pats()

      _ = Accounts.revoke_team_personal_access_token(team_a, pat_b.id)

      # The re-read is the assertion — NOT the return value. A refusal that still
      # stamped the row would pass [fence-a] and BE the whole bug. This is the
      # FIRST assertion in this test so the mutation reds it directly.
      assert %UserToken{revoked_at: nil, team_id: still_b} = Repo.get(UserToken, pat_b.id)
      assert still_b == pat_b.team_id

      # HAPPY-PATH CONTROL, same body: team_a's own twin IS revocable, so the
      # survival above is the fence and not a dead call...
      assert {:ok, %UserToken{}} = Accounts.revoke_team_personal_access_token(team_a, pat_a.id)
      assert %UserToken{revoked_at: %DateTime{}} = Repo.get(UserToken, pat_a.id)

      # ...and the control did not reach across either.
      assert %UserToken{revoked_at: nil} = Repo.get(UserToken, pat_b.id)
    end

    test "[fence-c] the admin's own team-scoped list is unchanged by the refused call" do
      %{team_a: team_a, team_b: team_b, pat_a: pat_a, pat_b: pat_b} = twin_pats()

      _ = Accounts.revoke_team_personal_access_token(team_a, pat_b.id)

      # TEAM-SCOPED, never a global aggregate: one live row each side, the same
      # two rows as before the call.
      assert [%UserToken{id: only_a, revoked_at: nil}] =
               Accounts.list_team_personal_access_tokens(team_a)

      assert only_a == pat_a.id

      assert [%UserToken{id: only_b, revoked_at: nil}] =
               Accounts.list_team_personal_access_tokens(team_b)

      assert only_b == pat_b.id
    end
  end

  describe "revoke_team_personal_access_token/2 — the context: \"pat\" fence" do
    test "a NON-PAT token carrying this very team_id is NOT revocable through this door" do
      %{holder: holder, team_a: team_a, pat_a: pat_a} = twin_pats()
      other = team_scoped_non_pat(team_a, holder)

      # Precondition, asserted rather than assumed: the decoy really does carry
      # the team_id the fence tests for, so `team_id:` cannot be what refuses it.
      assert other.team_id == team_a.id
      assert other.context == "sse"

      assert {:error, :not_found} =
               Accounts.revoke_team_personal_access_token(team_a, other.id)

      # And it SURVIVES unstamped — the refusal is not a silent revoke.
      assert %UserToken{revoked_at: nil, context: "sse"} = Repo.get(UserToken, other.id)

      # HAPPY-PATH CONTROL, same body: a real PAT on the same team, revoked by
      # the same call, so the refusal above is `context:` and not a dead door.
      assert {:ok, %UserToken{}} = Accounts.revoke_team_personal_access_token(team_a, pat_a.id)
    end
  end

  describe "revoke_team_personal_access_token/2 — the uuid_or_nil guard" do
    test "a non-UUID token id is {:error, :not_found}, NOT a raised CastError" do
      %{team_a: team_a} = twin_pats()

      # Without `Repo.uuid_or_nil/1` this is an Ecto.Query.CastError — a 500
      # where the contract says 404. `assert` on the tuple, so a raise fails the
      # test rather than being rescued into a pass.
      assert {:error, :not_found} =
               Accounts.revoke_team_personal_access_token(team_a, "not-a-uuid")

      assert {:error, :not_found} = Accounts.revoke_team_personal_access_token(team_a, "")

      # Same shape as a well-formed id that simply does not exist: the guard
      # routes to the SAME branch, it does not invent a second refusal.
      assert Accounts.revoke_team_personal_access_token(team_a, "not-a-uuid") ==
               Accounts.revoke_team_personal_access_token(team_a, Ecto.UUID.generate())
    end

    test "a NON-BINARY token id falls to the catch-all clause, not a FunctionClauseError" do
      %{team_a: team_a} = twin_pats()

      # `when is_binary(token_id)` guards the real clause; this is the arity-2
      # fallback beneath it. The route can never produce this (path_params are
      # always strings), so nothing else in the suite reaches the clause.
      assert {:error, :not_found} = Accounts.revoke_team_personal_access_token(team_a, nil)
      assert {:error, :not_found} = Accounts.revoke_team_personal_access_token(team_a, 42)
    end
  end

  describe "revoke_team_personal_access_token/2 — idempotence" do
    test "a second revoke returns {:ok, _} and does NOT move revoked_at" do
      %{team_a: team_a, pat_a: pat_a} = twin_pats()

      assert {:ok, %UserToken{revoked_at: first}} =
               Accounts.revoke_team_personal_access_token(team_a, pat_a.id)

      assert %DateTime{} = first

      # The stamp as the DATABASE holds it, read back before the second call.
      %UserToken{revoked_at: stored_before} = Repo.get(UserToken, pat_a.id)
      assert stored_before == first

      assert {:ok, %UserToken{revoked_at: second}} =
               Accounts.revoke_team_personal_access_token(team_a, pat_a.id)

      # THE CLAIM: the timestamp, not the return shape. Two `{:ok, _}`s prove the
      # call did not crash; only this proves the tombstone stayed put. A re-stamp
      # would silently rewrite when the credential died.
      assert second == first
      %UserToken{revoked_at: stored_after} = Repo.get(UserToken, pat_a.id)
      assert stored_after == stored_before
    end

    test "the revoked token's :user stays preloaded on BOTH calls so the audit row can name the holder" do
      %{holder: holder, team_a: team_a, pat_a: pat_a} = twin_pats()

      assert {:ok, %UserToken{user: %{id: id1}}} =
               Accounts.revoke_team_personal_access_token(team_a, pat_a.id)

      assert id1 == holder.id

      # The already-revoked branch is a DIFFERENT clause with its own
      # `Repo.preload/2`; dropping it there would hand the router's audit
      # callback `token.user == nil` on every repeat revoke.
      assert {:ok, %UserToken{user: %{id: id2}}} =
               Accounts.revoke_team_personal_access_token(team_a, pat_a.id)

      assert id2 == holder.id
    end
  end
end
