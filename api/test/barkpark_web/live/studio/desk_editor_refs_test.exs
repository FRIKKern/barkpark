defmodule BarkparkWeb.Studio.DeskEditorRefsTest do
  @moduledoc """
  References in the desk's editor pane (journey J08): the link strip above
  the editor (`nav.dk-edit-refs a[data-desk-ref]`), following a link into the
  next pane, and the parent pane left of it.

  Three strip/parent journeys are broken in the desk (a reference picked or
  cleared in the editor does not update the strip until a reload; the parent
  pane keeps the old title after the referenced document is saved); their red
  tests stay on branch `editing/probe` for the rows that own them.
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

  # J08 (WORKS, pinned): a link opens the target as the next pane, the parent stays.
  test "a strip link opens its target as the next pane and keeps the parent", c do
    {:ok, view, _html} = live(admin(c.conn), "#{c.base}/#{c.post};#{c.one}")
    settle(view)

    to_ada = "#{c.base}/#{c.post};#{c.one};#{c.ada},type=#{c.author},parentRefPath=author"
    view |> element(~s(nav.dk-edit-refs a[data-desk-ref][href="#{to_ada}"])) |> render_click()
    assert_patch(view, to_ada)
    settle(view)

    assert poll(view, fn ->
             has_element?(view, ~s([data-pane-index="3"][data-pane-editing] #editor-form))
           end)

    assert poll(view, fn ->
             has_element?(
               view,
               ~s([data-pane-index="3"] #editor-form input[name="doc[title]"][value="Ada Published"])
             )
           end),
           "the next pane never showed the referenced document's title"

    # The parent stays, a read-only pane now, with its own link marked current.
    assert has_element?(view, ~s([data-pane-index="2"][data-pane-kind="doc"]))
    refute has_element?(view, ~s([data-pane-index="2"][data-pane-editing]))
  end

  # J08: in a BROWSER the parent pane stays a skeleton (aria-busy, title =
  # raw id, no fields; measured at 1, 4 and 10 s) after a strip link opens the
  # next pane (tmp/editing-w2/p4-parent-skeleton.mjs). This LiveViewTest is
  # GREEN: the test client mounts the pane's component afresh and it reads.
  # Suspected cause: `PaneComponent.update/2` keeps a pane first drawn with
  # `hold` (loading, no read) when it comes back with the same id and
  # data_key (the `same?` branch). Kept as the server-side pin.
  test "the parent pane reads its document after a strip link opens the next pane", c do
    {:ok, view, _html} = live(admin(c.conn), "#{c.base}/#{c.post};#{c.one}")
    settle(view)

    to_ada = "#{c.base}/#{c.post};#{c.one};#{c.ada},type=#{c.author},parentRefPath=author"
    view |> element(~s(nav.dk-edit-refs a[data-desk-ref][href="#{to_ada}"])) |> render_click()
    settle(view)

    assert poll(view, fn ->
             has_element?(view, ~s([data-pane-index="2"] .pane-header-title), "Post One") and
               not has_element?(view, ~s([data-pane-index="2"][aria-busy="true"]))
           end),
           "the parent pane never loaded: " <>
             (view |> element(~s([data-pane-index="2"])) |> render() |> String.slice(0, 300))
  end
end
