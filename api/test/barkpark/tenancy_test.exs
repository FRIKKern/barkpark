defmodule Barkpark.TenancyTest do
  use Barkpark.DataCase, async: true

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

  describe "by-id lookups guard the :binary_id cast" do
    # These are public context functions with @spec binary() | nil. A raw,
    # non-UUID id (the moment a controller wires an :id path param in — the
    # #672 mistake) would raise Ecto.CastError → 500 on the bare Repo.get.
    # Ecto.UUID.cast keeps the contract nil-on-absent/malformed.
    test "get_workspace_by_id/1 returns nil for a non-UUID id" do
      assert Tenancy.get_workspace_by_id("not-a-uuid") == nil
    end

    test "get_project_by_id/1 returns nil for a non-UUID id" do
      assert Tenancy.get_project_by_id("not-a-uuid") == nil
    end

    test "get_dataset_by_id/1 returns nil for a non-UUID id" do
      assert Tenancy.get_dataset_by_id("not-a-uuid") == nil
    end

    test "the by-id lookups still return nil for a nil id" do
      assert Tenancy.get_workspace_by_id(nil) == nil
      assert Tenancy.get_project_by_id(nil) == nil
      assert Tenancy.get_dataset_by_id(nil) == nil
    end

    test "a well-formed but absent UUID returns nil, not a raise" do
      absent = Ecto.UUID.generate()
      assert Tenancy.get_workspace_by_id(absent) == nil
      assert Tenancy.get_project_by_id(absent) == nil
      assert Tenancy.get_dataset_by_id(absent) == nil
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

  describe "list_projects/1 ordering" do
    test "puts the default-slug project FIRST, then the rest alphabetically" do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "ord-ws", name: "Ord"})
      # Insert out of order to prove the query — not insertion — drives ordering.
      {:ok, _} = Tenancy.create_project(ws, %{slug: "zebra", name: "Zebra"})
      {:ok, _} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
      {:ok, _} = Tenancy.create_project(ws, %{slug: "analytics", name: "Analytics"})

      slugs = Enum.map(Tenancy.list_projects(ws), & &1.slug)
      assert slugs == ["default", "analytics", "zebra"]
      # The canonical consumer contract: first project == the default.
      assert List.first(Tenancy.list_projects(ws)).slug == "default"
    end

    test "with no default-slug project, ordering stays pure alphabetical" do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "ord-ws-no-def", name: "NoDef"})
      {:ok, _} = Tenancy.create_project(ws, %{slug: "zebra", name: "Zebra"})
      {:ok, _} = Tenancy.create_project(ws, %{slug: "analytics", name: "Analytics"})
      {:ok, _} = Tenancy.create_project(ws, %{slug: "mango", name: "Mango"})

      slugs = Enum.map(Tenancy.list_projects(ws), & &1.slug)
      assert slugs == ["analytics", "mango", "zebra"]
    end
  end

  describe "list_datasets/1 ordering" do
    test "puts the production-slug dataset FIRST, then the rest alphabetically" do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "ds-ord-ws", name: "DsOrd"})
      {:ok, project} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

      # Insert out of order to prove the query — not insertion — drives ordering.
      {:ok, _} = Tenancy.create_dataset(project, %{slug: "zebra", name: "Zebra"})
      {:ok, _} = Tenancy.create_dataset(project, %{slug: "production", name: "Production"})
      {:ok, _} = Tenancy.create_dataset(project, %{slug: "analytics", name: "Analytics"})

      slugs = Enum.map(Tenancy.list_datasets(project), & &1.slug)
      assert slugs == ["production", "analytics", "zebra"]
      # The mobile cascade's single-option auto-select contract: first dataset
      # == the canonical production.
      assert List.first(Tenancy.list_datasets(project)).slug == "production"
    end

    test "with no production-slug dataset, ordering stays pure alphabetical" do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "ds-ord-ws-no-prod", name: "NoProd"})
      {:ok, project} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

      {:ok, _} = Tenancy.create_dataset(project, %{slug: "zebra", name: "Zebra"})
      {:ok, _} = Tenancy.create_dataset(project, %{slug: "analytics", name: "Analytics"})
      {:ok, _} = Tenancy.create_dataset(project, %{slug: "mango", name: "Mango"})

      slugs = Enum.map(Tenancy.list_datasets(project), & &1.slug)
      assert slugs == ["analytics", "mango", "zebra"]
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

      bad =
        Membership.changeset(%Membership{}, %{
          workspace_id: ws.id,
          principal_id: principal_id,
          role: "wizard"
        })

      refute bad.valid?
    end
  end

  describe "User principals (principal_type: \"user\")" do
    alias Barkpark.Accounts
    alias Barkpark.Tenancy.Auth

    defp user(prefix) do
      {:ok, u} =
        Accounts.register_user(%{
          email: prefix <> "-" <> Ecto.UUID.generate() <> "@example.com",
          password: "correct horse battery"
        })

      u
    end

    test "list_workspaces_for/1 returns exactly the workspaces the user is a member of" do
      u = user("lister")
      {:ok, ws_a} = Tenancy.create_workspace(%{slug: "u-lw-a", name: "A"})
      {:ok, _ws_b} = Tenancy.create_workspace(%{slug: "u-lw-b", name: "B"})

      # The user is a member of ws_a only (as a "user" principal).
      {:ok, _} = Auth.create_membership(ws_a.id, u.id, "member", "user")

      slugs = Tenancy.list_workspaces_for(u) |> Enum.map(& &1.slug)
      assert slugs == ["u-lw-a"]
      refute "u-lw-b" in slugs
    end

    test "kind isolation: a token membership sharing the user's id does NOT leak into the user's list" do
      u = user("kind")
      {:ok, ws_user} = Tenancy.create_workspace(%{slug: "u-kind-user", name: "UserWS"})
      {:ok, ws_token} = Tenancy.create_workspace(%{slug: "u-kind-token", name: "TokenWS"})

      # A "user" membership in ws_user…
      {:ok, _} = Auth.create_membership(ws_user.id, u.id, "member", "user")
      # …and an "api_token" membership carrying the SAME principal_id in ws_token.
      # (No FK on principal_id — a coincidentally-shared id is representable.)
      {:ok, _} = Auth.create_membership(ws_token.id, u.id, "owner", "api_token")

      slugs = Tenancy.list_workspaces_for(u) |> Enum.map(& &1.slug)
      # Only the "user"-kind grant is visible; the token grant is invisible.
      assert slugs == ["u-kind-user"]
      refute "u-kind-token" in slugs
    end

    test "create_workspace_with_owner/2 stamps a \"user\" owner-membership and grants the creator" do
      u = user("owner")
      {:ok, ws} = Tenancy.create_workspace_with_owner(%{name: "User Owned"}, u)

      m = Auth.membership(u, ws.id)
      assert %Membership{} = m
      assert m.role == "owner"
      assert m.principal_type == "user"

      # The creator can actually see + fully administer the workspace they made.
      assert Auth.authorize(u, ws.id, :read) == :ok
      assert Auth.authorize(u, ws.id, :write) == :ok
      assert Auth.authorize(u, ws.id, :admin) == :ok

      # …and it shows up in the user's own workspace list.
      assert ws.slug in (Tenancy.list_workspaces_for(u) |> Enum.map(& &1.slug))
    end
  end
end
