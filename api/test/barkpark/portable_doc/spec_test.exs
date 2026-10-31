defmodule Barkpark.PortableDoc.SpecTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Barkpark.Content.Papers.Template
  alias Barkpark.PortableDoc.{ComposeCensus, Render, Spec, Tiers}
  alias Barkpark.PortableDoc.Spec.Fields
  alias Mix.Tasks.Barkpark.PortableDoc.GenPdParity

  @host ~r/\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:cloud|com|net|org|io|no|dev|app|local|internal)\b/i
  @ip ~r/\b\d{1,3}(?:\.\d{1,3}){3}\b/

  @holes ~w(
    callout.slots.body card.slots.action card.slots.body card.slots.media[] card.slots.title
    columns.columns[] expandable.blocks expandable.children figure.child list.items[].children
    note.slots.body note.slots.label note.slots.lead section.blocks stage.slots.detail
    stage.slots.kind stage.slots.title steps.steps[].blocks steps.steps[].children
    tabs.tabs[].blocks terminal.blocks terminal.children
  )

  @portable_doc Path.expand("../../../lib/barkpark/portable_doc", __DIR__)
  @compose_source File.read!(Path.join(@portable_doc, "render/compose.ex"))
  @reader_sources Path.wildcard(Path.join(@portable_doc, "render/*.ex")) ++
                    Enum.map(
                      ~w(render.ex slots.ex master_ref.ex task_resolver.ex ../content/sheets.ex),
                      &Path.join(@portable_doc, &1)
                    )

  setup_all do
    schema = Spec.schema()

    strict =
      update_in(schema, ["definitions", "blocks"], fn blocks ->
        Map.new(blocks, fn {type, block} ->
          {type, Map.put(block, "additionalProperties", false)}
        end)
      end)

    %{
      schema: schema,
      root: ExJsonSchema.Schema.resolve(schema),
      strict: ExJsonSchema.Schema.resolve(strict)
    }
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

    test "names no URL, host or IP address but json-schema.org" do
      json = Spec.json()
      urls = Regex.scan(~r{[a-z]+://[^"\s]+}, json) |> List.flatten() |> Enum.uniq()
      assert urls == ["http://json-schema.org/draft-07/schema#"]

      hosts =
        Regex.scan(@host, json)
        |> List.flatten()
        |> Enum.uniq()

      assert hosts == ["json-schema.org"]
      assert Regex.scan(@ip, json) == []
    end

    test "the host scan sees a bare hostname and an IP address" do
      assert Regex.match?(@host, "at guerrilla.barkpark.cloud now")
      assert Regex.match?(@ip, "box 157.180.90.121 here")
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

      spec =
        Map.new(schema["definitions"]["aliases"], fn {spelling, block} ->
          {spelling, {block["x-alias-of"], block["x-set"] |> Map.keys() |> Enum.sort()}}
        end)

      assert spec == reader
    end

    test "an alias renders as its target with x-set applied over the stored fields", %{
      schema: schema
    } do
      for {spelling, %{"x-alias-of" => target, "x-set" => set}} <-
            schema["definitions"]["aliases"] do
        stored =
          Map.merge(GenPdParity.input(target), Map.new(set, fn {k, v} -> {k, other(v)} end))

        as_alias = render(Map.put(stored, "type", spelling))

        assert as_alias == render(Map.merge(stored, set)), spelling

        if set != %{} do
          assert as_alias != render(stored),
                 "#{spelling}: x-set changes nothing, so it pins nothing"
        end
      end
    end

    test "the census reads aliases only off clauses that rewrite the type" do
      source = """
      defmodule Fixture do
        @spellings ~w(h4 h5)
        @overlay ~w(tasks)
        def compose_block(%{"type" => "heading"} = b, style), do: {b, style}
        def compose_block(%{"type" => t} = b, style) when t in @spellings,
          do: compose_block(b |> Map.put("type", "heading") |> Map.put("level", 4), style)
        def compose_block(%{"type" => t} = b, style) when t == "title",
          do: compose_block(Map.put(b, "type", "heading"), style)
        def compose_block(%{"type" => t, "unavailable" => true} = b, style) when t in @overlay,
          do: {b, style}
      end
      """

      assert ComposeCensus.types(source) == ["heading"]

      assert ComposeCensus.aliases(source) == %{
               "h4" => {"heading", ["level"]},
               "h5" => {"heading", ["level"]},
               "title" => {"heading", []}
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

    test "every field the pd-parity corpus uses is declared on its block", %{strict: strict} do
      for type <- GenPdParity.types() do
        assert ExJsonSchema.Validator.validate(strict, GenPdParity.input(type)) == :ok, type
      end
    end

    test "an alias spelling validates as its target, with forced fields free", %{root: root} do
      assert ExJsonSchema.Validator.validate(root, %{"type" => "h2", "text" => "Two"}) == :ok
      assert ExJsonSchema.Validator.validate(root, %{"type" => "h2", "level" => "two"}) == :ok
      assert {:error, _} = ExJsonSchema.Validator.validate(root, %{"type" => "h2", "text" => 2})
    end

    test "every nested-block slot checks its child", %{root: root} do
      holes =
        for {type, own} <- Fields.all(),
            {field, shape} <- own,
            {path, hole} <- holes(shape, field),
            do: {type, path, hole}

      assert holes |> Enum.map(fn {type, path, _} -> "#{type}.#{path}" end) |> Enum.sort() ==
               @holes

      for {type, path, hole} <- holes do
        at = "#{type}.#{path}"
        field = path |> String.split([".", "["]) |> hd()
        good = %{"type" => type, field => hole.(%{"type" => "divider"})}
        bad = %{"type" => type, field => hole.(%{"type" => "hologram"})}
        assert ExJsonSchema.Validator.validate(root, good) == :ok, at
        assert match?({:error, _}, ExJsonSchema.Validator.validate(root, bad)), at
      end
    end

    test "a typeless card media element is an image without a type", %{root: root} do
      card = fn media -> %{"type" => "card", "slots" => %{"media" => [media]}} end

      assert ExJsonSchema.Validator.validate(root, card.(%{"src" => "a.png", "alt" => "A"})) ==
               :ok

      assert {:error, _} = ExJsonSchema.Validator.validate(root, card.(%{"src" => 5}))
    end

    test "fields the reader takes in more than one shape", %{strict: root} do
      ok = fn block ->
        assert ExJsonSchema.Validator.validate(root, block) == :ok, inspect(block)
      end

      bad = fn block ->
        assert match?({:error, _}, ExJsonSchema.Validator.validate(root, block)), inspect(block)
      end

      ok.(%{"type" => "heading", "level" => "6"})
      ok.(%{"type" => "heading", "level" => 1})
      bad.(%{"type" => "heading", "level" => 99})
      bad.(%{"type" => "heading", "level" => "7"})
      ok.(%{"type" => "code", "code" => "x = 1"})
      ok.(%{"type" => "code", "content" => [%{"type" => "text", "value" => "x"}]})
      ok.(%{"type" => "image", "width" => "640"})

      ok.(%{
        "type" => "list",
        "items" => [
          "plain",
          [%{"type" => "text", "value" => "x"}],
          %{"text" => "t", "checked" => true}
        ]
      })
    end

    test "the common id, role and locked fields are typed", %{root: root} do
      ok = %{"type" => "divider", "id" => "b1", "role" => "rule", "locked" => true}
      assert ExJsonSchema.Validator.validate(root, ok) == :ok

      for {k, v} <- [{"id", 1}, {"role", 2}, {"locked", "yes"}] do
        assert match?({:error, _}, ExJsonSchema.Validator.validate(root, Map.put(ok, k, v))), k
      end
    end

    test "a type with no tier refuses to generate" do
      assert_raise ArgumentError, ~r/hologram has no tier/, fn ->
        Spec.schema(%{"hologram" => %{}}, %{})
      end
    end

    test "an unknown type, a missing type and a wrong field type fail", %{root: root} do
      assert {:error, _} = ExJsonSchema.Validator.validate(root, %{"type" => "hologram"})
      assert {:error, _} = ExJsonSchema.Validator.validate(root, %{"text" => "no type"})

      assert {:error, _} =
               ExJsonSchema.Validator.validate(root, %{"type" => "heading", "level" => "two"})

      nested = %{"type" => "section", "blocks" => [%{"type" => "heading", "level" => "two"}]}
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

      two_key_count = Map.put(wire(good), "count", %{"min" => 1, "max" => 2})
      assert {:error, _} = ExJsonSchema.Validator.validate(root, two_key_count)
    end
  end

  defp holes(:block, path), do: [{path, & &1}]
  defp holes(:blocks, path), do: [{path, &[&1]}]

  defp holes({:array, shape}, path),
    do: for({p, h} <- holes(shape, path <> "[]"), do: {p, fn c -> [h.(c)] end})

  defp holes({:object, own}, path) do
    for {k, shape} <- own,
        {p, h} <- holes(shape, "#{path}.#{k}"),
        do: {p, fn c -> %{k => h.(c)} end}
  end

  defp holes({:any_of, shapes}, path), do: Enum.flat_map(shapes, &holes(&1, path))
  defp holes(_shape, _path), do: []

  defp render(block), do: Render.render_block(block, %{style: :article})

  defp other(v) when is_boolean(v), do: not v
  defp other(v) when is_integer(v), do: rem(v, 6) + 1

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
