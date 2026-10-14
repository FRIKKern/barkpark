defmodule BarkparkWeb.Plugs.AuthDenyBranchTest do
  @moduledoc """
  task-36dc8313ef457d98 — the auth mutation sweep. 46 deny branches in the
  write gates (CallerContext, LiveAuth, 16 plugs) were flipped one at a time
  and the tests that exercise each gate were run. 37 mutations were killed.
  These tests pin the 8 killable survivors, each at the level of the gate
  itself, so a regression in that ONE branch reds by name even when a later
  gate would still refuse the request:

    * RRM1  RequireRecentMfa: no user/session is challenged (401 mfa_required).
    * ROM1  RequireOrgMfaEnrolment: no user is refused (403).
    * RSE1  RequireShareEditToken: a share-edit token scoped to ANOTHER
            ws/proj/dataset earns no write grant.
    * RSS1  RequireShareScope: a READ section share admits no write method.
    * RSS2  RequireShareScope: an item share link admits no write method.
    * RSS4  RequireShareScope: an item link minted for another project of the
            same workspace earns no grant.
    * RBS1  RequireBearerOrSessionToken: no credential at all is a 401.
    * CC5   CallerContext.from_conn: a plain member's workspace role never
            reads as owner/admin.

  RSS3 (drop the item link's workspace check) is an EQUIVALENT mutant and has
  no test here: the project check right after it implies the workspace (a
  project belongs to exactly one workspace), so no request can tell the two
  apart.

  Every refusal sits next to a control on the same gate that proves the
  allowed path still passes, so a refusal cannot be vacuous.
  """

  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Sharing}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content.CallerContext
  alias Barkpark.Sharing.Links
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Plugs

  @dataset "production"

  defp with_shares(entry) do
    original = Application.get_env(:barkpark, :shares)
    Application.put_env(:barkpark, :shares, Sharing.parse(entry))
    on_exit(fn -> Application.put_env(:barkpark, :shares, original || []) end)
  end

  defp plug_conn(method, ws, proj, extra_params \\ %{}, query \\ "") do
    path = "/w/#{ws.slug}/p/#{proj.slug}/v1/data/x/#{@dataset}" <> query

    Phoenix.ConnTest.build_conn(method, path)
    |> Map.put(
      :path_params,
      Map.merge(
        %{"workspace_slug" => ws.slug, "project_slug" => proj.slug, "dataset" => @dataset},
        extra_params
      )
    )
  end

  defp ws_proj! do
    ws = create_workspace!("deny-#{System.unique_integer([:positive])}")
    proj = create_project!(ws)
    {ws, proj}
  end

  defp user! do
    {:ok, user} =
      Accounts.register_user(%{
        email: "deny-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    user
  end

  defp share_edit_token(scope),
    do: %ApiToken{kind: "api", permissions: ["share-edit-docs"], share_scope: scope}

  defp item_link!(ws, proj, ref_id) do
    {:ok, {raw, _link}} =
      Links.create(%{
        workspace_id: ws.id,
        project_id: proj.id,
        dataset: @dataset,
        kind: "doc",
        ref_type: "post",
        ref_id: ref_id,
        access: "edit"
      })

    raw
  end

  describe "RRM1 / ROM1 — the MFA plugs refuse a request with no user" do
    test "RequireRecentMfa challenges a conn with no user or session" do
      conn = Plugs.RequireRecentMfa.call(scoped_conn(), [])
      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "mfa_required"
    end

    test "RequireOrgMfaEnrolment refuses a conn with no user" do
      conn = Plugs.RequireOrgMfaEnrolment.call(scoped_conn(), [])
      assert conn.halted
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "mfa_enrolment_required"
    end

    test "control: a user with no MFA requirement passes both" do
      user = user!()
      conn = scoped_conn() |> assign(:current_user, user)
      refute Plugs.RequireOrgMfaEnrolment.call(conn, []).halted
    end
  end

  describe "RSE1 — RequireShareEditToken binds the token to ITS OWN share scope" do
    setup do
      {ws, proj} = ws_proj!()
      with_shares("#{ws.slug}/#{proj.slug}/#{@dataset}:docs:edit")
      %{ws: ws, proj: proj}
    end

    test "a share-edit token scoped elsewhere earns no write grant", %{ws: ws, proj: proj} do
      conn =
        plug_conn(:post, ws, proj)
        |> assign(:api_token, share_edit_token("other-ws/#{proj.slug}/#{@dataset}"))
        |> Plugs.RequireShareEditToken.call(%{surface: :docs})

      refute conn.assigns[:share_writer]
      refute conn.assigns[:share_public]
    end

    test "control: the token scoped to this ws/proj/dataset is granted", %{ws: ws, proj: proj} do
      conn =
        plug_conn(:post, ws, proj)
        |> assign(:api_token, share_edit_token("#{ws.slug}/#{proj.slug}/#{@dataset}"))
        |> Plugs.RequireShareEditToken.call(%{surface: :docs})

      assert conn.assigns[:share_writer] == true
    end
  end

  describe "RSS1 / RSS2 / RSS4 — RequireShareScope grants reads, never writes" do
    test "RSS1: a READ section share admits GET but not POST" do
      {ws, proj} = ws_proj!()
      with_shares("#{ws.slug}/#{proj.slug}/#{@dataset}:docs:read")

      read = plug_conn(:get, ws, proj) |> Plugs.RequireShareScope.call(%{surface: :docs})
      assert read.assigns[:share_public] == true

      write = plug_conn(:post, ws, proj) |> Plugs.RequireShareScope.call(%{surface: :docs})
      refute write.assigns[:share_public], "a read-only share admitted a write method"
    end

    test "RSS2: an item share link admits GET but not POST, even an edit link" do
      {ws, proj} = ws_proj!()
      raw = item_link!(ws, proj, "doc-1")

      read =
        plug_conn(:get, ws, proj, %{"doc_id" => "doc-1"}, "?share=#{raw}")
        |> Plugs.RequireShareScope.call(%{surface: :docs})

      assert read.assigns[:share_grant] == :item

      write =
        plug_conn(:post, ws, proj, %{"doc_id" => "doc-1"}, "?share=#{raw}")
        |> Plugs.RequireShareScope.call(%{surface: :docs})

      refute write.assigns[:share_public], "an item link admitted a write method"
    end

    test "RSS4: a link minted for another project of the same workspace earns no grant" do
      {ws, proj_a} = ws_proj!()
      proj_b = create_project!(ws)
      raw = item_link!(ws, proj_a, "doc-1")

      other =
        plug_conn(:get, ws, proj_b, %{"doc_id" => "doc-1"}, "?share=#{raw}")
        |> Plugs.RequireShareScope.call(%{surface: :docs})

      refute other.assigns[:share_public], "a link for project A opened project B"

      own =
        plug_conn(:get, ws, proj_a, %{"doc_id" => "doc-1"}, "?share=#{raw}")
        |> Plugs.RequireShareScope.call(%{surface: :docs})

      assert own.assigns[:share_grant] == :item
    end
  end

  describe "RBS1 — RequireBearerOrSessionToken refuses no credential at all" do
    test "no bearer, no session token, no account session is a 401" do
      conn =
        scoped_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plugs.RequireBearerOrSessionToken.call([])

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "CC5 — CallerContext.from_conn reads the user's REAL workspace role" do
    setup do
      {ws, _proj} = ws_proj!()
      %{ws: ws}
    end

    test "a plain member is not admin", %{ws: ws} do
      user = user!()
      {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")

      ctx =
        CallerContext.from_conn(%{
          assigns: %{current_user: user, current_workspace: ws}
        })

      assert ctx.roles == ["member"]
      refute ctx.is_admin
    end

    test "control: an owner is admin", %{ws: ws} do
      user = user!()
      {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "owner", "user")

      ctx = CallerContext.from_conn(%{assigns: %{current_user: user, current_workspace: ws}})
      assert ctx.is_admin
    end
  end
end
