defmodule BarkparkCloud.WarmPoolTest do
  @moduledoc """
  The warm-pool claim store (dwb-10) — pre-baked boxes the Go worker registers,
  claims (assign / retire), and deletes. Two halves:

    * the Registry context — register (idempotent) / claim (race-safe, ready-only,
      nil-when-empty) / claim-for-retire (separate status, never grabs an assigned
      box) / count / delete / stale-reap.
    * the /v1/internal/warm-servers/* HTTP endpoints — reachable ONLY with the
      shared WORKER token, rejecting user tokens and no token.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.WarmServer
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @worker_token "worker-token-test-fixed"

  ## Fixtures (mirrors ProvisioningTest)

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

  # Force a strictly-earlier inserted_at so "oldest" ordering is unambiguous.
  defp backdate(name, ts) do
    from(w in WarmServer, where: w.name == ^name) |> Repo.update_all(set: [inserted_at: ts])
  end

  ## Context: register / claim / retire / count / delete / reap

  describe "register_warm_server/2" do
    test "inserts a ready row" do
      assert {:ok, %WarmServer{} = ws} = Registry.register_warm_server("warm-abc123", "10.0.0.7")
      assert ws.status == "ready"
      assert ws.name == "warm-abc123"
      assert ws.ip == "10.0.0.7"
      assert Registry.count_ready_warm_servers() == 1
    end

    test "is IDEMPOTENT on name — a retried register never duplicates the row" do
      assert {:ok, _} = Registry.register_warm_server("warm-dup", "10.0.0.1")
      assert {:ok, _} = Registry.register_warm_server("warm-dup", "10.0.0.1")
      assert Repo.aggregate(from(w in WarmServer, where: w.name == "warm-dup"), :count) == 1
      assert Registry.count_ready_warm_servers() == 1
    end
  end

  describe "claim_warm_server/1" do
    test "claims the OLDEST ready box and flips it to claimed" do
      {:ok, _} = Registry.register_warm_server("warm-old", "10.0.0.1")
      backdate("warm-old", ~U[2020-01-01 00:00:00.000000Z])
      {:ok, _} = Registry.register_warm_server("warm-new", "10.0.0.2")

      assert %WarmServer{} = ws = Registry.claim_warm_server("ct-1")
      assert ws.name == "warm-old"
      assert ws.status == "claimed"
      assert ws.claim_token == "ct-1"
      assert ws.claimed_at != nil
      # Only warm-new stays ready.
      assert Registry.count_ready_warm_servers() == 1
    end

    test "returns nil when the pool is empty (the go-live's fall-through signal)" do
      assert Registry.claim_warm_server("ct-empty") == nil
    end

    test "race-safe: N concurrent claimers over N ready boxes each get a DISTINCT box" do
      n = 8

      for i <- 1..n do
        {:ok, _} = Registry.register_warm_server("warm-race-#{i}", "10.0.0.#{i}")
      end

      parent = self()

      tasks =
        for i <- 1..n do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())

            case Registry.claim_warm_server("ct-race-#{i}") do
              %WarmServer{} = ws -> ws.name
              nil -> nil
            end
          end)
        end

      claimed = tasks |> Enum.map(&Task.await/1) |> Enum.reject(&is_nil/1)

      # No double-claim: every claimed box name is distinct.
      assert length(claimed) == length(Enum.uniq(claimed))
      # Every box ended up claimed exactly once; none left ready.
      assert Repo.aggregate(from(w in WarmServer, where: w.status == "claimed"), :count) == n
      assert Registry.count_ready_warm_servers() == 0
    end
  end

  describe "claim_warm_server_for_retire/1" do
    test "flips a ready box to retiring and NEVER grabs an already-claimed box" do
      {:ok, _} = Registry.register_warm_server("warm-ready", "10.0.0.1")
      {:ok, _} = Registry.register_warm_server("warm-taken", "10.0.0.2")
      # Take one for an assign; retire must not touch it.
      _ = Registry.claim_warm_server("ct-assign")

      # (claim grabbed the oldest ready; whichever it was, one ready remains.)
      assert %WarmServer{status: "retiring"} =
               retired = Registry.claim_warm_server_for_retire("ct-r")

      # The retired box was NOT the one already claimed.
      claimed_names =
        from(w in WarmServer, where: w.status == "claimed", select: w.name) |> Repo.all()

      refute retired.name in claimed_names
      # Nothing ready left, so a second retire finds nothing.
      assert Registry.claim_warm_server_for_retire("ct-r2") == nil
    end
  end

  describe "delete_warm_server/1" do
    test "removes the row and is idempotent on an absent name" do
      {:ok, _} = Registry.register_warm_server("warm-del", "10.0.0.1")
      assert {:ok, 1} = Registry.delete_warm_server("warm-del")
      assert {:ok, 0} = Registry.delete_warm_server("warm-del")
      assert Registry.count_ready_warm_servers() == 0
    end
  end

  # claim-fence (bp-c55): a warm box that was claimed, reaped as stale, then re-
  # registered + re-claimed under the SAME name must NOT be torn down by the first
  # (now-stale) worker's delete. When the worker echoes the claim_token it holds,
  # the delete only removes the row while the token still matches. A token-LESS
  # delete keeps today's delete-by-name (Stage 1 compat for the deployed Go fleet).
  describe "claim-fence — delete_warm_server (bp-c55)" do
    test "a stale-token delete is a no-op; the live claimant's row survives" do
      {:ok, _} = Registry.register_warm_server("warm-fence", "10.0.0.1")
      assert %WarmServer{claim_token: "tok-A"} = Registry.claim_warm_server("tok-A")

      # Age the claim + reap it (the crashed-mid-consume path).
      old =
        DateTime.utc_now()
        |> DateTime.add(-(Registry.warm_stale_after_seconds() + 60), :second)
        |> DateTime.truncate(:microsecond)

      from(w in WarmServer, where: w.name == "warm-fence")
      |> Repo.update_all(set: [claimed_at: old])

      assert Registry.reap_stale_warm_claims() == 1

      # A fresh box lands under the SAME name and is claimed by worker B.
      {:ok, _} = Registry.register_warm_server("warm-fence", "10.0.0.2")
      assert %WarmServer{claim_token: "tok-B"} = Registry.claim_warm_server("tok-B")

      # The stale worker A's delete (its OLD token) is a fenced no-op — B's row lives.
      assert {:ok, 0} = Registry.delete_warm_server("warm-fence", "tok-A")
      assert Repo.aggregate(from(w in WarmServer, where: w.name == "warm-fence"), :count) == 1

      # B's own token deletes it.
      assert {:ok, 1} = Registry.delete_warm_server("warm-fence", "tok-B")
    end

    test "a token-LESS delete still removes the row (Stage 1 compat)" do
      {:ok, _} = Registry.register_warm_server("warm-compat", "10.0.0.1")
      assert %WarmServer{} = Registry.claim_warm_server("tok-x")
      assert {:ok, 1} = Registry.delete_warm_server("warm-compat")
    end
  end

  describe "reap_stale_warm_claims/0" do
    test "deletes stale claimed/retiring rows but leaves fresh + ready ones" do
      {:ok, _} = Registry.register_warm_server("warm-keep-ready", "10.0.0.1")
      {:ok, _} = Registry.register_warm_server("warm-fresh-claim", "10.0.0.2")
      {:ok, _} = Registry.register_warm_server("warm-stale-claim", "10.0.0.3")
      {:ok, _} = Registry.register_warm_server("warm-stale-retire", "10.0.0.4")

      now = DateTime.truncate(DateTime.utc_now(), :microsecond)
      old = DateTime.add(now, -(Registry.warm_stale_after_seconds() + 60), :second)

      from(w in WarmServer, where: w.name == "warm-fresh-claim")
      |> Repo.update_all(set: [status: "claimed", claimed_at: now])

      from(w in WarmServer, where: w.name == "warm-stale-claim")
      |> Repo.update_all(set: [status: "claimed", claimed_at: old])

      from(w in WarmServer, where: w.name == "warm-stale-retire")
      |> Repo.update_all(set: [status: "retiring", claimed_at: old])

      assert Registry.reap_stale_warm_claims() == 2

      remaining = from(w in WarmServer, select: w.name) |> Repo.all() |> Enum.sort()
      assert remaining == ["warm-fresh-claim", "warm-keep-ready"]
    end
  end

  ## HTTP: worker-token auth + the queue endpoints

  describe "warm-server endpoints require the worker token" do
    test "401 without a token, and with a user token" do
      {user, _team} = user_with_team()
      {:ok, user_tok} = Accounts.create_user_session_token(user)

      for {method, path} <- [
            {"POST", "/v1/internal/warm-servers/claim"},
            {"POST", "/v1/internal/warm-servers/claim-retire"},
            {"GET", "/v1/internal/warm-servers/count"}
          ] do
        assert call(method, path, nil, nil).status == 401
        assert call(method, path, nil, user_tok).status == 401
      end

      assert call("POST", "/v1/internal/warm-servers", %{name: "x", ip: "1.2.3.4"}, nil).status ==
               401
    end
  end

  describe "warm-server HTTP happy paths (worker token)" do
    test "register → count → claim → delete round-trip" do
      reg =
        call(
          "POST",
          "/v1/internal/warm-servers",
          %{name: "warm-h1", ip: "10.9.9.9"},
          @worker_token
        )

      assert reg.status == 201
      assert json_body(reg) == %{"ok" => true}

      cnt = call("GET", "/v1/internal/warm-servers/count", nil, @worker_token)
      assert cnt.status == 200
      assert json_body(cnt) == %{"ready" => 1}

      claim = call("POST", "/v1/internal/warm-servers/claim", nil, @worker_token)
      assert claim.status == 200
      claim_body = json_body(claim)
      assert claim_body["name"] == "warm-h1"
      assert claim_body["ip"] == "10.9.9.9"
      # claim-fence (bp-c55): the response now carries the claim_token the worker
      # echoes back on DELETE.
      assert is_binary(claim_body["claim_token"]) and claim_body["claim_token"] != ""

      # Pool now empty → 204.
      assert call("POST", "/v1/internal/warm-servers/claim", nil, @worker_token).status == 204

      del = call("DELETE", "/v1/internal/warm-servers/warm-h1", nil, @worker_token)
      assert del.status == 200
      assert json_body(del) == %{"ok" => true}
    end

    test "register rejects a missing name with 422" do
      resp = call("POST", "/v1/internal/warm-servers", %{ip: "1.2.3.4"}, @worker_token)
      assert resp.status == 422
      assert json_body(resp) == %{"error" => "name_required"}
    end

    test "claim-retire pops a ready box, 204 when none" do
      assert call(
               "POST",
               "/v1/internal/warm-servers",
               %{name: "warm-r1", ip: "10.1.1.1"},
               @worker_token
             ).status ==
               201

      retire = call("POST", "/v1/internal/warm-servers/claim-retire", nil, @worker_token)
      assert retire.status == 200
      retire_body = json_body(retire)
      assert retire_body["name"] == "warm-r1"
      assert retire_body["ip"] == "10.1.1.1"
      assert is_binary(retire_body["claim_token"]) and retire_body["claim_token"] != ""

      assert call("POST", "/v1/internal/warm-servers/claim-retire", nil, @worker_token).status ==
               204
    end
  end
end
