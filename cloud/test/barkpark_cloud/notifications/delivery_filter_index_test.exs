defmodule BarkparkCloud.Notifications.DeliveryFilterIndexTest do
  @moduledoc """
  cch-w32-bl — the empty/rare-filter cliff on the delivery log, and the three
  indexes that close it.

  ## Why this file asserts the DATABASE and not a duration

  The defect is a QUERY PLAN, and no behavioural assertion can see one: an empty
  `?status=bogus` returns `[]` before the fix and `[]` after it, in the same
  handful of microseconds, because a test database holds a handful of rows. The
  cliff only exists at scale — measured at 1153 shared buffers with
  `Rows Removed by Filter: 50000` on a seeded 250k-row corpus, one 50k-row hot
  team (the numbers, all seven cases, are in
  `priv/repo/migrations/20260918110000_index_notification_delivery_filter_axes.exs`).

  So §1 reads the index definitions back out of `pg_indexes` — the migration
  either ran or it did not — and asserts the COLUMN LIST, not the index NAME. An
  index merely named `…_status_inserted_at_index` over the wrong columns passes
  a name check and still falls off the cliff; `platform_delivery_test.exs`
  measured that weaker assertion staying green against a real key mutation.

  §2 is the CONTROL half, and it must stay QUIET. The fix is an index and
  nothing else: no vocabulary gate was added, so an in-vocabulary filter must
  still return its rows, an in-vocabulary filter with nothing to match must
  still read as EMPTY rather than as an error, and an out-of-vocabulary value
  must still be matched LITERALLY — returning nothing rather than being dropped,
  which would widen the result set behind the caller's back. Those three are the
  properties a "fix" that reached for a 4xx gate would have broken, and they
  would have shipped invisible to §1.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.Delivery

  @axes ~w(status event channel)

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp delivery!(team, attrs) do
    %Delivery{}
    |> Delivery.changeset(
      Map.merge(
        %{
          team_id: team.id,
          recipient: "member@example.com",
          event: "deploy.failed",
          channel: "email",
          status: "sent"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp index_columns(name) do
    case Repo.query!("SELECT indexdef FROM pg_indexes WHERE indexname = $1", [name]) do
      %{rows: [[indexdef]]} ->
        case Regex.run(~r/USING btree \(([^)]+)\)/, indexdef) do
          [_, columns] -> columns |> String.split(", ") |> Enum.map(&String.trim/1)
          nil -> {:unparsed, indexdef}
        end

      %{rows: []} ->
        :missing
    end
  end

  describe "§1 the three filter axes are indexed in the DATABASE" do
    test "each axis has a (team_id, <axis>, inserted_at) index, by COLUMN LIST" do
      for axis <- @axes do
        name = "notification_deliveries_team_id_#{axis}_inserted_at_index"

        assert index_columns(name) == ["team_id", axis, "inserted_at"],
               """
               #{name} does not cover (team_id, #{axis}, inserted_at).

               Read back: #{inspect(index_columns(name))}

               Without it, `list_deliveries/2` filtered on `#{axis}` to an EMPTY or
               RARE result never fills its LIMIT, so the planner abandons
               (team_id, inserted_at) and bitmap-scans the team's WHOLE partition:
               1153 shared buffers and `Rows Removed by Filter: 50000` to return
               zero rows, measured on a 250k-row corpus.
               """
      end
    end

    test "the index leads with team_id, because the tenant fence must bound the read" do
      # An index keyed (status, team_id, …) would serve the same filter and
      # scan across TEAMS to do it. The leading column is the property, and it
      # is not visible in the index name.
      for axis <- @axes do
        assert [leading | _] =
                 index_columns("notification_deliveries_team_id_#{axis}_inserted_at_index")

        assert leading == "team_id"
      end
    end
  end

  describe "§2 CONTROL — the read contract is unchanged by the index" do
    test "an IN-vocabulary filter still returns its rows" do
      team = team_fixture()
      delivery!(team, %{status: "failed", event: "deploy.failed", channel: "email"})
      delivery!(team, %{status: "sent", event: "deploy.succeeded", channel: "discord"})

      assert [%Delivery{status: "failed"}] = Notifications.list_deliveries(team, status: "failed")

      assert [%Delivery{event: "deploy.succeeded"}] =
               Notifications.list_deliveries(team, event: "deploy.succeeded")

      assert [%Delivery{channel: "discord"}] =
               Notifications.list_deliveries(team, channel: "discord")
    end

    test "an IN-vocabulary filter with nothing to match reads as EMPTY, not as an error" do
      team = team_fixture()
      delivery!(team, %{status: "sent"})

      # `suppressed` is a real member of Delivery's status vocabulary; this team
      # simply has none. That must be an empty page, never a raise and never a
      # widened one.
      assert [] = Notifications.list_deliveries(team, status: "suppressed")
      assert [] = Notifications.list_deliveries(team, channel: "telegram")
    end

    test "an OUT-of-vocabulary filter is matched LITERALLY — nothing, never everything" do
      team = team_fixture()
      delivery!(team, %{status: "sent"})

      # No gate was added and none is wanted: dropping an unrecognised filter
      # would hand the caller MORE than they asked for, which is the one failure
      # mode a delivery log must not have.
      assert [] = Notifications.list_deliveries(team, status: "bogus")
      assert [] = Notifications.list_deliveries(team, event: "no.such.event")
      assert [] = Notifications.list_deliveries(team, channel: "carrier-pigeon")

      # …and the unfiltered read of the same team still sees the row, so the
      # emptiness above is the FILTER's, not an accidentally broken fixture.
      assert [%Delivery{status: "sent"}] = Notifications.list_deliveries(team)
    end
  end
end
