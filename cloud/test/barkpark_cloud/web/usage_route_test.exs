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

  # ── Instance-API programming (C11 fan-out order) ────────────────────────────
  #
  # build_usage fires, in order: (1) the dataset LIST, then (2) the DOCUMENTS
  # analytics fan-out (one call per dataset, in list order), then (3) the
  # WEBHOOKS fan-out (one per dataset). `program_instance/1` queues exactly that
  # sequence from a list of `{slug, doc_count, webhook_count}`.
  defp program_instance(datasets) do
    ds_body = Jason.encode!(%{datasets: Enum.map(datasets, fn {s, _d, _w} -> %{slug: s} end)})
    doc_resps = for {_s, d, _w} <- datasets, do: ok_json(200, Jason.encode!(%{total_documents: d}))

    wh_resps =
      for {_s, _d, w} <- datasets,
          do: ok_json(200, Jason.encode!(%{webhooks: List.duplicate(%{id: "wh"}, w)}))

    Fake.program([ok_json(200, ds_body) | doc_resps ++ wh_resps])
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
      assert @instance_url <> "/api/workspaces/default/projects/default/datasets" in urls
      assert @instance_url <> "/v1/data/analytics/production" in urls
      assert @instance_url <> "/v1/data/analytics/staging" in urls
      assert @instance_url <> "/v1/webhooks/production" in urls
      assert @instance_url <> "/v1/webhooks/staging" in urls

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
      Fake.program([ok_json(200, ~s({"datasets":[]}))])

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
      Fake.program([{:error, {:http_client, :timeout}}])

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
      # Datasets list ok (2), both analytics ok, but the SECOND webhook call 500s.
      Fake.program([
        ok_json(200, ~s({"datasets":[{"slug":"production"},{"slug":"staging"}]})),
        ok_json(200, ~s({"total_documents":10})),
        ok_json(200, ~s({"total_documents":5})),
        ok_json(200, ~s({"webhooks":[{"id":"a"}]})),
        ok_json(500, ~s({"error":"boom"}))
      ])

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

      Fake.program([
        ok_json(200, ~s({"datasets":[{"slug":"production"}]})),
        ok_json(200, ~s({"not_total":true})),
        ok_json(200, ~s({"webhooks":[]}))
      ])

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
      Fake.program([ok_json(200, ~s({"not_datasets":true}))])

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
      Fake.program([ok_json(200, Jason.encode!(%{datasets: slugs}))])

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
