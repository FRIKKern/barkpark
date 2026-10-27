defmodule BarkparkWeb.StatusProbesTest do
  @moduledoc """
  `GET /livez` and `GET /readyz`, the container platform probes.

  The "database unreachable" module checks out no sandbox connection, so every
  Repo call from the request raises `DBConnection.OwnershipError`, which is how
  this process sees a Postgres it cannot reach. It is async on purpose: async
  modules run before any shared-mode module could lend this process a
  connection.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Phoenix.ConnTest

  @endpoint BarkparkWeb.Endpoint

  test "with no database connection, /livez answers 200 and /readyz 503" do
    assert json_response(get(build_conn(), "/livez"), 200) == %{"status" => "ok"}

    # Ecto.Migrator logs the failed schema_migrations read; keep it out of the run.
    {conn, _log} = with_log(fn -> get(build_conn(), "/readyz") end)
    body = json_response(conn, 503)
    assert body["status"] == "not_ready"
    assert body["checks"]["database"] == false
    assert body["checks"]["migrations"] == false
    assert body["checks"]["oban"] == true
  end
end

defmodule BarkparkWeb.StatusProbesReadyTest do
  @moduledoc "`GET /readyz` with a reachable database and current migrations."
  use BarkparkWeb.ConnCase, async: false

  test "/readyz answers 200 with every check true", %{conn: conn} do
    assert json_response(get(conn, "/readyz"), 200) == %{
             "status" => "ready",
             "checks" => %{"database" => true, "migrations" => true, "oban" => true}
           }
  end
end
