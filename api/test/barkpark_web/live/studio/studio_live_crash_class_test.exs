defmodule BarkparkWeb.Studio.StudioLiveCrashClassTest do
  @moduledoc """
  Crash-class closure for the Studio LiveView dispatch (cycle-44 directive 3).

  The shell's 90-odd `handle_event/3` heads and 9 `handle_info/2` heads had no
  fall-through, so a stale/unknown phx event from an old client, or a stray
  PubSub message, used to FunctionClauseError-crash the whole session — the
  user lost unsaved editor state. Both now end in a catch-all that no-ops (the
  event catch-all logs a warning). This pins that the process survives.

  Also pins the multi-select cap in `StudioLive.Handlers.Bulk`: an unbounded
  `MapSet.put` of arbitrary client ids fed the per-click DB fan-out in
  `bulk_action`, so the selection is capped at 500.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias BarkparkWeb.Studio.StudioLive.Handlers.Bulk

  @dataset "production"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, conn: conn}
  end

  describe "dispatch fall-through keeps the session alive" do
    test "an unknown/stale phx event does not crash the LiveView", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post"))

      # A phx event name that matches no routing head (e.g. a stale button from
      # an old client) hits the catch-all instead of FunctionClauseError.
      render_hook(view, "totally-unknown-stale-event", %{"leftover" => "true"})

      assert Process.alive?(view.pid)
      assert is_binary(render(view))
    end

    test "a stray/unmatched PubSub message does not crash the LiveView", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post"))

      send(view.pid, {:some_unrouted_pubsub, %{"payload" => 1}})
      send(view.pid, :bare_unknown_atom)

      # render/1 round-trips through the process; a crash would raise here.
      assert is_binary(render(view))
      assert Process.alive?(view.pid)
    end
  end

  describe "Bulk multi-select cap" do
    defp socket_with(selected) do
      %Phoenix.LiveView.Socket{
        assigns: %{selected_doc_ids: selected, flash: %{}, __changed__: %{}}
      }
    end

    test "adding past the 500 cap flashes and never grows the set" do
      at_cap = MapSet.new(for i <- 1..500, do: "id-#{i}")

      {:noreply, socket} = Bulk.toggle_doc_checkbox(%{"id" => "id-501"}, socket_with(at_cap))

      assert MapSet.size(socket.assigns.selected_doc_ids) == 500
      refute MapSet.member?(socket.assigns.selected_doc_ids, "id-501")
      assert socket.assigns.flash["error"] =~ "Selection limit reached (500)"
    end

    test "deselecting always proceeds even at the cap" do
      at_cap = MapSet.new(for i <- 1..500, do: "id-#{i}")

      {:noreply, socket} = Bulk.toggle_doc_checkbox(%{"id" => "id-1"}, socket_with(at_cap))

      assert MapSet.size(socket.assigns.selected_doc_ids) == 499
      refute MapSet.member?(socket.assigns.selected_doc_ids, "id-1")
    end

    test "adds below the cap still grow the set" do
      {:noreply, socket} = Bulk.toggle_doc_checkbox(%{"id" => "p1"}, socket_with(MapSet.new()))

      assert MapSet.member?(socket.assigns.selected_doc_ids, "p1")
    end
  end
end
