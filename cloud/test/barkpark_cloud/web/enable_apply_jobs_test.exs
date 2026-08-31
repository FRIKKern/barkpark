defmodule BarkparkCloud.Web.EnableApplyJobsTest do
  @moduledoc """
  isu-w5 (task-509f5fd02bc48f9c) — the enable-apply retro-arm rail, cloud side.

  Three surfaces under test:

    1. The Registry queue verbs (`enqueue_enable_apply_job/1`,
       `maybe_enqueue_enable_apply_job/1` and its consent gate, the
       kind-filtered claim, the job-row-only succeed, the fail).
    2. The AUTO-ENQUEUE: `record_apply_unarmed/1` files the repair for a
       consented box and does NOT for an opted-out one — the criterion-2
       behavior ("auto-enqueues instead of pausing").
    3. The worker HTTP routes (`/v1/internal/enable-apply-jobs/*`) — worker-token
       gated, FLAT claim payload (the exact JSON the Go worker's EnableApplySpec
       decodes), honest host-less fail, claim-fence on succeed/fail.
    4. The PATCH /v1/barkparks/:id/autoupdate wiring — enabling autoupdate on a
       box already MEASURED unarmed files the job (criterion 1).
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.{Barkpark, ProvisionJob}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @worker_token "worker-token-test-fixed"

  ## Fixtures (the AgentKeyCustodyTest harness, verbatim shapes)

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp admin_with_team do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "admin")
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, team, token}
  end

  # A live managed box: host set, autoupdate on (the schema default), not
  # suspended — the shape the consent gate says yes to.
  defp live_box_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "Box #{n}", slug: "box-#{n}"})

    bp
    |> Ecto.Changeset.change(Map.merge(%{host: "203.0.113.88"}, attrs))
    |> Repo.update!()
  end

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

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  describe "Registry.enqueue_enable_apply_job/1" do
    test "files one pending enable_apply job; a second enqueue dedups to :already_arming" do
      team = team_fixture()
      bp = live_box_fixture(team)

      assert {:ok, %ProvisionJob{kind: "enable_apply", status: "pending"}} =
               Registry.enqueue_enable_apply_job(bp)

      assert {:error, :already_arming} = Registry.enqueue_enable_apply_job(bp)
    end
  end

  describe "Registry.maybe_enqueue_enable_apply_job/1 (the consent gate)" do
    test "eligible box (autoupdate on, live host, not suspended) enqueues" do
      team = team_fixture()
      bp = live_box_fixture(team)

      assert {:ok, %ProvisionJob{kind: "enable_apply"}} =
               Registry.maybe_enqueue_enable_apply_job(bp)
    end

    test "autoupdate opted out → :skipped, no job row" do
      team = team_fixture()
      bp = live_box_fixture(team, %{autoupdate_enabled: false})

      assert {:ok, :skipped} = Registry.maybe_enqueue_enable_apply_job(bp)
      assert Repo.aggregate(ProvisionJob, :count) == 0
    end

    test "suspended box → :skipped, no job row" do
      team = team_fixture()
      bp = live_box_fixture(team, %{suspended: true})

      assert {:ok, :skipped} = Registry.maybe_enqueue_enable_apply_job(bp)
      assert Repo.aggregate(ProvisionJob, :count) == 0
    end

    test "host-less box → :skipped, no job row" do
      team = team_fixture()
      bp = live_box_fixture(team, %{host: nil})

      assert {:ok, :skipped} = Registry.maybe_enqueue_enable_apply_job(bp)
      assert Repo.aggregate(ProvisionJob, :count) == 0
    end

    test "already-in-flight job dedups quietly to {:ok, :already_arming}" do
      team = team_fixture()
      bp = live_box_fixture(team)

      assert {:ok, %ProvisionJob{}} = Registry.maybe_enqueue_enable_apply_job(bp)
      assert {:ok, :already_arming} = Registry.maybe_enqueue_enable_apply_job(bp)
      assert Repo.aggregate(ProvisionJob, :count) == 1
    end
  end

  describe "Registry.record_apply_unarmed/1 auto-enqueue (criterion 2)" do
    test "a consented box measured unarmed gets its repair filed, not just recorded" do
      team = team_fixture()
      bp = live_box_fixture(team)

      assert {:ok, %Barkpark{apply_arming: "unarmed"}} = Registry.record_apply_unarmed(bp)

      assert [%ProvisionJob{kind: "enable_apply", status: "pending"}] = Repo.all(ProvisionJob)
    end

    test "an opted-out box is recorded unarmed but NOT enqueued (no consent)" do
      team = team_fixture()
      bp = live_box_fixture(team, %{autoupdate_enabled: false})

      assert {:ok, %Barkpark{apply_arming: "unarmed"}} = Registry.record_apply_unarmed(bp)
      assert Repo.aggregate(ProvisionJob, :count) == 0
    end

    test "re-measuring unarmed while a job is in flight stays one job (dedup)" do
      team = team_fixture()
      bp = live_box_fixture(team)

      assert {:ok, _} = Registry.record_apply_unarmed(bp)
      assert {:ok, _} = Registry.record_apply_unarmed(bp)
      assert Repo.aggregate(ProvisionJob, :count) == 1
    end
  end

  describe "POST /v1/internal/enable-apply-jobs/claim" do
    test "401 without the worker token" do
      conn = call(:post, "/v1/internal/enable-apply-jobs/claim", nil, "not-the-worker-token")
      assert conn.status == 401
    end

    test "204 when no pending job" do
      conn = call(:post, "/v1/internal/enable-apply-jobs/claim", nil, @worker_token)
      assert conn.status == 204
    end

    test "200 with the FLAT payload the Go EnableApplySpec decodes: job_id, claim_token, ip" do
      team = team_fixture()
      bp = live_box_fixture(team)
      {:ok, job} = Registry.enqueue_enable_apply_job(bp)

      conn = call(:post, "/v1/internal/enable-apply-jobs/claim", nil, @worker_token)
      assert conn.status == 200

      body = decode(conn)
      assert body["job_id"] == job.id
      assert is_binary(body["claim_token"]) and body["claim_token"] != ""
      assert body["ip"] == "203.0.113.88"

      # Flat, not nested — the Go side unmarshals top-level keys.
      refute Map.has_key?(body, "job")

      assert %ProvisionJob{status: "claimed"} = Repo.get!(ProvisionJob, job.id)
    end

    test "a host-less row is failed honestly and the claim answers 204" do
      team = team_fixture()
      bp = live_box_fixture(team)
      {:ok, job} = Registry.enqueue_enable_apply_job(bp)

      # The box lost its host mid-flight (removed/recycled).
      bp |> Ecto.Changeset.change(host: nil) |> Repo.update!()

      conn = call(:post, "/v1/internal/enable-apply-jobs/claim", nil, @worker_token)
      assert conn.status == 204

      failed = Repo.get!(ProvisionJob, job.id)
      assert failed.status == "failed"
      assert failed.error =~ "no host"
    end

    test "a claim is kind-filtered: a pending provision job is never handed to this drain" do
      team = team_fixture()
      bp = live_box_fixture(team)
      {:ok, _provision} = Registry.enqueue_provision_job(bp)

      conn = call(:post, "/v1/internal/enable-apply-jobs/claim", nil, @worker_token)
      assert conn.status == 204
    end
  end

  describe "POST /v1/internal/enable-apply-jobs/:id/succeed and /fail" do
    setup do
      team = team_fixture()

      bp =
        live_box_fixture(team, %{health_status: "up"})

      {:ok, job} = Registry.enqueue_enable_apply_job(bp)
      claim = call(:post, "/v1/internal/enable-apply-jobs/claim", nil, @worker_token)
      assert claim.status == 200
      %{bp: bp, job: job, claim_token: decode(claim)["claim_token"]}
    end

    test "succeed flips the JOB ROW ONLY — the live barkpark row keeps host and health",
         %{bp: bp, job: job, claim_token: token} do
      conn =
        call(
          :post,
          "/v1/internal/enable-apply-jobs/#{job.id}/succeed",
          %{ip: bp.host, claim_token: token},
          @worker_token
        )

      assert conn.status == 200

      succeeded = Repo.get!(ProvisionJob, job.id)
      assert succeeded.status == "succeeded"
      assert succeeded.result_ip == bp.host

      fresh = Repo.get!(Barkpark, bp.id)
      assert fresh.host == bp.host
      assert fresh.health_status == "up"
      # apply_arming stays a MEASUREMENT — the succeed does not fabricate "armed".
      assert fresh.apply_arming == bp.apply_arming
    end

    test "succeed with a stale claim token is fenced (409)", %{job: job} do
      conn =
        call(
          :post,
          "/v1/internal/enable-apply-jobs/#{job.id}/succeed",
          %{claim_token: "stale-token-from-a-lost-claim"},
          @worker_token
        )

      assert conn.status == 409
      assert decode(conn)["error"] == "stale_claim"
      assert %ProvisionJob{status: "claimed"} = Repo.get!(ProvisionJob, job.id)
    end

    test "fail records the error and leaves the barkpark row untouched",
         %{bp: bp, job: job, claim_token: token} do
      conn =
        call(
          :post,
          "/v1/internal/enable-apply-jobs/#{job.id}/fail",
          %{error: "ssh: connect refused", claim_token: token},
          @worker_token
        )

      assert conn.status == 200

      failed = Repo.get!(ProvisionJob, job.id)
      assert failed.status == "failed"
      assert failed.error == "ssh: connect refused"

      fresh = Repo.get!(Barkpark, bp.id)
      assert fresh.host == bp.host
    end
  end

  describe "PATCH /v1/barkparks/:id/autoupdate {enabled: true} wiring (criterion 1)" do
    test "enabling autoupdate on a MEASURED-unarmed box files the enable-apply job" do
      {_user, team, session} = admin_with_team()

      bp =
        live_box_fixture(team, %{
          autoupdate_enabled: false,
          apply_arming: "unarmed",
          apply_arming_checked_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        })

      conn =
        call(
          :patch,
          "/v1/barkparks/#{bp.id}/autoupdate",
          %{autoupdate_enabled: true},
          session
        )

      assert conn.status == 200
      assert decode(conn)["autoupdate"]["enabled"] == true

      assert [%ProvisionJob{kind: "enable_apply", status: "pending"}] = Repo.all(ProvisionJob)
    end

    test "enabling autoupdate on an unmeasured box files nothing (no blind SSH)" do
      {_user, team, session} = admin_with_team()
      bp = live_box_fixture(team, %{autoupdate_enabled: false, apply_arming: nil})

      conn =
        call(
          :patch,
          "/v1/barkparks/#{bp.id}/autoupdate",
          %{autoupdate_enabled: true},
          session
        )

      assert conn.status == 200
      assert Repo.aggregate(ProvisionJob, :count) == 0
    end
  end
end
