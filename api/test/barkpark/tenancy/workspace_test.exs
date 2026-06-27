defmodule Barkpark.Tenancy.WorkspaceTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Workspace

  # ---------------------------------------------------------------------------
  # reserved_slugs/0
  # ---------------------------------------------------------------------------

  describe "reserved_slugs/0" do
    test "returns a non-empty list of strings" do
      slugs = Workspace.reserved_slugs()
      assert is_list(slugs)
      refute Enum.empty?(slugs)
      assert Enum.all?(slugs, &is_binary/1)
    end

    test "includes the routing-critical slugs" do
      reserved = Workspace.reserved_slugs()

      for slug <- ~w(admin api studio v1 w p) do
        assert slug in reserved,
               "expected #{inspect(slug)} to be reserved but it was absent from #{inspect(reserved)}"
      end
    end

    test "includes the media and login slugs" do
      reserved = Workspace.reserved_slugs()
      assert "media" in reserved
      assert "login" in reserved
    end

    test "all reserved slugs consist only of lowercase alphanum / underscores" do
      # Reserved slugs bypass format validation via validate_exclusion, so they
      # must themselves be uncraftable through the normal changeset path.
      for slug <- Workspace.reserved_slugs() do
        assert slug =~ ~r/^[a-z0-9_]+$/,
               "reserved slug #{inspect(slug)} has unexpected characters"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — happy paths
  # ---------------------------------------------------------------------------

  describe "changeset/2 — valid attrs" do
    test "accepts a minimal valid workspace" do
      cs = Workspace.changeset(%Workspace{}, %{slug: "my-workspace", name: "My Workspace"})
      assert cs.valid?
    end

    test "accepts slug starting with a digit" do
      cs = Workspace.changeset(%Workspace{}, %{slug: "2nd-team", name: "Second Team"})
      assert cs.valid?
    end

    test "accepts slug with internal hyphens" do
      cs = Workspace.changeset(%Workspace{}, %{slug: "my-cool-org", name: "Cool Org"})
      assert cs.valid?
    end

    test "accepts slug that is exactly 63 characters" do
      slug = String.duplicate("a", 60) <> "bbb"
      assert byte_size(slug) == 63
      cs = Workspace.changeset(%Workspace{}, %{slug: slug, name: "Long Slug"})
      assert cs.valid?
    end

    test "accepts a name that is exactly 255 characters" do
      name = String.duplicate("n", 255)
      cs = Workspace.changeset(%Workspace{}, %{slug: "ok-slug", name: name})
      assert cs.valid?
    end

    test "accepts a single alphanumeric character as slug" do
      cs = Workspace.changeset(%Workspace{}, %{slug: "z", name: "Z"})
      assert cs.valid?
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — required-field guards
  # ---------------------------------------------------------------------------

  describe "changeset/2 — required fields" do
    test "requires slug" do
      cs = Workspace.changeset(%Workspace{}, %{name: "No Slug"})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).slug
    end

    test "requires name" do
      cs = Workspace.changeset(%Workspace{}, %{slug: "no-name"})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).name
    end

    test "empty string slug is treated as blank" do
      cs = Workspace.changeset(%Workspace{}, %{slug: "", name: "Has Name"})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).slug
    end

    test "empty string name is treated as blank" do
      cs = Workspace.changeset(%Workspace{}, %{slug: "has-slug", name: ""})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).name
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — slug format validation
  # ---------------------------------------------------------------------------

  describe "changeset/2 — slug format" do
    test "rejects uppercase letters" do
      cs = Workspace.changeset(%Workspace{}, %{slug: "MyWorkspace", name: "X"})
      refute cs.valid?
      assert errors_on(cs).slug != []
    end

    test "rejects slug with spaces" do
      cs = Workspace.changeset(%Workspace{}, %{slug: "my workspace", name: "X"})
      refute cs.valid?
      assert errors_on(cs).slug != []
    end

    test "rejects slug starting with a hyphen" do
      cs = Workspace.changeset(%Workspace{}, %{slug: "-bad", name: "X"})
      refute cs.valid?
      assert errors_on(cs).slug != []
    end

    test "rejects slug with a dot" do
      cs = Workspace.changeset(%Workspace{}, %{slug: "bad.slug", name: "X"})
      refute cs.valid?
      assert errors_on(cs).slug != []
    end

    test "rejects slug with an underscore" do
      cs = Workspace.changeset(%Workspace{}, %{slug: "bad_slug", name: "X"})
      refute cs.valid?
      assert errors_on(cs).slug != []
    end

    test "format error message mentions lowercase alphanumeric with hyphens" do
      cs = Workspace.changeset(%Workspace{}, %{slug: "UPPER", name: "X"})
      errors = errors_on(cs).slug

      assert Enum.any?(errors, &String.contains?(&1, "lowercase alphanumeric")),
             "expected format error to mention 'lowercase alphanumeric', got: #{inspect(errors)}"
    end

    test "rejects slug that is too long (> 63 chars)" do
      slug = String.duplicate("a", 64)
      cs = Workspace.changeset(%Workspace{}, %{slug: slug, name: "X"})
      refute cs.valid?
      assert errors_on(cs).slug != []
    end

    test "rejects name that exceeds 255 characters" do
      name = String.duplicate("n", 256)
      cs = Workspace.changeset(%Workspace{}, %{slug: "ok-slug", name: name})
      refute cs.valid?
      assert errors_on(cs).name != []
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — reserved slug exclusion
  # ---------------------------------------------------------------------------

  describe "changeset/2 — reserved slugs" do
    test "rejects every reserved slug with 'is reserved'" do
      for reserved <- Workspace.reserved_slugs() do
        cs = Workspace.changeset(%Workspace{}, %{slug: reserved, name: "Org"})

        refute cs.valid?,
               "expected slug #{inspect(reserved)} to be rejected as reserved but changeset was valid"

        assert "is reserved" in errors_on(cs).slug,
               "expected 'is reserved' for slug #{inspect(reserved)}, got: #{inspect(errors_on(cs).slug)}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — DB-level unique constraint (slug is globally unique)
  # ---------------------------------------------------------------------------

  describe "changeset/2 — global slug uniqueness" do
    test "duplicate slug across the whole table returns a unique constraint error" do
      slug = "dup-ws-#{unique_int()}"
      {:ok, _} = Tenancy.create_workspace(%{slug: slug, name: "First"})

      {:error, cs} = Tenancy.create_workspace(%{slug: slug, name: "Second"})
      refute cs.valid?

      assert errors_on(cs).slug != [],
             "expected a slug uniqueness error, got: #{inspect(errors_on(cs))}"
    end

    test "distinct slugs can be inserted concurrently" do
      slug_a = "ws-a-#{unique_int()}"
      slug_b = "ws-b-#{unique_int()}"

      assert {:ok, ws_a} = Tenancy.create_workspace(%{slug: slug_a, name: "A"})
      assert {:ok, ws_b} = Tenancy.create_workspace(%{slug: slug_b, name: "B"})

      assert ws_a.slug == slug_a
      assert ws_b.slug == slug_b
      assert ws_a.id != ws_b.id
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_int, do: System.unique_integer([:positive])
end
