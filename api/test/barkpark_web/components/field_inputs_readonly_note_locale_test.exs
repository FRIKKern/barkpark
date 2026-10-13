defmodule BarkparkWeb.Components.FieldInputsReadonlyNoteLocaleTest do
  @moduledoc """
  task-1f3513bed827fc3a: a legacy array/object field renders read-only in the
  classic editor with a note saying so. The note was English in a Norwegian
  Studio.
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Components.FieldInputs

  defp note_html(locale) do
    Gettext.with_locale(BarkparkWeb.Gettext, locale, fn ->
      render_component(&FieldInputs.input/1,
        field: %{"type" => "array", "name" => "tags"},
        editor_form: %{"tags" => ["a", "b"]}
      )
    end)
  end

  test "the read-only note reads in the Studio language" do
    assert note_html("nb_NO") =~ "skrivebeskyttet — styres via API-et"
    assert note_html("en") =~ "read-only — managed via API"
  end
end
