defmodule Barkpark.Tenancy.ProjectTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Project

  # ---------------------------------------------------------------------------
  # reserved_slugs/0
  # ---------------------------------------------------------------------------

  describe "reserved_slugs/0" do
    test "returns a non-empty list of strings" do
      slugs = Project.reserved_slugs()
      assert is_list(slugs)
      refute Enum.empty?(slugs)
      assert Enum.all?(slugs, &is_binary/1)
    end

    test "includes the routing-critical slugs" do
      reserved = Project.reserved_slugs()
      # These appear in the router's scoped path and must never collide.
      for slug <- ~w(admin api studio v1 w p) do
        assert slug in reserved,
               "expected #{inspect(slug)} to be reserved but it was not in #{inspect(reserved)}"
      end
    end

    test "all reserved slugs are lower-case alphanumeric (no hyphens, no spaces)" do
      # Reserved slugs bypass the format validator via validate_exclusion, so
      # they must themselves not be craftable via the public changeset.
      for slug <- Project.reserved_slugs() do
        assert slug =~ ~r/^[a-z0-9_]+$/,
               "reserved slug #{inspect(slug)} has unexpected characters"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — happy paths
  # ---------------------------------------------------------------------------

  describe "changeset/2 — valid attrs" do
    setup do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "proj-test-ws-#{unique_int()}", name: "Test"})
      {:ok, ws: ws}
    end

    test "accepts a minimal valid project", %{ws: ws} do
      cs = Project.changeset(%Project{}, %{slug: "my-project", name: "My Project", workspace_id: ws.id})
      assert cs.valid?
    end

    test "accepts slug starting with a digit", %{ws: ws} do
      cs = Project.changeset(%Project{}, %{slug: "2nd-site", name: "2nd", workspace_id: ws.id})
      assert cs.valid?
    end

    test "accepts slug that is exactly 63 characters", %{ws: ws} do
      slug = String.duplicate("a", 60) <> "bbb"
      assert byte_size(slug) == 63
      cs = Project.changeset(%Project{}, %{slug: slug, name: "Long", workspace_id: ws.id})
      assert cs.valid?
    end

    test "accepts a name that is exactly 255 characters", %{ws: ws} do
      name = String.duplicate("n", 255)
      cs = Project.changeset(%Project{}, %{slug: "ok-slug", name: name, workspace_id: ws.id})
      assert cs.valid?
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — required-field guards
  # ---------------------------------------------------------------------------

  describe "changeset/2 — required fields" do
    test "requires slug" do
      cs = Project.changeset(%Project{}, %{name: "No Slug", workspace_id: Ecto.UUID.generate()})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).slug
    end

    test "requires name" do
      cs = Project.changeset(%Project{}, %{slug: "no-name", workspace_id: Ecto.UUID.generate()})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).name
    end

    test "requires workspace_id" do
      cs = Project.changeset(%Project{}, %{slug: "no-ws", name: "No Workspace"})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).workspace_id
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — slug format validation
  # ---------------------------------------------------------------------------

  describe "changeset/2 — slug format" do
    setup do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "fmt-ws-#{unique_int()}", name: "FmtWs"})
      {:ok, ws: ws}
    end

    test "rejects uppercase letters", %{ws: ws} do
      cs = Project.changeset(%Project{}, %{slug: "MyProject", name: "X", workspace_id: ws.id})
      refute cs.valid?
      assert errors_on(cs).slug != []
    end

    test "rejects slug with spaces", %{ws: ws} do
      cs = Project.changeset(%Project{}, %{slug: "my project", name: "X", workspace_id: ws.id})
      refute cs.valid?
      assert errors_on(cs).slug != []
    end

    test "rejects slug starting with a hyphen", %{ws: ws} do
      cs = Project.changeset(%Project{}, %{slug: "-bad", name: "X", workspace_id: ws.id})
      refute cs.valid?
      assert errors_on(cs).slug != []
    end

    test "rejects slug with a trailing dot or special chars", %{ws: ws} do
      cs = Project.changeset(%Project{}, %{slug: "bad.slug", name: "X", workspace_id: ws.id})
      refute cs.valid?
      assert errors_on(cs).slug != []
    end

    test "rejects slug that is too long (> 63 chars)", %{ws: ws} do
      slug = String.duplicate("a", 64)
      cs = Project.changeset(%Project{}, %{slug: slug, name: "X", workspace_id: ws.id})
      refute cs.valid?
      assert errors_on(cs).slug != []
    end

    test "rejects name that exceeds 255 characters", %{ws: ws} do
      name = String.duplicate("n", 256)
      cs = Project.changeset(%Project{}, %{slug: "ok-slug2", name: name, workspace_id: ws.id})
      refute cs.valid?
      assert errors_on(cs).name != []
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — reserved slug exclusion
  # ---------------------------------------------------------------------------

  describe "changeset/2 — reserved slugs" do
    setup do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "rsv-ws-#{unique_int()}", name: "RsvWs"})
      {:ok, ws: ws}
    end

    test "rejects every reserved slug", %{ws: ws} do
      for reserved <- Project.reserved_slugs() do
        cs = Project.changeset(%Project{}, %{slug: reserved, name: "X", workspace_id: ws.id})
        refute cs.valid?,
               "expected slug #{inspect(reserved)} to be rejected as reserved but changeset was valid"
        assert "is reserved" in errors_on(cs).slug,
               "expected 'is reserved' error for slug #{inspect(reserved)}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — DB-level unique constraint (slug scoped to workspace)
  # ---------------------------------------------------------------------------

  describe "changeset/2 — uniqueness constraint" do
    test "same slug in the same workspace returns a unique constraint error" do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "uniq-ws-#{unique_int()}", name: "Uniq"})
      {:ok, _} = Tenancy.create_project(ws, %{slug: "dup", name: "First"})

      {:error, cs} = Tenancy.create_project(ws, %{slug: "dup", name: "Second"})
      refute cs.valid?
      assert "already exists in this workspace" in errors_on(cs).slug
    end

    test "same slug in a different workspace is allowed" do
      {:ok, ws_a} = Tenancy.create_workspace(%{slug: "cross-a-#{unique_int()}", name: "A"})
      {:ok, ws_b} = Tenancy.create_workspace(%{slug: "cross-b-#{unique_int()}", name: "B"})

      {:ok, _} = Tenancy.create_project(ws_a, %{slug: "shared", name: "Shared"})
      assert {:ok, p_b} = Tenancy.create_project(ws_b, %{slug: "shared", name: "Shared"})
      assert p_b.workspace_id == ws_b.id
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — assoc_constraint on workspace_id
  # ---------------------------------------------------------------------------

  describe "changeset/2 — workspace assoc constraint" do
    test "rejects a non-existent workspace_id at the DB level" do
      ghost_id = Ecto.UUID.generate()

      result =
        %Project{}
        |> Project.changeset(%{slug: "orphan", name: "Orphan", workspace_id: ghost_id})
        |> Barkpark.Repo.insert()

      assert {:error, cs} = result
      refute cs.valid?
      # assoc_constraint fires as a foreign-key violation → :workspace error
      assert errors_on(cs).workspace != [], "expected workspace assoc error, got #{inspect(errors_on(cs))}"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_int, do: System.unique_integer([:positive])
end
