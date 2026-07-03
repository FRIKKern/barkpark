defmodule BarkparkWeb.SearchIntelTest do
  use BarkparkWeb.ConnCase, async: true

  alias BarkparkWeb.SearchIntel

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
