defmodule BarkparkWeb.Studio.StudioTokenEditorOpenTest do
  @moduledoc """
  Gyldendal field report #34 — the TOKEN arm.

  `gfr-w1-studio-principal-kind` closed the ACCOUNT arm (an account session was
  teleported to Default by the flat→scoped funnel). This file pins the arm that
  slice recorded as "resolved correctly the whole time" and that the customer
  re-reproduced live on 2026-09-04 against gyl 0.2.26.1669: a Studio session
  signed in with an API TOKEN that is a MEMBER (even the OWNER) of a
  non-default workspace lands on the correctly scoped URL, sees the type list
  with the document in it, and the editor pane still answers

      Studio could not open this document.
      No <type> with the id <id> exists in this dataset.

  The scoped HTTP read of the same document with the same token answers 200, so
  the denial is specific to the LiveView document-open path.

  ## The fixture kind is the whole test

  Every principal here is a TOKEN principal seated in a NON-default workspace,
  and the document lives in THAT workspace's `production` dataset — the shape
  the twin migration produced. A Default-workspace fixture would pass on
  unpatched main (the customer's control test did), so it certifies nothing.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} = Tenancy.create_workspace(%{slug: "gfr34-twin-#{suffix}", name: "GFR34 Twin"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "gfr34-owner-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "gfr34-owner", @dataset, ["read", "write", "admin"], default_ws.id)

    # The customer's shape: the api_token that CREATED the workspace holds the
    # owner seat there (`bp workspace member-ls` on gyl: principal_type
    # api_token, role owner, permissions read/write/admin).
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")

    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "publication",
          "title" => "Utgivelse",
          "icon" => "book",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{"name" => "isbn", "title" => "ISBN", "type" => "string"}
          ]
        },
        @dataset,
        scope
      )

    {:ok, doc} =
      Content.create_document(
        "publication",
        %{"title" => "Over My Dead Body", "isbn" => "9788205000001", "status" => "published"},
        @dataset,
        scope
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, conn: conn, ws: ws, proj: proj, doc: doc}
  end

  defp desk_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

  describe "a token member of a non-default workspace opens a document in the editor" do
    test "the deep link /studio/<type>/<id> renders the editor, not the not-found card", %{
      conn: conn,
      ws: ws,
      proj: proj,
      doc: doc
    } do
      {:ok, _view, html} = live(conn, desk_url(ws, proj) <> "/publication/#{doc.doc_id}")

      refute html =~ "Studio could not open this document",
             "the editor answered not-found for a document the type list shows and the scoped HTTP read returns"

      assert html =~ ~s(value="Over My Dead Body")
    end

    test "a row click from the type list opens the editor and REPLACES the path (#35b)", %{
      conn: conn,
      ws: ws,
      proj: proj,
      doc: doc
    } do
      {:ok, view, html} = live(conn, desk_url(ws, proj) <> "/publication")
      assert html =~ "Over My Dead Body"

      pub_id = Barkpark.Content.DraftId.published_id(doc.doc_id)

      html =
        view
        |> element(~s(button.bp-doc-row-body[phx-value-id="#{pub_id}"]))
        |> render_click()

      # The click patches to the CANONICAL path — the pane stack's own address
      # (#35a/#35b: a desk-group-normalized type gains its group segment), so
      # assert the tail, not the exact short form the deep link used.
      path = assert_patch(view)
      assert String.ends_with?(path, "/publication/#{pub_id}"), path
      assert String.starts_with?(path, desk_url(ws, proj) <> "/"), path

      refute html =~ "Studio could not open this document"
      assert html =~ ~s(value="Over My Dead Body")
    end
  end
end
