defmodule Barkpark.Tenancy.OrganizationTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Organization

  describe "organizations" do
    test "the migration back-fills a default organization" do
      assert %Organization{slug: "default"} = Tenancy.get_default_organization()
    end

    test "create_organization/1 inserts a valid org" do
      assert {:ok, org} = Tenancy.create_organization(%{slug: "acme", name: "Acme Inc"})
      assert org.slug == "acme"
      assert Tenancy.get_organization_by_slug("acme").id == org.id
    end

    test "rejects an invalid slug" do
      assert {:error, cs} = Tenancy.create_organization(%{slug: "Acme Inc", name: "Acme"})
      refute cs.valid?
    end

    test "slug is unique" do
      {:ok, _} = Tenancy.create_organization(%{slug: "dup", name: "One"})
      assert {:error, cs} = Tenancy.create_organization(%{slug: "dup", name: "Two"})
      refute cs.valid?
    end
  end

  describe "one organization spans multiple workspaces" do
    test "workspaces_for_organization returns every attached workspace" do
      {:ok, org} = Tenancy.create_organization(%{slug: "multi", name: "Multi Corp"})
      {:ok, ws1} = Tenancy.create_workspace(%{slug: "multi-a", name: "A"})
      {:ok, ws2} = Tenancy.create_workspace(%{slug: "multi-b", name: "B"})

      {:ok, _} = Tenancy.assign_workspace_to_organization(ws1, org.id)
      {:ok, _} = Tenancy.assign_workspace_to_organization(ws2, org.id)

      ids = org.id |> Tenancy.workspaces_for_organization() |> Enum.map(& &1.slug) |> Enum.sort()
      assert ids == ["multi-a", "multi-b"]
    end

    test "detaching a workspace sets its organization_id to nil" do
      {:ok, org} = Tenancy.create_organization(%{slug: "detach", name: "Detach"})
      {:ok, ws} = Tenancy.create_workspace(%{slug: "detach-ws", name: "WS"})
      {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
      assert ws.organization_id == org.id

      {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, nil)
      assert is_nil(ws.organization_id)
    end
  end

  describe "additive / behaviour-preserving" do
    test "a workspace created without an org is valid (organization_id nullable)" do
      assert {:ok, ws} = Tenancy.create_workspace(%{slug: "no-org", name: "No Org"})
      assert is_nil(ws.organization_id)
    end
  end
end
