defmodule BarkparkWeb.Studio.DeskLiveTest do
  @moduledoc """
  The desk slice (/papers/desk-vertical-slice): the pane chain comes from the
  URL, and every row is a real link whose href is the URL it patches to.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.PaneComponent

  @dataset "production"
  @type_name "desk_slice_note"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Desk slice notes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "summary", "title" => "Summary", "type" => "string"}
          ]
        },
        @dataset
      )

    n = System.unique_integer([:positive])

    for {id, title} <- [{"dsn-a-#{n}", "Alpha note"}, {"dsn-b-#{n}", "Beta note"}] do
      {:ok, _doc} =
        Content.create_document(
          @type_name,
          %{"doc_id" => id, "title" => title, "content" => %{"summary" => "About " <> title}},
          @dataset
        )
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok, conn: conn, base: base, a: "dsn-a-#{n}", b: "dsn-b-#{n}"}
  end

  defp sign_in(conn, permissions) do
    raw = "desk-slice-token-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-slice", @dataset, permissions, ws.id)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  # A pane's read runs in its own task; a list asks the Studio's pane builder,
  # which takes longer than render_async's default 100 ms on a busy machine.
  defp settle(view), do: render_async(view, 5_000)

  # A document pane shows `text`: as a printed field in a read-only pane, or
  # as a field's value in the Studio's editor (the last document of a chain).
  defp doc_shows?(view, index, text) do
    pane = ~s([data-pane-index="#{index}"])

    has_element?(view, pane <> " dd", text) or
      has_element?(view, pane <> ~s( #editor-form [value="#{text}"])) or
      has_element?(view, pane <> " #editor-form textarea", text)
  end

  defp admin(conn), do: sign_in(conn, ["read", "write", "admin"])

  test "the root URL draws the desk root alone, its rows links", %{conn: conn, base: base} do
    {:ok, view, _html} = live(admin(conn), base)
    settle(view)

    assert has_element?(
             view,
             ~s([data-testid="panes"] [data-pane-index="0"][data-pane-kind="types"])
           )

    refute has_element?(view, ~s([data-pane-index="1"]))
    assert has_element?(view, ~s([data-pane-index="0"] a[data-desk-row][href^="#{base}/"]))
    refute has_element?(view, "#desk-panes a[phx-click]")
  end

  test "the pane row has the TanStack name, and the labels bp-desk.js draws with", %{
    conn: conn,
    base: base
  } do
    {:ok, view, _html} = live(admin(conn), base)
    settle(view)

    assert has_element?(view, ~s(#desk-panes.panes[data-testid="panes"]))
    # The placeholder goes out as written: the script fills in the title.
    assert has_element?(view, ~s(#desk-panes[data-desk-expand="Expand %{title}"]))
    assert has_element?(view, ~s(#desk-panes[data-desk-resize="Resize pane"]))
  end

  test "the page has one main landmark, with and without the editor", %{
    conn: conn,
    base: base,
    a: a
  } do
    {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name}")
    settle(view)

    assert has_element?(view, ~s(#desk-panes[role="main"]))
    assert mains(view) == 1

    # The Studio's editor brings a main landmark of its own.
    view |> element(~s(a[data-desk-row][href$=";#{a}"])) |> render_click()
    settle(view)

    assert has_element?(view, "[data-pane-editing] #editor-form")
    refute has_element?(view, ~s(#desk-panes[role="main"]))
    assert mains(view) == 1
  end

  defp mains(view) do
    length(Regex.scan(~r/<main[\s>]|role="main"/, render(view)))
  end

  test "a deep link draws root, list and document", %{conn: conn, base: base, a: a} do
    {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")
    settle(view)

    assert has_element?(view, ~s([data-pane-index="0"][data-pane-kind="types"]))
    assert has_element?(view, ~s([data-pane-index="1"][data-pane-kind="list"]))
    assert has_element?(view, ~s([data-pane-index="2"][data-pane-kind="doc"]))
    refute has_element?(view, ~s([data-pane-index="3"]))

    # The open row is the current one; its sibling is not.
    assert has_element?(view, ~s([data-pane-index="1"] a[aria-current="true"]), "Alpha note")
    refute has_element?(view, ~s([data-pane-index="1"] a[aria-current="true"]), "Beta note")

    # The last document of the chain is in the Studio's own editor.
    assert has_element?(view, ~s([data-pane-index="2"][data-pane-editing] #editor-form))
    assert doc_shows?(view, 2, "About Alpha note")
  end

  test "a row's href is the pane URL, and following it patches there", %{
    conn: conn,
    base: base,
    a: a,
    b: b
  } do
    {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")
    settle(view)

    beta = ~s([data-pane-index="1"] a[data-desk-row][href="#{base}/#{@type_name};#{b}"])
    assert has_element?(view, beta, "Beta note")

    view |> element(beta) |> render_click()
    settle(view)
    assert_patch(view, "#{base}/#{@type_name};#{b}")

    assert has_element?(view, ~s([data-pane-index="1"] a[aria-current="true"]), "Beta note")
    assert doc_shows?(view, 2, "About Beta note")
  end

  test "closing a pane goes to the URL without it", %{conn: conn, base: base, a: a} do
    {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")
    settle(view)

    view |> element(~s([data-pane-index="2"] a.dk-close)) |> render_click()
    settle(view)
    assert_patch(view, "#{base}/#{@type_name}")
    refute has_element?(view, ~s([data-pane-index="2"]))
  end

  test "a URL that names a revision, a view or an inspector says what the desk shows instead", %{
    conn: conn,
    base: base,
    a: a,
    b: b
  } do
    # The last document of the chain: the editor, on the current document.
    {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a},rev=abc123")
    settle(view)
    assert has_element?(view, ~s([data-pane-index="2"] [data-desk-left-out]), "abc123")
    assert doc_shows?(view, 2, "About Alpha note")

    # A document further left: a read-only pane.
    chain = "#{@type_name};#{a},rev=abc123;#{b},type=#{@type_name}"
    {:ok, view, _html} = live(admin(conn), "#{base}/#{chain}")
    settle(view)
    assert has_element?(view, ~s([data-pane-index="2"] [data-desk-left-out]), "abc123")
    assert doc_shows?(view, 2, "About Alpha note")
    refute has_element?(view, ~s([data-pane-index="3"] [data-desk-left-out]))

    for param <- ["view=json", "inspect=sanity%2Fstructure%2Fhistory"] do
      {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a},#{param}")
      settle(view)
      assert has_element?(view, ~s([data-pane-index="2"] [data-desk-left-out])), param
    end

    {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")
    settle(view)
    refute has_element?(view, "[data-desk-left-out]")
  end

  test "a pane for a document that was not found shows no revision note", %{
    conn: conn,
    base: base,
    b: b
  } do
    # A read-only pane (not the last document) for an id that does not exist.
    chain = "#{@type_name};dsn-nobody,rev=abc123,view=json;#{b},type=#{@type_name}"
    {:ok, view, _html} = live(admin(conn), "#{base}/#{chain}")
    settle(view)

    assert has_element?(view, ~s([data-pane-index="2"] .dk-note), "dsn-nobody")
    refute has_element?(view, ~s([data-pane-index="2"] [data-desk-left-out]))
  end

  test "a pane URL whose bytes are not text after decoding reads as the text it spells", %{
    conn: conn,
    base: base
  } do
    # The router decodes once and the pane reader once more: %25FF is the byte
    # 0xFF by then. It must not reach a query or the page as that byte.
    # Encoded once, the router alone makes the byte: the same holds. So it
    # does for a NUL, which is UTF-8 but which Postgres refuses as text.
    for bad <- ~w(x%25FF x%25C3%2528 x%25E2%2582 x,path=%25FF x%FF x%C3%28 x%00 x%2500) do
      {:ok, view, html} = live(admin(conn), "#{base}/#{@type_name};#{bad}")
      settle(view)

      assert String.valid?(html), bad
      assert String.valid?(render(view)), bad
      assert has_element?(view, ~s([data-pane-index="2"]), "x"), bad
      refute has_element?(view, ~s(.dk-note[role="alert"])), bad

      # Not the last document of the chain: a read-only pane, which queries.
      {:ok, view, html} = live(admin(conn), "#{base}/#{@type_name};#{bad};y,type=#{@type_name}")
      settle(view)

      assert String.valid?(html), bad
      assert String.valid?(render(view)), bad
      assert has_element?(view, ~s([data-pane-index="2"] .dk-note), "x"), bad
      refute has_element?(view, ~s(.dk-note[role="alert"])), bad
    end

    # A link that decodes twice to text reads as it always did.
    {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};x%2541")
    settle(view)
    assert has_element?(view, ~s([data-pane-index="2"]), "xA")

    # The hover path takes its href from the browser: the same bytes, once encoded.
    view
    |> element("#desk-panes")
    |> render_hook("warm", %{"href" => "#{base}/#{@type_name};x%FF"})

    settle(view)
    assert String.valid?(render(view))
  end

  test "the editor's notes sit in a holder that stays when a note comes or goes", %{
    conn: conn,
    base: base,
    a: a
  } do
    # Every row of the editor pane has an id, so a live patch moves none of
    # them: a note with no holder made it re-append the editor's body.
    holder = ~s([data-pane-index="2"] > [id="desk-pane-2-doc:#{a}-notes"])

    {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")
    settle(view)
    assert has_element?(view, holder)
    refute has_element?(view, holder <> " [data-desk-left-out]")

    render_patch(view, "#{base}/#{@type_name};#{a},rev=abc123")
    settle(view)
    assert has_element?(view, holder <> " [data-desk-left-out]", "abc123")

    render_patch(view, "#{base}/#{@type_name};#{a}")
    settle(view)
    assert has_element?(view, holder)
    refute has_element?(view, "[data-desk-left-out]")

    # Every row of the pane after its header has an id.
    refute has_element?(view, ~s{[data-pane-index="2"] > :not(.pane-header):not([id])})
  end

  test "closing a pane keeps the tab title the pane now last had read", %{
    conn: conn,
    base: base,
    a: a
  } do
    {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")
    render_async(view)
    assert page_title(view) =~ "Alpha note"

    view |> element(~s([data-pane-index="2"] a.dk-close)) |> render_click()
    render_async(view)
    assert page_title(view) =~ "Desk slice notes"
  end

  test "a missing document and an unknown type say so in their own pane", %{
    conn: conn,
    base: base
  } do
    {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};no-such-doc")
    settle(view)
    assert has_element?(view, ~s([data-pane-index="1"] a[data-desk-row]))
    assert has_element?(view, ~s([data-pane-index="2"]), "no-such-doc")

    {:ok, view, _html} = live(admin(conn), "#{base}/no_such_type")
    settle(view)
    assert has_element?(view, ~s([data-pane-index="1"] .dk-note), "no_such_type")
  end

  describe "each pane reads alone" do
    setup do
      test = self()
      id = "desk-slice-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        id,
        [:barkpark, :desk, :pane_load],
        fn _event, _measure, meta, _config -> send(test, {:pane_load, meta.kind}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)
    end

    test "opening another document does not read the list again", %{
      conn: conn,
      base: base,
      a: a,
      b: b
    } do
      {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")
      settle(view)

      # One connected mount: the list once. The last document is the editor's.
      assert_received {:pane_load, :list}
      refute_received {:pane_load, _}

      view
      |> element(~s([data-pane-index="1"] a[data-desk-row][href="#{base}/#{@type_name};#{b}"]))
      |> render_click()

      settle(view)

      refute_received {:pane_load, _}
      assert doc_shows?(view, 2, "About Beta note")
    end

    test "a hovered row is read ahead, and the click opens it with no further read", %{
      conn: conn,
      base: base,
      a: a,
      b: b
    } do
      {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")
      settle(view)
      assert_received {:pane_load, :list}

      # What bp-desk.js sends when the pointer settles on Beta's row.
      beta = "#{base}/#{@type_name};#{b}"
      view |> element("#desk-panes") |> render_hook("warm", %{"href" => beta})
      settle(view)
      assert_received {:pane_load, :doc}

      # Hovering it again reads nothing; nor does a link that is not the desk's.
      view |> element("#desk-panes") |> render_hook("warm", %{"href" => beta})
      view |> element("#desk-panes") |> render_hook("warm", %{"href" => "/elsewhere"})
      settle(view)
      refute_received {:pane_load, _}

      # The click: the pane arrives with its data in the patch itself.
      view
      |> element(~s([data-pane-index="1"] a[data-desk-row][href="#{beta}"]))
      |> render_click()

      assert doc_shows?(view, 2, "About Beta note")
      refute has_element?(view, "[aria-busy]")
      settle(view)
      refute_received {:pane_load, _}

      # The page draws again while that read is still kept (the next hover's
      # read landing does it): the open pane is handed the same read a second
      # time and must take it in its stride. This killed the page in a browser.
      alpha = "#{base}/#{@type_name};#{a}"
      view |> element("#desk-panes") |> render_hook("warm", %{"href" => alpha})
      settle(view)
      assert_received {:pane_load, :doc}
      assert doc_shows?(view, 2, "About Beta note")
    end

    test "a row hovered again after its kept read went stale is read again", %{
      conn: conn,
      base: base,
      a: a,
      b: b
    } do
      {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")
      settle(view)
      assert_received {:pane_load, :list}

      beta = "#{base}/#{@type_name};#{b}"
      view |> element("#desk-panes") |> render_hook("warm", %{"href" => beta})
      settle(view)
      assert_received {:pane_load, :doc}

      # A minute passes: the kept read is older than a pane may show.
      :sys.replace_state(view.pid, fn state ->
        warm =
          Map.new(state.socket.assigns.warm, fn {key, {data, at}} ->
            {key, {data, at - 60_000}}
          end)

        put_in(state.socket.assigns.warm, warm)
      end)

      # bp-desk.js has forgotten the row by now and asks again.
      view |> element("#desk-panes") |> render_hook("warm", %{"href" => beta})
      settle(view)
      assert_received {:pane_load, :doc}
    end

    test "a pane draws its frame before its read lands", %{
      conn: conn,
      base: base,
      a: a,
      b: b
    } do
      test = self()

      # Hold every read until the test lets it go.
      swap_reader(fn pane, node, dataset, scope, title ->
        send(test, {:reading, self()})

        receive do
          :go -> PaneComponent.read(pane, node, dataset, scope, title)
        end
      end)

      # Alpha is a read-only pane here: Beta, the last document, is the editor's.
      {:ok, view, _html} = live(admin(conn), "#{base}/#{two_docs(a, b)}")

      # The frames are there, busy, titled from the URL alone.
      assert has_element?(view, ~s([data-pane-index="1"][aria-busy="true"]))
      assert has_element?(view, ~s([data-pane-index="2"][aria-busy="true"] .pane-header-title), a)

      for _ <- 1..2 do
        assert_receive {:reading, task}
        send(task, :go)
      end

      settle(view)
      refute has_element?(view, "[aria-busy]")
      assert has_element?(view, ~s([data-pane-index="2"] .pane-header-title), "Alpha note")
    end

    test "a document split in three is read once for its two read-only panes", %{
      conn: conn,
      base: base,
      a: a
    } do
      # Panes 2 and 3 show the document read-only; pane 4, the last, is the editor.
      {:ok, view, _html} =
        live(admin(conn), "#{base}/#{@type_name};#{a}|,view=json|,view=json")

      settle(view)

      assert_received {:pane_load, :list}
      assert_received {:pane_load, :doc}
      refute_received {:pane_load, _}

      assert has_element?(view, ~s([data-pane-index="2"] dd), "About Alpha note")
      assert has_element?(view, ~s([data-pane-index="3"] dd), "About Alpha note")
      refute has_element?(view, ~s([data-pane-index="2"][aria-busy]))
      refute has_element?(view, ~s([data-pane-index="3"][aria-busy]))
    end

    test "a read-ahead that fails is forgotten: the next hover reads, the click still opens", %{
      conn: conn,
      base: base,
      a: a,
      b: b
    } do
      swap_reader(fn
        %{kind: :doc, id: ^b}, _node, _dataset, _scope, _title -> raise "the read-ahead failed"
        pane, node, dataset, scope, title -> PaneComponent.read(pane, node, dataset, scope, title)
      end)

      {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")
      settle(view)
      # The open document is the editor's to read, so only the list read.
      assert_received {:pane_load, :list}
      refute_received {:pane_load, _}

      beta = "#{base}/#{@type_name};#{b}"
      view |> element("#desk-panes") |> render_hook("warm", %{"href" => beta})
      settle(view)
      assert_received {:pane_load, :doc}

      # The failed read left no key behind: hovering again reads again.
      view |> element("#desk-panes") |> render_hook("warm", %{"href" => beta})
      settle(view)
      assert_received {:pane_load, :doc}

      # The click is not broken by it: the document opens (the last pane is
      # the Studio's editor, which reads for itself), with no pane read.
      view
      |> element(~s([data-pane-index="1"] a[data-desk-row][href="#{beta}"]))
      |> render_click()

      settle(view)
      refute_received {:pane_load, _}
      assert doc_shows?(view, 2, "About Beta note")
    end
  end

  test "a read that fails is that pane's to show; the others stay up", %{
    conn: conn,
    base: base,
    a: a,
    b: b
  } do
    swap_reader(fn
      %{kind: :doc}, _node, _dataset, _scope, _title -> raise "the document read failed"
      pane, node, dataset, scope, title -> PaneComponent.read(pane, node, dataset, scope, title)
    end)

    {:ok, view, _html} = live(admin(conn), "#{base}/#{two_docs(a, b)}")
    settle(view)

    assert has_element?(view, ~s([data-pane-index="2"] [role="alert"] button[phx-click="retry"]))
    assert has_element?(view, ~s([data-pane-index="1"] a[data-desk-row]), "Alpha note")

    # Retry reads again; with the fault gone the document shows.
    Application.delete_env(:barkpark, PaneComponent)
    view |> element(~s([data-pane-index="2"] button[phx-click="retry"])) |> render_click()
    settle(view)
    assert doc_shows?(view, 2, "About Alpha note")
  end

  # Two documents in a chain: the first is a read-only pane, the second the editor.
  defp two_docs(first, second),
    do: "#{@type_name};#{first};#{second},type=#{@type_name},parentRefPath=more"

  defp swap_reader(reader) do
    Application.put_env(:barkpark, PaneComponent, reader: reader)
    on_exit(fn -> Application.delete_env(:barkpark, PaneComponent) end)
  end

  test "someone else's save shows in the open document and its list row, with no click", %{
    conn: conn,
    base: base,
    a: a
  } do
    {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")
    settle(view)

    {:ok, _doc} =
      Content.upsert_document(
        @type_name,
        %{"doc_id" => a, "title" => "Alpha renamed", "content" => %{"summary" => "Now changed"}},
        @dataset
      )

    # Wait until the page has heard of the save (the broadcast is not always
    # in its mailbox when the write returns), then fire the refresh it would
    # have run a moment later.
    heard? = fn -> MapSet.size(:sys.get_state(view.pid).socket.assigns.stale) > 0 end

    assert Enum.any?(1..200, fn _ -> heard?.() or (Process.sleep(10) && false) end),
           "the page never heard of the save"

    send(view.pid, :desk_refresh)

    # The refresh is a message, and so is the pane's own re-read behind it:
    # `settle/1` right here can find nothing running yet and return at once
    # (it did on CI). Wait for the new value itself.
    shown? = fn ->
      settle(view)
      doc_shows?(view, 2, "Now changed")
    end

    assert Enum.any?(1..200, fn _ -> shown?.() or (Process.sleep(10) && false) end),
           "the open document never showed the saved value"

    assert doc_shows?(view, 2, "Now changed")
    assert doc_shows?(view, 2, "Alpha renamed")
    assert has_element?(view, ~s([data-pane-index="1"] a[data-desk-row]), "Alpha renamed")
    # The row it replaced stays put: Beta is still there, read with the same list.
    assert has_element?(view, ~s([data-pane-index="1"] a[data-desk-row]), "Beta note")
  end

  describe "the active document is edited by the Studio's own editor" do
    test "typing in the active document saves a draft", %{conn: conn, base: base, a: a} do
      {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")
      settle(view)

      assert has_element?(view, ~s([data-pane-index="2"][data-pane-editing] #editor-form))

      # The panes are in the page in chain order, the editor last (a browser
      # drew it first, and the layout collapsed the wrong panes).
      order = Regex.scan(~r/data-pane-index="(\d)"/, render(view)) |> Enum.map(&List.last/1)
      assert order == ~w(0 1 2)

      # The list beside it is still the desk's own pane.
      assert has_element?(view, ~s([data-pane-index="1"] a[data-desk-row][aria-current="true"]))

      view
      |> form("#editor-form")
      |> render_change(%{"doc" => %{"title" => "Alpha typed", "summary" => "Typed here"}})

      {doc, draft?, _published?} = Content.fetch_doc_with_draft(@type_name, a, @dataset)
      assert draft?
      assert doc.title == "Alpha typed"
      assert doc.content["summary"] == "Typed here"
    end

    test "publish goes through the Studio's own action", %{conn: conn, base: base, a: a} do
      {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")
      settle(view)

      view |> form("#editor-form") |> render_change(%{"doc" => %{"title" => "Alpha to publish"}})
      render_hook(view, "publish", %{})

      {doc, draft?, published?} = Content.fetch_doc_with_draft(@type_name, a, @dataset)
      assert published?
      refute draft?
      assert doc.title == "Alpha to publish"
    end

    test "a remote save during unsaved typing raises the conflict banner, and keeps the typing",
         %{
           conn: conn,
           base: base,
           a: a
         } do
      {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")
      settle(view)

      view |> form("#editor-form") |> render_change(%{"doc" => %{"title" => "Mine, unsaved"}})

      {:ok, _doc} =
        Content.upsert_document(
          @type_name,
          %{"doc_id" => a, "title" => "Theirs", "content" => %{"summary" => "Theirs"}},
          @dataset
        )

      conflicted? = fn -> :sys.get_state(view.pid).socket.assigns.doc_conflict == true end

      assert Enum.any?(1..200, fn _ -> conflicted?.() or (Process.sleep(10) && false) end),
             "the editor never raised the conflict"

      html = render(view)
      assert html =~ "Updated by another user"
      # The buffer is not overwritten by the remote value.
      assert has_element?(view, ~s(#editor-form [value="Mine, unsaved"]))
      refute has_element?(view, ~s(#editor-form [value="Theirs"]))
    end

    test "another document in the chain stays a read-only pane", %{conn: conn, base: base} do
      {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name}")
      settle(view)
      refute has_element?(view, "[data-pane-editing]")
      refute has_element?(view, "#editor-form")
    end
  end

  test "search finds a document and its hit opens it as panes", %{conn: conn, base: base, b: b} do
    {:ok, view, _html} = live(admin(conn), base)
    settle(view)
    refute has_element?(view, "a[data-desk-hit]")

    view |> form("#desk-search-form") |> render_change(%{"value" => "Beta no"})

    hit = ~s(#desk-search-hits a[data-desk-hit][href$=";#{b}"])
    assert has_element?(view, hit, "Beta note")

    href =
      view |> element(hit) |> render() |> then(&Regex.run(~r/href="([^"]+)"/, &1)) |> List.last()

    view |> element(hit) |> render_click()
    assert_patch(view, href)
    settle(view)

    # The document is open, its list beside it, and the search is put away.
    assert has_element?(
             view,
             ~s([data-pane-kind="list"] a[data-desk-row][aria-current="true"]),
             "Beta note"
           )

    assert has_element?(view, ~s([data-pane-editing] #editor-form))
    refute has_element?(view, "#desk-search-hits")

    # Nothing found says so.
    view |> form("#desk-search-form") |> render_change(%{"value" => "zzz-no-such-thing"})
    assert has_element?(view, ~s(#desk-search-hits [role="status"]), "zzz-no-such-thing")
  end

  describe "a list draws the Studio's own rows" do
    @big "desk_slice_big"

    setup do
      {:ok, _schema} =
        Content.upsert_schema(
          %{
            "name" => @big,
            "title" => "Desk slice big",
            "visibility" => "public",
            "list_preview" => %{"subtitle" => "kicker"},
            "desk" => %{
              "orderings" => [%{"field" => "title", "direction" => "asc"}],
              "sortOrderings" => [
                %{
                  "name" => "titleDesc",
                  "title" => "Title, Z first",
                  "by" => [%{"field" => "title", "direction" => "desc"}]
                }
              ]
            },
            "fields" => [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{"name" => "kicker", "title" => "Kicker", "type" => "string"}
            ]
          },
          @dataset
        )

      n = System.unique_integer([:positive])

      for i <- 1..130 do
        num = String.pad_leading(to_string(i), 3, "0")

        {:ok, _doc} =
          Content.create_document(
            @big,
            %{
              "doc_id" => "dsb-#{n}-#{num}",
              "title" => "Big #{num}",
              "content" => %{"kicker" => "Kicker #{num}"}
            },
            @dataset
          )
      end

      :ok
    end

    defp row_titles(view) do
      view
      |> render()
      |> then(&Regex.scan(~r/Big (\d{3})/, &1))
      |> Enum.map(fn [_, num] -> num end)
      |> Enum.uniq()
    end

    test "subtitle, draft mark, declared order, and more than one page", %{conn: conn, base: base} do
      {:ok, view, _html} = live(admin(conn), "#{base}/#{@big}")
      settle(view)

      list = ~s([data-pane-kind="list"])
      # The schema's list preview subtitle, and the draft mark of an unpublished row.
      assert has_element?(view, list <> " a[data-desk-row] .dk-row-sub", "Kicker 001")
      assert has_element?(view, list <> " a[data-desk-row] .dk-draft")

      # The declared order (title ascending), one page of 100.
      titles = row_titles(view)
      assert length(titles) == 100
      assert titles == Enum.sort(titles)
      assert hd(titles) == "001"

      # More than one page: scrolling to the last row reads the rest below it.
      view
      |> element(list <> " [role=list][phx-viewport-bottom=more]")
      |> render_hook("more", %{})

      settle(view)
      assert length(row_titles(view)) == 130
      assert has_element?(view, list <> " a[data-desk-row]", "Big 130")
    end

    test "the sort menu changes the order for this list", %{conn: conn, base: base} do
      {:ok, view, _html} = live(admin(conn), "#{base}/#{@big}")
      settle(view)

      view
      |> element(~s([data-pane-kind="list"] form.dk-sort))
      |> render_change(%{"sort" => "titleDesc"})

      settle(view)
      assert hd(row_titles(view)) == "130"
    end
  end

  describe "references open the next pane" do
    @ref_type "desk_slice_linked"

    setup %{a: a, b: b} do
      {:ok, _schema} =
        Content.upsert_schema(
          %{
            "name" => @ref_type,
            "title" => "Desk slice linked",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{"name" => "note", "title" => "Note", "type" => "reference", "to" => [@type_name]},
              %{
                "name" => "more",
                "title" => "More",
                "type" => "arrayOf",
                "of" => [%{"type" => "reference", "to" => [%{"type" => @type_name}]}]
              }
            ]
          },
          @dataset
        )

      id = "dsl-#{System.unique_integer([:positive])}"

      {:ok, _doc} =
        Content.create_document(
          @ref_type,
          %{
            "doc_id" => id,
            "title" => "Linked one",
            "content" => %{
              "note" => %{"_ref" => a, "_type" => "reference"},
              "more" => [%{"_ref" => b, "_type" => "reference"}, a, "dsn-gone"]
            }
          },
          @dataset
        )

      {:ok, linked: id}
    end

    test "a reference is a link that opens its target beside the document", %{
      conn: conn,
      base: base,
      linked: linked,
      a: a,
      b: b
    } do
      {:ok, view, _html} = live(admin(conn), "#{base}/#{@ref_type};#{linked}")
      settle(view)

      to_a = "#{base}/#{@ref_type};#{linked};#{a},type=#{@type_name},parentRefPath=note"

      assert has_element?(
               view,
               ~s([data-pane-index="2"] a[data-desk-ref][href="#{to_a}"]),
               "Alpha note"
             )

      # An array of references: one link each, in stored order; a bare id reads too.
      to_b = "#{base}/#{@ref_type};#{linked};#{b},type=#{@type_name},parentRefPath=more"

      assert has_element?(
               view,
               ~s([data-pane-index="2"] a[data-desk-ref][href="#{to_b}"]),
               "Beta note"
             )

      view |> element(~s(a[data-desk-ref][href="#{to_a}"])) |> render_click()
      assert_patch(view, to_a)
      settle(view)

      assert doc_shows?(view, 3, "About Alpha note")

      assert has_element?(
               view,
               ~s([data-pane-index="2"] a[data-desk-ref][aria-current="true"]),
               "Alpha note"
             )

      # A target that is gone keeps its id and is not a link.
      assert has_element?(view, ~s([data-pane-index="2"] .dk-ref-missing), "dsn-gone")
      # The document it was opened from stays, now a read-only pane.
      assert has_element?(view, ~s([data-pane-index="2"] .pane-header-title), "Linked one")
    end

    test "a followed document with no type= has its type looked up", %{
      conn: conn,
      base: base,
      linked: linked,
      a: a
    } do
      {:ok, view, _html} = live(admin(conn), "#{base}/#{@ref_type};#{linked};#{a}")
      settle(view)
      assert doc_shows?(view, 3, "About Alpha note")
    end

    test "a chain eight panes deep comes back from its URL", %{
      conn: conn,
      base: base,
      linked: linked,
      a: a,
      b: b
    } do
      hop = fn id, path -> "#{id},type=#{@type_name},parentRefPath=#{path}" end
      back = "#{linked},type=#{@ref_type},parentRefPath=x"

      chain =
        [linked, hop.(a, "note"), back, hop.(b, "more"), back, hop.(a, "note")]
        |> Enum.join(";")

      {:ok, view, _html} = live(admin(conn), "#{base}/#{@ref_type};#{chain}")
      settle(view)

      # Root + list + six documents.
      for i <- 0..7, do: assert(has_element?(view, ~s([data-pane-index="#{i}"])))
      refute has_element?(view, ~s([data-pane-index="8"]))
      assert doc_shows?(view, 7, "About Alpha note")
      assert has_element?(view, ~s([data-pane-index="6"] .pane-header-title), "Linked one")

      # Closing the fourth pane prints the chain up to it, params intact.
      view |> element(~s([data-pane-index="4"] a.dk-close)) |> render_click()
      assert_patch(view, "#{base}/#{@ref_type};#{linked};#{hop.(a, "note")}")
    end
  end

  describe "a tree list drills pane by pane, as the Studio's own desk" do
    @cat "desk_slice_cat"

    # A declared desk: «Kategorier» holds a parent-child tree of categories
    # and a groupBy of the same categories by parent (built deferred).
    setup do
      for {name, fields} <- [
            {@cat,
             [
               %{"name" => "title", "title" => "Title", "type" => "string"},
               %{"name" => "parent", "title" => "Parent", "type" => "reference", "to" => [@cat]}
             ]},
            {"deskStructure", [%{"name" => "items", "title" => "Items", "type" => "array"}]}
          ] do
        {:ok, _} =
          Content.upsert_schema(
            %{"name" => name, "title" => name, "visibility" => "public", "fields" => fields},
            @dataset
          )
      end

      n = System.unique_integer([:positive])
      id = fn key -> "dsc-#{key}-#{n}" end

      for {key, title, parent} <- [
            {"a", "Alpha", nil},
            {"b", "Bravo", nil},
            {"a1", "Alpha one", "a"},
            {"a2", "Alpha two", "a"},
            {"a1x", "Alpha one x", "a1"}
          ] do
        content = if parent, do: %{"parent" => id.(parent)}, else: %{}

        {:ok, _} =
          Content.create_document(
            @cat,
            %{"doc_id" => id.(key), "title" => title, "content" => content},
            @dataset
          )

        {:ok, _} = Content.publish_document(id.(key), @cat, @dataset)
      end

      items = [
        %{
          "kind" => "list",
          "id" => "kategorier",
          "title" => "Kategorier",
          "items" => [
            %{
              "kind" => "tree",
              "id" => "hierarki",
              "title" => "Hierarki",
              "type" => @cat,
              "parent" => "content.parent",
              "orderings" => [%{"field" => "title", "direction" => "asc"}]
            },
            %{
              "kind" => "groupBy",
              "id" => "etter-forelder",
              "title" => "Etter forelder",
              "type" => @cat,
              "over" => @cat,
              "by" => "content.parent"
            }
          ]
        }
      ]

      {:ok, _} =
        Content.create_document(
          "deskStructure",
          %{"doc_id" => "deskStructure", "title" => "Desk", "content" => %{"items" => items}},
          @dataset
        )

      {:ok, _} = Content.publish_document("deskStructure", "deskStructure", @dataset)
      {:ok, cat: id}
    end

    defp rows(view, index) do
      view
      |> element(~s([data-pane-index="#{index}"] .pane-body))
      |> render()
      |> then(
        &Regex.scan(
          ~r/<a[^>]*data-desk-row[^>]*>\s*<span class="pane-item-label">\s*([^<]+?)\s*</,
          &1
        )
      )
      |> Enum.map(fn [_, title] -> title end)
    end

    # A pane's read is async, and CI is slower than a laptop: poll for the rows.
    defp await_rows(view, index, want, tries \\ 50) do
      settle(view)
      got = rows(view, index)

      cond do
        got == want ->
          got

        tries == 0 ->
          got

        true ->
          Process.sleep(100)
          await_rows(view, index, want, tries - 1)
      end
    end

    test "a row opens its children as the next pane, its parent on top", %{
      conn: conn,
      base: base,
      cat: cat
    } do
      tree = "#{base}/kategorier;hierarki"
      {:ok, view, _html} = live(admin(conn), tree)

      # The root level: the parentless categories.
      assert await_rows(view, 2, ["Alpha", "Bravo"]) == ["Alpha", "Bravo"]

      # A row opens a tree level, not the document.
      alpha = ~s([data-pane-index="2"] a[data-desk-row][href="#{tree};#{cat.("a")}"])
      assert has_element?(view, alpha <> ~s([data-desk-opens="list"]))
      view |> element(alpha) |> render_click()
      assert_patch(view, "#{tree};#{cat.("a")}")

      # The level: the parent on top, a divider, then its children.
      want = ["Alpha", "Alpha one", "Alpha two"]
      assert await_rows(view, 3, want) == want
      assert has_element?(view, ~s([data-pane-index="3"][data-pane-kind="list"] .pane-divider))
      refute has_element?(view, ~s([data-pane-index="3"] #editor-form))
      assert has_element?(view, ~s([data-pane-index="2"] a[aria-current="true"]), "Alpha")
      refute has_element?(view, ~s([data-pane-index="2"] a[aria-current="true"]), "Bravo")

      # The URL it printed opens the same panes from a reload.
      {:ok, again, _html} = live(admin(conn), "#{tree};#{cat.("a")}")
      assert await_rows(again, 3, want) == want
    end

    test "the parent on top opens the document in the editor", %{
      conn: conn,
      base: base,
      cat: cat
    } do
      level = "#{base}/kategorier;hierarki;#{cat.("a")}"
      {:ok, view, _html} = live(admin(conn), level)
      assert await_rows(view, 3, ["Alpha", "Alpha one", "Alpha two"]) |> hd() == "Alpha"

      top = ~s([data-pane-index="3"] a[data-desk-row][href="#{level};#{cat.("a")}"])
      assert has_element?(view, top <> ~s([data-desk-opens="doc"]))
      view |> element(top) |> render_click()
      assert_patch(view, "#{level};#{cat.("a")}")
      settle(view)

      assert has_element?(view, ~s([data-pane-index="4"][data-pane-editing] #editor-form))
      assert doc_shows?(view, 4, "Alpha")
      assert has_element?(view, ~s([data-pane-index="3"] a[aria-current="true"]), "Alpha")
    end

    test "a child drills one level deeper, and its own top opens it", %{
      conn: conn,
      base: base,
      cat: cat
    } do
      level = "#{base}/kategorier;hierarki;#{cat.("a")}"
      {:ok, view, _html} = live(admin(conn), level)
      await_rows(view, 3, ["Alpha", "Alpha one", "Alpha two"])

      child = ~s([data-pane-index="3"] a[data-desk-row][href="#{level};#{cat.("a1")}"])
      view |> element(child) |> render_click()
      assert_patch(view, "#{level};#{cat.("a1")}")

      assert await_rows(view, 4, ["Alpha one", "Alpha one x"]) == ["Alpha one", "Alpha one x"]
      assert has_element?(view, ~s([data-pane-index="3"] a[aria-current="true"]), "Alpha one")
      refute has_element?(view, ~s([data-pane-index="3"] a[aria-current="true"]), "Alpha two")

      deep = "#{level};#{cat.("a1")};#{cat.("a1")}"
      {:ok, view, _html} = live(admin(conn), deep)
      settle(view)
      assert has_element?(view, ~s([data-pane-index="5"][data-pane-editing] #editor-form))
      assert doc_shows?(view, 5, "Alpha one")
    end

    test "a search hit for a tree list's type opens the document, not a tree level", %{
      conn: conn,
      base: base,
      cat: cat
    } do
      {:ok, view, _html} = live(admin(conn), base)
      settle(view)

      view |> form("#desk-search-form") |> render_change(%{"value" => "Alpha one x"})

      # Under a tree an id alone opens a level; the id twice opens the doc.
      doc = "#{base}/kategorier;hierarki;#{cat.("a1x")};#{cat.("a1x")}"
      hit = ~s(#desk-search-hits a[data-desk-hit][href$=";#{cat.("a1x")}"])
      assert has_element?(view, hit, "Alpha one x")
      assert has_element?(view, ~s(#desk-search-hits a[data-desk-hit][href="#{doc}"]))

      view |> element(hit) |> render_click()
      assert_patch(view, doc)
      settle(view)

      assert has_element?(view, ~s([data-pane-index="4"][data-pane-editing] #editor-form))
      assert doc_shows?(view, 4, "Alpha one x")
    end

    test "a deferred groupBy's menu shows its groups, and a group lists its docs", %{
      conn: conn,
      base: base,
      cat: cat
    } do
      menu = "#{base}/kategorier;etter-forelder"
      {:ok, view, _html} = live(admin(conn), menu)
      settle(view)

      groups = rows(view, 2)
      assert "Alpha" in groups and "Alpha one" in groups

      # A group's id is `<the groupBy's place in the desk>-<the over doc's id>`:
      # the second item of the first desk item (`Structure`).
      group = ~s([data-pane-index="2"] a[data-desk-row][href="#{menu};desk-0-1-#{cat.("a1")}"])
      assert has_element?(view, group <> ~s([data-desk-opens="list"]), "Alpha one")
      view |> element(group) |> render_click()
      assert await_rows(view, 3, ["Alpha one x"]) == ["Alpha one x"]

      assert has_element?(
               view,
               ~s([data-pane-index="3"] a[data-desk-row][href$=";#{cat.("a1x")}"])
             )
    end
  end

  test "someone who is not a workspace admin lands on the Studio", %{conn: conn, base: base} do
    studio = String.replace_suffix(base, "/_desk", "")

    assert {:error, {:live_redirect, %{to: ^studio}}} = live(sign_in(conn, ["read"]), base)
  end
end
