defmodule BarkparkWeb.StudioChromeTest do
  @moduledoc """
  The shared top-bar contract (BarkparkWeb.StudioChrome): every surface in
  the Studio layout renders the same chrome, and the switcher is SAFE
  everywhere — on non-StudioLive surfaces a switch is a navigation to the
  target scope's canonical URL (it used to crash MediaLive/ApiTesterLive:
  LiveScope assigned current_workspace so the switcher RENDERED, but only
  StudioLive defined the switch-* handlers).
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    ws_a = create_workspace!("chrome-a")
    {:ok, proj_a} = Tenancy.create_project_with_dataset(ws_a, %{name: "chrome-pa"})
    ws_b = create_workspace!("chrome-b")
    {:ok, _proj_b} = Tenancy.create_project_with_dataset(ws_b, %{name: "chrome-pb"})

    raw = "chrome-test-#{System.unique_integer([:positive])}"

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "chrome-member",
        dataset: @dataset,
        permissions: ["read", "write"]
      })
      |> Repo.insert()

    {:ok, _} = Tenancy.Auth.create_membership(ws_a.id, token.id, "member")
    {:ok, _} = Tenancy.Auth.create_membership(ws_b.id, token.id, "member")

    member_conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    %{member_conn: member_conn, ws_a: ws_a, proj_a: proj_a, ws_b: ws_b}
  end

  defp media_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/studio/#{@dataset}/media"

  describe "the switcher is safe on non-StudioLive surfaces (the crash kill)" do
    test "switch-workspace on MediaLive NAVIGATES to the target scope", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      {:ok, view, _html} = live(conn, media_url(ws_a, proj_a))

      # Pre-chrome this was a FunctionClauseError crash: MediaLive has no
      # switch-* handlers, yet the switcher rendered (LiveScope assigns).
      view
      |> element(~s{form[phx-change="switch-workspace"]})
      |> render_change(%{"workspace" => ws_b.slug})

      assert_redirect(view, "/w/#{ws_b.slug}/p/chrome-pb/studio/#{@dataset}")
    end

    test "switch-dataset on MediaLive navigates within the scope", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      {:ok, staging} = Tenancy.create_dataset(proj_a, %{slug: "staging", name: "staging"})

      {:ok, view, _html} = live(conn, media_url(ws_a, proj_a))

      view
      |> element(~s{form[phx-change="switch-dataset"]})
      |> render_change(%{"dataset" => staging.slug})

      assert_redirect(view, "/w/#{ws_a.slug}/p/#{proj_a.slug}/studio/staging")
    end

    test "a forged switch into a non-membership workspace is ignored", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      foreign = create_workspace!("chrome-foreign")
      {:ok, _} = Tenancy.create_project_with_dataset(foreign, %{name: "chrome-pf"})

      {:ok, view, _html} = live(conn, media_url(ws_a, proj_a))

      html =
        view
        |> element(~s{form[phx-change="switch-workspace"]})
        |> render_change(%{"workspace" => foreign.slug})

      # No navigation, no crash — the chrome guard mirrors StudioLive's.
      assert html =~ "media-explorer-host"
    end
  end

  describe "consistent chrome across surfaces" do
    test "MediaLive renders the full workspace switcher + tabs", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      {:ok, _view, html} = live(conn, media_url(ws_a, proj_a))

      assert html =~ ~s{phx-change="switch-workspace"}
      assert html =~ "studio-bar-tabs"
      assert html =~ "/w/#{ws_a.slug}/p/#{proj_a.slug}/studio/#{@dataset}/api-tester"
    end

    test "ApiTesterLive renders the switcher + tabs too", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      {:ok, _view, html} =
        live(conn, "/w/#{ws_a.slug}/p/#{proj_a.slug}/studio/#{@dataset}/api-tester")

      assert html =~ ~s{phx-change="switch-workspace"}
      assert html =~ "studio-bar-tabs"
    end
  end
end
