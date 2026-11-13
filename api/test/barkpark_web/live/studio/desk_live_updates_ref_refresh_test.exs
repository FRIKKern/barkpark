defmodule BarkparkWeb.Studio.DeskLiveUpdatesRefRefreshTest do
  @moduledoc """
  J23: a read-only document pane shows its references by their titles. When a
  referenced document is saved (in the desk's own editor, or by someone
  else), the pane reads again and shows the new title. Before, a document pane
  read again only on a save of its own `{type, id}`.

  The rule (`LiveRefresh.refresh/1`): a read-only document pane reads again
  when a changed document's type is one its reference fields can point at
  (`Refs.target_types/1`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    author = "j23_author_#{n}"
    post = "j23_post_#{n}"
    other = "j23_other_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => author,
          "title" => "J23 authors",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => other,
          "title" => "J23 others",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => post,
          "title" => "J23 posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "author", "title" => "Author", "type" => "reference", "to" => [author]}
          ]
        },
        @dataset
      )

    ada = "j23-ada-#{n}"
    bob = "j23-bob-#{n}"
    one = "j23-post-#{n}"

    for {id, title} <- [{ada, "Ada Published"}, {bob, "Bob Published"}] do
      {:ok, _} = Content.create_document(author, %{"doc_id" => id, "title" => title}, @dataset)
    end

    {:ok, _} =
      Content.create_document(other, %{"doc_id" => "j23-x-#{n}", "title" => "X"}, @dataset)

    {:ok, _} =
      Content.create_document(
        post,
        %{
          "doc_id" => one,
          "title" => "Post One",
          "content" => %{"author" => %{"_ref" => ada, "_type" => "reference"}}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    raw = "desk-j23-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-j23", @dataset, ["read", "write", "admin"], ws.id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: conn,
     base: base,
     author: author,
     post: post,
     other: other,
     ada: ada,
     bob: bob,
     one: one}
  end

  # Wait for a value the view reaches after a message, never right after a send.
  defp poll(view, fun, tries \\ 50) do
    render_async(view, 5_000)

    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && poll(view, fun, tries - 1)
    end
  end

  defp parent_shows?(view, title),
    do: has_element?(view, ~s([data-pane-index="2"] a[data-desk-ref]), title)

  defp parent(view),
    do: view |> element(~s([data-pane-index="2"])) |> render() |> String.slice(0, 400)

  test "the parent pane shows the new title after the referenced doc is saved", c do
    chain = "#{c.post};#{c.one};#{c.ada},type=#{c.author},parentRefPath=author"
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{chain}")
    assert poll(view, fn -> parent_shows?(view, "Ada Published") end)

    view
    |> form(~s([data-pane-index="3"] #editor-form))
    |> render_change(%{"doc" => %{"title" => "Ada Renamed"}})

    assert poll(view, fn ->
             {doc, _d, _p} = Content.fetch_doc_with_draft(c.author, c.ada, @dataset)
             doc.title == "Ada Renamed"
           end)

    assert poll(view, fn -> parent_shows?(view, "Ada Renamed") end),
           "the parent pane still shows: " <> parent(view)
  end

  test "a referenced document that is not open, saved by someone else, shows its new title", c do
    # Bob is in the editor; Ada is only a reference link in the read-only pane.
    chain = "#{c.post};#{c.one};#{c.bob},type=#{c.author}"
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{chain}")
    assert poll(view, fn -> parent_shows?(view, "Ada Published") end)

    {:ok, _} =
      Content.upsert_document(
        c.author,
        %{"doc_id" => c.ada, "title" => "Ada Elsewhere"},
        @dataset
      )

    send(view.pid, {:document_changed, %{type: c.author, doc_id: c.ada}})

    assert poll(view, fn -> parent_shows?(view, "Ada Elsewhere") end),
           "the parent pane still shows: " <> parent(view)
  end

  test "a save of a type the pane cannot reference does not read the pane again", c do
    chain = "#{c.post};#{c.one};#{c.bob},type=#{c.author}"
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{chain}")
    assert poll(view, fn -> parent_shows?(view, "Ada Published") end)

    # Renamed in the store behind the app's back (no broadcast of its own),
    # then announced as another type's change: a pane that read again would
    # show the new title.
    %{num_rows: rows} =
      Barkpark.Repo.query!(
        "UPDATE documents SET title = 'Ada Quiet' WHERE doc_id IN ($1, $2)",
        [c.ada, "drafts." <> c.ada]
      )

    assert rows > 0

    send(view.pid, {:document_changed, %{type: c.other, doc_id: "j23-x"}})
    # The refresh fires 120 ms after a change; wait well past it.
    Process.sleep(600)
    render_async(view, 5_000)

    assert parent_shows?(view, "Ada Published"), "the pane read again: " <> parent(view)
  end
end
