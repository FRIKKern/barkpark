defmodule BarkparkWeb.Studio.DeskListPaneReadsTest do
  @moduledoc """
  A desk pane never stays a skeleton: whatever path it took to its loading
  state, a read is running or the page is about to hand it its data.

  The pane is hosted by a bare LiveView here, so a test can change what the
  page passes it (`hold`, `warm`) exactly as `DeskLive` does between two
  patches, and the `reader:` seam holds every read until the test lets it go.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.Desk.PaneComponent
  alias BarkparkWeb.Studio.Desk.Panes

  defmodule Host do
    use Phoenix.LiveView

    @impl true
    def mount(_params, %{"assigns" => assigns}, socket), do: {:ok, assign(socket, assigns)}

    @impl true
    def handle_info({:set, kv}, socket), do: {:noreply, assign(socket, kv)}
    def handle_info({:desk_pane_title, _index, _title}, socket), do: {:noreply, socket}
    def handle_info({:desk_doc_titles, _titles}, socket), do: {:noreply, socket}

    @impl true
    def render(assigns) do
      ~H"""
      <.live_component
        module={PaneComponent}
        id="pane"
        pane={Enum.at(@panes, 2)}
        index={2}
        node={nil}
        hold={@hold}
        warm={@warm}
        panes={@panes}
        base="/desk"
        dataset="production"
        scope={[]}
      />
      """
    end
  end

  setup do
    test = self()

    # Every read says it started and waits for the value the test hands it.
    Application.put_env(:barkpark, PaneComponent,
      reader: fn _pane, _node, _dataset, _scope, _title ->
        send(test, {:reading, self()})

        receive do
          {:go, value} -> %{title: "Alpha", fields: [%{title: "Summary", value: value}]}
        end
      end
    )

    on_exit(fn -> Application.delete_env(:barkpark, PaneComponent) end)
    :ok
  end

  defp host(conn, assigns) do
    panes = Panes.parse("note;doc-a;doc-b,type=note,parentRefPath=more")
    assigns = Map.merge(%{panes: panes, hold: false, warm: nil}, assigns)
    {:ok, view, _html} = live_isolated(conn, Host, session: %{"assigns" => assigns})
    view
  end

  # CI is slower than this machine: wait for the value itself (CAMPAIGN rule 6).
  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  defp shows?(view, text), do: has_element?(view, "#pane dd", text)

  test "a pane drawn on hold for the editor reads when it becomes a parent", %{conn: conn} do
    view = host(conn, %{hold: true})

    # On hold the editor reads: the pane draws its frame and reads nothing.
    assert has_element?(view, ~s(#pane[aria-busy="true"]))
    refute_receive {:reading, _}, 100

    # A reference opened the next pane: this one is a read-only parent now.
    send(view.pid, {:set, hold: false})

    assert_receive {:reading, task}, 2_000
    send(task, {:go, "the parent's summary"})
    assert eventually(fn -> shows?(view, "the parent's summary") end)
    refute has_element?(view, "#pane[aria-busy]")
  end

  test "a refresh during a read waits for it, then reads once more", %{conn: conn} do
    view = host(conn, %{})
    assert_receive {:reading, first}, 2_000

    # Two saves land while the read is out: neither throws it away.
    Phoenix.LiveView.send_update(view.pid, PaneComponent, id: "pane", refresh: true)
    Phoenix.LiveView.send_update(view.pid, PaneComponent, id: "pane", refresh: true)
    refute_receive {:reading, _}, 200

    send(first, {:go, "before the saves"})
    assert eventually(fn -> shows?(view, "before the saves") end)

    # One more read for both saves, and its value is the one shown.
    assert_receive {:reading, again}, 2_000
    send(again, {:go, "after the saves"})
    assert eventually(fn -> shows?(view, "after the saves") end)
    refute_receive {:reading, _}, 200
    refute has_element?(view, "#pane[aria-busy]")
  end

  test "a read cancelled for a hover's data is not a failed pane", %{conn: conn} do
    view = host(conn, %{})
    assert_receive {:reading, task}, 2_000
    ref = Process.monitor(task)

    # A hover read the same pane first: the pane takes it and cancels its own.
    warm = %{title: "Alpha", fields: [%{title: "Summary", value: "read ahead"}]}
    send(view.pid, {:set, warm: warm})

    assert_receive {:DOWN, ^ref, :process, ^task, {:shutdown, :cancel}}, 2_000
    assert eventually(fn -> shows?(view, "read ahead") end)

    # The cancelled read's exit has reached the pane by now; it shows no error.
    for _ <- 1..5 do
      Process.sleep(20)
      refute has_element?(view, ~s(#pane [role="alert"]))
    end

    assert shows?(view, "read ahead")
  end

  # task-f8383ce8dd2ef270 criterion 8: while a pane reads for a new key its
  # last result stays on screen. The note about what the desk leaves out is
  # from the URL, so it sat over the document before.
  test "no revision note over the document before while the next is read", %{conn: conn} do
    view = host(conn, %{})
    assert_receive {:reading, task}, 1_000
    send(task, {:go, "about the first"})
    assert eventually(fn -> shows?(view, "about the first") end)
    refute has_element?(view, "#pane [data-desk-left-out]")

    tail = ";doc-b,type=note,parentRefPath=more"
    send(view.pid, {:set, panes: Panes.parse("note;doc-z,rev=abc123" <> tail)})
    assert_receive {:reading, task}, 1_000

    # The first document's fields are still there; the note is not theirs.
    assert shows?(view, "about the first")
    refute has_element?(view, "#pane [data-desk-left-out]")

    send(task, {:go, "about the second"})
    assert eventually(fn -> shows?(view, "about the second") end)
    assert has_element?(view, "#pane [data-desk-left-out]", "abc123")

    # The same document asked for with another `rev=` is not read again: the
    # note is its own at once.
    send(view.pid, {:set, panes: Panes.parse("note;doc-z,rev=def456" <> tail)})
    assert eventually(fn -> has_element?(view, "#pane [data-desk-left-out]", "def456") end)
    refute_receive {:reading, _task}, 100
  end
end
