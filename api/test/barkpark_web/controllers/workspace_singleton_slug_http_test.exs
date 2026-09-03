defmodule BarkparkWeb.WorkspaceSingletonSlugHttpTest do
  @moduledoc """
  The singleton-seat refusal must surface as a **422**, not a 500
  (task-94a6ed8ced1fc547).

  This is not a cosmetic preference — it is what keeps the support box working.
  `supportEnsureWorkspaceStep` (internal/cli/cloud_support_cmd.go) runs, on every
  box and with the box's own admin token:

      code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST .../api/workspaces \\
        --data '{"name":"default","slug":"default"}')
      case "$code" in
        2*|409|422) exit 0 ;;
        *) echo "workspace ensure: POST /api/workspaces answered HTTP $code" >&2; exit 1 ;;
      esac

  On the resetDefault path the slug IS "default", so the guard fires on the
  exact request that step makes. `2*|409|422` is the whole tolerance: a 500 (or
  a 403) fails the step and breaks support-box provisioning.

  So this file pins the STATUS, against the ACTUAL request that step sends,
  rather than trusting that a changeset error happens to render as 422.
  """

  use BarkparkWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Repo, Tenancy}
  alias Barkpark.Tenancy.Workspace

  setup do
    # Vacate the seat so the guard is the thing being exercised, not the
    # unique constraint (which would also produce a 422 and hide a regression).
    {_n, _} =
      Repo.update_all(
        from(w in Workspace, where: w.slug == ^"default"),
        set: [slug: "vacated-for-http-test"]
      )

    refute Tenancy.get_default_workspace()

    raw = "singleton-http-#{System.unique_integer([:positive])}"
    {:ok, _token} = Auth.create_token(raw, "singleton http", "test", ["read", "write", "admin"])

    {:ok, raw: raw}
  end

  defp authed(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  test "the support box's exact request answers 422 — inside its 2*|409|422 tolerance", %{
    conn: conn,
    raw: raw
  } do
    conn =
      conn
      |> authed(raw)
      |> post("/api/workspaces", %{"name" => "default", "slug" => "default"})

    assert conn.status == 422,
           "supportEnsureWorkspaceStep tolerates only 2xx/409/422; a #{conn.status} " <>
             "fails the step and breaks support-box provisioning"

    refute Tenancy.get_default_workspace(),
           "the seat must still be vacant after the refusal"
  end

  test "the DERIVED shape answers 422 too (no slug field at all)", %{conn: conn, raw: raw} do
    conn = conn |> authed(raw) |> post("/api/workspaces", %{"name" => "Default"})

    assert conn.status == 422
    refute Tenancy.get_default_workspace()
  end

  test "an ordinary workspace create still answers 201", %{conn: conn, raw: raw} do
    conn = conn |> authed(raw) |> post("/api/workspaces", %{"name" => "Some Team"})

    assert conn.status == 201,
           "the guard over-reached: ordinary workspace creation must be untouched"
  end
end
