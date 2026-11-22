defmodule BarkparkWeb.Studio.ClashWordsTest do
  @moduledoc """
  task-c0374ce0961cc1bf: a conflict that names the fields another editor
  rewrote says so in TanStack's words (barkpark-studio `edits.ts` `clash`,
  `i18n/nb/document.ts`), the fields by title in the schema's order. A
  conflict that keeps the whole buffer names none and keeps its token.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.RefusedSave

  @schema %{
    fields: [
      %{"name" => "title", "title" => "Title"},
      %{"name" => "excerpt", "title" => "Excerpt"},
      %{"name" => "slug"}
    ]
  }

  defp conflict(keys),
    do: %{
      save_status: "Updated by another user",
      doc_conflict: true,
      editor_clash_fields: keys,
      editor_schema: @schema
    }

  test "the rewritten fields by title, in the schema's order" do
    assert RefusedSave.status(conflict(["slug", "excerpt", "title"])) ==
             "Someone else rewrote Title, Excerpt, slug meanwhile. Your text is kept here, " <>
               "not saved: type on to save yours over theirs."
  end

  test "in nb_NO, TanStack's Norwegian" do
    Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fn ->
      assert RefusedSave.status(conflict(["excerpt"])) ==
               "Noen andre skrev om Excerpt i mellomtiden. Teksten din er tatt vare på her, " <>
                 "ikke lagret: skriv videre for å lagre din over deres."
    end)
  end

  test "no fields named, or no conflict standing: the token" do
    assert RefusedSave.status(conflict([])) == "Updated by another user"

    assert RefusedSave.status(%{conflict(["title"]) | doc_conflict: false}) ==
             "Updated by another user"

    assert RefusedSave.status(%{conflict(["title"]) | save_status: "Saved"}) == "Saved"
  end
end
