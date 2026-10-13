defmodule Mix.Tasks.Barkpark.SchemaDiff do
  @moduledoc """
  Compares the schemas of two databases and names every object that differs
  (Barkspark phase 2, slice 3, task-097a1b8ed6d27a8b).

      mix barkpark.schema_diff barkpark_test_a barkpark_test_b
      mix barkpark.schema_diff "host=localhost dbname=a" "host=localhost dbname=b"

  Each argument goes to `pg_dump --dbname`, so a bare name uses the usual
  `PGHOST`, `PGUSER` and `PGPASSWORD`. `pg_dump` must be on PATH and its major
  version must be at least the server's.

  Prints one line per difference and a count. Exits 0 when the schemas match,
  1 when they differ, and 2 when a dump fails. See `Barkpark.SchemaDiff` for
  how statements are normalised and keyed.
  """
  @shortdoc "Compares two database schemas object by object"

  use Mix.Task

  alias Barkpark.SchemaDiff

  @impl Mix.Task
  def run([a, b]) do
    with {:ok, dump_a} <- SchemaDiff.dump(a),
         {:ok, dump_b} <- SchemaDiff.dump(b) do
      differences = SchemaDiff.diff(dump_a, dump_b)
      objects = map_size(SchemaDiff.objects(dump_a))

      Mix.shell().info("schema-diff: A=#{a} B=#{b} (#{objects} objects in A)")
      Enum.each(differences, &Mix.shell().info(SchemaDiff.format(&1)))
      Mix.shell().info("#{length(differences)} difference(s)")

      if differences != [], do: exit({:shutdown, 1})
    else
      {:error, message} ->
        Mix.shell().error("schema-diff: CANNOT READ — #{message}")
        exit({:shutdown, 2})
    end
  end

  def run(_args) do
    Mix.shell().error("usage: mix barkpark.schema_diff DB_A DB_B")
    exit({:shutdown, 2})
  end
end
