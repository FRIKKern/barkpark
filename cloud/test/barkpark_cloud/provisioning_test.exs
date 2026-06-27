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

    test "a STALE claimed job IS re-claimable past the staleness threshold" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      # First claim → claimed, attempts bumped to 1.
      {claimed, _} = Registry.claim_next_job("ct-1")
      assert claimed.status == "claimed"
      assert claimed.attempts == 1

      # Age the claim well past the staleness threshold (simulating a worker that
      # crashed / whose report failed in transit and left the row "claimed").
      stale_at =
        DateTime.utc_now()
        |> DateTime.add(-(Registry.stale_after_seconds() + 60), :second)
        |> DateTime.truncate(:microsecond)

      _ =
        from(j in ProvisionJob, where: j.id == ^job.id)
        |> Repo.update_all(set: [claimed_at: stale_at])

      # A fresh claim re-picks the stale job, bumps attempts, and resets claimed_at.
      assert {%ProvisionJob{} = reclaimed, %Barkpark{}} = Registry.claim_next_job("ct-2")
      assert reclaimed.id == job.id
      assert reclaimed.status == "claimed"
      assert reclaimed.claim_token == "ct-2"
      assert reclaimed.attempts == 2
      assert DateTime.compare(reclaimed.claimed_at, stale_at) == :gt
    end

    test "a FRESH claimed job is NOT re-claimable (a live worker is never raced)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, _job} = Registry.enqueue_provision_job(bp)

      # Claim it; claimed_at is now (well within the staleness threshold).
      {claimed, _} = Registry.claim_next_job("ct-1")
      assert claimed.status == "claimed"

      # The next claim finds nothing claimable — the fresh claim is off-limits.
      assert Registry.claim_next_job("ct-2") == nil
    end

    test "a stale claim past the attempt cap is FAILED instead of re-handed-out" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      max = Registry.max_provision_attempts()

      # Park the job at the attempt cap and make its claim stale.
      stale_at =
        DateTime.utc_now()
        |> DateTime.add(-(Registry.stale_after_seconds() + 60), :second)
        |> DateTime.truncate(:microsecond)

      _ =
        from(j in ProvisionJob, where: j.id == ^job.id)
        |> Repo.update_all(set: [status: "claimed", claimed_at: stale_at, attempts: max])

      # The over-budget stale job is failed, and since it was the only claimable
      # row, the claim returns nil (nothing handed out).
      assert Registry.claim_next_job("ct-cap") == nil

      reloaded = Repo.get(ProvisionJob, job.id)
      assert reloaded.status == "failed"
      assert reloaded.error =~ "exceeded max provision attempts"
    end

    test "an over-budget stale job is failed but a younger pending job is still claimed" do
      {_user, team} = user_with_team()
      stale_bp = barkpark_fixture(team, %{slug: "stale"})
      fresh_bp = barkpark_fixture(team, %{slug: "fresh"})
      {:ok, stale_job} = Registry.enqueue_provision_job(stale_bp)
      {:ok, pending_job} = Registry.enqueue_provision_job(fresh_bp)
      max = Registry.max_provision_attempts()

      # The stale job is the OLDEST (smallest inserted_at) AND over budget, so the
      # claim loop must fail it and move on to the younger pending job.
      old_ts = ~U[2020-01-01 00:00:00.000000Z]

      _ =
        from(j in ProvisionJob, where: j.id == ^stale_job.id)
        |> Repo.update_all(
          set: [status: "claimed", claimed_at: old_ts, inserted_at: old_ts, attempts: max]
        )

      assert {%ProvisionJob{} = claimed, _} = Registry.claim_next_job("ct-skip")
      assert claimed.id == pending_job.id
      assert claimed.status == "claimed"

      assert Repo.get(ProvisionJob, stale_job.id).status == "failed"
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

    test "a non-UUID id → {:error, :not_found} (no 500/CastError)" do
      assert Registry.succeed_job("not-a-uuid", "1.2.3.4") == {:error, :not_found}
    end

    test "rolls back the job flip when the barkpark health upsert fails (no split-brain)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{health_status: "unknown", agent_status: "offline"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      # An ip the narrow health_changeset rejects (spaces violate @host_format) —
      # the barkpark health/host upsert MUST fail. The whole call rolls back: the
      # job stays NOT-succeeded and the barkpark stays provisioning (host=nil), so
      # there is never a "succeeded job / still-provisioning barkpark" split-brain.
      assert {:error, %Ecto.Changeset{}} = Registry.succeed_job(job.id, "bad ip with spaces")

      reloaded_job = Repo.get(ProvisionJob, job.id)
      refute reloaded_job.status == "succeeded"
      assert reloaded_job.result_ip == nil

      reloaded_bp = Registry.get_barkpark(bp.id)
      assert reloaded_bp.health_status == "unknown"
      assert reloaded_bp.host == nil
    end

    test "IDEMPOTENT: a re-succeed of an already-succeeded job returns {:ok} with NO double work" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{health_status: "unknown", agent_status: "offline"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      # First succeed: job → succeeded, barkpark → up. Capture the barkpark's
      # updated_at — the no-double-work assertion is that a re-succeed leaves it
      # UNTOUCHED (the health/host upsert never re-runs).
      assert {:ok, _done} = Registry.succeed_job(job.id, "203.0.113.7")
      bp_after_first = Registry.get_barkpark(bp.id)
      assert bp_after_first.health_status == "up"
      first_updated_at = bp_after_first.updated_at

      # A retried/duplicate succeed (the worker re-POSTs after a dropped response).
      # It returns {:ok, job} — the worker keeps its box — WITHOUT re-running the
      # barkpark upsert. Pass a DIFFERENT ip to prove the side-effect is skipped:
      # if the upsert re-ran, host would change to the new ip.
      assert {:ok, %ProvisionJob{status: "succeeded"} = again} =
               Registry.succeed_job(job.id, "10.10.10.10")

      assert again.id == job.id
      # result_ip is unchanged from the first succeed — the re-POST did no work.
      assert again.result_ip == "203.0.113.7"

      bp_after_second = Registry.get_barkpark(bp.id)
      # The barkpark is untouched: same host, same updated_at (no second upsert).
      assert bp_after_second.host == "203.0.113.7"
      assert bp_after_second.updated_at == first_updated_at
    end

    test "STATUS GUARD: succeed on a FAILED job → {:error, :conflict}, job stays failed, barkpark untouched" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{health_status: "unknown", agent_status: "offline"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      # Drive the job terminal-failed first.
      assert {:ok, _} = Registry.fail_job(job.id, "hetzner: out of capacity")

      # A succeed arriving for an already-failed job must NOT resurrect it.
      assert {:error, :conflict} = Registry.succeed_job(job.id, "203.0.113.7")

      reloaded_job = Repo.get(ProvisionJob, job.id)
      assert reloaded_job.status == "failed"
      assert reloaded_job.result_ip == nil

      reloaded_bp = Registry.get_barkpark(bp.id)
      assert reloaded_bp.health_status == "unknown"
      assert reloaded_bp.host == nil
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

    test "a non-UUID id → {:error, :not_found} (no 500/CastError)" do
      assert Registry.fail_job("not-a-uuid", "x") == {:error, :not_found}
    end

    test "IDEMPOTENT: a re-fail of an already-failed job returns {:ok} unchanged" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{health_status: "unknown"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      assert {:ok, _} = Registry.fail_job(job.id, "hetzner: quota exceeded")

      # A retried/duplicate fail (dropped response) self-heals to {:ok} and does
      # NOT overwrite the original error.
      assert {:ok, %ProvisionJob{status: "failed"} = again} =
               Registry.fail_job(job.id, "a different reason")

      assert again.id == job.id
      assert again.error == "hetzner: quota exceeded"
    end

    test "STATUS GUARD: fail on a SUCCEEDED job → {:error, :conflict}, job stays succeeded" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{health_status: "unknown", agent_status: "offline"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      # Drive the job terminal-succeeded first (barkpark now up).
      assert {:ok, _} = Registry.succeed_job(job.id, "198.51.100.9")

      # A straggler fail must NOT un-succeed a live box.
      assert {:error, :conflict} = Registry.fail_job(job.id, "too late")

      reloaded_job = Repo.get(ProvisionJob, job.id)
      assert reloaded_job.status == "succeeded"
      assert reloaded_job.result_ip == "198.51.100.9"

      reloaded_bp = Registry.get_barkpark(bp.id)
      assert reloaded_bp.health_status == "up"
      assert reloaded_bp.host == "198.51.100.9"
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

      # go-live stores the GLOBALLY-unique customer-facing FQDN up front, and it is
      # IDENTICAL to the provisioning subdomain the worker stands up.
      assert bp.url == Barkpark.provisioning_url(bp)
      assert bp.url == "https://my-prod-" <> Barkpark.team_short_id(team.id) <> ".barkpark.cloud"
      assert json_body(conn)["barkpark"]["url"] == bp.url
    end

    test "two teams that both name a Barkpark 'prod' get DISTINCT global FQDNs (the bug fix)" do
      {user_a, team_a} = user_with_team()
      {user_b, team_b} = user_with_team()
      {:ok, _} = Billing.subscribe(team_a, "pro")
      {:ok, _} = Billing.subscribe(team_b, "pro")
      {:ok, token_a} = Accounts.create_user_session_token(user_a)
      {:ok, token_b} = Accounts.create_user_session_token(user_b)

      assert call(:post, "/v1/go-live", %{name: "prod", plan: "pro"}, token_a).status == 201
      assert call(:post, "/v1/go-live", %{name: "prod", plan: "pro"}, token_b).status == 201

      [bp_a] = Registry.list_barkparks(team_a)
      [bp_b] = Registry.list_barkparks(team_b)

      # Same per-team slug ...
      assert bp_a.slug == "prod"
      assert bp_b.slug == "prod"
      # ... but DISTINCT global FQDNs — no cross-tenant collision.
      assert bp_a.url != bp_b.url
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
      # `slug` is the GLOBALLY-unique provisioning subdomain (<slug>-<team_short_id>),
      # NOT the bare per-team slug — this is the label the worker turns into the DNS
      # record + box name, so it must be globally unique.
      assert body["slug"] == Barkpark.provisioning_subdomain(bp)
      assert body["slug"] == "acme-" <> Barkpark.team_short_id(team.id)
      assert body["slug"] != "acme"
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

    test "a MALFORMED (non-UUID) job id → 404, not 500" do
      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/not-a-uuid/succeed",
          %{ip: "1.2.3.4"},
          @worker_token
        )

      assert conn.status == 404
      assert json_body(conn)["error"] == "not_found"
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

    test "IDEMPOTENT: a retried succeed on an already-succeeded job → 200 (worker keeps box)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      path = "/v1/internal/provision-jobs/#{job.id}/succeed"
      assert call(:post, path, %{ip: "198.51.100.9"}, @worker_token).status == 200

      # The dropped-response retry: same endpoint, 200 again — the worker keeps box.
      conn = call(:post, path, %{ip: "198.51.100.9"}, @worker_token)
      assert conn.status == 200
      assert json_body(conn)["ok"] == true
      assert Repo.get(ProvisionJob, job.id).status == "succeeded"
    end

    test "STATUS GUARD: succeed on a FAILED job → 409 (worker tears down orphan box)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.fail_job(job.id, "out of capacity")

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/succeed",
          %{ip: "198.51.100.9"},
          @worker_token
        )

      assert conn.status == 409
      assert json_body(conn)["error"] == "conflict"
      assert Repo.get(ProvisionJob, job.id).status == "failed"
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

    test "a MALFORMED (non-UUID) job id → 404, not 500" do
      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/not-a-uuid/fail",
          %{error: "x"},
          @worker_token
        )

      assert conn.status == 404
      assert json_body(conn)["error"] == "not_found"
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

    test "IDEMPOTENT: a retried fail on an already-failed job → 200" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{health_status: "unknown"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      path = "/v1/internal/provision-jobs/#{job.id}/fail"
      assert call(:post, path, %{error: "boom"}, @worker_token).status == 200

      conn = call(:post, path, %{error: "boom again"}, @worker_token)
      assert conn.status == 200
      assert json_body(conn)["ok"] == true
      assert Repo.get(ProvisionJob, job.id).status == "failed"
    end

    test "STATUS GUARD: fail on a SUCCEEDED job → 409 (don't un-succeed a live box)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.succeed_job(job.id, "198.51.100.9")

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/fail",
          %{error: "too late"},
          @worker_token
        )

      assert conn.status == 409
      assert json_body(conn)["error"] == "conflict"

      reloaded = Repo.get(ProvisionJob, job.id)
      assert reloaded.status == "succeeded"
      assert Registry.get_barkpark(bp.id).health_status == "up"
    end
  end
end
