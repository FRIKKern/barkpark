defmodule BarkparkWeb.Admin.PluginAdminA11yTest do
  @moduledoc """
  The axe pass over the plugin admin pages (run 8): OnixEdit staleness and
  Bokbasen, the plugin list and plugin settings had no main landmark
  (landmark-one-main + region). The plugin list jumped from its h1 to each
  card's "Callbacks implemented" h3 (heading-order).

  The Pulse and GitHub ops pages dim text with inline `opacity`, which
  multiplies down the tree. GitHub's "(github_mirror)" sat at 0.6 x 0.7 =
  0.42 (3.73:1 dark, 2.88:1 light), and Pulse's cost note at 0.55 read
  4.41:1 in the light theme. Ink at opacity `a` over the ground clears 4.5:1
  from a = 0.56 in light (#09090b on #fff) and 0.48 in dark (#f2f2f2 on
  #09090b), so 0.56 is the floor for any text.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth

  @token "plugin-admin-a11y-token"
  @opacity_floor 0.56

  setup do
    {:ok, _} = Auth.create_token(@token, "a11y admin", "production", ["read", "write", "admin"])
    %{conn: build_conn() |> init_test_session(%{"api_token" => @token})}
  end

  @pages [
    "/admin/onixedit/staleness",
    "/admin/onixedit/bokbasen",
    "/admin/github",
    "/admin/pulse",
    "/w/default/p/default/d/production/studio/_plugins",
    "/w/default/p/default/d/production/studio/_plugins/onixedit/settings"
  ]

  for path <- @pages do
    test "#{path} has exactly one main landmark", %{conn: conn} do
      {:ok, view, _html} = live(conn, unquote(path))
      assert count(render(view), "main") == 1
    end
  end

  test "each plugin card titles itself with an h2 above its h3", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/w/default/p/default/d/production/studio/_plugins")
    html = render(view)
    cards = count(html, "section.bp-plugin-card")

    assert cards > 0
    assert count(html, "section.bp-plugin-card h2.bp-plugin-card-title") == cards
    assert count(html, "section.bp-plugin-card h3") == cards
  end

  for path <- ["/admin/github", "/admin/pulse"] do
    test "#{path}: no text is dimmed below #{@opacity_floor}", %{conn: conn} do
      {:ok, view, _html} = live(conn, unquote(path))

      dim =
        render(view)
        |> LazyHTML.from_fragment()
        |> LazyHTML.to_tree()
        |> text_opacities(1.0)
        |> Enum.filter(fn {op, _text} -> op < @opacity_floor end)

      assert dim == [], "text below the opacity floor: #{inspect(dim)}"
    end
  end

  defp count(html, selector),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()

  # Every non-blank text node with the opacity it renders at: inline
  # `opacity` multiplies down the tree.
  defp text_opacities(nodes, op) when is_list(nodes),
    do: Enum.flat_map(nodes, &text_opacities(&1, op))

  defp text_opacities({_tag, attrs, children}, op) do
    style = attrs |> List.keyfind("style", 0, {"style", ""}) |> elem(1)

    own =
      case Regex.run(~r/(?:^|[;\s])opacity:\s*([\d.]+)/, style) do
        [_, v] -> v |> Float.parse() |> elem(0)
        nil -> 1.0
      end

    text_opacities(children, op * own)
  end

  defp text_opacities(text, op) when is_binary(text) do
    if String.trim(text) == "", do: [], else: [{Float.round(op, 3), String.trim(text)}]
  end

  defp text_opacities(_other, _op), do: []
end
