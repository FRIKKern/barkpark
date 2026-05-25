defmodule Barkpark.TenancyTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.{Workspace, Project, Membership}
  alias Barkpark.Content.Document

  describe "default tenancy backfill" do
    test "get_default_workspace/0 returns the seeded Default Workspace" do
      ws = Tenancy.get_default_workspace()
      assert %Workspace{} = ws
      assert ws.slug == "default"
      assert ws.name == "Default Workspace"
    end

    test "get_default_project/0 returns the seeded Default Project under it" do
      ws = Tenancy.get_default_workspace()
      project = Tenancy.get_default_project()
      assert %Project{} = project
      assert project.slug == "default"
      assert project.name == "Default Project"
      assert project.workspace_id == ws.id
    end

    test "a document can be assigned the default workspace + project (backfill shape)" do
      ws = Tenancy.get_default_workspace()
      project = Tenancy.get_default_project()

      {:ok, doc} =
        %Document{workspace_id: ws.id, project_id: project.id}
        |> Document.changeset(%{doc_id: "tenancy-test-1", type: "thing", rev: "r1"})
        |> Repo.insert()

      reloaded = Repo.get!(Document, doc.id)
      assert reloaded.workspace_id == ws.id
      assert reloaded.project_id == project.id
    end
  end

  describe "Workspace changeset" do
    test "rejects a reserved slug" do
      cs = Workspace.changeset(%Workspace{}, %{slug: "admin", name: "X"})
      refute cs.valid?
      assert "is reserved" in errors_on(cs).slug
    end

    test "rejects a bad-format slug" do
      cs = Workspace.changeset(%Workspace{}, %{slug: "Bad Slug!", name: "X"})
      refute cs.valid?
      assert errors_on(cs).slug != []
    end

    test "accepts a well-formed slug" do
      cs = Workspace.changeset(%Workspace{}, %{slug: "my-team", name: "My Team"})
      assert cs.valid?
    end
  end

  describe "create_workspace/1 + create_project/2" do
    test "creates a workspace and a project under it" do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "acme", name: "Acme"})
      {:ok, project} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})

      assert project.workspace_id == ws.id
      assert Tenancy.get_project("acme", "site").id == project.id
      assert Enum.map(Tenancy.list_projects(ws), & &1.slug) == ["site"]
    end

    test "project slug must be unique within a workspace" do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "acme2", name: "Acme2"})
      {:ok, _} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})

      assert {:error, cs} = Tenancy.create_project(ws, %{slug: "site", name: "Dupe"})
      refute cs.valid?
      assert errors_on(cs).slug != []
    end

    test "same project slug is allowed in a different workspace" do
      {:ok, ws_a} = Tenancy.create_workspace(%{slug: "team-a", name: "A"})
      {:ok, ws_b} = Tenancy.create_workspace(%{slug: "team-b", name: "B"})

      {:ok, _} = Tenancy.create_project(ws_a, %{slug: "shared", name: "Shared"})
      assert {:ok, p_b} = Tenancy.create_project(ws_b, %{slug: "shared", name: "Shared"})
      assert p_b.workspace_id == ws_b.id
    end
  end

  describe "Membership changeset (table only)" do
    test "requires a valid role and binds to a workspace" do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "mem-ws", name: "Mem"})
      principal_id = Ecto.UUID.generate()

      {:ok, m} =
        %Membership{}
        |> Membership.changeset(%{
          workspace_id: ws.id,
          principal_id: principal_id,
          role: "owner"
        })
        |> Repo.insert()

      assert m.principal_type == "api_token"
      assert m.role == "owner"

      bad = Membership.changeset(%Membership{}, %{workspace_id: ws.id, principal_id: principal_id, role: "wizard"})
      refute bad.valid?
    end
  end
end
