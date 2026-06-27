defmodule BarkparkCloud.ProvisioningTest do
  @moduledoc """
  The provision-jobs queue — the bridge between this Elixir control plane and the
  off-box Go warm-pool provisioner.

  Two halves:

    * the Registry context functions — enqueue / claim (race-safe, oldest-first,
      nil-when-empty) / succeed (flips the Barkpark to up at its IP) / fail (the
      Barkpark stays provisioning).
    * the /v1/internal/provision-jobs/* HTTP endpoints — reachable ONLY with the
      shared WORKER token, rejecting user tokens, agent tokens, and no token.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Billing, Registry}
  alias BarkparkCloud.Registry.{Barkpark, ProvisionJob}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @worker_token "worker-token-test-fixed"

  ## Fixtures (mirrors RouterTest)

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })
      |> Accounts.register_user()

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp user_with_team do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  ## Request helpers

  defp call(method, path, body, token) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  ## Context: enqueue / claim / succeed / fail

  describe "enqueue_provision_job/1" do
    test "inserts a pending job for the barkpark" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)

      assert {:ok, %ProvisionJob{} = job} = Registry.enqueue_provision_job(bp)
      assert job.status == "pending"
      assert job.barkpark_id == bp.id
      assert job.claim_token == nil
      assert job.claimed_at == nil
    end
  end

  describe "claim_next_job/1" do
    test "claims the OLDEST pending job and CAS-es it to claimed" do
      {_user, team} = user_with_team()
      bp1 = barkpark_fixture(team, %{slug: "first"})
      bp2 = barkpark_fixture(team, %{slug: "second"})

      {:ok, first} = Registry.enqueue_provision_job(bp1)
      # Force a strictly-later inserted_at so "oldest" is unambiguous.
      _ =
        from(j in ProvisionJob, where: j.id == ^first.id)
        |> Repo.update_all(set: [inserted_at: ~U[2020-01-01 00:00:00.000000Z]])

      {:ok, _second} = Registry.enqueue_provision_job(bp2)

      assert {%ProvisionJob{} = claimed, %Barkpark{} = bp} = Registry.claim_next_job("ct-1")
      assert claimed.id == first.id
      assert claimed.status == "claimed"
      assert claimed.claim_token == "ct-1"
      assert claimed.claimed_at != nil
      assert bp.id == bp1.id
    end

    test "returns nil when no job is pending (the worker's 204 path)" do
      assert Registry.claim_next_job("ct-empty") == nil
    end

    test "an already-claimed job is not re-claimable; the next claim takes the next pending" do
      {_user, team} = user_with_team()
      bp1 = barkpark_fixture(team, %{slug: "a"})
      bp2 = barkpark_fixture(team, %{slug: "b"})
      {:ok, _} = Registry.enqueue_provision_job(bp1)
      {:ok, _} = Registry.enqueue_provision_job(bp2)

      {claimed1, _} = Registry.claim_next_job("ct-a")
      {claimed2, _} = Registry.claim_next_job("ct-b")

      assert claimed1.id != claimed2.id
      # The third claim finds nothing pending.
      assert Registry.claim_next_job("ct-c") == nil
    end

    test "race-safe: N concurrent claimers over N jobs each get a DISTINCT job, none duplicated" do
      {_user, team} = user_with_team()

      # Insert outside the per-test sandbox connection so the spawned tasks can
      # see the rows (shared-mode sandbox; async:true tests still share within
      # the test's own checked-out connection via allowances).
      n = 8

      for i <- 1..n do
        bp = barkpark_fixture(team, %{slug: "race-#{i}"})
        {:ok, _} = Registry.enqueue_provision_job(bp)
      end

      parent = self()

      tasks =
        for i <- 1..n do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())

            case Registry.claim_next_job("ct-race-#{i}") do
              {job, _bp} -> job.id
              nil -> nil
            end
          end)
        end

      claimed_ids = tasks |> Enum.map(&Task.await/1) |> Enum.reject(&is_nil/1)

      # Every claim returned a DISTINCT job id — no double-claim.
      assert length(claimed_ids) == length(Enum.uniq(claimed_ids))
      # And every job ended up claimed exactly once.
      assert Repo.aggregate(from(j in ProvisionJob, where: j.status == "claimed"), :count) == n
      assert Repo.aggregate(from(j in ProvisionJob, where: j.status == "pending"), :count) == 0
    end
  end

  describe "succeed_job/2" do
    test "marks the job succeeded with the ip and flips the barkpark to up at that host" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{health_status: "unknown", agent_status: "offline"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      assert {:ok, %ProvisionJob{} = done} = Registry.succeed_job(job.id, "203.0.113.7")
      assert done.status == "succeeded"
      assert done.result_ip == "203.0.113.7"

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.health_status == "up"
      assert reloaded.host == "203.0.113.7"
      assert reloaded.agent_status == "offline"
    end

    test "unknown id → {:error, :not_found}" do
      assert Registry.succeed_job(Ecto.UUID.generate(), "1.2.3.4") == {:error, :not_found}
    end
  end

  describe "fail_job/2" do
    test "marks the job failed and leaves the barkpark provisioning (health unchanged)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{health_status: "unknown"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      assert {:ok, %ProvisionJob{} = failed} =
               Registry.fail_job(job.id, "hetzner: quota exceeded")

      assert failed.status == "failed"
      assert failed.error == "hetzner: quota exceeded"

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.health_status == "unknown"
      assert reloaded.host == nil
    end

    test "unknown id → {:error, :not_found}" do
      assert Registry.fail_job(Ecto.UUID.generate(), "x") == {:error, :not_found}
    end
  end

  ## go-live enqueues a job

  describe "go-live enqueues a provision job" do
    test "POST /v1/go-live leaves exactly one pending job for the new barkpark" do
      {user, team} = user_with_team()
      # go-live now GATES on an active subscription (the subscription replaced the
      # per-go-live charge) — subscribe the team first so launch is permitted.
      {:ok, _sub} = Billing.subscribe(team, "pro")
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/go-live", %{name: "My Prod", plan: "pro"}, token)
      assert conn.status == 201

      [bp] = Registry.list_barkparks(team)
      jobs = Repo.all(from j in ProvisionJob, where: j.barkpark_id == ^bp.id)
      assert [%ProvisionJob{status: "pending"}] = jobs
    end

    test "POST /v1/launch (the alias) also enqueues" do
      {user, team} = user_with_team()
      {:ok, _sub} = Billing.subscribe(team, "pro")
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/launch", %{provider: "hetzner", name: "Launched"}, token)
      assert conn.status == 201
      assert Repo.aggregate(ProvisionJob, :count) == 1
    end
  end

  ## Internal endpoints — worker auth + behaviour

  describe "POST /v1/internal/provision-jobs/claim" do
    test "worker token + a pending job → 200 {job_id, name, slug, region, server_type}" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{name: "Acme", slug: "acme"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      conn = call(:post, "/v1/internal/provision-jobs/claim", %{}, @worker_token)
      assert conn.status == 200

      body = json_body(conn)
      assert body["job_id"] == job.id
      assert body["name"] == "Acme"
      assert body["slug"] == "acme"
      assert body["region"] == Registry.default_region()
      assert body["server_type"] == Registry.default_server_type()

      # The job is now claimed.
      assert Repo.get(ProvisionJob, job.id).status == "claimed"
    end

    test "worker token + no pending job → 204 (empty body)" do
      conn = call(:post, "/v1/internal/provision-jobs/claim", %{}, @worker_token)
      assert conn.status == 204
      assert conn.resp_body == ""
    end

    test "no token → 401" do
      conn = call(:post, "/v1/internal/provision-jobs/claim", %{}, nil)
      assert conn.status == 401
    end

    test "a USER session token → 401 (never user-reachable)" do
      {user, _team} = user_with_team()
      {:ok, user_token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/internal/provision-jobs/claim", %{}, user_token)
      assert conn.status == 401
    end

    test "an AGENT token → 401 (never agent-reachable)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, agent_token, _} = Registry.mint_agent_token(bp, "report")

      conn = call(:post, "/v1/internal/provision-jobs/claim", %{}, agent_token)
      assert conn.status == 401
    end
  end

  describe "POST /v1/internal/provision-jobs/:id/succeed" do
    test "worker token + {ip} → 200 ok, job succeeded, barkpark up at ip" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/succeed",
          %{ip: "198.51.100.9"},
          @worker_token
        )

      assert conn.status == 200
      assert json_body(conn)["ok"] == true

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.health_status == "up"
      assert reloaded.host == "198.51.100.9"
    end

    test "missing ip → 422" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      conn = call(:post, "/v1/internal/provision-jobs/#{job.id}/succeed", %{}, @worker_token)
      assert conn.status == 422
    end

    test "unknown job id → 404" do
      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{Ecto.UUID.generate()}/succeed",
          %{ip: "1.2.3.4"},
          @worker_token
        )

      assert conn.status == 404
    end

    test "a USER token → 401" do
      {user, _team} = user_with_team()
      {:ok, user_token} = Accounts.create_user_session_token(user)

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{Ecto.UUID.generate()}/succeed",
          %{ip: "1.2.3.4"},
          user_token
        )

      assert conn.status == 401
    end
  end

  describe "POST /v1/internal/provision-jobs/:id/fail" do
    test "worker token + {error} → 200 ok, job failed, barkpark stays provisioning" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{health_status: "unknown"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      conn =
        call(:post, "/v1/internal/provision-jobs/#{job.id}/fail", %{error: "boom"}, @worker_token)

      assert conn.status == 200
      assert json_body(conn)["ok"] == true

      assert Repo.get(ProvisionJob, job.id).status == "failed"
      assert Registry.get_barkpark(bp.id).health_status == "unknown"
    end

    test "unknown job id → 404" do
      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{Ecto.UUID.generate()}/fail",
          %{error: "x"},
          @worker_token
        )

      assert conn.status == 404
    end

    test "an AGENT token → 401" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, agent_token, _} = Registry.mint_agent_token(bp, "report")

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{Ecto.UUID.generate()}/fail",
          %{error: "x"},
          agent_token
        )

      assert conn.status == 401
    end

    test "no token → 401" do
      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{Ecto.UUID.generate()}/fail",
          %{error: "x"},
          nil
        )

      assert conn.status == 401
    end
  end
end
