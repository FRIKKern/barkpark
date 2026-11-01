defmodule Barkpark.PortableDoc.ValidateTest do
  @moduledoc """
  `Barkpark.PortableDoc.Validate` against `@portable-doc/validate`: the vendored
  `fixtures/broken` docs are refused with exactly their expected codes and
  paths, `fixtures/valid` and the golden pack pass, and the walk follows the
  JS rules for order, depth and schema keywords. Expected lists marked "JS"
  were printed by portable-doc's `packages/validate/index.js` at the SOURCE
  commit.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Validate
  alias Barkpark.PortableDoc.Validate.Schema

  @fixtures Path.expand("../../support/fixtures/portable-doc-validate", __DIR__)
  @goldens Path.expand("../../../priv/portable_doc/goldens", __DIR__)
  @max Validate.max_depth()

  defp read(path), do: path |> File.read!() |> Jason.decode!()
  defp json_in(dir), do: dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()

  defp broken do
    for file <- json_in(Path.join(@fixtures, "broken")), do: {Path.basename(file), read(file)}
  end

  defp pairs({:error, errors}), do: Enum.map(errors, &{Atom.to_string(&1.code), &1.path})
  defp pairs(:ok), do: []

  defp sorted(pairs), do: Enum.sort_by(pairs, fn {code, path} -> "#{path} #{code}" end)

  describe "vendored fixtures" do
    test "match the SOURCE commit's blobs byte for byte, file for file" do
      source = File.read!(Path.join(@fixtures, "SOURCE"))
      assert source =~ ~r/\AFRIKKern\/portable-doc [0-9a-f]{40}\n/

      pinned =
        for [_, sha, path] <-
              Regex.scan(~r/^100644 blob ([0-9a-f]{40})\tfixtures\/(\S+)$/m, source),
            into: %{},
            do: {path, sha}

      vendored =
        for file <-
              json_in(Path.join(@fixtures, "broken")) ++ json_in(Path.join(@fixtures, "valid")),
            into: %{} do
          bytes = File.read!(file)

          sha =
            :crypto.hash(:sha, "blob #{byte_size(bytes)}\0" <> bytes)
            |> Base.encode16(case: :lower)

          {Path.relative_to(file, @fixtures), sha}
        end

      assert map_size(pinned) == 41
      assert vendored == pinned
    end

    test "every code has a broken fixture and every fixture names a known code" do
      used =
        broken()
        |> Enum.flat_map(fn {_, f} -> Enum.map(f["expect"], & &1["code"]) end)
        |> MapSet.new()

      codes = Validate.codes() |> Enum.map(&Atom.to_string/1) |> MapSet.new()
      assert used == codes
    end
  end

  for file <-
        Path.wildcard(
          Path.expand("../../support/fixtures/portable-doc-validate/broken/*.json", __DIR__)
        ) do
    @file_name Path.basename(file)
    test "broken/#{@file_name} is refused with exactly its expected codes and paths" do
      %{"doc" => doc, "expect" => expect} = read(Path.join([@fixtures, "broken", @file_name]))
      result = Validate.validate(doc)
      assert {:error, [_ | _]} = result
      assert sorted(pairs(result)) == sorted(Enum.map(expect, &{&1["code"], &1["path"]}))
    end
  end

  test "every valid fixture passes" do
    files = json_in(Path.join(@fixtures, "valid"))
    assert length(files) == 8
    for file <- files, do: assert({file, Validate.validate(read(file))} == {file, :ok})
  end

  test "every block golden input passes as a one-block doc" do
    files = json_in(Path.join(@goldens, "blocks"))
    assert length(files) >= 80

    for file <- files,
        do: assert({file, Validate.validate(%{"blocks" => [read(file)["input"]]})} == {file, :ok})
  end

  test "the nested-list golden and every ops golden doc pass" do
    assert Validate.validate(read(Path.join(@goldens, "nested-list-carriers.json"))) == :ok
    ops = json_in(Path.join(@goldens, "ops"))
    assert ops != []

    for file <- ops, side <- ~w(before after) do
      assert {file, side, Validate.validate(read(file)[side])} == {file, side, :ok}
    end
  end

  test "every type the schema names passes as a bare block" do
    types = read(Barkpark.PortableDoc.Spec.path())["properties"]["type"]["enum"]
    assert length(types) >= 80

    for type <- types,
        do: assert({type, Validate.validate(%{"blocks" => [%{"type" => type}]})} == {type, :ok})
  end

  describe "order" do
    test "errors come out in the JS walk order: schema property order, then duplicates" do
      doc = %{
        "blocks" => [
          %{
            "id" => "a",
            "type" => "heading",
            "level" => 9,
            "text" => 5,
            "content" => [%{}, %{"type" => 1}]
          },
          %{"id" => "a", "type" => "nope"},
          "x",
          %{"type" => "list", "items" => 5},
          %{
            "type" => "card",
            "slots" => %{"media" => [%{"id" => "a", "type" => "image", "src" => 1}, 7]}
          }
        ]
      }

      assert pairs(Validate.validate(doc)) == [
               {"missing_required_field", "/blocks/0/content/0/type"},
               {"wrong_field_type", "/blocks/0/content/1/type"},
               {"value_not_allowed", "/blocks/0/level"},
               {"wrong_field_type", "/blocks/0/text"},
               {"unknown_block_type", "/blocks/1/type"},
               {"block_not_object", "/blocks/2"},
               {"wrong_field_type", "/blocks/3/items"},
               {"wrong_field_type", "/blocks/4/slots/media/0/src"},
               {"wrong_field_type", "/blocks/4/slots/media/1"},
               {"duplicate_block_id", "/blocks/1/id"},
               {"duplicate_block_id", "/blocks/4/slots/media/0/id"}
             ]
    end

    test "a float with no fraction is an integer, as JSON.parse reads it" do
      levels = [2.0, 1.5, "7", nil]
      doc = %{"blocks" => Enum.map(levels, &%{"type" => "heading", "level" => &1})}

      assert pairs(Validate.validate(doc)) == [
               {"wrong_field_type", "/blocks/1/level"},
               {"value_not_allowed", "/blocks/2/level"},
               {"wrong_field_type", "/blocks/3/level"}
             ]
    end
  end

  describe "not_a_doc" do
    test "the envelope is checked before any block" do
      assert pairs(Validate.validate("doc")) == [{"not_a_doc", ""}]
      assert pairs(Validate.validate(nil)) == [{"not_a_doc", ""}]
      assert pairs(Validate.validate(%{})) == [{"not_a_doc", "/blocks"}]
      assert pairs(Validate.validate(%{"blocks" => %{}})) == [{"not_a_doc", "/blocks"}]
      assert Validate.validate([]) == :ok
      assert Validate.validate(%{"blocks" => []}) == :ok
    end
  end

  describe "Portable Text" do
    test "is refused in inline content too" do
      pt = %{"_type" => "block", "children" => [%{"_type" => "span", "text" => "Pasted."}]}

      doc = %{
        "blocks" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "Fine."}, pt]}
        ]
      }

      assert pairs(Validate.validate(doc)) == [{"portable_text_block", "/blocks/0/content/1"}]
    end

    test "each signature key alone makes one; _type alone does not" do
      for key <- ~w(children markDefs listItem) do
        assert Validate.portable_text_block?(%{"_type" => "block", key => []})
      end

      refute Validate.portable_text_block?(%{"_type" => "block", "text" => "x"})
      refute Validate.portable_text_block?(%{"_type" => "span", "children" => []})
      refute Validate.portable_text_block?("block")
    end
  end

  describe "duplicate ids" do
    defp paragraph(id), do: %{"id" => id, "type" => "paragraph", "text" => id}

    test "ids inside list item children and card media count, though BlockIds skips them" do
      list = %{"type" => "list", "items" => [%{"text" => "item", "children" => [paragraph("x")]}]}

      assert pairs(Validate.validate(%{"blocks" => [paragraph("x"), list]})) == [
               {"duplicate_block_id", "/blocks/1/items/0/children/0/id"}
             ]

      card = fn src ->
        %{
          "type" => "card",
          "slots" => %{"media" => [%{"id" => "x", "type" => "image", "src" => src}]}
        }
      end

      assert pairs(Validate.validate(%{"blocks" => [paragraph("x"), card.("a.png")]})) == [
               {"duplicate_block_id", "/blocks/1/slots/media/0/id"}
             ]

      assert pairs(Validate.validate(%{"blocks" => [paragraph("x"), card.(5)]})) == [
               {"wrong_field_type", "/blocks/1/slots/media/0/src"},
               {"duplicate_block_id", "/blocks/1/slots/media/0/id"}
             ]
    end

    test "a blank id never counts, and three of one id give two errors" do
      assert Validate.validate(%{"blocks" => [paragraph(""), paragraph("")]}) == :ok

      assert pairs(
               Validate.validate(%{"blocks" => [paragraph("y"), paragraph("y"), paragraph("y")]})
             ) == [
               {"duplicate_block_id", "/blocks/1/id"},
               {"duplicate_block_id", "/blocks/2/id"}
             ]
    end
  end

  describe "depth" do
    defp nest(depth, wrap) do
      block =
        Enum.reduce(2..depth//1, %{"type" => "paragraph", "text" => "Deep."}, fn _, b ->
          wrap.(b)
        end)

      %{"blocks" => [block]}
    end

    defp section(b), do: %{"type" => "section", "blocks" => [b]}

    defp under(inner), do: Enum.reduce(1..@max, inner, fn _, b -> section(b) end)

    @wraps %{
      "section" => &__MODULE__.wrap_section/1,
      "list children" => &__MODULE__.wrap_list/1,
      "figure child" => &__MODULE__.wrap_figure/1,
      "card media" => &__MODULE__.wrap_card/1
    }

    def wrap_section(b), do: section(b)
    def wrap_list(b), do: %{"type" => "list", "items" => [%{"text" => "item", "children" => [b]}]}
    def wrap_figure(b), do: %{"type" => "figure", "child" => b}
    def wrap_card(b), do: %{"type" => "card", "slots" => %{"media" => [b]}}

    for name <- Map.keys(@wraps) do
      @name name
      test "#{name}: #{@max} levels pass, #{@max + 1} and 5000 are too_deep" do
        wrap = @wraps[@name]
        assert Validate.validate(nest(@max, wrap)) == :ok

        for depth <- [@max + 1, 5000] do
          assert {:error, [%{code: :too_deep}]} = Validate.validate(nest(depth, wrap))
        end
      end
    end

    test "too_deep points at the block at level #{@max + 1}" do
      {:error, [%{path: path}]} = Validate.validate(nest(@max + 1, &section/1))
      assert path == "/blocks/0" <> String.duplicate("/blocks/0", @max)
    end

    test "past max depth a block gets only too_deep: not block_not_object, and its id does not count" do
      assert pairs(Validate.validate(%{"blocks" => [under(7)]})) |> Enum.map(&elem(&1, 0)) == [
               "too_deep"
             ]

      doc = %{"blocks" => [paragraph("x"), under(%{"id" => "x", "type" => "paragraph"})]}
      assert pairs(Validate.validate(doc)) |> Enum.map(&elem(&1, 0)) == ["too_deep"]
    end

    test "a Portable Text block at level #{@max + 1} gets portable_text_block, not too_deep (JS)" do
      pt = %{"_type" => "block", "children" => []}
      deep = "/blocks/0" <> String.duplicate("/blocks/0", @max)

      assert pairs(Validate.validate(%{"blocks" => [under(pt)]})) == [
               {"portable_text_block", deep}
             ]

      assert pairs(Validate.validate(%{"blocks" => [under(section(pt))]})) == [{"too_deep", deep}]
    end
  end

  @tiny %{
    "type" => "object",
    "required" => ["type"],
    "properties" => %{"type" => %{"enum" => ["note", "pair"]}, "id" => %{"type" => "string"}},
    "allOf" => [
      %{
        "if" => %{"properties" => %{"type" => %{"const" => "note"}}, "required" => ["type"]},
        "then" => %{"$ref" => "#/definitions/blocks/note"}
      },
      %{
        "if" => %{"properties" => %{"type" => %{"const" => "pair"}}, "required" => ["type"]},
        "then" => %{"$ref" => "#/definitions/blocks/pair"}
      }
    ],
    "definitions" => %{
      "blocks" => %{
        "note" => %{
          "x-tier" => "element",
          "properties" => %{
            "text" => %{"type" => "string"},
            "size" => %{"type" => "integer", "minimum" => 1, "maximum" => 3},
            "kind" => %{"const" => "plain"},
            "tag" => %{"not" => %{"type" => "string"}},
            "body" => %{"type" => "array", "items" => %{"$ref" => "#"}},
            "ref" => %{
              "anyOf" => [
                %{"type" => "string"},
                %{
                  "type" => "object",
                  "required" => ["a"],
                  "properties" => %{"a" => %{"type" => "string"}, "b" => %{"type" => "string"}}
                }
              ]
            },
            "either" => %{
              "anyOf" => [
                %{"type" => "string"},
                %{"required" => ["a"]},
                %{"type" => "object", "required" => ["c"]}
              ]
            },
            "media" => %{
              "type" => "array",
              "items" => %{"anyOf" => [%{"$ref" => "#"}, %{"type" => "string"}]}
            }
          }
        },
        "pair" => %{"properties" => %{"left" => %{"$ref" => "#"}, "right" => %{"$ref" => "#"}}}
      },
      "constraints" => %{"additionalProperties" => false}
    }
  }

  describe "compile" do
    test "follows the schema it is given, keyword by keyword" do
      schema = Schema.compile(@tiny)

      codes = fn blocks ->
        %{"blocks" => blocks}
        |> Validate.validate(schema)
        |> pairs()
        |> Enum.map(fn {c, p} -> "#{c} #{p}" end)
      end

      assert codes.([
               %{
                 "type" => "note",
                 "text" => "ok",
                 "size" => 2,
                 "kind" => "plain",
                 "tag" => 1,
                 "ref" => "x"
               }
             ]) == []

      assert codes.([%{"type" => "paragraph"}]) == ["unknown_block_type /blocks/0/type"]
      assert codes.([%{"type" => "note", "size" => 4}]) == ["value_not_allowed /blocks/0/size"]
      assert codes.([%{"type" => "note", "size" => 0}]) == ["value_not_allowed /blocks/0/size"]
      assert codes.([%{"type" => "note", "size" => 1.5}]) == ["wrong_field_type /blocks/0/size"]

      assert codes.([%{"type" => "note", "kind" => "fancy"}]) == [
               "value_not_allowed /blocks/0/kind"
             ]

      assert codes.([%{"type" => "note", "tag" => "no"}]) == ["value_not_allowed /blocks/0/tag"]

      assert codes.([%{"type" => "note", "ref" => %{"b" => 1}}]) == [
               "missing_required_field /blocks/0/ref/a",
               "wrong_field_type /blocks/0/ref/b"
             ]

      assert codes.([%{"type" => "note", "ref" => 3}]) == ["wrong_field_type /blocks/0/ref"]

      assert codes.([%{"type" => "note", "either" => %{"b" => 1}}]) == [
               "missing_required_field /blocks/0/either/a"
             ]

      assert codes.([%{"type" => "note", "media" => ["ok", 5]}]) == [
               "wrong_field_type /blocks/0/media/1"
             ]

      assert codes.([%{"type" => "note", "body" => [%{"type" => "note", "text" => 1}]}]) == [
               "wrong_field_type /blocks/0/body/0/text"
             ]

      assert codes.([
               %{
                 "type" => "pair",
                 "left" => %{"id" => "x", "type" => "note"},
                 "right" => %{"id" => "x", "type" => "note"}
               }
             ]) == ["duplicate_block_id /blocks/0/right/id"]

      assert codes.([%{"type" => "note", "a/b~c" => 1}]) == []
      assert codes.([%{"text" => "x"}]) == ["missing_required_field /blocks/0/type"]
    end

    test "ids count only where a block was accepted, and pointers escape ~ and /" do
      schema =
        Schema.compile(%{
          "type" => "object",
          "required" => ["type"],
          "properties" => %{
            "type" => %{"enum" => ["box"]},
            "id" => %{"type" => "string"},
            "a/b~c" => %{
              "type" => "array",
              "items" => %{
                "anyOf" => [
                  %{"$ref" => "#"},
                  %{"type" => "object", "properties" => %{"id" => %{"type" => "string"}}}
                ]
              }
            }
          }
        })

      assert Validate.validate(
               %{"blocks" => [%{"id" => "x", "type" => "box", "a/b~c" => [%{"id" => "x"}]}]},
               schema
             ) == :ok

      assert {:error, [%{path: "/blocks/0/a~1b~0c/0"}]} =
               Validate.validate(
                 %{"blocks" => [%{"id" => "x", "type" => "box", "a/b~c" => [7]}]},
                 schema
               )
    end

    test "anyOf picks the first passing shape, else the first whose JS typeof fits (JS)" do
      schema =
        Schema.compile(%{
          "type" => "object",
          "properties" => %{
            "n" => %{"anyOf" => [%{"enum" => [nil]}, %{"type" => "string"}]},
            "c" => %{"anyOf" => [%{"const" => "a"}, %{"type" => "integer"}]},
            "e" => %{"anyOf" => []},
            "t" => %{"type" => []},
            "o" => %{
              "anyOf" => [
                %{"type" => "object", "required" => ["a"]},
                %{"type" => "object", "required" => ["b"]}
              ]
            }
          }
        })

      cases = [
        {%{"n" => %{}}, ["value_not_allowed /blocks/0/n"]},
        {%{"n" => []}, ["value_not_allowed /blocks/0/n"]},
        {%{"n" => 1}, ["wrong_field_type /blocks/0/n"]},
        {%{"c" => "b"}, ["value_not_allowed /blocks/0/c"]},
        {%{"c" => 1.5}, ["wrong_field_type /blocks/0/c"]},
        {%{"c" => 2}, []},
        {%{"e" => 1}, ["wrong_field_type /blocks/0/e"]},
        {%{"t" => "x"}, ["wrong_field_type /blocks/0/t"]},
        {%{"o" => %{}}, ["missing_required_field /blocks/0/o/a"]},
        {%{"o" => %{"b" => 1}}, []}
      ]

      for {block, expected} <- cases do
        got = %{"blocks" => [block]} |> Validate.validate(schema) |> pairs()
        assert {block, Enum.map(got, fn {c, p} -> "#{c} #{p}" end)} == {block, expected}
      end
    end

    test "const and enum compare numbers as JS ===, and $ref unescapes ~1 and ~0 (JS)" do
      schema =
        Schema.compile(%{
          "type" => "object",
          "properties" => %{
            "k" => %{"const" => 1},
            "e" => %{"enum" => [1, 2]},
            "s" => %{"$ref" => "#/definitions/a~1b"},
            "t" => %{"$ref" => "#/definitions/c~0d"}
          },
          "definitions" => %{"a/b" => %{"type" => "string"}, "c~d" => %{"type" => "integer"}}
        })

      cases = [
        {%{"k" => 1.0}, []},
        {%{"k" => 2}, ["value_not_allowed /blocks/0/k"]},
        {%{"e" => 2.0}, []},
        {%{"e" => 3}, ["value_not_allowed /blocks/0/e"]},
        {%{"s" => "x", "t" => 1}, []},
        {%{"s" => 1, "t" => "x"},
         ["wrong_field_type /blocks/0/s", "wrong_field_type /blocks/0/t"]}
      ]

      for {block, expected} <- cases do
        got = %{"blocks" => [block]} |> Validate.validate(schema) |> pairs()
        assert {block, Enum.map(got, fn {c, p} -> "#{c} #{p}" end)} == {block, expected}
      end
    end

    test "keeps the order of a schema decoded with ordered objects" do
      json = ~s({"type":"object","properties":{"z":{"type":"string"},"a":{"type":"string"}}})
      schema = Schema.compile(Jason.decode!(json, objects: :ordered_objects))

      assert {:error, [%{path: "/blocks/0/z"}, %{path: "/blocks/0/a"}]} =
               Validate.validate(%{"blocks" => [%{"z" => 1, "a" => 1}]}, schema)
    end

    defp with_note(extra) do
      update_in(@tiny, ["definitions", "blocks", "note"], &Map.merge(&1, extra))
    end

    test "refuses a schema it cannot follow" do
      refusals = [
        {%{"additionalProperties" => false},
         ~r/unsupported schema keyword additionalProperties at #\/definitions\/blocks\/note/},
        {%{"else" => %{}}, ~r/unsupported schema keyword else/},
        {%{"type" => "date"}, ~r/unsupported schema type "date"/},
        {%{"nox-tier" => 1}, ~r/unsupported schema keyword nox-tier/},
        {%{"xtier" => 1}, ~r/unsupported schema keyword xtier/},
        {%{"properties" => %{"kind" => %{"const" => %{"a" => 1}}}},
         ~r/unsupported schema const or enum value .* at #\/definitions\/blocks\/note\/properties\/kind/},
        {%{"properties" => %{"kind" => %{"enum" => ["a", ["b"]]}}},
         ~r/unsupported schema const or enum value \["b"\]/},
        {%{"properties" => %{"kind" => %{"enum" => "abc"}}},
         ~r/schema enum at #\/definitions\/blocks\/note\/properties\/kind is not an array/},
        {%{"properties" => %{"text" => %{"type" => "string", "pattern" => "^a"}}},
         ~r/unsupported schema keyword pattern at #\/definitions\/blocks\/note\/properties\/text/},
        {%{"anyOf" => [%{"type" => "string"}, %{"format" => "uri"}]},
         ~r/unsupported schema keyword format at #\/definitions\/blocks\/note\/anyOf\/1/},
        {%{"properties" => %{"text" => true}},
         ~r/schema at #\/definitions\/blocks\/note\/properties\/text is not an object/},
        {%{"properties" => 5},
         ~r/schema properties at #\/definitions\/blocks\/note is not an object/},
        {%{"required" => "type"},
         ~r/schema required at #\/definitions\/blocks\/note is not a list of names/},
        {%{"allOf" => %{}}, ~r/schema allOf at #\/definitions\/blocks\/note is not an array/}
      ]

      for key <- ~w(items not if then) do
        assert_raise ArgumentError,
                     ~r/unsupported schema keyword format at #\/definitions\/blocks\/note\/#{key}/,
                     fn ->
                       Schema.compile(with_note(%{key => %{"format" => "uri"}}))
                     end
      end

      for {extra, message} <- refusals do
        assert_raise ArgumentError, message, fn -> Schema.compile(with_note(extra)) end
      end

      assert Schema.compile(
               with_note(%{"properties" => %{"kind" => %{"enum" => ["a", 1, true, nil]}}})
             )

      assert_raise ArgumentError,
                   ~r/\$ref #\/definitions\/blocks\/missing does not resolve/,
                   fn ->
                     Schema.compile(
                       Map.put(@tiny, "allOf", [%{"$ref" => "#/definitions/blocks/missing"}])
                     )
                   end

      assert_raise ArgumentError, ~r/\$ref "other.json" at #\/allOf\/0 does not resolve/, fn ->
        Schema.compile(Map.put(@tiny, "allOf", [%{"$ref" => "other.json"}]))
      end
    end
  end
end
