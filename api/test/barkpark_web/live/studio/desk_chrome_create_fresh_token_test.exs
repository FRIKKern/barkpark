defmodule BarkparkWeb.Studio.DeskChromeCreateFreshTokenTest do
  @moduledoc """
  task-6dd234b8f84baaf5: on the desk, `create-project` and `create-workspace`
  are answered by `StudioChrome`'s fallback, before `Caps`. It decided on the
  token row read at mount, so a token cut to read (or revoked) mid-session
  still created a project and a dataset. Studio (`Caps`, fresh on every press)
  and REST refuse it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.{Repo, Tenancy}
  alias Barkpark.Auth.ApiToken

  setup %{conn: conn} do
    c = setup_doc(conn)
    {:ok, view, _html} = live(c.conn, "#{c.root}/_desk/#{c.type};#{c.id}")
    Map.merge(c, %{view: view, ws: Tenancy.get_default_workspace()})
  end

  defp cut!(c, change) do
    hash = ApiToken.hash_token(c.conn.private.plug_session["api_token"])

    {:ok, _} =
      ApiToken |> Repo.get_by!(token_hash: hash) |> Ecto.Changeset.change(change) |> Repo.update()
  end

  defp name, do: "fresh-#{System.unique_integer([:positive])}"
  defp project?(c, name), do: Enum.any?(Tenancy.list_projects(c.ws.id), &(&1.name == name))
  defp workspace?(name), do: Enum.any?(Tenancy.list_workspaces(), &(&1.name == name))

  test "a token cut to read under the open desk creates no project", c do
    cut!(c, permissions: ["read"])
    n = name()

    html = render_submit(c.view, "create-project", %{"name" => n})

    refute project?(c, n)
    assert html =~ "You need write access in this workspace to create a project"
  end

  test "a token cut to read under the open desk creates no workspace", c do
    cut!(c, permissions: ["read"])
    n = name()

    html = render_submit(c.view, "create-workspace", %{"name" => n})

    refute workspace?(n)
    assert html =~ "You need write access in this workspace to create a workspace"
  end

  test "a token revoked under the open desk creates neither", c do
    cut!(c, revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
    {p, w} = {name(), name()}

    assert render_submit(c.view, "create-project", %{"name" => p}) =~
             "Sign in to create a project"

    assert render_submit(c.view, "create-workspace", %{"name" => w}) =~
             "Sign in to create a workspace"

    refute project?(c, p)
    refute workspace?(w)
  end

  test "control: the token keeps write: the desk creates the project and the workspace", c do
    {p, w} = {name(), name()}

    assert {:error, {:live_redirect, _}} = render_submit(c.view, "create-project", %{"name" => p})
    assert project?(c, p)

    {:ok, view, _html} = live(c.conn, "#{c.root}/_desk/#{c.type};#{c.id}")
    assert {:error, {:live_redirect, _}} = render_submit(view, "create-workspace", %{"name" => w})
    assert workspace?(w)
  end
end
