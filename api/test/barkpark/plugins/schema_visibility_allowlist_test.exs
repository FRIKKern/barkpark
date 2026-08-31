defmodule Barkpark.Plugins.SchemaVisibilityAllowlistTest do
  @moduledoc """
  The plugin-schema visibility ALLOWLIST, guarded at the file level.

  `Content.schema_public?/3` and the anonymous read paths treat `visibility`
  as an allowlist: a type is public only when it EXPLICITLY says
  `"public"`. The ruling is recorded at
  `Barkpark.Plugins.Indx.IndexerWorker` `schema_public?/1` — "a nil/unknown/
  future visibility value fails CLOSED everywhere instead of indexing here
  while 404ing there".

  Every plugin loader now spells the closed default, but a default is only
  the second line of defence: the FIRST is that a registered schema JSON
  says what it means. Bulldocs leans on exactly that — its `session` type
  carries cwd, hostname, git branch/HEAD and a transcript ref, and
  `bulldocs.ex` documents the private visibility as the sole gate ("Every
  read of a session therefore costs a token"). A dropped key in
  `session.json` would have silently registered it PUBLIC, and nothing in
  the suite would have noticed.

  This test is the missing tripwire. It scans the schema JSON of every
  plugin the registry can actually discover, and requires an explicit,
  valid `visibility` on each type that is registered top-level.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Registry.Discovery

  @valid ~w(public private)

  # The registered top-level type names, taken from the plugins the registry
  # itself discovers — NOT a hand-maintained list, so a new plugin is covered
  # the day it lands. Sub-schemas that are only SPLICED into a parent (the
  # OnixEdit `contributor` / `text_content` composites) never appear in any
  # `register_schemas/1` result and are therefore out of scope by
  # construction rather than by a skip-list that would rot.
  defp registered_names do
    Discovery.default_paths()
    |> Enum.flat_map(&Discovery.plugin_dirs_in/1)
    |> Enum.flat_map(fn dir ->
      case dir |> Path.join("plugin.json") |> File.read() do
        {:ok, raw} -> [Jason.decode!(raw)]
        _ -> []
      end
    end)
    |> Enum.flat_map(fn manifest ->
      case Discovery.resolve_module(manifest) do
        {:ok, mod} -> [mod]
        _ -> []
      end
    end)
    |> Enum.filter(&function_exported?(&1, :register_schemas, 1))
    |> Enum.flat_map(& &1.register_schemas(dataset: "production"))
    |> MapSet.new(& &1.name)
  end

  defp schema_json_files do
    Discovery.default_paths()
    |> Enum.flat_map(&Discovery.plugin_dirs_in/1)
    |> Enum.flat_map(fn dir -> dir |> Path.join("schemas/*.json") |> Path.wildcard() end)
  end

  test "every registered plugin schema declares an explicit, valid visibility" do
    names = registered_names()

    # A floor, so a discovery regression cannot quietly empty this test:
    # zero registered names would make the scan below vacuous.
    assert MapSet.size(names) > 0,
           "no plugin schemas were discovered — this test would pass vacuously"

    offenders =
      for file <- schema_json_files(),
          raw = file |> File.read!() |> Jason.decode!(),
          name = Map.get(raw, "name"),
          MapSet.member?(names, name),
          Map.get(raw, "visibility") not in @valid,
          do: {Path.basename(file), name, Map.get(raw, "visibility")}

    assert offenders == [], """
    These registered plugin schemas do not declare an explicit
    `"visibility": "public" | "private"`:

    #{Enum.map_join(offenders, "\n", fn {f, n, v} -> "  * #{f} (type #{n}) — got #{inspect(v)}" end)}

    Visibility is an ALLOWLIST: the loaders default an omitted key to
    "private", so an omission does not leak — but it also does not say what
    the author meant, and a type that MEANT to be public will silently 404
    instead. Declare it in the JSON.
    """
  end

  # Proves the scan above actually reaches the file that matters, rather than
  # passing because it matched nothing. Without this, deleting the whole
  # `schema_json_files/0` body would keep the test green.
  test "the scan reaches the private Bulldocs types the gate depends on" do
    scanned =
      schema_json_files()
      |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))
      |> Map.new(&{Map.get(&1, "name"), Map.get(&1, "visibility")})

    assert Map.get(scanned, "session") == "private"
    assert Map.get(scanned, "form_response") == "private"
    assert Map.get(scanned, "paper") == "public"
  end
end
