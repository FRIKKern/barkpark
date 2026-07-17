defmodule BarkparkWeb.Studio.ApiTesterLiveAuthzTest do
  @moduledoc """
  authz-drift fix (sibling of PR #1553): the Studio API Tester playground.

  Two holes closed here:

    1. the form token used to default to the all-perms `barkpark-dev-token`, so
       any Studio operator ran authenticated requests as god. It now defaults to
       the CALLER'S OWN raw token (from the session).
    2. `run` / `run-all` dispatched REAL authenticated HTTP with no gate. They
       now require `Caps.derive(socket).admin` — a non-admin member is denied.

  Scope/setup mirrors ApiTesterLiveScopeGuardTest: a uniquely-slugged
  workspace+project+dataset, mounted at its scoped API Tester URL.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @ws_slug "api-tester-authz-ws"
  @proj_slug "api-tester-authz-proj"
  @dataset "api-tester-authz-ds"

  setup do
    default_ws = Tenancy.get_default_workspace()

    {:ok, ws} = Tenancy.create_workspace(%{slug: @ws_slug, name: "ApiTesterAuthzWS"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: @proj_slug, name: "ApiTesterAuthzProj"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "ApiTesterAuthz"})

    admin_raw = "api-tester-authz-admin-" <> Ecto.UUID.generate()

    {:ok, admin_tok} =
      Auth.create_token(
        admin_raw,
        "authz-admin",
        "production",
        ~w(read write admin),
        default_ws.id
      )

    {:ok, _} = TenancyAuth.create_membership(ws.id, admin_tok.id, "admin")

    member_raw = "api-tester-authz-member-" <> Ecto.UUID.generate()

    {:ok, member_tok} =
      Auth.create_token(member_raw, "authz-member", "production", ~w(read write), default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, member_tok.id, "member")

    {:ok, admin_raw: admin_raw, member_raw: member_raw}
  end

  defp mount_as(conn, raw) do
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    live(conn, "/w/#{@ws_slug}/p/#{@proj_slug}/d/#{@dataset}/studio/api-tester")
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
  defp flash_error(view), do: assigns(view).flash["error"] || ""

  describe "form token default" do
    test "defaults to the CALLER'S OWN raw token, never barkpark-dev-token", %{
      conn: conn,
      member_raw: raw
    } do
      {:ok, view, _html} = mount_as(conn, raw)

      assert assigns(view).token == raw
      refute assigns(view).token == "barkpark-dev-token"
    end
  end

  describe "run/run-all admin gate" do
    test "a non-admin MEMBER's run is DENIED — nothing dispatches", %{
      conn: conn,
      member_raw: raw
    } do
      {:ok, view, _html} = mount_as(conn, raw)

      render_click(view, "run", %{})

      assert flash_error(view) =~ "Admin access required"
      # Non-vacuous: no run Task was spawned — the in-flight flag never flipped.
      assert assigns(view).running == false
      assert assigns(view).run_task_ref == nil
    end

    test "a non-admin MEMBER's run-all is DENIED — nothing dispatches", %{
      conn: conn,
      member_raw: raw
    } do
      {:ok, view, _html} = mount_as(conn, raw)

      render_click(view, "run-all", %{})

      assert flash_error(view) =~ "Admin access required"
      assert assigns(view).running == false
      assert assigns(view).run_task_ref == nil
    end

    test "an ADMIN's run passes the gate (positive control) — not denied", %{
      conn: conn,
      admin_raw: raw
    } do
      {:ok, view, _html} = mount_as(conn, raw)

      render_click(view, "run", %{})

      # The admin clears the gate: no deny flash. (The actual HTTP dispatch runs
      # in a Task against localhost and is irrelevant here — the point is the
      # gate did NOT block an admin.)
      refute flash_error(view) =~ "Admin access required"
    end
  end
end
