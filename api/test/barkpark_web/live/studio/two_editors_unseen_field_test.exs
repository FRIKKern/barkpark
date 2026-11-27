defmodule BarkparkWeb.Studio.TwoEditorsUnseenFieldTest do
  @moduledoc """
  task-f18af43e26e46ff4, review of #26988: another editor saves a field this
  page does not draw at that moment, and the person edits it once it is drawn.

  A post with no number for a field is merged from what the page showed
  before the first push it did not take (`RemoteValues`). That only holds if
  the page numbers every value it shows. Two ways it did not:

    * R1: the field was on another group tab (or hidden by visibleWhen), so
      bp-array-focus.js found no input and wrote no number. It now writes the
      new number: the field is drawn later from the server's form.
    * R2: a document view was open, so the form (and `_bp_seen`) was not on
      the page; it came back as "{}". The server now draws `_bp_seen` with the
      number of each field's latest value (`RemoteValues.seen_value/1`),
      under "drawn": read only beside `v`, since an older copy of the JS
      posts those numbers back stale (X1).

  Each post here is what the page sends after that change.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "uf_post_#{n}"
    doc_id = "uf-post-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "UF posts",
          "visibility" => "public",
          "groups" => [
            %{"name" => "main", "title" => "Main"},
            %{"name" => "seo", "title" => "SEO"}
          ],
          "desk" => %{
            "views" => [%{"id" => "refs", "title" => "Refs", "type" => type, "by" => "kicker"}]
          },
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "kicker", "title" => "Kicker", "type" => "string", "group" => "main"},
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "text", "group" => "seo"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => doc_id,
          "title" => "Hello",
          "content" => %{"excerpt" => "Short.", "kicker" => "K"}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "unseen-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "unseen", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: conn,
     url: "#{base}/#{type}/#{doc_id}",
     desk: "#{base}/_desk/#{type};#{doc_id}",
     type: type,
     doc_id: doc_id}
  end

  defp open(c, url) do
    {:ok, view, _html} = live(c.conn, url)
    render(view)
    view
  end

  defp form_of(view),
    do:
      Map.take(:sys.get_state(view.pid).socket.assigns.editor_form, ["title", "excerpt", "kicker"])

  # What the page's bp-array-focus.js posts: its numbers and its `v`.
  defp send_post(view, target, changes, seen),
    do: post(view, target, changes, Map.put(seen, "v", 2))

  # A tab still running the JS from before this change: no number for a
  # field it did not draw, and no `v`.
  defp old_js_post(view, target, changes), do: post(view, target, changes, %{})

  defp post(view, target, changes, seen) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc", target],
      "doc" => Map.merge(form_of(view), changes),
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  defp told(view) do
    render(view)
    assert_push_event(view, "bp:form-remote-values", %{values: values} = payload)
    {values, Map.get(payload, :seqs, %{})}
  end

  # The `_bp_seen` the server drew into the form.
  defp drawn_seen(view) do
    [value] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s(input[name="_bp_seen"]))
      |> LazyHTML.attribute("value")

    Jason.decode!(value)
  end

  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    Map.put(Map.take(doc.content || %{}, ["excerpt", "kicker"]), "title", doc.title)
  end

  for surface <- [:desk, :studio] do
    describe "R1 a field on another group tab (#{surface})" do
      setup c, do: {:ok, at: if(unquote(surface) == :desk, do: c.desk, else: c.url)}

      test "A edits B's word after switching tab: no duplication", c do
        a = open(c, c.at)
        b = open(c, c.at)
        render_click(a, "select-group", %{"group" => "main"})
        refute render(a) =~ ~s(name="doc[excerpt]")

        send_post(b, "excerpt", %{"excerpt" => "Short. world"}, %{})
        # The excerpt is not drawn: the page numbers the value it will draw.
        {_values, seqs} = told(a)
        seen = %{"doc[excerpt]" => List.last(seqs["doc[excerpt]"])}

        render_click(a, "select-group", %{"group" => "seo"})
        assert render(a) =~ "Short. world"
        send_post(a, "excerpt", %{"excerpt" => "Short. word"}, seen)

        assert stored(c)["excerpt"] == "Short. word"
      end
    end
  end

  # Review r2 of #26988: the same posts from a tab loaded before the deploy
  # (old JS: "{}") store what main stores.
  for {surface, typed, want} <- [
        {:studio, "Short. word", "Short. word"},
        {:desk, "Short. word", "Short. word"},
        {:studio, "Short.", "Short."}
      ] do
    test "R1 from a tab running the old JS: #{inspect(typed)} stores as on main (#{surface})",
         c do
      at = if unquote(surface) == :desk, do: c.desk, else: c.url
      a = open(c, at)
      b = open(c, at)
      render_click(a, "select-group", %{"group" => "main"})

      send_post(b, "excerpt", %{"excerpt" => "Short. world"}, %{})
      told(a)
      render_click(a, "select-group", %{"group" => "seo"})
      old_js_post(a, "excerpt", %{"excerpt" => unquote(typed)})

      assert stored(c)["excerpt"] == unquote(want)
    end
  end

  # The desk keeps a post that returns a field to the value its editor_doc
  # holds as "untouched" (already so on main): task-9db9c20cd53351ab.
  test "R1 A deletes B's words after switching tab: the deletion stays (studio)", c do
    a = open(c, c.url)
    b = open(c, c.url)
    render_click(a, "select-group", %{"group" => "main"})

    send_post(b, "excerpt", %{"excerpt" => "Short. world"}, %{})
    {_values, seqs} = told(a)
    seen = %{"doc[excerpt]" => List.last(seqs["doc[excerpt]"])}

    render_click(a, "select-group", %{"group" => "seo"})
    send_post(a, "excerpt", %{"excerpt" => "Short."}, seen)

    assert stored(c)["excerpt"] == "Short."
  end

  test "R2 a view hides the form while B saves: the form comes back numbered", c do
    a = open(c, c.url)
    b = open(c, c.url)

    send_post(a, "title", %{"title" => "Hello A"}, %{})
    render_click(a, "select-view", %{"view" => "refs"})
    refute has_element?(a, "#editor-form")

    send_post(b, "title", %{"title" => "Hello A and B"}, %{})
    render(a)
    render_click(a, "select-view", %{"view" => "refs"})
    assert has_element?(a, "#editor-form")

    # A deletes " and B" from the title it sees, posting the drawn numbers.
    seen = drawn_seen(a)
    assert is_integer(seen["drawn"]["doc[title]"])
    send_post(a, "title", %{"title" => "Hello A"}, seen)

    assert stored(c)["title"] == "Hello A"
  end

  # Review r3 of #26988 (X1): the form is drawn again with the server's
  # numbers (a document view closed), then another editor saves the field
  # while it is on another group tab. An older copy of the JS skips that push
  # (no input), so the drawn number it posts back is stale; the new JS writes
  # the field's own number, which wins.
  for surface <- [:desk, :studio], js <- [:old, :new] do
    test "X1 #{surface}, #{js} JS: a drawn number gone stale merges nothing", c do
      a = open(c, if(unquote(surface) == :desk, do: c.desk, else: c.url))
      b = open(c, if(unquote(surface) == :desk, do: c.desk, else: c.url))

      render_click(a, "select-view", %{"view" => "refs"})
      refute has_element?(a, "#editor-form")
      send_post(b, "excerpt", %{"excerpt" => "Short. world"}, %{})
      _ = told(a)
      render_click(a, "select-view", %{"view" => "refs"})
      # An older copy of the JS keeps the drawn value as it is.
      seen = drawn_seen(a)

      render_click(a, "select-group", %{"group" => "main"})
      refute render(a) =~ ~s(name="doc[excerpt]")
      send_post(b, "excerpt", %{"excerpt" => "Short. world now"}, %{})
      {_values, seqs} = told(a)

      render_click(a, "select-group", %{"group" => "seo"})
      assert render(a) =~ "Short. world now"

      case unquote(js) do
        :old ->
          post(a, "excerpt", %{"excerpt" => "Short. world new"}, seen)

        :new ->
          seen = Map.put(seen, "doc[excerpt]", List.last(seqs["doc[excerpt]"]))
          send_post(a, "excerpt", %{"excerpt" => "Short. world new"}, seen)
      end

      assert stored(c)["excerpt"] == "Short. world new"
    end
  end

  # It carries only the digest of each value it shows (`TextConfirmed`,
  # task-fe9d8741f0641f97), which no number reads.
  test "a form drawn before any push draws no numbers", c do
    a = open(c, c.url)
    seen = drawn_seen(a)
    assert Map.keys(seen) == ["ok"]
    assert seen["ok"]["doc[title]"] =~ ~r/^[0-9a-f]{16}$/
  end
end
