defmodule BarkparkWeb.Studio.PresenceFallbackNameLocaleTest do
  @moduledoc """
  task-af8133b738966b6c: a session with no display name and no stored name is
  named "User <4 hex>". In a Norwegian Studio its own avatar read
  "User 795b — åpne profilen din", and peers saw "User 795b". The fallback is
  now "Bruker 795b" there; an English Studio reads as before. Mount builds the
  name before handle_params puts the Studio locale, so this goes through a
  real mount, not a handler.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Studio.SheetGrid.Geometry

  @dataset "production"

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} =
      Tenancy.create_workspace(%{slug: "fallback-name-#{suffix}", name: "Fallback Name"})

    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "nb-NO")

    raw = "fallback-name-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "fallback-name", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj}
  end

  defp own_name(conn, ws, proj) do
    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"user_id" => "795b0c1d-0000-4000-8000-000000000000"})
      |> live("/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio")

    {:sys.get_state(view.pid).socket.assigns.user_name, render(view)}
  end

  test "a Norwegian Studio names a nameless session Bruker <hex>", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    {name, html} = own_name(conn, ws, proj)
    assert name == "Bruker 795b"
    assert html =~ "Bruker 795b — åpne profilen din"
    refute html =~ "User 795b"
  end

  test "an English Studio still names it User <hex>", %{conn: conn, ws: ws, proj: proj} do
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "en")
    assert {"User 795b", _html} = own_name(conn, ws, proj)
  end

  test "a sheet peer without a name reads in the Studio language" do
    peers = [%{user_id: "a1b2c3d4", tab: 0}]

    nb =
      Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fn ->
        Geometry.grid_peers(peers, "me", 0)
      end)

    assert [%{name: "Bruker a1b2"}] = nb
    assert [%{name: "User a1b2"}] = Geometry.grid_peers(peers, "me", 0)
  end
end
