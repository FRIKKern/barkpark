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
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient, as: Fake
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
                 ~w(documents datasets webhooks db_size disk seats api_requests bandwidth)
               )

      for {_name, meter} <- m do
        assert Map.has_key?(meter, "value")
        assert meter["quota"] == nil
        assert meter["warn_at"] == nil
        assert is_binary(meter["source"])
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
end
