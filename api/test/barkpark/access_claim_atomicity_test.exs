defmodule Barkpark.AccessClaimAtomicityTest do
  @moduledoc """
  Tripwire for the UNENFORCED half of `Barkpark.Access`'s moduledoc claim:

      **Claim is atomic.** `claim/2` conditionally updates `WHERE claimed_at IS
      NULL`, so two concurrent claims cannot both succeed.

  The claim is TRUE on `main`, but only one half of it was enforced. Deleting
  `and is_nil(g.claimed_at)` from `do_claim/2` reds
  `test/barkpark/access_test.exs` ("a single-use grant refuses a second claim").
  Rewriting `do_claim/2` as a read-then-write — `Repo.get`, check `claimed_at`,
  then an UNGUARDED `UPDATE ... WHERE id = $1` — is a genuine TOCTOU and
  survives that whole file with 0 failures, because sequentially the two shapes
  are indistinguishable. This file closes that gap.

  ## What it pins, and what it does NOT

  This is a SQL-SHAPE ORACLE. It attaches to `[:barkpark, :repo, :query]`,
  runs a real `Access.claim/2`, and asserts on the SQL Ecto actually emitted at
  runtime (not on the source text): exactly ONE `UPDATE "access_grants"`
  statement, and that statement carries `"claimed_at" IS NULL`.

  It therefore pins the MECHANISM (one conditional UPDATE that does its own
  check in the WHERE clause), NOT the OUTCOME (two racing claimants, one
  winner). That distinction is the honest limit of this file, and stating it is
  the point: an oracle that oversells itself is the next phantom warrant.

  A true two-connection race is NOT expressible under the Ecto SQL sandbox:

    * `{:shared, pid}` ownership serialises every process onto ONE checked-out
      connection, so a "concurrent" second claimant queues behind the first
      rather than racing it; and
    * `:manual` ownership gives each process its own transaction, so the grant
      row inserted by the test setup is never visible to the second claimant at
      all — the race cannot even be set up.

  A one-connection oracle on the emitted SQL is the strongest cheap check
  available here, so that is what this is.

  ## False-positive risk, for whoever sees this red

  A legitimate refactor that keeps claim atomicity by a DIFFERENT mechanism —
  `SELECT ... FOR UPDATE` then an unguarded update inside the same transaction,
  or a unique partial index on `(id) WHERE claimed_at IS NULL` — would red this
  test even though the invariant still holds. This red is a prompt to
  RE-DERIVE the invariant against the new mechanism (and re-point this oracle
  at it), never a prompt to revert or to soften the moduledoc claim.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Access
  alias Barkpark.Accounts
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy.Auth

  @password "correct-horse-battery"
  @event [:barkpark, :repo, :query]

  defp grantor_token(ws) do
    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token("t-" <> Ecto.UUID.generate()),
        label: "grantor",
        dataset: "test",
        permissions: ["admin"]
      })
      |> Repo.insert()

    {:ok, _} = Auth.create_membership(ws.id, token.id, "admin", "api_token")
    token
  end

  defp grantee_user do
    email = "grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  # Collect every SQL statement this process emits while `fun` runs. Ecto emits
  # its query telemetry synchronously in the CALLING process, so filtering on
  # `self()` keeps this safe under `async: true` — a sibling suite's queries can
  # never land in our bucket.
  defp capture_sql(fun) do
    test_pid = self()
    handler_id = {__MODULE__, test_pid}

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        fn _event, _measurements, metadata, ^test_pid ->
          if self() == test_pid, do: send(test_pid, {:sql, metadata[:query]})
          :ok
        end,
        test_pid
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain_sql([])
  end

  defp drain_sql(acc) do
    receive do
      {:sql, sql} -> drain_sql([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "claim/2 is atomic — the SQL shape says so" do
    test "emits exactly one conditional UPDATE on access_grants guarded by claimed_at IS NULL" do
      ws = create_workspace!()
      grantor = grantor_token(ws)
      user = grantee_user()

      {:ok, %{token: raw}} =
        Access.mint(grantor, %{
          grantee_email: "grantee@example.com",
          workspace_id: ws.id,
          capabilities: ["read"],
          single_use: true
        })

      statements = capture_sql(fn -> assert {:ok, _grant} = Access.claim(raw, user) end)

      # The table is `access_grants` (see `Barkpark.Access.Grant`'s schema), NOT
      # `grants`. An oracle keyed on the wrong name observes nothing and greens
      # vacuously, so a zero-UPDATE observation must fail LOUDLY, not silently.
      updates =
        Enum.filter(statements, fn sql ->
          is_binary(sql) and String.contains?(sql, ~s(UPDATE "access_grants"))
        end)

      assert length(updates) == 1,
             """
             expected EXACTLY ONE `UPDATE "access_grants"` during claim/2, saw #{length(updates)}.

             Zero means this oracle observed nothing (wrong table name, telemetry
             prefix drift, or claim/2 no longer writing) — a vacuous green turned
             loud, not a pass. More than one means the single conditional update
             became a multi-statement sequence, which is where TOCTOU lives.

             SQL observed during claim/2:
             #{Enum.map_join(statements, "\n", &"  - #{inspect(&1)}")}
             """

      [update] = updates

      assert String.contains?(update, ~s("claimed_at" IS NULL)),
             """
             the claim UPDATE is not self-guarding: its WHERE clause does not carry
             `"claimed_at" IS NULL`, so the check happened somewhere else (a prior
             read) and two concurrent claims could both win — a read-then-write
             TOCTOU. `Barkpark.Access`'s moduledoc says the update is conditional.

             statement: #{inspect(update)}
             """
    end
  end
end
