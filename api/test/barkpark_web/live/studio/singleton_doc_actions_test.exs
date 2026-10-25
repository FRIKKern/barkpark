defmodule BarkparkWeb.Studio.SingletonDocActionsTest do
  @moduledoc """
  task-1141bc9aa8bdff34: a type with `singleton: true` offers no Unpublish,
  Duplicate or Delete, as Sanity limits a singleton to publish, discard and
  restore. The events behind those actions do nothing on a singleton, so a
  stale client cannot run them. A type without the flag keeps every action.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias BarkparkWeb.Studio.StudioLive.DocActions

  @dataset "production"
  @admin_token "singleton-actions-admin"

  defp admin_conn(conn) do
    {:ok, _} =
      Barkpark.Auth.create_token(
        @admin_token,
        "singleton actions admin",
        @dataset,
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    Plug.Test.init_test_session(conn, %{"api_token" => @admin_token})
  end

  defp schema!(name, extra) do
    {:ok, _} =
      Content.upsert_schema(
        Map.merge(
          %{
            "name" => name,
            "title" => String.capitalize(name),
            "icon" => "settings",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{"name" => "tagline", "title" => "Tagline", "type" => "string"}
            ]
          },
          extra
        ),
        @dataset
      )
  end

  setup %{conn: conn} do
    schema!("sitePrefs", %{"singleton" => true})
    schema!("note", %{})

    {:ok, _} =
      Content.create_document(
        "sitePrefs",
        %{"doc_id" => "sitePrefs", "title" => "Site prefs", "content" => %{"tagline" => "x"}},
        @dataset
      )

    {:ok, _} = Content.publish_document("sitePrefs", "sitePrefs", @dataset)

    {:ok, _} =
      Content.create_document(
        "note",
        %{"doc_id" => "n1", "title" => "Note one", "content" => %{"tagline" => "y"}},
        @dataset
      )

    {:ok, _} = Content.publish_document("n1", "note", @dataset)

    {:ok, conn: admin_conn(conn)}
  end

  test "a singleton's header offers no Unpublish, Duplicate or Delete", %{conn: conn} do
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sitePrefs/sitePrefs"))

    refute html =~ ~s(phx-click="unpublish")
    refute html =~ ~s(phx-click="duplicate-doc")
    refute html =~ ~s(phx-click="delete-doc")
    assert html =~ ~s(phx-click="show-history")
  end

  test "a type without singleton keeps Unpublish, Duplicate and Delete", %{conn: conn} do
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/note/n1"))

    assert html =~ ~s(phx-click="unpublish")
    assert html =~ ~s(phx-click="duplicate-doc")
    assert html =~ ~s(phx-click="delete-doc")
  end

  test "a singleton's draft still offers Publish and Discard draft", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sitePrefs/sitePrefs"))

    render_change(view, "autosave", %{
      "_target" => ["doc", "tagline"],
      "doc" => %{"tagline" => "changed"}
    })

    # Open the singleton again so the editor loads the draft with its
    # published twin, which is what offers Discard draft.
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sitePrefs/sitePrefs"))
    assert html =~ ~s(phx-click="publish")
    assert html =~ ~s(phx-click="discard-draft")
    refute html =~ ~s(phx-click="delete-doc")
  end

  test "the withheld events change nothing on a singleton", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sitePrefs/sitePrefs"))
    count = length(Content.list_documents("sitePrefs", @dataset))

    html = render_click(view, "delete-doc", %{})
    refute html =~ "delete-modal"
    render_click(view, "confirm-delete", %{})
    render_click(view, "unpublish", %{})
    render_click(view, "confirm-unpublish", %{})
    render_click(view, "duplicate-doc", %{})

    assert {:ok, %{status: "published"}} =
             Content.get_document("sitePrefs", "sitePrefs", @dataset)

    assert length(Content.list_documents("sitePrefs", @dataset)) == count
  end

  test "withheld_action_names/1 reads the singleton flag in either key form" do
    assert DocActions.withheld_action_names(%{singleton: true}) ==
             ~w(unpublish duplicate-doc delete-doc)

    assert DocActions.withheld_action_names(%{"singleton" => true}) ==
             ~w(unpublish duplicate-doc delete-doc)

    assert DocActions.withheld_action_names(%{singleton: false}) == []
    assert DocActions.withheld_action_names(nil) == []
  end
end
