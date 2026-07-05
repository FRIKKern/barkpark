defmodule BarkparkWeb.StatusControllerTest do
  @moduledoc "Public status page + JSON + admin incident management."
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth

  @dataset "production"

  setup do
    raw = "tok-admin-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "admin", @dataset, ["read", "write", "admin"])
    %{admin: raw}
  end

  defp admin(conn, raw),
    do: conn |> put_req_header("authorization", "Bearer #{raw}") |> put_req_header("content-type", "application/json")

  test "GET /status.json reports real component health + SLA", %{conn: conn} do
    body = conn |> get("/status.json") |> json_response(200)

    assert body["status"] == "operational"
    names = Enum.map(body["components"], & &1["name"])
    assert "database" in names and "migrations" in names and "plugins" in names
    assert Enum.find(body["components"], &(&1["name"] == "database"))["status"] == "operational"
    assert body["sla"]["uptime_target"]
    assert is_integer(body["uptime_seconds"])
  end

  test "GET /status renders a public HTML page", %{conn: conn} do
    html = conn |> get("/status") |> response(200)
    assert html =~ "Barkpark Status"
    assert html =~ "All systems operational"
    assert html =~ "uptime target"
  end

  test "an open incident degrades overall status and shows on the page", %{admin: raw} do
    created =
      admin(build_conn(), raw)
      |> post("/v1/status/incidents", Jason.encode!(%{title: "DB latency", component: "database", impact: "major", body: "elevated query times"}))
      |> json_response(201)

    id = created["incident"]["id"]

    # Overall now reflects the open major incident.
    body = build_conn() |> get("/status.json") |> json_response(200)
    assert body["status"] == "partial_outage"
    assert Enum.any?(body["incidents"], &(&1["title"] == "DB latency"))

    # The public page surfaces it.
    html = build_conn() |> get("/status") |> response(200)
    assert html =~ "DB latency"

    # Resolving it returns to operational.
    assert admin(build_conn(), raw)
           |> post("/v1/status/incidents/#{id}/resolve", "{}")
           |> json_response(200)

    assert build_conn() |> get("/status.json") |> json_response(200) |> Map.fetch!("status") == "operational"
  end

  test "incident management requires admin", %{} do
    # Anonymous → RequireToken rejects.
    assert build_conn()
           |> put_req_header("content-type", "application/json")
           |> post("/v1/status/incidents", Jason.encode!(%{title: "x", impact: "minor"}))
           |> json_response(401)
  end
end
