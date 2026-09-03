defmodule BarkparkCloud.Notifications.WithholdBatchTest do
  @moduledoc """
  cch-withhold-fanout-write-amplification — the SHAPE of the withhold write.

  `Withhold.record/4` fans one withheld notification out to one `suppressed`
  `Delivery` row per team member. The GRAIN is correct and is pinned in
  `withhold_test.exs` §2; what was wrong was the number of statements it took —
  one `Repo.insert/1` per member, so a ten-member team cost ten round trips for
  one decision.

  These tests measure the statements, not the rows. They are the instrument the
  row-grain tests cannot be: a per-row insert and a batched insert produce
  IDENTICAL rows, so nothing that reads the delivery log can tell them apart, and
  a "fix" that quietly changed the grain instead of the shape would be green
  everywhere else in the suite.

  ## The measurement

  Ecto emits `[:barkpark_cloud, :repo, :query]` per statement. The handler below
  filters on the team's OWN id appearing in the query's dumped params, so a
  concurrent async test's traffic cannot be counted into this file's totals.

  ## Why the clamp is re-proved here

  `insert_suppressed/1` had to stop calling `Repo.insert/1`, and `insert_all/2`
  runs NO changeset — so the batched path could have shipped as a pure
  performance win that silently deleted `Delivery.changeset/2`'s `last_error`
  clamp, the property that keeps a raw transport term (which carries the SMTP
  relay host) off a page every team admin can read. §3 drives a raw transport
  term through the batched path and asserts it is still refused.
  """
  use BarkparkCloud.DataCase, async: false

  import ExUnit.CaptureLog

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.{Delivery, Withhold}

  ## Fixtures

  defp team_with_members(count) do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})

    emails =
      for i <- 1..count do
        m = System.unique_integer([:positive])
        email = "member-#{m}-#{i}@example.com"

        {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
        {:ok, _} = Accounts.add_member(team, user, if(i == 1, do: "owner", else: "member"))
        email
      end

    {team, emails}
  end

  # Every SQL statement executed inside `fun` whose params mention `team_id`.
  # The id filter is what makes this safe next to other tests: a statement from
  # another team's fixture never carries this team's dumped uuid.
  defp statements_touching(team_id, fun) do
    raw = Ecto.UUID.dump!(team_id)
    ref = make_ref()
    test = self()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:barkpark_cloud, :repo, :query],
      fn _event, _measure, meta, _config ->
        if raw in List.wrap(meta[:params]), do: send(test, {ref, meta.query})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    collect(ref, [])
  end

  defp collect(ref, acc) do
    receive do
      {^ref, query} -> collect(ref, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp inserts_into_deliveries(statements),
    do: Enum.filter(statements, &(&1 =~ ~r/^INSERT INTO "notification_deliveries"/))

  defp member_email_selects(statements),
    do: Enum.filter(statements, &(&1 =~ ~r/^SELECT/ and &1 =~ "team_memberships"))

  ## 1. ONE member-email query per call — not one per member, and (with the
  ##    reaper's per-dropped-alert loop deleted) not one per withheld alert.

  test "record/4 resolves the member list with exactly ONE query for N members" do
    {team, emails} = team_with_members(5)
    assert length(emails) == 5

    statements =
      statements_touching(team.id, fn -> Withhold.record(team.id, "x", :reap_alert_cap) end)

    assert length(member_email_selects(statements)) == 1,
           "the member list must be resolved once per call, got " <>
             "#{length(member_email_selects(statements))} lookups for 5 members"
  end

  ## 2. ONE insert for the whole fan-out — the amplification this row is about.

  test "record/4 writes N member rows in ONE insert statement" do
    {team, emails} = team_with_members(6)

    statements =
      statements_touching(team.id, fn ->
        assert Withhold.record(team.id, "deployment_failed", :reap_alert_cap) == 6
      end)

    inserts = inserts_into_deliveries(statements)

    assert length(inserts) == 1,
           "6 member rows must cost ONE insert, got #{length(inserts)} statements"

    # THE GRAIN IS UNCHANGED — one row per member, that member's own address.
    # A batched write that lost a row, or collapsed six people into one marker,
    # would pass the statement count above and fail here.
    rows = Notifications.list_deliveries(team, status: "suppressed", limit: 100)
    assert length(rows) == 6
    assert rows |> Enum.map(& &1.recipient) |> Enum.sort() == Enum.sort(emails)

    for row <- rows do
      assert row.status == "suppressed"
      assert row.attempts == 0
      assert row.channel == "email"
      assert row.kind == "alert"
      assert row.last_error == Withhold.label(:reap_alert_cap)
    end
  end

  ## 3. THE CLAMP SURVIVES THE BATCH. `insert_all/2` runs no changeset, so the
  ##    batched path validates every entry itself and drops what does not pass.

  test "a raw transport term is REFUSED through the batched path, and its batch mates still land" do
    {team, [good | _]} = team_with_members(1)

    raw = "** (Mint.TransportError) connection refused to smtp.relay.internal:587"

    base = %{
      team_id: team.id,
      event: "deployment_failed",
      channel: "email",
      kind: "alert",
      status: "suppressed",
      attempts: 0
    }

    log =
      capture_log(fn ->
        assert Withhold.insert_suppressed([
                 Map.merge(base, %{recipient: "leak@example.com", last_error: raw}),
                 Map.merge(base, %{
                   recipient: good,
                   last_error: Withhold.label(:reap_alert_cap)
                 })
               ]) == 1
      end)

    assert log =~ "refused a suppressed delivery"

    rows = Notifications.list_deliveries(team, status: "suppressed", limit: 100)
    assert length(rows) == 1
    assert hd(rows).recipient == good
    assert hd(rows).last_error == Withhold.label(:reap_alert_cap)

    # The relay host never reached the column the console publishes verbatim.
    refute Repo.exists?(from(d in Delivery, where: d.last_error == ^raw))
  end

  ## 4. The batch is not a bypass of the OTHER validations either.

  test "an entry with no recipient is refused, and an empty batch is a quiet zero" do
    {team, _} = team_with_members(1)

    log =
      capture_log(fn ->
        assert Withhold.insert_suppressed([
                 %{
                   team_id: team.id,
                   event: "deployment_failed",
                   status: "suppressed",
                   last_error: Withhold.label(:reap_alert_cap)
                 }
               ]) == 0
      end)

    assert log =~ "refused a suppressed delivery"
    assert Notifications.list_deliveries(team, limit: 100) == []

    assert Withhold.insert_suppressed([]) == 0
  end
end
