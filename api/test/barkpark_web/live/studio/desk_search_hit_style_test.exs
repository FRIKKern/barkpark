defmodule BarkparkWeb.Studio.DeskSearchHitStyleTest do
  @moduledoc """
  Desk search hits keep their row padding.

  A hit is `<a class="pane-doc-item bp-desk-search-hit">`. Its padding rule was
  a bare `.bp-desk-search-hit`, but a LATER rule of equal specificity,
  `.pane-doc-item { padding: 0 }` (doc rows moved their padding onto an inner
  button), won the cascade: in a real browser every hit rendered at 21px, flush
  against the pane's left edge (run-4 lane C dogfood). The type="search" input
  also drew the browser's native cancel glyph beside the pane's own clear
  button — two x's.

  ExUnit has no layout engine, so this pins the source facts that decide the
  cascade.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)

  test "the hit padding rule outranks the later `.pane-doc-item { padding: 0 }`" do
    css = File.read!(@root)

    assert css =~ ~r/\.pane-doc-item \{ padding: 0; \}/,
           "premise moved: the row-padding reset is gone or reshaped"

    [rule] = Regex.run(~r/\.pane-doc-item\.bp-desk-search-hit \{[^}]*\}/, css)
    assert rule =~ ~r/padding:\s*8px 12px/, "the compound hit rule lost its padding: #{rule}"
  end

  test "the desk search input hides the native cancel glyph" do
    css = File.read!(@root)

    assert css =~
             ~r/\.bp-desk-search-input::-webkit-search-cancel-button \{[^}]*appearance:\s*none/
  end
end
