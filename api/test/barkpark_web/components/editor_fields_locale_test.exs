defmodule BarkparkWeb.StudioComponents.EditorFieldsLocaleTest do
  @moduledoc """
  task-882187e316940726: a member of a Norwegian workspace saw another editor's
  presence avatar as "Jump to Kari — editing Fjellsanger" / "Click to jump
  there". The same component file renders the bulk action bar and the
  secondary "Open in new pane" card, all in English. They now read in the
  Studio language.
  """
  use Barkpark.DataCase, async: false

  import Phoenix.LiveViewTest

  alias BarkparkWeb.StudioComponents.EditorFields

  defp in_locale(locale, fun), do: Gettext.with_locale(BarkparkWeb.Gettext, locale, fun)

  defp presence(locale) do
    in_locale(locale, fn ->
      render_component(&EditorFields.presence_nav/1,
        user_id: "me",
        user_name: "Me",
        user_color: "#000",
        dataset: "production",
        presences: [
          %{user_id: "kari", name: "Kari", color: "#f00", type: "post", doc_id: "missing-doc"},
          %{user_id: "ola", name: "Ola", color: "#0f0", type: nil, doc_id: nil}
        ]
      )
    end)
  end

  defp bulk(locale) do
    in_locale(locale, fn ->
      render_component(&EditorFields.bulk_action_bar/1,
        selected_doc_ids: MapSet.new(["a", "b"]),
        admin?: true
      )
    end)
  end

  defp secondary(locale) do
    in_locale(locale, fn ->
      render_component(&EditorFields.secondary_editor_card/1,
        secondary_doc: %{doc_id: "drafts.x", title: nil, status: "draft", content: %{}},
        secondary_schema: %{"fields" => []},
        secondary_type: "post"
      )
    end)
  end

  test "presence reads Norwegian under nb_NO" do
    html = presence("nb_NO")
    assert html =~ "Gå til Kari — redigerer missing-doc"
    assert html =~ "Klikk for å gå dit"
    assert html =~ "blar"
    refute html =~ "Click to jump there"
  end

  test "the bulk bar and the secondary card read Norwegian under nb_NO" do
    bulk = bulk("nb_NO")
    assert bulk =~ ~s(aria-label="Massehandlinger")
    assert bulk =~ "2 valgt"
    assert bulk =~ "Publiser valgte"

    card = secondary("nb_NO")
    assert card =~ "Uten tittel"
    assert card =~ ~s(aria-label="Lukk sideruten")
    assert card =~ "Skrivebeskyttet — rediger i hovedruten."
  end

  test "English reads as before" do
    assert presence("en") =~ "Jump to Kari — editing missing-doc"
    assert bulk("en") =~ "Publish selected"
    assert secondary("en") =~ "Read-only — edit via primary pane."
  end
end
