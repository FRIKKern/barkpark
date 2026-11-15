defmodule BarkparkWeb.Studio.StalePostKeepsRemoteTest do
  @moduledoc """
  task-a4ded0be5c8ec3cb: a post already on its way when another editor's save
  reached the page does not put the old values back.

  A and B have one document open. B saves `note`, `byline`, `score`, `flag`
  and the title; A's page takes them. A change A made in `g` just before left
  the browser carrying the OLD values of B's fields. The store keeps B's
  values for it. The form buffer took the whole post, so A's page drew the old
  values again and A's next change anywhere wrote them over B's.

  The first post is sent as the browser sent it (old values); every later one
  is the form as the page now draws it.

  The two stale-post tests run in the desk only. In the old Studio the list
  topic's frame reloads `editor_doc` before the stale post arrives, so that
  post is read as an edit of every field and the store takes the old values at
  once: another cause, in the store's base and not in the form buffer
  (task-9db9c20cd53351ab). The other two tests run in both.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  @old %{
    "note" => "old note",
    "byline" => "old byline",
    "score" => 1,
    "flag" => false,
    "g" => "g0",
    "h" => "h0"
  }

  # What the page of an editor who has not seen B's save posts.
  @old_post %{
    "title" => "Old title",
    "note" => "old note",
    "byline" => "old byline",
    "score" => "1",
    "flag" => "false",
    "g" => "g0",
    "h" => "h0"
  }

  @new_post %{
    "title" => "New title",
    "note" => "new note",
    "byline" => "new byline",
    "score" => "2",
    "flag" => "true"
  }

  @new %{"note" => "new note", "byline" => "new byline", "score" => 2, "flag" => true}

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "stale_post_#{n}"
    doc_id = "stale-post-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Stale posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "note", "title" => "Note", "type" => "text"},
            %{"name" => "byline", "title" => "Byline", "type" => "string"},
            %{"name" => "score", "title" => "Score", "type" => "number"},
            %{"name" => "flag", "title" => "Flag", "type" => "boolean"},
            %{"name" => "g", "title" => "G", "type" => "string"},
            %{"name" => "h", "title" => "H", "type" => "string"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => doc_id, "title" => "Old title", "content" => @old},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "stale-post-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "stale-post", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: conn,
     type: type,
     doc_id: doc_id,
     studio: {"#{base}/#{type}/#{doc_id}", "#editor-form"},
     desk: {"#{base}/_desk/#{type};#{doc_id}", "[data-pane-editing] #editor-form"}}
  end

  defp open(c, surface) do
    {url, sel} = Map.fetch!(c, surface)
    {:ok, view, _html} = live(c.conn, url)
    render_async(view, 5_000)
    assert Enum.any?(1..200, fn _ -> has_element?(view, sel) or (Process.sleep(10) && false) end)
    {view, sel}
  end

  # A post with exactly these values: what a browser that drew them sends.
  defp sends({view, sel}, target, doc) do
    view |> element(sel) |> render_change(%{"_target" => ["doc", target], "doc" => doc})
  end

  # A change of one field, every other input as the page draws it now.
  defp type_in({view, sel}, name, text) do
    view |> form(sel, %{"doc" => %{name => text}}) |> render_change(%{"_target" => ["doc", name]})
  end

  # What the page draws for a text input now.
  defp shown({view, sel}, name) do
    html = view |> element(~s(#{sel} input[name="doc[#{name}]"])) |> render()
    [_, value] = Regex.run(~r/\svalue="([^"]*)"/, html)
    value
  end

  defp stored(c) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    Map.put(doc.content || %{}, "title", doc.title)
  end

  # B saves its fields and A's page takes them.
  defp b_saves(c, surface, a) do
    b = open(c, surface)
    sends(b, "note", Map.merge(@old_post, @new_post))
    assert Map.take(stored(c), Map.keys(@new)) == @new
    render(elem(a, 0))
    assert shown(a, "byline") == "new byline"
  end

  test "desk: A's post from before B's save, then a change elsewhere: B's values stay",
       c do
    a = open(c, :desk)
    b_saves(c, :desk, a)

    sends(a, "g", Map.put(@old_post, "g", "g typed"))

    assert Map.take(stored(c), Map.keys(@new)) == @new
    assert shown(a, "byline") == "new byline"
    assert shown(a, "score") == "2"

    type_in(a, "h", "h typed")

    assert stored(c) ==
             Map.merge(@new, %{"title" => "New title", "g" => "g typed", "h" => "h typed"})
  end

  test "desk: A's post from before B's save, then Save: B's values stay", c do
    a = open(c, :desk)
    b_saves(c, :desk, a)

    sends(a, "g", Map.put(@old_post, "g", "g typed"))
    {view, sel} = a
    view |> form(sel) |> render_submit()

    assert stored(c) ==
             Map.merge(@new, %{"title" => "New title", "g" => "g typed", "h" => "h0"})
  end

  for surface <- [:studio, :desk] do
    @surface surface

    test "#{surface}: a field A changes after B's save is A's", c do
      a = open(c, @surface)
      b_saves(c, @surface, a)

      type_in(a, "score", "5")
      type_in(a, "byline", "A's byline")
      type_in(a, "flag", "false")
      type_in(a, "h", "h typed")

      assert stored(c) ==
               %{
                 "title" => "New title",
                 "note" => "new note",
                 "byline" => "A's byline",
                 "score" => 5,
                 "flag" => false,
                 "g" => "g0",
                 "h" => "h typed"
               }
    end

    test "#{surface}: A alone: two changes land and nothing else moves", c do
      a = open(c, @surface)

      sends(a, "g", Map.put(@old_post, "g", "g typed"))
      assert shown(a, "g") == "g typed"
      type_in(a, "h", "h typed")

      assert stored(c) ===
               Map.merge(@old, %{"title" => "Old title", "g" => "g typed", "h" => "h typed"})
    end
  end
end
