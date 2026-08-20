defmodule Barkpark.OrgSessionPolicyTest do
  @moduledoc """
  era-w8-org-session-policy — the org-wide idle-timeout + absolute-lifetime knob,
  its strictest-wins resolver, the fail-closed wiring into the session verify
  path, and the audit trail.

  The governing model mirrors `org_requires_mfa_for_user?/1`: any org reachable
  through a user's `principal_type: "user"` memberships can tighten the bound,
  and strictest (smallest positive) wins per axis. Both bounds NULL = the
  byte-identical zero-tax default (30-day / no-idle).
  """
  use Barkpark.DataCase, async: true

  import Ecto.Query, warn: false

  alias Barkpark.{Accounts, Audit, Repo, Tenancy}
  alias Barkpark.Accounts.{User, UserSession}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct-horse-battery"

  defp user!(email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  defp org!(slug, policy \\ nil) do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})

    if policy do
      {:ok, org} = Tenancy.set_organization_session_policy(org.id, policy)
      org
    else
      org
    end
  end

  # Put `user` under `org` via an owning workspace membership (principal_type
  # "user"), so the org governs them.
  defp govern!(user, org, ws_slug) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: ws_slug, name: ws_slug})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")
    :ok
  end

  # Mint a real session for `user`, then backdate its activity/birth timestamps so
  # a policy can bite deterministically. Returns the plaintext bearer.
  defp session_for!(user, opts) do
    {:ok, plaintext} = Accounts.create_user_session_token(user)
    hash = UserSession.hash_token(plaintext)

    sets =
      []
      |> maybe_put(:last_used_at, opts[:last_used_at])
      |> maybe_put(:inserted_at, opts[:inserted_at])

    if sets != [] do
      {1, _} =
        from(t in UserSession, where: t.token_hash == ^hash) |> Repo.update_all(set: sets)
    end

    plaintext
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: [{key, value} | kw]

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  describe "set_organization_session_policy/2 + org_session_policy_for_user/1" do
    test "defaults are NULL and the resolver reports no bound" do
      org = org!("acme")
      assert org.session_idle_timeout_seconds == nil
      assert org.session_absolute_lifetime_seconds == nil

      assert Tenancy.org_session_policy_for_user(Ecto.UUID.generate()) ==
               %{idle_timeout_seconds: nil, absolute_lifetime_seconds: nil}
    end

    test "sets, clears, and validates each axis" do
      org = org!("beta")

      {:ok, org} =
        Tenancy.set_organization_session_policy(org.id, %{
          idle_timeout_seconds: 900,
          absolute_lifetime_seconds: 86_400
        })

      assert org.session_idle_timeout_seconds == 900
      assert org.session_absolute_lifetime_seconds == 86_400

      # string keys work too; nil clears one axis, leaves the other
      {:ok, org} =
        Tenancy.set_organization_session_policy(org.id, %{"idle_timeout_seconds" => nil})

      assert org.session_idle_timeout_seconds == nil
      assert org.session_absolute_lifetime_seconds == 86_400

      # non-positive / non-integer is rejected without touching the row
      assert {:error, :invalid_policy} =
               Tenancy.set_organization_session_policy(org.id, %{idle_timeout_seconds: 0})

      assert {:error, :invalid_policy} =
               Tenancy.set_organization_session_policy(org.id, %{idle_timeout_seconds: -5})

      assert Repo.get!(Barkpark.Tenancy.Organization, org.id).session_absolute_lifetime_seconds ==
               86_400
    end

    test "unknown or malformed id is a clean :not_found (no CastError)" do
      assert {:error, :not_found} =
               Tenancy.set_organization_session_policy(Ecto.UUID.generate(), %{
                 idle_timeout_seconds: 60
               })

      assert {:error, :not_found} =
               Tenancy.set_organization_session_policy("not-a-uuid", %{idle_timeout_seconds: 60})
    end

    test "strictest-wins per axis across a user's governing orgs" do
      user = user!("multi@example.com")
      strict = org!("strict", %{idle_timeout_seconds: 300, absolute_lifetime_seconds: 100_000})
      lax = org!("lax", %{idle_timeout_seconds: 3600, absolute_lifetime_seconds: 10_000})
      govern!(user, strict, "strict-ws")
      govern!(user, lax, "lax-ws")

      assert Tenancy.org_session_policy_for_user(user.id) ==
               %{idle_timeout_seconds: 300, absolute_lifetime_seconds: 10_000}
    end

    test "an org that sets no bound never governs a bound" do
      user = user!("orphan@example.com")
      # only membership is in a workspace with NO organization
      {:ok, ws} = Tenancy.create_workspace(%{slug: "no-org-ws", name: "no-org-ws"})
      {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")

      assert Tenancy.org_session_policy_for_user(user.id) ==
               %{idle_timeout_seconds: nil, absolute_lifetime_seconds: nil}
    end

    test "an api_token membership does not govern a user (principal_type filter)" do
      user = user!("token-member@example.com")
      org = org!("strict2", %{idle_timeout_seconds: 60})
      {:ok, ws} = Tenancy.create_workspace(%{slug: "s2-ws", name: "s2-ws"})
      {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
      {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "api_token")

      assert Tenancy.org_session_policy_for_user(user.id).idle_timeout_seconds == nil
    end
  end

  describe "verify_user_session_token/1 — fail-closed enforcement (DENY paths)" do
    test "a governed session idle past the org idle timeout is logged out" do
      user = user!("idle@example.com")
      org = org!("idle-org", %{idle_timeout_seconds: 60})
      govern!(user, org, "idle-ws")

      # last activity 10 minutes ago; born recently (absolute lifetime unset)
      plaintext = session_for!(user, last_used_at: ago(600))

      assert Accounts.verify_user_session_token(plaintext) == nil
    end

    test "a governed session past the absolute lifetime is logged out even if just active" do
      user = user!("stale@example.com")
      org = org!("stale-org", %{absolute_lifetime_seconds: 3600})
      govern!(user, org, "stale-ws")

      # born 2 hours ago but active right now — absolute lifetime still evicts it
      plaintext = session_for!(user, inserted_at: ago(7200), last_used_at: ago(1))

      assert Accounts.verify_user_session_token(plaintext) == nil
    end
  end

  describe "verify_user_session_token/1 — zero-tax + within-policy (ALLOW paths)" do
    test "NULL org policy leaves an old-but-unexpired session valid (byte-identical default)" do
      user = user!("nulltax@example.com")
      org = org!("null-org")
      govern!(user, org, "null-ws")

      # idle 10 minutes AND born 2 hours ago: with NO org bound the 30-day
      # per-session expires_at still governs, so it remains valid.
      plaintext = session_for!(user, last_used_at: ago(600), inserted_at: ago(7200))

      assert %User{id: uid} = Accounts.verify_user_session_token(plaintext)
      assert uid == user.id
    end

    test "a governed session within both bounds stays valid" do
      user = user!("fresh@example.com")
      org = org!("fresh-org", %{idle_timeout_seconds: 3600, absolute_lifetime_seconds: 86_400})
      govern!(user, org, "fresh-ws")

      plaintext = session_for!(user, last_used_at: ago(5), inserted_at: ago(60))

      assert %User{id: uid} = Accounts.verify_user_session_token(plaintext)
      assert uid == user.id
    end

    test "an ungoverned user is unaffected (no org membership at all)" do
      user = user!("solo@example.com")
      plaintext = session_for!(user, last_used_at: ago(999_999), inserted_at: ago(999_999))

      assert %User{} = Accounts.verify_user_session_token(plaintext)
    end
  end

  describe "audit trail (auth category)" do
    defp last_auth_event do
      Repo.one(
        from e in Barkpark.Audit.Event,
          where: e.category == "auth",
          order_by: [desc: e.id],
          limit: 1
      )
    end

    test "setting the session policy emits an auth/session_policy_changed event" do
      org = org!("audited")
      {:ok, _} = Tenancy.set_organization_session_policy(org.id, %{idle_timeout_seconds: 120})

      event = last_auth_event()
      assert event.category == "auth"
      assert event.action == "session_policy_changed"
      assert event.subject == org.id
      assert event.metadata["organization_id"] == org.id
      assert event.metadata["session_idle_timeout_seconds"] == 120
    end

    test "setting require_mfa emits an auth/require_mfa_changed event (previously silent)" do
      org = org!("audited-mfa")
      {:ok, _} = Tenancy.set_organization_require_mfa(org.id, true)

      event = last_auth_event()
      assert event.action == "require_mfa_changed"
      assert event.subject == org.id
      assert event.metadata["require_mfa"] == true
    end

    test "the whole audit chain stays intact after policy writes" do
      org = org!("chain")
      {:ok, _} = Tenancy.set_organization_session_policy(org.id, %{idle_timeout_seconds: 30})
      assert :ok == Audit.verify_chain(nil)
    end
  end
end
