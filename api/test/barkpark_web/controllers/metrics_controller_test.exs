defmodule BarkparkWeb.MetricsControllerTest do
  @moduledoc """
  Contract tests for `GET /v1/instance/metrics`.

  The route rides `[:api, :require_admin]` (task-d7ac954aa57aa522). It rode
  `[:api, :require_token]` — NOT-ANONYMOUS, which admits any read/write/admin
  token from any workspace — until the payload was read rather than assumed:
  `BarkparkWeb.Telemetry.prometheus_metrics/0` tags four series with
  `:workspace_id`, so one scrape enumerates the box's workspace roster and each
  tenant's write/search/publish/media volume. The tier arms below are what
  would catch a revert.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth

  @route "/v1/instance/metrics"

  # Unique labels: the test DB is shared across agents.
  defp mint(perms, label) do
    raw = "metrics-test-#{label}-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, _token} = Auth.create_token(raw, "metrics-test-#{label}", "test", perms)
    raw
  end

  defp bearer(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  test "401 without a token — the scrape endpoint is never anonymous", %{conn: conn} do
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

  # THE REGRESSION GUARD. A plain `["read"]` token — deliberately not
  # `public-read`, which `PublicRead` would have clamped on the old pipeline for
  # an unrelated reason and so could not tell the two tiers apart. This conn got
  # a 200 and the full label set before task-d7ac954aa57aa522.
  test "403 for a plain read token — the label set names other tenants", %{conn: conn} do
    assert %{"error" => %{"code" => "forbidden"}} =
             conn |> bearer(mint(["read"], "read")) |> get(@route) |> json_response(403)
  end

  test "200 text/plain Prometheus exposition for an admin token", %{conn: conn} do
    # Seed a sample so the exposition is non-empty.
    :telemetry.execute([:vm, :memory], %{total: 15_000_000}, %{})

    conn = conn |> bearer(mint(["read", "write", "admin"], "admin")) |> get(@route)

    assert response(conn, 200)
    assert response_content_type(conn, :text) =~ "text/plain"
    body = response(conn, 200)
    # The named metric families are exposed for scraping.
    assert body =~ "vm_memory_total"
  end

  # The reason for the tier, asserted rather than asserted-about: the exposition
  # this route serves carries a `workspace_id` LABEL. `scrape/2` is tenant-blind
  # — the disclosure is in the label set, which is why reading the controller
  # alone produced the wrong verdict.
  test "the exposition's own label set carries workspace_id", %{conn: conn} do
    ws = "ws-tier-probe-" <> Integer.to_string(System.unique_integer([:positive]))

    :telemetry.execute(
      [:barkpark, :media, :mutate],
      %{count: 1},
      %{workspace_id: ws}
    )

    body =
      conn
      |> bearer(mint(["read", "write", "admin"], "label"))
      |> get(@route)
      |> response(200)

    assert body =~ "workspace_id=\"#{ws}\""
  end
end
