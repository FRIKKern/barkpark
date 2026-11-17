defmodule BarkparkWeb.Studio.BoundAdminWriteTest do
  @moduledoc """
  The dataset-bound admin write rule on Studio's admin actions
  (`BarkparkWeb.Studio.BoundAdminWrite`): the Access panel's grant revoke, the
  Shares panel's add and remove, MediaLive's media publish and the Chat hosts
  page's enroll and revoke.

  For a session signed in with a dataset-bound admin token, `:enforce` refuses
  with the rule's flash and writes nothing; `:observe` writes as before plus
  one audit row naming the workspace written, with no token text in the row or
  the log. An unbound admin token and an account session are unchanged in
  `:enforce`, with no row. Connectors and org-admin:
  `BoundAdminWriteConnectorsOrgTest`.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :capture_log
  @moduletag :requires_plugins

  import Ecto.Query
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Barkpark.{Access, Accounts, Auth, ChatHosts, Repo, Sharing, Tenancy}
  alias Barkpark.Access.Grant
  alias Barkpark.Audit.Event
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.TenancyFixtures
  alias BarkparkWeb.Plugs.DatasetBoundAdminWrites

  @admin ["read", "write", "admin"]
  @refusal "this token is bound to one dataset and cannot change workspace members, access, tokens or secrets"

  setup %{conn: conn} do
    {ws, proj} = TenancyFixtures.ensure_default_scope!()
    {:ok, _} = Tenancy.get_or_create_dataset(proj, "production")
    {:ok, _} = Tenancy.get_or_create_dataset(proj, "staging")

    previous = Application.get_env(:barkpark, :dataset_bound_admin_reads)
    prior_shares = Application.get_env(:barkpark, :shares)
    prior_env = Application.get_env(:barkpark, :shares_env)
    Application.put_env(:barkpark, :shares, [])
    Application.put_env(:barkpark, :shares_env, [])

    on_exit(fn ->
      restore(:dataset_bound_admin_reads, previous)
      restore(:shares, prior_shares)
      restore(:shares_env, prior_env)
    end)

    {:ok,
     conn: conn,
     ws: ws,
     proj: proj,
     bound: token!(ws.id, dataset_bound: true),
     unbound: token!(ws.id, [])}
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp mode!(mode), do: Application.put_env(:barkpark, :dataset_bound_admin_reads, mode)

  defp token!(ws_id, opts) do
    n = System.unique_integer([:positive])
    raw = "bound-write-live-#{n}"
    label = "bound-write-label-#{n}"
    {:ok, token} = Auth.create_token(raw, label, "production", @admin, ws_id, opts)
    %{raw: raw, id: token.id, struct: token, label: label}
  end

  defp user_session!(ws_id, role) do
    email = "bound-write-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = TenancyAuth.create_membership(ws_id, user.id, role, "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    %{"user_session" => raw}
  end

  defp records,
    do: Repo.all(from(e in Event, where: e.action == ^DatasetBoundAdminWrites.action()))

  # One new row (beyond `before`) for `token`, naming `ws_id` and `route`, with
  # no token text in the row or in `log`. Audit rows are append-only.
  defp one_row!(token, ws_id, route, surface, log, before \\ []) do
    assert [row] = records() -- before
    assert row.actor_id == token.id and row.subject == token.id
    assert row.actor_type == "api_token" and row.category == "access"
    assert row.workspace_id == ws_id
    assert row.metadata["route"] == route
    assert row.metadata["surface"] == surface
    assert log =~ "dataset_bound_admin_write token_id=#{token.id}"

    text = inspect(Map.from_struct(row)) <> log

    for secret <- [token.raw, ApiToken.hash_token(token.raw), token.label],
        do: refute(text =~ secret)
  end

  defp studio(conn, session),
    do: conn |> init_test_session(session) |> live(scoped_studio("/d/production/studio"))

  defp as_token(token), do: %{"api_token" => token.raw}

  # ── Access panel: access-revoke ────────────────────────────────────────

  defp staging_grant!(ctx) do
    {:ok, minted} =
      Access.mint(ctx.unbound.struct, %{
        "workspace_id" => ctx.ws.id,
        "project_id" => ctx.proj.id,
        "dataset" => "staging",
        "grantee_email" => "bound-write-#{System.unique_integer([:positive])}@example.com",
        "capabilities" => ["read"]
      })

    grant =
      case minted do
        {%Grant{} = g, _raw} -> g
        %{grant: %Grant{} = g} -> g
        %Grant{} = g -> g
      end

    assert grant.dataset == "staging"
    grant
  end

  defp revoked?(grant), do: not is_nil(Repo.get!(Grant, grant.id).revoked_at)

  defp revoke_grant(ctx, session, grant) do
    {:ok, view, _} = studio(ctx.conn, session)
    render_hook(view, "access-open", %{})
    render_hook(view, "access-revoke", %{"id" => grant.id})
  end

  describe "Access panel access-revoke" do
    test "enforce: a bound admin session is refused and the grant stays", ctx do
      mode!(:enforce)
      grant = staging_grant!(ctx)
      html = revoke_grant(ctx, as_token(ctx.bound), grant)

      assert html =~ @refusal
      refute revoked?(grant)
      assert records() == []
    end

    test "observe: the revoke goes through, one row naming the grant's workspace", ctx do
      mode!(:observe)
      grant = staging_grant!(ctx)
      log = capture_log(fn -> revoke_grant(ctx, as_token(ctx.bound), grant) end)

      assert revoked?(grant)
      one_row!(ctx.bound, ctx.ws.id, "live StudioLive.access-revoke", "members_write", log)
    end

    test "controls in enforce: an unbound admin token and an account admin revoke, no row",
         ctx do
      mode!(:enforce)

      for session <- [as_token(ctx.unbound), user_session!(ctx.ws.id, "admin")] do
        grant = staging_grant!(ctx)
        html = revoke_grant(ctx, session, grant)
        refute html =~ @refusal
        assert revoked?(grant)
      end

      assert records() == []
    end
  end

  # ── Shares panel: shares-add / shares-remove ───────────────────────────

  defp staging_scope(ctx), do: "#{ctx.ws.slug}/#{ctx.proj.slug}/staging"
  defp staging_shared?(ctx), do: Sharing.shared?(ctx.ws.slug, ctx.proj.slug, "staging", :docs)

  defp share(view, ctx),
    do: render_hook(view, "shares-add", %{"scope" => staging_scope(ctx), "surfaces" => ["docs"]})

  defp unshare(view, ctx),
    do: render_hook(view, "shares-remove", %{"scope" => staging_scope(ctx)})

  describe "Shares panel shares-add / shares-remove" do
    test "enforce: a bound admin session can neither add nor remove a share", ctx do
      mode!(:enforce)
      {:ok, view, _} = studio(ctx.conn, as_token(ctx.bound))
      render_hook(view, "shares-open", %{})

      assert share(view, ctx) =~ @refusal
      refute staging_shared?(ctx)

      {:ok, _} = Sharing.add_share("#{staging_scope(ctx)}:docs:read")
      assert unshare(view, ctx) =~ @refusal
      assert staging_shared?(ctx)
      assert records() == []
    end

    test "observe: add then remove go through, one row each naming the scope's workspace",
         ctx do
      mode!(:observe)
      {:ok, view, _} = studio(ctx.conn, as_token(ctx.bound))
      render_hook(view, "shares-open", %{})

      log = capture_log(fn -> share(view, ctx) end)
      assert staging_shared?(ctx)
      one_row!(ctx.bound, ctx.ws.id, "live StudioLive.shares-add", "shares_write", log)

      before = records()
      log = capture_log(fn -> unshare(view, ctx) end)
      refute staging_shared?(ctx)

      one_row!(
        ctx.bound,
        ctx.ws.id,
        "live StudioLive.shares-remove",
        "shares_write",
        log,
        before
      )
    end

    test "controls in enforce: an unbound admin token and an account admin add and remove, no row",
         ctx do
      mode!(:enforce)

      for session <- [as_token(ctx.unbound), user_session!(ctx.ws.id, "admin")] do
        {:ok, view, _} = studio(ctx.conn, session)
        render_hook(view, "shares-open", %{})
        share(view, ctx)
        assert staging_shared?(ctx)
        unshare(view, ctx)
        refute staging_shared?(ctx)
      end

      assert records() == []
    end
  end

  # ── MediaLive: publish_scope_media ─────────────────────────────────────

  defp media_path(ctx), do: "/w/#{ctx.ws.slug}/p/#{ctx.proj.slug}/d/production/studio/media"
  defp media_shared?(ctx), do: Sharing.media_shared?(ctx.ws.slug, ctx.proj.slug, "production")

  defp publish_media(ctx, session) do
    {:ok, view, _} = ctx.conn |> init_test_session(session) |> live(media_path(ctx))
    render_click(view, "publish_scope_media", %{})
  end

  describe "MediaLive publish_scope_media" do
    test "enforce: a bound admin session is refused and nothing is published", ctx do
      mode!(:enforce)
      assert publish_media(ctx, as_token(ctx.bound)) =~ @refusal
      refute media_shared?(ctx)
      assert records() == []
    end

    test "observe: the publish goes through, one row naming the workspace", ctx do
      mode!(:observe)
      log = capture_log(fn -> publish_media(ctx, as_token(ctx.bound)) end)
      assert media_shared?(ctx)
      one_row!(ctx.bound, ctx.ws.id, "live MediaLive.publish_scope_media", "shares_write", log)
    end

    test "controls in enforce: an unbound admin token and an account admin publish, no row",
         ctx do
      mode!(:enforce)

      for session <- [as_token(ctx.unbound), user_session!(ctx.ws.id, "admin")] do
        Sharing.remove_share(ctx.ws.slug, ctx.proj.slug, "production")
        refute media_shared?(ctx)
        refute publish_media(ctx, session) =~ @refusal
        assert media_shared?(ctx)
      end

      assert records() == []
    end
  end

  # ── ChatHostsLive: enroll / revoke ─────────────────────────────────────

  defp hosts_ws! do
    n = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "bound-write-hosts-#{n}", name: "Hosts"})
    {:ok, _} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
    ws
  end

  defp owner!(ws, opts) do
    token = token!(nil, opts)
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")
    token
  end

  defp hosts_view(ctx, ws, session),
    do:
      ctx.conn |> init_test_session(session) |> live("/w/#{ws.slug}/p/default/studio/chat-hosts")

  defp enroll(view, name) do
    view
    |> form("form[phx-submit=enroll]", %{
      "host" => %{"name" => name, "approved_roots" => [System.tmp_dir!()]}
    })
    |> render_submit()
  end

  defp host_ids(ws), do: ws.id |> ChatHosts.list_hosts() |> Enum.map(& &1.id)
  defp host_names(ws), do: ws.id |> ChatHosts.list_hosts() |> Enum.map(& &1.name)

  defp old_host!(ws) do
    {:ok, %{host: %{id: id}}} = ChatHosts.issue_enrollment(ws.id, %{name: "old box"})
    id
  end

  describe "ChatHostsLive enroll / revoke" do
    test "enforce: a bound owner session can neither revoke nor enroll", ctx do
      mode!(:enforce)
      ws = hosts_ws!()
      bound = owner!(ws, dataset_bound: true)
      old = old_host!(ws)
      {:ok, view, _} = hosts_view(ctx, ws, as_token(bound))

      assert render_click(view, "revoke", %{"id" => old}) =~ @refusal
      assert old in host_ids(ws)

      html = enroll(view, "bound laptop")
      assert html =~ @refusal
      refute html =~ "One-time enrollment token"
      refute "bound laptop" in host_names(ws)
      assert records() == []
    end

    test "observe: revoke and enroll go through, one row each naming the workspace", ctx do
      mode!(:observe)
      ws = hosts_ws!()
      bound = owner!(ws, dataset_bound: true)
      old = old_host!(ws)
      {:ok, view, _} = hosts_view(ctx, ws, as_token(bound))

      log = capture_log(fn -> render_click(view, "revoke", %{"id" => old}) end)
      refute old in host_ids(ws)
      one_row!(bound, ws.id, "live ChatHostsLive.revoke", "tokens_write", log)

      before = records()

      log =
        capture_log(fn -> assert enroll(view, "bound laptop") =~ "One-time enrollment token" end)

      assert "bound laptop" in host_names(ws)
      one_row!(bound, ws.id, "live ChatHostsLive.enroll", "tokens_write", log, before)
    end

    test "controls in enforce: an unbound owner token and an account owner revoke and enroll, no row",
         ctx do
      mode!(:enforce)
      ws = hosts_ws!()
      unbound = owner!(ws, [])

      for {session, name} <- [
            {as_token(unbound), "token laptop"},
            {user_session!(ws.id, "owner"), "user laptop"}
          ] do
        old = old_host!(ws)
        {:ok, view, _} = hosts_view(ctx, ws, session)
        render_click(view, "revoke", %{"id" => old})
        refute old in host_ids(ws)
        assert enroll(view, name) =~ "One-time enrollment token"
      end

      assert records() == []
    end
  end
end
