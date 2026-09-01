defmodule Barkpark.Content.SchemaSurfaceRuntimeTest do
  @moduledoc false
  # pd-doctrine t7 runtime guard: the per-field `surface` flag is PURE METADATA
  # with no consumer this wave (D1) — which means nothing else would notice if
  # a serializer or seed silently dropped it before sidebar-v2 arrives to read
  # it. These tests pin the full round trip the unit tests can't see:
  #
  #   paper.json → SchemaDefinition.parse → Content.upsert_schema (Postgres)
  #             → Content.serialize_schema_for_sdk (the /api/schemas envelope)
  #
  # plus the demo seed profile: every stored seed field re-parses with only
  # valid surface values (catches a typo like "side-bar" at seed-author time).
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition

  test "paper.json's surface stamps survive upsert and ride the SDK envelope" do
    raw =
      :code.priv_dir(:barkpark)
      |> Path.join("plugins/bulldocs/schemas/paper.json")
      |> File.read!()
      |> Jason.decode!()

    # parse accepts the stamped file, with the audited classification intact
    assert {:ok, parsed} = SchemaDefinition.parse(raw)

    assert Map.new(parsed.fields, &{&1.name, &1.surface}) == %{
             "title" => "body",
             "description" => "sidebar",
             "event_type" => "sidebar",
             "source_doc" => "sidebar",
             "goal_id" => "sidebar",
             "related" => "sidebar",
             "tags" => "sidebar"
           }

    # write path: stored verbatim
    assert {:ok, schema} = Content.upsert_schema(raw, "production")

    # read path: /api/schemas serializer carries it to SDK/CLI consumers
    sdk = Content.serialize_schema_for_sdk(schema)
    sdk_surfaces = Map.new(sdk.fields, &{&1["name"], &1["surface"]})
    assert sdk_surfaces["title"] == "body"
    assert sdk_surfaces["related"] == "sidebar"
  end

  test "every demo seed schema stores fields that re-parse with valid surfaces" do
    # capture_io: the seed profile narrates via IO.puts — keep test output clean
    ExUnit.CaptureIO.capture_io(fn ->
      scope = Barkpark.Seeds.Shared.ensure_default_scope()
      Barkpark.Seeds.Demo.seed(scope)
    end)

    schemas = Barkpark.Repo.all(SchemaDefinition)
    assert schemas != []

    for schema <- schemas do
      parse_result = SchemaDefinition.parse(%{"name" => schema.name, "fields" => schema.fields})

      assert match?({:ok, _}, parse_result),
             "seed schema #{schema.name} failed to parse: #{inspect(parse_result)}"

      {:ok, parsed} = parse_result

      for f <- parsed.fields do
        assert f.surface in [nil, "body", "sidebar"],
               "seed schema #{schema.name} field #{f.name} has invalid surface #{inspect(f.surface)}"
      end
    end
  end
end
