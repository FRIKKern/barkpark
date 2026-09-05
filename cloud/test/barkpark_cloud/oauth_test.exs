defmodule BarkparkCloud.OAuthTest do
  @moduledoc """
  Unit tests for the OAuth/SSO context (oauth-sso): the signed-state CSRF guard,
  authorize-URL building, the stubbed token-exchange + userinfo path, and the
  SAFE identity-linking precedence in `Accounts.get_or_create_user_from_oauth/1`.
  Everything runs through `BarkparkCloud.OAuthStub` — ZERO network calls.
  """
  # async: false — this module swaps node-global env (`:barkpark_cloud, OAuth`)
  # to null github's client_secret. That is ONE value for the whole node, so
  # while it is held `OAuth.enabled?(:github)` is false for EVERY concurrent
  # test: forcing the interleave red router_oauth_test.exs's callback assertion
  # AND made github vanish from GET /v1/auth/oauth/providers. Ratchet:
  # scripts/async_env_seam_scan.exs.
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.{Accounts, Billing, OAuth, OAuthStub}
  alias BarkparkCloud.Accounts.{ExternalIdentity, TeamMembership, User}
  alias BarkparkCloud.Notifications.EmailSettings

  # The fixed test state_secret (config/test.exs) — recomputed here only to FORGE
  # an expired/tampered state the public API can't otherwise produce.
  @state_secret "oauth-state-test-fixed"

  defp forge_state(provider, exp, nonce \\ "n") do
    payload = Jason.encode!(%{"p" => provider, "n" => nonce, "exp" => exp})
    mac = :crypto.mac(:hmac, :sha256, @state_secret, payload) |> Base.encode16(case: :lower)
    Base.url_encode64(payload, padding: false) <> "." <> mac
  end

  describe "enabled_providers/0 + enabled?/1" do
    test "both fake-credentialed providers are enabled, sorted" do
      assert OAuth.enabled_providers() == ["github", "google"]
      assert OAuth.enabled?("github")
      assert OAuth.enabled?("google")
      refute OAuth.enabled?("gitlab")
      refute OAuth.enabled?(nil)
    end

    test "a provider with blank creds is excluded" do
      base = Application.get_env(:barkpark_cloud, OAuth)

      patched =
        put_in(base[:providers]["github"][:client_secret], nil)

      Application.put_env(:barkpark_cloud, OAuth, patched)
      on_exit(fn -> Application.put_env(:barkpark_cloud, OAuth, base) end)

      assert OAuth.enabled_providers() == ["google"]
      refute OAuth.enabled?("github")
    end
  end

  describe "authorize_url/1" do
    test "builds the GitHub URL with client_id, derived redirect_uri, scope, and an acceptable state" do
      assert {:ok, url, state} = OAuth.authorize_url("github")
      assert String.starts_with?(url, "https://github.com/login/oauth/authorize?")
      assert url =~ "client_id=gh_test_client_id"
      assert url =~ URI.encode_www_form("http://localhost:4100/v1/auth/oauth/github/callback")
      assert url =~ URI.encode_www_form("read:user user:email")
      assert url =~ "state=#{state}"
      # The state minted in the URL verifies for this provider.
      assert OAuth.verify_state(state, "github") == :ok
    end

    test "Google URL carries response_type=code and the openid scope" do
      assert {:ok, url, _state} = OAuth.authorize_url("google")
      assert String.starts_with?(url, "https://accounts.google.com/o/oauth2/v2/auth?")
      assert url =~ "response_type=code"
      assert url =~ URI.encode_www_form("openid email profile")
    end

    test "a disabled provider returns an error, never a URL" do
      assert OAuth.authorize_url("gitlab") == {:error, :provider_not_enabled}
    end
  end

  describe "verify_state/2" do
    test "round-trips a freshly minted state" do
      state = OAuth.mint_state("github")
      assert OAuth.verify_state(state, "github") == :ok
    end

    test "is SINGLE USE — a second verify of the same state is rejected (replay guard)" do
      state = OAuth.mint_state("github")
      assert OAuth.verify_state(state, "github") == :ok
      # Second redemption of the identical, still-unexpired state must fail: the
      # single-use ledger consumed the nonce on the first verify.
      assert {:error, _} = OAuth.verify_state(state, "github")
    end

    test "rejects a state minted for a DIFFERENT provider (no cross-provider replay)" do
      state = OAuth.mint_state("github")
      assert {:error, _} = OAuth.verify_state(state, "google")
    end

    test "rejects a tampered mac" do
      [enc, mac] = String.split(OAuth.mint_state("github"), ".", parts: 2)
      # Prepend two hex chars: the mac no longer matches (and differs in length),
      # so secure_compare fails deterministically.
      tampered = enc <> ".00" <> mac
      assert {:error, _} = OAuth.verify_state(tampered, "github")
    end

    test "rejects an expired state" do
      expired = forge_state("github", System.system_time(:second) - 5)
      assert {:error, _} = OAuth.verify_state(expired, "github")
    end

    test "rejects a forged mac (wrong secret)" do
      payload = Jason.encode!(%{"p" => "github", "n" => "x", "exp" => far_future()})
      bad = Base.url_encode64(payload, padding: false) <> "." <> "deadbeef"
      assert {:error, _} = OAuth.verify_state(bad, "github")
    end

    test "rejects garbage" do
      assert {:error, _} = OAuth.verify_state("not-a-state", "github")
      assert {:error, _} = OAuth.verify_state(nil, "github")
    end
  end

  describe "fetch_identity/2 (stubbed transport)" do
    test "GitHub returns the numeric id as uid and the verified primary email" do
      assert {:ok, identity} = OAuth.fetch_identity("github", "any-code")
      assert identity.provider == "github"
      assert identity.provider_uid == "4242"
      assert identity.email == "octocat@example.com"
    end

    test "GitHub with NO verified primary yields email: nil (link still stands on uid)" do
      OAuthStub.put_response(:github_emails, [
        %{"email" => "unverified@example.com", "primary" => true, "verified" => false}
      ])

      assert {:ok, identity} = OAuth.fetch_identity("github", "any-code")
      assert identity.provider_uid == "4242"
      assert identity.email == nil
    end

    test "Google returns the OIDC sub as uid and the verified email" do
      OAuthStub.put_response(:google_userinfo, %{
        "sub" => "google-123",
        "email" => "ada@example.com",
        "email_verified" => true
      })

      assert {:ok, identity} = OAuth.fetch_identity("google", "any-code")
      assert identity.provider_uid == "google-123"
      assert identity.email == "ada@example.com"
    end

    test "Google with email_verified=false yields email: nil" do
      OAuthStub.put_response(:google_userinfo, %{
        "sub" => "google-456",
        "email" => "spoof@example.com",
        "email_verified" => false
      })

      assert {:ok, identity} = OAuth.fetch_identity("google", "any-code")
      assert identity.email == nil
    end
  end

  describe "Accounts.get_or_create_user_from_oauth/1 — the SAFE linking" do
    test "first sight births a user + team + owner membership + one identity" do
      identity = %{provider: "github", provider_uid: "u-1", email: "first@example.com"}

      assert {:ok, %User{} = user, :created} = Accounts.get_or_create_user_from_oauth(identity)
      assert user.email == "first@example.com"

      # The team + owner membership were born in the same transaction.
      team = Accounts.primary_team(user)
      assert team != nil
      membership = Repo.get_by(TeamMembership, user_id: user.id, team_id: team.id)
      assert membership.role == "owner"

      # Exactly one identity row, keyed on (provider, provider_uid).
      assert Repo.aggregate(ExternalIdentity, :count) == 1
      assert Accounts.get_user_by_external_identity("github", "u-1").id == user.id

      # An OAuth-birthed team gets the SAME entitlement chain as a password
      # signup: a self-serve trial + a notification-settings row (main's
      # register/3 parity — not a second-class OAuth signup).
      trial = Billing.active_subscription(team)
      assert trial != nil
      assert trial.plan == "trial"
      assert Repo.get_by(EmailSettings, team_id: team.id) != nil
    end

    test "second sight of the SAME (provider, provider_uid) returns the same user, no new rows" do
      identity = %{provider: "github", provider_uid: "u-2", email: "stable@example.com"}

      assert {:ok, user1, :created} = Accounts.get_or_create_user_from_oauth(identity)
      users_before = Repo.aggregate(User, :count)
      ids_before = Repo.aggregate(ExternalIdentity, :count)

      assert {:ok, user2, :existing} = Accounts.get_or_create_user_from_oauth(identity)
      assert user2.id == user1.id
      assert Repo.aggregate(User, :count) == users_before
      assert Repo.aggregate(ExternalIdentity, :count) == ids_before
    end

    test "the ANTI-COOLIFY case: same verified email via a SECOND provider LINKS, never forks" do
      email = "converge@example.com"

      assert {:ok, gh_user, :created} =
               Accounts.get_or_create_user_from_oauth(%{
                 provider: "github",
                 provider_uid: "gh-9",
                 email: email
               })

      # Now the SAME human signs in with Google, same verified email.
      assert {:ok, g_user, :linked} =
               Accounts.get_or_create_user_from_oauth(%{
                 provider: "google",
                 provider_uid: "g-9",
                 email: email
               })

      # Converged onto ONE account — not a second forked user.
      assert g_user.id == gh_user.id
      assert Repo.aggregate(User, :count) == 1
      # Two identities, one user — both providers now reach the same account.
      assert Repo.aggregate(ExternalIdentity, :count) == 2
      assert Accounts.get_user_by_external_identity("google", "g-9").id == gh_user.id
    end

    test "converges onto an existing PASSWORD account (same email) — links, never forks or takes over" do
      # A human first signs up with email + password and owns a team.
      {:ok, pw_user} =
        Accounts.register_user(%{email: "human@example.com", password: "correct horse battery"})

      {:ok, team} = Accounts.create_team(%{name: "Human Co", slug: "human-co"})
      {:ok, _} = Accounts.add_member(team, pw_user, "owner")

      memberships_before = Repo.aggregate(TeamMembership, :count)

      # Later they click "Continue with GitHub" — same VERIFIED email.
      assert {:ok, oauth_user, :linked} =
               Accounts.get_or_create_user_from_oauth(%{
                 provider: "github",
                 provider_uid: "gh-conv",
                 email: "human@example.com"
               })

      # Converged onto the SAME account, not a forked second user.
      assert oauth_user.id == pw_user.id
      assert Repo.aggregate(User, :count) == 1

      # NO takeover: the original password still authenticates (hash untouched).
      assert %User{} =
               Accounts.get_user_by_email_and_password(
                 "human@example.com",
                 "correct horse battery"
               )

      # The convergence NEVER mutated the account's team memberships/roles.
      assert Repo.aggregate(TeamMembership, :count) == memberships_before
      membership = Repo.get_by(TeamMembership, user_id: pw_user.id, team_id: team.id)
      assert membership.role == "owner"

      # Exactly one identity, linked to the existing account.
      assert Accounts.get_user_by_external_identity("github", "gh-conv").id == pw_user.id
      assert Repo.aggregate(ExternalIdentity, :count) == 1
    end

    test "a second link to the SAME (provider, provider_uid) is a unique violation (conflict guard)" do
      {:ok, user_a, :created} =
        Accounts.get_or_create_user_from_oauth(%{
          provider: "github",
          provider_uid: "dup-1",
          email: nil
        })

      {:ok, user_b, :created} =
        Accounts.get_or_create_user_from_oauth(%{
          provider: "github",
          provider_uid: "other",
          email: nil
        })

      # Force a duplicate identity insert for user_b on user_a's key — the
      # composite unique index the :identity_conflict reconciliation relies on
      # must reject it rather than silently creating a second link.
      assert {:error, changeset} =
               Accounts.link_external_identity(user_b, %{
                 provider: "github",
                 provider_uid: "dup-1"
               })

      assert Enum.any?(changeset.errors, fn {_f, {_m, opts}} ->
               Keyword.get(opts, :constraint) == :unique
             end)

      # user_a's link is intact and unchanged.
      assert Accounts.get_user_by_external_identity("github", "dup-1").id == user_a.id
    end

    test "a withheld email (nil) still births a usable account on a synthetic email" do
      assert {:ok, user, :created} =
               Accounts.get_or_create_user_from_oauth(%{
                 provider: "github",
                 provider_uid: "noemail-1",
                 email: nil
               })

      assert user.email =~ "@oauth.users.barkpark.cloud"
      assert Accounts.primary_team(user) != nil
      assert Accounts.get_user_by_external_identity("github", "noemail-1").id == user.id
    end

    test "distinct uids with no shared email yield distinct users" do
      assert {:ok, a, :created} =
               Accounts.get_or_create_user_from_oauth(%{
                 provider: "github",
                 provider_uid: "d-1",
                 email: nil
               })

      assert {:ok, b, :created} =
               Accounts.get_or_create_user_from_oauth(%{
                 provider: "github",
                 provider_uid: "d-2",
                 email: nil
               })

      refute a.id == b.id
      assert Repo.aggregate(User, :count) == 2
    end
  end

  defp far_future, do: System.system_time(:second) + 3600
end
