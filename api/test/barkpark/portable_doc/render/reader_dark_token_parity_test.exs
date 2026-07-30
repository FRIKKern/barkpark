defmodule Barkpark.PortableDoc.Render.ReaderDarkTokenParityTest do
  @moduledoc """
  Reader dark-mode token-coverage guard.

  The paper palette is theme-swapped TWO different ways:

    * The EDIT surfaces (Studio, the embedder bundle) stamp `html[data-theme]`,
      so they pick up the DARK values from paper-surface.css's
      `html[data-theme="dark"] .bp-paper-surface` block.

    * The `/papers` READER never stamps `data-theme` — it theme-swaps purely via
      `prefers-color-scheme` in the inline `<style>` of
      `layouts/bulldocs.html.heex`.

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
