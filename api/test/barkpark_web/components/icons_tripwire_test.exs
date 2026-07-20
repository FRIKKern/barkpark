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
    2. **It structurally CANNOT catch a tenant-supplied name.** `tab_icon/1`
       (`lib/barkpark_web/components/studio_components/editor.ex:808`) returns a
       workspace's `schema["icon"]` string VERBATIM, and `@editor_schema.icon` /
       `item.icon` are the same shape. That set is unbounded and lives in the
       database, not in the tree — no static scan can enumerate it. The guard
       for that class is `Icons.known_icon?/1` at the call site, which is NOT
       yet applied there (filed as follow-up work, not fixed here).
    3. **It only reads literals in `lib/`.** Names built by interpolation
       (`"chevron-" <> dir`) are invisible, and `test/` is not scanned.

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
      for emoji <- ["📄", "📑", "👤", "🏷", "💼", "⚙", "🧭", "🎨", "📁", "📂", "🖼", "✅", "📰", "📊", "🎫", "🧩", "🗂"] do
        assert Icons.known_icon?(emoji), "emoji #{emoji} aliases a glyph that does not exist"
      end
    end
  end

  # ── the scanner ────────────────────────────────────────────────────────────

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

  defp line_at(source, offset) do
    source
    |> binary_part(0, offset)
    |> :binary.matches("\n")
    |> length()
    |> Kernel.+(1)
  end
end
