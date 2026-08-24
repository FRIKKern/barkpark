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
    do:
      conn
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("content-type", "application/json")

  test "GET /status.json reports real component health + SLA", %{conn: conn} do
    body = conn |> get("/status.json") |> json_response(200)

    assert body["status"] == "operational"
    names = Enum.map(body["components"], & &1["name"])
    assert "database" in names and "migrations" in names and "plugins" in names
    assert Enum.find(body["components"], &(&1["name"] == "database"))["status"] == "operational"
    assert body["sla"]["uptime_target"]
    assert is_integer(body["uptime_seconds"])
  end

  test "GET /status.json publishes the running commit sha to an ANONYMOUS caller", %{conn: conn} do
    # No bearer, no session — this is the unattended owner's uptime monitor.
    body = build_conn() |> get("/status.json") |> json_response(200)

    assert Map.has_key?(body, "commit"), "commit must be SURFACED, never omitted"
    assert body["commit"] == Barkpark.BuildInfo.commit()

    # An IDENTITY, not the commits-since-tag DISTANCE that `version` carries.
    assert body["commit"] =~ ~r/^([0-9a-f]{7,40}|unknown)$/
    assert body["commit"] != body["version"]

    # Same payload for an anonymous conn built any other way.
    assert conn |> get("/status.json") |> json_response(200) |> Map.fetch!("commit") ==
             body["commit"]
  end

  test "an underivable sha renders \"unknown\" rather than dropping the key" do
    # BuildInfo freezes its sha at compile time, so the fallback is proven
    # through Status.commit/1's injectable resolver — the same code path
    # /status.json takes.
    assert Barkpark.Status.commit(fn -> raise "no git on this box" end) == "unknown"
    assert Barkpark.Status.commit(fn -> nil end) == "unknown"
    assert Barkpark.Status.commit(fn -> "" end) == "unknown"
    assert Barkpark.Status.commit(fn -> "deadbee" end) == "deadbee"

    # And the key is always present in the payload, whatever the value.
    body = build_conn() |> get("/status.json") |> json_response(200)
    assert is_binary(body["commit"]) and body["commit"] != ""
  end

  test "GET /status renders a public HTML page", %{conn: conn} do
    html = conn |> get("/status") |> response(200)
    assert html =~ "Barkpark Status"
    assert html =~ "All systems operational"
    assert html =~ "uptime target"
    assert html =~ "commit #{Barkpark.BuildInfo.commit()}"
  end

  test "an open incident degrades overall status and shows on the page", %{admin: raw} do
    created =
      admin(build_conn(), raw)
      |> post(
        "/v1/status/incidents",
        Jason.encode!(%{
          title: "DB latency",
          component: "database",
          impact: "major",
          body: "elevated query times"
        })
      )
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

    assert build_conn() |> get("/status.json") |> json_response(200) |> Map.fetch!("status") ==
             "operational"
  end

  test "incident management requires admin", %{} do
    # Anonymous → RequireToken rejects.
    assert build_conn()
           |> put_req_header("content-type", "application/json")
           |> post("/v1/status/incidents", Jason.encode!(%{title: "x", impact: "minor"}))
           |> json_response(401)
  end

  describe "mail deliverability component" do
    setup do
      original = Application.get_env(:barkpark, Barkpark.Mailer)
      on_exit(fn -> Application.put_env(:barkpark, Barkpark.Mailer, original) end)
      :ok
    end

    test "a node whose mailer discards every message reports mail degraded", %{conn: conn} do
      # The queryable half of the fix. Password reset and magic-link sign-in
      # answer 200 for anti-enumeration reasons, so an operator or an uptime
      # monitor has nowhere else to see that identity mail is dead.
      Application.put_env(:barkpark, Barkpark.Mailer, adapter: Swoosh.Adapters.Local)

      body = conn |> get("/status.json") |> json_response(200)
      mail = Enum.find(body["components"], &(&1["name"] == "mail"))

      assert mail, "the status payload must carry a mail component"
      assert mail["status"] == "degraded"
      refute body["status"] == "operational"
    end

    test "a node with a real relay reports mail operational", %{conn: conn} do
      Application.put_env(:barkpark, Barkpark.Mailer, adapter: Swoosh.Adapters.SMTP)

      body = conn |> get("/status.json") |> json_response(200)
      mail = Enum.find(body["components"], &(&1["name"] == "mail"))

      assert mail["status"] == "operational"
    end
  end
end
