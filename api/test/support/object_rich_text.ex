defmodule BarkparkWeb.ObjectRichText do
  @moduledoc """
  Fixtures and helpers for the tests of rich text inside an object
  (task-47be2cdf59d0acd5): a schema with `meta.rt`, `meta.rt2` and a row's
  rich text, a document of it, and two tabs' posts.
  """

  import ExUnit.Assertions
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @event "bp:rt-remote"
  @endpoint BarkparkWeb.Endpoint

  @doc "The schema, two documents and a signed-in conn; the test context."
  def setup_doc(conn) do
    n = System.unique_integer([:positive])
    type = "obj_rt_remote_#{n}"
    rt = fn name -> %{"name" => name, "title" => name, "type" => "richText"} end

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Object rich text",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            rt.("body"),
            %{
              "name" => "meta",
              "title" => "Meta",
              "type" => "composite",
              "fields" => [
                %{"name" => "label", "title" => "Label", "type" => "string"},
                rt.("rt"),
                rt.("rt2"),
                %{
                  "name" => "rows",
                  "title" => "Rows",
                  "type" => "arrayOf",
                  "of" => [
                    %{
                      "type" => "composite",
                      "name" => "row",
                      "title" => "Row",
                      "fields" => [rt.("rt")]
                    }
                  ]
                }
              ]
            }
          ]
        },
        @dataset
      )

    id = "obj-rt-remote-#{n}"

    meta = %{
      "label" => "l0",
      "rt" => [block("k1", "one two")],
      "rt2" => [block("q1", "second")],
      "rows" => [%{"_type" => "row", "_key" => "r1", "rt" => [block("w1", "rowtext")]}]
    }

    for {doc_id, rt} <- [{id, meta["rt"]}, {id <> "-link", link()}] do
      {:ok, _} =
        Content.create_document(
          type,
          %{
            "doc_id" => doc_id,
            "title" => "T0",
            "content" => %{"body" => [block("b1", "body0")], "meta" => Map.put(meta, "rt", rt)}
          },
          @dataset
        )
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "obj-rt-remote-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "obj-rt-remote", @dataset, ~w(read write admin), ws_id)
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    %{
      conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
      root: root,
      surface: :desk,
      type: type,
      id: id
    }
  end

  def block(key, text) do
    %{
      "_type" => "block",
      "_key" => key,
      "style" => "normal",
      "markDefs" => [],
      "children" => [%{"_type" => "span", "_key" => key <> "s", "text" => text, "marks" => []}]
    }
  end

  def link do
    [
      %{
        "_type" => "block",
        "_key" => "k1",
        "style" => "normal",
        "markDefs" => [%{"_type" => "link", "_key" => "m1", "href" => "https://x.example"}],
        "children" => [
          %{"_type" => "span", "_key" => "s1", "text" => "one ", "marks" => []},
          %{"_type" => "span", "_key" => "s2", "text" => "two", "marks" => ["m1"]}
        ]
      }
    ]
  end

  def open(c) do
    path =
      case c.surface do
        :desk -> "#{c.root}/_desk/#{c.type};#{c.id}"
        :studio -> "#{c.root}/#{c.type}/#{c.id}"
      end

    {:ok, view, _html} = live(c.conn, path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  def eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  def stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc.content
  end

  def words(blocks) when is_list(blocks),
    do: for(%{"children" => spans} <- blocks, do: Enum.map_join(spans, & &1["text"]))

  def words(_), do: nil

  def wraps(view) do
    ~r/<div id="([^"]+)"[^>]*data-pt-subfield="([^"]+)"/
    |> Regex.scan(render(view))
    |> Map.new(fn [_, id, name] -> {name, id} end)
  end

  def form(view), do: :sys.get_state(view.pid).socket.assigns.editor_form

  def send_post(view, target, fields) do
    view
    |> element("#editor-form")
    |> render_change(Map.merge(%{"_target" => [target], "doc" => %{"title" => "T0"}}, fields))
  end

  def b_saves_rt(b, c, html, words) do
    send_post(b, "doc[meta].rt", %{"doc[meta].label" => "l0", "doc[meta].rt" => html})
    assert eventually(fn -> words(stored(c)["meta"]["rt"]) == words end)
  end

  @doc """
  A's page as bp-rt-remote.js keeps one editor's numbers: `seen/1` is what
  its `_bp_rt_seen` reports. `got/3` takes a push, drawn at once or left
  waiting (A typing); `drew/1`, the waiting value drawn once A is idle.
  """
  def page, do: %{last: 0, first: nil}

  def got(page, %{seq: seq} = v, draw?) do
    first = if page.first && !v[:own], do: page.first, else: seq
    %{last: max(page.last, seq), first: if(draw?, do: nil, else: first)}
  end

  def drew(page), do: %{page | first: nil}
  def seen(%{first: nil, last: last}), do: last
  def seen(%{first: first}), do: first - 1

  @doc "The next value pushed to `view` for `doc[meta].rt`."
  def next_push(view) do
    assert_push_event(view, @event, %{values: %{"doc[meta].rt" => v}}, 2_000)
    v
  end

  def post_rt(view, html, seen) do
    send_post(view, "doc[meta].rt", %{
      "doc[meta].label" => "l0",
      "doc[meta].rt" => html,
      "_bp_rt_seen" => ["doc[meta].rt|#{seen}"]
    })
  end

  # B adds a paragraph, and A's editor shows it; then B rewrites "two" in
  # the first block. A's editor, still showing "one two" there, types right
  # after "two": both edited one word, a clash of that block, held with the
  # banner. (Two edits to different words of one block merge once
  # task-266ffbe9cd115f3c lands, so the clash is an overlap on purpose.) The number of the
  # view A is sent (A's block, B's paragraph). The store keeps B's.
  def held_by_clash(a, b, c) do
    b_saves_rt(b, c, "<p>one two</p><p>B para</p>", ["one two", "B para"])
    assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: seen}}}, 2_000)
    b_saves_rt(b, c, "<p>one TWO</p><p>B para</p>", ["one TWO", "B para"])
    assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: seq}}}, 2_000)

    html = post_rt(a, "<p>one twoA</p><p>B para</p>", seen)

    assert html =~ "Someone else rewrote"

    assert_push_event(
      a,
      @event,
      %{values: %{"doc[meta].rt" => %{seq: view, html: shown}}},
      2_000
    )

    assert view > seq and shown =~ "one twoA" and shown =~ "B para"
    view
  end
end
