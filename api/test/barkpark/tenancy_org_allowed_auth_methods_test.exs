defmodule Barkpark.TenancyOrgAllowedAuthMethodsTest do
  @moduledoc """
  era-bl-allowed-auth-methods — the org column, the guarded setter, and the
  governing-org resolver.

  The rule mirrors `require_mfa`'s: a user is governed by every org reachable
  through their `principal_type: "user"` workspace memberships, and the
  strictest applicable policy wins. Here "strictest" is the INTERSECTION of
  the non-NULL allow-lists — a laxer org cannot re-open a door a stricter one
  closed. NULL everywhere is the zero-tax default: every method allowed.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Organization

  defp org!(slug, methods \\ :unset) do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})

    case methods do
      :unset ->
        org

      m ->
        {:ok, org} = Tenancy.set_organization_allowed_auth_methods(org.id, m)
        org
    end
  end

  defp workspace_in!(org_or_nil, slug) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: slug})

    case org_or_nil do
      nil ->
        ws

      org ->
        {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
        ws
    end
  end

  defp member!(ws, user_id, principal_type \\ "user") do
    {:ok, _} = TenancyAuth.create_membership(ws.id, user_id, "member", principal_type)
    :ok
  end

  defp user_id, do: Ecto.UUID.generate()

  # ── the column + setter ────────────────────────────────────────────────────

  test "allowed_auth_methods defaults to nil (no policy) and is settable + clearable" do
    org = org!(unique("acme"))
    assert org.allowed_auth_methods == nil

    {:ok, org} = Tenancy.set_organization_allowed_auth_methods(org.id, ["sso"])
    assert org.allowed_auth_methods == ["sso"]

    {:ok, org} = Tenancy.set_organization_allowed_auth_methods(org.id, nil)
    assert org.allowed_auth_methods == nil
  end

  test "the stored policy is deduped + sorted, so one policy has one byte shape" do
    org = org!(unique("canon"))

    {:ok, a} = Tenancy.set_organization_allowed_auth_methods(org.id, ["sso", "password", "sso"])
    assert a.allowed_auth_methods == ["password", "sso"]

    {:ok, b} = Tenancy.set_organization_allowed_auth_methods(org.id, ["password", "sso"])
    assert b.allowed_auth_methods == a.allowed_auth_methods
  end

  test "atoms are accepted and normalised to the stored string vocabulary" do
    org = org!(unique("atoms"))
    {:ok, org} = Tenancy.set_organization_allowed_auth_methods(org.id, [:sso, :passkey])
    assert org.allowed_auth_methods == ["passkey", "sso"]
  end

  test "an unknown method, an empty list, and a non-list are :invalid_policy — DB untouched" do
    org = org!(unique("bad"))

    assert {:error, :invalid_policy} =
             Tenancy.set_organization_allowed_auth_methods(org.id, ["passwrod"])

    assert {:error, :invalid_policy} = Tenancy.set_organization_allowed_auth_methods(org.id, [])

    assert {:error, :invalid_policy} =
             Tenancy.set_organization_allowed_auth_methods(org.id, "sso")

    assert Repo.get(Organization, org.id).allowed_auth_methods == nil
  end

  test "an unknown or malformed organization id is a clean :not_found" do
    assert {:error, :not_found} =
             Tenancy.set_organization_allowed_auth_methods(Ecto.UUID.generate(), ["sso"])

    assert {:error, :not_found} =
             Tenancy.set_organization_allowed_auth_methods("not-a-uuid", ["sso"])
  end

  test "the changeset itself rejects an out-of-vocabulary method" do
    changeset =
      Organization.changeset(%Organization{}, %{
        slug: unique("cs"),
        name: "cs",
        allowed_auth_methods: ["password", "carrier-pigeon"]
      })

    refute changeset.valid?
    assert %{allowed_auth_methods: [msg]} = errors_on(changeset)
    assert msg =~ "carrier-pigeon"
  end

  # ── the governing-org resolver ─────────────────────────────────────────────

  test "no membership and no policy anywhere → nil = every method allowed (zero tax)" do
    uid = user_id()
    assert Tenancy.org_allowed_auth_methods_for_user(uid) == nil
    assert Tenancy.auth_method_allowed_for_user?(uid, "password")
    assert Tenancy.auth_method_allowed_for_user?(uid, "magic_link")
    assert Tenancy.auth_method_allowed_for_user?(uid, "passkey")

    ws = workspace_in!(org!(unique("plain")), unique("plain-ws"))
    member!(ws, uid)

    assert Tenancy.org_allowed_auth_methods_for_user(uid) == nil
    assert Tenancy.auth_method_allowed_for_user?(uid, "password")
  end

  test "a governing SSO-only org closes password and magic-link, keeps sso" do
    uid = user_id()
    ws = workspace_in!(org!(unique("ssoonly"), ["sso"]), unique("ssoonly-ws"))
    member!(ws, uid)

    assert Tenancy.org_allowed_auth_methods_for_user(uid) == ["sso"]
    refute Tenancy.auth_method_allowed_for_user?(uid, "password")
    refute Tenancy.auth_method_allowed_for_user?(uid, "magic_link")
    refute Tenancy.auth_method_allowed_for_user?(uid, "passkey")
    assert Tenancy.auth_method_allowed_for_user?(uid, "sso")
  end

  test "strictest wins: a laxer org does NOT re-open a door a stricter one closed" do
    uid = user_id()
    strict = workspace_in!(org!(unique("strict"), ["sso"]), unique("strict-ws"))
    lax = workspace_in!(org!(unique("lax"), ["sso", "password", "magic_link"]), unique("lax-ws"))
    member!(strict, uid)
    member!(lax, uid)

    assert Tenancy.org_allowed_auth_methods_for_user(uid) == ["sso"]
    refute Tenancy.auth_method_allowed_for_user?(uid, "password")
  end

  test "an org with NO policy expresses no opinion and never widens a governing one" do
    uid = user_id()
    strict = workspace_in!(org!(unique("s2"), ["sso"]), unique("s2-ws"))
    silent = workspace_in!(org!(unique("silent")), unique("silent-ws"))
    member!(strict, uid)
    member!(silent, uid)

    assert Tenancy.org_allowed_auth_methods_for_user(uid) == ["sso"]
  end

  test "disjoint governing policies intersect to no door at all — honest, not a bug" do
    uid = user_id()
    a = workspace_in!(org!(unique("disj-a"), ["sso"]), unique("disj-a-ws"))
    b = workspace_in!(org!(unique("disj-b"), ["password"]), unique("disj-b-ws"))
    member!(a, uid)
    member!(b, uid)

    assert Tenancy.org_allowed_auth_methods_for_user(uid) == []
    refute Tenancy.auth_method_allowed_for_user?(uid, "sso")
    refute Tenancy.auth_method_allowed_for_user?(uid, "password")
  end

  test "a workspace with no organization never governs" do
    uid = user_id()
    orphan = workspace_in!(nil, unique("orphan-ws"))
    member!(orphan, uid)

    assert Tenancy.org_allowed_auth_methods_for_user(uid) == nil
  end

  test "a NON-user principal membership does not drag the policy onto that id" do
    uid = user_id()
    ws = workspace_in!(org!(unique("svc"), ["sso"]), unique("svc-ws"))
    member!(ws, uid, "api_token")

    assert Tenancy.org_allowed_auth_methods_for_user(uid) == nil
    assert Tenancy.auth_method_allowed_for_user?(uid, "password")
  end

  test "setting the policy lands an auth audit event naming the new value" do
    org = org!(unique("audited"))
    {:ok, _} = Tenancy.set_organization_allowed_auth_methods(org.id, ["sso"], actor_id: "tester")

    events =
      Repo.all(
        from e in Barkpark.Audit.Event,
          where: e.subject == ^org.id and e.action == "allowed_auth_methods_changed"
      )

    assert [event] = events
    assert event.metadata["allowed_auth_methods"] == ["sso"]
    assert event.metadata["organization_id"] == org.id
  end

  # Slugs are globally unique and this database is shared across agents — never
  # reuse a fixed slug.
  defp unique(prefix), do: prefix <> "-" <> String.replace(Ecto.UUID.generate(), "-", "")
end
