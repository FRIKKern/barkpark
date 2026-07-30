defmodule BarkparkWeb.IconsTripwireTest do
  @moduledoc """
  Turns the whole of `lib/` into one assertion: every icon name a developer
  WROTE DOWN must be a glyph `BarkparkWeb.Icons` can actually draw.

  Why this exists: `icon/1` answered an unknown name with the "file" document
  glyph, silently. `arrow-left` was missing while three call sites asked for it
  by name — the Studio back button among them — and nobody saw it for months,
  because a wrong picture reds nothing. `alert-triangle` was missing while the
  AI-provider-not-ready warning card asked for it. Each was found by accident.
  This test is the thing that finds the next one on purpose, by name.

  ## WHAT THIS TEST CANNOT SEE — read before trusting it as coverage

  It is a grep, not a compiler. Three holes, stated so nobody mistakes a green
  run for a proof that no icon can ever fall back again:

    1. **It cannot see through a function call.** `<.icon name={tab_icon(item)} />`
       contributes nothing. `category_icon/1` and `endpoint_icon/1` are the same
       shape; both were traced by hand and every clause of both returns a
       literal that is already in `@icons`, but that tracing is a point-in-time
       fact this test does not re-check.

       This hole is what shipped four wrong pictures past the first version of
       this test. `doc_action_glyph/1`
       (`components/studio_components/editor.ex:584`) renders
       `<.icon name={@icon_name} />`, where `@icon_name` comes from a doc-action
       map — so `git-fork` and `rotate-ccw`, both written down as literals in
       `studio_live/doc_actions.ex`, were invisible to the tag scanner while
       painting documents on the desk. `tasks/schema.ex` hid `flag` and
       `clipboard-list` the same way. The name is still a developer-authored
       literal in the tree; it is just spelled as DATA rather than as an
       attribute. The `"icon" => "…"` scan below closes exactly that class, so
       the residue of hole 1 is now only names a function BUILDS or reads from
       outside the tree (hole 2).
    2. **It structurally CANNOT catch a tenant-supplied name.** `tab_icon/1`
       (`lib/barkpark_web/components/studio_components/editor.ex`) reads a
       workspace's `schema["icon"]` string, and `@editor_schema.icon` /
       `item.icon` are the same shape. That set is unbounded and lives in the
       database, not in the tree — no static scan can enumerate it. The guard
       for that class is `Icons.known_icon?/1` at the call site, and it IS now
       applied: `drawable_icon/1` sits in front of both `tab_icon/1` and
       `doc_action_glyph/1`, so a schema-supplied name naming no glyph degrades
       to the neutral "circle" or to the action's text label.

       That guard is load-bearing, not decorative: it is the reason `icon/1`
       raising in `:test` cannot be crashed by fixture data. `test/` schemas
       carry names like `"pulled-icon"` precisely because the set is arbitrary,
       and arbitrary data must never be a test failure — only a developer
       WRITING a name that does not exist is a bug, and that is what the two
       scans above catch.
    3. **It only reads literals in `lib/`.** Names built by interpolation
       (`"chevron-" <> dir`) are invisible, and `test/` is not scanned.
       `priv/plugins/*/schemas/*.json` USED to be part of this hole and no
       longer is — three shipped schemas were carrying unmapped emoji at once
       (spd-w17), so those files now have their own JSON-parsing scan below.

  Inside those limits it is exact: it parses balanced `{…}` attribute
  expressions, so a literal hiding inside `name={if x, do: "a", else: "b"}` is
  caught as well as a bare `name="a"`.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Icons

  @lib_root Path.expand("../../../lib", __DIR__)

  describe "every icon name literal in lib/" do
    test "resolves to a real glyph — a name with no entry paints the wrong picture, silently" do
      sites = icon_call_sites()

      assert length(sites) > 30,
             "expected the scanner to find the desk's icon call sites; found #{length(sites)} — " <>
               "the parser is probably broken, and a broken parser is a vacuously green tripwire"

      unknown =
        Enum.reject(sites, fn {_file, _line, name} -> Icons.known_icon?(name) end)

      assert unknown == [], """
      #{length(unknown)} icon name(s) in lib/ have no entry in BarkparkWeb.Icons,
      so `icon/1` paints the "file" document glyph where the call site asked for
      something else:

      #{Enum.map_join(unknown, "\n", fn {file, line, name} -> "  #{name}  <-  #{file}:#{line}" end)}

      Add the path to @icons in lib/barkpark_web/components/icons.ex.
      """
    end

    test "the scan actually reaches distinct names across more than one file" do
      sites = icon_call_sites()

      files = sites |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      names = sites |> Enum.map(&elem(&1, 2)) |> Enum.uniq()

      assert length(files) > 3, "scanned only #{inspect(files)}"
      assert length(names) > 10, "found only #{length(names)} distinct names: #{inspect(names)}"
    end

    test "the scanner sees literals nested inside a name={...} expression" do
      # A bare regex on `name="…"` would miss both of these; the ternary form is
      # how the desk expresses open/closed and collapsed/expanded chevrons.
      body = ~s(<.icon name={if @open, do: "chevron-down", else: "chevron-right"} size={14} />)

      assert names_in_tag_body(body) == ["chevron-down", "chevron-right"]
    end
  end

  describe "every icon name written as data in lib/" do
    test "resolves to a real glyph — a doc action's icon paints just as silently" do
      sites = icon_data_sites()

      assert length(sites) > 10,
             "expected the scanner to find the doc-action and schema-tab icon " <>
               "declarations; found #{length(sites)} — a broken parser is a " <>
               "vacuously green tripwire"

      unknown = Enum.reject(sites, fn {_file, _line, name} -> Icons.known_icon?(name) end)

      assert unknown == [], """
      #{length(unknown)} icon name(s) declared as data in lib/ have no entry in
      BarkparkWeb.Icons. These reach `icon/1` through `doc_action_glyph/1` and
      friends, so they paint the "file" document glyph on a real control:

      #{Enum.map_join(unknown, "\n", fn {file, line, name} -> "  #{name}  <-  #{file}:#{line}" end)}

      Add the path to @icons in lib/barkpark_web/components/icons.ex.
      """
    end

    test "the data scan reaches the registries that actually declare icons" do
      files = icon_data_sites() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      assert Enum.any?(files, &String.contains?(&1, "doc_actions.ex")),
             "the doc-action registry is the call site this scan exists for; " <>
               "scanned only #{inspect(files)}"
    end

    test "the data scanner reads an emoji alias as the glyph it aliases" do
      # `tasks/schema.ex` declares a tab icon as an emoji; `known_icon?/1`
      # resolves the alias, so the scan must hand it over unresolved and let
      # the predicate do that work rather than rejecting it as unknown.
      assert icon_values_in(~s(%{"name" => "tags", "icon" => "🏷"})) == ["🏷"]
      assert Icons.known_icon?("🏷")
    end
  end

  describe "every icon declared by a SHIPPED plugin schema (priv/)" do
    # THE FOURTH HOLE, and it was live in three schemas at once (spd-w17).
    # A plugin's schema JSON is not source — the two scans above never read
    # `priv/`, so `session.json`'s 🧵, `form_response.json`'s 🗳️ and scaffy
    # `command.json`'s 🔧 all shipped names `@emoji_map` does not carry. That
    # is not cosmetic: `icon/1` RAISES under :test (so any table-driven Studio
    # test carrying such a row dies before it can assert anything) and warns +
    # paints the "file" document glyph in dev and prod — a desk row lying
    # about what it opens. These are developer-authored literals in the tree,
    # exactly the class the lib/ scans exist for, just spelled as JSON.
    test "resolves to a real glyph — a schema icon paints a desk row" do
      sites = schema_icon_sites()

      assert length(sites) > 10,
             "expected the shipped plugin schemas to declare icons; found " <>
               "#{length(sites)} — a broken scan is a vacuously green tripwire"

      unknown = Enum.reject(sites, fn {_file, name} -> Icons.known_icon?(name) end)

      assert unknown == [], """
      #{length(unknown)} icon name(s) declared by a SHIPPED plugin schema have
      no entry in BarkparkWeb.Icons. `icon/1` raises on them under :test and
      paints the "file" glyph in dev/prod:

      #{Enum.map_join(unknown, "\n", fn {file, name} -> "  #{name}  <-  #{file}" end)}

      Use a name from BarkparkWeb.Icons.icon_names/0 (or add the path to
      @icons in lib/barkpark_web/components/icons.ex).
      """
    end

    test "the scan reaches the schemas that actually ship a desk row" do
      files = schema_icon_sites() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      for expected <- ["bulldocs/schemas/session.json", "bulldocs/schemas/paper.json"] do
        assert Enum.any?(files, &String.contains?(&1, expected)),
               "#{expected} declares a desk icon and must be scanned; " <>
                 "scanned only #{inspect(files)}"
      end
    end
  end

  describe "known_icon?/1" do
    test "answers the same question icon/1 asks, including emoji aliases" do
      assert Icons.known_icon?("plus")
      assert Icons.known_icon?("alert-triangle")
      # 📄 is an alias for file-text, which exists.
      assert Icons.known_icon?("📄")

      refute Icons.known_icon?("zzz-not-a-real-icon")
      # 🚀 has no alias entry and is not itself a glyph name.
      refute Icons.known_icon?("🚀")
      refute Icons.known_icon?(nil)
      refute Icons.known_icon?(:plus)
    end

    test "every emoji alias points at a glyph that exists" do
      # An alias to a missing name would fall back just as silently.
      for emoji <- [
            "📄",
            "📑",
            "👤",
            "🏷",
            "💼",
            "⚙",
            "🧭",
            "🎨",
            "📁",
            "📂",
            "🖼",
            "✅",
            "📰",
            "📊",
            "🎫",
            "🧩",
            "🗂"
          ] do
        assert Icons.known_icon?(emoji), "emoji #{emoji} aliases a glyph that does not exist"
      end
    end
  end

  # ── the scanner ────────────────────────────────────────────────────────────

  @priv_plugins_root Path.expand("../../../priv/plugins", __DIR__)

  # Every `"icon"` value declared anywhere in a shipped plugin schema — the
  # type's own desk glyph AND its field-group tab glyphs, which reach `icon/1`
  # through the same `drawable_icon/1` seam. Parsed as JSON rather than
  # grepped, so a nested declaration cannot hide from it.
  defp schema_icon_sites do
    @priv_plugins_root
    |> Path.join("*/schemas/*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      rel = Path.relative_to(path, @priv_plugins_root)

      path
      |> File.read!()
      |> Jason.decode!()
      |> icon_values()
      |> Enum.map(&{rel, &1})
    end)
  end

  defp icon_values(%{} = map) do
    own =
      case Map.get(map, "icon") do
        name when is_binary(name) -> [name]
        _ -> []
      end

    own ++ Enum.flat_map(Map.values(map), &icon_values/1)
  end

  defp icon_values(list) when is_list(list), do: Enum.flat_map(list, &icon_values/1)
  defp icon_values(_), do: []

  defp icon_call_sites do
    @lib_root
    |> source_files()
    |> Enum.flat_map(&sites_in_file/1)
  end

  # The module that DEFINES `icon/1` is the one place with no call sites, and
  # its docs/raise-message necessarily quote the tag shape as prose. Scanning it
  # would only ever find documentation.
  @definition_module "barkpark_web/components/icons.ex"

  defp source_files(root) do
    root
    |> Path.join("**/*.{ex,exs,heex}")
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, @definition_module))
  end

  defp sites_in_file(path) do
    source = File.read!(path)
    rel = Path.relative_to(path, Path.expand("..", @lib_root))

    source
    |> tag_bodies()
    |> Enum.flat_map(fn {body, offset} ->
      line = line_at(source, offset)
      Enum.map(names_in_tag_body(body), &{rel, line, &1})
    end)
  end

  # Every `<.icon …>` body in the source, with the byte offset it started at.
  defp tag_bodies(source), do: tag_bodies(source, 0, [])

  defp tag_bodies(source, consumed, acc) do
    case :binary.match(source, "<.icon") do
      :nomatch ->
        Enum.reverse(acc)

      {index, len} ->
        start = index + len
        rest = binary_part(source, start, byte_size(source) - start)
        {body, remainder} = balanced_tag_body(rest, 0, [])
        offset = consumed + index
        consumed_now = consumed + byte_size(source) - byte_size(remainder)
        tag_bodies(remainder, consumed_now, [{body, offset} | acc])
    end
  end

  # Walk to the `>` that closes the tag, ignoring any `>` nested inside a `{…}`
  # attribute expression (`size={if n > 2, do: 18, else: 14}` must not end it).
  defp balanced_tag_body(<<>>, _depth, acc), do: {collect(acc), ""}
  defp balanced_tag_body(<<">", rest::binary>>, 0, acc), do: {collect(acc), rest}

  defp balanced_tag_body(<<"{", rest::binary>>, depth, acc),
    do: balanced_tag_body(rest, depth + 1, ["{" | acc])

  defp balanced_tag_body(<<"}", rest::binary>>, depth, acc),
    do: balanced_tag_body(rest, max(depth - 1, 0), ["}" | acc])

  defp balanced_tag_body(<<c::utf8, rest::binary>>, depth, acc),
    do: balanced_tag_body(rest, depth, [<<c::utf8>> | acc])

  defp collect(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # `name="foo"` yields ["foo"]; `name={…}` yields every string literal inside
  # the balanced expression, so ternary/cond forms are covered too.
  defp names_in_tag_body(body) do
    case Regex.run(~r/(?:\A|\s)name=/, body, return: :index) do
      nil ->
        []

      [{index, len}] ->
        after_eq = binary_part(body, index + len, byte_size(body) - index - len)

        case after_eq do
          <<"\"", _::binary>> ->
            case Regex.run(~r/\A"([^"]*)"/, after_eq, capture: :all_but_first) do
              [name] -> [name]
              _ -> []
            end

          <<"{", rest::binary>> ->
            {expr, _} = balanced_expr(rest, 0, [])
            ~r/"([^"]*)"/ |> Regex.scan(expr, capture: :all_but_first) |> List.flatten()

          _ ->
            []
        end
    end
  end

  defp balanced_expr(<<>>, _depth, acc), do: {collect(acc), ""}
  defp balanced_expr(<<"}", rest::binary>>, 0, acc), do: {collect(acc), rest}

  defp balanced_expr(<<"{", rest::binary>>, depth, acc),
    do: balanced_expr(rest, depth + 1, ["{" | acc])

  defp balanced_expr(<<"}", rest::binary>>, depth, acc),
    do: balanced_expr(rest, depth - 1, ["}" | acc])

  defp balanced_expr(<<c::utf8, rest::binary>>, depth, acc),
    do: balanced_expr(rest, depth, [<<c::utf8>> | acc])

  # ── the data scanner ───────────────────────────────────────────────────────
  #
  # An icon name spelled as a map entry — `"icon" => "git-fork"` — rather than
  # as a tag attribute. Same developer-authored literal, same silent fallback,
  # invisible to the tag scanner because no `<.icon` sits anywhere near it.

  defp icon_data_sites do
    @lib_root
    |> source_files()
    |> Enum.flat_map(fn path ->
      source = File.read!(path)
      rel = Path.relative_to(path, Path.expand("..", @lib_root))

      ~r/"icon"\s*=>\s*"([^"]*)"/
      |> Regex.scan(source, return: :index)
      |> Enum.map(fn [{whole_at, _}, {name_at, name_len}] ->
        {rel, line_at(source, whole_at), binary_part(source, name_at, name_len)}
      end)
    end)
  end

  # Extracted so the parser is provable on a fixture rather than only on the
  # tree, which changes under it.
  defp icon_values_in(source) do
    ~r/"icon"\s*=>\s*"([^"]*)"/
    |> Regex.scan(source, capture: :all_but_first)
    |> List.flatten()
  end

  defp line_at(source, offset) do
    source
    |> binary_part(0, offset)
    |> :binary.matches("\n")
    |> length()
    |> Kernel.+(1)
  end
end
