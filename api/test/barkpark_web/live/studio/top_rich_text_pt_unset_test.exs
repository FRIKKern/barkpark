defmodule BarkparkWeb.Studio.TopRichTextPtUnsetTest do
  @moduledoc """
  task-7565817187a53934: a Portable Text richText (`format: portableText`)
  whose store holds an HTML string (task-49a96a7780dad558), and B removes
  the field (an `unset`, or a `/v1` create or replace without it) under A's
  desk or Studio post, or while A's page was away. The store then held no
  string, so the string rule (`HtmlBody.stored_string?/2`) was not read, and
  A's post was written over B's removal as blocks, with no banner. A block
  body B removes keeps the removal and holds A (`ObjectRebase.rich_text/4`
  merges A's edit against no blocks and keeps the store), and so does the
  string one now: the page showed a string the store no longer holds.
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

    c
  end

  defp body(c), do: stored(c)["body"]

  # B's write through the store, as `/v1` makes it: the string as given.
  defp put_body(c, value) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")

    content =
      if value == :drop,
        do: Map.delete(doc.content, "body"),
        else: Map.put(doc.content, "body", value)

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

  # B's removal kept, and A held.
  defp kept_and_held(c, view, html) do
    assert body(c) in [nil, []], "A's post was written over B's removal: #{inspect(body(c))}"

    assert html =~ "doc-conflict-banner", "A was not held"
    assert has_element?(view, @banner)
  end

  # How the store starts: the string the task is about, or blocks (the rule
  # the string case follows).
  @starts [
    {"a string", "<p>body0</p>"},
    {"blocks",
     [
       %{
         "_type" => "block",
         "_key" => "b1",
         "style" => "normal",
         "markDefs" => [],
         "children" => [%{"_type" => "span", "_key" => "s1", "text" => "body0", "marks" => []}]
       }
     ]}
  ]

  for surface <- [:desk, :studio], {start, value} <- @starts do
    @surface surface
    @start value

    test "#{surface} race, #{start}: B removes the field under A's post: removed, A held", c do
      put_body(c, @start)
      a = tab(c, @surface)
      seen = page(a)
      b_save = fn -> Task.await(Task.async(fn -> put_body(c, :drop) end)) end

      html = inside(a, b_save, fn -> types(a, "<p>body0 A</p>", seen) end)

      # On main, a string: A's blocks were written over B's removal.
      kept_and_held(c, a, html)
    end

    test "#{surface} rejoin, #{start}: B removes the field while A's page was away: removed, A held",
         c do
      put_body(c, @start)
      a = tab(c, @surface)
      seen = page(a)
      GenServer.stop(a.pid, :normal)
      put_body(c, :drop)

      a2 = rejoined(c, @surface)
      html = types(a2, "<p>body0 A7</p>", seen)

      kept_and_held(c, a2, html)
    end

    test "#{surface} control, #{start}: A alone types: written, no banner", c do
      put_body(c, @start)
      a = tab(c, @surface)
      html = types(a, "<p>body0 A1</p>", page(a))
      assert words(body(c)) == ["body0 A1"]
      refute html =~ "doc-conflict-banner"
    end
  end

  test "control: A types into a field that was absent from the start: written, no banner", c do
    put_body(c, :drop)
    a = tab(c, :studio)
    html = types(a, "<p>first A</p>", page(a))
    assert words(body(c)) == ["first A"]
    refute html =~ "doc-conflict-banner"
  end
end
