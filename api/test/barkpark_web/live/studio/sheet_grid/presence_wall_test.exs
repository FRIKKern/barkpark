defmodule BarkparkWeb.Studio.SheetGrid.PresenceWallTest do
  @moduledoc """
  pds-w42: `Ops.push_presence/2` sits OUTSIDE `Ops.send_ops/2`'s
  `write_capable: false` wall, so a write-DENIED Studio member still writes
  state — presence meta on the per-sheet topic.

  This suite ENUMERATES that surface by run: it drives one write-denied
  `SheetGrid` socket (`write_capable: false`, `live_session: true`,
  `chrome: :studio` — the middle row of the moduledoc's three-shape table)
  through every event whose handler can reach `push_presence/2`, and reads
  the tracked meta back after each one. The baseline meta is a sentinel
  (`editing: "Z9", tab: 99, active: "Z9", selection: "Z9:Z9"`); an event that
  reaches Presence changes at least one sentinel key, one that does not
  leaves all four.

  The enumeration is an EXPLICIT expected map, not a filter over whatever the
  code does — a new presence callsite reachable without write capability, or
  a guard silently dropped, flips this test rather than sliding past it.

  `async: false` — `BarkparkWeb.Presence` is a globally-registered tracker
  and the meta merge lands on the local tracker ETS, same as the M4 suites.
  """
  use BarkparkWeb.ConnCase, async: false

  alias BarkparkWeb.Presence
  alias BarkparkWeb.Studio.SheetGrid
  alias BarkparkWeb.Studio.SheetGrid.GridData

  @sentinel %{editing: "Z9", tab: 99, active: "Z9", selection: "Z9:Z9"}

  # Every event whose handler body can reach `Ops.push_presence/2`, with the
  # params a forged client frame would carry. `head-click`/`cell-click` reach
  # it only through `commit_clickaway/2`, so they carry a commit draft.
  @probes [
    {"edit-start", %{"seed" => "x"}, []},
    {"edit-cancel", %{}, []},
    {"edit-commit", %{"value" => "x", "move" => "down"}, []},
    {"bar-commit", %{"value" => "x", "move" => "down"}, []},
    {"presence-meta", %{"active" => "B2", "selection" => "B2:C3"}, []},
    {"tab-switch", %{"tab" => "1"}, []},
    {"cell-click", %{"ref" => "B2", "commit" => "x"}, [editing: %{prefill: nil}]},
    {"head-click", %{"kind" => "col", "index" => "2", "shift" => false, "bar_commit" => "x"}, []}
  ]

  # The write-denied verdicts this codebase is expected to produce. `:wrote`
  # means the event reached Presence from a write-denied socket.
  @expected %{
    "edit-start" => :silent,
    "edit-cancel" => :wrote,
    "edit-commit" => :silent,
    "bar-commit" => :silent,
    "presence-meta" => :wrote,
    "tab-switch" => :wrote,
    "cell-click" => :wrote,
    "head-click" => :wrote
  }

  describe "presence writes reachable by a write-DENIED principal (enumeration)" do
    test "each presence-emitting event is classified :wrote or :silent" do
      detail =
        Map.new(@probes, fn {event, params, overrides} ->
          {event, probe(event, params, overrides)}
        end)

      for {event, verdict} <- Enum.sort(detail) do
        IO.puts("PRESENCE-WALL #{event}: #{inspect(verdict)}")
      end

      assert Map.new(detail, fn {event, verdict} -> {event, tag(verdict)} end) == @expected
    end

    test "edit-start is refused server-side — no editing meta reaches peers" do
      # THE FIX. Before it, a forged `edit-start` from a write-denied socket
      # broadcast `editing: "A1"` to every peer (a soft lock nobody could
      # honour, since edit-commit/bar-commit are walled). The client-side
      # READ_MODE_EVENTS drop was the only thing preventing it.
      assert tag(probe("edit-start", %{"seed" => "x"}, [])) == :silent
    end

    test "a WRITE-CAPABLE socket still broadcasts edit-start (the guard is not a blanket mute)" do
      # The control: same event, same socket shape, write capability flipped
      # on. A guard that silenced everyone would pass the test above while
      # breaking the soft lock this component ships.
      assert probe("edit-start", %{"seed" => "x"}, write_capable: true) ==
               {:wrote, %{editing: "A1", tab: 0}}
    end
  end

  # ── harness ───────────────────────────────────────────────────────────────

  # Track this test process on a unique per-sheet topic with the sentinel meta,
  # run one event through the component, and report what the meta looks like
  # after. `push_presence` runs in THIS process (handle_event is synchronous
  # and LiveComponents run in the LV process), so the tracked pid matches and
  # the merge lands on the local tracker ETS immediately.
  defp probe(event, params, overrides) do
    topic = "sheets:presence-wall:#{System.unique_integer([:positive])}"
    user_id = "u-#{System.unique_integer([:positive])}"
    {:ok, _ref} = Presence.track(self(), topic, user_id, @sentinel)

    socket = build_socket(topic, user_id, overrides)
    {:noreply, _socket} = SheetGrid.handle_event(event, params, socket)

    meta = current_meta(topic, user_id)
    Presence.untrack(self(), topic, user_id)

    changed =
      for {k, v} <- @sentinel, Map.get(meta, k, :__absent__) != v, into: %{} do
        {k, Map.get(meta, k, :__absent__)}
      end

    if changed == %{}, do: :silent, else: {:wrote, changed}
  end

  defp tag(:silent), do: :silent
  defp tag({:wrote, _}), do: :wrote

  defp current_meta(topic, user_id) do
    case Presence.get_by_key(topic, user_id) do
      %{metas: [meta | _]} -> meta
      _ -> %{}
    end
  end

  # The middle row of the moduledoc's three-shape table: a Studio member with
  # liveness but NO write capability. Presence IS wired (the host tracked it),
  # which is exactly the shape the row is about.
  defp build_socket(topic, user_id, overrides) do
    {:ok, socket} = SheetGrid.mount(%Phoenix.LiveView.Socket{})

    socket
    |> Phoenix.Component.assign(
      content: %{
        "tabs" => [
          %{"name" => "S0", "cells" => %{"A1" => %{"v" => "a"}}},
          %{"name" => "S1", "cells" => %{}}
        ]
      },
      slug: "presence-wall-#{System.unique_integer([:positive])}",
      dataset: "presence_wall_nodb",
      write_capable: false,
      live_session: true,
      chrome: :studio,
      presence_topic: topic,
      user_id: user_id
    )
    |> Phoenix.Component.assign(Map.new(overrides))
    |> GridData.derive_grid()
    |> GridData.derive_editable()
  end
end
