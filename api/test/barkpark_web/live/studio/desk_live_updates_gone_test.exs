defmodule BarkparkWeb.Studio.DeskLiveUpdatesGoneTest do
  @moduledoc """
  J32 (barkpark-studio JOURNEYS.md, reference `e2e/journeys/gone.spec.ts`):
  someone else deletes the document you have open, or one shown in a
  read-only pane, and the desk says so (`BarkparkWeb.Studio.Desk.LiveRefresh`).

  The second person is this test process writing through `Barkpark.Content`,
  as an API write from another editor would. The page notes the document in
  `desk_gone`; `LiveRefresh.gone_notice/1` is what it shows for it. Until the
  page renders that notice (desk_live.ex), the notice is rendered here from
  the page's own assigns.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias BarkparkWeb.Studio.Desk.LiveRefresh

  @dataset "production"
  @type_name "desk_gone_note"

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

    n = System.unique_integer([:positive])
    a = "dgn-a-#{n}"
    b = "dgn-b-#{n}"

    for {id, title} <- [{a, "Alpha note"}, {b, "Beta note"}] do
      {:ok, _} = create(id, title)
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-gone-token-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "desk-gone", @dataset, ~w(read write admin), ws.id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    {:ok, conn: conn, base: base, a: a, b: b}
  end

  defp create(id, title),
    do:
      Content.create_document(
        @type_name,
        %{"doc_id" => id, "title" => title, "content" => %{"summary" => "About " <> title}},
        @dataset
      )

  defp open(conn, url) do
    {:ok, view, _html} = live(conn, url)
    render_async(view, 5_000)
    # This process hears what the page hears, to know a write went out.
    for topic <- assigns(view).topics, do: Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)
    view
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # The delete was announced on the page's topics with its mutation; the page
  # has handled everything sent before this returns.
  defp heard?(id, mutation) do
    receive do
      {:document_changed, %{doc_id: doc_id} = msg} ->
        (Content.published_id(doc_id) == id and msg[:mutation] == mutation) or
          heard?(id, mutation)
    after
      2_000 -> false
    end
  end

  defp gone(view) do
    _ = :sys.get_state(view.pid)
    assigns(view)[:desk_gone] || %{}
  end

  defp notice(view) do
    a = assigns(view)

    render_component(&LiveRefresh.gone_notice/1,
      gone: a.desk_gone,
      panes: a.desk_panes,
      chain: a.chain,
      base: a.base
    )
  end

  test "the open document deleted by someone else: the desk says so, with Close", %{
    conn: conn,
    base: base,
    a: a
  } do
    view = open(conn, "#{base}/#{@type_name};#{a}")
    assert assigns(view).active == 2, "precondition: the document is open in the editor"

    {:ok, _} = Content.delete_document(a, @type_name, @dataset)
    assert heard?(a, "delete"), "precondition: the page's topics never carried the delete"

    assert gone(view) == %{{@type_name, a} => "Alpha note"},
           "the page did not note that the open document was deleted: #{inspect(gone(view))}"

    html = notice(view)
    assert html =~ "This document has been deleted.", "the notice does not say so: #{html}"
    assert html =~ "Alpha note", "the notice does not name the document: #{html}"

    assert html =~ ~s(href="#{base}/#{@type_name}"),
           "the notice's Close does not close the deleted document's pane: #{html}"
  end

  test "a read-only pane's document deleted by someone else: the desk says so", %{
    conn: conn,
    base: base,
    a: a,
    b: b
  } do
    # b is a read-only pane (index 2), a the editor (index 3).
    view = open(conn, "#{base}/#{@type_name};#{b};#{a},type=#{@type_name},parentRefPath=x")
    assert assigns(view).active == 3, "precondition: b is a read-only pane"

    {:ok, _} = Content.delete_document(b, @type_name, @dataset)
    assert heard?(b, "delete"), "precondition: the page's topics never carried the delete"

    assert Map.keys(gone(view)) == [{@type_name, b}],
           "the page did not note that the read-only pane's document was deleted"

    html = notice(view)
    assert html =~ ~s(data-desk-gone-pane="2"), "the notice is not for pane 2: #{html}"
    assert html =~ "Beta note", "the notice does not name the document: #{html}"
  end

  test "a deleted document written again is no longer noted as gone", %{
    conn: conn,
    base: base,
    a: a
  } do
    view = open(conn, "#{base}/#{@type_name};#{a}")
    {:ok, _} = Content.delete_document(a, @type_name, @dataset)
    assert heard?(a, "delete"), "precondition: the page's topics never carried the delete"
    assert Map.has_key?(gone(view), {@type_name, a}), "precondition: the delete was noted"

    {:ok, _} = create(a, "Alpha again")
    assert heard?(a, "create"), "precondition: the page's topics never carried the write"

    assert gone(view) == %{}, "the document was written again and the desk still says deleted"

    assert notice(view) =~ "This document has been deleted." == false,
           "the notice still shows for a document that was written again"
  end

  test "a document deleted elsewhere, not on the desk, is not noted", %{
    conn: conn,
    base: base,
    a: a,
    b: b
  } do
    view = open(conn, "#{base}/#{@type_name};#{a}")
    {:ok, _} = Content.delete_document(b, @type_name, @dataset)
    assert heard?(b, "delete"), "precondition: the page's topics never carried the delete"

    assert gone(view) == %{}, "a document that is not on the desk was noted as gone"
  end
end
