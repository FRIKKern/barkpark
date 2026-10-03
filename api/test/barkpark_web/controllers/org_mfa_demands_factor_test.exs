defmodule BarkparkWeb.OrgMfaDemandsFactorTest do
  @moduledoc """
  Owner ruling #14 (task-f4cfc3e2ab4bd6b8, item 2): in an organization that
  requires MFA, password and social sign-ins must PRESENT a factor.

  The org check asked whether a factor was enrolled, not presented, so a
  passkey-only member signed in with the password alone, and a social sign-in
  needed no factor at all.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.{Accounts, Repo, Tenancy}
  alias Barkpark.Accounts.{UserSession, WebauthnCredential}
  alias Barkpark.Sso.Social

  @password "correct-horse-battery"

  defmodule MockHTTP do
    @behaviour Barkpark.Sso.Social.HTTP
    @impl true
    def post_form(_url, _params), do: {:ok, %{"access_token" => "at"}}
    @impl true
    def get_bearer(_url, _token), do: {:ok, Application.get_env(:barkpark, :social_test)}
  end

  setup do
    prev = Application.get_env(:barkpark, :social_http)
    Application.put_env(:barkpark, :social_http, MockHTTP)
    {:ok, _} = Social.enable_provider("google", "cid", "secret")

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :social_http, prev),
        else: Application.delete_env(:barkpark, :social_http)

      Application.delete_env(:barkpark, :social_test)
    end)

    :ok
  end

  defp uniq(p), do: "#{p}-#{System.unique_integer([:positive])}"

  defp user!(prefix) do
    {:ok, user} =
      Accounts.register_user(%{email: "#{uniq(prefix)}@example.com", password: @password})

    # Confirmed: a social sign-in on an UNCONFIRMED address reclaims the account
    # (strips its factors), which is a different rule than the one under test.
    Repo.update!(Accounts.User.confirm_changeset(user))
  end

  defp govern!(user) do
    slug = uniq("strict")
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})
    {:ok, _} = Tenancy.set_organization_require_mfa(org.id, true)
    {:ok, ws} = Tenancy.create_workspace(%{slug: "#{slug}-ws", name: "#{slug}-ws"})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")
    user
  end

  defp passkey!(user) do
    Repo.insert!(%WebauthnCredential{
      user_id: user.id,
      credential_id: :crypto.strong_rand_bytes(16),
      cose_key: :erlang.term_to_binary(%{}),
      nickname: "key"
    })

    user
  end

  defp totp!(user) do
    secret = Accounts.totp_secret()

    user
    |> Ecto.Changeset.change(%{totp_secret: secret, totp_enabled: true})
    |> Repo.update!()
  end

  defp sessions(user),
    do: Repo.aggregate(from(s in UserSession, where: s.user_id == ^user.id), :count)

  defp login(conn, user, extra \\ %{}),
    do:
      post(
        conn,
        "/v1/auth/login",
        Map.merge(%{"email" => user.email, "password" => @password}, extra)
      )

  describe "POST /v1/auth/login" do
    test "a passkey-only member of a require-MFA org is refused the password-only sign-in", %{
      conn: conn
    } do
      user = user!("pk-only") |> passkey!() |> govern!()

      body = json_response(login(conn, user), 401)
      assert body["error"]["code"] == "mfa_required"
      assert body["error"]["hint"] =~ "webauthn/login"
      assert sessions(user) == 0
    end

    test "a TOTP member still signs in with password + code", %{conn: conn} do
      user = user!("totp") |> govern!() |> totp!()

      assert json_response(login(conn, user), 401)["error"]["code"] == "mfa_required"

      code = NimbleTOTP.verification_code(user.totp_secret)

      assert %{"token" => _} =
               json_response(login(build_conn(), user, %{"totp_code" => code}), 201)
    end

    test "a passkey-only user OUTSIDE any require-MFA org is unchanged", %{conn: conn} do
      user = user!("pk-free") |> passkey!()
      assert %{"token" => _} = json_response(login(conn, user), 201)
    end

    test "a governed member with no factor still signs in to enrol", %{conn: conn} do
      user = user!("enrol") |> govern!()
      assert %{"mfa_enrolment_required" => true} = json_response(login(conn, user), 201)
    end
  end

  describe "social sign-in" do
    defp social(conn, user) do
      Application.put_env(:barkpark, :social_test, %{
        "email" => user.email,
        "sub" => uniq("g"),
        "id" => uniq("g"),
        "email_verified" => true
      })

      conn
      |> init_test_session(%{social_state: "s1"})
      |> get("/v1/auth/social/google/callback?code=abc&state=s1")
    end

    test "a governed member with a passkey or TOTP is refused (no factor rides a social sign-in)",
         %{conn: conn} do
      for user <- [
            user!("soc-pk") |> passkey!() |> govern!(),
            user!("soc-totp") |> govern!() |> totp!()
          ] do
        body = json_response(social(conn, user), 401)
        assert body["error"]["code"] == "mfa_required"
        assert sessions(user) == 0
      end
    end

    test "an ungoverned member with a passkey still signs in socially", %{conn: conn} do
      user = user!("soc-free") |> passkey!()
      assert %{"token" => _} = json_response(social(conn, user), 201)
    end
  end
end
