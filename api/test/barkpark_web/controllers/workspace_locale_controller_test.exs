defmodule BarkparkWeb.WorkspaceLocaleControllerTest do
  @moduledoc """
  Gyldendal parity E7 — `PATCH /w/:ws/p/:proj/v1/workspace/locale` sets the
  Studio chrome locale, admin-gated like the roster; the login page picks the
  locale up from a `return_to` that names the workspace.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup do
    ws = create_workspace!("locale-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    admin_raw = "locale-admin-#{System.unique_integer([:positive])}"

    {:ok, admin} =
      Auth.create_token(admin_raw, "locale-admin", @dataset, ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws.id, admin.id, "admin", "api_token")
    member_raw = "locale-member-#{System.unique_integer([:positive])}"
    {:ok, member} = Auth.create_token(member_raw, "locale-member", @dataset, ["read", "write"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, member.id, "member", "api_token")
    %{ws: ws, project: project, admin_raw: admin_raw, member_raw: member_raw}
  end

  defp req(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp locale_path(ws, project), do: "/w/#{ws.slug}/p/#{project.slug}/v1/workspace/locale"

  test "an admin sets nb-NO and the workspace resolves to it", %{
    ws: ws,
    project: project,
    admin_raw: raw
  } do
    conn = patch(req(raw), locale_path(ws, project), Jason.encode!(%{locale: "nb-NO"}))
    assert %{"locale" => "nb-NO", "known_locales" => known} = json_response(conn, 200)
    assert "nb-NO" in known
    assert Tenancy.workspace_locale(Tenancy.get_workspace_by_id(ws.id)) == "nb-NO"
  end

  test "an unknown locale is a 422 that names the known list", %{
    ws: ws,
    project: project,
    admin_raw: raw
  } do
    conn = patch(req(raw), locale_path(ws, project), Jason.encode!(%{locale: "sv-SE"}))

    assert %{"error" => %{"code" => "unknown_locale", "message" => msg}} =
             json_response(conn, 422)

    assert msg =~ "nb-NO"
    assert Tenancy.workspace_locale(Tenancy.get_workspace_by_id(ws.id)) == "en"
  end

  test "a missing locale is a 422", %{ws: ws, project: project, admin_raw: raw} do
    conn = patch(req(raw), locale_path(ws, project), Jason.encode!(%{}))
    assert %{"error" => %{"code" => "missing_locale"}} = json_response(conn, 422)
  end

  test "a plain member cannot set the workspace locale", %{
    ws: ws,
    project: project,
    member_raw: raw
  } do
    conn = patch(req(raw), locale_path(ws, project), Jason.encode!(%{locale: "nb-NO"}))
    assert conn.status in [401, 403]
    assert Tenancy.workspace_locale(Tenancy.get_workspace_by_id(ws.id)) == "en"
  end

  test "the login page speaks the return_to workspace's language", %{ws: ws, project: project} do
    {:ok, _} = Tenancy.set_workspace_locale(ws, "nb-NO")

    nb =
      get(scoped_conn(), "/login?return_to=/w/#{ws.slug}/p/#{project.slug}/d/production/studio")

    assert html_response(nb, 200) =~ "Logg inn med et API-token i stedet"
    en = get(scoped_conn(), "/login")
    assert html_response(en, 200) =~ "Sign in with an API token instead"
    refute html_response(en, 200) =~ "Logg inn med et API-token"
  end
end
