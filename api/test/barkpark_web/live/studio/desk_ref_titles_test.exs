defmodule BarkparkWeb.Studio.DeskRefTitlesTest do
  @moduledoc """
  refs.spec:179 (J23): a reference link shows its target's name, and follows
  a rename.

  (a) A type with no `title` field names its list title in
  `list_preview.title` (an author's `name`). The stored `title` column kept
  the first name a document had (the writer filled it only when blank, until
  task-f20c582a579fa514; rows renamed before that still carry the old name),
  so a link read from it showed the old name. The link now reads the
  `list_preview` field, as the desk's rows do.

  (b) The pane that edits shows its links in a strip, read again only when
  its reference ids change. A change to a document of a type its references
  can point at now reads the strip again too.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    author = "rt_author_#{n}"
    post = "rt_post_#{n}"
    other = "rt_other_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => author,
          "title" => "RT authors",
          "visibility" => "public",
          "list_preview" => %{"title" => "name"},
          "fields" => [%{"name" => "name", "title" => "Name", "type" => "string"}]
        },
        @dataset
      )

    for {name, fields} <- [
          {other, [%{"name" => "title", "title" => "Title", "type" => "string"}]},
          {post,
           [
             %{"name" => "title", "title" => "Title", "type" => "string"},
             %{"name" => "author", "title" => "Author", "type" => "reference", "to" => [author]}
           ]}
        ] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => name, "title" => name, "visibility" => "public", "fields" => fields},
          @dataset
        )
    end

    ada = "rt-ada-#{n}"
    bob = "rt-bob-#{n}"
    one = "rt-post-#{n}"

    for {id, name} <- [{ada, "Ada Lovelace"}, {bob, "Bob Kahn"}] do
      {:ok, _} =
        Content.create_document(
          author,
          %{"doc_id" => id, "content" => %{"name" => name}},
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
    raw = "desk-rt-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-rt", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: conn,
     base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk",
     author: author,
     post: post,
     other: other,
     ada: ada,
     bob: bob,
     one: one}
  end

  defp poll(view, fun, tries \\ 50) do
    render_async(view, 5_000)

    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && poll(view, fun, tries - 1)
    end
  end

  # Someone else renames Ada: the name moves, the stored title column stays.
  # The writer now moves the column with the name (task-f20c582a579fa514), so
  # the stale column a row renamed before that still carries is written behind
  # the app's back: the link must read the name, not the column.
  defp rename_elsewhere(c, name) do
    %{num_rows: rows} =
      Barkpark.Repo.query!(
        "UPDATE documents SET content = jsonb_set(content, '{name}', to_jsonb($1::text)) WHERE doc_id IN ($2, $3)",
        [name, c.ada, "drafts." <> c.ada]
      )

    assert rows > 0

    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(c.author, c.ada, @dataset)
    assert {doc.title, doc.content["name"]} == {"Ada Lovelace", name}
  end

  @read_only ~s([data-pane-index="2"])
  @edit "[data-pane-editing]"

  # The pane's one link shows `name`, and no longer `old`.
  defp shows?(view, pane, name, old \\ nil) do
    has_element?(view, pane <> " a[data-desk-ref]", name) and
      (old == nil or not has_element?(view, pane <> " a[data-desk-ref]", old))
  end

  defp strip(view, pane), do: view |> element(pane) |> render() |> String.slice(0, 600)

  test "(a) a read-only pane's link shows the target's list_preview name after a rename", c do
    chain = "#{c.post};#{c.one};#{c.bob},type=#{c.author}"
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{chain}")
    assert poll(view, fn -> shows?(view, @read_only, "Ada Lovelace") end)

    rename_elsewhere(c, "Ada Byron")
    send(view.pid, {:document_changed, %{type: c.author, doc_id: c.ada}})

    assert poll(view, fn -> shows?(view, @read_only, "Ada Byron", "Ada Lovelace") end),
           "the pane: " <> strip(view, @read_only)
  end

  test "(b) the edit pane's strip follows a rename of a referenced document", c do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.post};#{c.one}")
    assert poll(view, fn -> shows?(view, @edit, "Ada Lovelace") end)

    rename_elsewhere(c, "Ada Byron")
    send(view.pid, {:document_changed, %{type: c.author, doc_id: c.ada}})

    assert poll(view, fn -> shows?(view, @edit, "Ada Byron", "Ada Lovelace") end),
           "the edit pane: " <> strip(view, @edit)
  end

  test "control: a change of a type the editor cannot reference does not read its strip", c do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.post};#{c.one}")
    assert poll(view, fn -> shows?(view, @edit, "Ada Lovelace") end)

    # Renamed in the store behind the app's back, then announced as another
    # type's change: a strip that read again would show the new name.
    %{num_rows: rows} =
      Barkpark.Repo.query!(
        "UPDATE documents SET content = jsonb_set(content, '{name}', '\"Ada Quiet\"') WHERE doc_id IN ($1, $2)",
        [c.ada, "drafts." <> c.ada]
      )

    assert rows > 0
    send(view.pid, {:document_changed, %{type: c.other, doc_id: "rt-x"}})
    Process.sleep(600)
    render_async(view, 5_000)

    assert shows?(view, @edit, "Ada Lovelace", "Ada Quiet"),
           "the edit pane: " <> strip(view, @edit)
  end
end
