defmodule Barkpark.PortableDoc.Render.ReaderDarkTokenParityTest do
  @moduledoc """
  Reader dark-mode token-coverage guard.

  The paper palette is theme-swapped TWO different ways:

    * The EDIT surfaces (Studio, the embedder bundle) stamp `html[data-theme]`,
      so they pick up the DARK values from paper-surface.css's
      `html[data-theme="dark"] .bp-paper-surface` block.

    * The `/papers` READER defaults to `prefers-color-scheme` in the inline
      `<style>` of `layouts/bulldocs.html.heex`. Its dark/light pill stamps
      `data-theme` pre-paint (localStorage `barkpark_theme`), but the @media
      blocks remain the no-JS / first-paint owner of reader dark mode — so
      their token coverage must stay COMPLETE, which is what this guard pins.

  Because the two paths are separate, a DARK token defined only on
  `html[data-theme="dark"]` is invisible to an OS-dark reader unless the reader's
  own `@media (prefers-color-scheme: dark)` block ALSO re-skins it. That gap
  shipped once: the reader block re-declared `--paper-*` but not the callout
  `--bp-tone-*`, so OS-dark readers rendered LIGHT callout boxes (#eff6ff) on the
  dark article (fixed in #1217). This test is the tripwire so it can't recur:
  every dark token the edit theme sets (minus the genuinely edit-only ones) must
  also be re-skinned in the reader's prefers-color-scheme block.
  """
  use ExUnit.Case, async: true

  @paper_surface Path.expand(
                   "../../../../assets/paper-surface/paper-surface.css",
                   __DIR__
                 )

  @bulldocs Path.expand(
              "../../../../lib/barkpark_web/layouts/bulldocs.html.heex",
              __DIR__
            )

  # Tokens the DARK edit theme sets that the reader legitimately never needs —
  # edit-only affordances the read-only /papers page never paints. Keep this
  # list TIGHT: a token belongs here only if the reader provably can't use it.
  @edit_only MapSet.new(~w(--paper-edit-hover))

  test "every edit-dark token is re-skinned in the reader's prefers-color-scheme block" do
    surface = File.read!(@paper_surface)
    bulldocs = File.read!(@bulldocs)
    prefers_dark = ~r/@media\s*\(prefers-color-scheme:\s*dark\)\s*\{/

    edit_dark = tokens_in_blocks(surface, ~r/html\[data-theme="dark"\][^{]*\{/)

    # The reader loads BOTH paper-surface.css (Stylesheet.css/0) AND the inline
    # bulldocs.html.heex <style>, and theme-swaps via prefers-color-scheme. So a
    # token is reader-covered if a prefers-color-scheme:dark block in EITHER file
    # re-skins it — status `--st-*` live in paper-surface.css's own dark media
    # block; the `--paper-*` / `--bp-tone-*` reader companions live in bulldocs.
    reader_dark =
      MapSet.union(
        tokens_in_blocks(surface, prefers_dark),
        tokens_in_blocks(bulldocs, prefers_dark)
      )

    assert MapSet.size(edit_dark) > 0,
           "parsed ZERO dark tokens from paper-surface.css html[data-theme=\"dark\"] — the parser " <>
             "or the source block changed shape (distrust-vacuous-green)."

    assert MapSet.size(reader_dark) > 0,
           "parsed ZERO prefers-color-scheme:dark tokens from paper-surface.css + bulldocs.html.heex " <>
             "— the reader dark blocks moved or renamed (distrust-vacuous-green)."

    missing =
      edit_dark
      |> MapSet.difference(reader_dark)
      |> MapSet.difference(@edit_only)
      |> Enum.sort()

    assert missing == [],
           """
           Reader dark-mode token gap — these tokens dark-swap on the EDIT theme
           (paper-surface.css `html[data-theme="dark"]`) but are NOT re-skinned in
           the READER's `@media (prefers-color-scheme: dark)` block
           (layouts/bulldocs.html.heex). An OS-dark /papers reader falls back to
           their LIGHT values (e.g. a light callout box on the dark article — the
           #1217 bug). Add each to the reader's prefers-color-scheme block,
           byte-mirroring the html[data-theme="dark"] value, OR add it to
           @edit_only if the reader genuinely never paints it.

           Missing: #{Enum.join(missing, ", ")}
           """
  end

  # ── PRINT: the paged sheet is a LIGHT surface ───────────────────────────────
  # Sibling of the guard above, one medium over. BOTH dark routes survive into
  # paged output — a print preview keeps the OS `prefers-color-scheme` AND keeps
  # whatever `data-theme` the pre-paint toggle stamped — while the reader's
  # `@media print` block forces a WHITE ground. So before the print palette
  # re-stamp an OS-dark reader printed the DARK ink onto that white: #e7ede9 on
  # #fff, ~1.2:1, a page that looks blank.
  #
  # The re-stamp is GENERATED (design/emit.mjs `printRestamp`) from the same
  # token data the light blocks use, so it cannot drift by hand — but nothing
  # stopped a future emitter change from dropping a token, or from stamping a
  # value that is not the light one. This pins both: every token the reader's
  # own prefers-dark block re-skins must be re-stamped under @media print, with
  # a value byte-identical to the `html[data-theme="light"]` companion's.
  #
  # Scoped to the BASE palette (everything before the data-bp-theme banner):
  # the themed blocks repeat all three shapes per theme, and unioning them would
  # collide five different values onto one token name.
  @print_exempt_prefix "--mail-"

  test "the reader's @media print block re-stamps every dark token with its LIGHT value" do
    base =
      @bulldocs
      |> File.read!()
      |> String.split("theme identity (data-bp-theme)", parts: 2)
      |> hd()

    assert String.contains?(base, "@media print"),
           "parsed no @media print block out of the BASE reader palette — the split marker " <>
             "or the generated print block moved (distrust-vacuous-green)."

    dark = decls_in_blocks(base, ~r/@media\s*\(prefers-color-scheme:\s*dark\)\s*\{/)
    light = decls_in_blocks(base, ~r/html\[data-theme="light"\] body:has/)
    print = decls_in_blocks(base, ~r/@media print\s*\{/)

    for {label, m} <- [{"dark", dark}, {"light", light}, {"print", print}] do
      assert map_size(m) > 0,
             "parsed ZERO declarations from the reader's #{label} block — its selector or " <>
               "media header changed shape (distrust-vacuous-green)."
    end

    problems =
      for {name, _dark_value} <- Enum.sort(dark),
          not String.starts_with?(name, @print_exempt_prefix),
          reduce: [] do
        acc ->
          light_value = Map.get(light, name)
          print_value = Map.get(print, name)

          cond do
            is_nil(light_value) ->
              # Not this test's job to fix, but a dark token with no light
              # companion has nothing for print to fall back to either.
              ["#{name} — the html[data-theme=\"light\"] companion never declares it" | acc]

            is_nil(print_value) ->
              ["#{name} — NOT re-stamped under @media print (prints its DARK value)" | acc]

            print_value != light_value ->
              ["#{name} — print value #{print_value} is not the light value #{light_value}" | acc]

            true ->
              acc
          end
      end

    assert problems == [],
           """
           Reader PRINT palette gap — paged output would carry dark-mode values.
           The reader's @media print block must re-stamp every token its
           prefers-color-scheme:dark block re-skins, with the LIGHT value (the
           `html[data-theme="light"]` companion's). It is generated: fix
           design/emit.mjs `printRestamp` and re-run `node design/emit.mjs --write`,
           never by hand-editing the marker block.

           #{Enum.join(Enum.sort(problems), "\n           ")}
           """
  end

  # `--mail-*` is exempt: #bp-mailapp is `display: none !important` under
  # @media print (the Email view is an alternate VIEW of the article, not part
  # of the printed paper), so its chrome tokens are never painted on paper.
  # A token earns a place here only by being provably unpainted in print.

  # Collect `--custom-prop: value` PAIRS inside every block whose header matches
  # `header_re`, brace-matched like tokens_in_blocks/2. Later blocks win, which
  # matches the cascade for equal-specificity rules in source order.
  defp decls_in_blocks(source, header_re) do
    header_re
    |> Regex.scan(source, return: :index)
    |> Enum.reduce(%{}, fn [{start, len} | _], acc ->
      after_open = binary_part(source, start + len, byte_size(source) - start - len)
      body = brace_body(after_open)

      ~r/(--[a-z0-9-]+)\s*:\s*([^;{}]+)/
      |> Regex.scan(body)
      |> Enum.reduce(acc, fn [_, name, value], a ->
        Map.put(a, name, value |> String.trim() |> String.replace(~r/\s+/, " "))
      end)
    end)
  end

  # Collect every `--custom-prop` NAME declared inside every block whose header
  # matches `header_re`, brace-matched so nested rules (an @media wrapping an
  # inner selector) are included. Unions across all matching blocks.
  defp tokens_in_blocks(source, header_re) do
    header_re
    |> Regex.scan(source, return: :index)
    |> Enum.reduce(MapSet.new(), fn [{start, len} | _], acc ->
      after_open = binary_part(source, start + len, byte_size(source) - start - len)
      body = brace_body(after_open)

      ~r/(--[a-z0-9-]+)\s*:/
      |> Regex.scan(body)
      |> Enum.reduce(acc, fn [_, name], a -> MapSet.put(a, name) end)
    end)
  end

  # Given text that starts immediately AFTER an opening `{`, return the substring
  # up to (not including) the brace that closes it — depth-tracked so nested
  # `{ }` don't end it early.
  defp brace_body(s), do: brace_body(s, 1, [])
  defp brace_body(<<>>, _depth, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp brace_body(<<?}, _rest::binary>>, 1, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp brace_body(<<?{, rest::binary>>, depth, acc), do: brace_body(rest, depth + 1, [?{ | acc])
  defp brace_body(<<?}, rest::binary>>, depth, acc), do: brace_body(rest, depth - 1, [?} | acc])
  defp brace_body(<<c, rest::binary>>, depth, acc), do: brace_body(rest, depth, [c | acc])
end
