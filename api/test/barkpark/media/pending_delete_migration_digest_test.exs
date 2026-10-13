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

  defp probe_source(module) do
    @migration
    |> File.read!()
    |> String.replace(
      "Barkpark.Repo.Migrations.AddPendingMediaDeleteOperations",
      module |> Atom.to_string() |> String.trim_leading("Elixir.")
    )
  end
end
