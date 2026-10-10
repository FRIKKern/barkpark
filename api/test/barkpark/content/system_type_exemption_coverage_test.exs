defmodule Barkpark.Content.SystemTypeExemptionCoverageTest do
  @moduledoc """
  task-3c085ff3fc199ba7 safety pass, made MECHANICAL rather than a one-time
  finding. `Writer.@system_types` (now exposed via `Writer.system_types/0`)
  exempts a small, hand-audited list of Barkpark-internal document types
  from the unknown_type advisory/refusal, because each writes with no
  declared schema BY DESIGN (tag, task, listener, form_submission,
  form_endpoint — see that list's own comment for the full audit).

  A hand list is a SNAPSHOT: the next type a core module or a plugin writes
  with no schema reintroduces exactly the gap this task closed (worst case,
  `bp task` itself refusing every write on an enforcing dataset — found
  live during THIS task's own safety pass). This test re-runs that audit's
  grep as a census on every run: every `create_document`/`upsert_document`
  call site under `api/lib` whose TYPE argument is a literal string or a
  module attribute holding one must resolve to EITHER a real schema seed
  file (`priv/plugins/*/schemas/*.json`) or `Writer.system_types/0` — a
  type in neither is the exact unlisted-exemption gap, failed by name.

  Mirrors `SchemaRedactionCallSiteTripwireTest`'s own shape: a source-level
  regex census asserted as an exact membership check, not a line-numbered
  snapshot, so it survives unrelated edits moving call sites around.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)
  @schemas_glob Path.expand("../../../priv/plugins/*/schemas/*.json", __DIR__)

  # A module attribute definition: `@asset_type "mediaAsset"`.
  @attr_def ~r/@([a-z_][a-zA-Z0-9_]*)\s+"([^"]+)"/

  # A create/upsert call whose first argument is a literal string or an
  # attribute reference. Doesn't try to resolve a call whose type is a
  # runtime variable (`type`, `Contract.submission_type()`, …) — those
  # aren't visible to a static census either way, and the ones that ARE
  # resolvable this way are exactly the ones task-3c085ff3fc199ba7's own
  # audit found and fixed, so this census covers the same ground by
  # construction.
  @literal_call ~r/(?:create_document|upsert_document)\(\s*"([^"]+)"/
  @attr_call ~r/(?:create_document|upsert_document)\(\s*(@[a-z_][a-zA-Z0-9_]*)/

  defp ex_files do
    @lib
    |> Path.join("**/*.ex")
    |> Path.wildcard()
  end

  # type => [source_file, ...] for every statically-resolvable type found at
  # a create_document/upsert_document call site, across the whole lib tree.
  defp written_types do
    for file <- ex_files(), reduce: %{} do
      acc ->
        source = File.read!(file)
        rel = Path.relative_to(file, Path.expand("../../..", __DIR__))

        attrs =
          Regex.scan(@attr_def, source)
          |> Map.new(fn [_, name, value] -> {"@" <> name, value} end)

        literal_types = Regex.scan(@literal_call, source) |> Enum.map(&Enum.at(&1, 1))

        attr_types =
          Regex.scan(@attr_call, source)
          |> Enum.map(&Enum.at(&1, 1))
          |> Enum.map(&Map.get(attrs, &1))
          |> Enum.reject(&is_nil/1)

        (literal_types ++ attr_types)
        |> Enum.uniq()
        |> Enum.reduce(acc, fn type, acc ->
          Map.update(acc, type, [rel], &[rel | &1])
        end)
    end
  end

  defp schema_seeded_types do
    @schemas_glob
    |> Path.wildcard()
    |> Enum.map(fn path ->
      path |> File.read!() |> Jason.decode!() |> Map.fetch!("name")
    end)
    |> MapSet.new()
  end

  test "every statically-found create/upsert type resolves to a real schema seed or Writer.system_types/0" do
    seeded = schema_seeded_types()
    exempt = MapSet.new(Barkpark.Content.Writer.system_types())

    uncovered =
      written_types()
      |> Enum.reject(fn {type, _files} -> type in seeded or type in exempt end)

    assert uncovered == [], """
    #{length(uncovered)} document type(s) write with no registered schema AND no
    Writer.system_types/0 exemption — the exact gap task-3c085ff3fc199ba7 closed,
    reopened by a type this census could not have known about when that list was
    written:

    #{Enum.map_join(uncovered, "\n", fn {type, files} -> "  - #{inspect(type)} (#{Enum.join(Enum.uniq(files), ", ")})" end)}

    Either give the type a real schema (priv/plugins/<plugin>/schemas/<name>.json,
    the normal path), or — only if it is genuinely schemaless by design, the way
    every entry already in Writer.system_types/0 is — add it there with the
    one-line reason the others carry.
    """
  end

  test "the census sees at least the 5 known system types (the derivation itself hasn't gone blind)" do
    found = written_types() |> Map.keys() |> MapSet.new()
    known = MapSet.new(~w(tag listener))

    missing = MapSet.difference(known, found)

    assert MapSet.size(missing) == 0,
           "the census found none of #{inspect(MapSet.to_list(missing))} at a literal/attribute " <>
             "call site — it has gone blind (regex drift), the same way an empty derivation " <>
             "would pass this whole test vacuously"
  end
end
