defmodule BarkparkWeb.Studio.DeskPaneHeldTest do
  @moduledoc """
  The last document of a chain is drawn on hold: its pane is a frame, and the
  Studio's editor fills it in the next message. A second click can land
  before that message, and the held pane is then a read-only pane with split
  siblings behind it. It must read, and they must fill with it: no pane may
  stay busy for good.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "desk_held_note"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Held notes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "summary", "title" => "Summary", "type" => "string"}
          ]
        },
        @dataset
      )

    a = "dhn-a-#{System.unique_integer([:positive])}"

    {:ok, _doc} =
      Content.create_document(
        @type_name,
        %{"doc_id" => a, "title" => "Alpha note", "content" => %{"summary" => "About Alpha"}},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-held-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-held", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok, conn: conn, base: base, a: a}
  end

  test "a pane held for the editor that stops being last reads, and its split siblings with it",
       %{conn: conn, base: base, a: a} do
    {:ok, view, _html} = live(conn, "#{base}/#{@type_name}")
    render_async(view, 5_000)

    # Two clicks reach the page before it handles either: the document opens
    # (its pane is held for the editor), then it is split in three, so that
    # pane is the first of the split and the editor's pane is another.
    # The clicks in the page's queue, by name: a stray message is not one.
    patches = fn ->
      {:messages, queue} = Process.info(view.pid, :messages)
      Enum.count(queue, &match?(%Phoenix.Socket.Message{event: "live_patch"}, &1))
    end

    :ok = :sys.suspend(view.pid)

    clicks =
      for splat <- ["#{@type_name};#{a}", "#{@type_name};#{a}|,view=json|,view=json"] do
        before = patches.()
        click = Task.async(fn -> render_patch(view, "#{base}/#{splat}") end)
        wait(fn -> patches.() == before + 1 end)
        click
      end

    assert patches.() == 2, "both clicks wait in the page's queue, neither handled yet"
    :ok = :sys.resume(view.pid)
    Task.await_many(clicks)
    render_async(view, 5_000)

    refute has_element?(view, "[aria-busy]")
    assert has_element?(view, ~s([data-pane-index="2"] dd), "About Alpha")
    assert has_element?(view, ~s([data-pane-index="3"] dd), "About Alpha")
  end

  defp wait(check, tries \\ 100) do
    cond do
      check.() -> :ok
      tries == 0 -> flunk("the click never reached the page's queue")
      true -> Process.sleep(20) && wait(check, tries - 1)
    end
  end
end
