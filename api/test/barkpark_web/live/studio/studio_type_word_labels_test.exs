defmodule BarkparkWeb.Studio.StudioTypeWordLabelsTest do
  @moduledoc """
  task-6dfc55e961ffa137 — Studio copy names a multi-word type as words.

  The pane buttons read "New form_submission" / "Share access to
  form_submission", and an untitled row "Untitled form_submission · <tail>":
  the raw schema name. Schema titles cannot stand in (some are plural), so
  one humanizer, `PaneBuilder.type_word/1`, turns `_`/`-` into spaces.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content, TenancyFixtures}
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "production"
  @admin "type-word-admin"
  @type_name "field_note"

  test "type_word turns underscores and hyphens into spaces, and leaves one word alone" do
    assert PaneBuilder.type_word("form_submission") == "form submission"
    assert PaneBuilder.type_word("press-release") == "press release"
    assert PaneBuilder.type_word("ticket") == "ticket"
  end

  test "an untitled row is named in words" do
    doc = %{title: nil, doc_id: "drafts.field_note-4e956da749327770", type: @type_name}
    assert PaneBuilder.display_title(doc) == "Untitled field note · 4e956da749327770"
  end

  test "the list pane's New and Share access buttons name the type in words", %{conn: conn} do
    {_ws, _proj} = TenancyFixtures.ensure_default_scope!()

    {:ok, _} =
      Auth.create_token(
        @admin,
        "type word admin",
        @dataset,
        ["read", "write", "admin"],
        TenancyFixtures.default_workspace_id!()
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Field notes",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, view, _html} =
      conn
      |> Plug.Test.init_test_session(%{"api_token" => @admin})
      |> live(scoped_studio("/d/#{@dataset}/studio/#{@type_name}"))

    assert has_element?(view, ~s(button[aria-label="New field note"]))
    refute has_element?(view, ~s(button[aria-label="New field_note"]))

    assert has_element?(view, ~s(button[aria-label="Share access to field note"]))
  end
end
