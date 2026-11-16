defmodule BarkparkWeb.Studio.OrgAdminLiveOrgScopeTest do
  # task-4d44f2aefec77aff: with the operator allowlist unset, the org-admin page
  # listed every organization and let any admin mint SCIM tokens and change the
  # MFA, session and sign-in policy of any of them. A viewer now sees and acts
  # on an organization only when they hold an admin seat in every one of its
  # workspaces; a listed operator still sees and acts on all. Every event is
  # re-checked against the organization it names, not against what rendered.
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Repo, Tenancy}
  alias Barkpark.Scim.Token

  @refused "You do not administer this organization."

  setup do
    prev =
      {Application.get_env(:barkpark, :operator_emails),
       Application.get_env(:barkpark, :operator_token_ids)}

    on_exit(fn ->
      {emails, ids} = prev
      restore(:operator_emails, emails)
      restore(:operator_token_ids, ids)
    end)

    Application.put_env(:barkpark, :operator_emails, [])
    Application.put_env(:barkpark, :operator_token_ids, [])

    n = System.unique_integer([:positive])
    {org_a, ws_a} = org_with_ws("oscope-a-#{n}")
    {org_b, _ws_b} = org_with_ws("oscope-b-#{n}")

    raw = "org-scope-#{n}"

    {:ok, token} =
      Auth.create_token(raw, "admin of A", "production", ~w(read write admin), ws_a.id)

    %{raw: raw, token: token, org_a: org_a, ws_a: ws_a, org_b: org_b}
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp org_with_ws(slug) do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug <> "-ws", name: slug})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {org, ws}
  end

  defp open(conn, raw),
    do: live(init_test_session(conn, %{"api_token" => raw}), "/studio/org-admin")

  defp scim_count(org),
    do: Repo.aggregate(from(t in Token, where: t.organization_id == ^org.id), :count)

  defp unchanged?(org) do
    now = Repo.reload!(org)

    now.require_mfa == org.require_mfa and
      now.session_idle_timeout_seconds == org.session_idle_timeout_seconds and
      now.session_absolute_lifetime_seconds == org.session_absolute_lifetime_seconds and
      now.allowed_auth_methods == org.allowed_auth_methods
  end

  describe "an admin of workspace A, allowlist unset" do
    test "an admin of workspace A cannot see or mint a SCIM token for an organisation they do not administer",
         %{conn: conn, raw: raw, org_a: org_a, org_b: org_b} do
      {:ok, view, html} = open(conn, raw)

      assert html =~ ~s(data-org="#{org_a.slug}")
      refute html =~ org_b.slug

      html = render_click(view, "mint_scim", %{"org" => org_b.id})
      assert html =~ @refused
      refute html =~ "scim_"
      assert scim_count(org_b) == 0
    end

    test "cannot toggle MFA for an organisation they do not administer",
         %{conn: conn, raw: raw, org_b: org_b} do
      {:ok, view, _html} = open(conn, raw)

      assert render_click(view, "toggle_require_mfa", %{"org" => org_b.id, "to" => "true"}) =~
               @refused

      assert unchanged?(org_b)
    end

    test "cannot set the session policy of an organisation they do not administer",
         %{conn: conn, raw: raw, org_b: org_b} do
      {:ok, view, _html} = open(conn, raw)

      html =
        render_submit(view, "set_session_policy", %{
          "org" => org_b.id,
          "idle" => "60",
          "absolute" => "120"
        })

      assert html =~ @refused
      assert unchanged?(org_b)
    end

    test "cannot set the sign-in methods of an organisation they do not administer",
         %{conn: conn, raw: raw, org_b: org_b} do
      {:ok, view, _html} = open(conn, raw)

      html =
        render_submit(view, "set_allowed_auth_methods", %{"org" => org_b.id, "methods" => ["sso"]})

      assert html =~ @refused
      assert unchanged?(org_b)
    end

    test "an organisation that also holds a workspace they do not administer is not theirs",
         %{conn: conn, raw: raw, token: token} do
      {mixed, ws_own} = org_with_ws("oscope-mixed-#{System.unique_integer([:positive])}")
      {:ok, _} = Tenancy.Auth.create_membership(ws_own.id, token.id, "admin", "api_token")
      {:ok, other} = Tenancy.create_workspace(%{slug: "#{mixed.slug}-other", name: "other"})
      {:ok, _} = Tenancy.assign_workspace_to_organization(other, mixed.id)

      {:ok, view, html} = open(conn, raw)
      refute html =~ mixed.slug

      assert render_click(view, "mint_scim", %{"org" => mixed.id}) =~ @refused

      render_submit(view, "set_allowed_auth_methods", %{"org" => mixed.id, "methods" => ["sso"]})
      assert scim_count(mixed) == 0
      assert unchanged?(mixed)
    end

    test "a forged or missing org id is refused without a crash", %{conn: conn, raw: raw} do
      {:ok, view, _html} = open(conn, raw)

      assert render_click(view, "mint_scim", %{"org" => "not-a-uuid"}) =~ @refused
      assert render_click(view, "mint_scim", %{"org" => Ecto.UUID.generate()}) =~ @refused
      assert render_click(view, "toggle_require_mfa", %{"to" => "true"}) =~ @refused
      assert render_click(view, "no_such_event", %{}) =~ @refused
    end

    test "their own organisation still works for every action",
         %{conn: conn, raw: raw, org_a: org_a} do
      {:ok, view, _html} = open(conn, raw)

      assert render_click(view, "mint_scim", %{"org" => org_a.id}) =~ "scim_"
      assert scim_count(org_a) == 1

      render_click(view, "toggle_require_mfa", %{"org" => org_a.id, "to" => "true"})
      render_submit(view, "set_session_policy", %{"org" => org_a.id, "idle" => "60"})

      render_submit(view, "set_allowed_auth_methods", %{
        "org" => org_a.id,
        "methods" => ["password", "sso"]
      })

      org_a = Repo.reload!(org_a)
      assert org_a.require_mfa
      assert org_a.session_idle_timeout_seconds == 60
      assert org_a.allowed_auth_methods == ["password", "sso"]
    end

    test "a user session sees the organisation of the workspace they own, not another",
         %{conn: conn, ws_a: ws_a, org_a: org_a, org_b: org_b} do
      {:ok, user} =
        Barkpark.Accounts.register_user(%{
          email: "org-scope-#{System.unique_integer([:positive])}@example.com",
          password: "correct-horse-battery"
        })

      {:ok, _} = Tenancy.Auth.create_membership(ws_a.id, user.id, "owner", "user")

      {:ok, _} =
        Tenancy.Auth.create_membership(
          Tenancy.get_default_workspace().id,
          user.id,
          "admin",
          "user"
        )

      {:ok, session} = Barkpark.Accounts.create_user_session_token(user)

      {:ok, view, html} =
        live(init_test_session(conn, %{"user_session" => session}), "/studio/org-admin")

      assert html =~ ~s(data-org="#{org_a.slug}")
      refute html =~ org_b.slug
      assert render_click(view, "mint_scim", %{"org" => org_b.id}) =~ @refused
      assert scim_count(org_b) == 0
    end
  end

  test "a listed operator still sees and acts on every organisation",
       %{conn: conn, raw: raw, token: token, org_b: org_b} do
    Application.put_env(:barkpark, :operator_token_ids, [token.id])

    {:ok, view, html} = open(conn, raw)
    assert html =~ ~s(data-org="#{org_b.slug}")

    view |> element(~s([data-mint-scim="#{org_b.slug}"])) |> render_click()
    assert scim_count(org_b) == 1

    render_submit(view, "set_session_policy", %{"org" => org_b.id, "idle" => "90"})
    assert Repo.reload!(org_b).session_idle_timeout_seconds == 90
  end

  test "the page mounts for the same people with the allowlist unset and set",
       %{conn: conn, raw: raw, token: token, org_a: org_a} do
    flat = "org-scope-flat-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(flat, "flat admin", "production", ~w(read write admin))

    # Unset: the seated admin and a flat admin token with no seat both mount;
    # the flat token administers no organization, so it sees none.
    assert {:ok, _view, _html} = open(conn, raw)
    assert {:ok, _view, html} = open(conn, flat)
    refute html =~ org_a.slug

    # Set and naming the seated token: only it mounts, as before this change.
    Application.put_env(:barkpark, :operator_token_ids, [token.id])
    assert {:ok, _view, _html} = open(conn, raw)
    assert {:error, {:redirect, %{to: "/studio"}}} = open(conn, flat)
  end
end
