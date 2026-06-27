defmodule BarkparkWeb.SearchLocalTest do
  @moduledoc """
  Covers the localhost fast-path search endpoint added in Barkpark Cloud
  P4 / Move B:

      GET /v1/data/local/search/:dataset

  Two load-bearing properties:

    * **Loopback gate**. A non-loopback `remote_ip` is silently 403'd — the
      surface should not appear to exist to anyone but the box itself.
    * **Returns the same JSON shape as the standard endpoint** (`/v1/data/
      search/:dataset`) so the co-located /web can swap routes without
      changing its response shape.

  The shaved-floor latency win (no OptionalToken / RateLimit DB lookups) is
  architectural — measurable in prod but not asserted here.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content

  @ds "search-local-test"

  setup do
    # Seed one doc so search has something to match.
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "local-test-doc", "title" => "LocalUniqAlphagrid Doc"},
        @ds,
        []
      )

    {:ok, _} = Content.publish_document("local-test-doc", "post", @ds, [])
    :ok
  end

  test "loopback caller (default in tests) → 200 with normal shape", %{conn: conn} do
    # Plug.Test conns default to {127,0,0,1} remote_ip → loopback gate accepts.
    resp =
      conn
      |> get("/v1/data/local/search/#{@ds}", q: "localuniqalphagrid")

    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert body["count"] >= 1
    assert is_list(body["documents"])
    # Shape parity with the standard endpoint — same keys.
    for k <- ~w(documents count query parsedQuery highlights ms) do
      assert Map.has_key?(body, k), "missing key #{k}"
    end
  end

  test "missing q → 400 (matches the standard endpoint's missing_q shape)", %{conn: conn} do
    resp = conn |> get("/v1/data/local/search/#{@ds}")
    assert resp.status == 400
  end

  test "non-loopback caller → 403 with no body (silent rejection)", %{conn: conn} do
    # Spoof a public IP. Plug.Test's `Plug.Conn` lets us set remote_ip directly.
    resp =
      conn
      |> Map.put(:remote_ip, {203, 0, 113, 1})
      |> get("/v1/data/local/search/#{@ds}", q: "anything")

    assert resp.status == 403
    assert resp.resp_body == ""
  end

  test "IPv6 loopback (::1) is accepted", %{conn: conn} do
    resp =
      conn
      |> Map.put(:remote_ip, {0, 0, 0, 0, 0, 0, 0, 1})
      |> get("/v1/data/local/search/#{@ds}", q: "localuniqalphagrid")

    assert resp.status == 200
  end

  test "IPv6 non-loopback is rejected", %{conn: conn} do
    # IPv6 Documentation prefix 2001:db8::1 — public-routable shape, not ::1.
    resp =
      conn
      |> Map.put(:remote_ip, {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})
      |> get("/v1/data/local/search/#{@ds}", q: "anything")

    assert resp.status == 403
  end
end
