defmodule BarkparkWeb.GettextSlotBindingsTest do
  @moduledoc """
  task-a11f0a686ad04644: a `gettext` call whose msgid carries a `%{slot}` but
  passes no binding for it logs `missing Gettext bindings` at error level on
  every call. The paper canvas strings did it three times per mount in an nb
  Studio, and the paper reader layout once per render. A string map that hands
  a slot on to the browser passes it through (`n: "%{n}"`).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @lib Path.expand("../../lib", __DIR__)

  # A single-line call with a slot in its msgid and nothing after it.
  @unbound ~r/\b(?:gettext|pgettext|dgettext)\((?:"[^"]*",\s*)?"[^"]*%\{\w+\}[^"]*"\)/

  test "no gettext call in lib passes a %{slot} without a binding" do
    hits =
      for ext <- ["ex", "heex", "eex"],
          file <- Path.wildcard(Path.join(@lib, "**/*.#{ext}")),
          {line, n} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          Regex.match?(@unbound, line),
          do: "#{Path.relative_to(file, @lib)}:#{n}"

    assert hits == [], "gettext with an unbound slot:\n" <> Enum.join(hits, "\n")
  end

  test "the nb paper canvas strings log no missing bindings and keep their slots" do
    {strings, log} =
      with_log(fn ->
        Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fn ->
          BarkparkWeb.StudioLocale.component_strings(:paper_canvas)
        end)
      end)

    # The map is stamped as JSON on the canvas host.
    strings = Jason.decode!(strings)

    refute log =~ "missing Gettext bindings"
    assert strings["Option %{n} label"] =~ "%{n}"
    assert strings["Remove option %{n}"] =~ "%{n}"
  end
end
