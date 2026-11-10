defmodule BarkparkWeb.Studio.DeskLiveUpdatesJ32GoneTest do
  @moduledoc """
  J32 (barkpark-studio JOURNEYS.md, reference `e2e/journeys/gone.spec.ts`):
  someone else deletes or changes the document you have open, or one it
  references, and the desk says so (banner + Restore / Reload / Close).

  The second person is this test process writing through `Barkpark.Content`,
  as an API write from another editor would. Every write is announced on the
  dataset's document topics; each test first waits until the page has HEARD
  it, so a red here means the page heard and did not show, never that the
  message was still in flight.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "desk_gone_note"
  @ref_type "desk_gone_linked"

  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Desk gone notes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "summary", "title" => "Summary", "type" => "string"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @ref_type,
          "title" => "Desk gone linked",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "note", "title" => "Note", "type" => "reference", "to" => [@type_name]}
          ]
        },
        @dataset
      )

    n = System.unique_integer([:positive])
    a = "dgn-a-#{n}"
    b = "dgn-b-#{n}"
    linked = "dgl-#{n}"

    for {id, title} <- [{a, "Alpha note"}, {b, "Beta note"}] do
      {:ok, _} =
        Content.create_document(
          @type_name,
          %{"doc_id" => id, "title" => title, "content" => %{"summary" => "About " <> title}},
          @dataset
        )
    end

    {:ok, _} =
      Content.create_document(
        @ref_type,
        %{
          "doc_id" => linked,
          "title" => "Linked one",
          "content" => %{"note" => %{"_ref" => a, "_type" => "reference"}}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok, conn: admin(conn), base: base, a: a, b: b, linked: linked}
  end

  defp admin(conn) do
    raw = "desk-gone-token-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-gone", @dataset, ~w(read write admin), ws.id)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp settle(view), do: render_async(view, 5_000)

  # Poll for a value itself (CAMPAIGN rule 6): ~2 s, settling the panes' reads.
  defp eventually(view, fun) do
    Enum.any?(1..200, fn _ ->
      settle(view)
      fun.() or (Process.sleep(10) && false)
    end)
  end

  # The page is subscribed to the dataset's document topics; so is this test,
  # from the moment the page is open, to know when a write went out.
  defp open(conn, url) do
    {:ok, view, _html} = live(conn, url)
    settle(view)

    for topic <- assigns(view).topics,
        do: Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)

    view
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # A write to `id` was announced on the topics the page listens to. The
  # page's own refresh runs 120 ms later; the asserts after this poll.
  defp heard_list_frame?(view, _type, id) do
    receive do
      {:document_changed, %{doc_id: doc_id}} when is_binary(doc_id) ->
        Content.published_id(doc_id) == id or heard_list_frame?(view, nil, id)
    after
      2_000 -> false
    end
  end

  # The Studio's editor heard of a write to the open document (its doc topic).
  defp editor_heard?(view),
    do: eventually(view, fn -> assigns(view).save_status == "Updated by another user" end)

  # The page refreshes stale panes on its own timer; poll for the result.
  defp refresh(view), do: settle(view)

  defp rename(type, id, title, content),
    do:
      {:ok, _} =
        Content.upsert_document(
          type,
          %{"doc_id" => id, "title" => title, "content" => content},
          @dataset
        )

  defp editor_value?(view, index, value),
    do: has_element?(view, ~s([data-pane-index="#{index}"] #editor-form [value="#{value}"]))

  describe "(a) the open document is changed by someone else" do
    test "while clean, the editor shows the saved value and no banner", %{
      conn: conn,
      base: base,
      a: a
    } do
      view = open(conn, "#{base}/#{@type_name};#{a}")
      assert editor_value?(view, 2, "Alpha note")

      rename(@type_name, a, "Alpha by someone else", %{"summary" => "Theirs"})

      assert eventually(view, fn -> editor_value?(view, 2, "Alpha by someone else") end),
             "the clean editor never showed the other person's save"

      refute has_element?(view, ~s([data-test-id="doc-conflict-banner"]))
    end

    test "while dirty, the typed text stays and a banner offers Reload, which loads theirs", %{
      conn: conn,
      base: base,
      a: a
    } do
      view = open(conn, "#{base}/#{@type_name};#{a}")

      view
      |> form("#editor-form")
      |> render_change(%{"doc" => %{"title" => "Alpha mine", "summary" => "Mine"}})

      rename(@type_name, a, "Alpha theirs", %{"summary" => "Theirs"})

      assert eventually(view, fn ->
               has_element?(view, ~s([data-test-id="doc-conflict-banner"]))
             end),
             "no 'Updated by another user' banner over the dirty editor"

      assert editor_value?(view, 2, "Alpha mine"), "the typed text was overwritten"

      view |> element(~s([data-test-id="doc-conflict-reload"])) |> render_click()

      assert eventually(view, fn -> editor_value?(view, 2, "Alpha theirs") end),
             "Reload did not load the other person's save"

      refute has_element?(view, ~s([data-test-id="doc-conflict-banner"]))
    end
  end

  describe "(b) the open document is deleted by someone else" do
    test "the editor says it has been deleted and offers to restore it", %{
      conn: conn,
      base: base,
      a: a
    } do
      view = open(conn, "#{base}/#{@type_name};#{a}")

      {:ok, _} = Content.delete_document(a, @type_name, @dataset)
      assert editor_heard?(view), "precondition: the editor never heard of the delete"

      assert eventually(view, fn -> render(view) =~ "This document has been deleted" end),
             "the open document was deleted and the editor pane does not say so"

      assert has_element?(view, ~s([data-pane-index="2"] button), "Restore most recent revision")
    end

    test "typing into a deleted document does not silently bring it back", %{
      conn: conn,
      base: base,
      a: a
    } do
      view = open(conn, "#{base}/#{@type_name};#{a}")

      {:ok, _} = Content.delete_document(a, @type_name, @dataset)
      assert editor_heard?(view), "precondition: the editor never heard of the delete"

      view
      |> form("#editor-form")
      |> render_change(%{"doc" => %{"title" => "Typed after the delete"}})

      {doc, _draft?, _published?} = Content.fetch_doc_with_draft(@type_name, a, @dataset)

      assert doc == nil,
             "a keystroke after someone deleted the document re-created it as #{inspect(doc && doc.doc_id)}"
    end
  end

  describe "(c) a read-only pane's document is deleted by someone else" do
    test "the pane reads again and says the document has been deleted", %{
      conn: conn,
      base: base,
      a: a,
      b: b
    } do
      # b is a read-only pane (index 2), a the editor (index 3).
      view = open(conn, "#{base}/#{@type_name};#{b};#{a},type=#{@type_name},parentRefPath=x")
      assert has_element?(view, ~s([data-pane-index="2"] dd), "About Beta note")

      {:ok, _} = Content.delete_document(b, @type_name, @dataset)
      assert heard_list_frame?(view, @type_name, b), "precondition: the page never heard"
      refresh(view)

      # The pane re-reads: its fields are gone. (Green today.)
      assert eventually(view, fn ->
               not has_element?(view, ~s([data-pane-index="2"] dd), "About Beta note")
             end),
             "the read-only pane still shows the deleted document's fields"

      # It says what happened, not that the id never existed. (Red today: it
      # says "No document … was found.", as for a typo in the URL.)
      assert has_element?(view, ~s([data-pane-index="2"]), "This document has been deleted"),
             "the read-only pane does not say its document was deleted: " <>
               inspect(view |> element(~s([data-pane-index="2"] .pane-body)) |> render())
    end
  end

  describe "(d) a document the open one references is changed or deleted" do
    test "a renamed target's reference link in the editor pane shows its new title", %{
      conn: conn,
      base: base,
      a: a,
      linked: linked
    } do
      view = open(conn, "#{base}/#{@ref_type};#{linked}")
      assert has_element?(view, ~s([data-pane-index="2"] a[data-desk-ref]), "Alpha note")

      rename(@type_name, a, "Alpha renamed", %{"summary" => "About Alpha note"})
      assert heard_list_frame?(view, @type_name, a), "precondition: the page never heard"
      refresh(view)

      assert eventually(view, fn ->
               has_element?(view, ~s([data-pane-index="2"] a[data-desk-ref]), "Alpha renamed")
             end),
             "the editor pane's reference link kept the old title after its target was renamed"
    end

    test "a deleted target's reference in the editor pane is no longer a live link", %{
      conn: conn,
      base: base,
      a: a,
      linked: linked
    } do
      view = open(conn, "#{base}/#{@ref_type};#{linked}")
      assert has_element?(view, ~s([data-pane-index="2"] a[data-desk-ref]), "Alpha note")

      {:ok, _} = Content.delete_document(a, @type_name, @dataset)
      assert heard_list_frame?(view, @type_name, a), "precondition: the page never heard"
      refresh(view)

      assert eventually(view, fn ->
               has_element?(view, ~s([data-pane-index="2"] .dk-ref-missing), a)
             end),
             "the editor pane still links to a deleted target"
    end

    test "a renamed target's reference link in a read-only pane shows its new title", %{
      conn: conn,
      base: base,
      a: a,
      b: b,
      linked: linked
    } do
      # linked is a read-only pane (index 2) referencing a; b is the editor.
      view = open(conn, "#{base}/#{@ref_type};#{linked};#{b},type=#{@type_name},parentRefPath=x")
      assert has_element?(view, ~s([data-pane-index="2"] a[data-desk-ref]), "Alpha note")

      rename(@type_name, a, "Alpha renamed", %{"summary" => "About Alpha note"})
      assert heard_list_frame?(view, @type_name, a), "precondition: the page never heard"
      refresh(view)

      assert eventually(view, fn ->
               has_element?(view, ~s([data-pane-index="2"] a[data-desk-ref]), "Alpha renamed")
             end),
             "the read-only pane's reference link kept the old title after its target was renamed"
    end

    test "the parent's reference moves while its old target is open: the target pane says so", %{
      conn: conn,
      base: base,
      a: a,
      b: b,
      linked: linked
    } do
      # linked (read-only, index 2) -> its note, a, open as the editor (index 3).
      view =
        open(conn, "#{base}/#{@ref_type};#{linked};#{a},type=#{@type_name},parentRefPath=note")

      assert editor_value?(view, 3, "Alpha note")

      rename(@ref_type, linked, "Linked one", %{"note" => %{"_ref" => b, "_type" => "reference"}})
      assert heard_list_frame?(view, @ref_type, linked), "precondition: the page never heard"
      refresh(view)

      # The parent re-reads and now links to b. (Green today.)
      assert eventually(view, fn ->
               has_element?(view, ~s([data-pane-index="2"] a[data-desk-ref]), "Beta note")
             end),
             "the parent pane never showed its new reference"

      # The pane opened through the old reference says it changed. (Red today.)
      assert render(view) =~ "This reference has changed since you opened it",
             "the pane opened through a reference that moved does not say so"
    end
  end
end
