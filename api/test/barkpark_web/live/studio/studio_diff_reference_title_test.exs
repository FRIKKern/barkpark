defmodule BarkparkWeb.Studio.StudioDiffReferenceTitleTest do
  @moduledoc """
  task-30d564b8b1219ab9 — the Studio Diff shows a reference as the referenced
  document's title, read in the editor's own workspace.

  A same-id author in another workspace carries a different title; the Diff
  must name the one in the open document's workspace and never the other.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.TenancyFixtures

  @dataset "production"

  setup do
    {ws, proj} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: proj.id]

    for {name, fields} <- [
          {"dfauthor", [%{"name" => "name", "title" => "Navn", "type" => "string"}]},
          {"dfpub",
           [
             %{"name" => "title", "title" => "Tittel", "type" => "string"},
             %{
               "name" => "author",
               "title" => "Forfatter",
               "type" => "reference",
               "to" => [%{"type" => "dfauthor"}]
             }
           ]}
        ] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => name, "title" => name, "visibility" => "public", "fields" => fields},
          @dataset
        )
    end

    other_ws = TenancyFixtures.create_workspace!()
    other_proj = TenancyFixtures.create_project!(other_ws)

    {:ok, _} =
      Content.create_document(
        "dfauthor",
        %{
          "doc_id" => "df-author",
          "title" => "Other Tenant Author",
          "content" => %{"name" => "x"}
        },
        @dataset,
        workspace_id: other_ws.id,
        project_id: other_proj.id
      )

    for {id, title} <- [{"df-author", "Ingrid Ness"}, {"df-author-2", "Sverre Graff"}] do
      {:ok, _} =
        Content.create_document(
          "dfauthor",
          %{"doc_id" => id, "title" => title, "content" => %{"name" => title}},
          @dataset,
          scope
        )
    end

    {:ok, _} =
      Content.create_document(
        "dfpub",
        %{
          "doc_id" => "df-pub",
          "title" => "Fjellet",
          "content" => %{"title" => "Fjellet", "author" => %{"_ref" => "df-author"}}
        },
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("df-pub", "dfpub", @dataset, scope)

    {:ok, _} =
      Content.upsert_document(
        "dfpub",
        %{
          "doc_id" => "drafts.df-pub",
          "title" => "Fjellet",
          "content" => %{"title" => "Fjellet", "author" => %{"_ref" => "df-author-2"}}
        },
        @dataset,
        scope
      )

    :ok
  end

  test "the Diff names both authors by title, from the editor's own workspace", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/dfpub/df-pub"))
    html = render_click(view, "toggle-diff", %{})

    diff = view |> element(~s([data-test-id="draft-diff-row-author"])) |> render()
    assert diff =~ "Forfatter"
    assert diff =~ "Ingrid Ness"
    assert diff =~ "Sverre Graff"
    assert diff =~ "Changed"
    refute diff =~ "_ref"
    refute html =~ "Other Tenant Author"
  end
end
