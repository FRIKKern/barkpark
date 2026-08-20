defmodule Barkpark.SsoJitRaceTest do
  @moduledoc """
  Mobile charter D5 — the `Sso.find_or_create_user/1` JIT race.

  The original body was an unguarded get-then-insert: two concurrent same-email
  JIT calls could BOTH observe "no user", and the loser's insert then hit the
  `users_email_index` unique constraint — `{:ok, user} = register_user(...)`
  blew up with a MatchError. The app-token exchange makes this window hot (every
  mobile mint JITs the cloud identity), so the leg is now conflict-safe: the
  loser re-fetches the winner's row and both callers get the SAME user.

  Two protective legs:

    * a barrier-released concurrent storm through the public API — the shape
      that CRASHED on the old code (each task's SELECT lands during the bcrypt
      window of its siblings, so collisions are effectively guaranteed);
    * the deterministic lost-race leg through the `@doc false`
      `jit_create_user/1` seam — "we checked nil, somebody inserted, now we
      insert" with no scheduler luck involved.

  async: false — the storm funnels every task through the shared sandbox
  connection on purpose (that serialization is what lines the SELECTs up).
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Accounts.User
  alias Barkpark.Sso

  defp unique_email, do: "jit-race-#{System.unique_integer([:positive])}@example.com"

  test "concurrent same-email JIT calls all return the SAME user, one row total (D5)" do
    email = unique_email()
    parent = self()
    n = 12

    tasks =
      for i <- 1..n do
        Task.async(fn ->
          send(parent, {:ready, i})

          receive do
            :go -> :ok
          end

          Sso.find_or_create_user(email)
        end)
      end

    # Barrier: every task is parked BEFORE its get-then-insert, then all are
    # released together — maximal overlap of the race window.
    for _ <- 1..n do
      receive do
        {:ready, _} -> :ok
      end
    end

    for t <- tasks, do: send(t.pid, :go)

    users = Task.await_many(tasks, 30_000)

    assert Enum.all?(users, &match?(%User{}, &1)),
           "every concurrent JIT call must return a User (old code: loser MatchError)"

    assert users |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1,
           "all concurrent JIT calls must converge on ONE identity"

    assert [row] = Repo.all(from(u in User, where: u.email == ^email))
    assert row.id == hd(users).id
  end

  test "deterministic lost-race leg: the insert path returns the winner's existing row" do
    email = unique_email()

    # The winner lands first...
    winner = Sso.find_or_create_user(email)

    # ...and the loser — who already checked and saw NO user — now runs the
    # insert path against the existing row. Old code: unique-constraint
    # changeset error → MatchError. New code: conflict-safe re-fetch.
    loser = Sso.jit_create_user(email)

    assert %User{} = loser
    assert loser.id == winner.id
  end

  test "fresh email still provisions a confirmed account through the insert path" do
    email = unique_email()

    user = Sso.jit_create_user(email)

    assert %User{} = user
    assert user.email == email
    assert user.confirmed_at != nil, "IdP-vouched JIT accounts are confirmed on creation"
  end
end
