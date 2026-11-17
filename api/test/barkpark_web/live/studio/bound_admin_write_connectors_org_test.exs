defmodule BarkparkWeb.Studio.BoundAdminWriteConnectorsOrgTest do
  @moduledoc """
  The dataset-bound admin write rule (`BarkparkWeb.Studio.BoundAdminWrite`) on
  the Connectors page (connect and disconnect mint and revoke `connector:*`
  chat tokens; Add to Slack stages one) and on the org-admin page (SCIM token
  mint, MFA, session and sign-in policy).

  A bound admin session: `:enforce` refuses with the rule's flash and writes
  nothing; `:observe` writes as before plus one audit row each, with no token
  text in the row or the log. An unbound admin token and an account session
  are unchanged in `:enforce`, with no row. The other panels:
  `BoundAdminWriteTest`.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :capture_log

  import Ecto.Query
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Barkpark.{Accounts, Auth, Repo, Tenancy}
  alias Barkpark.Audit.Event
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Connectors.Catalog
  alias Barkpark.Scim.Token, as: ScimToken
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Test.ConnectorsBridgeStub, as: Stub
  alias BarkparkWeb.Plugs.DatasetBoundAdminWrites

  @admin ["read", "write", "admin"]
  @refusal "this token is bound to one dataset and cannot change workspace members, access, tokens or secrets"
  @secret "test-connect-secret"
  @key "8100000077"

  setup do
    Barkpark.TenancyFixtures.ensure_default_scope!()

    keys = [:dataset_bound_admin_reads, :operator_emails, :operator_token_ids]
    prior = Map.new(keys, &{&1, Application.get_env(:barkpark, &1)})

    on_exit(fn ->
      Enum.each(prior, fn {k, v} -> restore(k, v) end)
      Application.delete_env(:barkpark, Barkpark.Connectors)
    end)

    Application.put_env(:barkpark, :operator_emails, [])
    Application.put_env(:barkpark, :operator_token_ids, [])
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp mode!(mode), do: Application.put_env(:barkpark, :dataset_bound_admin_reads, mode)

  defp token!(ws_id, opts) do
    n = System.unique_integer([:positive])
    raw = "bound-write-co-#{n}"
    label = "bound-write-co-label-#{n}"
    {:ok, token} = Auth.create_token(raw, label, "production", @admin, ws_id, opts)
    %{raw: raw, id: token.id, label: label}
  end

  defp user_session!(ws_id) do
    email = "bound-write-co-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = TenancyAuth.create_membership(ws_id, user.id, "admin", "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, %{"user_session" => raw}}
  end

  defp as_token(token), do: %{"api_token" => token.raw}

  defp records,
    do: Repo.all(from(e in Event, where: e.action == ^DatasetBoundAdminWrites.action()))

  defp one_row!(token, ws_id, route, surface, log, before) do
    assert [row] = records() -- before
    assert row.actor_id == token.id and row.subject == token.id
    assert row.workspace_id == ws_id
    assert row.metadata["route"] == route
    assert row.metadata["surface"] == surface
    assert log =~ "dataset_bound_admin_write token_id=#{token.id}"

    text = inspect(Map.from_struct(row)) <> log

    for secret <- [token.raw, ApiToken.hash_token(token.raw), token.label],
        do: refute(text =~ secret)

    row
  end

  # ── Connectors ─────────────────────────────────────────────────────────

  defp connectors_ws! do
    n = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "bound-write-conn-#{n}", name: "Conn"})
    {:ok, _} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
    ws
  end

  defp admin!(ws, opts) do
    token = token!(nil, opts)
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "admin")
    token
  end

  defp configure(extra) do
    Application.put_env(
      :barkpark,
      Barkpark.Connectors,
      [bridge_url: "http://127.0.0.1:4020/connectors", bridge: Stub, connect_secret: @secret] ++
        extra
    )
  end

  defp script!(ws, extra \\ []) do
    Stub.start(%{
      workspace_id: ws.id,
      provider: "telegram",
      stage_pending: {:ok, %{}},
      validate: {:ok, %{install_key: @key, display_name: "Bound Bot"}},
      connect: {:ok, %{install_key: @key, mounted: true}},
      disconnect: {:ok, %{removed: true}}
    })

    configure(extra)
  end

  defp connectors(conn, ws, session),
    do: conn |> init_test_session(session) |> live("/w/#{ws.slug}/p/default/studio/connectors")

  defp connect(view) do
    view |> element(~s([data-test-id="connector-connect-telegram"])) |> render_click()

    view
    |> form(~s(#connectors-connect-modal form), %{"credential" => "123:abc"})
    |> render_submit()

    view |> element(~s([data-test-id="connectors-confirm-connect"])) |> render_click()
  end

  defp disconnect(view) do
    view |> element(~s([data-test-id="connector-disconnect-telegram"])) |> render_click()
    view |> element(~s([data-test-id="connectors-confirm-disconnect"])) |> render_click()
  end

  defp live_tokens(ws) do
    label = Catalog.token_label("telegram", @key)

    Repo.all(
      from(t in ApiToken,
        where: t.workspace_id == ^ws.id and t.label == ^label and is_nil(t.revoked_at)
      )
    )
  end

  defp oauth_tokens(ws), do: Auth.live_tokens_by_label(ws.id, "connector:slack:oauth")

  describe "ConnectorsLive connect / disconnect" do
    test "enforce: a bound admin session can neither connect nor disconnect", %{conn: conn} do
      ws = connectors_ws!()
      script!(ws)
      mode!(:enforce)
      bound = admin!(ws, dataset_bound: true)
      {:ok, view, _} = connectors(conn, ws, as_token(bound))

      assert connect(view) =~ @refusal
      assert live_tokens(ws) == []
      assert Catalog.installs_for_workspace(ws) == []

      {:ok, admin_view, _} = connectors(conn, ws, as_token(admin!(ws, [])))
      connect(admin_view)
      assert [_] = live_tokens(ws)

      {:ok, view, _} = connectors(conn, ws, as_token(bound))
      assert disconnect(view) =~ @refusal
      assert [_] = live_tokens(ws)
      assert [_] = Catalog.installs_for_workspace(ws)
      assert records() == []
    end

    test "observe: connect and disconnect go through, one row each naming the workspace",
         %{conn: conn} do
      ws = connectors_ws!()
      script!(ws)
      mode!(:observe)
      bound = admin!(ws, dataset_bound: true)
      {:ok, view, _} = connectors(conn, ws, as_token(bound))

      log = capture_log(fn -> assert connect(view) =~ "Telegram connected" end)
      assert [_] = live_tokens(ws)
      one_row!(bound, ws.id, "live ConnectorsLive.confirm_connect", "tokens_write", log, [])

      before = records()
      log = capture_log(fn -> assert disconnect(view) =~ "1 token revoked" end)
      assert live_tokens(ws) == []

      one_row!(
        bound,
        ws.id,
        "live ConnectorsLive.confirm_disconnect",
        "tokens_write",
        log,
        before
      )
    end

    test "Add to Slack: enforce stages nothing; observe stages and records one row",
         %{conn: conn} do
      ws = connectors_ws!()

      slack = [
        slack_client_id: "123.456",
        slack_redirect_uri: "https://example.test/connectors/oauth/slack/callback"
      ]

      script!(ws, slack)
      bound = admin!(ws, dataset_bound: true)

      mode!(:enforce)
      {:ok, view, _} = connectors(conn, ws, as_token(bound))
      html = render(view)
      assert html =~ @refusal
      refute html =~ "slack.com/oauth/v2/authorize"
      assert oauth_tokens(ws) == []
      assert Stub.calls() == []
      assert records() == []

      mode!(:observe)

      log =
        capture_log(fn ->
          {:ok, view, _} = connectors(conn, ws, as_token(bound))
          assert render(view) =~ "slack.com/oauth/v2/authorize"
        end)

      assert [_] = oauth_tokens(ws)
      one_row!(bound, ws.id, "live ConnectorsLive.slack_oauth_stage", "tokens_write", log, [])
    end

    test "controls in enforce: an unbound admin token and an account admin connect and disconnect, no row",
         %{conn: conn} do
      mode!(:enforce)

      for kind <- [:token, :user] do
        ws = connectors_ws!()
        script!(ws)

        session =
          case kind do
            :token -> as_token(admin!(ws, []))
            :user -> ws.id |> user_session!() |> elem(1)
          end

        {:ok, view, _} = connectors(conn, ws, session)
        assert connect(view) =~ "Telegram connected"
        assert [_] = live_tokens(ws)
        assert disconnect(view) =~ "1 token revoked"
        assert live_tokens(ws) == []
      end

      assert records() == []
    end
  end

  # ── OrgAdminLive ───────────────────────────────────────────────────────

  defp org! do
    slug = "bound-write-org-#{System.unique_integer([:positive])}"
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug <> "-ws", name: slug})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {org, ws}
  end

  @org_events [
    {"mint_scim", "tokens_write", %{}},
    {"toggle_require_mfa", "org_write", %{"to" => "true"}},
    {"set_session_policy", "org_write", %{"idle" => "600", "absolute" => ""}},
    {"set_allowed_auth_methods", "org_write", %{"methods" => ["sso"]}}
  ]

  defp fire(view, org, event, params) do
    params = Map.put(params, "org", org.id)

    if event in ["mint_scim", "toggle_require_mfa"],
      do: render_click(view, event, params),
      else: render_submit(view, event, params)
  end

  defp org_admin(conn, session),
    do: conn |> init_test_session(session) |> live("/studio/org-admin")

  defp scim_count(org),
    do: Repo.aggregate(from(t in ScimToken, where: t.organization_id == ^org.id), :count)

  defp policy(org) do
    org = Repo.reload!(org)

    {org.require_mfa, org.session_idle_timeout_seconds, org.session_absolute_lifetime_seconds,
     org.allowed_auth_methods}
  end

  describe "OrgAdminLive writes" do
    test "enforce: a bound admin session is refused on every write, nothing changes",
         %{conn: conn} do
      mode!(:enforce)
      {org, ws} = org!()
      bound = token!(ws.id, dataset_bound: true)
      was = policy(org)
      {:ok, view, _} = org_admin(conn, as_token(bound))

      for {event, _surface, params} <- @org_events,
          do: assert(fire(view, org, event, params) =~ @refusal)

      assert scim_count(org) == 0
      assert policy(org) == was
      assert records() == []
    end

    test "observe: every write goes through, one row each naming the organization",
         %{conn: conn} do
      mode!(:observe)
      {org, ws} = org!()
      bound = token!(ws.id, dataset_bound: true)
      was = policy(org)
      {:ok, view, _} = org_admin(conn, as_token(bound))

      for {event, surface, params} <- @org_events do
        before = records()
        log = capture_log(fn -> refute fire(view, org, event, params) =~ @refusal end)
        row = one_row!(bound, nil, "live OrgAdminLive.#{event}", surface, log, before)
        assert row.metadata["organization_id"] == org.id
      end

      assert scim_count(org) == 1
      assert policy(org) != was
    end

    test "controls in enforce: an unbound admin token and an account admin write, no row",
         %{conn: conn} do
      mode!(:enforce)

      for kind <- [:token, :user] do
        {org, ws} = org!()

        session =
          case kind do
            :token ->
              as_token(token!(ws.id, []))

            :user ->
              {user, session} = user_session!(ws.id)

              {:ok, _} =
                TenancyAuth.create_membership(
                  Tenancy.get_default_workspace().id,
                  user.id,
                  "admin",
                  "user"
                )

              session
          end

        {:ok, view, _} = org_admin(conn, session)

        for {event, _surface, params} <- @org_events,
            do: refute(fire(view, org, event, params) =~ @refusal)

        assert scim_count(org) == 1
      end

      assert records() == []
    end
  end
end
