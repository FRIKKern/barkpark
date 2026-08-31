defmodule BarkparkCloud.Web.FleetListEnableApplyReproTest do
  @moduledoc """
  PROD-500 repro harness (2026-08-31): after the enable-apply deploy
  (bbcf1d95d), GET /v1/barkparks returns 500 in production while single-box
  reads stay 200. This test recreates the post-sweep data shape — boxes with
  arming columns stamped, enable_apply job rows in pending/claimed/failed
  states — and asserts the fleet list renders. If this stays green, the prod
  crash is data the test DB does not model, and diagnosis moves elsewhere.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.{Barkpark, ProvisionJob}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  defp fixture do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{email: "u#{n}@example.com", password: "correct-horse-battery"})
    {:ok, team} = Accounts.create_team(%{name: "T#{n}", slug: "t-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "admin")
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, team, token}
  end

  defp box(team, attrs) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "B#{n}", slug: "b-#{n}"})
    bp |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  test "fleet list renders with enable_apply jobs in every state + stamped arming columns" do
    {_user, team, token} = fixture()

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    unarmed =
      box(team, %{
        host: "203.0.113.10",
        health_status: "up",
        apply_arming: "unarmed",
        apply_arming_checked_at: now,
        update_state: "behind",
        update_running_release: "0.2.25",
        update_latest_release: "0.2.26"
      })

    degraded =
      box(team, %{
        host: "203.0.113.11",
        health_status: "down",
        apply_arming: "unarmed",
        apply_arming_checked_at: now,
        update_state: "behind"
      })

    current = box(team, %{host: "203.0.113.12", health_status: "up", update_state: "current"})

    # pending job (fresh sweep enqueue)
    {:ok, _p} = Registry.enqueue_enable_apply_job(unarmed)

    # claimed job (worker mid-flight)
    {:ok, c} = Registry.enqueue_enable_apply_job(degraded)
    c |> Ecto.Changeset.change(status: "claimed", claim_token: "tok-x", claimed_at: now, attempts: 1) |> Repo.update!()

    # failed job (SSH refused)
    %ProvisionJob{}
    |> ProvisionJob.changeset(%{barkpark_id: current.id, kind: "enable_apply", status: "failed", error: "ssh: connect refused"})
    |> Repo.insert!()

    conn =
      conn(:get, "/v1/barkparks")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Router.call(@opts)

    assert conn.status == 200, "fleet list crashed: #{conn.resp_body |> String.slice(0, 500)}"
    body = Jason.decode!(conn.resp_body)
    assert length(body["barkparks"]) == 3

    # scope=all variant crashes identically in prod — cover it too
    conn2 =
      conn(:get, "/v1/barkparks?scope=all")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Router.call(@opts)

    assert conn2.status == 200, "scope=all crashed: #{conn2.resp_body |> String.slice(0, 500)}"
  end
end
