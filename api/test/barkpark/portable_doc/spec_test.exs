defmodule Barkpark.PortableDoc.SpecTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Barkpark.Content.Papers.Template
  alias Barkpark.PortableDoc.{ComposeCensus, Spec, Tiers}
  alias Mix.Tasks.Barkpark.PortableDoc.GenPdParity

  @portable_doc Path.expand("../../../lib/barkpark/portable_doc", __DIR__)
  @compose_source File.read!(Path.join(@portable_doc, "render/compose.ex"))
  @reader_sources Path.wildcard(Path.join(@portable_doc, "render/*.ex")) ++
                    Enum.map(
                      ~w(render.ex slots.ex master_ref.ex task_resolver.ex ../content/sheets.ex),
                      &Path.join(@portable_doc, &1)
                    )

  setup_all do
    schema = Spec.schema()
    %{schema: schema, root: ExJsonSchema.Schema.resolve(schema)}
  end

  describe "the generated file" do
    test "the committed blocks.schema.json is what gen_spec writes" do
      assert File.read!(Spec.path()) == Spec.json(),
             "blocks.schema.json is stale — run `mix barkpark.portable_doc.gen_spec`"
    end

    @tag :tmp_dir
    test "two runs of the task write identical bytes", %{tmp_dir: tmp_dir} do
      [a, b] =
        for name <- ["a.json", "b.json"] do
          out = Path.join(tmp_dir, name)
          capture_io(fn -> Mix.Tasks.Barkpark.PortableDoc.GenSpec.run(["--out", out]) end)
          File.read!(out)
        end

      assert a == b
      assert a == File.read!(Spec.path())
    end

    test "every object's keys are sorted" do
      decoded = Jason.decode!(Spec.json(), objects: :ordered_objects)
      unsorted = unsorted_objects(decoded, "#")
      assert unsorted == [], "objects with unsorted keys: #{inspect(unsorted)}"
    end

    test "names no host but json-schema.org" do
      urls = Regex.scan(~r{[a-z]+://[^"\s]+}, Spec.json()) |> List.flatten() |> Enum.uniq()
      assert urls == ["http://json-schema.org/draft-07/schema#"]
    end
  end

  describe "the schema and the reader agree on the block types" do
    test "every type the reader renders is in the schema, and no other", %{schema: schema} do
      reader = MapSet.new(ComposeCensus.types(@compose_source))
      spec = schema["definitions"]["blocks"] |> Map.keys() |> MapSet.new()

      assert MapSet.size(reader) > 30,
             "the census read #{MapSet.size(reader)} types — compose.ex moved?"

      assert MapSet.difference(reader, spec) |> Enum.sort() == [],
             "rendered by compose.ex but missing from the schema — add them to Spec.Fields"

      assert MapSet.difference(spec, reader) |> Enum.sort() == [],
             "in the schema but compose.ex does not render them"
    end

    test "the aliases are the spellings compose.ex rewrites, with the same targets", %{
      schema: schema
    } do
      reader = ComposeCensus.aliases(@compose_source)
      assert map_size(reader) > 0
      assert schema["x-aliases"] == reader
      assert Enum.all?(Map.values(reader), &Map.has_key?(schema["definitions"]["blocks"], &1))
    end

    test "the census reads aliases only off clauses that rewrite the type" do
      source = """
      defmodule Fixture do
        @spellings ~w(h4 h5)
        @overlay ~w(tasks)
        def compose_block(%{"type" => "heading"} = b, style), do: {b, style}
        def compose_block(%{"type" => t} = b, style) when t in @spellings,
          do: compose_block(b |> Map.put("type", "heading"), style)
        def compose_block(%{"type" => t} = b, style) when t == "title",
          do: compose_block(Map.put(b, "type", "heading"), style)
        def compose_block(%{"type" => t, "unavailable" => true} = b, style) when t in @overlay,
          do: {b, style}
      end
      """

      assert ComposeCensus.types(source) == ["heading"]

      assert ComposeCensus.aliases(source) == %{
               "h4" => "heading",
               "h5" => "heading",
               "title" => "heading"
             }
    end

    test "each block carries its Tiers tier", %{schema: schema} do
      for {type, block} <- schema["definitions"]["blocks"] do
        assert block["x-tier"] == Atom.to_string(Tiers.tier_of(type)), type
      end
    end

    test "the tier vocabulary is Tiers'", %{schema: schema} do
      tiers = schema["definitions"]["constraints"]["tier"]["enum"]

      assert Enum.sort(tiers) ==
               Tiers.by_tier() |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    end

    test "every declared field is a key the reader names", %{schema: schema} do
      literals =
        Enum.reduce(@reader_sources, MapSet.new(), &MapSet.union(&2, string_literals(&1)))

      unknown =
        for {type, block} <- schema["definitions"]["blocks"],
            field <- Map.keys(block["properties"]) -- ["id", "locked", "role", "type"],
            not MapSet.member?(literals, field),
            do: "#{type}.#{field}"

      assert unknown == [], "fields no reader source names: #{inspect(unknown)}"
    end
  end

  describe "validation" do
    test "every block in the pd-parity corpus validates", %{root: root} do
      for type <- GenPdParity.types() do
        assert ExJsonSchema.Validator.validate(root, GenPdParity.input(type)) == :ok, type
      end
    end

    test "every field the pd-parity corpus uses is declared on its block", %{schema: schema} do
      strict =
        update_in(schema, ["definitions", "blocks"], fn blocks ->
          Map.new(blocks, fn {type, block} ->
            {type, Map.put(block, "additionalProperties", false)}
          end)
        end)
        |> ExJsonSchema.Schema.resolve()

      for type <- GenPdParity.types() do
        assert ExJsonSchema.Validator.validate(strict, GenPdParity.input(type)) == :ok, type
      end
    end

    test "an alias spelling validates as its target", %{root: root} do
      assert ExJsonSchema.Validator.validate(root, %{"type" => "h2", "text" => "Two"}) == :ok

      assert {:error, _} =
               ExJsonSchema.Validator.validate(root, %{"type" => "h2", "level" => "two"})
    end

    test "an unknown type, a missing type and a wrong field type fail", %{root: root} do
      assert {:error, _} = ExJsonSchema.Validator.validate(root, %{"type" => "hologram"})
      assert {:error, _} = ExJsonSchema.Validator.validate(root, %{"text" => "no type"})

      assert {:error, _} =
               ExJsonSchema.Validator.validate(root, %{"type" => "heading", "level" => "two"})

      nested = %{"type" => "section", "blocks" => [%{"type" => "image", "width" => "wide"}]}
      assert {:error, _} = ExJsonSchema.Validator.validate(root, nested)
    end
  end

  describe "the constraint vocabulary" do
    test "the paper template's declarations validate", %{schema: schema} do
      root = declaration_root(schema)

      for decl <- Template.paper_declarations() do
        assert ExJsonSchema.Validator.validate(root, wire(decl)) == :ok, inspect(decl)
      end
    end

    test "a tier kind and the type of the same name stay apart", %{schema: schema} do
      assert schema["definitions"]["blocks"]["section"]["x-tier"] == "section"

      root = declaration_root(schema)

      decl = %{
        kind: "section",
        presence: :optional,
        count: {:max, 1},
        position: [:free],
        locked: false
      }

      assert ExJsonSchema.Validator.validate(root, wire(decl)) == :ok
      assert wire(%{decl | kind: :section})["kind"] == %{"tier" => "section"}
      assert ExJsonSchema.Validator.validate(root, wire(%{decl | kind: :section})) == :ok

      assert {:error, _} =
               ExJsonSchema.Validator.validate(root, %{
                 wire(decl)
                 | "kind" => %{"tier" => "sections"}
               })
    end

    test "every position form, a tier kind and the bad forms", %{schema: schema} do
      root = declaration_root(schema)

      good = %{
        kind: :widget,
        presence: :optional,
        count: {:max, 0},
        position: [
          {:index, 0},
          {:not_index, 1},
          :top_group,
          :bottom_group,
          :free,
          {:before, :section}
        ],
        locked: false
      }

      assert ExJsonSchema.Validator.validate(root, wire(good)) == :ok

      for bad <- [
            %{good | presence: :maybe},
            %{good | count: {:exactly, -1}},
            %{good | count: {:around, 2}},
            %{good | position: [:middle]},
            Map.delete(good, :locked)
          ] do
        assert match?({:error, _}, ExJsonSchema.Validator.validate(root, wire(bad))), inspect(bad)
      end
    end
  end

  defp declaration_root(schema) do
    schema
    |> Map.put("$ref", "#/definitions/constraints/declaration")
    |> Map.drop(["allOf", "properties", "required", "type"])
    |> ExJsonSchema.Schema.resolve()
  end

  defp wire(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), wire(v)} end)
  defp wire({tag, value}) when is_atom(tag), do: %{Atom.to_string(tag) => wire(value)}

  defp wire(tier) when tier in [:element, :widget, :section],
    do: %{"tier" => Atom.to_string(tier)}

  defp wire(list) when is_list(list), do: Enum.map(list, &wire/1)
  defp wire(atom) when is_atom(atom) and not is_boolean(atom), do: Atom.to_string(atom)
  defp wire(value), do: value

  defp string_literals(path) do
    {_, acc} =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk(MapSet.new(), fn
        literal, acc when is_binary(literal) -> {literal, MapSet.put(acc, literal)}
        node, acc -> {node, acc}
      end)

    acc
  end

  defp unsorted_objects(%Jason.OrderedObject{values: values}, at) do
    keys = Enum.map(values, &elem(&1, 0))
    here = if keys == Enum.sort(keys), do: [], else: [at]
    here ++ Enum.flat_map(values, fn {k, v} -> unsorted_objects(v, at <> "/" <> k) end)
  end

  defp unsorted_objects(list, at) when is_list(list),
    do:
      list
      |> Enum.with_index()
      |> Enum.flat_map(fn {v, i} -> unsorted_objects(v, "#{at}/#{i}") end)

  defp unsorted_objects(_value, _at), do: []
end
