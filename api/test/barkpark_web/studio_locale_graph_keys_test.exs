defmodule BarkparkWeb.StudioLocaleGraphKeysTest do
  @moduledoc """
  task-d1c2ef3924bde715: the Studio graph pane, the rich-text toolbar and the
  document preview rendered their words in English in a Norwegian Studio. Each
  now looks its words up in a map the server stamps on it, keyed by the English;
  a word the component asks for that the map does not carry reads English
  silently, so this test pins every one.
  """
  use ExUnit.Case, async: false

  alias BarkparkWeb.StudioLocale

  # {map, file, the component's lookup helper}
  @components [
    {:graph, "bp-graph.js", ~r/\bgt\("((?:[^"\\]|\\.)+)"/},
    {:rich_text, "bp-rich-text-editor.js", ~r/\bt\("((?:[^"\\]|\\.)+)"\)/},
    {:document_preview, "bp-document-preview.js", ~r/this\._t\("((?:[^"\\]|\\.)+)"\)/}
  ]

  for {kind, file, helper} <- @components do
    test "every word #{file} looks up is in component_strings(#{inspect(kind)})" do
      js = File.read!(Path.join(:code.priv_dir(:barkpark), "static/assets/#{unquote(file)}"))

      asked =
        unquote(Macro.escape(helper))
        |> Regex.scan(js, capture: :all_but_first)
        |> List.flatten()
        |> Enum.map(&String.replace(&1, ~s(\\"), ~s(")))
        |> Enum.uniq()

      assert length(asked) > 3, "#{unquote(file)} looks up almost nothing — the scan is broken"

      sent = unquote(kind) |> StudioLocale.component_strings() |> Jason.decode!() |> Map.keys()
      assert asked -- sent == []
    end
  end

  test "the maps read Norwegian under nb_NO and English otherwise" do
    nb = fn kind ->
      Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fn ->
        kind |> StudioLocale.component_strings() |> Jason.decode!()
      end)
    end

    assert nb.(:graph)["No connections yet"] == "Ingen koblinger ennå"
    assert nb.(:graph)["%{count} connections"] == "%{count} koblinger"
    assert nb.(:rich_text)["Remove"] == "Fjern"
    assert nb.(:document_preview)["No document selected"] == "Ingen dokument valgt"

    en =
      Gettext.with_locale(BarkparkWeb.Gettext, "en", fn ->
        :graph |> StudioLocale.component_strings() |> Jason.decode!()
      end)

    assert en["No connections yet"] == "No connections yet"
  end
end
