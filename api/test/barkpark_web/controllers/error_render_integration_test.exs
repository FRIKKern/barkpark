defmodule BarkparkWeb.ErrorRenderIntegrationTest do
  @moduledoc """
  End-to-end proof that the endpoint's RenderErrors layer renders our error
  modules WITHOUT crashing — the actual bug: previously the renderer blew up
  ("the module does not exist") and dropped the connection.

  `/__error_test__/boom` (test-only route, router.ex) raises inside the real
  BarkparkWeb.Endpoint; `assert_error_sent` catches it and returns the response
  RenderErrors actually sent, so this exercises the full
  endpoint → RenderErrors → ErrorJSON/ErrorHTML path.
  """
  use BarkparkWeb.ConnCase, async: true

  @tag :capture_log
  test "a raise on a JSON request yields a well-formed internal_error envelope", %{conn: conn} do
    {status, _headers, body} =
      assert_error_sent(500, fn ->
        conn
        |> put_req_header("accept", "application/json")
        |> get("/__error_test__/boom")
      end)

    assert status == 500
    decoded = Jason.decode!(body)

    # Canonical v1 envelope shape (same as FallbackController) — SDK/CLI key on
    # error.code. NO exception detail is leaked: message is the generic text.
    assert %{"error" => %{"code" => "internal_error", "message" => message}} = decoded
    assert message == "unknown error"
    refute message =~ "boom"
    refute Map.has_key?(decoded, "errors")
  end

  @tag :capture_log
  test "a raise on an HTML request yields a minimal error page, not a crash", %{conn: conn} do
    {status, _headers, body} =
      assert_error_sent(500, fn ->
        conn
        |> put_req_header("accept", "text/html")
        |> get("/__error_test__/boom")
      end)

    assert status == 500
    assert body =~ "<h1>500</h1>"
    assert body =~ "Internal Server Error"
    refute body =~ "boom"
  end

  # ── Route misses (no raise — the app handles these gracefully) ───────────

  @tag :capture_log
  test "unknown JSON route returns a well-formed not_found envelope, not a crash", %{conn: conn} do
    resp =
      conn
      |> put_req_header("accept", "application/json")
      |> get("/v1/__definitely_not_a_route__/a/b/c")

    assert resp.status == 404
    # Same canonical envelope as FallbackController — clients key on error.code.
    assert %{"error" => %{"code" => "not_found", "message" => _}} =
             Jason.decode!(resp.resp_body)
  end

  @tag :capture_log
  test "unknown HTML route returns a rendered 404 page, not a crash", %{conn: conn} do
    resp =
      conn
      |> put_req_header("accept", "text/html")
      |> get("/__definitely_not_a_browser_route__")

    assert resp.status == 404
    # Real markup, not escaped text (the raw/1 regression this test pins).
    assert resp.resp_body =~ "<h1>404</h1>"
    refute resp.resp_body =~ "&lt;h1&gt;"
  end
end
