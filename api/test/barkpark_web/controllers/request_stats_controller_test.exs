defmodule BarkparkWeb.RequestStatsControllerTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content
  alias BarkparkWeb.RequestStats

  @route "/v1/instance/request-stats"

  defp authed_conn(conn) do
    raw = "reqstats-test-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, _token} = Auth.create_token(raw, "reqstats-test", "test", ["read"])

    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("accept", "application/json")
  end

  defp seed_paper(slug) do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          body_html: ~s(<section id="block-1"><h1>Metered</h1></section>),
          event_type: "plan-written"
        })
      )

    paper
  end

  test "401 without a token — never an unauthenticated stats endpoint", %{conn: conn} do
    conn = get(conn, @route)
    assert json_response(conn, 401)
  end

  test "401 with a bogus token", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer not-a-real-token")
      |> get(@route)

    assert json_response(conn, 401)
  end

  test "200 with the agent token seam; contract shape {req_per_s, p95_ms, err_5xx_per_s, window_s, count, elapsed_s, sampled_at, classes}",
       %{
         conn: conn
       } do
    body =
      conn
      |> authed_conn()
      |> get(@route)
      |> json_response(200)

    assert Map.keys(body) |> Enum.sort() ==
             [
               "classes",
               "count",
               "elapsed_s",
               "err_5xx_per_s",
               "p95_ms",
               "req_per_s",
               "sampled_at",
               "window_s"
             ]

    assert body["window_s"] == 60
    assert is_float(body["req_per_s"])
    assert body["req_per_s"] >= 0.0
    # Honesty: p95_ms is null (no samples) or a real integer — never a fake 0ms
    # standing in for "no data".
    assert is_nil(body["p95_ms"]) or is_integer(body["p95_ms"])
    # Same law for the error rate: an empty window is null, not a reassuring 0.0
    # standing in for "this box is serving no errors".
    assert is_nil(body["err_5xx_per_s"]) or is_float(body["err_5xx_per_s"])
    assert is_nil(body["err_5xx_per_s"]) or body["err_5xx_per_s"] >= 0.0
    # The additive four (D10): volume beside rate, the divisor, the read stamp,
    # and the per-class breakdown.
    assert is_integer(body["count"]) and body["count"] >= 0
    assert is_number(body["elapsed_s"]) and body["elapsed_s"] > 0
    assert {:ok, _dt, 0} = DateTime.from_iso8601(body["sampled_at"])
    assert is_map(body["classes"])

    # Every class row (this authed GET itself lands one) carries the closed
    # five-key per-class shape.
    for {class, row} <- body["classes"] do
      assert class in ~w(lv_dead browser api unrouted pre_router)

      assert Map.keys(row) |> Enum.sort() ==
               ["anon", "auth_unknown", "authed", "count", "req_per_s"]

      assert row["count"] == row["authed"] + row["anon"] + row["auth_unknown"]
    end
  end

  describe "route-class + auth classification driven through the real endpoint (D9/D11)" do
    # A test-scoped aggregator instance: its init attaches its own telemetry
    # handler, so every stop event the endpoint emits during the test lands in
    # an isolated table read via stats(name). Both files are async: false —
    # nothing else is dispatching while these run.
    setup do
      table = :"req_stats_ctrl_#{System.unique_integer([:positive])}"
      name = :"req_stats_ctrl_proc_#{System.unique_integer([:positive])}"
      start_supervised!({RequestStats, name: name, table: table})
      %{name: name, table: table}
    end

    test "a bearer API request lands in api.authed and moves NO anon counter", %{
      conn: conn,
      name: name
    } do
      conn |> authed_conn() |> get("/v1/capabilities") |> json_response(200)

      %{classes: classes, count: 1} = RequestStats.stats(name)
      assert %{api: %{count: 1, authed: 1, anon: 0, auth_unknown: 0}} = classes
      assert Enum.all?(classes, fn {_class, row} -> row.anon == 0 end)
    end

    test "an anonymous API request lands in api.anon (OptionalToken ran and resolved nothing)",
         %{conn: conn, name: name} do
      conn
      |> put_req_header("accept", "application/json")
      |> get("/v1/capabilities")
      |> json_response(200)

      %{classes: classes, count: 1} = RequestStats.stats(name)
      assert %{api: %{count: 1, authed: 0, anon: 1, auth_unknown: 0}} = classes
    end

    test "an anonymous LV dead render lands in lv_dead.auth_unknown — bare :browser runs no auth plug",
         %{conn: conn, name: name} do
      slug = "reqstats-anon-paper-#{System.unique_integer([:positive])}"
      seed_paper(slug)

      conn = get(conn, "/papers/#{slug}")
      assert html_response(conn, 200) =~ "Metered"

      %{classes: classes, count: 1} = RequestStats.stats(name)
      assert %{lv_dead: %{count: 1, authed: 0, anon: 0, auth_unknown: 1}} = classes
    end

    test "HIGH-FLIP-RISK pin: a SIGNED-IN paper-reader dead render is lv_dead.authed and moves NO anon counter anywhere",
         %{conn: conn, name: name} do
      slug = "reqstats-signed-paper-#{System.unique_integer([:positive])}"
      seed_paper(slug)

      raw = "reqstats-session-" <> Integer.to_string(System.unique_integer([:positive]))
      {:ok, _token} = Auth.create_token(raw, "reqstats-session", "test", ["read"])

      conn =
        conn
        |> Plug.Test.init_test_session(%{"api_token" => raw})
        |> get("/papers/#{slug}")

      assert html_response(conn, 200) =~ "Metered"

      # The flat reader's PIPELINES still run no :api_token-resolving plug, but
      # since edit-on-the-link slice 1 (task-0c242c8dc61f6b13) the reader's own
      # on_mount hook, `BarkparkWeb.PaperViewer`, verifies the session token
      # during the dead render and assigns `:api_token` — the same way
      # `LiveAuth.:fetch_api_token` does for Studio. The dead render copies the
      # socket assigns onto the conn, so the token is PRESENT at stop: `authed`
      # is the honest word (D11 never assigns absence; presence is presence).
      # Before slice 1 this sample was `auth_unknown`; the flip is deliberate.
      # The invariant that must never move: no anon counter, anywhere.
      %{classes: classes, count: 1} = RequestStats.stats(name)
      # lv_dead is the ONLY class present…
      assert Map.keys(classes) == [:lv_dead]
      assert %{count: 1, authed: 1, anon: 0, auth_unknown: 0} = classes[:lv_dead]
      # …and no class row anywhere carries an anon tick.
      assert Enum.all?(classes, fn {_class, row} -> row.anon == 0 end)
    end

    test "an unrouted 404 lands in unrouted.auth_unknown (router ran, nothing matched)", %{
      conn: conn,
      name: name
    } do
      conn = get(conn, "/definitely-not-a-route-xyz")
      assert response(conn, 404)

      %{classes: classes, count: 1} = RequestStats.stats(name)
      assert %{unrouted: %{count: 1, authed: 0, anon: 0, auth_unknown: 1}} = classes
    end

    test "a REAL static file emits ZERO samples — Plug.Static halts before Plug.Telemetry", %{
      conn: conn,
      name: name
    } do
      conn = get(conn, "/robots.txt")
      assert response(conn, 200)

      %{count: 0, classes: classes} = RequestStats.stats(name)
      assert classes == %{}
    end
  end
end
