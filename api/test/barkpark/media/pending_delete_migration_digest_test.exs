defmodule Barkpark.Media.PendingDeleteMigrationDigestTest do
  use ExUnit.Case, async: true

  @migration Path.expand(
               "../../../priv/repo/migrations/20261011140000_add_pending_media_delete_operations.exs",
               __DIR__
             )
  @resource Path.expand("../../../priv/media/delete_operations_v1.sql", __DIR__)

  test "an unchanged SQL resource compiles, but a mutation cannot reuse the migration version" do
    root =
      Path.join(System.tmp_dir!(), "pending-sql-digest-#{System.unique_integer([:positive])}")

    migrations = Path.join(root, "api/priv/repo/migrations")
    resource = Path.join(root, "api/priv/media/delete_operations_v1.sql")
    File.mkdir_p!(migrations)
    File.mkdir_p!(Path.dirname(resource))
    File.cp!(@resource, resource)

    good = Module.concat(__MODULE__, "Good#{System.unique_integer([:positive])}")
    good_file = Path.join(migrations, "good.exs")
    File.write!(good_file, probe_source(good))
    assert [{^good, _binary}] = Code.compile_file(good_file)

    File.write!(
      resource,
      File.read!(resource) <> "\n-- changed after the version was published\n"
    )

    bad = Module.concat(__MODULE__, "Bad#{System.unique_integer([:positive])}")
    bad_file = Path.join(migrations, "bad.exs")
    File.write!(bad_file, probe_source(bad))

    assert_raise ArgumentError,
                 ~r/pending media migration SQL changed; add a forward migration/,
                 fn ->
                   Code.compile_file(bad_file)
                 end
  end

  test "the source-id forward migration also binds both SQL versions" do
    root =
      Path.join(
        System.tmp_dir!(),
        "pending-source-id-digest-#{System.unique_integer([:positive])}"
      )

    migrations = Path.join(root, "api/priv/repo/migrations")
    resources = Path.join(root, "api/priv/media")
    File.mkdir_p!(migrations)
    File.mkdir_p!(resources)

    for name <- ["delete_operations_v1.sql", "delete_operations_source_id_v2.sql"] do
      File.cp!(Path.join(Path.dirname(@resource), name), Path.join(resources, name))
    end

    migration =
      Path.join(
        Path.dirname(@migration),
        "20261014001000_refresh_pending_media_delete_source_id.exs"
      )

    module = Module.concat(__MODULE__, "SourceId#{System.unique_integer([:positive])}")

    source =
      File.read!(migration)
      |> String.replace(
        "Barkpark.Repo.Migrations.RefreshPendingMediaDeleteSourceId",
        module |> Atom.to_string() |> String.trim_leading("Elixir.")
      )

    probe = Path.join(migrations, "source_id.exs")
    File.write!(probe, source)
    assert [{^module, _}] = Code.compile_file(probe)

    for name <- ["delete_operations_v1.sql", "delete_operations_source_id_v2.sql"] do
      original = File.read!(Path.join(resources, name))
      File.write!(Path.join(resources, name), original <> "\n-- altered applied SQL\n")

      assert_raise ArgumentError,
                   ~r/pending media migration SQL changed; add a forward migration/,
                   fn ->
                     Code.compile_file(probe)
                   end

      File.write!(Path.join(resources, name), original)
    end
  end

  defp probe_source(module) do
    @migration
    |> File.read!()
    |> String.replace(
      "Barkpark.Repo.Migrations.AddPendingMediaDeleteOperations",
      module |> Atom.to_string() |> String.trim_leading("Elixir.")
    )
  end
end
