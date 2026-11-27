defmodule BarkparkWeb.Studio.TopRichTextPtStringTest do
  @moduledoc """
  task-49a96a7780dad558 (#29066 review, check 3): a Portable Text richText
  (`format: portableText`, not the legacy `body`) whose store holds an HTML
  string. `/v1` takes a string for it as it is (create, createOrReplace,
  patch set), and an import or an old row leaves one. A's desk or Studio
  post is read as blocks. B's string, written while A typed or while A's
  page was away, was overwritten by A's next post with no banner.

  The store's string is never converted or merged: a string A's post was
  not read against stays as stored, a string B removed stays removed, and
  A is held with the banner. A string A's post was read against, still
  stored, is written over by A's edit as before (owner ruling #44: Studio
  turns a stored string into blocks at the next save).

  Not here: B removing the field (`unset`) under A's post or while A was
  away. The store then holds no string, and A's post is written over the
  removal (task filed from this one).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias BarkparkWeb.PageSeen

  @moduletag :studio_live

  @banner ~s([data-test-id="doc-conflict-banner"])

  setup %{conn: conn} do
    c = setup_doc(conn)
    {:ok, schema} = Content.get_schema(c.type, "production")

    fields =
      Enum.map(schema.fields, fn
        %{"name" => "body"} = f -> Map.put(f, "format", "portableText")
        f -> f
      end)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => c.type,
          "title" => "Object rich text",
          "visibility" => "public",
          "fields" => fields
        },
        "production"
      )

    put_body(c, "<p>body0</p>")
    c
  end

  defp body(c), do: stored(c)["body"]

  # B's write through the store, as `/v1` makes it: the string as given.
  defp put_body(c, value) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")
    content = Map.put(doc.content, "body", value)

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => doc.title, "content" => content},
        "production"
      )
  end

  defp tab(c, surface) do
    path =
      case surface do
        :desk -> "#{c.root}/_desk/#{c.type};#{c.id}"
        :studio -> "#{c.root}/#{c.type}/#{c.id}"
      end

    {:ok, view, _html} = live(c.conn, path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  # LiveViewTest always joins with `_mounts: 0`: the rejoin is the state
  # `TextConfirmed.loaded/1` gives a socket that mounted as one.
  defp rejoined(c, surface) do
    view = tab(c, surface)

    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns, &Map.put(&1, :editor_rt_rejoin, MapSet.new(["doc[body]"])))
    end)

    view
  end

  defp page(view), do: view |> PageSeen.seen() |> Map.put("v", 2)

  defp types(view, html, seen) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc[body]"],
      "doc" => %{"title" => "T0", "body" => html},
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  # B's string kept byte for byte, and A held.
  defp kept_and_held(c, view, html, b_val) do
    assert body(c) == b_val, "A's post was written over B's string: #{inspect(body(c))}"

    assert html =~ "doc-conflict-banner", "A was not held"
    assert has_element?(view, @banner)
  end

  # A removal (`unset`) leaves no string, and is not read here: see the
  # moduledoc.
  @bs [
    {"B rewrites", "<p>bodB</p>"},
    {"B adds a paragraph", "<p>body0</p><p>B para</p>"}
  ]

  for surface <- [:desk, :studio] do
    @surface surface

    for {label, b_val} <- @bs do
      @b_val b_val

      test "#{surface} race, #{label}: B's API write lands under A's post: B's kept, A held",
           c do
        c = Map.put(c, :surface, @surface)
        a = tab(c, @surface)
        seen = page(a)
        b_save = fn -> Task.await(Task.async(fn -> put_body(c, @b_val) end)) end

        html = inside(a, b_save, fn -> types(a, "<p>body0 A</p>", seen) end)

        # On main: A's blocks were written over B's value.
        kept_and_held(c, a, html, @b_val)
      end

      test "#{surface} rejoin, #{label}: B's API write while A's page was away: B's kept, A held",
           c do
        a = tab(c, @surface)
        seen = page(a)
        GenServer.stop(a.pid, :normal)
        put_body(c, @b_val)

        a2 = rejoined(c, @surface)
        html = types(a2, "<p>body0 A7</p>", seen)

        kept_and_held(c, a2, html, @b_val)
      end
    end

    test "#{surface} control: A alone types on the stored string: written, no banner, then again",
         c do
      a = tab(c, @surface)
      seen = page(a)
      html = types(a, "<p>body0 A1</p>", seen)
      assert words(body(c)) == ["body0 A1"]
      refute html =~ "doc-conflict-banner"

      html = types(a, "<p>body0 A1 A2</p>", page(a))
      assert words(body(c)) == ["body0 A1 A2"]
      refute html =~ "doc-conflict-banner"
    end

    test "#{surface} control: A alone, the page rejoins on the stored string: written, no banner",
         c do
      a = tab(c, @surface)
      seen = page(a)
      GenServer.stop(a.pid, :normal)

      a2 = rejoined(c, @surface)
      html = types(a2, "<p>body0 A7</p>", seen)
      assert words(body(c)) == ["body0 A7"]
      refute html =~ "doc-conflict-banner"
    end
  end
end
