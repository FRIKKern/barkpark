defmodule Barkpark.MigrationIntegrity do
  @moduledoc """
  The invariant: **after the migrate step, every migration version present in
  the working tree is present in `schema_migrations`** — and no two files in the
  tree claim the same version. A version that fails either half is named, loudly.

  ## Why this exists

  Ecto keys applied migrations on the integer VERSION, never on the file or its
  contents. Two different files sharing a version are indistinguishable to it.
  So when a new migration is added whose stamp another file already claimed —
  a round-number timestamp dated today is the collision-prone shape, because
  every agent generating a stamp by hand reaches for the same digits — the
  migrator prints `Migrations already up`, **exits 0, and never runs the new
  file's `up/0`**. The object the migration was written to create is simply
  absent, and a guard asserting it exists then fails or passes for a reason
  unrelated to the code under test.

  Measured on 2026-09-08: `20260908090000_add_documents_media_processing_index.exs`
  collided with a version already in the shared test database; the index was
  never created and `mix ecto.migrate` reported success. Renaming to the
  non-round `20260908094217` made it run. The identical `20260908090000` stamp
  also landed on `origin/main` that night in a different file, so the hazard is
  between merged branches, not merely between concurrent agents.

  This module does NOT change how Ecto works. Version-keyed idempotence is
  correct and is what makes migrations safe to re-run. The gap it closes is that
  nothing told you when the migrator silently did nothing to a file you just added.

  ## Reading an empty set is a failure, not a pass

  A check that passes because it found nothing to check measures nothing. Both
  reads are therefore guarded: zero migration files on disk, or an empty /
  unreadable `schema_migrations`, are LOUD failures with their own message —
  never `{:ok, ...}`. `{:ok, %{checked: n}}` always carries the denominator so
  a caller can assert it is non-vacuous.

  ## Where it runs

  One implementation, two venues:

    * the test suite — `test/barkpark/migration_integrity_test.exs`, which runs
      after `mix test`'s `ecto.migrate` alias, i.e. exactly where a silently
      skipped migration would otherwise go unnoticed;
    * a release — `Barkpark.Release.verify_migrations!/0`, for an operator
      checking a box after `bin/barkpark eval 'Barkpark.Release.migrate()'`.
  """

  @version_re ~r/^(\d+)_/

  @type failure :: {:error, String.t()}
  @type success :: {:ok, %{checked: non_neg_integer(), applied: non_neg_integer()}}

  @doc """
  Check the invariant. `{:ok, %{checked: n, applied: m}}` or `{:error, message}`.

  Options (all defaulted; overridden only by the guard's own tests, which point
  them at fixture directories and fixture version sets):

    * `:dir` — the migrations directory (default: the app's `priv/repo/migrations`)
    * `:repo` — the repo whose `schema_migrations` is read (default: `Barkpark.Repo`)
    * `:applied` — a zero-arity fun returning the applied versions, bypassing `:repo`
  """
  @spec check(keyword()) :: success() | failure()
  def check(opts \\ []) do
    dir = Keyword.get_lazy(opts, :dir, &default_dir/0)

    with {:ok, files} <- read_files(dir),
         {:ok, by_version} <- index_by_version(files, dir),
         {:ok, applied} <- read_applied(opts) do
      missing =
        by_version
        |> Enum.reject(fn {version, _names} -> MapSet.member?(applied, version) end)
        |> Enum.sort_by(fn {version, _names} -> version end)

      if missing == [] do
        {:ok, %{checked: map_size(by_version), applied: MapSet.size(applied)}}
      else
        {:error, missing_message(missing, map_size(by_version))}
      end
    end
  end

  @doc """
  `check/1`, raising `RuntimeError` with the guard's message on failure.
  Returns the `{:ok, ...}` payload so a caller can log the denominator.
  """
  @spec check!(keyword()) :: %{checked: non_neg_integer(), applied: non_neg_integer()}
  def check!(opts \\ []) do
    case check(opts) do
      {:ok, counts} -> counts
      {:error, message} -> raise message
    end
  end

  @doc "The versions recorded in `schema_migrations`, as a MapSet of integers."
  @spec applied_versions(module()) :: MapSet.t(integer())
  def applied_versions(repo) do
    %{rows: rows} = repo.query!("SELECT version FROM schema_migrations", [])
    MapSet.new(rows, fn [version] -> version end)
  end

  @doc "The migrations directory this guard reads by default."
  @spec default_dir() :: String.t()
  def default_dir do
    Application.app_dir(:barkpark, "priv/repo/migrations")
  end

  # -- reads, each of which refuses an empty result ---------------------------

  defp read_files(dir) do
    case dir |> Path.join("*.exs") |> Path.wildcard() |> Enum.sort() do
      [] ->
        {:error,
         """
         migration integrity guard read ZERO migration files.

         Directory: #{dir}

         An empty read is a broken instrument, not a clean tree: this guard
         cannot pass by having found nothing to check. Either the path is wrong
         (a release whose priv/ was not shipped, a symlink into a stale _build)
         or every migration has been deleted — both are loud.
         """}

      files ->
        {:ok, files}
    end
  end

  defp index_by_version(files, dir) do
    {parsed, unparsable} =
      Enum.split_with(files, fn path -> Regex.run(@version_re, Path.basename(path)) end)

    if unparsable != [] do
      {:error,
       """
       migration filenames without a leading integer version — the migrator
       cannot key them and this guard cannot check them:

       #{Enum.map_join(unparsable, "\n", &"  #{Path.basename(&1)}")}

       Directory: #{dir}
       """}
    else
      by_version =
        Enum.group_by(
          parsed,
          fn path ->
            [_, version] = Regex.run(@version_re, Path.basename(path))
            String.to_integer(version)
          end,
          &Path.basename/1
        )

      case Enum.filter(by_version, fn {_version, names} -> length(names) > 1 end) do
        [] -> {:ok, by_version}
        collisions -> {:error, collision_message(Enum.sort(collisions))}
      end
    end
  end

  defp read_applied(opts) do
    applied =
      case Keyword.fetch(opts, :applied) do
        {:ok, fun} when is_function(fun, 0) -> MapSet.new(fun.())
        {:ok, versions} -> MapSet.new(versions)
        :error -> applied_versions(Keyword.get(opts, :repo, Barkpark.Repo))
      end

    if MapSet.size(applied) == 0 do
      {:error,
       """
       migration integrity guard read ZERO rows from schema_migrations.

       Either the migrate step this check runs after did not run, or it ran
       against a different database than the one being read. An empty applied
       set can never be evidence that the tree is applied — it is reported here
       as a failure precisely so it cannot be mistaken for one.
       """}
    else
      {:ok, applied}
    end
  rescue
    error ->
      {:error,
       """
       migration integrity guard could not read schema_migrations: #{Exception.message(error)}

       An unreadable applied-version table is a loud failure, not a pass.
       """}
  end

  # -- messages ---------------------------------------------------------------

  defp collision_message(collisions) do
    """
    two or more migration files claim the SAME version — one of them will
    NEVER run, and the migrator will exit 0 without telling you which:

    #{Enum.map_join(collisions, "\n", fn {version, names} -> "  version #{version}: #{Enum.join(Enum.sort(names), ", ")}" end)}

    Ecto keys `schema_migrations` on the integer version, not on the file. Once
    any one of these files is applied, every other file with that version is
    indistinguishable from it and is silently skipped — its `up/0` never runs
    and whatever it was written to create is simply absent.

    Fix: re-stamp the NEW file with a fresh, non-round timestamp
    (`date -u +%Y%m%d%H%M%S`) and rename it. Round-number stamps dated today are
    the collision-prone shape: they are what everyone reaches for by hand.
    """
  end

  defp missing_message(missing, checked) do
    """
    migration version(s) present in the working tree but ABSENT from
    schema_migrations — the migrate step did not apply them:

    #{Enum.map_join(missing, "\n", fn {version, names} -> "  version #{version}: #{Enum.join(Enum.sort(names), ", ")}" end)}

    Checked #{checked} migration version(s) in the tree.

    A migration that did not run cannot be detected by `mix ecto.migrations`
    reporting clean, nor by an exit code: the migrator exits 0 when it believes
    there is nothing to do. Whatever these files were written to create is
    absent from this database, and any guard asserting it exists is now
    measuring something other than the code under test.
    """
  end
end
