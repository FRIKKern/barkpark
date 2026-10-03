defmodule BarkparkWeb.Studio.SharedStudioFormPrivateFieldTest do
  @moduledoc """
  task-df2ea2e004ff4caf — an anonymous `:docs`-share viewer of Studio was shown every
  private field in the editor form.

  `LiveScope.authorize_read/4` grades an anonymous mount of a `:docs`-shared
  desk `:share_read`: the FULL Studio UI, read-only. `PaneBuilder` built the
  editor form with `Content.doc_to_form(doc, schema)` straight off the stored
  `%Document{}`, and `Shared.rebuild_panes/1` assigned it — no `Envelope`, so a
  field the schema declares `private: true` (the demo seed's `author.email`)
  rendered into the form for anyone holding the share. The same document
  through the share's JSON door (`/v1/data/doc`) was redacted.

  THE RULE is the one the paper reader clamp (task-fa27740cb3162dbd) already
  uses: a socket the write tier denies (`Shared.Paper.write_denied?/1`) is a
  NON-EDITING viewer and gets the redacted document. A write-capable socket
  keeps the raw read — an editor must be able to see and keep what they save.

  `async: false` — the `:shares` registry is process-global.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Content

  @dataset "share-form-private-#{System.unique_integer([:positive])}"

  setup do
    Barkpark.SharingFixtures.snapshot_shares!()

    # A NON-default workspace: Default is an open public demo in test, offered
    # before the share arm, so a share there never grades `:share_read`.
    ws = create_workspace!("share-form-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "share-form-proj")
    scope = [workspace_id: ws.id, project_id: proj.id]

    Barkpark.SharingFixtures.plant_shares!("#{ws.slug}/#{proj.slug}/#{@dataset}:docs:read")

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Authors",
          "visibility" => "public",
          "fields" => [
            %{"name" => "name", "title" => "Name", "type" => "string"},
            %{"name" => "bio", "title" => "Bio", "type" => "string"},
            %{"name" => "email", "title" => "Email", "type" => "string", "private" => true}
          ]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.create_document(
        "author",
        %{
          "_id" => "share-form-author",
          "title" => "Ada",
          "content" => %{
            "name" => "Ada Lovelace",
            "bio" => "Visible biography text",
            "email" => "ada-private@example.invalid"
          }
        },
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("share-form-author", "author", @dataset, scope)

    %{ws: ws, proj: proj}
  end

  test "ANONYMOUS share viewer: the editor form omits the private field", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    {:ok, _view, html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/author/share-form-author")

    # CONTROL: the editor rendered this document's public fields.
    assert html =~ "Visible biography text"

    refute html =~ "ada-private@example.invalid"
  end

  test "CONTROL: a write-capable socket keeps the private field in its form", %{conn: conn} do
    # The Default workspace is the open public-demo desk in test: principal-less
    # and write-capable BY DESIGN (see `Shared.Paper`'s reader clamp note), so
    # it is the editor posture — its form must hold every field it saves back.
    ws = Barkpark.Tenancy.get_default_workspace()
    proj = Barkpark.Tenancy.get_default_project()
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Authors",
          "visibility" => "public",
          "fields" => [
            %{"name" => "bio", "title" => "Bio", "type" => "string"},
            %{"name" => "email", "title" => "Email", "type" => "string", "private" => true}
          ]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.create_document(
        "author",
        %{
          "_id" => "demo-form-author",
          "title" => "Grace",
          "content" => %{"bio" => "Demo biography", "email" => "grace-editor@example.invalid"}
        },
        @dataset,
        scope
      )

    {:ok, _view, html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/author/demo-form-author")

    assert html =~ "Demo biography"
    assert html =~ "grace-editor@example.invalid"
  end
end
