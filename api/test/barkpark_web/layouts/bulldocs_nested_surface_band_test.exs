defmodule BarkparkWeb.Layouts.BulldocsNestedSurfaceBandTest do
  @moduledoc """
  The article shell widens the evidence stage (`--bp-evidence-band` and
  friends) on `.bp-paper-shell.bp-paper-article`. Edit mode paints each
  read-only canvas block's reader HTML inside its OWN `.bp-paper-surface`,
  which re-declares the shared default band (1040px) — so a breakout block such
  as the August Chronicle's lineage painted 1040px wide in Edit and 1180px in
  View, re-wrapping every entry. The nested-surface rule carries the article's
  stage into those holes; this pins the pair so the two can never drift apart.
  """
  use ExUnit.Case, async: true

  @layout Path.expand("../../../lib/barkpark_web/layouts/bulldocs.html.heex", __DIR__)
  @tokens ~w(--bp-evidence-band --bp-evidence-band-max --bp-evidence-fill)

  defp rule_body(css, selector) do
    case Regex.run(~r/(?:^|\n)\s*#{Regex.escape(selector)}\s*\{([^}]*)\}/, css) do
      [_, body] -> body
      _ -> flunk("no `#{selector} { … }` rule in bulldocs.html.heex")
    end
  end

  defp decls(body) do
    for token <- @tokens, into: %{} do
      case Regex.run(~r/#{Regex.escape(token)}\s*:\s*([^;]+);/, body) do
        [_, value] -> {token, String.trim(value)}
        _ -> {token, nil}
      end
    end
  end

  test "surfaces nested in the article carry the article's evidence stage" do
    css = File.read!(@layout)
    shell = css |> rule_body(".bp-paper-shell.bp-paper-article") |> decls()
    nested = css |> rule_body(".bp-paper-shell.bp-paper-article .bp-paper-surface") |> decls()

    assert Enum.all?(Map.values(shell), &is_binary/1),
           "article shell lost a band token: #{inspect(shell)}"

    assert nested == shell
  end
end
