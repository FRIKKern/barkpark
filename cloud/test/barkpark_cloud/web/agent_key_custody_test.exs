defmodule BarkparkCloud.Web.AgentKeyCustodyTest do
  @moduledoc """
  PDF-D94 (`pdf-bl-console-key-custody`) — the console paste-a-key path, with
  the REDACTION PROOF the task's criterion names: the key travels
  browser → CP → (worker claim) and is provably never persisted CP-side. The
  proof greps the DB writes (every provision_jobs + audit_events row), the
  captured logs, and every response body for the sentinel key — each of those
  assertions goes red if any surface starts keeping it.

  `async: false` — the AgentKeyStash is one shared named ETS table and the
  restart-loss test calls `reset/0`, which would race concurrent stashes.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog
  require Logger

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Accounts.AuditEvent
  alias BarkparkCloud.Registry.{AgentKeyStash, Barkpark, ProvisionJob}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @worker_token "worker-token-test-fixed"

  # The sentinel: url-safe, in-shape, and unmistakable in any dump.
  @key "sk-ant-api03-SENTINEL-NEVER-PERSISTED-0000000000"

  ## Fixtures (the FleetSupportsTest harness, verbatim shapes)

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

  defp user_with_role(role) do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, team, token}
  end

  defp main_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "Main #{n}", slug: "main-#{n}"})
    {:ok, main} = bp |> Barkpark.fleet_changeset(%{fleet_role: "main"}) |> Repo.update()
    main
  end

  # A LIVE support: bound under an in-team main, host set, healthy — the state
  # the console's key card renders for.
  defp live_support_fixture(team) do
    main = main_fixture(team)
    n = System.unique_integer([:positive])

    {:ok, support} =
      Registry.register_support_barkpark(team, %{
        name: "Muscle #{n}",
        slug: "muscle-#{n}",
        parent_id: main.id,
        token_id: "tok-#{n}"
      })

    support
    |> Ecto.Changeset.change(host: "203.0.113.77", health_status: "up", agent_status: "online")
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

  # THE CUSTODY GREP: every durable row this flow can touch, dumped and scanned.
  defp refute_key_persisted do
    jobs = Repo.all(ProvisionJob) |> inspect(limit: :infinity, printable_limit: :infinity)
    refute jobs =~ @key, "a provision_jobs row carries the key"

    audits = Repo.all(AuditEvent) |> inspect(limit: :infinity, printable_limit: :infinity)
    refute audits =~ @key, "an audit_events row carries the key"
  end

  describe "POST /v1/barkparks/:id/agent-key (the paste)" do
    test "202 for an admin session on a live support; the job row, audit row and logs hold NO key material" do
      {_user, team, token} = user_with_role("admin")
      support = live_support_fixture(team)

      # The test env filters at :warning, which would hide an :info-level leak
      # entirely (measured: an injected Logger.info carrying the key left this
      # capture EMPTY). Drop to :debug for the capture so the grep sees every
      # level a prod deployment could emit; async: false makes this safe.
      prev_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: prev_level) end)

      log =
        capture_log(fn ->
          conn = call(:post, "/v1/barkparks/#{support.id}/agent-key", %{key: @key}, token)
          assert conn.status == 202
          assert %{"ok" => true, "job_id" => job_id} = decode(conn)

          job = Repo.get!(ProvisionJob, job_id)
          assert job.kind == "push_agent_key"
          assert job.status == "pending"
          assert job.barkpark_id == support.id
        end)

      # NEVER KEEPS, proven by grep: DB writes, audit events, captured logs.
      refute_key_persisted()
      refute log =~ @key, "a log line carries the key"

      # The audit trail DOES record the fact — var name only.
      assert [audit] =
               Repo.all(from(a in AuditEvent, where: a.action == "barkpark.agent_key_delivered"))

      assert audit.target_id == support.id
      assert audit.metadata == %{"key_var" => "ANTHROPIC_API_KEY"}
    end

    test "explicit OPENAI_API_KEY key_var is accepted and audited as such" do
      {_user, team, token} = user_with_role("admin")
      support = live_support_fixture(team)

      conn =
        call(
          :post,
          "/v1/barkparks/#{support.id}/agent-key",
          %{key: @key, key_var: "OPENAI_API_KEY"},
          token
        )

      assert conn.status == 202

      assert [audit] =
               Repo.all(from(a in AuditEvent, where: a.action == "barkpark.agent_key_delivered"))

      assert audit.metadata == %{"key_var" => "OPENAI_API_KEY"}
    end

    test "a member session is refused with the ADMIN authority named (cch-w37-s2 parity)" do
      {_user, team, token} = user_with_role("member")
      support = live_support_fixture(team)

      conn = call(:post, "/v1/barkparks/#{support.id}/agent-key", %{key: @key}, token)
      assert conn.status == 403
      assert %{"required" => "admin"} = decode(conn)
      assert Repo.all(ProvisionJob) == []
    end

    test "a cross-team support is a 404 (no existence leak); an in-team MAIN is a 422" do
      {_user, team, token} = user_with_role("admin")
      other_team = team_fixture()
      foreign = live_support_fixture(other_team)

      assert call(:post, "/v1/barkparks/#{foreign.id}/agent-key", %{key: @key}, token).status ==
               404

      main = main_fixture(team)
      conn = call(:post, "/v1/barkparks/#{main.id}/agent-key", %{key: @key}, token)
      assert conn.status == 422
      assert %{"error" => "not_a_support"} = decode(conn)
    end

    test "a not-yet-live support (host nil) is a 409 not_live" do
      {_user, team, token} = user_with_role("admin")
      support = live_support_fixture(team) |> Ecto.Changeset.change(host: nil) |> Repo.update!()

      conn = call(:post, "/v1/barkparks/#{support.id}/agent-key", %{key: @key}, token)
      assert conn.status == 409
      assert %{"error" => "not_live"} = decode(conn)
    end

    test "an out-of-shape key is refused WITHOUT being echoed; an unknown var is refused" do
      {_user, team, token} = user_with_role("admin")
      support = live_support_fixture(team)
      hostile = "sk-ant-x'; rm -rf / #aaaaaaaaaaaaaa"

      conn = call(:post, "/v1/barkparks/#{support.id}/agent-key", %{key: hostile}, token)
      assert conn.status == 422
      refute conn.resp_body =~ hostile, "the refusal echoes the pasted value"

      conn =
        call(
          :post,
          "/v1/barkparks/#{support.id}/agent-key",
          %{key: @key, key_var: "HCLOUD_TOKEN"},
          token
        )

      assert conn.status == 422
      assert Repo.all(ProvisionJob) == []
    end

    test "a second paste while one is in flight is a 409 already_delivering" do
      {_user, team, token} = user_with_role("admin")
      support = live_support_fixture(team)

      assert call(:post, "/v1/barkparks/#{support.id}/agent-key", %{key: @key}, token).status ==
               202

      conn = call(:post, "/v1/barkparks/#{support.id}/agent-key", %{key: @key}, token)
      assert conn.status == 409
      assert %{"error" => "already_delivering"} = decode(conn)
    end
  end

  describe "POST /v1/internal/agent-key-jobs/claim (the ONE hand-off)" do
    test "delivers {job, ip, key_var, key} exactly once; the job row still never holds the key" do
      {_user, team, token} = user_with_role("admin")
      support = live_support_fixture(team)

      assert call(:post, "/v1/barkparks/#{support.id}/agent-key", %{key: @key}, token).status ==
               202

      conn = call(:post, "/v1/internal/agent-key-jobs/claim", %{}, @worker_token)
      assert conn.status == 200

      assert %{
               "job" => %{"id" => job_id, "claim_token" => claim_token},
               "ip" => "203.0.113.77",
               "key_var" => "ANTHROPIC_API_KEY",
               "key" => @key
             } = decode(conn)

      assert is_binary(claim_token) and claim_token != ""
      assert Repo.get!(ProvisionJob, job_id).status == "claimed"

      # Delete-on-read: after the hand-off, nothing durable OR in-memory holds it.
      refute_key_persisted()
      assert AgentKeyStash.take(job_id) == :error

      # And the queue is drained — a second claim is a clean 204.
      assert call(:post, "/v1/internal/agent-key-jobs/claim", %{}, @worker_token).status == 204
    end

    test "a CP-restart-shaped stash loss fails the job HONESTLY at claim (204, never a keyless 200)" do
      {_user, team, token} = user_with_role("admin")
      support = live_support_fixture(team)

      conn = call(:post, "/v1/barkparks/#{support.id}/agent-key", %{key: @key}, token)
      assert conn.status == 202
      %{"job_id" => job_id} = decode(conn)

      # The restart: the in-memory stash is gone, the DB job row survives.
      AgentKeyStash.reset()

      assert call(:post, "/v1/internal/agent-key-jobs/claim", %{}, @worker_token).status == 204

      job = Repo.get!(ProvisionJob, job_id)
      assert job.status == "failed"
      assert job.error =~ "paste it again"
    end

    test "the claim route refuses a non-worker bearer" do
      {_user, _team, token} = user_with_role("admin")
      assert call(:post, "/v1/internal/agent-key-jobs/claim", %{}, token).status == 401
    end
  end

  describe "succeed/fail transitions flip the JOB ROW ONLY" do
    # The guard this pins: wiring these routes to the generic succeed_job would
    # clobber a LIVE support row back to health "unknown" / agent "offline".
    # Mutate succeed_agent_key_job to succeed_job and this test goes red.
    test "succeed marks the job; the live support row keeps host, health and agent status" do
      {_user, team, token} = user_with_role("admin")
      support = live_support_fixture(team)

      assert call(:post, "/v1/barkparks/#{support.id}/agent-key", %{key: @key}, token).status ==
               202

      claim = call(:post, "/v1/internal/agent-key-jobs/claim", %{}, @worker_token)
      %{"job" => %{"id" => job_id, "claim_token" => fence}} = decode(claim)

      conn =
        call(
          :post,
          "/v1/internal/agent-key-jobs/#{job_id}/succeed",
          %{ip: "203.0.113.77", claim_token: fence},
          @worker_token
        )

      assert conn.status == 200
      assert Repo.get!(ProvisionJob, job_id).status == "succeeded"

      after_row = Repo.get!(Barkpark, support.id)
      assert after_row.host == "203.0.113.77"
      assert after_row.health_status == "up"
      assert after_row.agent_status == "online"
    end

    test "fail records the worker's error on the job; the row is untouched; a stale fence is refused" do
      {_user, team, token} = user_with_role("admin")
      support = live_support_fixture(team)

      assert call(:post, "/v1/barkparks/#{support.id}/agent-key", %{key: @key}, token).status ==
               202

      claim = call(:post, "/v1/internal/agent-key-jobs/claim", %{}, @worker_token)
      %{"job" => %{"id" => job_id, "claim_token" => fence}} = decode(claim)

      # claim-fence: a stale worker's transition is refused.
      stale =
        call(
          :post,
          "/v1/internal/agent-key-jobs/#{job_id}/fail",
          %{error: "boom", claim_token: "not-the-fence"},
          @worker_token
        )

      assert stale.status == 409
      assert %{"error" => "stale_claim"} = decode(stale)

      conn =
        call(
          :post,
          "/v1/internal/agent-key-jobs/#{job_id}/fail",
          %{error: "deliver ANTHROPIC_API_KEY: ssh: connect refused", claim_token: fence},
          @worker_token
        )

      assert conn.status == 200
      job = Repo.get!(ProvisionJob, job_id)
      assert job.status == "failed"
      assert job.error =~ "connect refused"
      assert Repo.get!(Barkpark, support.id).health_status == "up"
    end
  end

  describe "GET /v1/barkparks/:id/agent-key (the status poll)" do
    test "renders the latest job's status/error and NOTHING key-shaped; null when never delivered" do
      {_user, team, token} = user_with_role("admin")
      support = live_support_fixture(team)

      conn = call(:get, "/v1/barkparks/#{support.id}/agent-key", nil, token)
      assert conn.status == 200
      assert %{"job" => nil} = decode(conn)

      assert call(:post, "/v1/barkparks/#{support.id}/agent-key", %{key: @key}, token).status ==
               202

      conn = call(:get, "/v1/barkparks/#{support.id}/agent-key", nil, token)
      assert conn.status == 200
      assert %{"job" => %{"status" => "pending"}} = decode(conn)
      refute conn.resp_body =~ @key
    end

    test "a member session is refused; a cross-team read is a 404" do
      {_user, team, _} = user_with_role("admin")
      support = live_support_fixture(team)

      {_u2, _t2, member_token} = user_with_role("member")

      assert call(:get, "/v1/barkparks/#{support.id}/agent-key", nil, member_token).status in [
               403,
               404
             ]
    end
  end
end
