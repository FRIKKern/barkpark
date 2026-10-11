defmodule BarkparkWeb.GettextNbCompletenessTest do
  @moduledoc """
  The Norwegian catalogs only get more complete (run 8, nb completeness).

  Measured at the start: `nb_NO/default.po` had 2288 entries, none empty, none
  fuzzy, and none missing from `default.pot`; a fresh `mix gettext.extract`
  added no msgid. The gap was `nb_NO/errors.po`: all 24 of Ecto's changeset
  messages empty (9 plural), and Studio never asked that domain anyway, so a
  Norwegian author read "slug has already been taken".

  The ratchet counts nb entries with an empty msgstr (any plural form) or a
  `fuzzy` flag. Surfaces ruled English (Tasks, Tickets, Pulse, the API tester)
  are left out when EVERY reference of an entry points into one of them. The
  ceiling only comes down: a count above it reds, and so does one below it,
  so the record is lowered in the same change that earns it.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Shared

  @ceiling 0
  @gettext Path.expand("../../priv/gettext", __DIR__)
  @english_ruled ~r{plugins/tickets|tickets_live|/tickets|plugins/pulse|pulse/|api_tester|plugins/tasks|tasks_live|task_board|/tasks/}i

  defp gaps(%Expo.Messages{messages: messages}) do
    Enum.filter(messages, fn msg ->
      (untranslated?(msg) or Expo.Message.has_flag?(msg, "fuzzy")) and not english_ruled?(msg)
    end)
  end

  defp untranslated?(%Expo.Message.Singular{msgstr: msgstr}),
    do: IO.iodata_to_binary(msgstr) == ""

  defp untranslated?(%Expo.Message.Plural{msgstr: forms}),
    do: Enum.any?(forms, fn {_n, s} -> IO.iodata_to_binary(s) == "" end)

  defp english_ruled?(msg) do
    refs = msg.references |> List.flatten() |> Enum.map(&reference_path/1)
    refs != [] and Enum.all?(refs, &Regex.match?(@english_ruled, &1))
  end

  defp reference_path({path, _line}), do: path
  defp reference_path(path) when is_binary(path), do: path

  defp catalog(domain),
    do: Expo.PO.parse_file!(Path.join(@gettext, "nb_NO/LC_MESSAGES/#{domain}.po"))

  defp key(msg),
    do: {msg.msgctxt && IO.iodata_to_binary(msg.msgctxt), IO.iodata_to_binary(msg.msgid)}

  test "the nb gap count is at its ceiling, and only comes down" do
    found = Enum.flat_map(["default", "errors"], &gaps(catalog(&1)))
    ids = Enum.map(found, &IO.iodata_to_binary(&1.msgid))

    assert length(found) <= @ceiling,
           "#{length(found)} nb entries are empty or fuzzy (ceiling #{@ceiling}): #{inspect(Enum.take(ids, 10))}"

    assert length(found) >= @ceiling,
           "the nb gap count fell to #{length(found)}; lower @ceiling to it in this change"
  end

  test "every msgid in the templates has an nb entry" do
    for domain <- ["default", "errors"] do
      pot = Expo.PO.parse_file!(Path.join(@gettext, "#{domain}.pot"))
      nb = catalog(domain) |> Map.get(:messages) |> MapSet.new(&key/1)
      missing = for msg <- pot.messages, not MapSet.member?(nb, key(msg)), do: key(msg)

      assert missing == [],
             "#{domain}.pot msgids with no nb entry: #{inspect(Enum.take(missing, 10))}"
    end
  end

  # The counter is not vacuous: on a catalog that has them, it finds the empty
  # and the fuzzy entry and leaves out the one only an English-ruled surface uses.
  test "control: the counter sees an empty and a fuzzy entry, and skips an English-ruled one" do
    po =
      Expo.PO.parse_string!("""
      #: lib/barkpark_web/live/studio/settings_live.ex
      msgid "Empty"
      msgstr ""

      #: lib/barkpark_web/live/studio/settings_live.ex
      #, fuzzy
      msgid "Fuzzy"
      msgstr "Uklar"

      #: lib/barkpark_web/live/studio/settings_live.ex
      msgid "%{count} item"
      msgid_plural "%{count} items"
      msgstr[0] "%{count} element"
      msgstr[1] ""

      #: lib/barkpark/plugins/tickets/web/inbox_live.ex
      msgid "Ticket only"
      msgstr ""

      #: lib/barkpark_web/live/studio/settings_live.ex
      msgid "Done"
      msgstr "Ferdig"
      """)

    assert po |> gaps() |> Enum.map(&IO.iodata_to_binary(&1.msgid)) == [
             "Empty",
             "Fuzzy",
             "%{count} item"
           ]
  end

  describe "Studio shows changeset errors in the workspace language" do
    test "Ecto's messages, singular and plural, read Norwegian" do
      Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fn ->
        assert Shared.translate_changeset_error({"can't be blank", [validation: :required]}) ==
                 "må fylles ut"

        min =
          {"should be at least %{count} character(s)",
           [count: 3, validation: :length, kind: :min, type: :string]}

        assert Shared.translate_changeset_error(min) == "skal være minst 3 tegn"

        one =
          {"should have at least %{count} item(s)",
           [count: 1, validation: :length, kind: :min, type: :list]}

        two =
          {"should have at least %{count} item(s)",
           [count: 2, validation: :length, kind: :min, type: :list]}

        assert Shared.translate_changeset_error(one) == "skal ha minst 1 element"
        assert Shared.translate_changeset_error(two) == "skal ha minst 2 elementer"

        assert Shared.translate_changeset_error({"must be our own words", []}) ==
                 "must be our own words",
               "a message no catalog carries comes back as written"
      end)
    end

    test "the create flash names the thing and the field's error in Norwegian" do
      changeset =
        {%{}, %{slug: :string}}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:slug, "has already been taken", validation: :unsafe_unique)

      Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fn ->
        assert Shared.create_error(changeset, "workspace") ==
                 "Kunne ikke opprette arbeidsområde: slug er allerede i bruk"

        assert Shared.create_error(:nope, "project") == "Kunne ikke opprette prosjekt"

        blank =
          {%{}, %{name: :string}}
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.validate_required([:name])

        assert Shared.create_error(blank, "project") ==
                 "Kunne ikke opprette prosjekt: navn må fylles ut"
      end)

      Gettext.with_locale(BarkparkWeb.Gettext, "en", fn ->
        assert Shared.create_error(changeset, "workspace") ==
                 "Could not create workspace: slug has already been taken"
      end)
    end
  end
end
