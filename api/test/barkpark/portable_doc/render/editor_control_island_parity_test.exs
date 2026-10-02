defmodule Barkpark.PortableDoc.Render.EditorControlIslandParityTest do
  @moduledoc """
  View↔Edit parity for the editor's FORM-CONTROL islands and the ProseMirror
  numeral rule (task-ca99c4a10eb9c5df).

  Some canvas blocks edit their text in a real `<input>` / `<textarea>` that
  ProseMirror does not manage: the figure caption, the code body, and the
  terminal title and footer. The browser's own stylesheet gives every form
  control `letter-spacing: normal`, `word-spacing: normal` and
  `text-rendering: auto`, and a control whose rule sets `font-family` /
  `font-size` longhands (rather than `font: inherit`) also drops the surface's
  `font-feature-settings: "kern", "liga", "onum"`. None of that inherits
  from `.bp-paper-surface`, so each control lost the reader's 0.005em
  tracking, its ligatures and its old-style figures: the reader showed
  "Figure 12" in old-style numerals, the editor in lining ones, and a caption
  or a line of code set 0.09px per character wider in View than in Edit.

  `view_edit_parity_test.exs` cannot see this. It compares `.bp-paper-surface
  <el>` rules against their `.bp-paper-editor-body <el>` twins, and these
  controls have no reader twin: the reader prints the same text in a
  `<figcaption>` / `<pre>` / `<span>`. The rendered harness
  `__reader_canvas_render.mjs` (#16092) cannot see it either. It reads computed
  style from each block's ROOT (the `<figure>`, the `<pre>` frame), never from
  the control inside it.

  The fix is `inherit` on each control, so the value comes from the surface
  instead of being copied. The ProseMirror restore rule also dropped a redundant
  `font-variant-numeric: oldstyle-nums`, which made every editable prose
  element's computed style differ from the reader's (`normal`) while drawing
  the same glyphs. The reader gets old-style figures from
  `font-feature-settings` alone, and the restore rule now declares exactly that.

  Both sources are checked: the Studio/public shell stylesheet and the
  embedders' bundle stylesheet (its hand-kept mirror).
  """
  use ExUnit.Case, async: true

  @shell_css Path.expand(
               "../../../../priv/static/assets/bp-paper-editor-shell.css",
               __DIR__
             )
  @bundle_css Path.expand(
                "../../../../assets/paper-editor/src/styles.css",
                __DIR__
              )
  @surface_css Path.expand(
                 "../../../../assets/paper-surface/paper-surface.css",
                 __DIR__
               )

  # The four text-bearing form controls the canvas mounts in place of reader text.
  @controls [
    ".bp-canvas-figure-caption-input",
    ".bp-canvas-code-area",
    ".bp-canvas-term__title-input",
    ".bp-canvas-term__foot-input"
  ]

  # UA stylesheet resets that the reader's text does not have.
  @inherited_axes ["letter-spacing", "word-spacing", "text-rendering"]

  defp strip_comments(css), do: Regex.replace(~r{/\*.*?\*/}s, css, "")

  # Every declaration of every rule whose selector is EXACTLY `selector`
  # (one selector per rule, as all four controls are authored), merged in
  # source order so a later declaration wins, as in the cascade.
  defp declarations(css, selector) do
    ~r/(?:^|[}\n])\s*#{Regex.escape(selector)}\s*\{([^}]*)\}/
    |> Regex.scan(css, capture: :all_but_first)
    |> Enum.flat_map(fn [body] -> String.split(body, ";") end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn decl, acc ->
      case String.split(decl, ":", parts: 2) do
        [prop, value] -> Map.put(acc, String.trim(prop), String.trim(value))
        _ -> acc
      end
    end)
  end

  defp sources do
    [
      {"bp-paper-editor-shell.css", strip_comments(File.read!(@shell_css))},
      {"paper-editor/src/styles.css", strip_comments(File.read!(@bundle_css))}
    ]
  end

  test "every text-bearing form control inherits the surface's tracking and text rendering" do
    for {name, css} <- sources(), control <- @controls do
      decls = declarations(css, control)
      assert decls != %{}, "#{name}: no rule found for #{control} (parser sanity)"

      for axis <- @inherited_axes do
        assert Map.get(decls, axis) == "inherit",
               "#{name} #{control}: #{axis} is #{inspect(Map.get(decls, axis))}, " <>
                 "expected \"inherit\"; the browser's form-control default differs from the reader text"
      end
    end
  end

  test "a control that sets font longhands also inherits the surface's font features" do
    for {name, css} <- sources(), control <- @controls do
      decls = declarations(css, control)

      unless Map.get(decls, "font") == "inherit" do
        for axis <- ["font-feature-settings", "font-variant-ligatures"] do
          assert Map.get(decls, axis) == "inherit",
                 "#{name} #{control}: #{axis} is #{inspect(Map.get(decls, axis))}, " <>
                   "expected \"inherit\"; without it the control drops the reader's ligatures and old-style figures"
        end
      end
    end
  end

  test "the ProseMirror restore rule uses the reader's font-feature-settings and no numeric variant" do
    surface = declarations(strip_comments(File.read!(@surface_css)), ".bp-paper-surface")
    reader_features = Map.fetch!(surface, "font-feature-settings")
    assert Map.get(surface, "font-variant-numeric") == nil

    for {name, css, selector} <- [
          {"bp-paper-editor-shell.css", strip_comments(File.read!(@shell_css)),
           ".bp-paper-surface .ProseMirror"},
          {"paper-editor/src/styles.css", strip_comments(File.read!(@bundle_css)), ".ProseMirror"}
        ] do
      decls = declarations(css, selector)

      assert Map.get(decls, "font-feature-settings") == reader_features,
             "#{name} #{selector}: font-feature-settings drifted from the reader's #{reader_features}"

      assert Map.get(decls, "font-variant-numeric") == nil,
             "#{name} #{selector}: declares font-variant-numeric " <>
               "#{inspect(Map.get(decls, "font-variant-numeric"))}; the reader has none, " <>
               "so every editable prose element's computed style differs from View"
    end
  end
end
