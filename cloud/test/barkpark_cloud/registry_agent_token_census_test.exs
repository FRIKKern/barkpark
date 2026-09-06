defmodule BarkparkCloud.RegistryAgentTokenCensusTest do
  @moduledoc """
  THE DISARMED-BOX CENSUS — `Registry.barkparks_without_live_agent_token/0`
  (task-5cc3689cb0ab6637), the companion read to the mass-revoke fix that
  removed `revoke_all_agent_tokens_for_user/1`.

  The defect this closes is an OBSERVABILITY one: a box whose agent token was
  revoked looks healthy in every other projection (row intact, `suspended`
  false, `autoupdate_enabled` true) and its only symptom is `agent_status`
  drifting to "offline" via `StalenessWorker` — which is exactly what a box
  that is genuinely DOWN looks like. Nothing anywhere separated the two.

  FOUR SHAPES, and the census must get all four right:

    * NEVER MINTED  — zero token rows            → APPEARS (never armed)
    * LIVE          — unrevoked, unexpired       → ABSENT
    * REVOKED       — `revoked_at` stamped       → APPEARS (disarmed)
    * EXPIRED       — unrevoked, `expires_at` past → APPEARS (dark all the same)

  plus the MIXED box — one revoked AND one live — which must NOT appear, because
  a per-token read ("does this box have a revoked token?") answers the wrong
  question and would put every healthy re-provisioned box on the worklist.

  Liveness here is deliberately the same predicate `verify_agent_token/1`
  applies. An expired-but-unrevoked token opens no route, so a box holding only
  one is dark; counting it as live would hide the box.

  SCOPING NOTE: the query is fleet-wide by construction (it is a cross-team
  operator census), so every assertion here restricts the result to THIS test's
  own fixture slugs before comparing. That keeps the assertions exact about the
  population under test without asserting anything about rows this test did not
  create.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry}

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team, slug) do
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{slug}", slug: slug})
    bp
  end

  # A unique slug prefix per test, so "restrict to my own fixtures" is exact.
  defp prefix, do: "census-#{System.unique_integer([:positive])}"

  defp census_slugs(prefix) do
    Registry.barkparks_without_live_agent_token()
    |> Enum.map(& &1.slug)
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.sort()
  end

  defp census_row(slug) do
    Enum.find(Registry.barkparks_without_live_agent_token(), &(&1.slug == slug))
  end

  defp past,
    do: DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)

  describe "the four shapes" do
    test "never minted / revoked / expired APPEAR; live is ABSENT" do
      p = prefix()
      team = team_fixture()

      _never = barkpark_fixture(team, "#{p}-never")

      live = barkpark_fixture(team, "#{p}-live")
      {:ok, _pt, _t} = Registry.mint_agent_token(live, "report:health")

      revoked = barkpark_fixture(team, "#{p}-revoked")
      {:ok, pt, _t} = Registry.mint_agent_token(revoked, "report:health")
      {:ok, _} = Registry.revoke_agent_token(pt)

      expired = barkpark_fixture(team, "#{p}-expired")
      {:ok, _pt, _t} = Registry.mint_agent_token(expired, "report:health", expires_at: past())

      assert census_slugs(p) == ["#{p}-expired", "#{p}-never", "#{p}-revoked"]
    end

    test "an EXPIRED but never-revoked token counts as NOT live" do
      p = prefix()
      team = team_fixture()
      bp = barkpark_fixture(team, "#{p}-expired-only")
      {:ok, _pt, token} = Registry.mint_agent_token(bp, "report:health", expires_at: past())

      # The shape is real: the row is present and its revoked_at is nil, so
      # only the expiry arm can be what puts this box on the census.
      assert is_nil(token.revoked_at)
      refute is_nil(token.expires_at)

      # And it IS dark by the one predicate that matters at the door.
      row = census_row("#{p}-expired-only")
      assert row, "an expired-only box must appear on the disarmed census"
      assert row.token_count == 1
      assert row.revoked_token_count == 0
      assert is_nil(row.last_revoked_at)
    end

    test "a LIVE token with a FUTURE expiry keeps the box off the census" do
      p = prefix()
      team = team_fixture()
      bp = barkpark_fixture(team, "#{p}-future")

      future =
        DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:microsecond)

      {:ok, _pt, _t} = Registry.mint_agent_token(bp, "report:health", expires_at: future)

      assert census_slugs(p) == []
    end
  end

  describe "the mixed box — the false-positive this census must not manufacture" do
    test "a box with ONE revoked AND ONE live token does NOT appear" do
      p = prefix()
      team = team_fixture()
      bp = barkpark_fixture(team, "#{p}-mixed")

      # mint_agent_token/3 revokes the box's prior same-scope live token, so a
      # second mint produces exactly the mixed shape: one revoked row, one live.
      {:ok, _pt1, _t1} = Registry.mint_agent_token(bp, "report:health")
      {:ok, _pt2, _t2} = Registry.mint_agent_token(bp, "report:health")

      assert census_slugs(p) == []
    end

    test "revoking the SURVIVING token of a re-provisioned box puts it back on" do
      p = prefix()
      team = team_fixture()
      bp = barkpark_fixture(team, "#{p}-relapse")

      {:ok, _pt1, _t1} = Registry.mint_agent_token(bp, "report:health")
      {:ok, pt2, _t2} = Registry.mint_agent_token(bp, "report:health")
      assert census_slugs(p) == []

      {:ok, _} = Registry.revoke_agent_token(pt2)

      assert census_slugs(p) == ["#{p}-relapse"]
      row = census_row("#{p}-relapse")
      assert row.token_count == 2
      assert row.revoked_token_count == 2
    end
  end

  describe "the row carries what an operator needs to act" do
    test "DISARMED is distinguishable from NEVER ARMED" do
      p = prefix()
      team = team_fixture()

      never = barkpark_fixture(team, "#{p}-a-never")
      disarmed = barkpark_fixture(team, "#{p}-b-disarmed")
      {:ok, pt, _t} = Registry.mint_agent_token(disarmed, "report:health")
      {:ok, revoked_token} = Registry.revoke_agent_token(pt)

      never_row = census_row(never.slug)
      assert never_row.token_count == 0
      assert never_row.revoked_token_count == 0

      assert is_nil(never_row.last_revoked_at),
             "a never-armed box must carry NO last_revoked_at — that absence IS the signal"

      disarmed_row = census_row(disarmed.slug)
      assert disarmed_row.token_count == 1
      assert disarmed_row.revoked_token_count == 1
      assert DateTime.compare(disarmed_row.last_revoked_at, revoked_token.revoked_at) == :eq
    end

    test "the row carries the operator's triage fields, not just an id" do
      p = prefix()
      team = team_fixture()
      bp = barkpark_fixture(team, "#{p}-fields")

      row = census_row(bp.slug)

      assert row.id == bp.id
      assert row.name == bp.name
      assert row.team_id == team.id
      assert row.agent_status == bp.agent_status
      assert row.suspended == false

      assert MapSet.subset?(
               MapSet.new([
                 :id,
                 :slug,
                 :name,
                 :team_id,
                 :agent_status,
                 :suspended,
                 :last_seen_at,
                 :token_count,
                 :revoked_token_count,
                 :last_revoked_at
               ]),
               MapSet.new(Map.keys(row))
             )
    end
  end
end
