defmodule BarkparkWeb.Studio.ObjectRichTextRemoteTest do
  @moduledoc """
  task-47be2cdf59d0acd5: rich text inside an object or a row is drawn in a
  `phx-update="ignore"` wrapper. B's save of it reached A's form, but A's
  editor kept the old text, and A's next post wrote it back over B's. A
  remount would throw away A's unposted typing (#28349 review), so the
  server sends theirs to the open editor in place (`bp:rt-remote`), and a
  post typed over theirs is held with the conflict banner, never written
  over it (`Handlers.RichTextRemote`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @event "bp:rt-remote"

  setup %{conn: conn} do
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

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     root: root,
     surface: :desk,
     type: type,
     id: id}
  end

  defp block(key, text) do
    %{
      "_type" => "block",
      "_key" => key,
      "style" => "normal",
      "markDefs" => [],
      "children" => [%{"_type" => "span", "_key" => key <> "s", "text" => text, "marks" => []}]
    }
  end

  defp link do
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

  defp open(c) do
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

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc.content
  end

  defp words(blocks) when is_list(blocks),
    do: for(%{"children" => spans} <- blocks, do: Enum.map_join(spans, & &1["text"]))

  defp words(_), do: nil

  defp wraps(view) do
    ~r/<div id="([^"]+)"[^>]*data-pt-subfield="([^"]+)"/
    |> Regex.scan(render(view))
    |> Map.new(fn [_, id, name] -> {name, id} end)
  end

  defp form(view), do: :sys.get_state(view.pid).socket.assigns.editor_form

  defp send_post(view, target, fields) do
    view
    |> element("#editor-form")
    |> render_change(Map.merge(%{"_target" => [target], "doc" => %{"title" => "T0"}}, fields))
  end

  defp b_saves_rt(b, c, html, words) do
    send_post(b, "doc[meta].rt", %{"doc[meta].label" => "l0", "doc[meta].rt" => html})
    assert eventually(fn -> words(stored(c)["meta"]["rt"]) == words end)
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: B edits meta.rt: A's open editor is sent theirs, never remounted", c do
      c = %{c | surface: @surface}
      a = open(c)
      b = open(c)
      before = wraps(a)

      b_saves_rt(b, c, "<p>one two</p><p>B para</p>", ["one two", "B para"])

      assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: seq, html: html}}}, 2_000)
      assert is_integer(seq) and html =~ "B para"
      assert wraps(a) == before
    end

    # #28349 r3 review, K5/S5p/K8: B added a paragraph while A typed in
    # another block. A's post was held, and A's next one wrote over B's
    # paragraph, which A's editor never showed.
    test "#{surface}: B adds a paragraph while A types in another block: both are saved, no banner",
         c do
      c = %{c | surface: @surface}
      a = open(c)
      b = open(c)

      b_saves_rt(b, c, "<p>one two</p><p>B para</p>", ["one two", "B para"])
      assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: seq}}}, 2_000)

      html = post_rt(a, "<p>one twoHel</p>", seq - 1)

      assert words(stored(c)["meta"]["rt"]) == ["one twoHel", "B para"]
      refute html =~ "Someone else rewrote"
      assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: m, html: merged}}}, 2_000)
      assert m > seq and merged =~ "one twoHel" and merged =~ "B para"

      # K8: A types on before its editor has shown the merge.
      post_rt(a, "<p>one twoHello</p>", m - 1)
      assert words(stored(c)["meta"]["rt"]) == ["one twoHello", "B para"]
      assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: m2}}}, 2_000)

      # Shown: A's text is saved as typed.
      post_rt(a, "<p>one twoHello!</p><p>B para</p>", m2)
      assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["one twoHello!", "B para"] end)
      refute render(a) =~ "Someone else rewrote"
    end

    test "#{surface}: A and B rewrote the same block: theirs stays stored and is in the banner; only typing on what A was shown saves A's",
         c do
      c = %{c | surface: @surface}
      a = open(c)
      b = open(c)
      view = held_by_clash(a, b, c)

      assert words(stored(c)["meta"]["rt"]) == ["B one two", "B para"]
      assert words(form(a)["meta"]["rt"]) == ["one two A", "B para"]

      assert render(a) =~
               ~r|<blockquote class="bp-doc-conflict-theirs"[^>]*>B one two</blockquote>|

      # A typed on before its editor showed the view: held again.
      html = post_rt(a, "<p>one two AA</p>", view - 1)
      assert words(stored(c)["meta"]["rt"]) == ["B one two", "B para"]
      assert html =~ "Someone else rewrote"
      assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: view2}}}, 2_000)

      # Typing on what A was shown saves A's block; B's paragraph stays.
      post_rt(a, "<p>one two AAA</p><p>B para</p>", view2)
      assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["one two AAA", "B para"] end)
    end

    # Held, then B saves again: a paragraph B2 adds reaches A's held view,
    # and typing on it keeps it.
    test "#{surface}: while A is held, another save of the same rich text is merged into A's view",
         c do
      c = %{c | surface: @surface}
      a = open(c)
      b = open(c)
      _view = held_by_clash(a, b, c)

      send_post(b, "doc[meta].rt", %{
        "doc[meta].label" => "l0",
        "doc[meta].rt" => "<p>B one two</p><p>B para</p><p>B2 para</p>"
      })

      assert eventually(fn -> length(stored(c)["meta"]["rt"]) == 3 end)

      assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: v, html: html}}}, 2_000)
      assert html =~ "one two A" and html =~ "B2 para"
      assert words(form(a)["meta"]["rt"]) == ["one two A", "B para", "B2 para"]

      post_rt(a, "<p>one two AX</p><p>B para</p><p>B2 para</p>", v)

      assert eventually(fn ->
               words(stored(c)["meta"]["rt"]) == ["one two AX", "B para", "B2 para"]
             end)
    end
  end

  # #28349 r3 review, K6: the hold drew the banner above an id-less
  # fieldset; the patch took the fieldset out and put it back, which blurred
  # the editor and ended A's IME composition.
  test "desk: the fields' fieldset keeps one id through a hold, so the patch keeps it in place",
       c do
    a = open(c)
    b = open(c)
    assert render(a) =~ ~s(<fieldset id="dk-readonly-fields")
    _ = held_by_clash(a, b, c)
    assert render(a) =~ "bp-doc-conflict"
    assert render(a) =~ ~s(<fieldset id="dk-readonly-fields")
  end

  test "B saves the sibling meta.rt2: only rt2 is sent", c do
    a = open(c)
    b = open(c)

    send_post(b, "doc[meta].rt2", %{
      "doc[meta].label" => "l0",
      "doc[meta].rt2" => "<p>second B</p>"
    })

    assert eventually(fn -> words(stored(c)["meta"]["rt2"]) == ["second B"] end)

    assert_push_event(a, @event, %{values: values}, 2_000)
    assert Map.keys(values) == ["doc[meta].rt2"]
  end

  test "B edits the rich text of a row in the object: A's editor is sent it", c do
    a = open(c)
    b = open(c)
    before = wraps(a)
    assert Map.has_key?(before, "doc[meta].rows[0].rt")

    send_post(b, "doc[meta].rows[0].rt", %{
      "doc[meta].label" => "l0",
      "doc[meta].rows[0]._type" => "row",
      "doc[meta].rows[0]._key" => "r1",
      "doc[meta].rows[0].rt" => "<p>rowtext B</p>"
    })

    assert eventually(fn -> words(hd(stored(c)["meta"]["rows"])["rt"]) == ["rowtext B"] end)

    assert_push_event(
      a,
      @event,
      %{values: %{"doc[meta].rows[0].rt" => %{html: html}}},
      2_000
    )

    assert html =~ "rowtext B"
    assert wraps(a) == before
  end

  test "after A's own post of a linked text, B's saves of a string and the top-level body send A nothing",
       c do
    c = %{c | id: c.id <> "-link"}
    a = open(c)
    b = open(c)

    # A's own post comes back with new keys: no change of what it draws.
    send_post(a, "doc[meta].rt", %{
      "doc[meta].label" => "l0",
      "doc[meta].rt" => ~s(<p>one A <a href="https://x.example" data-pt-def="m1">two</a></p>)
    })

    assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["one A two"] end)

    # B's page was sent A's text but, with no browser here, its hidden input
    # still holds the old one: it reports the number it showed, as
    # bp-rt-remote.js does, and its old text is not written over A's.
    seen = %{"_bp_rt_seen" => ["doc[meta].rt|0"]}
    send_post(b, "doc[meta].label", Map.put(seen, "doc[meta].label", "l0 B"))
    assert eventually(fn -> stored(c)["meta"]["label"] == "l0 B" end)

    b
    |> element("#editor-form")
    |> render_change(
      Map.merge(seen, %{
        "_target" => ["doc", "body"],
        "doc" => %{"title" => "T0", "body" => "<p>body B</p>"}
      })
    )

    assert eventually(fn -> words(stored(c)["body"]) == ["body B"] end)
    assert eventually(fn -> form(a)["meta"]["label"] == "l0 B" end)
    assert words(stored(c)["meta"]["rt"]) == ["one A two"]
    refute_push_event(a, @event, %{values: _}, 300)
  end

  test "A's post of another field carries the old text it never touched: theirs stands", c do
    a = open(c)
    b = open(c)

    b_saves_rt(b, c, "<p>one two B</p>", ["one two B"])
    assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: seq}}}, 2_000)

    html =
      send_post(a, "doc[meta].label", %{
        "doc[meta].label" => "l0 A",
        "doc[meta].rt" => "<p>one two</p>",
        "_bp_rt_seen" => ["doc[meta].rt|#{seq - 1}"]
      })

    assert eventually(fn -> stored(c)["meta"]["label"] == "l0 A" end)
    assert words(stored(c)["meta"]["rt"]) == ["one two B"]
    refute html =~ "Someone else rewrote"
  end

  test "a post with no _bp_rt_seen (a page from before) is written as before", c do
    a = open(c)
    b = open(c)

    b_saves_rt(b, c, "<p>one two B</p>", ["one two B"])
    assert eventually(fn -> words(form(a)["meta"]["rt"]) == ["one two B"] end)

    send_post(a, "doc[meta].rt", %{
      "doc[meta].label" => "l0",
      "doc[meta].rt" => "<p>one two A</p>"
    })

    assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["one two A"] end)
  end

  # #28349 r2 review, S9: past 20k the page was told only that it changed,
  # so an idle A never showed it and A's next post was held, then saved over
  # it.
  test "theirs past 20k is sent whole, in an event of its own", c do
    a = open(c)
    b = open(c)
    long = String.duplicate("word ", 5_000)

    b_saves_rt(b, c, "<p>#{long}</p>", [String.trim_trailing(long)])

    assert_push_event(
      a,
      @event,
      %{values: %{"doc[meta].rt" => %{seq: seq, html: html}} = told},
      2_000
    )

    assert map_size(told) == 1
    assert is_integer(seq) and byte_size(html) > 20_000 and html =~ "word word"
  end

  # #28349 r2 review, SV2: Reload took theirs into the form but the editor
  # kept A's held words, and A's next word wrote them over B's, with no
  # banner.
  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: Reload sends the stored text to show at once; a post from an editor that never showed it is held",
         c do
      c = %{c | surface: @surface}
      a = open(c)
      b = open(c)
      view = held_by_clash(a, b, c)

      a |> element("[phx-click=reload-remote-doc]") |> render_click()

      assert_push_event(
        a,
        @event,
        %{values: %{"doc[meta].rt" => %{seq: shown, html: html, reload: true}}},
        2_000
      )

      assert shown > view and html =~ "B one two"
      assert words(form(a)["meta"]["rt"]) == ["B one two", "B para"]
      refute render(a) =~ "bp-doc-conflict-theirs"

      # An editor that still shows A's held words: held again, B's stays.
      html = post_rt(a, "<p>one two AZ</p><p>B para</p>", shown - 1)
      assert words(stored(c)["meta"]["rt"]) == ["B one two", "B para"]
      assert html =~ "Someone else rewrote"

      # The editor showed it: A's word lands on B's text.
      a |> element("[phx-click=reload-remote-doc]") |> render_click()

      assert_push_event(
        a,
        @event,
        %{values: %{"doc[meta].rt" => %{seq: again, reload: true}}},
        2_000
      )

      post_rt(a, "<p>B one two Z</p><p>B para</p>", again)
      assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["B one two Z", "B para"] end)
    end

    # #28349 r2 review, V1: an explicit Save skipped the check and wrote A's
    # stale text over B's.
    test "#{surface}: a Save of a stale rich text is held as an autosave is", c do
      c = %{c | surface: @surface}
      a = open(c)
      b = open(c)

      b_saves_rt(b, c, "<p>B one two</p>", ["B one two"])
      assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: seq}}}, 2_000)

      html =
        a
        |> element("#editor-form")
        |> render_submit(%{
          "doc" => %{"title" => "T0"},
          "doc[meta].label" => "l0 A",
          "doc[meta].rt" => "<p>one two A</p>",
          "_bp_rt_seen" => ["doc[meta].rt|#{seq - 1}"]
        })

      assert eventually(fn -> stored(c)["meta"]["label"] == "l0 A" end)
      assert words(stored(c)["meta"]["rt"]) == ["B one two"]
      assert words(form(a)["meta"]["rt"]) == ["one two A"]
      assert html =~ "Someone else rewrote"
    end
  end

  # #28349 r3, S6b: A's composition was under way when the hold came, and
  # its commit counted as typing on. The page reports the number before the
  # view it has not shown yet, so the commit is read against theirs again
  # and held. Typing on the view it showed saves A's.
  test "the commit of a composition begun before the hold is held again; input after it types on",
       c do
    a = open(c)
    b = open(c)
    view = held_by_clash(a, b, c)

    html = post_rt(a, "<p>one two Aか漢</p>", view - 1)

    assert words(stored(c)["meta"]["rt"]) == ["B one two", "B para"]
    assert words(form(a)["meta"]["rt"]) == ["one two Aか漢", "B para"]
    assert html =~ "Someone else rewrote"
    assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: view2}}}, 2_000)

    post_rt(a, "<p>one two Aか漢 Q</p><p>B para</p>", view2)
    assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["one two Aか漢 Q", "B para"] end)
  end

  defp post_rt(view, html, seen) do
    send_post(view, "doc[meta].rt", %{
      "doc[meta].label" => "l0",
      "doc[meta].rt" => html,
      "_bp_rt_seen" => ["doc[meta].rt|#{seen}"]
    })
  end

  # B rewrites the first block and adds a paragraph; A's editor, still
  # showing "one two", posts a word in that block: a clash, held with the
  # banner. The number of the view A is sent (A's block, B's paragraph).
  defp held_by_clash(a, b, c) do
    b_saves_rt(b, c, "<p>B one two</p><p>B para</p>", ["B one two", "B para"])
    assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: seq}}}, 2_000)

    html = post_rt(a, "<p>one two A</p>", seq - 1)

    assert html =~ "Someone else rewrote"

    assert_push_event(
      a,
      @event,
      %{values: %{"doc[meta].rt" => %{seq: view, html: shown}}},
      2_000
    )

    assert view > seq and shown =~ "one two A" and shown =~ "B para"
    view
  end

  test "theirs is sent as the first paint draws it: markup typed as text stays text", c do
    a = open(c)
    b = open(c)

    send_post(b, "doc[meta].rt", %{
      "doc[meta].label" => "l0",
      "doc[meta].rt" =>
        ~s|<p>&lt;img src=x onerror=alert(1)&gt;&lt;script&gt;x()&lt;/script&gt; <a href="javascript:alert(1)">go</a></p>|
    })

    assert eventually(fn -> hd(words(stored(c)["meta"]["rt"])) =~ "<img src=x" end)
    assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{html: html}}}, 2_000)

    assert html == Barkpark.Content.PortableText.to_html(stored(c)["meta"]["rt"])
    refute html =~ "<img"
    refute html =~ "<script"
    assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
  end
end
