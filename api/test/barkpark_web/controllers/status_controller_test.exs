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

  test "GET /status.json carries the codelists component, and a detail when one is degraded",
       %{conn: conn} do
    body = conn |> get("/status.json") |> json_response(200)

    names = Enum.map(body["components"], & &1["name"])
    assert "codelists" in names

    # The seed signal is only worth publishing if it survives JSON: a degraded
    # component whose payload is the word "degraded" tells an operator nothing,
    # so `detail` must ride through and NAME the list. Rendered from the same
    # component shape `Status.health/0` builds.
    degraded = %{
      component: :codelists,
      status: :degraded,
      detail: "codelist onixedit:thema is empty or stale: registered at issue 1.6 with 0 values"
    }

    rendered = BarkparkWeb.StatusController.component_json(degraded)

    assert rendered.detail =~ "codelist onixedit:thema is empty or stale"

    # And an operational probe with nothing to say does NOT invent a detail key.
    clean = %{component: :database, status: :operational, detail: nil}
    refute Map.has_key?(BarkparkWeb.StatusController.component_json(clean), :detail)
  end

  test "GET /status.json publishes the running commit sha to an ANONYMOUS caller", %{conn: conn} do
    # No bearer, no session — this is the unattended owner's uptime monitor.
    body = scoped_conn() |> get("/status.json") |> json_response(200)

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
    body = scoped_conn() |> get("/status.json") |> json_response(200)
    assert is_binary(body["commit"]) and body["commit"] != ""
  end

  describe "inventory: enabled capabilities + migration state (task-fe88bf2ed4df476d)" do
    defp applied_versions do
      %{rows: rows} = Barkpark.Repo.query!("SELECT version FROM schema_migrations")
      Enum.map(rows, fn [v] -> v end)
    end

    test "an anonymous caller gets the enabled-plugin COUNT, never the names" do
      plugins = Barkpark.Plugins.Registry.all()
      # Precondition: with zero plugins registered the name check below is vacuous.
      assert plugins != []

      resp = scoped_conn() |> get("/status.json")
      body = json_response(resp, 200)

      assert body["capabilities"] == %{
               "plugins_enabled" => length(plugins),
               "inventory" => "/v1/plugins"
             }

      # The disclosure decision: no plugin NAME appears anywhere in the raw
      # public body — not in `capabilities`, not in any other key.
      raw = resp.resp_body

      for %{name: name} <- plugins do
        refute raw =~ ~s("#{name}"), "anonymous /status.json leaked plugin name #{name}"
      end

      # And the route the payload points at still refuses an anonymous caller.
      assert scoped_conn() |> get("/v1/plugins") |> json_response(401)
    end

    test "reports the latest APPLIED migration version and a pending count of 0" do
      applied = applied_versions()
      assert applied != []

      body = scoped_conn() |> get("/status.json") |> json_response(200)

      assert body["migrations"] == %{"latest_applied" => Enum.max(applied), "pending" => 0}

      assert Enum.find(body["components"], &(&1["name"] == "migrations"))["status"] ==
               "operational"
    end

    test "a migration on disk but not applied is PENDING, and the component says so" do
      # Staged inside this test's sandbox transaction (rolled back after): drop
      # the newest applied row, so its on-disk file reads `:down` to the SAME
      # Ecto.Migrator read /status.json takes.
      applied = applied_versions() |> Enum.sort(:desc)
      [newest, previous | _] = applied

      Barkpark.Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [newest])

      body = scoped_conn() |> get("/status.json") |> json_response(200)

      assert body["migrations"] == %{"latest_applied" => previous, "pending" => 1}
      assert Enum.find(body["components"], &(&1["name"] == "migrations"))["status"] == "degraded"
      refute body["status"] == "operational"
    end

    test "applied version comes from the DB, not files; a probe that raises is UNKNOWN, not 0" do
      # A directory that does not exist has no migrations on disk: every applied
      # row is `:up` with no file, and nothing is pending.
      dir =
        Path.join(System.tmp_dir!(), "bp-status-empty-#{System.unique_integer([:positive])}")

      assert Barkpark.Status.migration_state([dir]) == %{
               latest_applied: Enum.max(applied_versions()),
               pending: 0
             }

      # A probe that raises must not read as "nothing pending".
      assert Barkpark.Status.migration_state([:not_a_path]) == %{
               latest_applied: nil,
               pending: nil
             }
    end
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
      admin(scoped_conn(), raw)
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
    body = scoped_conn() |> get("/status.json") |> json_response(200)
    assert body["status"] == "partial_outage"
    assert Enum.any?(body["incidents"], &(&1["title"] == "DB latency"))

    # The public page surfaces it.
    html = scoped_conn() |> get("/status") |> response(200)
    assert html =~ "DB latency"

    # Resolving it returns to operational.
    assert admin(scoped_conn(), raw)
           |> post("/v1/status/incidents/#{id}/resolve", "{}")
           |> json_response(200)

    assert scoped_conn() |> get("/status.json") |> json_response(200) |> Map.fetch!("status") ==
             "operational"
  end

  test "incident management requires admin", %{} do
    # Anonymous → RequireToken rejects.
    assert scoped_conn()
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
