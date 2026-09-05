defmodule BarkparkCloud.Web.UsageRouteTest do
  @moduledoc """
  GET /v1/barkparks/:id/usage (C9 + C11 — charter decision D48 / OC3): the
  console's usage meters, composed honestly. Proves:

    * 200 with the FULL fixed meter vocabulary, every meter uniform-shaped
    * flow meters (api_requests / bandwidth) are ALWAYS "unmetered"
    * seats reflect the team's real member count (+ pending-invitation detail)
    * db_size / disk come from the latest health beat, carrying its measured_at
    * C11 real inventory: documents + datasets + webhooks are fetched SERVER-SIDE
      with the vault-stored admin token — datasets from the instance's dataset
      list, documents (analytics total) and webhooks summed CROSS-DATASET over
      that list — and that token is ABSENT from the rendered body (regex-scanned)
      while every upstream request DID carry it (custody round-trip)
    * honest degradation: an unenumerable / unreachable instance still returns
      200 with the control-plane meters present and the instance-sourced meters
      degraded to "unmetered" — never a 500, never a fake zero, never a block
    * partial failure of a cross-dataset fan-out degrades that WHOLE meter (a
      partial sum would silently undercount) WITHOUT dragging the others down
    * a still-provisioning (no-url) / pre-feature (no-token) instance never calls
      upstream; the instance meters degrade, seats still return
    * auth: 401 unauthenticated; team-scope fail-closed → the SAME 404 for
      wrong-team / nonexistent / malformed ids
  """
  # async: false — this module swaps node-global env
  # (`:barkpark_cloud, :usage_fanout_budget_ms`), which is ONE value for the whole
  # node: while held, every concurrent async usage read runs on that budget.
  # Ratchet: scripts/async_env_seam_scan.exs.
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo, Usage}
  alias BarkparkCloud.Billing.Subscription
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient, as: Fake
  alias BarkparkCloud.Usage.Sample
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  @password "correct-horse-battery"
  @instance_admin_token "instance-admin-token-plaintext-XYZ"
  @instance_url "https://prod.barkpark.cloud"

  ## Fixtures (mirror InstanceApiProxyTest's)

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

  defp live_barkpark(team) do
    team
    |> barkpark_fixture()
    |> Ecto.Changeset.change(
      url: @instance_url,
      host: "203.0.113.10",
      admin_token_encrypted: Vault.encrypt(@instance_admin_token)
    )
    |> Repo.update!()
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

  defp usage(conn), do: Jason.decode!(conn.resp_body)["usage"]
  defp meters(conn), do: usage(conn)["meters"]

  defp ok_json(status, body), do: {:ok, %{status: status, body: body}}

  defp seed_health(bp, payload) do
    {:ok, _event} = Registry.record_event(bp, "health", payload)
    :ok
  end

  # ── Instance-API programming (C11 fan-out — PATH-KEYED) ─────────────────────
  #
  # build_usage fetches (1) the dataset LIST, then fans the DOCUMENTS + WEBHOOKS
  # calls out CONCURRENTLY (one per dataset) — so their arrival order is
  # non-deterministic and a FIFO queue can't address them. We program the fake
  # PATH-KEYED instead: each dataset's analytics + webhook URLs are distinct, so a
  # concurrent out-of-order child still gets the right body. The owner-keyed shared
  # store also lets those Task-child requests be recorded where `Fake.requests/0`
  # (on the test process) can see them — token-custody / URL asserts stay real.
  @ds_path "/api/workspaces/default/projects/default/datasets"
  defp analytics_path(slug), do: "/v1/data/analytics/#{slug}"
  defp webhooks_path(slug), do: "/v1/webhooks/#{slug}"

  defp program_instance(datasets) do
    ds_body = Jason.encode!(%{datasets: Enum.map(datasets, fn {s, _d, _w} -> %{slug: s} end)})

    responses =
      Enum.reduce(datasets, %{@ds_path => ok_json(200, ds_body)}, fn {s, d, w}, acc ->
        acc
        |> Map.put(analytics_path(s), ok_json(200, Jason.encode!(%{total_documents: d})))
        |> Map.put(
          webhooks_path(s),
          ok_json(200, Jason.encode!(%{webhooks: List.duplicate(%{id: "wh"}, w)}))
        )
      end)

    Fake.program(responses)
  end

  # A single-production-dataset healthy instance with the given doc/webhook count.
  defp program_simple(docs \\ 0, webhooks \\ 0) do
    program_instance([{"production", docs, webhooks}])
  end

  # Every upstream request must carry the decrypted admin bearer, and the token
  # must never surface in the rendered body.
  defp assert_token_custody(conn) do
    refute conn.resp_body =~ @instance_admin_token

    for req <- Fake.requests() do
      assert {"Authorization", "Bearer " <> @instance_admin_token} =
               List.keyfind(req.headers, "Authorization", 0)
    end
  end

  describe "GET /v1/barkparks/:id/usage — the composed envelope" do
    test "200 with the full meter vocabulary, uniform-shaped" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program_simple(0, 2)

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))

      assert conn.status == 200
      m = meters(conn)

      assert Enum.sort(Map.keys(m)) ==
               Enum.sort(
                 ~w(documents datasets webhooks db_size disk cpu ram req_per_s p95_ms seats instances api_requests bandwidth)
               )

      for {_name, meter} <- m do
        assert Map.has_key?(meter, "value")
        assert is_binary(meter["source"])
        assert Map.has_key?(meter, "over_at")
      end

      # The BILLING quota meter (instances) resolves quota nil for an unsubscribed
      # team — its ceiling is subscription-gated, never invented.
      assert m["instances"]["quota"] == nil
      assert m["instances"]["warn_at"] == nil

      # The physical machine meters (OC23/OC25) carry a FIXED 100/70/90 ceiling —
      # not a billing quota, so it's present regardless of subscription.
      for name <- ~w(cpu ram disk) do
        assert m[name]["quota"] == 100, "#{name} carries the physical 100 ceiling"
        assert m[name]["warn_at"] == 70
        assert m[name]["over_at"] == 90
      end

      # Rate/latency meters carry warn+over thresholds but NO quota (no bar).
      for name <- ~w(req_per_s p95_ms) do
        assert m[name]["quota"] == nil
        assert is_integer(m[name]["warn_at"])
        assert is_integer(m[name]["over_at"])
      end

      # The inventory / flow / seats meters invent nothing.
      for name <- ~w(documents datasets webhooks db_size seats api_requests bandwidth) do
        assert m[name]["quota"] == nil, "#{name} should carry no ceiling"
        assert m[name]["warn_at"] == nil
        assert m[name]["over_at"] == nil
      end
    end

    test "flow meters are always unmetered" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program_simple()

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      m = meters(conn)

      assert m["api_requests"]["value"] == "unmetered"
      assert m["bandwidth"]["value"] == "unmetered"
    end

    test "C11: documents + datasets are real counts from the enumerated instance" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program_simple(137, 0)

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      m = meters(conn)

      # One dataset (production) → datasets count 1, documents total 137.
      assert m["datasets"]["value"] == 1
      assert m["datasets"]["source"] == "instance.datasets"
      assert m["documents"]["value"] == 137
      assert m["documents"]["source"] == "instance.documents"
    end
  end

  describe "seats meter" do
    test "reflects the team's real member count + pending invitations" do
      {owner, team} = user_with_team()
      # A second member and a pending invitation.
      {:ok, _} = Accounts.add_member(team, user_fixture(), "admin")
      {:ok, _} = Accounts.invite_member(team, "invitee@example.com", "member", owner)

      bp = live_barkpark(team)
      program_simple()

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(owner))
      seats = meters(conn)["seats"]

      assert seats["value"] == 2
      assert seats["pending_invitations"] == 1
      assert seats["source"] == "control-plane.team_members"
    end
  end

  describe "telemetry meters" do
    test "db_size + disk come from the latest health beat with its measured_at" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)

      seed_health(bp, %{
        "disk_used_percent" => 57,
        "pg_size_bytes" => 987_654_321
      })

      program_simple()

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      m = meters(conn)

      assert m["db_size"]["value"] == 987_654_321
      assert m["disk"]["value"] == 57
      assert is_binary(m["db_size"]["measured_at"])
      assert m["db_size"]["measured_at"] == m["disk"]["measured_at"]
    end

    test "no health beat yet → db_size/disk unmetered, endpoint still 200" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program_simple()

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      m = meters(conn)

      assert conn.status == 200
      assert m["db_size"]["value"] == "unmetered"
      assert m["disk"]["value"] == "unmetered"
    end
  end

  describe "C11 instance inventory — cross-dataset counts + token custody" do
    test "webhooks + documents SUM across every enumerated dataset" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      # Three datasets with distinct doc + webhook counts.
      program_instance([
        {"production", 100, 2},
        {"staging", 20, 1},
        {"archive", 3, 4}
      ])

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      m = meters(conn)

      assert m["datasets"]["value"] == 3
      # documents = 100 + 20 + 3 ; webhooks = 2 + 1 + 4
      assert m["documents"]["value"] == 123
      assert m["webhooks"]["value"] == 7
      # The cross-dataset webhook label drops the old .production suffix.
      assert m["webhooks"]["source"] == "instance.webhooks"
    end

    test "every upstream call carries the bearer; the token never leaks" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program_instance([{"production", 5, 2}, {"staging", 0, 1}])

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      assert conn.status == 200

      urls = Enum.map(Fake.requests(), & &1.url)

      # 1 dataset-list + 2 analytics + 2 webhook-list calls.
      assert (@instance_url <> "/api/workspaces/default/projects/default/datasets") in urls
      assert (@instance_url <> "/v1/data/analytics/production") in urls
      assert (@instance_url <> "/v1/data/analytics/staging") in urls
      assert (@instance_url <> "/v1/webhooks/production") in urls
      assert (@instance_url <> "/v1/webhooks/staging") in urls

      assert_token_custody(conn)
    end

    test "a true zero across datasets renders real 0s, not the degrade" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program_instance([{"production", 0, 0}])

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      m = meters(conn)

      assert m["documents"]["value"] == 0
      assert m["webhooks"]["value"] == 0
      assert m["datasets"]["value"] == 1
    end

    test "an instance with NO datasets is an honest empty (datasets 0, sums 0)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      # Empty dataset list → no fan-out; sums are a true 0.
      Fake.program(%{@ds_path => ok_json(200, ~s({"datasets":[]}))})

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      m = meters(conn)

      assert m["datasets"]["value"] == 0
      assert m["documents"]["value"] == 0
      assert m["webhooks"]["value"] == 0
    end
  end

  describe "honest degradation — the endpoint never 500s, never blocks" do
    test "an unreachable instance → 200, control-plane meters present, instance meters unmetered" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      seed_health(bp, %{"pg_size_bytes" => 42})
      # The very first call (dataset list) fails → nothing to enumerate.
      Fake.program(%{@ds_path => {:error, {:http_client, :timeout}}})

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))

      assert conn.status == 200
      m = meters(conn)
      # Every instance-sourced meter degraded...
      assert m["datasets"]["value"] == "unmetered"
      assert m["documents"]["value"] == "unmetered"
      assert m["webhooks"]["value"] == "unmetered"
      # ...but control-plane meters STILL returned.
      assert m["seats"]["value"] == 1
      assert m["db_size"]["value"] == 42
      refute conn.resp_body =~ @instance_admin_token
    end

    test "a partial webhook fan-out failure degrades ONLY webhooks (no undercount)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      # Datasets list ok (2), both analytics ok, but the staging webhook call 500s.
      Fake.program(%{
        @ds_path => ok_json(200, ~s({"datasets":[{"slug":"production"},{"slug":"staging"}]})),
        analytics_path("production") => ok_json(200, ~s({"total_documents":10})),
        analytics_path("staging") => ok_json(200, ~s({"total_documents":5})),
        webhooks_path("production") => ok_json(200, ~s({"webhooks":[{"id":"a"}]})),
        webhooks_path("staging") => ok_json(500, ~s({"error":"boom"}))
      })

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      m = meters(conn)

      # webhooks can't be honestly totalled → unmetered...
      assert m["webhooks"]["value"] == "unmetered"
      assert m["webhooks"]["source"] == "instance.webhooks"
      # ...while datasets + documents (which all landed) stay real.
      assert m["datasets"]["value"] == 2
      assert m["documents"]["value"] == 15
    end

    test "a per-dataset 401 names the CREDENTIAL, not \"unknown\"" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)

      # The dataset LIST succeeds — so the failure that degrades documents is a
      # per-DATASET one, the case the fan-out used to squash. staging's analytics
      # read is refused 401: our admin credential was rejected for that dataset.
      Fake.program(%{
        @ds_path => ok_json(200, ~s({"datasets":[{"slug":"production"},{"slug":"staging"}]})),
        analytics_path("production") => ok_json(200, ~s({"total_documents":10})),
        analytics_path("staging") => ok_json(401, ~s({"error":"unauthorized"})),
        webhooks_path("production") => ok_json(200, ~s({"webhooks":[]})),
        webhooks_path("staging") => ok_json(200, ~s({"webhooks":[]}))
      })

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      m = meters(conn)

      # Still no partial sum and no fake zero — the WHOLE meter degrades.
      assert m["documents"]["value"] == "unmetered"

      reason = m["documents"]["unavailable_reason"]

      # RED before the fix: the reduce_while flattened every per-element failure
      # to an unlisted :dataset_fetch_failed, which normalised to "unknown".
      refute reason == "unknown", """
      a per-dataset 401 rendered as the generic "the read failed" — the customer \
      is told nothing they can act on.
      """

      # And it must not be blamed on the network: the box ANSWERED, it said no.
      refute reason == "unreachable", """
      a delivered 401 rendered as "we could not reach your box" — that sends a \
      paying customer to debug their network for a credential problem.
      """

      assert reason == "unauthorized"

      # The datasets meter, which read fine, is untouched by the degrade.
      assert m["datasets"]["value"] == 2
    end

    test "per-dataset 401 / 5xx / bad shape are THREE documents meters, not one" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)

      list = ok_json(200, ~s({"datasets":[{"slug":"production"}]}))
      wh = ok_json(200, ~s({"webhooks":[]}))

      reasons =
        for {expected, analytics} <- [
              {"unauthorized", ok_json(401, ~s({"error":"nope"}))},
              {"instance_error", ok_json(503, ~s({"error":"boom"}))},
              {"bad_shape", ok_json(200, ~s({"not_total":true}))}
            ] do
          Fake.program(%{
            @ds_path => list,
            analytics_path("production") => analytics,
            webhooks_path("production") => wh
          })

          m = meters(call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user)))
          assert m["documents"]["value"] == "unmetered"
          assert m["documents"]["unavailable_reason"] == expected
          m["documents"]["unavailable_reason"]
        end

      assert length(Enum.uniq(reasons)) == 3, """
      three distinct per-dataset failures collapsed to one word — the fan-out is \
      squashing the reason its own per-dataset reads already minted.
      """
    end

    test "a garbage-shaped analytics body degrades documents (no guessed count)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)

      Fake.program(%{
        @ds_path => ok_json(200, ~s({"datasets":[{"slug":"production"}]})),
        analytics_path("production") => ok_json(200, ~s({"not_total":true})),
        webhooks_path("production") => ok_json(200, ~s({"webhooks":[]}))
      })

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      m = meters(conn)

      assert m["documents"]["value"] == "unmetered"
      # datasets + webhooks still landed.
      assert m["datasets"]["value"] == 1
      assert m["webhooks"]["value"] == 0
    end

    test "a garbage-shaped dataset list degrades ALL instance meters, endpoint 200" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      Fake.program(%{@ds_path => ok_json(200, ~s({"not_datasets":true}))})

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      m = meters(conn)

      assert conn.status == 200
      assert m["datasets"]["value"] == "unmetered"
      assert m["documents"]["value"] == "unmetered"
      assert m["webhooks"]["value"] == "unmetered"
    end

    test "too many datasets: the COUNT still lands but the fan-outs degrade" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      # 30 datasets — over the fan-out cap (24). The list call alone reveals the
      # count; documents/webhooks refuse to fan out that wide and degrade.
      slugs = for i <- 1..30, do: %{slug: "ds#{i}"}
      Fake.program(%{@ds_path => ok_json(200, Jason.encode!(%{datasets: slugs}))})

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      m = meters(conn)

      assert m["datasets"]["value"] == 30
      assert m["documents"]["value"] == "unmetered"
      assert m["webhooks"]["value"] == "unmetered"
      # Only the ONE list call was made — no fan-out beyond the cap.
      assert length(Fake.requests()) == 1
    end

    test "a still-provisioning instance (no url) never calls upstream; seats still return" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      Fake.program([])

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))

      assert conn.status == 200
      m = meters(conn)
      assert m["webhooks"]["value"] == "unmetered"
      assert m["documents"]["value"] == "unmetered"
      assert m["datasets"]["value"] == "unmetered"
      assert m["seats"]["value"] == 1
      assert Fake.requests() == []
    end

    test "a pre-feature instance (no admin token) never calls upstream" do
      {user, team} = user_with_team()

      bp =
        team
        |> barkpark_fixture()
        |> Ecto.Changeset.change(url: @instance_url, host: "203.0.113.10")
        |> Repo.update!()

      Fake.program([])
      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))

      assert conn.status == 200
      m = meters(conn)
      assert m["webhooks"]["value"] == "unmetered"
      assert m["datasets"]["value"] == "unmetered"
      assert Fake.requests() == []
    end
  end

  # ── w58-s3: "unreachable" is a claim about the NETWORK ───────────────────────
  #
  # A box that ANSWERED and refused our admin credential is a different fact from
  # a box we never reached, and the meter is what a paying customer reads. These
  # drive the REAL route through the REAL http seam with four upstream shapes and
  # demand four distinct answers — before the fix all four were byte-identical.
  describe "delivered refusals are not unreachability (w58-s3)" do
    # The four upstream shapes, keyed by the word each one should earn.
    defp ds_shapes do
      %{
        "unauthorized" => ok_json(401, ~s({"error":"unauthorized"})),
        "refused" => ok_json(404, "<html>nginx</html>"),
        "instance_error" => ok_json(503, ~s({"error":"upstream down"})),
        "unreachable" => {:error, {:http_client, :econnrefused}}
      }
    end

    defp meters_for(user, bp, ds_response) do
      Fake.program(%{@ds_path => ds_response})

      meters(call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user)))
    end

    test "a delivered 401 and a refused connection produce DIFFERENT meters" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)

      refused_credential = meters_for(user, bp, ok_json(401, ~s({"error":"unauthorized"})))
      never_answered = meters_for(user, bp, {:error, {:http_client, :econnrefused}})

      # Both are still honest about the NUMBER — no fake zero on either side.
      assert refused_credential["datasets"]["value"] == "unmetered"
      assert never_answered["datasets"]["value"] == "unmetered"

      # ...but they no longer tell the customer the same story.
      refute refused_credential["datasets"] == never_answered["datasets"]
      assert refused_credential["datasets"]["unavailable_reason"] == "unauthorized"
      assert never_answered["datasets"]["unavailable_reason"] == "unreachable"
    end

    test "401 / 404 / 5xx / econnrefused / TLS handshake are FOUR answers, not one" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)

      for {expected, response} <- ds_shapes() do
        m = meters_for(user, bp, response)

        # The dataset list is the gate: all three instance meters degrade with
        # the SAME word, because they all failed on that one read.
        for name <- ~w(datasets documents webhooks) do
          assert m[name]["value"] == "unmetered"

          assert m[name]["unavailable_reason"] == expected,
                 "#{name} on a #{expected} upstream said #{inspect(m[name]["unavailable_reason"])}"
        end
      end

      # A TLS handshake failure never delivered a response either — it stays
      # unreachable, and must not be mistaken for the box saying no.
      tls = {:error, {:failed_connect, [{:tls_alert, {:handshake_failure, ~c"bad cert"}}]}}
      assert meters_for(user, bp, tls)["datasets"]["unavailable_reason"] == "unreachable"

      # The whole point, stated once: four upstream shapes, four distinct meters.
      distinct =
        ds_shapes()
        |> Map.values()
        |> Enum.map(&meters_for(user, bp, &1)["datasets"])
        |> Enum.uniq()

      assert length(distinct) == 4
    end

    test "the discrimination SURVIVES record_sample/1 into usage_samples.envelope" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)

      persisted =
        for {_word, response} <- ds_shapes() do
          Fake.program(%{@ds_path => response})
          {:ok, sample} = Usage.record_sample(bp)
          # Re-read: the ROW is the artefact the surfaces serve, not the
          # in-memory map we happened to hand the changeset.
          Repo.get!(Sample, sample.id).envelope["meters"]["datasets"]
        end

      # The stored rows differ too — the sparkline / fleet strip read this map,
      # not the live route, so a live-only fix would still lie from cache.
      assert length(Enum.uniq(persisted)) == 4

      assert Enum.sort(Enum.map(persisted, & &1["unavailable_reason"])) ==
               ~w(instance_error refused unauthorized unreachable)
    end
  end

  describe "instances meter — the fleet's one honest quota (OC11)" do
    # Stamp an active subscription on a team WITHOUT going through the gateway —
    # the row is all `barkpark_limit/1` + `active_subscription/1` read.
    defp subscribe(team, plan) do
      {:ok, sub} =
        %Subscription{}
        |> Subscription.changeset(%{team_id: team.id, plan: plan, status: "active"})
        |> Repo.insert()

      sub
    end

    test "no active subscription → live count present, quota nil (entitlement gate owns the ceiling)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program_simple()

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      instances = meters(conn)["instances"]

      # The one registered instance is counted; no subscription → no quota bar.
      assert instances["value"] == 1
      assert instances["quota"] == nil
      assert instances["warn_at"] == nil
      assert instances["source"] == "control-plane.team_instances"
      assert instances["measured_at"] == nil
    end

    test "an active subscription → quota is the plan ceiling, warn_at derived" do
      {user, team} = user_with_team()
      # supporter → ceiling 3 (default limits). warn_at = min(2, ceil(2.4)=3) = 2.
      subscribe(team, "supporter")
      bp = live_barkpark(team)
      program_simple()

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      instances = meters(conn)["instances"]

      assert instances["value"] == 1
      assert instances["quota"] == 3
      assert instances["warn_at"] == 2
    end

    test "the forever placeholder ceiling (1_000_000) → quota nil, no bar to a million" do
      {user, team} = user_with_team()
      subscribe(team, "forever")
      bp = live_barkpark(team)
      program_simple()

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      instances = meters(conn)["instances"]

      # Counted honestly, but the placeholder ceiling is not an honest wall.
      assert instances["value"] == 1
      assert instances["quota"] == nil
      assert instances["warn_at"] == nil
    end

    test "counts EVERY managed instance the team holds, not just the one in the path" do
      {user, team} = user_with_team()
      subscribe(team, "support_plus")
      bp = live_barkpark(team)
      # Two more registered (still-provisioning) instances the team holds.
      _second = barkpark_fixture(team)
      _third = barkpark_fixture(team)
      program_simple()

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      instances = meters(conn)["instances"]

      assert instances["value"] == 3
      # support_plus → ceiling 10; warn_at = min(9, ceil(8.0)=8) = 8.
      assert instances["quota"] == 10
      assert instances["warn_at"] == 8
    end
  end

  describe "concurrent fan-out — cross-process capture + aggregate deadline" do
    test "fan-out requests run in Task children yet are served + captured (RED under a process-dict fake)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      # 3 datasets → 1 list + 3 analytics + 3 webhook calls = 7 upstream requests;
      # the six fan-out calls are made in `Task.async_stream` CHILD processes. A
      # process-dictionary fake would (a) serve those children the empty-queue
      # default, so the sums could never be real, and (b) record their requests in
      # dead workers' dicts, invisible here. The owner-keyed store resolves each
      # child's owner via `$callers`, so both survive.
      program_instance([{"a", 1, 1}, {"b", 2, 2}, {"c", 3, 3}])

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      m = meters(conn)

      # Real cross-dataset sums only land if the child requests reached the fake
      # AND were served the programmed bodies — impossible under a process-dict fake.
      assert m["datasets"]["value"] == 3
      assert m["documents"]["value"] == 6
      assert m["webhooks"]["value"] == 6

      # All seven requests — including the six off-process fan-out calls — are
      # visible to the test, each carrying the bearer, none leaking it.
      assert length(Fake.requests()) == 7
      assert_token_custody(conn)
    end

    test "a slow many-dataset box degrades the fanned meters within the budget, not ~98s" do
      # Drive the aggregate wall-clock budget WAY down so the test is fast while
      # still proving the deadline bounds a genuinely slow fan-out. (Global env, but
      # every OTHER usage test's fake answers instantly, so a 500ms budget never
      # bites them.)
      prev = Application.get_env(:barkpark_cloud, :usage_fanout_budget_ms)
      Application.put_env(:barkpark_cloud, :usage_fanout_budget_ms, 500)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:barkpark_cloud, :usage_fanout_budget_ms, prev),
          else: Application.delete_env(:barkpark_cloud, :usage_fanout_budget_ms)
      end)

      {user, team} = user_with_team()
      bp = live_barkpark(team)

      # The LIST answers instantly (so the COUNT lands), but EVERY per-dataset
      # inventory call sleeps 8s — far past the 500ms shared budget. Sequentially
      # that is 6 × 8s = 48s; the aggregate deadline must cut it to ~the budget.
      slow = fn body -> {:delay, 8_000, ok_json(200, body)} end

      Fake.program(%{
        @ds_path => ok_json(200, ~s({"datasets":[{"slug":"a"},{"slug":"b"},{"slug":"c"}]})),
        analytics_path("a") => slow.(~s({"total_documents":1})),
        analytics_path("b") => slow.(~s({"total_documents":1})),
        analytics_path("c") => slow.(~s({"total_documents":1})),
        webhooks_path("a") => slow.(~s({"webhooks":[]})),
        webhooks_path("b") => slow.(~s({"webhooks":[]})),
        webhooks_path("c") => slow.(~s({"webhooks":[]}))
      })

      started = System.monotonic_time(:millisecond)
      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      elapsed = System.monotonic_time(:millisecond) - started

      assert conn.status == 200
      m = meters(conn)

      # The list landed → the datasets COUNT is real...
      assert m["datasets"]["value"] == 3
      # ...but the fanned meters could not be totalled inside the shared budget, so
      # they degrade honestly (never a partial/fake number, never a 500).
      assert m["documents"]["value"] == "unmetered"
      assert m["webhooks"]["value"] == "unmetered"
      # A control-plane meter still returns.
      assert m["seats"]["value"] == 1

      # The whole call returned in ~the aggregate budget, NOT 6 × 8s. Generous
      # ceiling to stay green on a loaded CI while still proving the deadline bit.
      assert elapsed < 4_000,
             "usage fan-out took #{elapsed}ms — the aggregate deadline did not bound it"
    end
  end

  describe "auth + team-scope fail-closed" do
    test "no auth → 401" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)
      Fake.program([])

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage")
      assert conn.status == 401
      assert Fake.requests() == []
    end

    test "wrong-team / nonexistent / malformed ids are the SAME 404, upstream never called" do
      {_owner_b, team_b} = user_with_team()
      bp_b = live_barkpark(team_b)

      {user_a, _team_a} = user_with_team()
      token_a = session_token(user_a)
      Fake.program([])

      wrong_team = call(:get, "/v1/barkparks/#{bp_b.id}/usage", token: token_a)
      nonexistent = call(:get, "/v1/barkparks/#{Ecto.UUID.generate()}/usage", token: token_a)
      malformed = call(:get, "/v1/barkparks/not-a-uuid/usage", token: token_a)

      assert wrong_team.status == 404
      assert nonexistent.status == 404
      assert malformed.status == 404

      assert Jason.decode!(wrong_team.resp_body) == Jason.decode!(nonexistent.resp_body)
      assert Jason.decode!(nonexistent.resp_body) == Jason.decode!(malformed.resp_body)

      assert Fake.requests() == []
    end
  end

  # ── GET /v1/barkparks/:id/usage/history — the sparkline series (wave 4) ───────

  @meter_names ~w(documents datasets webhooks db_size disk cpu ram req_per_s p95_ms seats instances api_requests bandwidth)

  defp seed_sample(bp, envelope, measured_at) do
    {:ok, sample} =
      %Sample{}
      |> Sample.changeset(%{barkpark_id: bp.id, envelope: envelope, measured_at: measured_at})
      |> Repo.insert()

    sample
  end

  defp history(conn), do: Jason.decode!(conn.resp_body)

  # A fake programmed to blow up on ANY request — history is a PURE cached read.
  defp forbid_instance_http do
    Fake.program(%{"/__any__" => {:error, {:http_client, :should_never_be_called}}})
  end

  describe "GET /v1/barkparks/:id/usage/history — the pure cached series" do
    test "a never-sampled instance is a normal 200 with all-nil series, ZERO instance HTTP" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      forbid_instance_http()

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage/history", token: session_token(user))

      assert conn.status == 200
      h = history(conn)

      assert h["ok"] == true
      assert is_binary(h["collected_at"])
      assert h["window_days"] == 14
      assert h["points"] == 56
      assert h["instance"]["id"] == bp.id
      assert h["instance"]["name"] == bp.name
      assert h["instance"]["slug"] == bp.slug
      assert h["instance"]["host"] == bp.host

      # Every meter's series is present, full-length, and honestly all-nil.
      assert Enum.sort(Map.keys(h["series"])) == Enum.sort(@meter_names)

      for name <- @meter_names do
        series = h["series"][name]
        assert length(series) == 56
        assert Enum.all?(series, &(&1["value"] == nil)), "#{name} should be all-nil, never a zero"
        # The x-axis is a real oldest→newest RFC3339 ladder.
        ats = Enum.map(series, & &1["at"])
        assert Enum.all?(ats, &is_binary/1)
        assert ats == Enum.sort(ats)
      end

      assert Fake.requests() == []
    end

    test "a recent sample lands in the newest bucket; numeric values plot, unmetered stays a nil gap" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      forbid_instance_http()

      # documents is a real 42; seats a real 3; the rest degrade to "unmetered".
      envelope = Usage.compose(%{documents: {:ok, 42}, seats: 3})
      seed_sample(bp, envelope, DateTime.add(DateTime.utc_now(), -60, :second))

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage/history", token: session_token(user))
      assert conn.status == 200
      series = history(conn)["series"]

      # Exactly one populated point (the newest bucket) for a metered meter.
      docs = series["documents"]
      assert List.last(docs)["value"] == 42
      assert Enum.count(docs, &(&1["value"] != nil)) == 1
      assert List.last(series["seats"])["value"] == 3

      # An "unmetered" meter in the sample is a nil GAP, never a fake zero.
      assert List.last(series["webhooks"])["value"] == nil
      assert Enum.all?(series["webhooks"], &(&1["value"] == nil))
      # Flow meters are unmetered by construction → nil.
      assert Enum.all?(series["api_requests"], &(&1["value"] == nil))
    end

    test "the LATEST sample in a bucket wins" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      forbid_instance_http()

      now = DateTime.utc_now()
      # Two samples minutes apart → same (6h) bucket; the newer documents count wins.
      seed_sample(bp, Usage.compose(%{documents: {:ok, 5}}), DateTime.add(now, -180, :second))
      seed_sample(bp, Usage.compose(%{documents: {:ok, 9}}), DateTime.add(now, -60, :second))

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage/history", token: session_token(user))
      docs = history(conn)["series"]["documents"]

      assert List.last(docs)["value"] == 9
      assert Enum.count(docs, &(&1["value"] != nil)) == 1
    end

    test "points is clamped via the shared parse_limit idiom" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      forbid_instance_http()

      conn =
        call(:get, "/v1/barkparks/#{bp.id}/usage/history?points=10", token: session_token(user))

      h = history(conn)
      assert h["points"] == 10
      assert length(h["series"]["documents"]) == 10

      # Over the cap → clamped to 200; garbage / non-positive → the 56 default.
      capped =
        call(:get, "/v1/barkparks/#{bp.id}/usage/history?points=9999", token: session_token(user))

      assert history(capped)["points"] == 200

      junk =
        call(:get, "/v1/barkparks/#{bp.id}/usage/history?points=abc", token: session_token(user))

      assert history(junk)["points"] == 56
    end

    test "a sample OLDER than the 14-day window never appears in the series" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      forbid_instance_http()

      # 15 days old — outside the window; must be excluded entirely.
      seed_sample(
        bp,
        Usage.compose(%{documents: {:ok, 7}}),
        DateTime.add(DateTime.utc_now(), -15 * 86_400, :second)
      )

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage/history", token: session_token(user))
      docs = history(conn)["series"]["documents"]
      assert Enum.all?(docs, &(&1["value"] == nil))
    end
  end

  describe "GET /v1/barkparks/:id/usage/history — auth + team-scope fail-closed" do
    test "no auth → 401, no read" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage/history")
      assert conn.status == 401
    end

    test "wrong-team / nonexistent / malformed ids are the SAME 404" do
      {_owner_b, team_b} = user_with_team()
      bp_b = live_barkpark(team_b)

      {user_a, _team_a} = user_with_team()
      token_a = session_token(user_a)

      wrong_team = call(:get, "/v1/barkparks/#{bp_b.id}/usage/history", token: token_a)

      nonexistent =
        call(:get, "/v1/barkparks/#{Ecto.UUID.generate()}/usage/history", token: token_a)

      malformed = call(:get, "/v1/barkparks/not-a-uuid/usage/history", token: token_a)

      assert wrong_team.status == 404
      assert nonexistent.status == 404
      assert malformed.status == 404
      assert Jason.decode!(wrong_team.resp_body) == Jason.decode!(nonexistent.resp_body)
      assert Jason.decode!(nonexistent.resp_body) == Jason.decode!(malformed.resp_body)
    end
  end
end
