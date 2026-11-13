defmodule BarkparkWeb.Studio.DeskListRefPreviewTest do
  @moduledoc """
  refs.spec:179 (J23, line 229): a list row whose preview reads through a
  reference (`list_preview.subtitle: "author.name"`) follows the referenced
  document. The list read again only on a change of its own type, so after
  the author was renamed elsewhere its rows kept the old name.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @list ~s([data-pane-index="1"])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    author = "lr_author_#{n}"
    post = "lr_post_#{n}"
    other = "lr_other_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => author,
          "title" => "LR authors",
          "visibility" => "public",
          "list_preview" => %{"title" => "name"},
          "fields" => [%{"name" => "name", "title" => "Name", "type" => "string"}]
        },
        @dataset
      )

    for {name, preview, fields} <- [
          {post, %{"title" => "title", "subtitle" => "author.name"},
           [
             %{"name" => "title", "title" => "Title", "type" => "string"},
             %{"name" => "author", "title" => "Author", "type" => "reference", "to" => [author]}
           ]},
          {other, %{"title" => "title"},
           [%{"name" => "title", "title" => "Title", "type" => "string"}]}
        ] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => name,
            "title" => name,
            "visibility" => "public",
            "list_preview" => preview,
            "fields" => fields
          },
          @dataset
        )
    end

    ada = "lr-ada-#{n}"

    {:ok, _} =
      Content.create_document(
        author,
        %{"doc_id" => ada, "content" => %{"name" => "Ada Lovelace"}},
        @dataset
      )

    for i <- 1..2 do
      {:ok, _} =
        Content.create_document(
          post,
          %{
            "doc_id" => "lr-post-#{n}-#{i}",
            "title" => "Post #{i}",
            "content" => %{"author" => %{"_ref" => ada, "_type" => "reference"}}
          },
          @dataset
        )

      {:ok, _} =
        Content.create_document(
          other,
          %{"doc_id" => "lr-other-#{n}-#{i}", "title" => "Other #{i}"},
          @dataset
        )
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-lr-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-lr", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: conn,
     base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk",
     n: n,
     author: author,
     post: post,
     other: other,
     ada: ada}
  end

  defp poll(view, fun, tries \\ 50) do
    render_async(view, 5_000)

    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && poll(view, fun, tries - 1)
    end
  end

  defp list(view), do: view |> element(@list) |> render() |> String.slice(0, 1500)

  test "a list row's subtitle read through a reference follows a rename", c do
    # The list is not the pane being edited: a post is open after it.
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.post};lr-post-#{c.n}-1")
    assert poll(view, fn -> has_element?(view, "#{@list} .dk-row-sub", "Ada Lovelace") end)

    {:ok, _} =
      Content.upsert_document(
        c.author,
        %{"doc_id" => c.ada, "content" => %{"name" => "Ada Byron"}},
        @dataset
      )

    send(view.pid, {:document_changed, %{type: c.author, doc_id: c.ada}})

    assert poll(view, fn ->
             has_element?(view, "#{@list} .dk-row-sub", "Ada Byron") and
               not has_element?(view, "#{@list} .dk-row-sub", "Ada Lovelace")
           end),
           "the list: " <> list(view)
  end

  test "control: a list whose preview reads no reference is not read again", c do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.other};lr-other-#{c.n}-1")
    assert poll(view, fn -> has_element?(view, "#{@list} a.pane-item", "Other 2") end)

    # Renamed in the store behind the app's back, then an author change is
    # announced: a list that read again would show the new title.
    %{num_rows: rows} =
      Barkpark.Repo.query!(
        "UPDATE documents SET title = 'Other quiet' WHERE doc_id IN ($1, $2)",
        ["lr-other-#{c.n}-2", "drafts.lr-other-#{c.n}-2"]
      )

    assert rows > 0
    send(view.pid, {:document_changed, %{type: c.author, doc_id: c.ada}})
    Process.sleep(600)
    render_async(view, 5_000)

    assert has_element?(view, "#{@list} a.pane-item", "Other 2"), "the list: " <> list(view)
    refute has_element?(view, "#{@list} a.pane-item", "Other quiet")
  end
end
