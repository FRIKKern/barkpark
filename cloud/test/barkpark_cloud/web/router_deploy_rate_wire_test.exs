defmodule BarkparkCloud.Web.RouterDeployRateWireTest do
  @moduledoc """
  dr-w10-s1 — THE DEPLOY VITAL REACHES THE WIRE.

  Charter D136: the server key, the Go field and the rendered column land in
  ONE PR, because a vital that lands server-side alone is a vital nothing reads
  — which is this epic's own bug. `deploy_ledger_box_rates_test.exs` asserts the
  READ; this file asserts the ROUTE, and it reads the DECODED HTTP RESPONSE and
  nothing else. A test that calls `box_rates/3` and then believes the row is
  serialized reproduces exactly the blindness being fixed.

  THE KEY IS ALWAYS PRESENT. `merge_deploy_rate/2` mirrors `merge_pressure/2`:
  a measured clause and an all-nil SENTINEL clause, so a consumer branches on
  the VALUES and never on the key's existence. The sentinel says `sites: 0` —
  "nothing to deploy", which is a DIFFERENT fact from "has sites, could not
  score" and from "an older control plane never sent it". Three facts, three
  renderings, asserted here so they cannot collapse into each other.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  defp user_with_owner_team do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{email: "dr-#{n}@example.com", password: @password})
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

  # Rows are inserted INSIDE the route's own 24h window, which the handler pins
  # per request. `usec` widening is required — `timestamps(type: :utc_datetime_usec)`.
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

  describe "GET /v1/barkparks carries deploy_rate" do
    test "a measured box serializes the rate WITH its denominator, its window and its companions" do
      {team, token} = user_with_owner_team()
      sick = barkpark_fixture(team)
      site = site_fixture(sick)

      # 250 box-refused failures, 250 live → 50.0% of 500 terminal, over the
      # census floor of 200. The recorded guerrilla SHAPE, at the floor.
      rows!(site, "failed", "the instance refused the deploy (HTTP 409)", "PLAN", 250)
      rows!(site, "live", nil, "SWITCH", 250)

      row = fleet_rows(token) |> Enum.find(&(&1["id"] == sick.id))
      node = row["deploy_rate"]

      assert node, "the fleet row must always carry the key — a consumer branches on VALUES"
      assert node["sites"] == 1
      assert node["sites_deploying"] == 1
      assert node["rate"]["sample"] == 500
      assert node["rate"]["numerator"] == 250
      assert node["rate"]["pct"] == 50.0
      assert node["rate"]["refused"] == false
      assert node["rate"]["min_sample"] == 200

      # The window travels WITH the number: a rate on a row that does not carry
      # its window is a number with no population.
      assert node["window"]["from"]
      assert node["window"]["to"]

      # The companions are INSEPARABLE from the rate (D107/D152), so no consumer
      # can print the accusation without the price of a raw rate beside it.
      assert node["absorption"]["sample"] == 500
      assert node["box_caused"]["numerator"] == 250
    end

    test "a box with NO SITES gets the all-nil sentinel, not a measured zero" do
      {team, token} = user_with_owner_team()
      bare = barkpark_fixture(team)

      node = fleet_rows(token) |> Enum.find(&(&1["id"] == bare.id)) |> Map.fetch!("deploy_rate")

      assert node["sites"] == 0
      assert node["sites_deploying"] == 0
      assert node["window"] == nil

      # `sites: 0` is what separates "nothing to deploy" from "measured, fine".
      # The sentinel's rate is a REFUSAL and never a 0.0 percentage — a box with
      # nothing to deploy has a perfect record only in the sense that it has no
      # record at all.
      assert node["rate"]["refused"] == true
      assert node["rate"]["pct"] == nil
    end

    test "a box WITH sites and too few rows refuses — a silence, never a green" do
      {team, token} = user_with_owner_team()
      quiet = barkpark_fixture(team)
      site = site_fixture(quiet)
      rows!(site, "failed", "the instance refused the deploy (HTTP 409)", "PLAN", 10)

      node = fleet_rows(token) |> Enum.find(&(&1["id"] == quiet.id)) |> Map.fetch!("deploy_rate")

      assert node["sites"] == 1, "the SURFACE is counted from sites, not from rows"
      assert node["rate"]["refused"] == true
      assert node["rate"]["pct"] == nil
      assert node["rate"]["sample"] == 10
      assert is_binary(node["rate"]["reason"])
    end
  end
end
