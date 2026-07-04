defmodule BarkparkWeb.Studio.SheetGrid.RemapTest do
  @moduledoc """
  SF-AM3 collaborator coherence for `BarkparkWeb.Studio.SheetGrid.Ops`:

    * the ANTI-CLOBBER GOLDEN — a viewer holding a selection + open editor
      inside a remotely-sorted rect follows its row, so the next edit-commit
      lands on the cell that MOVED (not the stale coordinate a collaborator
      shifted new content under). Driven end-to-end through two LiveViews, the
      sort applied server-side (the toolbar is SF-W's slice) exactly as a
      remote collaborator's sort would broadcast.

    * the remap_selection sort clause + remap_filters plumbing, unit-driven
      through the public `apply_delta/2` with synthetic structure payloads
      (no session needed — `Session.peek` returns `{:error, :no_session}` and
      `refetch` still runs the selection/filter remap): active + anchor follow
      their rows, positions outside the rect / other-tab sorts / malformed
      perms are untouched (degrade-never-crash), and a column insert/delete
      shifts / drops the per-viewer filter keys and funnel panel.

  `async: false` — the golden mounts globally-registered sheet sessions and
  fans presence diffs across test LiveViews, same as the M4 suites.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Core, as: Sheets
  alias Barkpark.Plugins.Sheets.Session
  alias BarkparkWeb.Studio.SheetGrid.Ops

  @dataset "production"

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    base = Application.get_env(:barkpark, Barkpark.Plugins.Sheets.Session, [])

    Application.put_env(
      :barkpark,
      Barkpark.Plugins.Sheets.Session,
      Keyword.merge(base, debounce_ms: 60_000, idle_stop_ms: 60_000)
    )

    Barkpark.TenancyFixtures.ensure_default_scope!()
    seed_sheet_schema!()
    :ok
  end

  # ── the anti-clobber golden (two-session, end-to-end) ─────────────────────

  # B selects B1 and opens an editor; a collaborator sorts A1:B3 by column A —
  # "banana" (row 1) moves to row 2, carrying B's "x1" to B2. B's active must
  # follow to B2 so his commit lands on the cell that MOVED, not the stale B1
  # (now "x2", apple's B). Without the sort remap clause B's commit clobbers B1.
  test "a remote sort remaps a peer's active cell + editor — the commit lands on the moved cell" do
    create_sheet!("rmp-sort-golden", %{
      "A1" => %{"v" => "banana"},
      "B1" => %{"v" => "x1"},
      "A2" => %{"v" => "apple"},
      "B2" => %{"v" => "x2"},
      "A3" => %{"v" => "cherry"},
      "B3" => %{"v" => "x3"}
    })

    {vb, tb, _} = open_as!("rmp-sort-golden", "bob-id-301", "Bob")

    # Bob selects B1 and opens the editor (a draft in progress inside the rect).
    render_hook(tb, "cell-click", %{"ref" => "B1", "shift" => false})
    render_hook(tb, "edit-start", %{})

    # A collaborator sorts A1:B3 ascending by column A (apple, banana, cherry).
    {:ok, %{applied: 1, errors: []}} =
      Session.apply_ops("rmp-sort-golden", @dataset, [
        %{
          "op" => "sort_range",
          "tab" => 0,
          "range" => "A1:B3",
          "keys" => [%{"col" => 0, "dir" => "asc"}],
          "user" => "alice"
        }
      ])

    # Bob's grid rendered the sorted content — banana is now in row 2, so "x1"
    # (Bob's cell) sits at B2.
    eventually(fn ->
      assert vb |> element(~s(td[data-ref="A2"])) |> render() =~ "banana"
      assert vb |> element(~s(td[data-ref="B2"])) |> render() =~ "x1"
    end)

    # Bob commits — his active followed to B2, so the edit lands there.
    render_hook(tb, "edit-commit", %{"value" => "bob-edit"})

    cells = peek_cells("rmp-sort-golden")
    assert cells["B2"]["v"] == "bob-edit"
    # The stale coordinate B1 now holds apple's B ("x2") — untouched by Bob.
    assert cells["B1"]["v"] == "x2"
  end

  # ── remap_selection sort clause (unit, via apply_delta) ───────────────────

  describe "remap_selection sort clause" do
    test "active + anchor inside the rect follow their rows" do
      # rect A1:A3, perm [2,0,1]: old row1→3, row2→1, row3→2.
      socket = build_socket(active: {1, 1}, anchor: {1, 2})
      socket = Ops.apply_delta(socket, sort_delta({1, 1, 1, 3}, [2, 0, 1]))

      assert socket.assigns.active == {1, 3}
      assert socket.assigns.anchor == {1, 1}
      # The next commit uses `active` — it targets the REMAPPED ref, not the stale.
      assert Sheets.format_ref(socket.assigns.active) == "A3"
    end

    test "a nil anchor stays nil" do
      socket = build_socket(active: {2, 1}, anchor: nil)
      socket = Ops.apply_delta(socket, sort_delta({1, 1, 2, 3}, [1, 0, 2]))

      assert socket.assigns.active == {2, 2}
      assert socket.assigns.anchor == nil
    end

    test "a position outside the rect is untouched" do
      # active E5 is right of the rect's last column (B) and below its last row.
      socket = build_socket(active: {5, 5}, anchor: nil)
      socket = Ops.apply_delta(socket, sort_delta({1, 1, 2, 3}, [2, 0, 1]))

      assert socket.assigns.active == {5, 5}
    end

    test "a sort on ANOTHER tab never touches this viewer's coordinates" do
      socket = build_socket(active: {1, 1}, anchor: {1, 2}, tab: 0)
      socket = Ops.apply_delta(socket, sort_delta({1, 1, 1, 3}, [2, 0, 1], 1))

      assert socket.assigns.active == {1, 1}
      assert socket.assigns.anchor == {1, 2}
    end

    test "a malformed perm degrades silently (no remap, no crash)" do
      socket = build_socket(active: {1, 1}, anchor: {1, 2})

      # perm not a list → the guard fails → catch-all → no remap.
      s1 = Ops.apply_delta(socket, sort_delta({1, 1, 1, 3}, "nope"))
      assert s1.assigns.active == {1, 1}
      assert s1.assigns.anchor == {1, 2}

      # rect missing entirely → clause head doesn't match → catch-all.
      s2 =
        Ops.apply_delta(
          build_socket(active: {1, 1}),
          %{
            rev: 1,
            tab: 0,
            changed: %{},
            structure: %{op: "sort_range", at: nil, count: nil, tab: 0, perm: [2, 0, 1]}
          }
        )

      assert s2.assigns.active == {1, 1}
    end
  end

  # ── filter column-remap (unit, via apply_delta) ───────────────────────────

  describe "remap_filters on a column insert/delete" do
    test "insert_cols shifts filter keys >= at and the open panel's column" do
      socket =
        build_socket(
          active: {1, 1},
          filters: %{2 => crit(), 5 => crit()},
          filter_panel: %{"col" => 5, "op" => "gt", "value" => "1", "value2" => ""}
        )

      socket = Ops.apply_delta(socket, col_delta("insert_cols", 3, 1))

      assert socket.assigns.filters == %{2 => crit(), 6 => crit()}
      assert socket.assigns.filter_panel["col"] == 6
    end

    test "delete_cols drops a deleted column's criterion and shifts the rest" do
      socket =
        build_socket(
          active: {1, 1},
          filters: %{2 => crit(), 3 => crit(), 5 => crit()},
          filter_panel: %{"col" => 5, "op" => "gt", "value" => "1", "value2" => ""}
        )

      socket = Ops.apply_delta(socket, col_delta("delete_cols", 3, 1))

      # Column 3 dropped; 5 shifted to 4; 2 untouched.
      assert socket.assigns.filters == %{2 => crit(), 4 => crit()}
      assert socket.assigns.filter_panel["col"] == 4
    end

    test "delete_cols on the OPEN panel's column closes the panel" do
      socket =
        build_socket(
          active: {1, 1},
          filters: %{3 => crit()},
          filter_panel: %{"col" => 3, "op" => "nonblank", "value" => "", "value2" => ""}
        )

      socket = Ops.apply_delta(socket, col_delta("delete_cols", 3, 1))

      assert socket.assigns.filters == %{}
      assert socket.assigns.filter_panel == nil
    end

    test "a ROW insert/delete never touches column-keyed filters" do
      socket = build_socket(active: {1, 1}, filters: %{2 => crit()}, filter_panel: nil)
      socket = Ops.apply_delta(socket, col_delta("insert_rows", 1, 1))

      assert socket.assigns.filters == %{2 => crit()}
    end
  end

  # ── tab-clamp editing clear (unit, via apply_delta) — QR-B / QR-D2 ────────

  describe "refetch tab-clamp clears a stale open editor only when the clamp OVERRIDES the remap" do
    test "a delete_tab that shrinks the list past the viewer clamps AND clears the open editor" do
      # There were 2 tabs; a collaborator deletes the ACTIVE trailing tab (index
      # 1). remap_tab(1, delete_tab tab:1) falls through to 1 (tab == i, no
      # shift), but the peeked content now has only 1 tab → the clamp pulls it to
      # 0: clamped(0) != remapped(1), so the viewer is forced onto DIFFERENT
      # content and the open editor is stale. (No session ⇒ peek is a no-op, so
      # the shorter content is set directly, exactly what a real peek would return.)
      {topic, user_id} = track_presence!("B2")

      socket =
        build_socket(
          tab: 1,
          editing: %{prefill: nil},
          content: %{"tabs" => [%{"name" => "S0", "cells" => %{}}]},
          presence_topic: topic,
          user_id: user_id
        )

      socket = Ops.apply_delta(socket, tab_delta(%{op: "delete_tab", tab: 1}))

      assert socket.assigns.tab == 0
      assert socket.assigns.editing == nil
      assert socket.assigns.notice =~ "tab you were editing was removed"
      # push_presence(%{editing: nil}) fired — the tracked meta cleared too.
      assert presence_editing(topic, user_id) == nil
    end

    test "a move_tab that remap-FOLLOWS the logical tab keeps the editor open (over-clear guard)" do
      # Viewer on tab 0; move_tab 0→1 re-indexes the SAME logical tab to 1. The
      # content under the viewer is unchanged (2 tabs, no shrink) so the clamp
      # can't override: clamped == remapped == 1 → the edit stays valid. This is
      # the guard against a naive "tab changed ⇒ clear" that over-clears.
      {topic, user_id} = track_presence!("A1")

      socket =
        build_socket(tab: 0, editing: %{prefill: nil}, presence_topic: topic, user_id: user_id)

      socket = Ops.apply_delta(socket, tab_delta(%{op: "move_tab", from: 0, to: 1}))

      assert socket.assigns.tab == 1
      assert socket.assigns.editing == %{prefill: nil}
      assert socket.assigns.notice == nil
      # No clear ⇒ no presence push: the tracked meta still reads the open edit.
      assert presence_editing(topic, user_id) == "A1"
    end

    test "the clamp fires but the editor is already closed — no notice, no presence push" do
      # Same shrink as the first test, but nothing is being edited. The clamp
      # still moves the tab, yet editing == nil ⇒ the guard skips the clear
      # (no phantom notice, no presence push on a viewer that wasn't editing).
      {topic, user_id} = track_presence!("A1")

      socket =
        build_socket(
          tab: 1,
          editing: nil,
          content: %{"tabs" => [%{"name" => "S0", "cells" => %{}}]},
          presence_topic: topic,
          user_id: user_id
        )

      socket = Ops.apply_delta(socket, tab_delta(%{op: "delete_tab", tab: 1}))

      assert socket.assigns.tab == 0
      assert socket.assigns.editing == nil
      assert socket.assigns.notice == nil
      # Untouched: no push_presence(%{editing: nil}) was issued.
      assert presence_editing(topic, user_id) == "A1"
    end

    test "a nil-structure refetch (session restart with fewer tabs) also clamps + clears" do
      # A pure rev-gap refetch carries NO :structure key → refetch(_, _, nil).
      # remap_tab(1, nil) = 1, but the restarted session peeks back only 1 tab →
      # the clamp pulls to 0: clamped != remapped, so the stale editor clears
      # even though no tab-reordering op named it.
      {topic, user_id} = track_presence!("C3")

      socket =
        build_socket(
          rev: 1,
          tab: 1,
          editing: %{prefill: nil},
          content: %{"tabs" => [%{"name" => "S0", "cells" => %{}}]},
          presence_topic: topic,
          user_id: user_id
        )

      # rev jumps 1 → 5 with NO :structure key: the pure rev-gap refetch path.
      socket = Ops.apply_delta(socket, %{rev: 5, tab: 0, changed: %{}})

      assert socket.assigns.tab == 0
      assert socket.assigns.editing == nil
      assert socket.assigns.notice =~ "tab you were editing was removed"
      assert presence_editing(topic, user_id) == nil
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp sort_delta(rect, perm, tab \\ 0) do
    %{
      rev: 1,
      tab: tab,
      changed: %{},
      structure: %{op: "sort_range", at: nil, count: nil, tab: tab, rect: rect, perm: perm}
    }
  end

  defp col_delta(op, at, count, tab \\ 0) do
    %{
      rev: 1,
      tab: tab,
      changed: %{},
      structure: %{op: op, at: at, count: count, tab: tab}
    }
  end

  # A structural delta carrying a tab-reordering structure map (move_tab /
  # duplicate_tab / delete_tab) — the shape `apply_delta` routes to `refetch/3`.
  defp tab_delta(structure, tab \\ 0) do
    %{rev: 1, tab: tab, changed: %{}, structure: structure}
  end

  # Track this test process on a unique per-sheet presence topic with an open
  # `editing` meta, mirroring what the hosting StudioLive tracks for an editor.
  # `push_presence` runs in THIS process (apply_delta is synchronous), so the
  # tracked pid matches and the meta merge lands on the local tracker ETS
  # immediately — no cross-node propagation to wait on.
  defp track_presence!(editing) do
    topic = "sheets:remap:presence:#{System.unique_integer([:positive])}"
    user_id = "u-#{System.unique_integer([:positive])}"
    {:ok, _ref} = BarkparkWeb.Presence.track(self(), topic, user_id, %{editing: editing})
    {topic, user_id}
  end

  # The `editing` value currently on the tracked presence meta (:__no_entry__ if
  # the key is gone). A push_presence(%{editing: nil}) leaves it nil; no push
  # leaves the original.
  defp presence_editing(topic, user_id) do
    case BarkparkWeb.Presence.get_by_key(topic, user_id) do
      %{metas: [meta | _]} -> Map.get(meta, :editing, :__absent__)
      _ -> :__no_entry__
    end
  end

  defp crit, do: %{"op" => "nonblank"}

  # A bare SheetGrid component socket with the assigns apply_delta/refetch read.
  # No live session is registered, so `Session.peek` returns {:error,
  # :no_session} and refetch keeps content stale but STILL runs the selection +
  # filter remap — exactly the seam under test.
  defp build_socket(overrides) do
    base = %{
      rev: 0,
      epoch: nil,
      tab: 0,
      active: {1, 1},
      anchor: nil,
      editing: nil,
      notice: nil,
      content: %{
        "tabs" => [
          %{"name" => "S0", "cells" => %{}},
          %{"name" => "S1", "cells" => %{}}
        ]
      },
      slug: "rmp-nodb-#{System.unique_integer([:positive])}",
      dataset: "remap_test_nodb",
      find_query: nil,
      find_hits: MapSet.new(),
      filters: %{},
      filter_panel: nil
    }

    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(Map.merge(base, Map.new(overrides)))
  end

  defp seed_sheet_schema! do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "sheet",
          "title" => "Sheets",
          "icon" => "grid",
          "visibility" => "private",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )
  end

  defp create_sheet!(slug, cells) do
    {:ok, doc} =
      Content.create_document(
        "sheet",
        %{"doc_id" => slug, "content" => %{"tabs" => [%{"name" => "Data", "cells" => cells}]}},
        @dataset
      )

    doc
  end

  defp peek_cells(slug) do
    {:ok, content} = Session.peek(slug, @dataset)
    get_in(content, ["tabs", Access.at(0), "cells"])
  end

  defp open_as!(slug, user_id, user_name) do
    conn =
      Phoenix.ConnTest.build_conn()
      |> put_connect_params(%{"user_id" => user_id, "user_name" => user_name})

    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/#{slug}"))
    {view, with_target(view, "#sheet-grid-#{slug}"), html}
  end

  defp eventually(fun, tries \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, tries) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(20)
      eventually(fun, tries - 1)
  end

  defp stop_all_sessions do
    for {_, pid, _, _} <-
          DynamicSupervisor.which_children(Barkpark.Plugins.Sheets.SessionSupervisor),
        is_pid(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end
end
