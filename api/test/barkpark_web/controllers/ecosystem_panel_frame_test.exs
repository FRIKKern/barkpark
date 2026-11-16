defmodule BarkparkWeb.EcosystemPanelFrameTest do
  @moduledoc """
  task-d76b1c09fe303401 — the ecosystem panel frame,
  `GET /w/:ws/p/:proj/studio/ecosystem-panel/frame`.

  Only an owner or admin of the URL workspace (`Tenancy.Auth.workspace_admin?/2`
  on the signed-in user or the session token) gets the stored HTML. Every other
  caller gets no snapshot bytes: each refusal asserts the marker is absent from
  the body. The 200 carries the sandbox CSP and nothing else as its policy.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.EcosystemPanel
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.TenancyFixtures

  @marker "FRAME-SNAPSHOT-MARKER"
  @html "<!doctype html><title>eco</title><p>#{@marker}</p>"

  @csp "sandbox allow-scripts; default-src 'none'; script-src 'unsafe-inline'; " <>
         "style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; " <>
         "img-src data:; connect-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors 'self'"

  setup do
    ws_a = TenancyFixtures.create_workspace!()
    proj_a = TenancyFixtures.create_project!(ws_a)
    ws_b = TenancyFixtures.create_workspace!()
    proj_b = TenancyFixtures.create_project!(ws_b)
    {:ok, _} = EcosystemPanel.put(ws_a.id, @html, DateTime.utc_now())

    %{ws_a: ws_a, ws_b: ws_b, path_a: frame_path(ws_a, proj_a), path_b: frame_path(ws_b, proj_b)}
  end

  test "signed out with :studio_demo on, the frame answers no snapshot bytes" do
    # :studio_demo is on in test: :scoped_browser resolves the default
    # workspace for an anonymous visitor, so only the frame's own check stands.
    assert Application.get_env(:barkpark, :public_demo_studio) == true
    {default_ws, default_proj} = TenancyFixtures.ensure_default_scope!()
    {:ok, _} = EcosystemPanel.put(default_ws.id, @html, DateTime.utc_now())

    conn = get(scoped_conn(), frame_path(default_ws, default_proj))

    refute conn.resp_body =~ @marker
    assert redirected_to(conn) =~ "/login"
  end

  test "signed out with :studio_demo off, the frame answers no snapshot bytes", ctx do
    prev = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :public_demo_studio, false)
    on_exit(fn -> Application.put_env(:barkpark, :public_demo_studio, prev) end)

    conn = get(scoped_conn(), ctx.path_a)

    refute conn.resp_body =~ @marker
    assert redirected_to(conn) =~ "/login"
  end

  test "members, outsiders, global admins and the flat path get no snapshot bytes", ctx do
    {default_ws, _} = TenancyFixtures.ensure_default_scope!()

    member_user = user!([{ctx.ws_a, "member"}])
    owner_of_b = user!([{ctx.ws_b, "owner"}])
    # Owns the default workspace (the flat /studio admin gate's grant) but is
    # only a member of A.
    global_admin_user = user!([{default_ws, "owner"}, {ctx.ws_a, "member"}])
    admin_a = user!([{ctx.ws_a, "admin"}])

    # A token with global admin permission, seated in A as a plain member.
    {member_raw, member_tok} = token!(["read", "write", "admin"], default_ws.id)
    {:ok, _} = TenancyAuth.create_membership(ctx.ws_a.id, member_tok.id, "member")

    # An admin of A whose org requires MFA and who has no factor enrolled.
    mfa_blocked = user!([{ctx.ws_a, "admin"}])
    govern_mfa!(mfa_blocked)

    # The status pins which gate answered: 403 from the frame's own check (or
    # ResolveWorkspace for a non-member), 404 for the flat copy and for B's
    # missing row.
    refusals = [
      {"member user", user_conn(member_user), ctx.path_a, 403},
      {"member token session", token_session_conn(member_raw, member_tok), ctx.path_a, 403},
      {"owner of B opening A's frame", user_conn(owner_of_b), ctx.path_a, 403},
      {"owner of B with A's sha as cache-buster", user_conn(owner_of_b),
       ctx.path_b <> "?v=#{EcosystemPanel.get(ctx.ws_a.id).sha256}", 404},
      {"global-admin user with a member role in A", user_conn(global_admin_user), ctx.path_a,
       403},
      {"admin of A without the MFA their org requires", user_conn(mfa_blocked), ctx.path_a, 403},
      {"admin of A on the flat path", user_conn(admin_a), "/studio/ecosystem-panel/frame", 404},
      {"admin of A with an unknown slug", user_conn(admin_a),
       "/w/no-such-ws-#{System.unique_integer([:positive])}/p/x/studio/ecosystem-panel/frame",
       403}
    ]

    for {label, conn, path, status} <- refusals do
      conn = get(conn, path)
      assert conn.status == status, "#{label}: expected #{status}, got #{conn.status}"
      refute conn.resp_body =~ @marker, "#{label}: the body carried the snapshot"
    end

    assert get(user_conn(owner_of_b), ctx.path_b).resp_body =~ "No snapshot"
  end

  test "an admin of A gets the HTML with exactly the frame headers", ctx do
    admin_user = user!([{ctx.ws_a, "admin"}])
    {admin_raw, admin_tok} = token!(["read"], nil)
    {:ok, _} = TenancyAuth.create_membership(ctx.ws_a.id, admin_tok.id, "admin")

    for {label, conn} <- [
          {"admin user", user_conn(admin_user)},
          {"admin token session", token_session_conn(admin_raw, admin_tok)}
        ] do
      conn = get(conn, ctx.path_a <> "?v=cache-buster")

      assert conn.status == 200, "#{label}: got #{conn.status}"
      assert conn.resp_body == @html

      # The REAL header list, duplicates included: one policy, never the Studio one.
      assert headers(conn, "content-security-policy") == [@csp]
      assert headers(conn, "cache-control") == ["no-store"]
      assert headers(conn, "x-content-type-options") == ["nosniff"]
      assert headers(conn, "referrer-policy") == ["no-referrer"]
      assert headers(conn, "content-type") == ["text/html; charset=utf-8"]
      refute conn.resp_body =~ "nonce"
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp frame_path(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/studio/ecosystem-panel/frame"

  defp headers(conn, name), do: for({^name, value} <- conn.resp_headers, do: value)

  defp user!(memberships) do
    email = "eco-frame-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    for {ws, role} <- memberships do
      {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, role, "user")
    end

    user
  end

  defp user_conn(user) do
    {:ok, raw} = Accounts.create_user_session_token(user)
    Plug.Test.init_test_session(scoped_conn(), %{"user_session" => raw})
  end

  defp token!(permissions, workspace_id) do
    raw = "eco-frame-#{System.unique_integer([:positive])}"
    {:ok, tok} = Auth.create_token(raw, "eco frame test", "production", permissions, workspace_id)
    {raw, tok}
  end

  defp token_session_conn(raw, tok) do
    {:ok, session_id} = Auth.create_token_session(raw, tok)
    Plug.Test.init_test_session(scoped_conn(), %{"api_token_session" => session_id})
  end

  defp govern_mfa!(user) do
    slug = "eco-mfa-#{System.unique_integer([:positive])}"
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})
    {:ok, _org} = Tenancy.set_organization_require_mfa(org.id, true)
    gws = TenancyFixtures.create_workspace!()
    {:ok, gws} = Tenancy.assign_workspace_to_organization(gws, org.id)
    {:ok, _} = TenancyAuth.create_membership(gws.id, user.id, "member", "user")
  end
end
