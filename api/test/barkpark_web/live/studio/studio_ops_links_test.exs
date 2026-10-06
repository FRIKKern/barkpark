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

  # Gate agreement (lead check on #21903): the chrome hides a link exactly when
  # the REAL `{LiveAuth, :ops}` gate would refuse the same viewer. The resolver
  # tests' viewer was an anonymous conn; it may mount the scoped Studio, but the
  # ops consoles behind those links refuse it.
  describe "agreement with the real :ops gate" do
    test "the anonymous viewer that mounts Studio is refused by the ops consoles", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio"))
      refute LiveAuth.ops_access?(nil, nil)

      for path <- ["/admin/projects", "/admin/onixedit/staleness"] do
        assert LiveAuth.ops_gated_path?(path)

        # The real gate refuses the anonymous viewer the hidden link was shown to.
        result = live(conn, path)

        assert match?(
                 {:error, {:redirect, %{flash: %{"error" => "Operator access required"}}}},
                 result
               ),
               "#{path} must refuse the anonymous viewer; got #{inspect(result)}"
      end
    end

    test "an admin is admitted to an ops console", %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, %{"api_token" => @admin})
      assert LiveAuth.ops_access?(token(@admin), nil)
      assert {:ok, _view, _html} = live(conn, "/admin/projects")
    end

    test "a non-ops plugin link stays visible to a member", %{conn: conn, ws_id: ws_id} do
      {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()

      {:ok, _} =
        Barkpark.Plugins.Bootstrap.install_for_plugin(
          %{name: "frt", module: Barkpark.Plugins.Frt},
          {ws.id, project.id}
        )

      {:ok, _} =
        Barkpark.Tenancy.set_workspace_plugin_settings(ws_id, %{"frt" => %{"enabled" => true}})

      # The FRT plugin's desk group, under the Plugins tier: singleton links to
      # Studio documents, routes the `:ops` gate does not guard.
      {:ok, _view, html} =
        live(
          member_conn(conn, ws_id),
          scoped_studio("/d/#{@dataset}/studio/plugins/plugin-grp-frt")
        )

      # Its first subgroup holds the singleton links; the ids are derived, so
      # read it off the pane rather than hard-coding it.
      [_, nest] = Regex.run(~r/phx-value-id="(plugin-nest-[^"]+)"/, html)

      {:ok, _view, html} =
        live(
          member_conn(conn, ws_id),
          scoped_studio("/d/#{@dataset}/studio/plugins/plugin-grp-frt/#{nest}")
        )

      hrefs =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query(~s(a[data-test-id="nav-plugin-entry"]))
        |> LazyHTML.attribute("href")

      assert Enum.any?(hrefs, &String.contains?(&1, "/studio/")),
             "a plugin link to a Studio route must stay visible to a member; got #{inspect(hrefs)}"

      refute Enum.any?(hrefs, &LiveAuth.ops_gated_path?/1)
    end
  end
end
