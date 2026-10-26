defmodule BarkparkWeb.BreakglassLoginTest do
  @moduledoc """
  Break-glass sign-in (BARKPARK_BREAKGLASS_EMAILS): a listed account in an
  SSO-only org signs in with a password plus TOTP, and each such sign-in writes
  a `breakglass_login` audit event. A password alone stays refused, and an
  account that is not listed is refused as before.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.{Accounts, Repo, Tenancy}

  @password "correct-horse-battery"

  setup do
    on_exit(fn -> Application.delete_env(:barkpark, :breakglass_emails) end)
    :ok
  end

  defp user!(prefix) do
    email = "#{prefix}-#{System.unique_integer([:positive])}@breakglass.example"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  defp sso_only!(user) do
    slug = "bg-#{System.unique_integer([:positive])}"
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})
    {:ok, _} = Tenancy.set_organization_allowed_auth_methods(org.id, ["sso"])
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug <> "-ws", name: slug <> "-ws"})
    {:ok, _} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")
    user
  end

  defp totp!(user) do
    user
    |> Ecto.Changeset.change(%{totp_secret: Accounts.totp_secret(), totp_enabled: true})
    |> Repo.update!()
  end

  defp list!(user),
    do: Application.put_env(:barkpark, :breakglass_emails, [String.upcase(user.email)])

  defp login(user, extra \\ %{}) do
    scoped_conn()
    |> post("/v1/auth/login", Map.merge(%{"email" => user.email, "password" => @password}, extra))
  end

  defp breakglass_events(user),
    do:
      Repo.all(
        from e in Barkpark.Audit.Event,
          where: e.action == "breakglass_login" and e.subject == ^user.id
      )

  test "a listed user signs in with password and TOTP, and the sign-in is audited" do
    user = user!("listed") |> sso_only!() |> totp!()
    list!(user)

    code = Barkpark.TotpTestHelper.totp_code_stable!(user.totp_secret)
    assert %{"token" => _} = json_response(login(user, %{"totp_code" => code}), 201)

    assert [%{metadata: %{"method" => "password"}}] = breakglass_events(user)
  end

  test "a listed user with a password alone is refused" do
    user = user!("nocode") |> sso_only!() |> totp!()
    list!(user)

    assert json_response(login(user), 401)["error"]["code"] == "mfa_required"
    assert breakglass_events(user) == []
  end

  test "a listed user without TOTP gets no exemption for the password door" do
    user = user!("nofactor") |> sso_only!()
    list!(user)

    assert json_response(login(user), 403)["error"]["code"] == "auth_method_not_allowed"
  end

  test "a user who is not listed is refused as before" do
    user = user!("unlisted") |> sso_only!() |> totp!()
    Application.put_env(:barkpark, :breakglass_emails, ["someone-else@breakglass.example"])

    code = Barkpark.TotpTestHelper.totp_code_stable!(user.totp_secret)

    assert json_response(login(user, %{"totp_code" => code}), 403)["error"]["code"] ==
             "auth_method_not_allowed"

    assert breakglass_events(user) == []
  end

  test "a listed user whose org allows passwords writes no break-glass event" do
    user = user!("ordinary") |> totp!()
    list!(user)

    code = Barkpark.TotpTestHelper.totp_code_stable!(user.totp_secret)
    assert %{"token" => _} = json_response(login(user, %{"totp_code" => code}), 201)
    assert breakglass_events(user) == []
  end
end
