defmodule Barkpark.MigrationIntegrityTest do
  @moduledoc """
  A migration that silently did not run must not be able to report green.

  ## The invariant

  After the migrate step this suite depends on (`mix test` is aliased to
  `ecto.create --quiet` + `ecto.migrate --quiet`, see the `aliases` block in
  `mix.exs`), EVERY migration version present in the working tree is present in
  `schema_migrations`, and no two files in the tree claim the same version. A
  version failing either half fails LOUDLY and names the version.

  ## Why an exit code cannot carry this

  Ecto keys applied migrations on the integer version, never on the file. Add a
  file whose stamp another file already claimed and the migrator prints
  `Migrations already up`, exits 0, and never runs the new file's `up/0` — the
  object it was written to create is simply absent, while every downstream
  guard asserting that object exists now measures something other than the code
  under test. Measured on 2026-09-08 (`20260908090000`, twice in one night).

  ## Both arms, one run

  The green arm ("the real tree ... reporting its denominator") runs the guard
  against the actual `priv/repo/migrations` and the actual `schema_migrations`
  of the database this suite migrated, and asserts the denominator is non-zero
  and equals the file count — a check that passed by finding nothing to check
  would fail here. The red arms drive fixture directories through the same code
  path and assert the message NAMES the offending version. Both arms are in
  this one module and run together.

  ## Mutation surface

  Note what is NOT used as a mutation here: dropping an object at the database
  level. `mix test` re-migrates first, so a dropped object is rebuilt before the
  first test runs and a schema guard "mutated" that way stays green with the
  defect supposedly in place. The mutation surface for anything migration-shaped
  is the FILE — which is why every red arm below mutates a directory of files.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.MigrationIntegrity

  @moduletag :tmp_dir

  describe "the real tree against the database this suite migrated" do
    test "every migration version in the tree is applied, with a non-vacuous denominator" do
      assert {:ok, %{checked: checked, applied: applied}} = MigrationIntegrity.check()

      on_disk =
        MigrationIntegrity.default_dir()
        |> Path.join("*.exs")
        |> Path.wildcard()
        |> length()

      assert on_disk > 0,
             "read ZERO migration files from #{MigrationIntegrity.default_dir()} — " <>
               "the denominator itself is broken"

      assert checked == on_disk,
             "guard checked #{checked} versions but #{on_disk} migration files are on disk"

      assert checked > 0
      assert applied >= checked
    end

    test "check!/1 returns the same denominator instead of raising" do
      assert %{checked: checked} = MigrationIntegrity.check!()
      assert checked > 0
    end
  end

  describe "red arm — a version in the tree with no row in schema_migrations" do
    test "reds naming the unapplied version and its file", %{tmp_dir: dir} do
      write(dir, "20260101000000_create_widgets.exs")
      write(dir, "20260102000000_add_widget_color.exs")

      assert {:error, message} =
               MigrationIntegrity.check(dir: dir, applied: [20_260_101_000_000])

      assert message =~ "ABSENT from"
      assert message =~ "20260102000000"
      assert message =~ "20260102000000_add_widget_color.exs"
      # the applied one is not accused
      refute message =~ "20260101000000_create_widgets.exs"
      # and the denominator travels with the failure
      assert message =~ "Checked 2 migration version(s)"
    end
  end

  describe "red arm — two files claiming one version (the collision)" do
    test "reds naming the version and BOTH files", %{tmp_dir: dir} do
      write(dir, "20260908090000_add_documents_media_processing_index.exs")
      write(dir, "20260908090000_add_allowed_auth_methods_to_organizations.exs")
      write(dir, "20260908094217_unrelated.exs")

      # Both colliding files' version IS in schema_migrations — that is exactly
      # the shape that makes the migrator exit 0 and skip one of them. The
      # tree-vs-applied half alone would pass here; the collision half is what
      # catches it.
      assert {:error, message} =
               MigrationIntegrity.check(
                 dir: dir,
                 applied: [20_260_908_090_000, 20_260_908_094_217]
               )

      assert message =~ "SAME version"
      assert message =~ "version 20260908090000"
      assert message =~ "20260908090000_add_documents_media_processing_index.exs"
      assert message =~ "20260908090000_add_allowed_auth_methods_to_organizations.exs"
      refute message =~ "20260908094217_unrelated.exs"
    end

    test "the same tree WITHOUT the collision passes — the negative control", %{tmp_dir: dir} do
      write(dir, "20260908094216_add_documents_media_processing_index.exs")
      write(dir, "20260908090000_add_allowed_auth_methods_to_organizations.exs")
      write(dir, "20260908094217_unrelated.exs")

      assert {:ok, %{checked: 3}} =
               MigrationIntegrity.check(
                 dir: dir,
                 applied: [20_260_908_090_000, 20_260_908_094_216, 20_260_908_094_217]
               )
    end
  end

  describe "positive control — an empty read is a failure, never a pass" do
    test "zero migration files reds instead of vacuously passing", %{tmp_dir: dir} do
      assert {:error, message} = MigrationIntegrity.check(dir: dir, applied: [1])
      assert message =~ "ZERO migration files"
      assert message =~ dir
    end

    test "zero rows in schema_migrations reds instead of vacuously passing", %{tmp_dir: dir} do
      write(dir, "20260101000000_create_widgets.exs")

      assert {:error, message} = MigrationIntegrity.check(dir: dir, applied: [])
      assert message =~ "ZERO rows from schema_migrations"
    end

    test "an unreadable schema_migrations reds instead of vacuously passing", %{tmp_dir: dir} do
      write(dir, "20260101000000_create_widgets.exs")

      assert {:error, message} =
               MigrationIntegrity.check(
                 dir: dir,
                 applied: fn -> raise Postgrex.Error, message: "relation does not exist" end
               )

      assert message =~ "could not read schema_migrations"
      assert message =~ "relation does not exist"
    end

    test "a filename with no version prefix reds naming the file", %{tmp_dir: dir} do
      write(dir, "20260101000000_create_widgets.exs")
      write(dir, "create_widgets_again.exs")

      assert {:error, message} = MigrationIntegrity.check(dir: dir, applied: [20_260_101_000_000])
      assert message =~ "without a leading integer version"
      assert message =~ "create_widgets_again.exs"
    end
  end

  describe "applied_versions/1 reads the live table" do
    test "returns a non-empty integer set for the database this suite migrated" do
      applied = MigrationIntegrity.applied_versions(Barkpark.Repo)

      assert MapSet.size(applied) > 0
      assert Enum.all?(applied, &is_integer/1)
    end
  end

  defp write(dir, name) do
    File.write!(Path.join(dir, name), "# fixture, never executed\n")
  end
end
