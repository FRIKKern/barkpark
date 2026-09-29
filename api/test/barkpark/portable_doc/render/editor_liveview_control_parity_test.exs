defmodule Barkpark.PortableDoc.Render.EditorLiveviewControlParityTest do
  @moduledoc """
  View↔Edit parity for the public /papers editor's OWN inline controls
  (task-cc09124c3ad48942).

  `PaperEditor.paper_block_editor/1` paints some reader text through LiveView
  controls, not through the canvas:
  - the figure caption: a paint `<button>` at rest, a `<textarea>` while typing;
  - the section title: a paint `<button>` and a `<textarea>`;
  - a contextual block's inline fields (the stage title and detail): a
    `<textarea class="bp-paper-inline-text">` inside `.bp-paper-contextual-preview`.

  The browser's stylesheet gives every button and form control
  `letter-spacing: normal`, `word-spacing: normal` and `text-rendering: auto`.
  None of those comes from `font: inherit`, so each control that did not
  inherit them explicitly drew the reader's text with different tracking or
  hinting. Reader text is `text-rendering: optimizeLegibility` and tracked
  0.005em from `.bp-paper-surface`.

  The #16092 harness and the PR #20087 control test cannot see this, because
  neither mounts these LiveView controls. The rendered proof is
  `npm run test:view-edit-parity` in api/assets/paper-editor, whose liveview
  surface renders this editor. This test pins the declarations, so a rule edit
  reds without a browser.
  """
  use ExUnit.Case, async: true

  @shell_css Path.expand(
               "../../../../priv/static/assets/bp-paper-editor-shell.css",
               __DIR__
             )

  @inherited_axes ["letter-spacing", "word-spacing", "text-rendering"]

  defp css, do: Regex.replace(~r{/\*.*?\*/}s, File.read!(@shell_css), "")

  # Every declaration of every rule whose selector is EXACTLY `selector`,
  # merged in source order, as in the cascade.
  defp declarations(selector) do
    ~r/(?:^|[}\n])\s*#{Regex.escape(selector)}\s*\{([^}]*)\}/
    |> Regex.scan(css(), capture: :all_but_first)
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

  defp assert_inherits(selector) do
    decls = declarations(selector)
    assert decls != %{}, "no rule found for #{selector} (parser sanity)"

    for axis <- @inherited_axes do
      assert Map.get(decls, axis) == "inherit",
             "#{selector}: #{axis} is #{inspect(Map.get(decls, axis))}, expected \"inherit\"; " <>
               "the browser's control default differs from the reader text"
    end
  end

  test "the figure caption at rest (the paint button) inherits the reader's tracking and rendering" do
    assert_inherits(".bp-paper-figure-caption-paint")
  end

  test "the figure caption while typing (textarea.bp-paper-figure-caption-input) inherits them" do
    assert_inherits("textarea.bp-paper-figure-caption-input")
  end

  test "the section title textarea and its paint button inherit them" do
    assert_inherits("textarea.bp-paper-inline-text.bp-paper-section-title-input")
    assert_inherits(".bp-paper-section-title-paint")
  end

  test "a contextual block's inline textarea (stage title and detail) inherits them" do
    assert_inherits(".bp-paper-contextual-preview textarea.bp-paper-inline-text")
  end
end
