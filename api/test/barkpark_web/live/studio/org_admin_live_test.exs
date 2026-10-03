defmodule BarkparkWeb.Studio.OrgAdminLiveTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Audit, Auth, Repo, Tenancy}
  alias Barkpark.Sso.Oidc
  alias Barkpark.Scim.Token
  import Ecto.Query

  @admin_token "org-admin-test-token"
  @junior_token "org-junior-test-token"

  setup %{conn: conn} do
    {:ok, _} =
      Auth.create_token(@admin_token, "test admin", "production", ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@junior_token, "test junior", "production", ["read"])
    {:ok, conn: conn}
  end

  defp org_with_ws(slug) do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug <> "-ws", name: "WS"})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {org, ws}
  end

  defp admin_conn(conn), do: init_test_session(conn, %{"api_token" => @admin_token})

  # task-05cf6cbd1b0460fe: every org's SCIM mint and identity policy is
  # instance-wide authority. With the operator allowlist armed, a non-operator
  # admin token must not mount the portal or fire its events.
  describe "operator tier (allowlist armed)" do
    setup do
      prev_emails = Application.get_env(:barkpark, :operator_emails)
      prev_ids = Application.get_env(:barkpark, :operator_token_ids)

      on_exit(fn ->
        if prev_emails,
          do: Application.put_env(:barkpark, :operator_emails, prev_emails),
          else: Application.delete_env(:barkpark, :operator_emails)

        if prev_ids,
          do: Application.put_env(:barkpark, :operator_token_ids, prev_ids),
          else: Application.delete_env(:barkpark, :operator_token_ids)
      end)

      op_raw = "org-admin-operator-#{System.unique_integer([:positive])}"
      {:ok, op} = Auth.create_token(op_raw, "operator", "production", ["read", "write", "admin"])
      Application.put_env(:barkpark, :operator_emails, [])
      %{op_raw: op_raw, op_id: op.id}
    end

    test "a non-operator admin token is refused at mount", %{conn: conn, op_id: op_id} do
      Application.put_env(:barkpark, :operator_token_ids, [op_id])
      org_with_ws("armedco")

      assert {:error, {:redirect, %{to: "/studio"}}} = live(admin_conn(conn), "/studio/org-admin")
    end

    test "the named operator still mounts and mints", %{conn: conn, op_raw: op_raw, op_id: op_id} do
      Application.put_env(:barkpark, :operator_token_ids, [op_id])
      {org, _ws} = org_with_ws("opco")

      {:ok, view, _html} =
        live(init_test_session(conn, %{"api_token" => op_raw}), "/studio/org-admin")

      view |> element(~s([data-mint-scim="opco"])) |> render_click()
      assert Repo.aggregate(from(t in Token, where: t.organization_id == ^org.id), :count) == 1
    end

    test "a socket mounted before the allowlist was armed cannot mint after", %{
      conn: conn,
      op_id: op_id
    } do
      Application.put_env(:barkpark, :operator_token_ids, [])
      {org, _ws} = org_with_ws("lateco")
      {:ok, view, _html} = live(admin_conn(conn), "/studio/org-admin")

      Application.put_env(:barkpark, :operator_token_ids, [op_id])
      html = view |> element(~s([data-mint-scim="lateco"])) |> render_click()

      assert html =~ "reserved for the platform operator"
      assert Repo.aggregate(from(t in Token, where: t.organization_id == ^org.id), :count) == 0
    end
  end

  describe "admin gate" do
    test "redirects to /studio when no session token", %{conn: conn} do
      conn = init_test_session(conn, %{})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/studio/org-admin")
    end

    test "redirects to /studio when token lacks admin permission", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @junior_token})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/studio/org-admin")
    end
  end

  describe "the portal renders per-org config" do
    test "shows the org, its SSO status, member count, and SCIM tokens", %{conn: conn} do
      org_with_ws("shellco")

      {:ok, _view, html} = live(admin_conn(conn), "/studio/org-admin")

      assert html =~ "Organization Admin"
      assert html =~ "shellco"
      # no SSO configured yet
      assert html =~ ~s(data-oidc="false")
      assert html =~ ~s(data-saml="false")
      assert html =~ "SCIM tokens"
    end

    test "reflects a configured OIDC connection", %{conn: conn} do
      {org, _ws} = org_with_ws("ssoco")

      {:ok, _} =
        Oidc.create_connection(%{
          organization_id: org.id,
          issuer: "https://idp",
          client_id: "c",
          client_secret: "s",
          authorization_endpoint: "https://idp/a",
          token_endpoint: "https://idp/t",
          jwks_uri: "https://idp/j"
        })

      {:ok, _view, html} = live(admin_conn(conn), "/studio/org-admin")
      assert html =~ ~s(data-oidc="true")
    end
  end

  describe "self-serve SCIM token minting" do
    test "clicking Mint SCIM token creates a token and shows the plaintext once", %{conn: conn} do
      {org, _ws} = org_with_ws("mintco")

      {:ok, view, _html} = live(admin_conn(conn), "/studio/org-admin")

      before = Repo.aggregate(from(t in Token, where: t.organization_id == ^org.id), :count)
      assert before == 0

      html = view |> element(~s([data-mint-scim="mintco"])) |> render_click()

      # the plaintext token is shown once, and a token now exists
      assert html =~ "shown again"
      assert html =~ "scim_"
      assert Repo.aggregate(from(t in Token, where: t.organization_id == ^org.id), :count) == 1
    end
  end

  describe "org-wide require-MFA toggle (era-w2-org-require-mfa)" do
    test "clicking the toggle flips the org flag and the rendered state", %{conn: conn} do
      {org, _ws} = org_with_ws("mfaco")

      {:ok, view, html} = live(admin_conn(conn), "/studio/org-admin")
      assert html =~ ~s(data-require-mfa="false")

      html = view |> element(~s([data-toggle-require-mfa="mfaco"])) |> render_click()
      assert html =~ ~s(data-require-mfa="true")
      assert Repo.reload!(org).require_mfa == true

      html = view |> element(~s([data-toggle-require-mfa="mfaco"])) |> render_click()
      assert html =~ ~s(data-require-mfa="false")
      assert Repo.reload!(org).require_mfa == false
    end
  end

  describe "allowed-auth-methods admin toggle (era-bl-allowed-auth-methods)" do
    # `Tenancy.Auth.create_membership/4` makes the user GOVERNED by the org —
    # without a membership the resolver returns nil for everyone and every
    # assertion below would pass whatever the toggle wrote (the OIDC-fixture
    # trap, one layer up). The resolver assertions are the ones that would go
    # vacuous, so the membership is what makes them real.
    defp governed_user!(ws) do
      uid = Ecto.UUID.generate()
      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, uid, "member", "user")
      uid
    end

    test "checking methods writes the sorted list and narrows the resolver", %{conn: conn} do
      {org, ws} = org_with_ws("aamco")
      uid = governed_user!(ws)

      {:ok, view, html} = live(admin_conn(conn), "/studio/org-admin")
      assert html =~ ~s(data-allowed-auth-methods="")
      assert Tenancy.auth_method_allowed_for_user?(uid, "password")

      html =
        view
        |> form(~s([data-allowed-auth-methods-form="aamco"]), %{"methods" => ["sso", "password"]})
        |> render_submit()

      # Stored sorted + deduped, so one policy has one byte shape.
      assert Repo.reload!(org).allowed_auth_methods == ["password", "sso"]
      assert html =~ ~s(data-allowed-auth-methods="password,sso")

      # And the policy actually BINDS: a method outside the list is refused.
      assert Tenancy.auth_method_allowed_for_user?(uid, "password")
      refute Tenancy.auth_method_allowed_for_user?(uid, "magic_link")
      refute Tenancy.auth_method_allowed_for_user?(uid, "passkey")
    end

    test "SSO-only is expressible and closes the consumer-social door too", %{conn: conn} do
      {org, ws} = org_with_ws("ssoonlyco")
      uid = governed_user!(ws)

      {:ok, view, _html} = live(admin_conn(conn), "/studio/org-admin")

      view
      |> form(~s([data-allowed-auth-methods-form="ssoonlyco"]), %{"methods" => ["sso"]})
      |> render_submit()

      assert Repo.reload!(org).allowed_auth_methods == ["sso"]
      assert Tenancy.auth_method_allowed_for_user?(uid, "sso")
      refute Tenancy.auth_method_allowed_for_user?(uid, "social")
      refute Tenancy.auth_method_allowed_for_user?(uid, "password")
    end

    # THE TRAP. Clearing must write NULL ("no policy, every door open"), never
    # [] ("an allow-list permitting nothing"), which the intersection resolver
    # turns into a lockout for every governed member — while the page still
    # renders like a working feature.
    test "clearing every box writes NULL, not [], and reopens every door", %{conn: conn} do
      {org, ws} = org_with_ws("clearco")
      uid = governed_user!(ws)

      {:ok, view, _html} = live(admin_conn(conn), "/studio/org-admin")

      view
      |> form(~s([data-allowed-auth-methods-form="clearco"]), %{"methods" => ["sso"]})
      |> render_submit()

      assert Repo.reload!(org).allowed_auth_methods == ["sso"]
      refute Tenancy.auth_method_allowed_for_user?(uid, "password")

      # Unchecking every box. NOTE the shape: a browser omits unchecked
      # checkboxes entirely, so the submit carries NO `methods` key at all.
      # This is driven through `render_submit/3` rather than `form/2` on
      # purpose — `form/2` rebuilds params from the RENDERED inputs, so it
      # would faithfully resubmit the still-checked "sso" box and silently
      # test the wrong thing (it did, on the first run of this test).
      html = render_submit(view, "set_allowed_auth_methods", %{"org" => org.id})

      cleared = Repo.reload!(org)
      assert cleared.allowed_auth_methods == nil
      refute cleared.allowed_auth_methods == []
      assert html =~ ~s(data-allowed-auth-methods="")

      # Zero tax restored: every door open again for the governed member.
      assert Tenancy.org_allowed_auth_methods_for_user(uid) == nil
      assert Tenancy.auth_method_allowed_for_user?(uid, "password")
      assert Tenancy.auth_method_allowed_for_user?(uid, "magic_link")
      assert Tenancy.auth_method_allowed_for_user?(uid, "sso")
    end

    # The same clear expressed the OTHER way a browser can produce it: an
    # explicitly empty list. Both shapes reach the handler and both must
    # become NULL — pinning only the absent-key shape would leave half the
    # lockout open.
    test "an explicitly EMPTY methods list also clears to NULL", %{conn: conn} do
      {org, _ws} = org_with_ws("emptyco")
      {:ok, _} = Tenancy.set_organization_allowed_auth_methods(org.id, ["sso"])

      {:ok, view, _html} = live(admin_conn(conn), "/studio/org-admin")

      render_submit(view, "set_allowed_auth_methods", %{"org" => org.id, "methods" => []})

      assert Repo.reload!(org).allowed_auth_methods == nil
    end
  end

  describe "audit activity" do
    test "recent audit events are listed", %{conn: conn} do
      org_with_ws("auditco")
      {:ok, _} = Audit.emit(%{category: "auth", action: "sso_login", actor_id: "u1"})

      {:ok, _view, html} = live(admin_conn(conn), "/studio/org-admin")
      assert html =~ "Recent activity"
      assert html =~ "sso_login"
    end
  end

  describe "trust and legal panel (era-w10-trust-panel)" do
    test "lists the four trust papers plus the status page, one click away", %{conn: conn} do
      {:ok, _view, html} = live(admin_conn(conn), "/studio/org-admin")

      assert html =~ "Trust and legal"

      assert html =~ ~s(href="/papers/soc2-controls-mapping")
      assert html =~ ~s(href="/papers/vulnerability-disclosure-policy")
      assert html =~ ~s(href="/papers/dpa-template")
      assert html =~ ~s(href="/papers/support-tiers")
      assert html =~ ~s(href="/status")
    end
  end

  # task-a0d8bdd7b5a518cc: the admin bar was checked only at mount, and the
  # per-event operator check admits everyone while the allowlist is unset.
  describe "an admin demoted after mount" do
    test "can no longer mint a SCIM token", %{conn: conn} do
      {org, _ws} = org_with_ws("demoteco")
      default_ws = Tenancy.get_default_workspace()

      {:ok, user} =
        Barkpark.Accounts.register_user(%{
          email: "org-admin-#{System.unique_integer([:positive])}@example.com",
          password: "correct-horse-battery"
        })

      {:ok, _} = Tenancy.Auth.create_membership(default_ws.id, user.id, "admin", "user")
      {:ok, raw} = Barkpark.Accounts.create_user_session_token(user)

      {:ok, view, _html} =
        live(init_test_session(conn, %{"user_session" => raw}), "/studio/org-admin")

      {:ok, _} =
        Tenancy.Members.update_role(default_ws.id, %{type: :user, id: user.id}, "member")

      view |> element(~s([data-mint-scim="demoteco"])) |> render_click()

      assert Repo.aggregate(from(t in Token, where: t.organization_id == ^org.id), :count) == 0,
             "a demoted admin minted a SCIM token"
    end
  end
end
