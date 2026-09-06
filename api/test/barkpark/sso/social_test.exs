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

    # Two distinct provider surfaces: the userinfo document, and github's
    # GET /user/emails list (a JSON ARRAY) which is the only place its
    # per-address `verified` flag lives.
    @impl true
    def get_bearer("https://api.github.com/user/emails", _token),
      do: {:ok, Application.get_env(:barkpark, :social_test_emails, [])}

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
      Application.delete_env(:barkpark, :social_test_emails)
    end)

    :ok
  end

  defp enable(provider),
    do: {:ok, _} = Social.enable_provider(provider, "client-id", "client-secret")

  # Mock userinfo carries both "sub" (google/microsoft) and "id" (github).
  # `verified` drives google's `email_verified` claim; github's answer instead
  # comes from the /user/emails list below.
  defp userinfo(email, external_id, verified \\ false) do
    Application.put_env(:barkpark, :social_test, %{
      "email" => email,
      "sub" => external_id,
      "id" => external_id,
      "email_verified" => verified
    })
  end

  # github GET /user/emails — the shape the real API returns.
  defp github_emails(entries), do: Application.put_env(:barkpark, :social_test_emails, entries)

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

  test "an existing email account is LINKED, never duplicated (github, VERIFIED primary)" do
    enable("github")

    {:ok, existing} =
      Accounts.register_user(%{email: "bob@example.com", password: "correct horse ok"})

    userinfo("bob@example.com", "gh-9")
    github_emails([%{"email" => "bob@example.com", "verified" => true, "primary" => true}])

    assert {:ok, user} = callback("github")
    assert user.id == existing.id
    assert Repo.aggregate(from(u in User, where: u.email == "bob@example.com"), :count) == 1
  end

  # ── era: unverified provider email may NEVER adopt an existing account ─────
  #
  # The defect: `extract/2` accepted the provider's `email` on is_binary/non-empty
  # ALONE, and `find_or_create_user/1` then resolved it straight to the EXISTING
  # Barkpark user and minted that user's session. Anyone able to put another
  # person's address on a provider account the provider had NOT verified was
  # handed that person's account.

  test "google: an UNVERIFIED email is refused adoption of an existing account" do
    enable("google")

    {:ok, victim} =
      Accounts.register_user(%{email: "victim@example.com", password: "correct horse ok"})

    userinfo("victim@example.com", "attacker-sub", false)

    assert {:error, :email_unverified} = callback("google")

    # Fail closed: no identity was linked onto the victim, so there is no
    # persistent re-entry path either.
    refute Repo.exists?(
             from si in SocialIdentity,
               where: si.user_id == ^victim.id
           )
  end

  test "google: email_verified=true still adopts the existing account" do
    enable("google")

    {:ok, existing} =
      Accounts.register_user(%{email: "trusted@example.com", password: "correct horse ok"})

    userinfo("trusted@example.com", "g-ok", true)

    assert {:ok, user} = callback("google")
    assert user.id == existing.id
  end

  test "microsoft has NO verification claim, so it can never adopt an existing account" do
    enable("microsoft")

    {:ok, _} = Accounts.register_user(%{email: "ms@example.com", password: "correct horse ok"})

    # Even a forged `email_verified` in Microsoft's userinfo is not consulted:
    # the provider has no such claim, so the config carries no verified_key.
    userinfo("ms@example.com", "ms-attacker", true)

    assert {:error, :email_unverified} = callback("microsoft")
  end

  test "github: the profile email alone (no verified /user/emails entry) is refused" do
    enable("github")

    {:ok, _} = Accounts.register_user(%{email: "gh@example.com", password: "correct horse ok"})

    userinfo("gh@example.com", "gh-attacker")
    # The address is on the account but UNVERIFIED, and a different address is
    # the verified primary — neither unlocks adoption.
    github_emails([
      %{"email" => "gh@example.com", "verified" => false, "primary" => true},
      %{"email" => "other@example.com", "verified" => true, "primary" => true}
    ])

    assert {:error, :email_unverified} = callback("github")
  end

  test "github: a verified but NON-primary address is refused" do
    enable("github")

    {:ok, _} = Accounts.register_user(%{email: "np@example.com", password: "correct horse ok"})

    userinfo("np@example.com", "gh-np")
    github_emails([%{"email" => "np@example.com", "verified" => true, "primary" => false}])

    assert {:error, :email_unverified} = callback("github")
  end

  test "an unverified email may still create a BRAND NEW account" do
    enable("microsoft")

    userinfo("fresh@example.com", "ms-1")

    assert {:ok, user} = callback("microsoft")
    assert user.email == "fresh@example.com"
  end

  test "an already-linked (provider, external_id) re-logs WITHOUT a verification signal" do
    enable("google")

    # First login creates the account (unverified creation is allowed) and links.
    userinfo("selfmade@example.com", "g-self")
    assert {:ok, u1} = callback("google")

    # Second login carries no verification claim at all; the LINK is the
    # credential, so it must still succeed.
    Application.put_env(:barkpark, :social_test, %{
      "email" => "selfmade@example.com",
      "sub" => "g-self",
      "id" => "g-self"
    })

    assert {:ok, u2} = callback("google")
    assert u1.id == u2.id
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
