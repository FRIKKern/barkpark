defmodule BarkparkCloud.Web.RouterSiteDeployCapabilityTest do
  @moduledoc """
  dr-w15-s5 — "CAN THIS BOX DEPLOY SITES" REACHES THE FLEET ROW.

  `merge_capability/2` reads the agent's `site_deploy` record off the latest
  health beat's RAW jsonb — the same beat `merge_pressure/2` reads — so the
  whole transport is POST /v1/agent/report → `Registry.record_event/3` → GET
  /v1/barkparks, with no column and no migration. This file asserts the DECODED
  HTTP RESPONSE and nothing else.

  THE LAW UNDER TEST: only a real JSON boolean survives. An absent record (an
  agent predating the field, or a probe that 404ed on an instance predating
  dr-w15-s1 — the agent sends NOTHING then), an absent inner key, a null, and a
  non-boolean ALL render nil — UNMEASURED — and NEVER `false`, because
  `configured: false` is the box's own refusal and fabricating it for a box
  nobody measured is the lie this slice exists to prevent. The control arm (a
  REAL false) proves the nil arms are not simply a serializer that drops every
  false on the floor.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  defp user_with_owner_team do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{email: "sd-#{n}@example.com", password: @password})
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

  defp beat!(bp, payload) do
    {:ok, _} = Registry.record_event(bp, "health", Map.merge(%{"cpu_percent" => 12.5}, payload))
    :ok
  end

  defp fleet_row(token, bp) do
    conn = conn(:get, "/v1/barkparks") |> put_req_header("authorization", "Bearer #{token}")
    conn = Router.call(conn, @opts)
    assert conn.status == 200

    conn.resp_body
    |> Jason.decode!()
    |> Map.fetch!("barkparks")
    |> Enum.find(&(&1["id"] == bp.id))
  end

  # PRECONDITION for every nil arm below: the beat really was read. Without it a
  # nil could come from the never-beaten sentinel and the test would pass over a
  # merge_capability/2 that never ran.
  defp assert_beat_was_read!(row) do
    assert row["pressure"]["cpu_percent"] == 12.5,
           "precondition: the seeded beat must be the one the row read"

    assert row["site_deploy"]["reported_at"],
           "precondition: the capability block must carry the beat's own timestamp"
  end

  describe "GET /v1/barkparks carries site_deploy" do
    test "a measured capable box serializes both booleans as true" do
      {team, token} = user_with_owner_team()
      bp = barkpark_fixture(team)
      beat!(bp, %{"site_deploy" => %{"configured" => true, "runner_alive" => true}})

      row = fleet_row(token, bp)
      assert_beat_was_read!(row)
      assert row["site_deploy"]["configured"] == true
      assert row["site_deploy"]["runner_alive"] == true
    end

    test "CONTROL: a REAL false from the box survives as false" do
      {team, token} = user_with_owner_team()
      bp = barkpark_fixture(team)
      beat!(bp, %{"site_deploy" => %{"configured" => false, "runner_alive" => false}})

      node = fleet_row(token, bp)["site_deploy"]
      assert node["configured"] === false
      assert node["runner_alive"] === false
    end

    test "an ABSENT site_deploy key (agent or instance predates the probe) is nil, NEVER false" do
      {team, token} = user_with_owner_team()
      bp = barkpark_fixture(team)
      beat!(bp, %{})

      row = fleet_row(token, bp)
      assert_beat_was_read!(row)
      assert Map.has_key?(row["site_deploy"], "configured")
      assert Map.has_key?(row["site_deploy"], "runner_alive")
      assert row["site_deploy"]["configured"] === nil
      assert row["site_deploy"]["runner_alive"] === nil
    end

    test "a half record keeps the stated half and leaves the unstated half nil" do
      {team, token} = user_with_owner_team()
      bp = barkpark_fixture(team)
      beat!(bp, %{"site_deploy" => %{"configured" => true}})

      row = fleet_row(token, bp)
      assert_beat_was_read!(row)
      assert row["site_deploy"]["configured"] == true
      assert row["site_deploy"]["runner_alive"] === nil
    end

    test "non-boolean garbage is UNMEASURED: a string \"false\", a 0, a null, a non-map record" do
      {team, token} = user_with_owner_team()

      for record <- [
            %{"configured" => "false", "runner_alive" => 0},
            %{"configured" => nil, "runner_alive" => nil},
            "false",
            false,
            nil
          ] do
        bp = barkpark_fixture(team)
        beat!(bp, %{"site_deploy" => record})

        row = fleet_row(token, bp)
        assert_beat_was_read!(row)

        assert row["site_deploy"]["configured"] === nil,
               "#{inspect(record)} must read UNMEASURED, got #{inspect(row["site_deploy"])}"

        assert row["site_deploy"]["runner_alive"] === nil
      end
    end

    test "a box that has NEVER beaten carries the all-nil sentinel, key present" do
      {team, token} = user_with_owner_team()
      bp = barkpark_fixture(team)

      row = fleet_row(token, bp)

      assert row["site_deploy"] == %{
               "configured" => nil,
               "runner_alive" => nil,
               "reported_at" => nil
             }
    end

    test "END TO END: what the agent POSTs to /v1/agent/report is what the fleet row serves" do
      {team, token} = user_with_owner_team()
      bp = barkpark_fixture(team)
      {:ok, agent, _} = Registry.mint_agent_token(bp, "report")

      body = %{
        "health_status" => "up",
        "agent_status" => "online",
        "cpu_percent" => 12.5,
        "site_deploy" => %{"configured" => false, "runner_alive" => true}
      }

      post =
        conn(:post, "/v1/agent/report", Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{agent}")
        |> Router.call(@opts)

      assert post.status in 200..299

      row = fleet_row(token, bp)
      assert_beat_was_read!(row)
      assert row["site_deploy"]["configured"] === false
      assert row["site_deploy"]["runner_alive"] === true
    end
  end
end
