defmodule BarkparkWeb.Studio.TargetSizeNoShrinkTest do
  @moduledoc """
  Run-8 narrow-width pass, measured at 390px: two Studio controls sized for
  touch were squeezed below 24px by flex shrink.

    * The document actions inside `<bp-overflow-menu>` went from 32px to
      23.8px wide (Publish from 46px). They never overflowed, so the
      priority+ "•••" collapse, which waits for `scrollWidth` to pass
      `clientWidth`, never fired.
    * The desk search's clear button (`.pane-add-btn`, a 24px square) went
      to 19-21px beside the input.

  ExUnit has no layout engine, so this reads the root layout's CSS and pins
  the declarations that stop the shrink (the browser measurement is in the PR).
  """
  use ExUnit.Case, async: true

  @layout Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)

  setup_all do
    %{css: File.read!(@layout)}
  end

  for selector <- ["bp-overflow-menu > *", ".bp-desk-search .pane-add-btn"] do
    test "#{selector} does not shrink", %{css: css} do
      decls = rule!(css, unquote(selector))
      assert decls =~ ~r/(^|;)\s*flex-shrink:\s*0\s*(;|$)/, "#{unquote(selector)} { #{decls} }"
    end
  end

  test "the no-shrink rule sets no display, so the collapse still hides overflowed items", %{
    css: css
  } do
    refute rule!(css, "bp-overflow-menu > *") =~ "display"
  end

  defp rule!(css, selector) do
    pattern = ~r/(?:^|[}\s])#{Regex.escape(selector)}\s*\{([^}]*)\}/

    case Regex.run(pattern, css) do
      [_, decls] -> String.trim(decls)
      nil -> flunk("no rule for `#{selector}` in root.html.heex")
    end
  end
end
