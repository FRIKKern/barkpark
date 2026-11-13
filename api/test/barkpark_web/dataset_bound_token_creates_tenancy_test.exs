defmodule BarkparkWeb.DatasetBoundTokenCreatesTenancyTest do
  @moduledoc """
  A token minted with an explicit dataset is held to that dataset. Making a
  project (which comes with its own `production` dataset) or a workspace makes
  datasets outside the binding, and the request names no dataset, so the
  request-level fence has nothing to compare. Every door refuses it: the
  `create-project` and `create-workspace` events, on the Studio itself
  (StudioLive answers them) and on the other pages (the chrome answers them),
  and their REST twins.
  An unbound token with the same seat still creates (control).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Repo, Tenancy}
  alias Barkpark.Tenancy.Workspace

  @own "bound-own"

  setup do
    ws = create_workspace!("bound-create-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    {:ok, _} = Tenancy.get_or_create_dataset(proj, @own)

    {:ok, ws: ws, base: "/w/#{ws.slug}/p/default/d/#{@own}/studio"}
  end

  # "" is the Studio itself (StudioLive); "/media" is a page the chrome answers.
  @pages [{"the Studio", ""}, {"a chrome page", "/media"}]

  defp token!(ws, opts) do
    raw = "bound-create-tok-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(raw, "bound create", @own, ["read", "write", "admin"], ws.id, opts)

    raw
  end

  defp studio(conn, raw), do: Plug.Test.init_test_session(conn, %{"api_token" => raw})
  defp bearer(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp name, do: "made-#{System.unique_integer([:positive])}"
  defp project?(ws, name), do: Enum.any?(Tenancy.list_projects(ws.id), &(&1.name == name))
  defp workspace?(name), do: Repo.get_by(Workspace, name: name) != nil

  describe "a dataset-bound token" do
    for {label, path} <- @pages do
      test "is refused create-project on #{label}", %{conn: conn, ws: ws, base: base} do
        page = base <> unquote(path)
        {:ok, view, _} = live(studio(conn, token!(ws, dataset_bound: true)), page)
        name = name()

        assert render_submit(view, "create-project", %{"name" => name}) =~ "bound to one dataset"
        refute project?(ws, name)
      end

      test "is refused create-workspace on #{label}", %{conn: conn, ws: ws, base: base} do
        page = base <> unquote(path)
        {:ok, view, _} = live(studio(conn, token!(ws, dataset_bound: true)), page)
        name = name()

        assert render_submit(view, "create-workspace", %{"name" => name}) =~
                 "bound to one dataset"

        refute workspace?(name)
      end
    end

    test "is refused POST /api/workspaces/:slug/projects", %{conn: conn, ws: ws} do
      name = name()

      conn =
        conn
        |> bearer(token!(ws, dataset_bound: true))
        |> post("/api/workspaces/#{ws.slug}/projects", %{"name" => name})

      assert json_response(conn, 403)
      refute project?(ws, name)
    end

    test "is refused POST /api/workspaces", %{conn: conn, ws: ws} do
      name = name()

      conn =
        conn
        |> bearer(token!(ws, dataset_bound: true))
        |> post("/api/workspaces", %{"name" => name})

      assert json_response(conn, 403)
      refute workspace?(name)
    end
  end

  describe "an unbound token with the same seat (control)" do
    for {label, path} <- @pages do
      test "creates a project on #{label}", %{conn: conn, ws: ws, base: base} do
        {:ok, view, _} = live(studio(conn, token!(ws, [])), base <> unquote(path))
        name = name()

        _ = render_submit(view, "create-project", %{"name" => name})
        assert project?(ws, name)
      end

      test "creates a workspace on #{label}", %{conn: conn, ws: ws, base: base} do
        {:ok, view, _} = live(studio(conn, token!(ws, [])), base <> unquote(path))
        name = name()

        _ = render_submit(view, "create-workspace", %{"name" => name})
        assert workspace?(name)
      end
    end

    test "creates a project over REST", %{conn: conn, ws: ws} do
      name = name()

      conn =
        conn
        |> bearer(token!(ws, []))
        |> post("/api/workspaces/#{ws.slug}/projects", %{"name" => name})

      assert json_response(conn, 201)
      assert project?(ws, name)
    end

    test "creates a workspace over REST", %{conn: conn, ws: ws} do
      name = name()
      conn = conn |> bearer(token!(ws, [])) |> post("/api/workspaces", %{"name" => name})

      assert json_response(conn, 201)
      assert workspace?(name)
    end
  end
end
