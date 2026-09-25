defmodule Mix.Tasks.Barkpark.CoreWithoutOwnedTables do
  @moduledoc """
  The differential proof that core runs without the plugin/fleet tables
  (Barkspark phase 2, slice 2, task-d3ecc509d4ea227d, criterion 0).

      mix test.core_without_owned_tables              # the whole suite
      mix test.core_without_owned_tables test/barkpark/tenancy
      mix test.core_without_owned_tables --keep-dbs   # leave both DBs for a look

  ## What it does

  1. Creates and migrates two fresh test databases, `<partition>_otp`
     (tables PRESENT) and `<partition>_ota` (tables ABSENT), where `<partition>`
     is this checkout's `MIX_TEST_PARTITION` suffix.
  2. In the ABSENT database drops every table in `Barkpark.OwnedTables.tables/0`,
     the two core triggers in `core_triggers/0` and the fleet SQL functions in
     `functions/0`. The functions are dropped WITHOUT cascade, so a core object
     that still depended on one would refuse the drop and fail the run.
  3. Runs `mix test` against each database with `BARKPARK_PLUGINS=""` and every
     capability in `BARKPARK_CAPABILITIES_OFF`, with the same `--seed`.
  4. A test red in the ABSENT run but not in the PRESENT run is NEWLY RED. Every
     file holding one is run again against both databases, and only a test red
     in the absent rerun and green in the present rerun counts. That keeps a
     one-off flake from failing the check.
  5. Prints both summary lines and the diff, drops both databases unless
     `--keep-dbs`, and exits 1 when any newly-red test is confirmed, or when
     either run printed no summary line.

  Tests already red with the tables PRESENT are not this check's subject. With
  every plugin off, many tests fail because they need a plugin's schemas; tagging
  those is task-ba5085862f3da4e4. This check reports only what the missing
  tables change.
  """
  @shortdoc "Differential: tests green with plugin/fleet tables present must stay green with them absent"

  use Mix.Task

  alias Barkpark.Capability
  alias Barkpark.OwnedTables

  @switches [keep_dbs: :boolean, seed: :integer]

  @impl Mix.Task
  def run(args) do
    {opts, test_args, _} = OptionParser.parse(args, strict: @switches)
    Mix.Task.run("app.config")

    base = Application.fetch_env!(:barkpark, :test_db_partition).suffix
    seed = Keyword.get_lazy(opts, :seed, fn -> :rand.uniform(999_999) end)
    present = base <> "_otp"
    absent = base <> "_ota"
    log_dir = Path.join(System.tmp_dir!(), "core_without_owned_tables_#{System.os_time()}")
    File.mkdir_p!(log_dir)

    try do
      Enum.each([present, absent], &fresh_db!/1)
      drop_owned!(absent)

      shell("seed #{seed}; logs in #{log_dir}")
      p = run_suite(present, test_args, seed, Path.join(log_dir, "present.log"))
      a = run_suite(absent, test_args, seed, Path.join(log_dir, "absent.log"))

      newly = MapSet.difference(a.failed, p.failed)
      confirmed = confirm(newly, a.files, present, absent, seed, log_dir)

      report(p, a, newly, confirmed)

      if p.summary == nil or a.summary == nil or MapSet.size(confirmed) > 0 do
        exit({:shutdown, 1})
      end
    after
      unless opts[:keep_dbs], do: Enum.each([present, absent], &drop_db/1)
    end
  end

  # ── databases ───────────────────────────────────────────────────────────

  defp fresh_db!(suffix) do
    drop_db(suffix)
    mix!(suffix, ["do", "ecto.create", "--quiet", "+", "ecto.migrate", "--quiet"])
  end

  defp drop_db(suffix), do: mix(suffix, ["ecto.drop", "--quiet", "--force-drop"])

  defp drop_owned!(suffix) do
    {:ok, _} = Application.ensure_all_started(:postgrex)

    config =
      Application.fetch_env!(:barkpark, Barkpark.Repo)
      |> Keyword.take([:hostname, :port, :username, :password])
      |> Keyword.put(:database, "barkpark_test" <> suffix)

    {:ok, conn} = Postgrex.start_link(config)

    statements =
      Enum.map(OwnedTables.core_triggers(), fn {table, trigger} ->
        ~s(DROP TRIGGER "#{trigger}" ON "#{table}")
      end) ++
        [
          "DROP TABLE " <> Enum.map_join(OwnedTables.tables(), ", ", &~s("#{&1}")) <> " CASCADE",
          "DROP FUNCTION " <> Enum.join(OwnedTables.functions(), ", ")
        ]

    Postgrex.transaction(conn, fn c -> Enum.each(statements, &Postgrex.query!(c, &1, [])) end)
    |> case do
      {:ok, _} -> :ok
      other -> Mix.raise("dropping the owned tables failed: #{inspect(other)}")
    end

    GenServer.stop(conn)

    shell(
      "dropped #{length(OwnedTables.tables())} owned tables, " <>
        "#{length(OwnedTables.core_triggers())} core triggers, " <>
        "#{length(OwnedTables.functions())} fleet functions in barkpark_test#{suffix}"
    )
  end

  # ── suite runs ──────────────────────────────────────────────────────────

  defp run_suite(suffix, test_args, seed, log) do
    status = mix(suffix, ["test", "--seed", Integer.to_string(seed) | test_args], log)
    parse(File.read!(log), status)
  end

  defp confirm(newly, files_by_test, present, absent, seed, log_dir) do
    files =
      newly |> Enum.map(&Map.get(files_by_test, &1)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if files == [] do
      newly
    else
      shell("re-running #{length(files)} file(s) holding newly-red tests against both databases")
      p = run_suite(present, files, seed, Path.join(log_dir, "confirm_present.log"))
      a = run_suite(absent, files, seed, Path.join(log_dir, "confirm_absent.log"))

      newly
      |> MapSet.intersection(a.failed)
      |> MapSet.difference(p.failed)
    end
  end

  # A failure header is `  N) test NAME (Module)` or `  N) Module: failure on
  # setup_all callback, ...`; the next non-blank line names `test/...:LINE`.
  defp parse(output, status) do
    lines = String.split(output, "\n")

    {failed, files} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({MapSet.new(), %{}}, fn {line, i}, {failed, files} ->
        case Regex.run(~r/^\s+\d+\) (.+)$/, line) do
          [_, id] ->
            file =
              lines
              |> Enum.drop(i + 1)
              |> Enum.find_value(&failure_file/1)

            {MapSet.put(failed, id), Map.put(files, id, file)}

          _ ->
            {failed, files}
        end
      end)

    summary = Enum.find(lines, &Regex.match?(~r/^\d+ (doctests?, )?tests?, \d+ failures?/, &1))
    %{failed: failed, files: files, summary: summary, status: status}
  end

  defp failure_file(line) do
    case Regex.run(~r/^\s+(test\/\S+_test\.exs):\d+$/, line) do
      [_, file] -> file
      _ -> nil
    end
  end

  defp report(p, a, newly, confirmed) do
    shell("PRESENT: #{p.summary || "NO SUMMARY LINE (exit #{p.status})"}")
    shell("ABSENT:  #{a.summary || "NO SUMMARY LINE (exit #{a.status})"}")

    shell(
      "red only when ABSENT: #{MapSet.size(newly)} first pass, " <>
        "#{MapSet.size(confirmed)} confirmed on rerun"
    )

    shell("red only when PRESENT: #{MapSet.size(MapSet.difference(p.failed, a.failed))}")
    Enum.each(Enum.sort(confirmed), &shell("  NEWLY RED  #{&1}"))

    Enum.each(
      Enum.sort(MapSet.difference(newly, confirmed)),
      &shell("  flaked (green on rerun)  #{&1}")
    )
  end

  # ── child mix ───────────────────────────────────────────────────────────

  defp child_env(suffix) do
    [
      {"MIX_ENV", "test"},
      {"MIX_TEST_PARTITION", suffix},
      # NOT "": an empty value UNSETS the variable in a port env (`System.cmd`),
      # and unset means "discover every plugin". "," parses to the same `[]`
      # kill switch (`Barkpark.Plugins.EnvConfig.parse/1`).
      {"BARKPARK_PLUGINS", ","},
      {"BARKPARK_CAPABILITIES_OFF", Enum.map_join(Capability.names(), ",", &Atom.to_string/1)}
    ]
  end

  defp mix!(suffix, args) do
    case mix(suffix, args) do
      0 -> :ok
      status -> Mix.raise("mix #{Enum.join(args, " ")} exited #{status}")
    end
  end

  defp mix(suffix, args, log \\ nil) do
    into = if log, do: File.stream!(log), else: IO.stream()

    {_, status} =
      System.cmd("mix", args, env: child_env(suffix), into: into, stderr_to_stdout: true)

    status
  end

  defp shell(msg), do: Mix.shell().info("[core-without-owned-tables] " <> msg)
end
