defmodule BarkparkWeb.Components.StudioLiteralStringsLocaleTest do
  @moduledoc """
  task-9e08ea33f42039db: an antologi document in an nb-NO workspace showed
  "Select…" as its select placeholder and "No color" beside its colour picker,
  and the doc-conflict banner read "Updated by another user … Reload". They
  were literal English in the templates. They now read in the Studio language,
  and English reads exactly as before.
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Components.FieldInputs
  alias BarkparkWeb.StudioComponents.Editor

  defp in_locale(locale, fun), do: Gettext.with_locale(BarkparkWeb.Gettext, locale, fun)

  defp select(locale) do
    in_locale(locale, fn ->
      render_component(&FieldInputs.input/1,
        field: %{"type" => "select", "name" => "sjanger", "options" => ["dikt", "prosa"]},
        editor_form: %{}
      )
    end)
  end

  defp color(locale, form) do
    in_locale(locale, fn ->
      render_component(&FieldInputs.input/1,
        field: %{"type" => "color", "name" => "farge"},
        editor_form: form
      )
    end)
  end

  defp conflict(locale) do
    in_locale(locale, fn -> render_component(&Editor.doc_conflict_banner/1, conflict: true) end)
  end

  # A string field handed a structured stored value renders read-only with a note.
  defp structured(locale) do
    in_locale(locale, fn ->
      render_component(&FieldInputs.input/1,
        field: %{"type" => "string", "name" => "slug"},
        editor_form: %{"slug" => %{"current" => "x"}}
      )
    end)
  end

  test "the read-only structured-value note reads in the Studio language" do
    assert structured("nb_NO") =~ "skrivebeskyttet — lagret som strukturerte data"

    assert structured("en") =~
             "read-only — stored as structured data this field&#39;s editor cannot show; saved unchanged"
  end

  test "the select placeholder, colour field and conflict banner read Norwegian under nb_NO" do
    assert select("nb_NO") =~ "Velg…"
    refute select("nb_NO") =~ "Select…"
    assert color("nb_NO", %{}) =~ "Ingen farge"
    assert color("nb_NO", %{"farge" => "#ff0000"}) =~ "Tøm"
    assert conflict("nb_NO") =~ "Oppdatert av en annen bruker"
    assert conflict("nb_NO") =~ "Last inn på nytt"
  end

  test "English reads as before" do
    assert select("en") =~ ~s(>Select…</option>)
    assert color("en", %{}) =~ "No color"
    assert color("en", %{"farge" => "#ff0000"}) =~ ">Clear</button>"
    assert conflict("en") =~ "Updated by another user — your unsaved edits are kept."
    assert conflict("en") =~ ">Reload</button>"
  end
end
