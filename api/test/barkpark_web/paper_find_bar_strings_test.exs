defmodule BarkparkWeb.PaperFindBarStringsTest do
  @moduledoc """
  The find bar's words (bp-paper-find-bar.js, task-c1bf7f10239f73bf) come from
  `StudioLocale.component_strings(:paper_hooks)`, keyed by the English text the
  bar falls back to. A word the bar asks for that the map lacks would stay
  English in a Norwegian Studio without any error, so this reads the words out
  of the script and looks each one up.
  """
  use ExUnit.Case, async: false

  alias BarkparkWeb.StudioLocale

  @script Path.join(:code.priv_dir(:barkpark), "static/assets/bp-paper-find-bar.js")

  setup do
    on_exit(fn -> Gettext.put_locale(BarkparkWeb.Gettext, "en") end)
  end

  defp asked do
    ~r/(?<![\w.])t\("([^"]+)"/
    |> Regex.scan(File.read!(@script), capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  test "every word the bar asks for is in the map, and is Norwegian in a Norwegian Studio" do
    words = asked()
    assert length(words) >= 12, "the scan found only #{length(words)} words: #{inspect(words)}"

    Gettext.put_locale(BarkparkWeb.Gettext, "nb_NO")
    nb = Jason.decode!(StudioLocale.component_strings(:paper_hooks))

    for word <- words do
      assert is_binary(nb[word]), "the map has no #{inspect(word)}"
      assert nb[word] != word, "#{inspect(word)} is not translated to Norwegian"
    end

    assert nb["%{index} of %{count}"] == "%{index} av %{count}"
    assert nb["Replaced %{count}"] == "Erstattet %{count}"
  end

  test "the Studio layout loads the bar without holding the page" do
    root = File.read!("lib/barkpark_web/layouts/root.html.heex")

    assert root =~
             ~s|<script src={BarkparkWeb.StaticAssets.path("bp-paper-find-bar.js")} async></script>|
  end
end
