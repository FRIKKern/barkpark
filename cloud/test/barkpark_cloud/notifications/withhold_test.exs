defmodule BarkparkCloud.Notifications.WithholdTest do
  @moduledoc """
  wave 32 S2 — a WITHHELD notification becomes a row a person can read.

  The delivery log was a log of ATTEMPTS: both writers run only after a transport
  returns, and `Delivery.@statuses` was `pending | sent | failed`. So every branch
  that DECIDED not to send was invisible on the one surface built to answer "was
  I notified?" — the 26th owner in a cluster-wide incident read a log that said
  nothing at all.

  These tests drive the funnel itself. The producer-level proof (a real reap
  sweep past the cap writing real rows) lives in
  `deployment_failed_dispatch_test.exs`; here we pin the vocabulary, the ROW
  GRAIN, the consented zero-recipient case, and the `last_error` clamp.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.{Delivery, DeliveryReason, Withhold}

  ## Fixtures

  defp team_with_members(count) do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})

    emails =
      for i <- 1..count do
        m = System.unique_integer([:positive])
        email = "member-#{m}-#{i}@example.com"

        {:ok, user} =
          Accounts.register_user(%{email: email, password: "correct-horse-battery"})

        {:ok, _} = Accounts.add_member(team, user, if(i == 1, do: "owner", else: "member"))
        email
      end

    {team, emails}
  end

  defp empty_team do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Empty #{n}", slug: "empty-#{n}"})
    team
  end

  ## 1. THE VOCABULARY — pinned by EQUALITY, not by inclusion.
  ##
  ##    Nothing pinned `Delivery.statuses/0` in EITHER direction before this
  ##    slice: it is exported and was asserted in zero tests, and the console
  ##    harness's own check was an inclusion loop that is green whether the server
  ##    grows a status the console cannot render or the console invents one the
  ##    server would reject. The counterpart pin is in
  ##    `cloud/priv/static/__app.test.mjs` ("pinned by EQUALITY").

  test "the delivery status vocabulary is EXACTLY these four words" do
    assert Delivery.statuses() == ~w(pending sent failed suppressed)
  end

  test "a suppressed row inserts, reads back team-scoped, and answers ?status=suppressed" do
    {team, [email | _]} = team_with_members(1)

    assert {:ok, %Delivery{status: "suppressed"}} =
             %Delivery{}
             |> Delivery.changeset(%{
               team_id: team.id,
               recipient: email,
               event: "deployment_failed",
               channel: "email",
               kind: "alert",
               status: "suppressed",
               attempts: 0,
               last_error: Withhold.label(:reap_alert_cap)
             })
             |> Repo.insert()

    # The team-scoped delivery surface — the route's own reader.
    assert [%Delivery{status: "suppressed", recipient: ^email}] =
             Notifications.list_deliveries(team)

    # ...and the status filter the console's new chip sends.
    assert [%Delivery{status: "suppressed"}] =
             Notifications.list_deliveries(team, status: "suppressed")

    assert [] = Notifications.list_deliveries(team, status: "failed")
  end

  ## 2. THE GRAIN — one row per MEMBER, with that member's OWN address.
  ##
  ##    A team-level marker row is unreadable by the person it concerns: the log
  ##    is read per-recipient. Any other grain makes "a member can see the alert
  ##    that was withheld from them" structurally impossible.

  test "record/4 writes one suppressed row per member, each with that member's own address" do
    {team, emails} = team_with_members(3)

    assert Withhold.record(team.id, "deployment_failed", :reap_alert_cap) == 3

    rows = Notifications.list_deliveries(team)
    assert length(rows) == 3
    assert Enum.map(rows, & &1.recipient) |> Enum.sort() == Enum.sort(emails)

    for row <- rows do
      assert row.status == "suppressed"
      assert row.event == "deployment_failed"
      assert row.channel == "email"
      assert row.kind == "alert"
      # Nothing was attempted — an attempt count of 1 would read as "we tried".
      assert row.attempts == 0
      assert row.last_error == Withhold.label(:reap_alert_cap)
      # The reason names the DECISION, and none of the failure sentences can.
      refute row.last_error in Enum.map(DeliveryReason.classes(), &DeliveryReason.label/1)
    end
  end

  test "two withholds for the same team are two rows per member — a decision each, not a dedupe" do
    {team, _emails} = team_with_members(2)

    assert Withhold.record(team.id, "deployment_failed", :reap_alert_cap) == 2
    assert Withhold.record(team.id, "deployment_failed", :reap_alert_cap) == 2

    assert length(Notifications.list_deliveries(team, limit: 50)) == 4
  end

  ## 3. THE CONSENTED ZERO-RECIPIENT CASE — named, and a no-op that COUNTS.
  ##
  ##    `Delivery` requires a recipient. Two withhold sites have none by
  ##    construction (a team with no member emails; the fleet digest with no
  ##    platform admins). They are consented — there is no person the alert was
  ##    withheld FROM — and they must never be given a synthetic recipient, which
  ##    would be a row claiming somebody was involved who was not.

  test "a team with zero member emails is a no-op that returns a COUNT, never a fabricated row" do
    team = empty_team()

    assert Withhold.record(team.id, "deployment_failed", :reap_alert_cap) == 0
    assert Notifications.list_deliveries(team) == []
  end

  test "a nil team and an unknown reason are counted no-ops, never raises" do
    assert Withhold.record(nil, "deployment_failed", :reap_alert_cap) == 0
    assert Withhold.record(Ecto.UUID.generate(), "deployment_failed", :not_a_reason) == 0
  end

  ## 4. THE CLAMP — `last_error` admits TWO vocabularies and nothing else.
  ##
  ##    `last_error` is PUBLISHED (`delivery_json/1` → app.js, verbatim), so it is
  ##    clamped to sentences this system is willing to say out loud. It cannot be
  ##    a `validate_inclusion`: `{:http_status, n}` is an unbounded family.

  defp last_error_changeset(value) do
    Delivery.changeset(%Delivery{}, %{
      recipient: "someone@example.com",
      event: "deployment_failed",
      status: "failed",
      last_error: value
    })
  end

  test "a real {:http_status, n} failure reason still validates — the unbounded family survives" do
    for code <- [400, 429, 500, 503] do
      cs = last_error_changeset(DeliveryReason.label({:http_status, code}))
      assert cs.valid?, "HTTP #{code} label was rejected: #{inspect(cs.errors)}"
    end
  end

  test "every constant failure label validates" do
    for class <- DeliveryReason.classes() do
      assert last_error_changeset(DeliveryReason.label(class)).valid?,
             "failure label for #{inspect(class)} was rejected"
    end
  end

  test "every withhold label validates" do
    for reason <- Withhold.reasons() do
      assert last_error_changeset(Withhold.label(reason)).valid?,
             "withhold label for #{inspect(reason)} was rejected"
    end
  end

  test "an arbitrary RAW transport term is REJECTED — the leak this clamp exists to stop" do
    raw =
      "{:retries_exceeded, {:network_failure, ~c\"relay.example.invalid\", {:error, :nxdomain}}}"

    cs = last_error_changeset(raw)

    refute cs.valid?
    assert %{last_error: [_ | _]} = errors_on(cs)

    # ...and a near-miss of the http family does not sneak through.
    refute last_error_changeset("The channel rejected the message (HTTP boom).").valid?
    refute last_error_changeset("timeout").valid?

    # nil is still legitimate — a successful send stores nothing here.
    assert last_error_changeset(nil).valid?
  end
end
