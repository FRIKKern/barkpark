defmodule BarkparkWeb.TenantIconGuardTest do
  @moduledoc """
  `icons-tab-icon-tenant-guard` — every `<.icon name={…} />` whose name is
  RUNTIME DATA must choose its fallback at the call site.

  ## The hole this closes

  `BarkparkWeb.IconsTripwireTest` scans `lib/` for icon names a developer WROTE
  DOWN. Its own moduledoc states the two holes it cannot close: it cannot see
  through a function call, and it "structurally CANNOT catch a tenant-supplied
  name" — a workspace schema's `icon`, a plugin's declared nav-item `icon`, a
  `Barkpark.Structure.Node`'s `icon`. That set is unbounded and lives in the
  database, not in the tree.

  The prescribed guard for that class is `Icons.drawable_name/2` (or the
  `drawable_icon/1` wrapper in `editor.ex`), which collapses BOTH failure shapes
  — a non-binary, and an unknown string — to a fallback the CALL SITE names.
  Nothing enforced that it was applied. This does.

  ## Why `|| "file"` is not the guard, and was the live defect

  Three sites were spelling the degrade as `||`, which answers **only** nil and
  false:

    * `components/studio_components/nav.ex` — `tab[:icon] || "file"`, where a tab
      comes from `Registry.collect_top_menu_entries/1`: PLUGIN data.
    * `live/studio/studio_live/components.ex` — `pane[:icon] || "file"`.
    * `live/studio/studio_live/components.ex` — `item.icon`, bare, on the
      `:plugin_link` row, sitting BETWEEN two siblings that were already on
      `drawable_name/2`. Its value is `item[:icon]` copied verbatim off a
      plugin's declared nav item by `Barkpark.Structure.plugin_item_to_node/2`.

  An unknown STRING passes `||` untouched and reaches `icon/1`, which paints the
  "file" document glyph in dev/prod and RAISES under `:test`. A truthy
  NON-BINARY passes too — `:folder || "file"` is `:folder` — which is the exact
  shape `Icons.resolve_paths/2`'s own raise message calls out.

  ## What the scan accepts

  It parses the `name=` expression with Elixir's own parser rather than grepping,
  so a literal-only conditional (`if @open, do: "a", else: "b"`) is accepted on
  its branches while `||` is NOT — `||` recurses into BOTH sides, and a data read
  on the left is the defect.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Icons

  @lib_root Path.expand("../../../lib", __DIR__)

  # The module that DEFINES icon/1 quotes the tag shape in its docs and raise
  # messages; scanning it would only ever find documentation.
  @definition_module "barkpark_web/components/icons.ex"

  # Calls whose return value is already bounded to a drawable name.
  #
  #   drawable_name/2  — BarkparkWeb.Icons, the public guard.
  #   drawable_icon/1  — editor.ex's private wrapper; `known_icon?(name) && name`.
  #   tab_icon/1       — editor.ex; `drawable_icon(icon) || "circle"`.
  @guard_calls ~w(drawable_name drawable_icon tab_icon)a

  # Sites the scan cannot prove and a human has ruled on. Each entry must carry
  # WHY, because an allowlist with no reason is just a suppressed failure.
  @adjudicated %{
    # `@icon_name` is assigned one line earlier as `drawable_icon(icon_name)`,
    # and the render is wrapped in `<%= if @icon_name do %>`. Guarded, just not
    # at the tag.
    {"lib/barkpark_web/components/studio_components/editor.ex", "@icon_name"} =>
      "assigned from drawable_icon/1 in doc_action_glyph/1, rendered under an if",
    # Both are private helpers in api_tester_live.ex whose every clause returns a
    # literal already in @icons. Traced by hand; the icons tripwire records the
    # same tracing as a point-in-time fact.
    {"lib/barkpark_web/live/studio/api_tester_live.ex", "category_icon(category)"} =>
      "every clause returns a literal in @icons (traced; see IconsTripwireTest hole 1)",
    {"lib/barkpark_web/live/studio/api_tester_live.ex", "endpoint_icon(ep)"} =>
      "every clause returns a literal in @icons (traced; see IconsTripwireTest hole 1)"
  }

  describe "every dynamic <.icon name={…}/> in lib/" do
    test "chooses its fallback at the call site — an unguarded one paints a wrong glyph, or raises" do
      sites = dynamic_icon_sites()

      assert length(sites) > 8,
             "expected the scanner to find the desk's DYNAMIC icon call sites; found " <>
               "#{length(sites)} — a broken parser is a vacuously green tripwire"

      unguarded =
        Enum.reject(sites, fn {file, _line, expr, verdict} ->
          verdict == :guarded or Map.has_key?(@adjudicated, {file, expr})
        end)

      assert unguarded == [], """
      #{length(unguarded)} `<.icon name={…}/>` site(s) hand runtime DATA to
      `icon/1` without choosing a fallback:

      #{Enum.map_join(unguarded, "\n", fn {file, line, expr, _} -> "  name={#{expr}}  <-  #{file}:#{line}" end)}

      An unknown string paints the "file" document glyph in dev/prod and RAISES
      under :test; a truthy non-binary does the same (`:folder || "file"` is
      `:folder`, so `||` does not cover it). Wrap the value:

          <.icon name={BarkparkWeb.Icons.drawable_name(item.icon, "folder")} />

      so the fallback glyph is a decision where it means something. If the value
      is provably bounded somewhere else, add it to @adjudicated WITH the reason.
      """
    end

    test "the scan reaches the files that actually render tenant icons" do
      files = dynamic_icon_sites() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      for expected <- [
            "lib/barkpark_web/components/studio_components/nav.ex",
            "lib/barkpark_web/live/studio/studio_live/components.ex",
            "lib/barkpark_web/components/studio_components/editor.ex"
          ] do
        assert expected in files,
               "#{expected} renders a tenant/plugin-supplied icon and must be scanned; " <>
                 "scanned only #{inspect(files)}"
      end
    end

    test "the classifier accepts a literal-only conditional and REJECTS ||" do
      # The distinction the whole scan turns on. `||` answers nil/false only, so
      # its left side still reaches icon/1 — that IS the defect being fixed.
      assert classify(~S<if @open, do: "chevron-down", else: "chevron-right">) == :guarded
      assert classify(~S<"plus">) == :guarded
      assert classify(~S<Icons.drawable_name(item.icon, "folder")>) == :guarded
      assert classify(~S<drawable_icon(@editor_schema.icon) || "file">) == :guarded

      assert classify(~S<tab[:icon] || "file">) == :unguarded
      assert classify(~S<item.icon>) == :unguarded
      assert classify(~S<@some_assign>) == :unguarded
    end
  end

  describe "drawable_name/2 is the substitution the call sites now make" do
    test "a KNOWN tenant icon is returned unchanged, alias included" do
      assert Icons.drawable_name("folder", "circle") == "folder"
      assert Icons.drawable_name("file-text", "circle") == "file-text"
      # An emoji alias resolves through known_icon?/1, so it survives too.
      assert Icons.known_icon?("📄")
      assert Icons.drawable_name("📄", "circle") == "📄"
    end

    test "an UNKNOWN tenant icon becomes the call site's documented default" do
      assert Icons.drawable_name("bp-tenant-icon-that-does-not-exist", "circle") == "circle"
      assert Icons.drawable_name("bp-tenant-icon-that-does-not-exist", "file") == "file"
    end

    test "a truthy NON-BINARY becomes the default too — the shape `||` lets through" do
      # `:folder || "file"` is `:folder`, which reaches icon/1 as a non-binary.
      assert Icons.drawable_name(:folder, "circle") == "circle"
      assert Icons.drawable_name(%{"name" => "folder"}, "file") == "file"
      assert Icons.drawable_name(nil, "circle") == "circle"
    end

    test "the guarded value renders under the :test RAISE policy without raising" do
      # The policy that makes an unguarded site a hard failure rather than a
      # cosmetic one. Rendering the raw tenant value raises; rendering the
      # guarded value does not, and paints the default glyph.
      assert_raise ArgumentError, ~r/bp-tenant-icon-that-does-not-exist/, fn ->
        render_component(&Icons.icon/1, name: "bp-tenant-icon-that-does-not-exist")
      end

      guarded = Icons.drawable_name("bp-tenant-icon-that-does-not-exist", "circle")
      html = render_component(&Icons.icon/1, name: guarded)

      assert html =~ "<svg"
      assert html == render_component(&Icons.icon/1, name: "circle")
      refute html == render_component(&Icons.icon/1, name: "file")
    end

    test "and under the dev/prod WARN policy it is the same glyph, not the 'file' default" do
      # Unguarded in dev/prod does not crash — it silently paints "file". The
      # point of the guard is that the two policies now agree on the picture.
      guarded = Icons.drawable_name("bp-tenant-icon-that-does-not-exist", "circle")

      assert Icons.resolve_paths(guarded, :warn) == Icons.resolve_paths("circle", :warn)

      refute Icons.resolve_paths("bp-tenant-icon-that-does-not-exist", :warn) ==
               Icons.resolve_paths("circle", :warn)
    end
  end

  # ── the scanner ──────────────────────────────────────────────────────────

  defp dynamic_icon_sites do
    @lib_root
    |> Path.join("**/*.{ex,exs,heex}")
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, @definition_module))
    |> Enum.flat_map(&sites_in_file/1)
  end

  defp sites_in_file(path) do
    source = File.read!(path)
    rel = Path.relative_to(path, Path.expand("..", @lib_root))

    source
    |> tag_bodies()
    |> Enum.flat_map(fn {body, offset} ->
      case name_expression(body) do
        nil -> []
        expr -> [{rel, line_at(source, offset), expr, classify(expr)}]
      end
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

  # The RAW text of the `name=` value: `name="x"` → `"x"`, `name={expr}` → `expr`.
  defp name_expression(body) do
    case Regex.run(~r/(?:\A|\s)name=/, body, return: :index) do
      nil ->
        nil

      [{index, len}] ->
        after_eq = binary_part(body, index + len, byte_size(body) - index - len)

        case after_eq do
          <<"{", rest::binary>> -> rest |> balanced_expression(0, []) |> String.trim()
          <<"\"", _::binary>> -> literal_attr(after_eq)
          _ -> nil
        end
    end
  end

  defp literal_attr(after_eq) do
    case Regex.run(~r/\A"([^"]*)"/, after_eq) do
      [whole, _] -> whole
      _ -> nil
    end
  end

  defp balanced_expression(<<>>, _depth, acc), do: collect(acc)
  defp balanced_expression(<<"}", _::binary>>, 0, acc), do: collect(acc)

  defp balanced_expression(<<"{", rest::binary>>, depth, acc),
    do: balanced_expression(rest, depth + 1, ["{" | acc])

  defp balanced_expression(<<"}", rest::binary>>, depth, acc),
    do: balanced_expression(rest, depth - 1, ["}" | acc])

  defp balanced_expression(<<c::utf8, rest::binary>>, depth, acc),
    do: balanced_expression(rest, depth, [<<c::utf8>> | acc])

  defp line_at(source, offset) do
    source |> binary_part(0, offset) |> :binary.matches("\n") |> length() |> Kernel.+(1)
  end

  # ── the classifier ───────────────────────────────────────────────────────

  @doc false
  def classify(expr) do
    case Code.string_to_quoted(expr) do
      {:ok, ast} -> if bounded?(ast), do: :guarded, else: :unguarded
      # An expression this test cannot parse is reported, never assumed safe.
      {:error, _} -> :unguarded
    end
  end

  # A string literal is the name itself.
  defp bounded?(name) when is_binary(name), do: true

  # A conditional is bounded when every BRANCH is — the condition never becomes
  # the icon name, so a data read there is irrelevant.
  defp bounded?({:if, _, [_cond, branches]}) when is_list(branches),
    do: Enum.all?(branches, fn {_k, v} -> bounded?(v) end)

  defp bounded?({:case, _, [_subject, [do: clauses]]}) when is_list(clauses),
    do: Enum.all?(clauses, fn {:->, _, [_head, body]} -> bounded?(body) end)

  defp bounded?({:cond, _, [[do: clauses]]}) when is_list(clauses),
    do: Enum.all?(clauses, fn {:->, _, [_head, body]} -> bounded?(body) end)

  # `||` and `&&` answer nil/false ONLY. Both operands can become the name, so
  # both must be bounded — which is exactly why `tab[:icon] || "file"` fails.
  defp bounded?({op, _, [l, r]}) when op in [:||, :&&], do: bounded?(l) and bounded?(r)

  # A call into one of the guards returns a drawable name by construction.
  defp bounded?({{:., _, [_mod, fun]}, _, _args}) when is_atom(fun), do: fun in @guard_calls
  defp bounded?({fun, _, args}) when is_atom(fun) and is_list(args), do: fun in @guard_calls

  # A bare variable, an assign, a field access, any other call: runtime data.
  defp bounded?(_), do: false
end
