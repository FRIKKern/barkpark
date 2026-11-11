defmodule BarkparkWeb.Studio.DeskWarmSlowReadTest do
  @moduledoc """
  A hovered row's read is kept for 30 s, and `bp-desk.js` forgets the row 30 s
  after the hover. Both clocks start at the hover, so a hover the browser
  sends again is never refused because the first read was slow.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.PaneComponent

  @dataset "production"
  @type_name "desk_warm_slow_note"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Slow notes",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    n = System.unique_integer([:positive])

    for {id, title} <- [{"dws-a-#{n}", "Alpha note"}, {"dws-b-#{n}", "Beta note"}] do
      {:ok, _doc} =
        Content.create_document(@type_name, %{"doc_id" => id, "title" => title}, @dataset)
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-warm-slow-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-warm-slow", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok, conn: conn, base: base, a: "dws-a-#{n}", b: "dws-b-#{n}"}
  end

  test "a row hovered again 30 s after the first hover is read again, though the first read was slow",
       %{conn: conn, base: base, a: a, b: b} do
    test = self()

    # Beta's read is held until the test lets it go, and says each time it starts.
    Application.put_env(:barkpark, PaneComponent,
      reader: fn
        %{kind: :doc, id: ^b} = pane, node, dataset, scope, title ->
          send(test, {:reading, self()})

          receive do
            :go -> PaneComponent.read(pane, node, dataset, scope, title)
          end

        pane, node, dataset, scope, title ->
          PaneComponent.read(pane, node, dataset, scope, title)
      end
    )

    on_exit(fn -> Application.delete_env(:barkpark, PaneComponent) end)

    {:ok, view, _html} = live(conn, "#{base}/#{@type_name};#{a}")
    render_async(view, 5_000)

    beta = "#{base}/#{@type_name};#{b}"
    view |> element("#desk-panes") |> render_hook("warm", %{"href" => beta})
    assert_receive {:reading, task}, 5_000

    # The read is still out 31 s after the hover; then it lands.
    :sys.replace_state(view.pid, fn state ->
      warm =
        Map.new(state.socket.assigns.warm, fn
          {key, {:reading, at}} -> {key, {:reading, at - 31_000}}
          entry -> entry
        end)

      put_in(state.socket.assigns.warm, warm)
    end)

    send(task, :go)
    render_async(view, 5_000)

    # bp-desk.js forgot the row 30 s after the hover, so it asks again.
    view |> element("#desk-panes") |> render_hook("warm", %{"href" => beta})
    assert_receive {:reading, task}, 1_000

    # Hovered once more while that read is out: no second read, and the read
    # is kept from this hover on, so the hover after it lands reads nothing.
    view |> element("#desk-panes") |> render_hook("warm", %{"href" => beta})
    send(task, :go)
    render_async(view, 5_000)
    view |> element("#desk-panes") |> render_hook("warm", %{"href" => beta})
    refute_receive {:reading, _task}, 200
  end
end
