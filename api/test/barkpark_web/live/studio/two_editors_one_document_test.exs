defmodule BarkparkWeb.Studio.TwoEditorsOneDocumentTest do
  @moduledoc """
  task-6f5426c4b04de74b (J05): two people edit one document.

  The editor's `editor_dirty` turned on with the first keystroke and only an
  explicit save or Reload turned it off; a successful autosave never did. So
  once B had typed anything, every later save by A was treated as a conflict:
  B's form kept the OLD values under "Updated by another user — your unsaved
  edits are kept" although B had nothing unsaved, and B's next keystroke in
  that field wrote B's stale value over A's words.

  Two LiveView sessions on one document. Each `render_change/2` posts what the
  browser posts: the whole form, as the inputs on that session's page show it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "tw_post_#{n}"
    doc_id = "tw-post-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "TW posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "string"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => doc_id, "title" => "Fixture post", "content" => %{"excerpt" => "First"}},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "two-editors-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "two-editors", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    url = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/#{type}/#{doc_id}"

    {:ok, conn: conn, url: url, type: type, doc_id: doc_id}
  end

  defp open(c) do
    {:ok, view, _html} = live(c.conn, c.url)
    view
  end

  # What the input named `doc[<name>]` shows on this session's page.
  defp shown(view, name) do
    html = view |> element(~s(#editor-form input[name="doc[#{name}]"])) |> render()
    [_, value] = Regex.run(~r/value="([^"]*)"/, html)
    value
  end

  # The browser posts every input of the form, as shown, with `_target` naming
  # the one typed in.
  defp type_in(view, name, text) do
    form = %{"title" => shown(view, "title"), "excerpt" => shown(view, "excerpt")}
    form = Map.update!(form, name, &(&1 <> text))

    view
    |> element("#editor-form")
    |> render_change(%{"_target" => ["doc", name], "doc" => form})

    form
  end

  defp stored(c) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    {doc.title, (doc.content || %{})["excerpt"]}
  end

  test "B's autosave landed, A saves the title: B shows A's title and no conflict banner", c do
    a = open(c)
    b = open(c)

    type_in(b, "excerpt", " B1")
    assert stored(c) == {"Fixture post", "First B1"}

    type_in(a, "title", " A2")
    assert stored(c) == {"Fixture post A2", "First B1"}

    # B handles A's save broadcast before the next read.
    render(b)
    assert shown(b, "title") == "Fixture post A2"
    refute has_element?(b, ~s([data-test-id="doc-conflict-banner"]))
  end

  test "B then types in the title A changed: A's words stay in the store", c do
    a = open(c)
    b = open(c)

    type_in(b, "excerpt", " B1")
    type_in(a, "title", " A2")
    render(b)

    type_in(b, "title", " B3")

    assert stored(c) == {"Fixture post A2 B3", "First B1"}
  end

  test "B then types in the excerpt: A's title stays in the store", c do
    a = open(c)
    b = open(c)

    type_in(b, "excerpt", " B1")
    type_in(a, "title", " A2")
    render(b)

    type_in(b, "excerpt", " B2")

    assert stored(c) == {"Fixture post A2", "First B1 B2"}
  end
end
