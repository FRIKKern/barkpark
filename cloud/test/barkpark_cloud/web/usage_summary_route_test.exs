defmodule BarkparkCloud.Web.UsageSummaryRouteTest do
  @moduledoc """
  GET /v1/usage/summary (cloud-console wave 3 — the Overview fleet meter strip).
  Proves it is a PURE cached read:

    * ZERO instance HTTP on the request path — the fake transport is programmed
      to blow up on any call, and the summary still returns 200 (it reads only
      the cached `usage_samples` rows + a cheap control-plane count)
    * per-instance `measured_at` + the full 9-name meter set from the LATEST
      cached sample; the newest row wins when several exist
    * a never-sampled checkable instance serves the honest all-"unmetered"
      envelope with `measured_at: nil`
    * only THIS team's checkable instances appear (host set, not suspended);
      a hostless / suspended box never shows, another team's box never shows
    * the `team.instances` fleet-quota meter is LIVE (OC11 rules): nil quota with
      no subscription, the plan ceiling with one
    * auth: 401 unauthenticated; 404 for a session with no team
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo, Usage}
  alias BarkparkCloud.Billing.Subscription
  alias BarkparkCloud.StudioLinkFakeHttpClient, as: Fake
  alias BarkparkCloud.Usage.Sample
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  ## Fixtures

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp user_with_team(role \\ "owner") do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, role)
    {user, team}
  end

  # A checkable instance: host set, not suspended.
  defp checkable_instance(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(Enum.into(attrs, %{host: "203.0.113.#{rem(n, 250) + 1}"}))
    |> Repo.update!()
  end

  defp seed_sample(bp, envelope, measured_at) do
    {:ok, sample} =
      %Sample{}
      |> Sample.changeset(%{barkpark_id: bp.id, envelope: envelope, measured_at: measured_at})
      |> Repo.insert()

    sample
  end

  defp subscribe(team, plan) do
    {:ok, sub} =
      %Subscription{}
      |> Subscription.changeset(%{team_id: team.id, plan: plan, status: "active"})
      |> Repo.insert()

    sub
  end

  defp session_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, opts \\ []) do
    token = Keyword.get(opts, :token)
    conn = conn(method, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp summary(conn), do: Jason.decode!(conn.resp_body)["usage"]

  # A fake programmed to blow up on ANY request — proving the summary NEVER
  # reaches across to an instance.
  defp forbid_instance_http do
    Fake.program(%{"/__any__" => {:error, {:http_client, :should_never_be_called}}})
  end

  @meter_names ~w(documents datasets webhooks db_size disk seats instances api_requests bandwidth)

  describe "the cached fleet read — ZERO instance HTTP" do
    test "returns the latest sample's meters + measured_at per checkable instance" do
      {user, team} = user_with_team()
      bp = checkable_instance(team)
      forbid_instance_http()

      old_at = ~U[2026-07-10 09:00:00.000000Z]
      new_at = ~U[2026-07-10 10:00:00.000000Z]
      # An older + newer sample — the newest wins.
      seed_sample(bp, Usage.compose(%{seats: 1, documents: {:ok, 5}}), old_at)
      seed_sample(bp, Usage.compose(%{seats: 4, documents: {:ok, 42}}), new_at)

      conn = call(:get, "/v1/usage/summary", token: session_token(user))

      assert conn.status == 200
      s = summary(conn)

      assert [inst] = s["instances"]
      assert inst["id"] == bp.id
      assert inst["name"] == bp.name
      assert inst["slug"] == bp.slug
      assert inst["host"] == bp.host
      # Newest sample wins.
      assert inst["measured_at"] == "2026-07-10T10:00:00.000000Z"
      assert inst["meters"]["documents"]["value"] == 42
      assert inst["meters"]["seats"]["value"] == 4

      # The full 9-name meter set is present (OC12 vocabulary).
      assert Enum.sort(Map.keys(inst["meters"])) == Enum.sort(@meter_names)

      # NOT ONE instance HTTP call was made — the fake would have errored the whole
      # request had it been reached.
      assert Fake.requests() == []
    end

    test "a never-sampled checkable instance serves the honest unmetered envelope, measured_at nil" do
      {user, team} = user_with_team()
      bp = checkable_instance(team)
      forbid_instance_http()

      conn = call(:get, "/v1/usage/summary", token: session_token(user))

      assert conn.status == 200
      assert [inst] = summary(conn)["instances"]
      assert inst["id"] == bp.id
      assert inst["measured_at"] == nil
      # Every meter is present and honestly degraded, never a fake zero.
      assert Enum.sort(Map.keys(inst["meters"])) == Enum.sort(@meter_names)
      assert inst["meters"]["documents"]["value"] == "unmetered"
      assert inst["meters"]["seats"]["value"] == "unmetered"
      assert Fake.requests() == []
    end

    test "several instances each carry their OWN latest sample" do
      {user, team} = user_with_team()
      a = checkable_instance(team)
      b = checkable_instance(team)
      forbid_instance_http()

      at = ~U[2026-07-10 10:00:00.000000Z]
      seed_sample(a, Usage.compose(%{documents: {:ok, 10}}), at)
      seed_sample(b, Usage.compose(%{documents: {:ok, 20}}), at)

      conn = call(:get, "/v1/usage/summary", token: session_token(user))
      by_id = Map.new(summary(conn)["instances"], &{&1["id"], &1})

      assert by_id[a.id]["meters"]["documents"]["value"] == 10
      assert by_id[b.id]["meters"]["documents"]["value"] == 20
    end
  end

  describe "team scoping — only this team's checkable instances" do
    test "a hostless / suspended box never appears; another team's box never appears" do
      {user, team} = user_with_team()
      shown = checkable_instance(team)
      # Same team, but NOT checkable: no host (still provisioning) and suspended.
      _hostless = checkable_instance(team, %{host: nil})
      _suspended = checkable_instance(team, %{suspended: true})

      # A different team's checkable instance.
      {_other_user, other_team} = user_with_team()
      _other = checkable_instance(other_team)

      forbid_instance_http()
      conn = call(:get, "/v1/usage/summary", token: session_token(user))

      ids = Enum.map(summary(conn)["instances"], & &1["id"])
      assert ids == [shown.id]
    end
  end

  describe "team.instances — the LIVE fleet-quota meter (OC11)" do
    test "no subscription → live count, quota nil" do
      {user, team} = user_with_team()
      _bp = checkable_instance(team)
      forbid_instance_http()

      conn = call(:get, "/v1/usage/summary", token: session_token(user))
      meter = summary(conn)["team"]["instances"]

      assert meter["value"] == 1
      assert meter["quota"] == nil
      assert meter["warn_at"] == nil
      assert meter["source"] == "control-plane.team_instances"
      assert meter["measured_at"] == nil
    end

    test "an active subscription → the plan ceiling with warn_at derived" do
      {user, team} = user_with_team()
      subscribe(team, "supporter")
      _bp = checkable_instance(team)
      forbid_instance_http()

      conn = call(:get, "/v1/usage/summary", token: session_token(user))
      meter = summary(conn)["team"]["instances"]

      assert meter["value"] == 1
      assert meter["quota"] == 3
      assert meter["warn_at"] == 2
    end
  end

  describe "auth" do
    test "no auth → 401" do
      conn = call(:get, "/v1/usage/summary")
      assert conn.status == 401
    end

    test "a user with no team → 404" do
      user = user_fixture()
      conn = call(:get, "/v1/usage/summary", token: session_token(user))
      assert conn.status == 404
    end
  end
end
