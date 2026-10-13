defmodule BarkparkWeb.Studio.ExplicitThemeStatusTest do
  @moduledoc """
  task-9dfa7ee60e6b0589: Studio's status hues followed the OS, not the theme the
  user picked. The light values sat in `:root` and the dark ones only under
  `@media (prefers-color-scheme: dark)`, and neither explicit theme re-declared
  them, so light theme on a dark-mode OS painted the dark amber on a light page
  (draft badge 1.69:1). The Studio block now has paper-surface's four-block
  shape: bare light, prefers-dark, explicit light, explicit dark. The explicit
  theme wins over the OS in both directions.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)

  # The generated Studio tokens region of the root layout.
  defp studio_tokens do
    css = File.read!(@root)
    [_, region] = Regex.run(~r/BEGIN GENERATED: tokens[^\n]*\n(.*?)END GENERATED: tokens/s, css)
    region
  end

  # The declarations of the first rule whose selector is exactly `selector`.
  defp block(region, selector) do
    pattern = ~r/(?:^|\n)\s*#{Regex.escape(selector)}\s*\{([^}]*)\}/

    case Regex.run(pattern, region, capture: :all_but_first) do
      [body] -> body
      nil -> flunk("no `#{selector} { … }` rule in the Studio tokens region")
    end
  end

  defp value(body, var) do
    case Regex.run(~r/#{Regex.escape(var)}:\s*([^;]+);/, body, capture: :all_but_first) do
      [v] -> String.trim(v)
      nil -> nil
    end
  end

  @status ~w(--warn-hsl --ok-hsl --danger-hsl --info-hsl --warn-text)

  test "an explicit light theme re-declares every status value at its light value" do
    region = studio_tokens()
    bare = block(region, ":root")
    light = block(region, ~s(html[data-theme="light"]))

    for var <- @status do
      assert value(light, var) != nil, "html[data-theme=light] does not declare #{var}"

      assert value(light, var) == value(bare, var),
             "#{var} under explicit light differs from the bare light value"
    end
  end

  test "an explicit dark theme declares every status value at its dark value" do
    region = studio_tokens()
    dark = block(region, ~s(html[data-theme="dark"]))

    [media] =
      Regex.run(~r/@media \(prefers-color-scheme: dark\)\s*\{\s*:root\s*\{([^}]*)\}/, region,
        capture: :all_but_first
      )

    for var <- @status do
      assert value(dark, var) != nil, "html[data-theme=dark] does not declare #{var}"

      assert value(dark, var) == value(media, var),
             "#{var} under explicit dark differs from the prefers-dark value"
    end

    # The two directions really differ, or this test proves nothing.
    assert value(dark, "--warn-hsl") != value(block(region, ":root"), "--warn-hsl")
  end
end
