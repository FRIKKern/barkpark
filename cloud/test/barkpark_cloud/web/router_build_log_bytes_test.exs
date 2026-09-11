defmodule BarkparkCloud.Web.RouterBuildLogBytesTest do
  @moduledoc """
  `dr-bl-recorder-http-read-path` c1 — the operator read path for the recorded
  build log's BYTES, addressed BY DEPLOYMENT ID, through the REAL router pipeline.

  THE HOLE THIS PINS. #16847 gave the control plane the structured record and
  said in its own moduledoc that it "CANNOT serve bytes the box will not hand
  over, and it does not try". #17624 made the box's bytes safe to hand over. The
  door between them did not exist: `GET …/build-log/bytes` fell through this
  router to its catch-all.

  WHAT IS DELIBERATELY NOT ASSERTED. No test here asserts a live 200 from the
  operator gate IN PRODUCTION. `PLATFORM_ADMIN_EMAILS` is unset in prod
  (`gr-ops-platform-admin-emails`), so this route is 403-dark there for every
  real account. These tests set the allowlist in Application config for the test
  process, which proves the GATE and the ROUTE and claims nothing about prod.

  `async: false` — the operator allowlist is process-global Application config.
  """
  use BarkparkCloud.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Sites.FakeBoxRelay
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  setup do
    prior = Application.get_env(:barkpark_cloud, :platform_admin_emails, [])
    on_exit(fn -> Application.put_env(:barkpark_cloud, :platform_admin_emails, prior) end)
    :ok
  end

  ## Fixtures -----------------------------------------------------------------

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp live_bp do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team_fixture(), %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: "https://bp-#{n}.barkpark.cloud",
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
    )
    |> Repo.update!()
  end

  defp site_fixture(bp) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Blog #{n}",
        slug: "blog-#{n}",
        kind: "static",
        framework: "astro"
      })

    site
  end

  defp deployment_fixture(site, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, d} = Registry.create_deployment(site, Enum.into(attrs, %{build_id: "bld-#{n}"}))
    d |> Ecto.Changeset.change(status: "failed") |> Repo.update!()
  end

  defp operator_fixture do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{email: "op-#{n}@example.com", password: @password})
    {:ok, team} = Accounts.create_team(%{name: "OpTeam #{n}", slug: "opteam-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    Application.put_env(:barkpark_cloud, :platform_admin_emails, [user.email])
    user
  end

  defp plain_user_fixture do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{email: "plain-#{n}@example.com", password: @password})
    {:ok, team} = Accounts.create_team(%{name: "PlainTeam #{n}", slug: "plainteam-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    user
  end

  defp get_bytes(site_id, dep_id, user) do
    conn = conn(:get, "/v1/sites/#{site_id}/deployments/#{dep_id}/build-log/bytes")

    conn =
      case user do
        nil ->
          conn

        user ->
          {:ok, token} = Accounts.create_user_session_token(user)
          put_req_header(conn, "authorization", "Bearer #{token}")
      end

    Router.call(conn, @opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  ## 1. c0 — the bytes are readable by deployment id ---------------------------

  describe "the bytes read path exists at all (the RED-before arm)" do
    # THE MUTATION PROOF. Delete the `get ".../build-log/bytes"` clause and this
    # fails: the catch-all answers 404 with no `deployment_id` and no `tail`. A
    # 200 carrying THAT deployment's id AND the log's own text can only come from
    # a route that resolved a deployment and asked a box for bytes.
    test "an operator reads a recorded build's BYTES by DEPLOYMENT ID" do
      operator = operator_fixture()
      site = site_fixture(live_bp())
      dep = deployment_fixture(site)

      FakeBoxRelay.program(
        build_log_bytes:
          FakeBoxRelay.build_log_bytes_payload(site.slug, dep.build_id, 200, "available",
            tail: "npm ERR! 401 Unauthorized\nBUILD failed\n"
          )
      )

      conn = get_bytes(site.id, dep.id, operator)

      assert conn.status == 200
      assert body(conn)["deployment_id"] == dep.id
      assert body(conn)["build_id"] == dep.build_id
      assert body(conn)["available"] == true
      assert body(conn)["tail"] =~ "npm ERR! 401 Unauthorized"
      assert body(conn)["truncated"] == false
    end

    # THE KEY IS THE DEPLOYMENT, NOT THE SLUG — days later, whether or not the
    # site has deployed since. A POSITIVE FACT about what crossed the seam.
    test "a later deployment on the same site does not change what the older one reads" do
      operator = operator_fixture()
      site = site_fixture(live_bp())
      old = deployment_fixture(site, %{build_id: "bld-old"})
      _newer = deployment_fixture(site, %{build_id: "bld-new"})

      FakeBoxRelay.program(
        build_log_bytes:
          FakeBoxRelay.build_log_bytes_payload(site.slug, "bld-old", 200, "available",
            tail: "the OLD build failed at BUILD\n"
          )
      )

      conn = get_bytes(site.id, old.id, operator)

      assert conn.status == 200
      assert body(conn)["tail"] =~ "the OLD build"
      assert [{:build_log_bytes, %{slug: slug, build_id: "bld-old"}}] = FakeBoxRelay.calls()
      assert slug == site.slug
    end

    test "no such deployment is 404 not_found, and a deployment of ANOTHER site is the same 404" do
      operator = operator_fixture()
      site = site_fixture(live_bp())
      other = site_fixture(live_bp())
      theirs = deployment_fixture(other)

      absent = get_bytes(site.id, Ecto.UUID.generate(), operator)
      foreign = get_bytes(site.id, theirs.id, operator)

      assert absent.status == 404
      assert body(absent)["error"] == "not_found"
      # EXISTENCE-LEAK PARITY: byte-identical, so this route leaks no deployment
      # ids the record route withholds.
      assert foreign.status == absent.status
      assert foreign.resp_body == absent.resp_body
    end
  end

  ## 2. c1 — the REFUSAL -------------------------------------------------------

  describe "log_scrub nil is a distinguishable REFUSAL, never a served log" do
    # THE CRITERION, and it is proved on BOTH sides of the relay: the box's own
    # 422 is relayed as a 422, AND a box that answers 200-available with a null
    # log_scrub is refused HERE too (defence in depth — an invariant held
    # somewhere else is what a byte door must not rely on).
    test "the box's 422 build_log_unscrubbed is relayed, not reinterpreted" do
      operator = operator_fixture()
      site = site_fixture(live_bp())
      dep = deployment_fixture(site)

      FakeBoxRelay.program(
        build_log_bytes:
          FakeBoxRelay.build_log_bytes_payload(site.slug, dep.build_id, 422, "available",
            log_scrub: nil,
            tail: nil,
            error: {"build_log_unscrubbed", "never folded"}
          )
      )

      conn = get_bytes(site.id, dep.id, operator)

      assert conn.status == 422
      assert body(conn)["error"] == "build_log_unscrubbed"
      assert body(conn)["available"] == false
      assert body(conn)["tail"] == nil
      # A REFUSAL, NOT AN ABSENCE: the operator is told the log is there.
      assert body(conn)["log_state"] == "available"
    end

    test "a 200 claiming available bytes with a NULL log_scrub is refused on this end too" do
      operator = operator_fixture()
      site = site_fixture(live_bp())
      dep = deployment_fixture(site)

      FakeBoxRelay.program(
        build_log_bytes:
          FakeBoxRelay.build_log_bytes_payload(site.slug, dep.build_id, 200, "available",
            log_scrub: nil,
            tail: "BARKPARK_TOKEN=bppat_neverfolded\n"
          )
      )

      conn = get_bytes(site.id, dep.id, operator)

      assert conn.status == 422
      assert body(conn)["error"] == "build_log_unscrubbed"
      # THE POINT: the unfolded bytes the box wrongly offered do not reach the
      # wire. Asserted against the RAW response, not a decoded field.
      refute conn.resp_body =~ "bppat_"
      assert body(conn)["tail"] == nil
    end

    # THE FOUR ANSWERS ARE FOUR STATUSES, asserted as ONE sorted comparison:
    # collapse any two and this compares equal and FAILS, which four separate
    # status assertions could never catch.
    test "refused / evicted / never-recorded / no-such-deployment are four statuses" do
      operator = operator_fixture()
      site = site_fixture(live_bp())
      dep = deployment_fixture(site)

      FakeBoxRelay.program(
        build_log_bytes:
          FakeBoxRelay.build_log_bytes_payload(site.slug, dep.build_id, 422, "available",
            log_scrub: nil,
            error: {"build_log_unscrubbed", "never folded"}
          )
      )

      refused = get_bytes(site.id, dep.id, operator).status

      FakeBoxRelay.program(
        build_log_bytes:
          FakeBoxRelay.build_log_bytes_payload(site.slug, dep.build_id, 410, "evicted",
            evicted_at: "2026-08-13T04:00:00Z"
          )
      )

      evicted = get_bytes(site.id, dep.id, operator).status

      FakeBoxRelay.program(
        build_log_bytes:
          FakeBoxRelay.build_log_bytes_payload(site.slug, dep.build_id, 200, "never_recorded")
      )

      never = get_bytes(site.id, dep.id, operator).status
      absent = get_bytes(site.id, Ecto.UUID.generate(), operator).status

      assert Enum.sort([refused, evicted, never, absent]) == [200, 404, 410, 422]
    end

    test "evicted is 410 and names when retention took the bytes" do
      operator = operator_fixture()
      site = site_fixture(live_bp())
      dep = deployment_fixture(site)

      FakeBoxRelay.program(
        build_log_bytes:
          FakeBoxRelay.build_log_bytes_payload(site.slug, dep.build_id, 410, "evicted",
            evicted_at: "2026-08-13T04:00:00Z"
          )
      )

      conn = get_bytes(site.id, dep.id, operator)

      assert conn.status == 410
      assert body(conn)["error"] == "build_log_evicted"
      assert body(conn)["evicted_at"] == "2026-08-13T04:00:00Z"
    end

    # AN OLD BOX IS NOT AN EMPTY LOG. A box that predates `bytes=1` ignores it and
    # answers the RECORD: 200, `log_state: "available"`, no `tail` key. Reading
    # that as "available, zero bytes" is a lie about a log sitting on the box.
    test "an old box answering the RECORD is 502, never a 200 with no bytes" do
      operator = operator_fixture()
      site = site_fixture(live_bp())
      dep = deployment_fixture(site)

      FakeBoxRelay.program(
        build_log_bytes: FakeBoxRelay.terminal_record(site.slug, dep.build_id, "available")
      )

      conn = get_bytes(site.id, dep.id, operator)

      assert conn.status == 502
      assert body(conn)["error"] == "box_unreachable"
      assert body(conn)["detail"] =~ "too old"
      refute Map.has_key?(body(conn), "tail")
    end
  end

  ## 3. c2 — the size policy is enforced on THIS end too ------------------------

  describe "the size policy is enforced here, not inherited" do
    test "an oversized tail from the box is truncated with a visible marker" do
      operator = operator_fixture()
      site = site_fixture(live_bp())
      dep = deployment_fixture(site)

      # An order of magnitude over nothing — exactly one byte over would pass a
      # boundary test and prove nothing about a box that forgot its cap. This is
      # 4x the control plane's own 256 KiB.
      oversized = String.duplicate("x", 1_048_576)

      FakeBoxRelay.program(
        build_log_bytes:
          FakeBoxRelay.build_log_bytes_payload(site.slug, dep.build_id, 200, "available",
            tail: oversized,
            tail_bytes: byte_size(oversized),
            truncated: false
          )
      )

      conn = get_bytes(site.id, dep.id, operator)

      assert conn.status == 200
      assert byte_size(body(conn)["tail"]) < byte_size(oversized)
      assert body(conn)["tail"] =~ "truncated by the control plane"
      # The box SAID not-truncated; this end says otherwise because this end did
      # the truncating. A flag that reported the box's claim would be a lie.
      assert body(conn)["truncated"] == true
      assert body(conn)["tail_bytes"] == byte_size(body(conn)["tail"])
    end

    test "a tail under the cap is passed through whole and stays untruncated" do
      operator = operator_fixture()
      site = site_fixture(live_bp())
      dep = deployment_fixture(site)
      whole = "npm ERR! short and complete\n"

      FakeBoxRelay.program(
        build_log_bytes:
          FakeBoxRelay.build_log_bytes_payload(site.slug, dep.build_id, 200, "available",
            tail: whole
          )
      )

      conn = get_bytes(site.id, dep.id, operator)

      assert body(conn)["tail"] == whole
      assert body(conn)["truncated"] == false
    end
  end

  ## 4. The gate ---------------------------------------------------------------

  describe "operator-gated, and the gate sits IN FRONT OF the relay" do
    # BOTH ARMS IN ONE RUN. An authenticated NON-operator gets 403 AND the box was
    # never called — which is what proves the gate is in front of the relay rather
    # than behind it. The identical fixture under `operator_fixture/0` above is the
    # specimen it must let through.
    test "an authenticated non-operator gets 403 and the box is never asked" do
      _operator = operator_fixture()
      plain = plain_user_fixture()
      site = site_fixture(live_bp())
      dep = deployment_fixture(site)

      FakeBoxRelay.program(
        build_log_bytes:
          FakeBoxRelay.build_log_bytes_payload(site.slug, dep.build_id, 200, "available",
            tail: "secret build output\n"
          )
      )

      conn = get_bytes(site.id, dep.id, plain)

      assert conn.status == 403
      assert FakeBoxRelay.calls() == []
      refute conn.resp_body =~ "secret build output"
    end

    test "anonymous gets 401 and the box is never asked" do
      site = site_fixture(live_bp())
      dep = deployment_fixture(site)
      FakeBoxRelay.program([])

      conn = get_bytes(site.id, dep.id, nil)

      assert conn.status == 401
      assert FakeBoxRelay.calls() == []
    end
  end
end
