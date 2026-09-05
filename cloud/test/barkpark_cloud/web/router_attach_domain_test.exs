defmodule BarkparkCloud.Web.RouterAttachDomainTest do
  @moduledoc """
  Instance custom domains — the HTTP surface. Proves:

    * `POST /v1/barkparks/:id/domain` happy path: 202 {ok, custom_host, status:
      "attaching"}, custom_host persisted (and surfaced in barkpark_json), one
      pending attach_domain job enqueued, and the TLS ask-gate flips 404 → 200
      for the host
    * rejection mapping: malformed domain → 422 invalid_domain, missing → 422
      domain_required, taken → 409 taken, attach-in-flight → 409
      already_attaching (exactly one active job)
    * the worker roundtrip over the internal routes with the WORKER token:
      claim returns EXACTLY the pinned cross-language contract {job_id,
      claim_token, ip, custom_host, dns_label, dns_zone, app_port}, succeed
      flips the job (idempotently), fail marks it failed; no/bad token → 401
    * auth posture: plain member → 403; an admin of ANOTHER team gets the SAME
      404 as a nonexistent id (no existence leak); unauthenticated → 401
    * cch-w54-bl re-attach: a SECOND, different host on an instance that already
      answers on one → 409 already_attached, the row keeps the FIRST host, no
      second job, and the first host stays ask-gate-approved; the same host
      again is still a 202 (the failed-attach recovery path)
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.ProvisionJob
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  @password "correct-horse-battery"
  @worker_token "worker-token-test-fixed"
  @domain "gyldendal.barkpark.cloud"
  @box_ip "203.0.113.10"

  ## Fixtures (mirror RouterSelfUpdateTest's)

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

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  # A LIVE instance: the worker-provisioned host set (the ip the attach worker
  # SSHes to).
  defp live_barkpark(team) do
    bp = barkpark_fixture(team)
    {:ok, _} = Registry.upsert_health(bp, %{host: @box_ip})
    Registry.get_barkpark(bp.id)
  end

  defp session_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, body \\ nil, token \\ nil) do
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

  # A barkpark's ACTIVE (pending|claimed) attach_domain jobs — bounded to at
  # most one by the one-active-job-per-kind partial index.
  defp active_attaches(bp) do
    from(j in ProvisionJob,
      where:
        j.barkpark_id == ^bp.id and j.kind == "attach_domain" and
          j.status in ["pending", "claimed"]
    )
    |> Repo.aggregate(:count, :id)
  end

  describe "POST /v1/barkparks/:id/domain" do
    test "team admin + valid platform-zone host → 202, job enqueued pending, custom_host persisted, ask-gate flips 200" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = session_token(user)

      # Before the attach the ask-gate refuses the host.
      assert call(:get, "/v1/tls/ask?domain=#{@domain}").status == 404

      conn = call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: @domain}, token)

      assert conn.status == 202

      assert json_body(conn) == %{
               "ok" => true,
               "custom_host" => @domain,
               "status" => "attaching"
             }

      assert Registry.get_barkpark(bp.id).custom_host == @domain
      assert active_attaches(bp) == 1

      assert [%ProvisionJob{kind: "attach_domain", status: "pending"}] =
               Repo.all(from(j in ProvisionJob, where: j.barkpark_id == ^bp.id))

      # The ask-gate now approves on-demand issuance for the host.
      assert call(:get, "/v1/tls/ask?domain=#{@domain}").status == 200

      # And the fleet row surfaces the attached host.
      list = call(:get, "/v1/barkparks", nil, token)
      assert list.status == 200
      assert [%{"custom_host" => @domain}] = json_body(list)["barkparks"]
    end

    test "normalization: mixed case / trailing dot stores (and echoes) the canonical host" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)

      conn =
        call(
          :post,
          "/v1/barkparks/#{bp.id}/domain",
          %{domain: "Gyldendal.Barkpark.Cloud."},
          session_token(user)
        )

      assert conn.status == 202
      assert json_body(conn)["custom_host"] == @domain
      assert Registry.get_barkpark(bp.id).custom_host == @domain
    end

    test "malformed domain → 422 invalid_domain; missing → 422 domain_required; nothing persisted or enqueued" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = session_token(user)

      # (V2: a well-formed foreign FQDN like gyldendal.example.com is no longer
      # malformed — it rides the external ownership-proof path, proven in
      # RouterAttachDomainV2Test.)
      for bad <- ["barkpark.cloud", "a.b.barkpark.cloud", "-bad.barkpark.cloud"] do
        conn = call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: bad}, token)
        assert conn.status == 422
        assert json_body(conn) == %{"error" => "invalid_domain"}
      end

      for missing <- [%{}, %{domain: ""}, %{domain: 42}] do
        conn = call(:post, "/v1/barkparks/#{bp.id}/domain", missing, token)
        assert conn.status == 422
        assert json_body(conn) == %{"error" => "domain_required"}
      end

      assert Registry.get_barkpark(bp.id).custom_host == nil
      assert active_attaches(bp) == 0
    end

    test "host already claimed elsewhere → 409 taken, no job enqueued" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)

      other = live_barkpark(elem(user_with_team(), 1))
      {:ok, _} = Registry.set_custom_host(other, @domain)

      conn = call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: @domain}, session_token(user))

      assert conn.status == 409
      assert json_body(conn) == %{"error" => "taken"}
      assert Registry.get_barkpark(bp.id).custom_host == nil
      assert active_attaches(bp) == 0
    end

    test "double-enqueue: a second attach while one is in flight → 409 already_attaching, still ONE active job" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = session_token(user)

      assert call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: @domain}, token).status == 202

      conn = call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: @domain}, token)

      assert conn.status == 409
      assert json_body(conn) == %{"error" => "already_attaching"}
      assert active_attaches(bp) == 1
    end

    test "a plain team member → 403, nothing persisted" do
      {_owner, team} = user_with_team()
      bp = live_barkpark(team)

      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")

      conn =
        call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: @domain}, session_token(member))

      assert conn.status == 403
      assert Registry.get_barkpark(bp.id).custom_host == nil
      assert active_attaches(bp) == 0
    end

    test "cross-team: an admin of ANOTHER team gets the same 404 as a nonexistent id (no leak)" do
      {_user_b, team_b} = user_with_team()
      bp_b = live_barkpark(team_b)

      {user_a, _team_a} = user_with_team()
      token_a = session_token(user_a)

      wrong_team = call(:post, "/v1/barkparks/#{bp_b.id}/domain", %{domain: @domain}, token_a)

      nonexistent =
        call(:post, "/v1/barkparks/#{Ecto.UUID.generate()}/domain", %{domain: @domain}, token_a)

      assert wrong_team.status == 404
      assert nonexistent.status == 404
      assert json_body(wrong_team) == json_body(nonexistent)
      assert Registry.get_barkpark(bp_b.id).custom_host == nil
    end

    test "no token → 401" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)

      conn = call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: @domain})
      assert conn.status == 401
    end
  end

  # ── cch-w54-bl: a re-attach is REFUSED, never an overwrite ──────────────────
  #
  # PRE-FIX, driven 2026-09-03 on origin/main (probe output in the PR body):
  # POST host-a → 202, then POST host-b → 202; the row flipped to host-b,
  # `Registry.domain_registered?("host-a")` went true → false and
  # `GET /v1/tls/ask?domain=host-a` went 200 → 404. The A record the attach
  # worker had already published for host-a survived all of that on a LIVE,
  # still-billed box, with nothing in the control plane pointing at it any more.
  # There is no detach verb on this surface to sequence instead, so the fix is
  # the refusal.
  #
  # MUTATION: delete the `reattach_of_different_host?` arm from
  # `Registry.set_custom_host/2` and the first test below reds by name on the
  # 202 (and on the flipped custom_host), which is exactly the orphan.
  # Drain a barkpark's attach jobs so the one-active-job-per-kind index is NOT
  # what answers a SECOND attach POST — the re-attach refusal under test must be
  # the already_attached gate, not already_attaching.
  defp drain_attach_jobs(bp) do
    from(j in ProvisionJob, where: j.barkpark_id == ^bp.id and j.kind == "attach_domain")
    |> Repo.update_all(set: [status: "succeeded"])
  end

  describe "POST /v1/barkparks/:id/domain — re-attach (cch-w54-bl)" do
    test "a SECOND, different host → 409 already_attached; the first host survives on the row, in DNS and at the ask-gate" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = session_token(user)

      assert call(
               :post,
               "/v1/barkparks/#{bp.id}/domain",
               %{domain: "host-a.barkpark.cloud"},
               token
             ).status ==
               202

      drain_attach_jobs(bp)

      conn =
        call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: "host-b.barkpark.cloud"}, token)

      assert conn.status == 409
      body = json_body(conn)
      assert body["error"] == "already_attached"
      # The refusal NAMES the host in the way — without it the caller cannot act.
      assert body["custom_host"] == "host-a.barkpark.cloud"
      assert body["detail"] =~ "host-a.barkpark.cloud"

      # The orphan the pre-fix path created, asserted absent in all three places
      # the probe measured it.
      assert Registry.get_barkpark(bp.id).custom_host == "host-a.barkpark.cloud"
      assert Registry.domain_registered?("host-a.barkpark.cloud")
      refute Registry.domain_registered?("host-b.barkpark.cloud")
      assert call(:get, "/v1/tls/ask?domain=host-a.barkpark.cloud").status == 200
      assert call(:get, "/v1/tls/ask?domain=host-b.barkpark.cloud").status == 404

      # Refused before the persist → no second job, and no audit row claiming
      # a domain was attached.
      assert active_attaches(bp) == 0

      assert Accounts.list_audit_events(team)
             |> Enum.count(&(&1.action == "barkpark.domain_attached")) == 1
    end

    test "the SAME host again (any spelling) is still 202 — the failed-attach recovery path is untouched" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = session_token(user)

      assert call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: @domain}, token).status == 202
      drain_attach_jobs(bp)

      # Case, whitespace and the trailing dot all normalize to the stored host,
      # so this is a re-attach of ITSELF, not a replacement.
      conn =
        call(
          :post,
          "/v1/barkparks/#{bp.id}/domain",
          %{domain: "  Gyldendal.Barkpark.Cloud. "},
          token
        )

      assert conn.status == 202
      assert json_body(conn)["custom_host"] == @domain
      assert Registry.get_barkpark(bp.id).custom_host == @domain
      assert active_attaches(bp) == 1
    end

    test "a malformed second domain is still the SYNTAX verdict, not the re-attach one" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = session_token(user)

      assert call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: @domain}, token).status == 202
      drain_attach_jobs(bp)

      conn = call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: "a.b.barkpark.cloud"}, token)
      assert conn.status == 422
      assert json_body(conn) == %{"error" => "invalid_domain"}
      assert Registry.get_barkpark(bp.id).custom_host == @domain
    end
  end

  describe "internal attach-domain queue (worker token)" do
    test "claim → EXACTLY the pinned contract; succeed → 200, job succeeded (idempotently)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)

      assert call(
               :post,
               "/v1/barkparks/#{bp.id}/domain",
               %{domain: @domain},
               session_token(user)
             ).status == 202

      conn = call(:post, "/v1/internal/attach-domain-jobs/claim", %{}, @worker_token)
      assert conn.status == 200

      body = json_body(conn)
      [%ProvisionJob{} = job] = Repo.all(from(j in ProvisionJob, where: j.barkpark_id == ^bp.id))

      # The pinned cross-language contract — keys AND values, nothing extra.
      assert body == %{
               "job_id" => job.id,
               "claim_token" => job.claim_token,
               "ip" => @box_ip,
               "custom_host" => @domain,
               "dns_label" => "gyldendal",
               "dns_zone" => "barkpark.cloud",
               "app_port" => 4000
             }

      assert job.status == "claimed"

      succeed =
        call(
          :post,
          "/v1/internal/attach-domain-jobs/#{job.id}/succeed",
          %{claim_token: body["claim_token"], ip: @box_ip},
          @worker_token
        )

      assert succeed.status == 200
      assert json_body(succeed)["ok"] == true

      job = Repo.get(ProvisionJob, job.id)
      assert job.status == "succeeded"
      assert job.result_ip == @box_ip
      assert Registry.get_barkpark(bp.id).custom_host == @domain

      # IDEMPOTENT: a re-POSTed succeed (dropped response) still 200s.
      retried =
        call(
          :post,
          "/v1/internal/attach-domain-jobs/#{job.id}/succeed",
          %{claim_token: body["claim_token"]},
          @worker_token
        )

      assert retried.status == 200
    end

    test "claim with an empty queue → 204; a pending PROVISION job is never handed out here" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, _} = Registry.enqueue_provision_job(bp)

      conn = call(:post, "/v1/internal/attach-domain-jobs/claim", %{}, @worker_token)
      assert conn.status == 204
      assert conn.resp_body == ""
    end

    test "fail marks the job failed with the reason; the custom_host stays for a re-attach" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)

      call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: @domain}, session_token(user))
      claim = json_body(call(:post, "/v1/internal/attach-domain-jobs/claim", %{}, @worker_token))

      conn =
        call(
          :post,
          "/v1/internal/attach-domain-jobs/#{claim["job_id"]}/fail",
          %{error: "ssh unreachable", claim_token: claim["claim_token"]},
          @worker_token
        )

      assert conn.status == 200
      assert Repo.get(ProvisionJob, claim["job_id"]).status == "failed"
      assert Repo.get(ProvisionJob, claim["job_id"]).error == "ssh unreachable"
      assert Registry.get_barkpark(bp.id).custom_host == @domain
    end

    test "claim-fence: succeed with a mismatched claim_token → 409 stale_claim" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)

      call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: @domain}, session_token(user))
      claim = json_body(call(:post, "/v1/internal/attach-domain-jobs/claim", %{}, @worker_token))

      conn =
        call(
          :post,
          "/v1/internal/attach-domain-jobs/#{claim["job_id"]}/succeed",
          %{claim_token: "stale-token"},
          @worker_token
        )

      assert conn.status == 409
      assert json_body(conn) == %{"error" => "stale_claim"}
    end

    test "no / bad worker token → 401 on all three routes" do
      id = Ecto.UUID.generate()

      for {path, body} <- [
            {"/v1/internal/attach-domain-jobs/claim", %{}},
            {"/v1/internal/attach-domain-jobs/#{id}/succeed", %{}},
            {"/v1/internal/attach-domain-jobs/#{id}/fail", %{error: "x"}}
          ] do
        assert call(:post, path, body, nil).status == 401
        assert call(:post, path, body, "not-the-worker-token").status == 401
      end
    end
  end
end
