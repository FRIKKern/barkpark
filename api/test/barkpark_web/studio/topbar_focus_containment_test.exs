defmodule BarkparkWeb.Studio.TopbarFocusContainmentTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)

  # Source tripwires, not pixel evidence. Chrome reproduces the failure by
  # focusing Theme: shell.scrollLeft becomes 100 and the Paper x becomes -100.
  # Wrapping must remove the overflow, not clip controls or the scope popover.
  test "narrow and phone top bars wrap without creating a clipping ancestor" do
    source = File.read!(@root) |> then(&Regex.replace(~r|/\*.*?\*/|s, &1, ""))

    for bucket <- ["narrow", "phone"] do
      selector = ~s|html[data-width-bucket="#{bucket}"] .studio-bar|
      bar = rule!(source, selector)
      assert bar =~ "display: flex;"
      assert bar =~ "flex-wrap: wrap;"
      assert bar =~ "height: auto;"
      assert bar =~ "flex-shrink: 0;"
      refute bar =~ "overflow"

      for group <- [".studio-bar-tabs", ".studio-bar-right", ".studio-bar-actions"] do
        body = rule!(source, ~s|html[data-width-bucket="#{bucket}"] #{group}|)
        assert body =~ "flex-wrap: wrap;"
        assert body =~ "max-width: 100%;"
      end
    end
  end

  test "the default desktop top bar retains its centered three-column grid" do
    body = rule!(File.read!(@root), ".studio-bar")
    assert body =~ "height: 48px;"
    assert body =~ "display: grid;"
    assert body =~ "grid-template-columns: 1fr auto 1fr;"
    assert body =~ "gap: 24px;"
  end

  test "the narrow workspace menu owns its overflowing Miller columns" do
    for bucket <- ["narrow", "phone"] do
      selector = ~s|html[data-width-bucket="#{bucket}"] .scope-menu|
      menu = rule!(File.read!(@root), selector)
      assert menu =~ "overflow-x: auto;"
      assert menu =~ "flex-wrap: wrap;"
      assert menu =~ "max-height: calc(100vh - 80px);"

      column = rule!(File.read!(@root), selector <> "-col")
      assert column =~ "flex: 1 1 160px;"
      assert column =~ "max-width: 100%;"
    end
  end

  defp rule!(source, selector) do
    # Match each comma-list member independently, never a substring of a
    # bucket selector. Missing rules fail loudly rather than testing nil.
    pattern = ~r/(?:^|\n)\s*#{Regex.escape(selector)}\s*(?:,\s*[^{}]+)?\{([^{}]*)\}/
    assert [_, body] = Regex.run(pattern, source), "missing CSS rule: #{selector}"
    body
  end
end
