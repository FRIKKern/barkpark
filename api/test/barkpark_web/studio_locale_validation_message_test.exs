defmodule BarkparkWeb.StudioLocaleValidationMessageTest do
  @moduledoc """
  Gyldendal parity E7 follow-up (friction #87): the kernel validator's English
  message keys become the workspace's language at the Studio assign, and
  everything it does not recognise — a schema's own `message`, an odd string —
  passes through untouched. The default locale is byte-identical to before.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.StudioLocale

  defp nb(fun), do: Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fun)

  test "the default locale leaves every key as it was" do
    for msg <- [
          "Required",
          "Must be at least 3 characters",
          "Must be at most 300 characters",
          "Must be at least 1",
          "Must be at most 9.5",
          "Does not match required format",
          "Beskrivelsen bør være under 300 tegn."
        ] do
      assert StudioLocale.validation_message(msg) == msg
    end
  end

  test "nb_NO translates the validator's keys with their bounds" do
    nb(fn ->
      assert StudioLocale.validation_message("Required") == "Påkrevd"

      assert StudioLocale.validation_message("Must be at least 3 characters") ==
               "Må være minst 3 tegn"

      assert StudioLocale.validation_message("Must be at most 300 characters") ==
               "Kan være høyst 300 tegn"

      assert StudioLocale.validation_message("Must be at least 1") == "Må være minst 1"
      assert StudioLocale.validation_message("Must be at most 9.5") == "Kan være høyst 9.5"

      assert StudioLocale.validation_message("Does not match required format") ==
               "Har ikke riktig format"
    end)
  end

  test "a schema's own message and unknown strings pass through verbatim" do
    nb(fn ->
      assert StudioLocale.validation_message("Beskrivelsen bør være under 300 tegn.") ==
               "Beskrivelsen bør være under 300 tegn."

      assert StudioLocale.validation_message("Must be at most many characters") ==
               "Must be at most many characters"

      assert StudioLocale.validation_message(nil) == nil
    end)
  end

  test "the flat envelope's pointer form keeps its path and translates the tail" do
    nb(fn ->
      assert StudioLocale.validation_message("/banners/0/title: Required") ==
               "/banners/0/title: Påkrevd"
    end)
  end

  test "localize_findings walks the check_tree shape and keeps it" do
    tree = %{
      "title" => ["Required"],
      "banners" => %{1 => %{"title" => ["Required"]}, __self__: ["Must be at most 3"]},
      "seo" => %{"description" => ["Beskrivelsen bør være under 300 tegn."]}
    }

    nb(fn ->
      assert StudioLocale.localize_findings(tree) == %{
               "title" => ["Påkrevd"],
               "banners" => %{1 => %{"title" => ["Påkrevd"]}, __self__: ["Kan være høyst 3"]},
               "seo" => %{"description" => ["Beskrivelsen bør være under 300 tegn."]}
             }
    end)

    assert StudioLocale.localize_findings(%{}) == %{}
    assert StudioLocale.localize_findings(tree) == tree
  end
end
