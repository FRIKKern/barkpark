defmodule BarkparkWeb.Plugs.IdempotencyTest do
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias BarkparkWeb.Plugs.Idempotency, as: Plug
  alias Barkpark.{Auth, Idempotency, Repo}
  alias Barkpark.Repo.IdempotencyStore

  setup do
    {:ok, token} = Auth.create_token("idem-test-token", "test", "dev", ["read", "write"])
    %{token: token}
  end

  defp build_mutate_conn(token, key \\ nil) do
    conn =
      build_conn(:post, "/v1/data/mutate/production", "")
      |> assign(:api_token, token)

    if key, do: put_req_header(conn, "idempotency-key", key), else: conn
  end

  test "passes through when no Idempotency-Key header is present", %{token: token} do
    conn = build_mutate_conn(token)
    result = Plug.call(conn, Plug.init([]))
    refute result.halted
    assert result.resp_body == nil
  end

  test "passes through on non-mutating methods", %{token: token} do
    conn =
      build_conn(:get, "/v1/data/query/production/post", "")
      |> assign(:api_token, token)
      |> put_req_header("idempotency-key", "k")

    result = Plug.call(conn, Plug.init([]))
    refute result.halted
  end

  test "first request stores the response; second replays it", %{token: token} do
    conn1 = build_mutate_conn(token, "key-1")
    c1 = Plug.call(conn1, Plug.init([]))
    refute c1.halted

    c1_sent =
      c1
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s({"transactionId":"tx1","results":[]}))

    assert c1_sent.status == 200
    assert c1_sent.resp_body == ~s({"transactionId":"tx1","results":[]})

    # Second call with same key replays
    conn2 = build_mutate_conn(token, "key-1")
    c2 = Plug.call(conn2, Plug.init([]))

    assert c2.halted
    assert c2.status == 200
    assert c2.resp_body == ~s({"transactionId":"tx1","results":[]})

    assert [{"idempotency-replay", "true"}] =
             Enum.filter(c2.resp_headers, fn {k, _} -> k == "idempotency-replay" end)
  end

  test "does not store 5xx responses", %{token: token} do
    conn = build_mutate_conn(token, "key-5xx")
    c = Plug.call(conn, Plug.init([]))
    refute c.halted

    _ = c |> send_resp(500, ~s({"error":"boom"}))

    hash = Idempotency.hash_key("key-5xx", token.id, "POST", "/v1/data/mutate/production")
    assert :miss = Idempotency.lookup(hash)
  end

  test "halts with 401 when Idempotency-Key is sent without an api_token" do
    conn =
      build_conn(:post, "/v1/data/mutate/production", "")
      |> put_req_header("idempotency-key", "k")

    c = Plug.call(conn, Plug.init([]))
    assert c.halted
    assert c.status == 401
  end

  # PROTECTIVE TEST for the P1 concurrency gap (task-16803b3f0eb244bf).
  #
  # Two simultaneous requests with the SAME Idempotency-Key race at the plug.
  # Each non-halted (claimed) conn represents the handler executing its
  # non-idempotent mutation ({"inc":{"count":1}}). The guarantee: EXACTLY ONE
  # executes; the other is halted 409 idempotency_key_in_use and applies nothing.
  #
  # RED before the fix: the old lookup->:miss path had no claim step, so BOTH
  # concurrent calls returned :miss (non-halted) -> `executed == 2` -> the patch
  # double-applies (count == start+2). GREEN after: `executed == 1`.
  test "concurrent duplicate requests execute the mutation exactly once", %{token: token} do
    key = "concurrent-key"
    body = ~s({"transactionId":"tx","results":[]})

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          conn = build_mutate_conn(token, key)
          c = Plug.call(conn, Plug.init([]))

          if c.halted do
            {:halted, c.status}
          else
            # The plug let us through: simulate the handler applying the mutation
            # and forming its response (fires register_before_send -> caches it).
            _ =
              c
              |> put_resp_content_type("application/json")
              |> send_resp(200, body)

            :executed
          end
        end)
      end

    results = Task.await_many(tasks, 5_000)

    executed = Enum.count(results, &(&1 == :executed))
    halted = Enum.filter(results, &match?({:halted, _}, &1))

    # THE guarantee: exactly one handler ran, so {"inc":{"count":1}} applied once
    # (count == start+1, not start+2). Pre-fix this is 2.
    assert executed == 1, "expected exactly ONE execution, got #{executed}: #{inspect(results)}"

    # The loser never executed: it either 409'd (both truly in-flight) or replayed
    # the winner's already-cached response (winner finished first). Both are
    # "exactly once" — a re-execution (another :executed) is the only failure.
    assert [{:halted, status}] = halted
    assert status in [200, 409], "loser should replay(200) or 409, got #{status}"
  end

  test "concurrent loser gets 409 idempotency_key_in_use (never re-executes)", %{token: token} do
    # First request claims and is still in-flight (no response sent yet).
    conn1 = build_mutate_conn(token, "inflight-key")
    c1 = Plug.call(conn1, Plug.init([]))
    refute c1.halted

    # A second concurrent request must be refused, not allowed to execute.
    conn2 = build_mutate_conn(token, "inflight-key")
    c2 = Plug.call(conn2, Plug.init([]))

    assert c2.halted
    assert c2.status == 409
    assert %{"error" => %{"code" => "idempotency_key_in_use"}} = json_body(c2)
  end

  test "a 5xx releases the claim so a retry can re-claim", %{token: token} do
    conn = build_mutate_conn(token, "key-5xx-release")
    c = Plug.call(conn, Plug.init([]))
    refute c.halted

    _ = c |> send_resp(500, ~s({"error":"boom"}))

    # Claim released -> a retry is admitted (not halted with 409).
    retry = build_mutate_conn(token, "key-5xx-release")
    r = Plug.call(retry, Plug.init([]))
    refute r.halted
  end

  test "a stale (crashed) pending reservation is reclaimed, not wedged", %{token: token} do
    hash = Idempotency.hash_key("stale-key", token.id, "POST", "/v1/data/mutate/production")

    # Simulate a crashed reservation: the plug's own pending row (its scope),
    # aged past the pending TTL.
    refute Plug.call(build_mutate_conn(token, "stale-key"), Plug.init([])).halted
    old = DateTime.add(DateTime.utc_now(), -1 * (pending_ttl() + 5), :second)

    {1, _} =
      Repo.update_all(from(k in IdempotencyStore.Key, where: k.key_hash == ^hash),
        set: [inserted_at: old]
      )

    # A fresh request reclaims the stale reservation instead of 409-ing forever.
    conn = build_mutate_conn(token, "stale-key")
    c = Plug.call(conn, Plug.init([]))
    refute c.halted
  end

  test "a FRESH pending reservation is NOT reclaimed (still 409)", %{token: token} do
    hash = Idempotency.hash_key("fresh-pending", token.id, "POST", "/v1/data/mutate/production")

    # The plug's own pending row (its scope), inserted just now.
    refute Plug.call(build_mutate_conn(token, "fresh-pending"), Plug.init([])).halted
    assert %IdempotencyStore.Key{state: "pending"} = Repo.get(IdempotencyStore.Key, hash)

    conn = build_mutate_conn(token, "fresh-pending")
    c = Plug.call(conn, Plug.init([]))
    assert c.halted
    assert c.status == 409
  end

  # task-a87c7261c1aa63c2: an unbound mount stored the bare "mutation" scope, the
  # row #26786's transition rule existed for. No mount may store one again.
  test "a mount configured with only scope \"mutation\" binds the request", %{token: token} do
    opts = Plug.init(scope: "mutation")

    first = token |> build_mutate_conn("bound-key") |> with_params([1]) |> Plug.call(opts)
    refute first.halted
    _ = first |> put_resp_content_type("application/json") |> send_resp(200, ~s({"n":1}))

    second = token |> build_mutate_conn("bound-key") |> with_params([2]) |> Plug.call(opts)

    assert second.halted
    assert second.status == 422, "#{second.status} #{second.resp_body}"
    assert %{"error" => %{"code" => "idempotency_key_reused"}} = json_body(second)
  end

  test "Plug.init/1 refuses an unbound mount" do
    assert_raise ArgumentError, ~r/bind_request/, fn -> Plug.init(bind_request: false) end
  end

  defp with_params(conn, mutations) do
    params = %{"mutations" => mutations}
    %{conn | params: params, body_params: params, path_params: %{}}
  end

  defp pending_ttl do
    Application.get_env(:barkpark, :idempotency, [])
    |> Keyword.get(:pending_ttl_seconds, 60)
  end

  defp json_body(conn) do
    conn.resp_body |> Jason.decode!()
  end
end
