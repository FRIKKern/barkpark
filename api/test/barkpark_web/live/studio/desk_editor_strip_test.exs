defmodule BarkparkWeb.Studio.DeskEditorStripTest do
  @moduledoc """
  Journey J08 in the desk's editor pane: the targets of the document's
  references follow what the editor saves. A reference picked or cleared
  shows at once, with no reload (`EditorHost` reads the targets again when
  the ids the document holds change). A single reference's card is drawn in
  the browser and is the link to the next pane, so the targets are pushed to
  it (`desk:ref-targets`); the "…" menu holds a link only for an array's
  references ("Open reference: <title>").

  Measured in a browser first (editing-w2 probe): before the fix a pick was
  saved and the strip kept the old link until the page was reloaded.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    author = "w2t_author_#{n}"
    post = "w2t_post_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => author,
          "title" => "W2 test authors",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "bio", "title" => "Bio", "type" => "string"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => post,
          "title" => "W2 test posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "author", "title" => "Author", "type" => "reference", "to" => [author]},
            %{
              "name" => "authors",
              "title" => "Authors",
              "type" => "arrayOf",
              "of" => %{"type" => "reference", "to" => [%{"type" => author}]}
            }
          ]
        },
        @dataset
      )

    ada = "w2t-ada-#{n}"
    bob = "w2t-bob-#{n}"
    one = "w2t-post-#{n}"

    for {id, title} <- [{ada, "Ada Published"}, {bob, "Bob Published"}] do
      {:ok, _} =
        Content.create_document(
          author,
          %{"doc_id" => id, "title" => title, "content" => %{"bio" => "About " <> title}},
          @dataset
        )
    end

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

    {:ok, conn: conn, base: base, author: author, post: post, ada: ada, bob: bob, one: one}
  end

  defp admin(conn) do
    raw = "desk-w2-token-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-w2", @dataset, ["read", "write", "admin"], ws.id)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp settle(view), do: render_async(view, 5_000)

  # Wait for a condition on the view itself, never assert right after a send.
  defp poll(view, fun, tries \\ 25) do
    settle(view)

    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && poll(view, fun, tries - 1)
    end
  end

  @ref ~s(section[data-pane-editing] > .pane-header a[data-desk-doc-action="open-reference"])

  # The single reference's target, as last pushed to its card.
  defmacrop assert_target(view, id, title) do
    quote do
      id = unquote(id)

      assert_push_event(
        unquote(view),
        "desk:ref-targets",
        %{refs: [%{path: "author", id: ^id, title: unquote(title), type: _}]},
        5_000
      )
    end
  end

  test "a reference picked in the editor shows in the link strip without a reload", c do
    {:ok, view, _html} = live(admin(c.conn), "#{c.base}/#{c.post};#{c.one}")
    settle(view)

    assert_target(view, c.ada, "Ada Published")

    # What the picker's hidden input posts (BarkparkFieldBridge -> phx-change).
    view |> form("#editor-form") |> render_change(%{"doc" => %{"author" => c.bob}})

    # The pick is saved...
    assert poll(view, fn ->
             {doc, _draft?, _pub?} = Content.fetch_doc_with_draft(c.post, c.one, @dataset)
             match?(%{"_ref" => _}, doc.content["author"]) or doc.content["author"] == c.bob
           end)

    # ...and its card is told the new target, alone.
    assert_target(view, c.bob, "Bob Published")
  end

  test "a cleared reference leaves the link strip without a reload", c do
    {:ok, view, _html} = live(admin(c.conn), "#{c.base}/#{c.post};#{c.one}")
    settle(view)
    assert_target(view, c.ada, "Ada Published")

    view |> form("#editor-form") |> render_change(%{"doc" => %{"author" => ""}})

    assert poll(view, fn ->
             {doc, _d, _p} = Content.fetch_doc_with_draft(c.post, c.one, @dataset)
             doc.content["author"] in [nil, ""]
           end),
           "the clear was not saved"

    assert_push_event(view, "desk:ref-targets", %{refs: []}, 5_000)
  end

  # Measured in a browser: when the row of links only came into the page with
  # its first link, the patch that added it rebuilt the editor below, and the
  # focus (on the picker's Change button after a pick) fell to the page. The
  # links are now in the header's menu, which is there with or without them.
  test "no row of links above the editor; the menu keeps its place when the last link goes",
       c do
    {:ok, view, _html} = live(admin(c.conn), "#{c.base}/#{c.post};#{c.one}")
    settle(view)
    pane = "section[data-pane-editing]"
    refute has_element?(view, "#{pane} nav.dk-edit-refs")
    refute has_element?(view, "#{pane} > nav")
    # A single reference's card is its link: no hidden twin in the menu.
    refute has_element?(view, @ref), "in the menu: " <> inspect(strip(view))

    view |> form("#editor-form") |> render_change(%{"doc" => %{"author" => ""}})
    assert_push_event(view, "desk:ref-targets", %{refs: []}, 5_000)

    assert has_element?(view, ~s(#{pane} > .pane-header [role="menu"][id$="-actions"]))
    assert has_element?(view, "#{pane} > .pane-body[id] #editor-form")
  end

  defp strip(view) do
    view
    |> render()
    |> then(
      &Regex.scan(~r/<a[^>]*data-desk-doc-action="open-reference"[^>]*>\s*([^<]*?)\s*</, &1)
    )
    |> Enum.map(&List.last/1)
  end
end
