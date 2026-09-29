defmodule BarkparkCloud.Web.RouterBoxRateTenancyTest do
  @moduledoc """
  dr-w10-bl-team-scoped-box-rate — THE PER-BOX RATE IS THE CALLER'S OWN NUMBER.

  `GET /v1/barkparks` has carried a per-box deploy vital since dr-w10-s1: a
  `rate` with its denominator, an `absorption` figure and a `box_caused` share,
  behind `require_user_or_pat` + `require_ability("read")` — a NON-ADMIN read, as
  against `/v1/operator/deploy-ledger/census`, whose `require_platform_operator`
  gate has a production population of zero. That half of this row was already
  standing. This file is the half that was not.

  ## THE HAZARD: A BOX IS A HOST, NOT A TENANT

  `box_rates/4` folds `sites LEFT JOIN deployments` grouped by barkpark. The
  route bounds WHICH boxes it asks about — the caller's own — and until this
  slice that was the only scope in the read. But `sites` carries its OWN
  `team_id` beside `barkpark_id`, so "every site on this box" and "every site of
  mine on this box" are two different populations. Fold before you scope and the
  caller's own box row reports a rate, a SURFACE count and an absorption figure
  computed over a foreign team's deploys — and because the leak arrives as an
  aggregate, not a row, no id in the response ever names the team it came from.
  #18607 tested for exactly this shape one level up, on the per-site census row.

  `create_site/2` derives `team_id` from the `%Barkpark{}` argument today
  (`Map.put`, never `put_new`), so the mixed-tenant box is not reachable through
  the create door. That is a property of ONE function rather than of the schema —
  the column pair exists and `Site.changeset/2` casts both — so these arms PLANT
  the mixed-tenant row directly and assert the fold refuses it on its own,
  without resting on a neighbour's invariant.

  Every arm here is driven from the LOW-privilege side and reads the DECODED HTTP
  RESPONSE, never `box_rates/4`'s return value.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, DeployLedger, Registry, Repo}
  alias BarkparkCloud.Registry.{Deployment, Site}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # The census floor. A rate below it REFUSES, so every arm that wants a real
  # percentage has to clear it and every arm that wants a refusal has to miss it.
  @floor DeployLedger.min_sample()

  defp user_with_owner_team do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{email: "bx-#{n}@example.com", password: @password})
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

  defp site_fixture(bp) do
    n = System.unique_integer([:positive])
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  # A site PHYSICALLY on `bp`'s box, owned by `team`. This is the mixed-tenant
  # row the create door will not mint; it is planted with a direct update so the
  # fold is asked the question on its own terms.
  defp foreign_site_on!(bp, team) do
    site = site_fixture(bp)
    {1, _} = Repo.update_all(from(s in Site, where: s.id == ^site.id), set: [team_id: team.id])
    Repo.get!(Site, site.id)
  end

  defp rows!(site, status, reason, stage, n) do
    at = DateTime.utc_now() |> DateTime.add(-1, :hour)
    at = %{at | microsecond: {elem(at.microsecond, 0), 6}}

    Repo.insert_all(
      Deployment,
      for _ <- 1..n do
        %{
          id: Ecto.UUID.generate(),
          site_id: site.id,
          status: status,
          stage: stage,
          failure_reason: reason,
          environment: "production",
          inserted_at: at,
          updated_at: at
        }
      end
    )
  end

  defp fleet_rows(token) do
    conn = conn(:get, "/v1/barkparks") |> put_req_header("authorization", "Bearer #{token}")
    conn = Router.call(conn, @opts)
    assert conn.status == 200
    conn.resp_body |> Jason.decode!() |> Map.fetch!("barkparks")
  end

  defp node_for(token, bp), do: fleet_rows(token) |> Enum.find(&(&1["id"] == bp.id))

  ## ── The cross-team fold ───────────────────────────────────────────────────

  describe "a foreign team's site on the caller's box" do
    test "contributes nothing to the rate, the surface count or absorption — while the caller's own site on the SAME box still scores" do
      {mine, my_token} = user_with_owner_team()
      {theirs, _their_token} = user_with_owner_team()

      box = barkpark_fixture(mine)
      my_site = site_fixture(box)
      their_site = foreign_site_on!(box, theirs)

      # MINE: 100 failed / 300 live = 25.0% of 400 terminal, over the floor.
      rows!(my_site, "failed", "the instance refused the deploy (HTTP 409)", "PLAN", 100)
      rows!(my_site, "live", nil, "SWITCH", 300)

      # THEIRS, on the same box: a catastrophe. If it enters my fold the rate
      # moves 25.0 -> 62.5 and the sample 400 -> 800, so a leak is loud here by
      # construction; a spot check on `pct` alone would not have to be trusted.
      rows!(their_site, "failed", "the instance refused the deploy (HTTP 409)", "PLAN", 400)

      node = node_for(my_token, box) |> Map.fetch!("deploy_rate")

      # ANTI-VACUITY: the same node that refuses the foreign rows PRODUCES a real
      # percentage for mine. A filter that simply returned nothing would pass a
      # leak assertion and fail this one.
      assert node["rate"]["pct"] == 25.0
      assert node["rate"]["refused"] == false
      assert node["rate"]["sample"] == 400
      assert node["rate"]["numerator"] == 100

      # The SURFACE is a scoped count too. Leaking it would tell me another team
      # exists on my box without ever printing a number of theirs.
      assert node["sites"] == 1
      assert node["sites_deploying"] == 1

      # Absorption shares the denominator, so it leaks by the same door.
      assert node["absorption"]["sample"] == 400
      assert node["box_caused"]["numerator"] == 100
    end

    test "REFUSAL TRACKS THE SAMPLE: a box carrying ONLY a foreign team's 400 rows answers 'could not measure', never a percentage" do
      {mine, my_token} = user_with_owner_team()
      {theirs, _} = user_with_owner_team()

      box = barkpark_fixture(mine)
      their_site = foreign_site_on!(box, theirs)
      rows!(their_site, "failed", "the instance refused the deploy (HTTP 409)", "PLAN", 400)

      node = node_for(my_token, box) |> Map.fetch!("deploy_rate")

      # 400 rows sit on this box and NONE of them are mine. The honest answer is
      # a refusal at sample 0 — not 100%, and not a silent 0.0 either.
      assert node["rate"]["refused"] == true
      assert node["rate"]["pct"] == nil
      assert node["rate"]["sample"] == 0
      assert node["rate"]["sample"] < @floor
      assert is_binary(node["rate"]["reason"])
      assert node["sites"] == 0, "a foreign site is not MY deploy surface"
    end

    test "naming another team's box id buys nothing: the foreign box is absent from the caller's fleet, rate and all" do
      {_mine, my_token} = user_with_owner_team()
      {theirs, _} = user_with_owner_team()

      their_box = barkpark_fixture(theirs)
      their_site = site_fixture(their_box)
      rows!(their_site, "failed", "the instance refused the deploy (HTTP 409)", "PLAN", 400)

      rows = fleet_rows(my_token)
      assert Enum.find(rows, &(&1["id"] == their_box.id)) == nil

      # And the id does not arrive by any other door on this payload either.
      refute String.contains?(Jason.encode!(rows), their_box.id)
    end
  end

  ## ── The unauthenticated case ──────────────────────────────────────────────

  test "an unauthenticated read is 401 and carries no rate key at all" do
    {team, _token} = user_with_owner_team()
    box = barkpark_fixture(team)
    site = site_fixture(box)
    rows!(site, "failed", "the instance refused the deploy (HTTP 409)", "PLAN", 400)

    conn = Router.call(conn(:get, "/v1/barkparks"), @opts)

    assert conn.status == 401
    refute String.contains?(conn.resp_body, "deploy_rate")
    refute String.contains?(conn.resp_body, "absorption")
    refute String.contains?(conn.resp_body, box.id)
  end

  ## ── The node SHAPE, by key-set equality ───────────────────────────────────

  test "every rate node on the box row has the SAME key set as the census's own rate node — not merely the same `pct`" do
    {team, token} = user_with_owner_team()
    box = barkpark_fixture(team)
    site = site_fixture(box)
    rows!(site, "failed", "the instance refused the deploy (HTTP 409)", "PLAN", 100)
    rows!(site, "live", nil, "SWITCH", 300)

    node = node_for(token, box) |> Map.fetch!("deploy_rate")

    to = DateTime.utc_now()
    from = DateTime.add(to, -24, :hour)

    reference =
      DeployLedger.census(from, to, site_ids: [site.id])
      |> Map.fetch!(:terminal_failure_rate)
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    # KEY-SET EQUALITY, not a spot check: a node that quietly dropped
    # `min_sample`, `basis` or `refused` would still answer `pct` correctly and
    # sail past every assertion above. The denominator and the refusal law are
    # the payload here; `pct` is the least of it.
    for key <- ["rate", "absorption", "box_caused"] do
      assert MapSet.new(Map.keys(node[key])) == reference,
             "#{key} diverged from the census rate node: " <>
               inspect(MapSet.symmetric_difference(MapSet.new(Map.keys(node[key])), reference))
    end
  end
end
