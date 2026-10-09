defmodule BarkparkWeb.StudioLocaleComponentKeysTest do
  @moduledoc """
  task-4a15ad05b70d29c7: the reference picker asked for `one_result` and
  `n_results`, and the server never sent them, so a Norwegian Studio heard
  "1 result". Every key a web component asks `_t` for must be in the map
  `StudioLocale.component_strings/1` stamps on it; a missing key reads English
  silently, so this test is the only place it shows.
  """
  use ExUnit.Case, async: false

  alias BarkparkWeb.StudioLocale

  @components [
    reference: "bp-reference-picker.js",
    media: "bp-media-picker.js",
    asset_explorer: "bp-asset-explorer.js"
  ]

  for {kind, file} <- @components do
    test "every _t key in #{file} is in component_strings(#{inspect(kind)})" do
      js = File.read!(Path.join(:code.priv_dir(:barkpark), "static/assets/#{unquote(file)}"))

      # `_t("key", …)`, and the two keys of `_count(n, "one", …, "many", …)`.
      direct = Regex.scan(~r/_t\("((?:[^"\\]|\\.)+)"/, js, capture: :all_but_first)

      counted =
        Regex.scan(~r/_count\([^,]+,\s*"([a-z0-9_]+)",\s*"[^"]*",\s*"([a-z0-9_]+)"/, js,
          capture: :all_but_first
        )

      asked = (direct ++ counted) |> List.flatten() |> Enum.uniq()

      assert asked != [], "#{unquote(file)} asks _t for nothing — the scan is broken"

      sent = unquote(kind) |> StudioLocale.component_strings() |> Jason.decode!() |> Map.keys()
      assert asked -- sent == []
    end
  end

  test "the reference picker's count and suggestions are Norwegian under nb_NO" do
    strings =
      Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fn ->
        :reference |> StudioLocale.component_strings() |> Jason.decode!()
      end)

    assert strings["one_result"] == "1 treff"
    assert strings["n_results"] == "%{count} treff"
    assert strings["recent"] == "Nylige"
    assert strings["n_docs"] == "%{count} dokumenter"
  end
end
