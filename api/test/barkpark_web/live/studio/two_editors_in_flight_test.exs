defmodule BarkparkWeb.Studio.TwoEditorsInFlightTest do
  @moduledoc """
  task-f18af43e26e46ff4 (rig J06): two browsers type in one title at once.

  Each page posts 300 ms after its last key, so the two posts cross. When B's
  save lands first, A's post was already on its way: it left the page before
  the push that numbers B's value reached it, so its `_bp_seen` names nothing
  for the title. The server read "nothing" as "no base" and let A's post
  stand, and B's words were gone from both pages.

  A post with no number is the page's text typed from the value it showed
  before the first push it has not taken: its own landed post, or the value
  the first push said it showed. Those are its base now. Every post here is
  what bp-array-focus.js sends; the stored row is read back after each.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.StudioLive.Handlers.RemoteValues

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "if_post_#{n}"
    doc_id = "if-post-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "IF posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "text"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => doc_id,
          "title" => "Fixture post 14",
          "content" => %{"excerpt" => "Short."}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "in-flight-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "in-flight", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: conn,
     url: "#{base}/#{type}/#{doc_id}",
     desk: "#{base}/_desk/#{type};#{doc_id}",
     type: type,
     doc_id: doc_id}
  end

  # The desk loads its editor on a message to itself after the join: the
  # render waits for it, so a save made next is one this page is told of.
  defp open(c, url) do
    {:ok, view, _html} = live(c.conn, url)
    render(view)
    view
  end

  defp form_of(view),
    do: Map.take(:sys.get_state(view.pid).socket.assigns.editor_form, ["title", "excerpt"])

  # `v` is what bp-array-focus.js writes into `_bp_seen` (it numbers every
  # value it shows); `old_js_post/3` is a tab still running the file before it.
  defp send_post(view, target, changes, seen \\ %{}),
    do: post(view, target, changes, Map.put(seen, "v", 2))

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

  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    %{"title" => doc.title, "excerpt" => (doc.content || %{})["excerpt"]}
  end

  # The numbers the last push named per field, [was, new], as the page keeps them.
  defp told(view) do
    render(view)
    assert_push_event(view, "bp:form-remote-values", %{values: values} = payload)
    {values, Map.get(payload, :seqs, %{})}
  end

  for surface <- [:desk, :studio] do
    describe "J05 then J06 (#{surface})" do
      setup c, do: {:ok, at: if(unquote(surface) == :desk, do: c.desk, else: c.url)}

      test "B's prefix and A's suffix both stay when A's post crosses B's save", c do
        a = open(c, c.at)
        b = open(c, c.at)

        # J05: A in the title, B in the excerpt. B is told A's title and shows it.
        send_post(a, "title", %{"title" => "Fixture post 14 A"})
        {_values, b_seqs} = told(b)
        b_seen = %{"doc[title]" => List.last(b_seqs["doc[title]"])}
        send_post(b, "excerpt", %{"excerpt" => "Short. B"}, b_seen)
        told(a)
        assert stored(c) == %{"title" => "Fixture post 14 A", "excerpt" => "Short. B"}

        # J06: B lands first; A's post left before B's push reached A.
        send_post(b, "title", %{"title" => "bbb Fixture post 14 A"}, b_seen)
        send_post(a, "title", %{"title" => "Fixture post 14 A aaa"})

        assert stored(c)["title"] == "bbb Fixture post 14 A aaa"
        assert stored(c)["excerpt"] == "Short. B"

        # A's page is told B's title (it shows its own typing, so keeps it),
        # then the merged title over the text it posted, which it takes...
        {values, _} = told(a)
        assert values["doc[title]"] == %{value: "bbb Fixture post 14 A", was: "Fixture post 14 A"}
        {values, _} = told(a)

        assert values["doc[title]"] == %{
                 value: "bbb Fixture post 14 A aaa",
                 was: "Fixture post 14 A aaa"
               }

        assert form_of(a)["title"] == "bbb Fixture post 14 A aaa"
        # ...and so is B's, over its own title, which it takes.
        {values, _} = told(b)

        assert values["doc[title]"] == %{
                 value: "bbb Fixture post 14 A aaa",
                 was: "bbb Fixture post 14 A"
               }
      end

      test "the first edit of a fresh page merges too (no own post yet)", c do
        a = open(c, c.at)
        b = open(c, c.at)

        send_post(b, "title", %{"title" => "bbb Fixture post 14"})
        send_post(a, "title", %{"title" => "Fixture post 14 aaa"})

        assert stored(c)["title"] == "bbb Fixture post 14 aaa"
      end
    end
  end

  describe "the save path stays safe" do
    test "A's deletion in a crossing post stays deleted", c do
      a = open(c, c.desk)
      b = open(c, c.desk)

      send_post(a, "title", %{"title" => "Fixture post 14 A"})
      {_values, seqs} = told(b)
      b_seen = %{"doc[title]" => List.last(seqs["doc[title]"])}
      send_post(b, "title", %{"title" => "bbb Fixture post 14 A"}, b_seen)
      send_post(a, "title", %{"title" => "Fixture post 14"})

      assert stored(c)["title"] == "bbb Fixture post 14"
    end

    test "fast typing on both sides: every post keeps both people's words", c do
      a = open(c, c.desk)
      b = open(c, c.desk)

      # Round 1: the first posts cross. Neither page has a number yet.
      send_post(b, "title", %{"title" => "b Fixture post 14"})
      send_post(a, "title", %{"title" => "Fixture post 14 a"})
      assert stored(c)["title"] == "b Fixture post 14 a"

      # Both keep typing, so neither page takes what it is told: each keeps
      # the number of the value it was typed from (bp-array-focus.js).
      {_values, a1} = told(a)
      {_values, _a2} = told(a)
      {_values, b1} = told(b)
      a_seen = %{"doc[title]" => hd(a1["doc[title]"])}
      b_seen = %{"doc[title]" => hd(b1["doc[title]"])}

      # Round 2: each page's next post is its own text typed on.
      send_post(b, "title", %{"title" => "bb Fixture post 14"}, b_seen)
      send_post(a, "title", %{"title" => "Fixture post 14 aa"}, a_seen)
      assert stored(c)["title"] == "bb Fixture post 14 aa"
    end

    test "after Reload, a crossing post is merged from the reloaded value", c do
      a = open(c, c.desk)
      b = open(c, c.desk)

      send_post(a, "title", %{"title" => "Fixture post 14 A"})
      {_values, seqs} = told(b)
      b_seen = %{"doc[title]" => List.last(seqs["doc[title]"])}
      # Reload drops A's history (and its own post with it).
      render_click(a, "reload-remote-doc", %{})
      send_post(b, "title", %{"title" => "bbb Fixture post 14 A"}, b_seen)
      send_post(a, "title", %{"title" => "Fixture post 14 A aaa"})

      assert stored(c)["title"] == "bbb Fixture post 14 A aaa"
    end

    test "past the kept history, a post with no number stands, as before", c do
      a = open(c, c.desk)
      b = open(c, c.desk)

      # Twenty saves by B, none taken by A: the value A last showed is no
      # longer kept, so nothing tells what A's post was typed from.
      for i <- 1..20, do: send_post(b, "title", %{"title" => "Fixture post 14 b#{i}"})
      send_post(a, "title", %{"title" => "Fixture post 14 aaa"})

      assert stored(c)["title"] == "Fixture post 14 aaa"
    end

    # task-4fc7383b936f606a: the title A typed on the old socket's value was
    # written over B's "bbb", with no banner. It is held now: B's title
    # stays, A's typing waits in the form with the banner.
    test "a page that rejoins: the other's field survives; its own field's post is held over B's",
         c do
      a = open(c, c.desk)
      b = open(c, c.desk)

      send_post(a, "title", %{"title" => "Fixture post 14 A"})
      # B shows A's title, and its page reports that number.
      {_values, seqs} = told(b)
      b_seen = %{"doc[title]" => List.last(seqs["doc[title]"])}

      # A drops off; B saves both fields; A's page rejoins on a new socket
      # and posts the title it typed meanwhile, with the old socket's number.
      GenServer.stop(a.pid, :normal)
      send_post(b, "excerpt", %{"excerpt" => "Short. B"}, b_seen)
      send_post(b, "title", %{"title" => "bbb Fixture post 14 A"}, b_seen)
      a2 = open(c, c.desk)
      send_post(a2, "title", %{"title" => "Fixture post 14 A aaa"}, %{"doc[title]" => 1})

      assert stored(c) == %{"title" => "bbb Fixture post 14 A", "excerpt" => "Short. B"}
      assert :sys.get_state(a2.pid).socket.assigns.editor_form["title"] == "Fixture post 14 A aaa"
      assert has_element?(a2, ~s([data-test-id="doc-conflict-banner"]))
    end

    # The desk's Paste field writes a value the server built: no `_bp_seen`.
    test "a change the server built (no _bp_seen at all) takes no base", c do
      a = open(c, c.desk)
      b = open(c, c.desk)

      send_post(a, "title", %{"title" => "Fixture post 14 A"})
      send_post(b, "title", %{"title" => "bbb Fixture post 14 A"})
      render(a)

      socket = :sys.get_state(a.pid).socket

      assert RemoteValues.put_bases(socket, ["title"], ~s({"v":2})).assigns.editor_field_bases ==
               %{"title" => "Fixture post 14 A"}

      assert RemoteValues.put_bases(socket, ["title"], nil).assigns.editor_field_bases == %{}
    end

    # A tab loaded before this change keeps its old bp-array-focus.js across a
    # deploy. It does not number a field it does not draw, so "no number" from
    # it is not a crossing: its post stands, as before (review r2 of #26988).
    for surface <- [:desk, :studio] do
      test "a crossing post from a tab running the old JS stands, as before (#{surface})", c do
        at = if unquote(surface) == :desk, do: c.desk, else: c.url
        a = open(c, at)
        b = open(c, at)

        send_post(b, "title", %{"title" => "bbb Fixture post 14"})
        old_js_post(a, "title", %{"title" => "Fixture post 14 aaa"})

        assert stored(c)["title"] == "Fixture post 14 aaa"
      end
    end
  end
end
