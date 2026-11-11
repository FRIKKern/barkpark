defmodule BarkparkWeb.Studio.DeskPaneLateTitleTest do
  @moduledoc """
  A pane's title reaches the page as a message. One that lands after its pane
  was replaced must not be kept under the pane that took its place.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.PaneComponent

  @dataset "production"
  @type_name "desk_late_title_note"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Late title notes",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    n = System.unique_integer([:positive])

    for {id, title} <- [{"dlt-a-#{n}", "Alpha note"}, {"dlt-b-#{n}", "Beta note"}] do
      {:ok, _doc} =
        Content.create_document(@type_name, %{"doc_id" => id, "title" => title}, @dataset)
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-late-title-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "desk-late-title",
        @dataset,
        ~w(read write admin),
        Tenancy.get_default_workspace().id
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok, conn: conn, base: base, a: "dlt-a-#{n}", b: "dlt-b-#{n}"}
  end

  test "a title that lands after its pane was replaced is not the new pane's", %{
    conn: conn,
    base: base,
    a: a,
    b: b
  } do
    test = self()

    # Hold Alpha's read until the test lets it go.
    Application.put_env(:barkpark, PaneComponent,
      reader: fn
        %{kind: :doc, id: ^a} = pane, node, dataset, scope, title ->
          send(test, {:reading, self()})

          receive do
            :go -> PaneComponent.read(pane, node, dataset, scope, title)
          end

        pane, node, dataset, scope, title ->
          PaneComponent.read(pane, node, dataset, scope, title)
      end
    )

    on_exit(fn -> Application.delete_env(:barkpark, PaneComponent) end)

    # Alpha is a read-only pane at index 2; Beta, the last document, is the editor's.
    chain = "#{@type_name};#{a};#{b},type=#{@type_name},parentRefPath=more"
    {:ok, view, _html} = live(conn, "#{base}/#{chain}")
    assert_receive {:reading, task}, 5_000

    # The page is busy while the click and Alpha's read both arrive: the read
    # lands first, so its title is said after the click put Beta at index 2.
    # The clicks in the page's queue, by name: a stray message is not one.
    patches = fn ->
      {:messages, queue} = Process.info(view.pid, :messages)
      Enum.count(queue, &match?(%Phoenix.Socket.Message{event: "live_patch"}, &1))
    end

    :ok = :sys.suspend(view.pid)
    click = Task.async(fn -> render_patch(view, "#{base}/#{@type_name};#{b}") end)
    wait(fn -> patches.() == 1 end)
    ref = Process.monitor(task)
    send(task, :go)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000
    assert patches.() == 1, "the click waits in the page's queue while the read lands"
    :ok = :sys.resume(view.pid)
    Task.await(click)
    render_async(view, 5_000)

    refute page_title(view) =~ "Alpha note"
  end

  defp wait(check, tries \\ 100) do
    cond do
      check.() -> :ok
      tries == 0 -> flunk("the click never reached the page's queue")
      true -> Process.sleep(20) && wait(check, tries - 1)
    end
  end
end
