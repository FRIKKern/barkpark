defmodule Barkpark.Sso.SocialTest do
  @moduledoc "Social login against a mock provider (era-w2-social-oauth)."
  use Barkpark.DataCase, async: false

  alias Barkpark.{Accounts, Repo}
  alias Barkpark.Accounts.User
  alias Barkpark.Sso.Social
  alias Barkpark.Sso.SocialIdentity
  import Ecto.Query

  defmodule MockHTTP do
    @behaviour Barkpark.Sso.Social.HTTP
    @impl true
    def post_form(_url, _params), do: {:ok, %{"access_token" => "access-token-123"}}
    @impl true
    def get_bearer(_url, _token), do: {:ok, Application.get_env(:barkpark, :social_test)}
  end

  setup do
    prev = Application.get_env(:barkpark, :social_http)
    Application.put_env(:barkpark, :social_http, MockHTTP)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :social_http, prev),
        else: Application.delete_env(:barkpark, :social_http)

      Application.delete_env(:barkpark, :social_test)
    end)

    :ok
  end

  defp enable(provider),
    do: {:ok, _} = Social.enable_provider(provider, "client-id", "client-secret")

  # Mock userinfo carries both "sub" (google/microsoft) and "id" (github).
  defp userinfo(email, external_id),
    do:
      Application.put_env(:barkpark, :social_test, %{
        "email" => email,
        "sub" => external_id,
        "id" => external_id
      })

  defp callback(provider),
    do: Social.handle_callback(Social.provider(provider), "code", "https://bp/cb")

  test "each provider (google, github, microsoft) mints a user" do
    for {provider, id} <- [{"google", "g1"}, {"github", "h1"}, {"microsoft", "m1"}] do
      enable(provider)
      userinfo("u-#{provider}@example.com", id)
      assert {:ok, %User{} = user} = callback(provider)
      assert user.email == "u-#{provider}@example.com"
    end
  end

  test "a new social login find-or-creates the user and links the identity" do
    enable("google")
    userinfo("alice@example.com", "g-42")

    assert {:ok, user} = callback("google")
    assert user.email == "alice@example.com"
    refute is_nil(Accounts.get_user(user.id).confirmed_at)

    assert Repo.exists?(
             from si in SocialIdentity,
               where:
                 si.provider == "google" and si.external_id == "g-42" and si.user_id == ^user.id
           )
  end

  test "an existing email account is LINKED, never duplicated" do
    enable("github")

    {:ok, existing} =
      Accounts.register_user(%{email: "bob@example.com", password: "correct horse ok"})

    userinfo("bob@example.com", "gh-9")

    assert {:ok, user} = callback("github")
    assert user.id == existing.id
    assert Repo.aggregate(from(u in User, where: u.email == "bob@example.com"), :count) == 1
  end

  test "re-login with the same (provider, external_id) returns the same user (no dup identity)" do
    enable("google")
    userinfo("carol@example.com", "g-7")

    assert {:ok, u1} = callback("google")
    assert {:ok, u2} = callback("google")
    assert u1.id == u2.id
    assert Repo.aggregate(from(si in SocialIdentity, where: si.external_id == "g-7"), :count) == 1
  end

  test "an unconfigured provider resolves to nil" do
    assert Social.provider("google") == nil
  end
end
