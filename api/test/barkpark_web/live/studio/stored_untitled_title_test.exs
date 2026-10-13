defmodule BarkparkWeb.Studio.StoredUntitledTitleTest do
  @moduledoc """
  task-75c3d1234335d10f: documents created before task-79e28148d9925097 store
  the literal English "Untitled" in their title column. The list pane already
  treats it as unnamed, but the tab title and the document header showed the
  stored word, so a Norwegian Studio read "Untitled · Barkpark". Each surface
  now falls through to its localized fallback; a real title still shows.

  `async: false`: the test puts the default workspace in nb-NO.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.DocTitle

  @dataset "production"

  setup do
    raw = "stored-untitled-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Barkpark.Auth.create_token(
        raw,
        "stored-untitled",
        @dataset,
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    {:ok, _} =
      Barkpark.Tenancy.set_workspace_locale(Barkpark.Tenancy.get_default_workspace(), "nb-NO")

    {:ok, _} =
      Barkpark.Content.upsert_schema(
        %{
          "name" => "stored_untitled_note",
          "title" => "Note",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, conn: build_conn() |> Plug.Test.init_test_session(%{"api_token" => raw})}
  end

  test "shown/1 drops a blank or literal Untitled title and keeps a real one" do
    assert DocTitle.shown(nil) == nil
    assert DocTitle.shown("") == nil
    assert DocTitle.shown("  ") == nil
    assert DocTitle.shown("Untitled") == nil
    assert DocTitle.shown(" Untitled ") == nil
    assert DocTitle.shown("Untitled draft") == "Untitled draft"
    assert DocTitle.shown("Vinterreise") == "Vinterreise"
  end

  test "a stored Untitled reads the localized fallback in the tab and the header", %{
    conn: conn
  } do
    {:ok, _} =
      Barkpark.Content.create_document(
        "stored_untitled_note",
        %{"doc_id" => "su-1", "title" => "Untitled"},
        @dataset
      )

    {:ok, view, html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/stored_untitled_note/su-1"))

    assert page_title(view) == "Uten tittel · Barkpark"
    header = view |> element("[data-role=content] h1") |> render()
    assert header =~ "Uten tittel"
    refute header =~ "Untitled"
    refute html =~ "<title data-default=\"Studio\" data-suffix=\" · Barkpark\">Untitled"
  end

  test "a real title still names the tab and the header", %{conn: conn} do
    {:ok, _} =
      Barkpark.Content.create_document(
        "stored_untitled_note",
        %{"doc_id" => "su-2", "title" => "Vinterreise"},
        @dataset
      )

    {:ok, view, _} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/stored_untitled_note/su-2"))

    assert page_title(view) == "Vinterreise · Barkpark"
    assert view |> element("[data-role=content] h1") |> render() =~ "Vinterreise"
  end
end
