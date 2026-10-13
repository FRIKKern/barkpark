defmodule BarkparkWeb.Studio.StudioBetaDocActionsTest do
  @moduledoc """
  Beta's per-document header offers the document actions Classic does, so an
  editor can publish without leaving Beta (task-fc4102c1e2f9b606).

  Found dogfooding the S9 round trip: in Beta the header held only the
  Classic / Beta toggle, so Publish, History, Discard draft, Duplicate and
  Delete were reachable only after switching back to Classic.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "betaact",
          "title" => "Utgivelse",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{"name" => "body", "title" => "Tekst", "type" => "richText"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "betaact",
        %{
          "doc_id" => "betaact-1",
          "title" => "Fjellet",
          "content" => %{"title" => "Fjellet", "body" => "<p>Et fjell.</p>"}
        },
        @dataset
      )

    :ok
  end

  defp open_beta(conn) do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/betaact/betaact-1"))
    html = view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert html =~ ~s(data-test-id="studio-doc-beta-editor")
    {view, html}
  end

  defp action_names(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s([data-test-id="studio-beta-doc-actions"] [phx-click]))
    |> LazyHTML.attribute("phx-click")
  end

  test "the Beta header offers Classic's document actions, minus the Classic-only panels",
       %{conn: conn} do
    {_view, html} = open_beta(conn)
    names = action_names(html)

    for event <- ~w(publish show-history duplicate-doc delete-doc) do
      assert event in names, "#{event} missing from the Beta header: #{inspect(names)}"
    end

    refute "toggle-diff" in names
    refute "toggle-content-preview" in names
  end

  test "an editor publishes from the Beta header", %{conn: conn} do
    {view, _html} = open_beta(conn)
    assert {:error, :not_found} = Content.get_document("betaact-1", "betaact", @dataset)

    view
    |> element(~s([data-test-id="studio-beta-doc-actions"] [phx-click="publish"]))
    |> render_click()

    assert {:ok, published} = Content.get_document("betaact-1", "betaact", @dataset)
    assert published.title == "Fjellet"
  end
end
