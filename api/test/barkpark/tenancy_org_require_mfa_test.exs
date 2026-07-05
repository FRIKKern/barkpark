defmodule Barkpark.TenancyOrgRequireMfaTest do
  @moduledoc """
  era-w2-org-require-mfa — the org flag + the governing-org rule.

  The rule (owner-ratified): ANY-org-requires → enforce, strictest-wins. A
  user is governed by every org reachable through their `principal_type:
  "user"` workspace memberships; one requiring org is enough, and belonging
  to a laxer org grants no bypass.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  defp org!(slug, opts \\ []) do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})

    if opts[:require_mfa] do
      {:ok, org} = Tenancy.set_organization_require_mfa(org.id, true)
      org
    else
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

  test "require_mfa defaults to false and is settable both ways" do
    org = org!("acme")
    assert org.require_mfa == false

    {:ok, org} = Tenancy.set_organization_require_mfa(org.id, true)
    assert org.require_mfa == true

    {:ok, org} = Tenancy.set_organization_require_mfa(org.id, false)
    assert org.require_mfa == false
  end

  test "set_organization_require_mfa on an unknown or malformed id is a clean :not_found" do
    assert {:error, :not_found} =
             Tenancy.set_organization_require_mfa(Ecto.UUID.generate(), true)

    # a non-UUID id must not raise Ecto.CastError
    assert {:error, :not_found} = Tenancy.set_organization_require_mfa("not-a-uuid", true)
  end

  describe "org_requires_mfa_for_user?/1 — the ANY-org governing rule" do
    test "a member of a requiring org's workspace is governed" do
      uid = user_id()
      org = org!("strict", require_mfa: true)
      ws = workspace_in!(org, "strict-ws")
      member!(ws, uid)

      assert Tenancy.org_requires_mfa_for_user?(uid)
    end

    test "ANY requiring org governs — a laxer org grants no bypass" do
      uid = user_id()
      strict = org!("strict2", require_mfa: true)
      lax = org!("lax")
      member!(workspace_in!(strict, "s-ws"), uid)
      member!(workspace_in!(lax, "l-ws"), uid)

      assert Tenancy.org_requires_mfa_for_user?(uid)
    end

    test "membership only in non-requiring orgs does not govern" do
      uid = user_id()
      lax = org!("lax2")
      member!(workspace_in!(lax, "l2-ws"), uid)

      refute Tenancy.org_requires_mfa_for_user?(uid)
    end

    test "a workspace without an organization never governs" do
      uid = user_id()
      member!(workspace_in!(nil, "orphan-ws"), uid)

      refute Tenancy.org_requires_mfa_for_user?(uid)
    end

    test "an api_token membership does not make a user governed (principal_type filter)" do
      uid = user_id()
      org = org!("strict3", require_mfa: true)
      member!(workspace_in!(org, "s3-ws"), uid, "api_token")

      refute Tenancy.org_requires_mfa_for_user?(uid)
    end

    test "a user with no memberships is not governed" do
      refute Tenancy.org_requires_mfa_for_user?(user_id())
    end
  end
end
