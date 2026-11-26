defmodule BarkparkWeb.Studio.DeskRejoinEditorTest do
  @moduledoc """
  task-2f3d3e3835f2a755: a desk socket that rejoins after a drop drew its
  first render with the document pane still loading and no editor, so the
  join patch dropped the browser's editor section, and with it what was
  typed offline. On a rejoin (LiveView's `_mounts` connect param above 0)
  the pending document now loads inside the join render.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  setup %{conn: conn}, do: setup_doc(conn)

  defp desk(c, id), do: "#{c.root}/_desk/#{c.type};#{id}"

  # The join, and whether the page sent itself the deferred load
  # (`{:desk_edit, target}`): traced on receive, so no read of the page can
  # race the message it is about.
  defp joined(c, path, mounts) do
    :erlang.trace_pattern(:receive, [{[:_, :_, {:desk_edit, :_}], [], []}], [])
    :erlang.trace(:new_processes, true, [:receive])

    {:ok, view, html} =
      try do
        c.conn |> put_connect_params(%{"_mounts" => mounts}) |> live(path)
      after
        :erlang.trace(:new_processes, false, [:receive])
      end

    _ = :sys.get_state(view.pid)
    pid = view.pid
    deferred? = Enum.any?(drain(), &match?({:trace, ^pid, :receive, {:desk_edit, _}}, &1))
    {view, LazyHTML.from_document(html), deferred?}
  end

  defp drain do
    receive do
      {:trace, _, :receive, _} = t -> [t | drain()]
    after
      200 -> []
    end
  end

  defp has?(doc, selector), do: LazyHTML.query(doc, selector) |> Enum.count() > 0

  # LiveViewTest always joins with `_mounts: 0` (client_proxy.ex), so a
  # rejoin is the page's own flag, set as `mount/3` sets it from that param.
  defp rejoined(c, path) do
    {view, _doc, _} = joined(c, desk(c, c.id <> "-link"), 0)
    assert eventually(fn -> has_element?(view, "#editor-form") end)

    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns, &Map.put(&1, :desk_rejoin?, true))
    end)

    :erlang.trace_pattern(:receive, [{[:_, :_, {:desk_edit, :_}], [], []}], [])
    :erlang.trace(view.pid, true, [:receive])
    html = render_patch(view, path)
    :erlang.trace(view.pid, false, [:receive])
    pid = view.pid
    {view, html, Enum.any?(drain(), &match?({:trace, ^pid, :receive, {:desk_edit, _}}, &1))}
  end

  test "rejoin?/1 reads LiveView's `_mounts`: above 0 is a rejoin" do
    assert BarkparkWeb.Studio.DeskLive.rejoin?(%{"_mounts" => 1})
    refute BarkparkWeb.Studio.DeskLive.rejoin?(%{"_mounts" => 0})
    refute BarkparkWeb.Studio.DeskLive.rejoin?(%{})
    refute BarkparkWeb.Studio.DeskLive.rejoin?(false)
  end

  test "a rejoin's first patch loads the open document in that render: no deferred load", c do
    {view, html, deferred?} = rejoined(c, desk(c, c.id))

    refute deferred?
    assert html =~ "data-pane-editing"
    assert has_element?(view, ~s(section[data-pane-editing][id$="-editor"] #editor-form))
    assert :sys.get_state(view.pid).socket.assigns.desk_rejoin? == false
  end

  test "control: a first join still draws the pane first and the editor after", c do
    {view, doc, deferred?} = joined(c, desk(c, c.id), 0)

    assert deferred?
    refute has?(doc, "[data-pane-editing]")
    assert eventually(fn -> has_element?(view, "#editor-form") end)
  end

  test "after the rejoin, a patch to another document defers again", c do
    {view, _html, false} = rejoined(c, desk(c, c.id))
    html = render_patch(view, desk(c, c.id <> "-link"))

    refute html =~ "data-pane-editing"
    assert eventually(fn -> has_element?(view, "#editor-form") end)
  end

  test "a rejoin on a document that is gone, or on a list, loads nothing and does not crash",
       c do
    {view, _html, _} = rejoined(c, desk(c, c.id <> "-nope"))
    assert Process.alive?(view.pid)

    {view, _html, deferred?} = rejoined(c, "#{c.root}/_desk/#{c.type}")
    assert Process.alive?(view.pid)
    refute deferred?
    refute has_element?(view, "[data-pane-editing]")
  end
end
