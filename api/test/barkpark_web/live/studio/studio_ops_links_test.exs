defmodule BarkparkWeb.Studio.StudioOpsLinksTest do
  # task-f859c5f7f3a0f9f5: the Tasks plugin's Projects and Fleet consoles sit
  # behind the `:ops` gate, but their top-bar tabs and desk links showed to
  # every viewer, and a member who clicked was bounced with "Operator access
  # required". The chrome now leaves out an ops-gated link for a viewer the
  # gate would refuse.
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Barkpark.Auth
  alias BarkparkWeb.LiveAuth

  @dataset "production"
  @admin "barkpark-test-opslinks-admin"
  @writer "barkpark-test-opslinks-writer"

  setup do
    {ws, _project} = Barkpark.TenancyFixtures.ensure_default_scope!()

    {:ok, _} =
      Auth.create_token(@admin, "opslinks-admin", @dataset, ["read", "write", "admin"], ws.id)

    {:ok, _} = Auth.create_token(@writer, "opslinks-writer", @dataset, ["read", "write"], ws.id)
    %{ws_id: ws.id}
  end

  defp token(raw) do
    {:ok, t} = Auth.verify_token(raw)
    t
  end

  defp member_conn(conn, ws_id) do
    raw = "opslinks-member-#{System.unique_integer([:positive])}"

    {:ok, token} =
      %Auth.ApiToken{}
      |> Auth.ApiToken.changeset(%{
        token_hash: Auth.ApiToken.hash_token(raw),
        label: "opslinks-member",
        dataset: @dataset,
        permissions: ["read", "write"]
      })
      |> Barkpark.Repo.insert()

    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws_id, token.id, "member")
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  test "the Projects and Fleet consoles are ops-gated routes; Studio is not" do
    assert LiveAuth.ops_gated_path?("/admin/projects")
    assert LiveAuth.ops_gated_path?("/admin/fleet")
    refute LiveAuth.ops_gated_path?("/d/#{@dataset}/studio")
    refute LiveAuth.ops_gated_path?("/no/such/route")
    refute LiveAuth.ops_gated_path?(nil)
  end

  test "ops access mirrors the gate's bearer arm" do
    assert LiveAuth.ops_access?(token(@admin), nil)
    refute LiveAuth.ops_access?(token(@writer), nil)
    refute LiveAuth.ops_access?(nil, nil)
  end

  test "a member sees no tab or desk link to an ops console", %{conn: conn, ws_id: ws_id} do
    {:ok, _view, html} = live(member_conn(conn, ws_id), scoped_studio("/d/#{@dataset}/studio"))
    refute html =~ ~s(href="/admin/projects")
    refute html =~ ~s(href="/admin/fleet")
  end

  test "an admin still sees them", %{conn: conn} do
    conn = Plug.Test.init_test_session(conn, %{"api_token" => @admin})
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio"))
    assert html =~ ~s(href="/admin/projects")
    assert html =~ ~s(href="/admin/fleet")
  end
end
