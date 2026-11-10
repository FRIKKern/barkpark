defmodule BarkparkWeb.Studio.DeskEditorLifecycleTest do
  @moduledoc """
  Journeys J03 (edit the title: instant, no save button, an edited state) and
  J04 (the draft lifecycle: edit, publish, unpublish, discard, a flash per
  action) in the desk's editor pane (`DeskLive`, the last document of the
  chain).

  Measured in a browser first (editing-w1 probe, port 4131): typing saves a
  draft at once and the header badge turns to "draft"; Publish and Unpublish
  work and their flash shows inside the desk. "Discard draft" does not: the
  editor keeps the discarded draft, and the patch it pushes rewrites a
  `<type>;<id>` chain into the Studio's own path for the type
  (`content-types;<type>;<id>`), which adds a menu pane to the left.

  Run both ways: `--only desk_editor_red` for the known-broken journeys,
  `--exclude desk_editor_red` for the behaviour that holds.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "w1_life_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "W1 lifecycle #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "summary", "title" => "Summary", "type" => "text"}
          ]
        },
        @dataset
      )

    id = "w1l-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "Life published", "content" => %{"summary" => "Pub"}},
        @dataset
      )

    {:ok, _} = Content.publish_document(id, type, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok, conn: sign_in(conn), base: base, type: type, id: id}
  end

  defp sign_in(conn) do
    raw = "desk-w1-token-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-w1", @dataset, ["read", "write", "admin"], ws.id)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp settle(view), do: render_async(view, 5_000)

  defp open(ctx) do
    {:ok, view, _html} = live(ctx.conn, "#{ctx.base}/#{ctx.type};#{ctx.id}")
    settle(view)
    assert has_element?(view, "[data-pane-editing] #editor-form")
    view
  end

  defp title_shown?(view, text),
    do:
      has_element?(
        view,
        ~s([data-pane-editing] #editor-form input[name="doc[title]"][value="#{text}"])
      )

  defp badge?(view, word), do: has_element?(view, "[data-pane-editing] .pane-header .badge", word)

  defp offered?(view, label),
    do: has_element?(view, ~s([data-pane-editing] .pane-header button[aria-label="#{label}"]))

  defp flash?(view, text), do: has_element?(view, "#studio-flash .flash", text)

  # Poll for a value the view reaches after a message, never right after a send.
  defp eventually(fun) do
    Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)
  end

  describe "J03 edit the title" do
    test "typing saves a draft at once, with no save button, and the badge says draft", ctx do
      view = open(ctx)
      assert badge?(view, "published")
      refute has_element?(view, "[data-pane-editing] #editor-form button[type=submit]")

      view |> form("#editor-form") |> render_change(%{"doc" => %{"title" => "Life typed"}})

      {doc, draft?, _} = Content.fetch_doc_with_draft(ctx.type, ctx.id, @dataset)
      assert draft?
      assert doc.title == "Life typed"
      assert eventually(fn -> badge?(view, "draft") end), "the header badge never said draft"
      assert offered?(view, "Publish")
    end
  end

  describe "J04 draft lifecycle" do
    test "publish then unpublish: each changes the badge and flashes inside the desk", ctx do
      view = open(ctx)
      view |> form("#editor-form") |> render_change(%{"doc" => %{"title" => "Life to publish"}})

      view
      |> element(~s([data-pane-editing] .pane-header button[aria-label="Publish"]))
      |> render_click()

      assert flash?(view, "Published")
      assert badge?(view, "published")
      assert offered?(view, "Unpublish")
      {_doc, draft?, published?} = Content.fetch_doc_with_draft(ctx.type, ctx.id, @dataset)
      assert published?
      refute draft?

      view
      |> element(~s([data-pane-editing] .pane-header button[aria-label="Unpublish"]))
      |> render_click()

      assert flash?(view, "Unpublished")
      assert badge?(view, "draft")
      assert offered?(view, "Publish")
    end

    test "Discard draft opens its dialog inside the desk, and Cancel closes it", ctx do
      {:ok, _} =
        Content.upsert_document(
          ctx.type,
          %{"doc_id" => Content.draft_id(ctx.id), "title" => "Life draft"},
          @dataset
        )

      view = open(ctx)
      assert title_shown?(view, "Life draft")
      assert offered?(view, "Discard draft")

      render_click(view, "discard-draft", %{})
      assert has_element?(view, ~s([data-test-id="discard-draft-modal"]))
      render_click(view, "close-discard", %{})
      refute has_element?(view, ~s([data-test-id="discard-draft-modal"]))
      assert title_shown?(view, "Life draft")
    end

    # BROKEN in the desk: confirming "Discard draft" on a document opened as
    # `<type>;<id>` patches to `content-types;<type>;<id>`: Discard.confirm_discard
    # prints the Studio's `nav_path` (Tree.path_to_type, set by DeskLive.edit/2)
    # through Shared.studio_path/4, so a "Content types" menu pane appears on
    # the left. (The editor also keeps the discarded draft: see
    # desk_editor_history_test.exs, same cause in DeskLive.handle_params `kept?`.)
    @tag :desk_editor_red
    test "Discard draft keeps a type;id chain as it is", ctx do
      {:ok, _} =
        Content.upsert_document(
          ctx.type,
          %{"doc_id" => Content.draft_id(ctx.id), "title" => "Life draft"},
          @dataset
        )

      view = open(ctx)
      render_click(view, "discard-draft", %{})
      render_click(view, "confirm-discard", %{})

      to = view |> assert_patch() |> URI.decode()

      assert to == "#{ctx.base}/#{ctx.type};#{ctx.id}",
             "discard patched to #{to}: the chain was rewritten"
    end
  end
end
