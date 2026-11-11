defmodule BarkparkWeb.Studio.DeskLocaleTest do
  @moduledoc """
  B01: every desk string reads in Norwegian.

  The desk's strings were never extracted, so `default.pot` did not hold
  them and `GettextNbCompletenessTest` (which reads the template) could not
  see them: 19 of the desk's 34 msgids read in English in a Norwegian
  workspace. This test reads the msgids from the desk's own source files,
  so a new desk string with no nb translation reds here.
  """
  use ExUnit.Case, async: false

  @api Path.expand("../../../..", __DIR__)
  @nb Path.join(@api, "priv/gettext/nb_NO/LC_MESSAGES/default.po")

  defp sources do
    [Path.join(@api, "lib/barkpark_web/live/studio/desk_live.ex")] ++
      Path.wildcard(Path.join(@api, "lib/barkpark_web/live/studio/desk/*.ex")) ++
      Path.wildcard(Path.join(@api, "lib/barkpark_web/studio/desk/*.ex"))
  end

  # `gettext("…"` and `dgettext("default", "…"` calls with a literal msgid.
  defp msgids do
    for path <- sources(),
        [_, id] <- Regex.scan(~r/\bgettext\(\s*"((?:[^"\\]|\\.)*)"/, File.read!(path)),
        uniq: true,
        do: id
  end

  defp nb_catalog do
    for %Expo.Message.Singular{} = msg <- Expo.PO.parse_file!(@nb).messages,
        msg.msgctxt == nil,
        into: %{},
        do: {IO.iodata_to_binary(msg.msgid), msg}
  end

  test "the scan reads the desk's strings (not vacuous)" do
    ids = msgids()
    assert length(ids) >= 30, "only #{length(ids)} desk msgids found: #{inspect(ids)}"
    assert "Search list" in ids
    assert "This pane could not be read." in ids
  end

  test "every desk msgid has a non-empty, non-fuzzy nb translation" do
    catalog = nb_catalog()

    gaps =
      Enum.filter(msgids(), fn id ->
        case catalog[id] do
          nil -> true
          msg -> IO.iodata_to_binary(msg.msgstr) == "" or Expo.Message.has_flag?(msg, "fuzzy")
        end
      end)

    assert gaps == [], "desk strings with no nb translation: #{inspect(gaps)}"
  end

  test "the compiled catalog answers in Norwegian for the desk" do
    Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fn ->
      assert Gettext.gettext(BarkparkWeb.Gettext, "Search list") == "Søk i listen"

      assert Gettext.gettext(BarkparkWeb.Gettext, "This pane could not be read.") ==
               "Ruten kunne ikke leses."

      assert Gettext.gettext(BarkparkWeb.Gettext, "Close %{title}", title: "Post") ==
               "Lukk Post"
    end)
  end
end
