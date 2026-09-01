defmodule BarkparkCloud.Web.RouterSuspendedAtWireTest do
  @moduledoc """
  cch-w54-bl-suspended-at-is-written-but-never-serialized — THE STAMP REACHES
  THE WIRE.

  Suspension is one UPDATE of three columns on the `barkparks` row:
  `suspended`, `suspended_reason` and `suspended_at`
  (`Registry.suspend_barkpark/2`, and the bulk
  `Registry.suspend_team_barkparks/2` behind it). Two of those three were
  serialized. The third was not, on ANY route — `grep -c suspended_at
  cloud/lib/barkpark_cloud/web/router.ex` returned 0 — so every reader could
  say a box was suspended and WHY, but never SINCE WHEN.

  That is not a cosmetic gap, because the console did not render nothing in its
  place: `suspendedCardBannerHtml` fell through to `dunningDates(sub)`, which
  is computed off `sub.current_period_end` — the NEXT renewal day. A box
  suspended today rendered a FUTURE date as a past-tense suspension day. A
  field with no reader is invisible; a field with no reader whose absence is
  papered over by a wrong value is a silent-failure defect, which is why the
  fix is the field and not the copy.

  ## WHY THIS FILE ASSERTS THE WIRE AND NOT THE WRITE

  `billing_lifecycle_test.exs`, `lifecycle_state_manifest_test.exs` and
  `promise_actor_manifest_test.exs` all already assert `suspended_at` is
  WRITTEN, and all three were green across the entire life of this defect.
  They had to be: the write was never broken. A test that reloads the row
  reproduces exactly the blindness being fixed, so every assertion below reads
  the DECODED HTTP RESPONSE and nothing else.

  The reason axis is swept rather than sampled. `suspended_at` is stamped by
  the same clause for every producer, but the CONSUMER branched on the reason
  (the quota arm was made dateless by cch-w54-s1 precisely because the plane
  could not produce this date), so a per-reason pin is what keeps "for every
  reason" from decaying into "for the one reason someone happened to fixture".
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # Every reason the plane actually writes. `billing_lapsed` and
  # `billing_past_due` come from Billing (cancel_subscription/1 and the
  # grace-elapsed arm of mark_past_due/2); `quota_exceeded` comes from
  # Billing.reconcile_plan_limit/1 and is never a payment event.
  @reasons ~w(billing_lapsed billing_past_due quota_exceeded)

  defp user_with_owner_team do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{email: "u-#{n}@example.com", password: @password})
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, token} = Accounts.create_user_session_token(user)
    {team, token}
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "Box #{n}", slug: "box-#{n}"})
    bp
  end

  defp call(method, path, token) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp fleet_row(token, id) do
    conn = call(:get, "/v1/barkparks", token)
    assert conn.status == 200

    conn.resp_body
    |> Jason.decode!()
    |> Map.fetch!("barkparks")
    |> Enum.find(&(&1["id"] == id))
  end

  describe "GET /v1/barkparks carries suspended_at" do
    test "the stamp the suspension wrote is the stamp the fleet row serializes, for EVERY reason" do
      {team, token} = user_with_owner_team()

      for reason <- @reasons do
        bp = barkpark_fixture(team)
        {:ok, suspended} = Registry.suspend_barkpark(bp, reason)

        # The write half, kept only to name the value the wire half must equal.
        # On its own this assertion is the blindness, not the fix.
        assert suspended.suspended_at

        row = fleet_row(token, bp.id)

        assert row["suspended"] == true
        assert row["suspended_reason"] == reason

        # THE ARM. Not `is_map_key` and not "not nil": the serialized instant
        # must be the one the suspension stamped. A serializer wired to any
        # other datetime on the row — `updated_at` moves on every status poll,
        # `inserted_at` is the box's birthday — passes a presence check and
        # still renders the wrong day, which is the defect this row is about.
        assert row["suspended_at"],
               "`suspended_at` is absent from the #{reason} fleet row. It is written by " <>
                 "Registry.suspend_barkpark/2 on every suspension; without it on the wire " <>
                 "the console has no source for the suspension day and falls back to " <>
                 "sub.current_period_end, a FUTURE renewal day."

        assert {:ok, wire, _} = DateTime.from_iso8601(row["suspended_at"])

        assert DateTime.compare(
                 DateTime.truncate(wire, :microsecond),
                 DateTime.truncate(suspended.suspended_at, :microsecond)
               ) == :eq,
               "the wire's suspended_at (#{row["suspended_at"]}) is not the stamp the " <>
                 "suspension wrote (#{inspect(suspended.suspended_at)}) — the serializer is " <>
                 "reading some other column."

        # And it is NOT one of the two datetimes a mis-wire would most plausibly
        # pick up. Both are present on the same row and both are wrong days.
        refute row["suspended_at"] == row["created_at"]
      end
    end

    test "an UNSUSPENDED box carries suspended_at: null — absent, never a borrowed date" do
      {team, token} = user_with_owner_team()
      bp = barkpark_fixture(team)

      row = fleet_row(token, bp.id)

      assert row["suspended"] == false

      assert Map.has_key?(row, "suspended_at"),
             "the key is unconditional, so a client can " <>
               "branch on presence without an existence check"

      assert row["suspended_at"] == nil,
             "a box that was never suspended has no suspension day; null is the only honest " <>
               "answer, and rendering anything else here is the exact substitution this row fixes."
    end

    test "unsuspending clears the stamp on the wire, not just in the row" do
      {team, token} = user_with_owner_team()
      bp = barkpark_fixture(team)

      {:ok, _} = Registry.suspend_barkpark(bp, "quota_exceeded")
      assert fleet_row(token, bp.id)["suspended_at"]

      # Registry.unsuspend_barkpark/1 nulls all three columns so a restored box
      # carries no stale suspension state. The wire must forget it too — a
      # lingering date on a live box is a suspension that never ended.
      {:ok, restored} = Registry.unsuspend_barkpark(Repo.reload!(bp))
      assert is_nil(restored.suspended_at)

      row = fleet_row(token, bp.id)
      assert row["suspended"] == false
      assert row["suspended_at"] == nil
    end
  end
end
