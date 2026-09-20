defmodule Barkpark.Plugins.Github.ReadDoctrineTest do
  @moduledoc """
  The github plugin's read doctrine (`Link`'s moduledoc, amended 2026-09-20) is
  a NAMED ALLOWLIST of raw-`Repo` read shapes, one bullet per file with an
  explicit site count. A doctrine nobody can red is a doctrine that drifts: the
  wording it replaced ("reads and writes go through `Barkpark.Content.*` ONLY")
  sat untrue in this moduledoc for the whole life of the plugin because nothing
  ever compared it to the source.

  This test IS that comparison. It derives the live raw-read site set from the
  plugin source and asserts it equals the table parsed out of `link.ex`. A new
  raw read reds here until its shape is named and justified in the doctrine; a
  read MIGRATED to `Content.*` reds here until the count comes back down. The
  table is therefore a claim under test, not prose.
  """
  use ExUnit.Case, async: true

  @plugin_dir Path.expand("../../../../lib/barkpark/plugins/github", __DIR__)
  @link_ex Path.join(@plugin_dir, "link.ex")

  # A raw READ through `Barkpark.Repo`. Writes are not listed: the doctrine's
  # write half is absolute (every document write goes through `Content.*`), so
  # a write has no allowlist to belong to and this census does not track it.
  @read_verbs ~w(all one get get! get_by get_by! exists? aggregate stream preload)

  defp read_call_regex do
    verbs = Enum.map_join(@read_verbs, "|", &Regex.escape/1)
    Regex.compile!("Repo\\.(?:#{verbs})\\b")
  end

  defp plugin_sources do
    @plugin_dir
    |> Path.join("**/*.ex")
    |> Path.wildcard()
  end

  # The live set: {basename, number of raw-read call sites}, files with none
  # omitted — exactly the shape the doctrine table states.
  defp derived_sites do
    re = read_call_regex()

    plugin_sources()
    |> Enum.map(fn path ->
      {Path.basename(path), length(Regex.scan(re, File.read!(path)))}
    end)
    |> Enum.reject(fn {_name, count} -> count == 0 end)
    |> Map.new()
  end

  # The doctrine's own table, parsed from the moduledoc: every occurrence of
  # `<name>.ex` (N). One bullet names two files, so this scans for the PAIR
  # anywhere in the prose rather than assuming one file per line.
  defp doctrine_sites do
    ~r/`([a-z_]+\.ex)`\s+\((\d+)\)/
    |> Regex.scan(File.read!(@link_ex))
    |> Map.new(fn [_all, name, count] -> {name, String.to_integer(count)} end)
  end

  test "every raw Repo read in the github plugin is named in the link.ex doctrine table" do
    derived = derived_sites()
    doctrine = doctrine_sites()

    unnamed = Map.drop(derived, Map.keys(doctrine))

    assert unnamed == %{},
           """
           A github plugin file runs raw `Repo` reads but is NOT named in the \
           read-doctrine table in link.ex: #{inspect(unnamed)}

           Either migrate the read to a `Barkpark.Content.*` reader (the right \
           answer whenever one fits the shape — see `relations.ex` \
           `load_draft_first/3`, which did exactly that), or add a bullet to \
           the table naming the shape and why no reader expresses it.
           """

    assert derived == doctrine,
           """
           The link.ex read-doctrine table no longer matches the source.

             doctrine says: #{inspect(doctrine)}
             source has:    #{inspect(derived)}

           A count that went UP means a new raw read arrived unnamed. A count \
           that went DOWN means a read was migrated and the doctrine still \
           claims it — shrink the bullet, or drop it.
           """
  end

  test "the doctrine no longer claims reads go through Content.* only" do
    src = File.read!(@link_ex)

    # The retracted wording, quoted so this probes for the CLAIM and not for a
    # sentence that happens to contain the word "reads".
    refute src =~ "Reads\n  and writes go through `Barkpark.Content.*` ONLY"

    # ...and the replacement is actually present, so deleting the table does
    # not silently satisfy the refute above.
    assert src =~ "## The Repo rule, narrowed by shape (amended 2026-09-20)"
    assert src =~ "EVERY WRITE that touches a `content.documents` row goes through"
  end

  test "the census regex is a live instrument, not a constant" do
    # CONTROL. If the derivation could not see a read it would report an empty
    # map and both assertions above would pass vacuously against an empty
    # doctrine table. A file KNOWN to hold raw reads must be seen.
    derived = derived_sites()

    assert Map.get(derived, "health.ex", 0) > 0,
           "the raw-read derivation found nothing in health.ex — the regex or " <>
             "the plugin path is wrong, and the doctrine assertions above are vacuous"

    # And the regex must not match a `Repo.` WRITE verb, or the census would
    # silently conflate the two halves of the doctrine.
    refute Regex.match?(read_call_regex(), "Repo.insert(changeset)")
    refute Regex.match?(read_call_regex(), "Repo.update(changeset)")
    refute Regex.match?(read_call_regex(), "Repo.transaction(fn -> :ok end)")
  end
end
