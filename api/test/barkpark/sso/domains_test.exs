defmodule Barkpark.Sso.DomainsTest do
  @moduledoc "Domain verification + SSO routing + JIT provisioning (era-w3-jit-domain)."
  use Barkpark.DataCase, async: false

  alias Barkpark.{Accounts, Repo, Sso, Tenancy}
  alias Barkpark.Sso.Domains
  alias Barkpark.Tenancy.Membership
  import Ecto.Query

  defmodule MockResolver do
    @behaviour Barkpark.Sso.Domains.Resolver
    @impl true
    def txt_records(_domain), do: Application.get_env(:barkpark, :dns_test, [])
  end

  setup do
    prev = Application.get_env(:barkpark, :dns_resolver)
    Application.put_env(:barkpark, :dns_resolver, MockResolver)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :dns_resolver, prev),
        else: Application.delete_env(:barkpark, :dns_resolver)

      Application.delete_env(:barkpark, :dns_test)
    end)

    :ok
  end

  defp org(slug) do
    {:ok, o} = Tenancy.create_organization(%{slug: slug, name: slug})
    o
  end

  describe "domain verification (DNS TXT)" do
    test "verify only succeeds when the TXT token is present" do
      o = org("acme")
      {:ok, rec} = Domains.request_verification(o, "acme.com")
      assert rec.dns_token =~ "barkpark-verify="
      assert is_nil(rec.verified_at)

      # TXT not published yet → fails, stays unverified
      Application.put_env(:barkpark, :dns_test, ["some-other-record"])
      assert {:error, :txt_record_absent} = Domains.verify("acme.com")

      # publish the token → verifies
      Application.put_env(:barkpark, :dns_test, [rec.dns_token])
      assert {:ok, verified} = Domains.verify("acme.com")
      refute is_nil(verified.verified_at)
    end

    test "verify on an unclaimed domain is not_found" do
      assert {:error, :not_found} = Domains.verify("nobody.com")
    end
  end

  describe "route_for_email — only VERIFIED domains route" do
    test "an unverified domain does not route; a verified one routes to its org" do
      o = org("routeco")
      {:ok, rec} = Domains.request_verification(o, "routeco.com")

      # unverified → no routing (security: ownership not yet proven)
      assert Domains.route_for_email("someone@routeco.com") == nil

      Application.put_env(:barkpark, :dns_test, [rec.dns_token])
      {:ok, _} = Domains.verify("routeco.com")

      routed = Domains.route_for_email("someone@routeco.com")
      assert routed.slug == "routeco"
      # a different domain still doesn't route
      assert Domains.route_for_email("x@other.com") == nil
    end
  end

  describe "jit_provision — first SSO login gains a membership" do
    test "provisions a membership in each of the org's workspaces (idempotent)" do
      o = org("jitco")
      {:ok, ws} = Tenancy.create_workspace(%{slug: "jitco-ws", name: "WS"})
      {:ok, _} = Tenancy.assign_workspace_to_organization(ws, o.id)

      {:ok, user} =
        Accounts.register_user(%{email: "jit@jitco.com", password: "correct horse ok"})

      assert Sso.jit_provision(o.id, user) == 1

      assert Repo.exists?(
               from m in Membership,
                 where:
                   m.principal_type == "user" and m.principal_id == ^user.id and
                     m.workspace_id == ^ws.id and m.role == "member"
             )

      # idempotent — second call doesn't duplicate
      assert Sso.jit_provision(o.id, user) == 1

      assert Repo.aggregate(
               from(m in Membership,
                 where: m.principal_id == ^user.id and m.workspace_id == ^ws.id
               ),
               :count
             ) == 1
    end
  end
end
