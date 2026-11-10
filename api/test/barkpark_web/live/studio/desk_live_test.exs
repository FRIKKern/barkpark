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

  defp admin(conn), do: sign_in(conn, ["read", "write", "admin"])

  test "the root URL draws the desk root alone, its rows links", %{conn: conn, base: base} do
    {:ok, view, _html} = live(admin(conn), base)
    render_async(view)

    assert has_element?(
             view,
             ~s([data-testid="panes"] [data-pane-index="0"][data-pane-kind="types"])
           )

    refute has_element?(view, ~s([data-pane-index="1"]))
    assert has_element?(view, ~s([data-pane-index="0"] a[data-desk-row][href^="#{base}/"]))
    refute has_element?(view, "#desk-panes a[phx-click]")
  end

  test "a deep link draws root, list and document", %{conn: conn, base: base, a: a} do
    {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")
    render_async(view)

    assert has_element?(view, ~s([data-pane-index="0"][data-pane-kind="types"]))
    assert has_element?(view, ~s([data-pane-index="1"][data-pane-kind="list"]))
    assert has_element?(view, ~s([data-pane-index="2"][data-pane-kind="doc"]))
    refute has_element?(view, ~s([data-pane-index="3"]))

    # The open row is the current one; its sibling is not.
    assert has_element?(view, ~s([data-pane-index="1"] a[aria-current="true"]), "Alpha note")
    refute has_element?(view, ~s([data-pane-index="1"] a[aria-current="true"]), "Beta note")

    # The document is printed, not edited.
    assert has_element?(view, ~s([data-pane-index="2"] dd), "About Alpha note")
    refute has_element?(view, "#desk-panes :is(input, textarea, form)")
  end

  test "a row's href is the pane URL, and following it patches there", %{
    conn: conn,
    base: base,
    a: a,
    b: b
  } do
    {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")
    render_async(view)

    beta = ~s([data-pane-index="1"] a[data-desk-row][href="#{base}/#{@type_name};#{b}"])
    assert has_element?(view, beta, "Beta note")

    view |> element(beta) |> render_click()
    render_async(view)
    assert_patch(view, "#{base}/#{@type_name};#{b}")

    assert has_element?(view, ~s([data-pane-index="1"] a[aria-current="true"]), "Beta note")
    assert has_element?(view, ~s([data-pane-index="2"] dd), "About Beta note")
  end

  test "closing a pane goes to the URL without it", %{conn: conn, base: base, a: a} do
    {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")
    render_async(view)

    view |> element(~s([data-pane-index="2"] a.dk-close)) |> render_click()
    render_async(view)
    assert_patch(view, "#{base}/#{@type_name}")
    refute has_element?(view, ~s([data-pane-index="2"]))
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
    render_async(view)
    assert has_element?(view, ~s([data-pane-index="1"] a[data-desk-row]))
    assert has_element?(view, ~s([data-pane-index="2"] .dk-note), "no-such-doc")

    {:ok, view, _html} = live(admin(conn), "#{base}/no_such_type")
    render_async(view)
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
      render_async(view)

      # One connected mount: the list once, the document once.
      assert_received {:pane_load, :list}
      assert_received {:pane_load, :doc}
      refute_received {:pane_load, _}

      view
      |> element(~s([data-pane-index="1"] a[data-desk-row][href="#{base}/#{@type_name};#{b}"]))
      |> render_click()

      render_async(view)

      assert_received {:pane_load, :doc}
      refute_received {:pane_load, _}
      assert has_element?(view, ~s([data-pane-index="2"] dd), "About Beta note")
    end

    test "a hovered row is read ahead, and the click opens it with no further read", %{
      conn: conn,
      base: base,
      a: a,
      b: b
    } do
      {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")
      render_async(view)
      assert_received {:pane_load, :list}
      assert_received {:pane_load, :doc}

      # What bp-desk.js sends when the pointer settles on Beta's row.
      beta = "#{base}/#{@type_name};#{b}"
      view |> element("#desk-panes") |> render_hook("warm", %{"href" => beta})
      render_async(view)
      assert_received {:pane_load, :doc}

      # Hovering it again reads nothing; nor does a link that is not the desk's.
      view |> element("#desk-panes") |> render_hook("warm", %{"href" => beta})
      view |> element("#desk-panes") |> render_hook("warm", %{"href" => "/elsewhere"})
      render_async(view)
      refute_received {:pane_load, _}

      # The click: the pane arrives with its data in the patch itself.
      view
      |> element(~s([data-pane-index="1"] a[data-desk-row][href="#{beta}"]))
      |> render_click()

      assert has_element?(view, ~s([data-pane-index="2"] dd), "About Beta note")
      refute has_element?(view, "[aria-busy]")
      render_async(view)
      refute_received {:pane_load, _}

      # The page draws again while that read is still kept (the next hover's
      # read landing does it): the open pane is handed the same read a second
      # time and must take it in its stride. This killed the page in a browser.
      alpha = "#{base}/#{@type_name};#{a}"
      view |> element("#desk-panes") |> render_hook("warm", %{"href" => alpha})
      render_async(view)
      assert_received {:pane_load, :doc}
      assert has_element?(view, ~s([data-pane-index="2"] dd), "About Beta note")
    end

    test "a pane draws its frame before its read lands", %{conn: conn, base: base, a: a} do
      test = self()

      # Hold every read until the test lets it go.
      swap_reader(fn pane, node, dataset, scope, title ->
        send(test, {:reading, self()})

        receive do
          :go -> PaneComponent.read(pane, node, dataset, scope, title)
        end
      end)

      {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")

      # The frames are there, busy, titled from the URL alone.
      assert has_element?(view, ~s([data-pane-index="1"][aria-busy="true"]))
      assert has_element?(view, ~s([data-pane-index="2"][aria-busy="true"] .pane-header-title), a)

      for _ <- 1..2 do
        assert_receive {:reading, task}
        send(task, :go)
      end

      render_async(view)
      refute has_element?(view, "[aria-busy]")
      assert has_element?(view, ~s([data-pane-index="2"] .pane-header-title), "Alpha note")
      assert page_title(view) =~ "Alpha note"
    end
  end

  test "a read that fails is that pane's to show; the others stay up", %{
    conn: conn,
    base: base,
    a: a
  } do
    swap_reader(fn
      %{kind: :doc}, _node, _dataset, _scope, _title -> raise "the document read failed"
      pane, node, dataset, scope, title -> PaneComponent.read(pane, node, dataset, scope, title)
    end)

    {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")
    render_async(view)

    assert has_element?(view, ~s([data-pane-index="2"] [role="alert"] button[phx-click="retry"]))
    assert has_element?(view, ~s([data-pane-index="1"] a[data-desk-row]), "Alpha note")

    # Retry reads again; with the fault gone the document shows.
    Application.delete_env(:barkpark, PaneComponent)
    view |> element(~s([data-pane-index="2"] button[phx-click="retry"])) |> render_click()
    render_async(view)
    assert has_element?(view, ~s([data-pane-index="2"] dd), "About Alpha note")
  end

  defp swap_reader(reader) do
    Application.put_env(:barkpark, PaneComponent, reader: reader)
    on_exit(fn -> Application.delete_env(:barkpark, PaneComponent) end)
  end

  test "someone who is not a workspace admin lands on the Studio", %{conn: conn, base: base} do
    studio = String.replace_suffix(base, "/_desk", "")

    assert {:error, {:live_redirect, %{to: ^studio}}} = live(sign_in(conn, ["read"]), base)
  end
end
