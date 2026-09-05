defmodule BarkparkWeb.Studio.StudioRowClickReplacesPathTest do
  @moduledoc """
  Gyldendal field report #35b: a desk row click APPENDED the document id to
  the current path instead of replacing the document segment — from
  `/studio/publication/pub-a` a click on the same list produced
  `/studio/publication/pub-a/pub-b`, and from an error state the path grew on
  every click.

  Mechanism: `Handlers.Scope.select/2` computed
  `Enum.take(nav_path, pane_idx) ++ [id]` where `pane_idx` is the RENDERED pane
  index the row carries and `nav_path` is the URL's raw segments. When
  `PaneBuilder.resolve/4` normalizes a type that lives under a desk group
  (Content / Plugins / …Rest) to its nested node path for the WALK, the pane
  stack is one longer than the URL — [structure, group, type-list] against
  [type, doc] — so the slice kept the old doc id and the click appended.

  The fixture is a type that the desk places under a group in a NON-default
  workspace (the twin's shape). A Default-workspace `post` with its own desk
  groups has a 3-segment URL that matches its 3 panes, so it never showed the
  bug — which is why it survived.
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

    {:ok, ws} = Tenancy.create_workspace(%{slug: "gfr35-twin-#{suffix}", name: "GFR35 Twin"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "gfr35-owner-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "gfr35-owner", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")

    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "publication",
          "title" => "Utgivelse",
          "icon" => "book",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Tittel", "type" => "string"}]
        },
        @dataset,
        scope
      )

    {:ok, doc_a} =
      Content.create_document(
        "publication",
        %{"doc_id" => "pub-a", "title" => "Over My Dead Body", "status" => "published"},
        @dataset,
        scope
      )

    {:ok, doc_b} =
      Content.create_document(
        "publication",
        %{"doc_id" => "pub-b", "title" => "Snow Angels", "status" => "published"},
        @dataset,
        scope
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    a = Content.DraftId.published_id(doc_a.doc_id)
    b = Content.DraftId.published_id(doc_b.doc_id)

    {:ok, conn: conn, ws: ws, proj: proj, a: a, b: b}
  end

  defp desk_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

  defp click_row(view, id) do
    view
    |> element(~s(button.bp-doc-row-body[phx-value-id="#{id}"]))
    |> render_click()
  end

  test "with doc A open, clicking row B REPLACES the document segment — one doc id in the path, and it is B",
       %{conn: conn, ws: ws, proj: proj, a: a, b: b} do
    {:ok, view, html} = live(conn, desk_url(ws, proj) <> "/publication/#{a}")
    assert html =~ ~s(value="Over My Dead Body")

    html = click_row(view, b)
    path = assert_patch(view)

    segments = path |> String.split("?") |> hd() |> String.split("/", trim: true)

    assert List.last(segments) == b, "the patched path must end in the clicked id: #{path}"
    refute a in segments, "the previously open id must be gone from the path: #{path}"
    assert Enum.count(segments, &(&1 in [a, b])) == 1, "exactly one document segment: #{path}"

    assert html =~ ~s(value="Snow Angels")
    refute html =~ "Studio could not open this document"
  end

  test "clicking the row that is already open does not grow the path", %{
    conn: conn,
    ws: ws,
    proj: proj,
    a: a
  } do
    {:ok, view, _html} = live(conn, desk_url(ws, proj) <> "/publication/#{a}")

    _html = click_row(view, a)
    path = assert_patch(view)
    segments = path |> String.split("?") |> hd() |> String.split("/", trim: true)

    assert Enum.count(segments, &(&1 == a)) == 1, "the id must appear once, not twice: #{path}"
  end

  test "the patched path is itself a working deep link (the URL equals the pane stack)", %{
    conn: conn,
    ws: ws,
    proj: proj,
    a: a,
    b: b
  } do
    {:ok, view, _html} = live(conn, desk_url(ws, proj) <> "/publication/#{a}")
    _ = click_row(view, b)
    path = assert_patch(view)

    {:ok, _view2, html2} = live(conn, path)
    assert html2 =~ ~s(value="Snow Angels")
    refute html2 =~ "Studio could not open this document"
  end
end
