defmodule BarkparkWeb.SearchIntelTest do
  use BarkparkWeb.ConnCase, async: true

  alias BarkparkWeb.SearchIntel

  # ── actor_key/1: the header may SUBDIVIDE an actor, never SELECT one ──────
  # Regression for stw10-backlog-suggestions-recent-scope: `x-bp-search-client`
  # was consulted BEFORE the token, so the caller chose the identity whose
  # `recent` bucket it read.

  test "actor_key/1 keys on the token even when a foreign client header is spoofed" do
    victim = build_conn() |> put_req_header("x-bp-search-client", "victim-browser-uuid")

    attacker =
      build_conn()
      |> assign(:api_token, %{id: "tok-attacker"})
      |> put_req_header("x-bp-search-client", "victim-browser-uuid")

    key = SearchIntel.actor_key(attacker)

    # The token owns the namespace; the spoofed header only subdivides INSIDE it.
    assert key == "token:tok-attacker:victim-browser-uuid"
    assert String.starts_with?(key, "token:tok-attacker")
    # ...and it is NOT the victim's bucket, which is what the old ordering returned.
    refute key == SearchIntel.actor_key(victim)
    refute key == "client:victim-browser-uuid"
  end

  test "actor_key/1 gives a token holder with no header the plain token bucket" do
    conn = build_conn() |> assign(:api_token, %{id: "tok-1"})

    assert SearchIntel.actor_key(conn) == "token:tok-1"
  end

  test "actor_key/1 gives two different client headers two different anonymous buckets" do
    a = build_conn() |> put_req_header("x-bp-search-client", "browser-a")
    b = build_conn() |> put_req_header("x-bp-search-client", "browser-b")

    key_a = SearchIntel.actor_key(a)
    key_b = SearchIntel.actor_key(b)

    assert key_a == "client:global:browser-a"
    assert key_b == "client:global:browser-b"
    refute key_a == key_b
  end

  test "actor_key/1 returns the shared \"anon\" bucket with no header and no token" do
    # `Barkpark.Search.Intelligence.recent_queries/6` answers "anon" with [].
    assert SearchIntel.actor_key(build_conn()) == "anon"
  end

  test "actor_key/1 namespaces the anonymous bucket by the server-resolved workspace" do
    ws_a =
      build_conn()
      |> assign(:current_workspace, %{id: "ws-a"})
      |> put_req_header("x-bp-search-client", "same-browser-id")

    ws_b =
      build_conn()
      |> assign(:current_workspace, %{id: "ws-b"})
      |> put_req_header("x-bp-search-client", "same-browser-id")

    assert SearchIntel.actor_key(ws_a) == "client:ws-a:same-browser-id"
    assert SearchIntel.actor_key(ws_b) == "client:ws-b:same-browser-id"
    refute SearchIntel.actor_key(ws_a) == SearchIntel.actor_key(ws_b)
  end

  test "actor_key/1 lets no header carry a tokenless caller into a token namespace" do
    holder =
      build_conn()
      |> assign(:api_token, %{id: "tok-1"})
      |> put_req_header("x-bp-search-client", "shared-browser-id")

    # Every header shape an unauthenticated caller could try, including one that
    # spells out the token namespace verbatim.
    for spoof <- ["shared-browser-id", "token:tok-1", "token:tok-1:shared-browser-id"] do
      key = build_conn() |> put_req_header("x-bp-search-client", spoof) |> SearchIntel.actor_key()

      refute key == SearchIntel.actor_key(holder)
      refute String.starts_with?(key, "token:")
    end
  end

  test "session_key/1 keeps its raw per-browser semantics" do
    conn = build_conn() |> put_req_header("x-bp-search-client", "browser-a")

    assert SearchIntel.session_key(conn) == "browser-a"
    assert SearchIntel.session_key(build_conn()) == nil
  end

  test "should_record? requires commit header when client is tracked" do
    conn =
      build_conn()
      |> put_req_header("x-bp-search-client", "picker-1")

    refute SearchIntel.should_record?(conn)

    conn =
      conn
      |> put_req_header("x-bp-search-record", "1")

    assert SearchIntel.should_record?(conn)
  end

  test "should_record? skips tentative partial queries" do
    conn =
      build_conn()
      |> put_req_header("x-bp-search-tentative", "1")

    refute SearchIntel.should_record?(conn)
  end

  test "tags/1 parses header and param values" do
    conn =
      build_conn()
      |> Map.put(:params, %{"searchTags" => "studio"})
      |> put_req_header("x-bp-search-tags", "smoke, qa")

    assert SearchIntel.tags(conn) == ["smoke", "qa", "studio"]
  end

  test "parse_period_start/1 parses an ISO date and rejects garbage" do
    assert SearchIntel.parse_period_start("2026-07-01") == ~D[2026-07-01]
    assert SearchIntel.parse_period_start("not-a-date") == nil
    assert SearchIntel.parse_period_start(nil) == nil
  end

  test "parse_period_start/1 fails soft (nil) on list/map params instead of raising" do
    # Phoenix parses `?periodStart[]=x` into a list and `?periodStart[k]=v` into
    # a map; both used to hit no clause → FunctionClauseError → 500.
    assert SearchIntel.parse_period_start(["2026-07-01"]) == nil
    assert SearchIntel.parse_period_start(%{"k" => "v"}) == nil
  end
end
