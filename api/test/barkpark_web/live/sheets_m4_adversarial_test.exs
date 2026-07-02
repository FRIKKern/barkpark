defmodule BarkparkWeb.SheetsM4AdversarialTest do
  @moduledoc """
  Adversarial M4 probes (independent skeptic pass) — the cases the shipped
  suites circle but never pin down:

    * two users undoing INTERLEAVED ops on the same cell (each undo restores
      the prior value captured at that user's op time — Google semantics);
    * undoing an insert AFTER another user wrote into the inserted span —
      the inverse delete eats their data (documented LWW), but the broadcast
      delta must still report every removed cell;
    * a BRUTAL `:kill` of an editor mid-edit with the presence `editing`
      flag set — observers must lose the tag (no ghost soft-lock);
    * 9+ users into the fixed 8-color palette — deterministic, palette-only,
      pigeonhole collision;
    * the public reader mounted on a 500+ row sheet respects the render cap.

  `async: false` — sheet sessions are globally registered processes and
  presence diffs fan out across test-spawned LiveViews, same as the M2/M4
  suites.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session
  alias BarkparkWeb.Studio.PresenceState

  @dataset "production"
  @palette ~w(#3b82f6 #ef4444 #10b981 #f59e0b #8b5cf6 #ec4899 #06b6d4 #f97316)

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    put_cfg(debounce_ms: 60_000, idle_stop_ms: 60_000)
    Barkpark.TenancyFixtures.ensure_default_scope!()
    seed_sheet_schema!()
    :ok
  end

  defp put_cfg(overrides) do
    base = Application.get_env(:barkpark, Barkpark.Plugins.Sheets.Session, [])

    Application.put_env(
      :barkpark,
      Barkpark.Plugins.Sheets.Session,
      Keyword.merge(base, overrides)
    )
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

  defp set_cell(ref, raw, user),
    do: %{"op" => "set_cell", "tab" => 0, "ref" => ref, "raw" => raw, "user" => user}

  defp undo(user), do: %{"op" => "undo", "user" => user}

  defp apply!(slug, ops) do
    {:ok, reply} = Session.apply_ops(slug, @dataset, ops)
    reply
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

  # ── interleaved undo on the same cell ───────────────────────────────────────

  test "two users undo interleaved ops on one cell — each restores the prior at THEIR op time" do
    create_sheet!("adv-interleave", %{})

    %{applied: 1} = apply!("adv-interleave", [set_cell("A1", "a1", "alice")])
    %{applied: 1} = apply!("adv-interleave", [set_cell("A1", "b1", "bob")])
    %{applied: 1} = apply!("adv-interleave", [set_cell("A1", "a2", "alice")])
    %{applied: 1} = apply!("adv-interleave", [set_cell("A1", "b2", "bob")])

    # Bob's undo restores the value HIS op overwrote ("a2")…
    %{applied: 1, errors: []} = apply!("adv-interleave", [undo("bob")])
    assert peek_cells("adv-interleave")["A1"] == %{"v" => "a2"}

    # …Alice's restores what HER "a2" overwrote ("b1") — overwriting Bob's
    # restoration, Google semantics…
    %{applied: 1, errors: []} = apply!("adv-interleave", [undo("alice")])
    assert peek_cells("adv-interleave")["A1"] == %{"v" => "b1"}

    # …and so on down both stacks until the cell is gone.
    %{applied: 1, errors: []} = apply!("adv-interleave", [undo("bob")])
    assert peek_cells("adv-interleave")["A1"] == %{"v" => "a1"}

    %{applied: 1, errors: []} = apply!("adv-interleave", [undo("alice")])
    refute Map.has_key?(peek_cells("adv-interleave"), "A1")

    %{applied: 0, errors: [%{code: "nothing_to_undo"}]} = apply!("adv-interleave", [undo("bob")])
  end

  # ── structural undo eats another user's cells — delta must say so ──────────

  test "undoing an insert after another user wrote into the span reports every removed cell" do
    doc = create_sheet!("adv-span", %{"A1" => %{"v" => "head"}, "A2" => %{"v" => "tail"}})

    %{applied: 1} =
      apply!("adv-span", [
        %{"op" => "insert_rows", "tab" => 0, "at" => 2, "count" => 2, "user" => "alice"}
      ])

    # Bob fills the inserted span (rows 2–3).
    %{applied: 2, errors: []} =
      apply!("adv-span", [set_cell("B2", "bob-1", "bob"), set_cell("B3", "bob-2", "bob")])

    Phoenix.PubSub.subscribe(
      Barkpark.PubSub,
      Session.topic("adv-span", @dataset, doc.workspace_id)
    )

    # Alice undoes the insert → delete_rows 2..3. Bob's cells die (documented
    # LWW) — but the delta must report them: B2/B3 → nil, A4 → nil (shifted
    # away), A2 → the shifted "tail".
    %{applied: 1, errors: []} = apply!("adv-span", [undo("alice")])

    assert_receive {:sheets_op, %{changed: changed, structure: %{op: "delete_rows"}}}, 1_000
    assert changed["B2"] == nil and Map.has_key?(changed, "B2")
    assert changed["B3"] == nil and Map.has_key?(changed, "B3")
    assert changed["A4"] == nil and Map.has_key?(changed, "A4")
    assert changed["A2"] == %{"v" => "tail"}

    assert peek_cells("adv-span") == %{"A1" => %{"v" => "head"}, "A2" => %{"v" => "tail"}}
  end

  # ── brutal kill mid-edit: no ghost editing tag ──────────────────────────────

  test "a :kill of an editor mid-edit clears the editing tag for observers" do
    create_sheet!("adv-kill", %{})
    {view1, _t1, _} = open_as!("adv-kill", "alice-id-001", "Alice")
    {view2, t2, _} = open_as!("adv-kill", "bob-id-002", "Bob")

    render_hook(t2, "cell-click", %{"ref" => "B2", "shift" => false})
    render_hook(t2, "edit-start", %{})

    # Peer decoration lives on the overlay layer, not the tds.
    peer_cursor = fn view, ref ->
      selector = ~s(.sheet-peer-cursor[data-peer-cell="#{ref}"])
      if has_element?(view, selector), do: view |> element(selector) |> render(), else: ""
    end

    eventually(fn ->
      assert peer_cursor.(view1, "B2") =~ "sheet-peer-editing"
      assert peer_cursor.(view1, "B2") =~ "Bob"
    end)

    # Brutal kill — no terminate/2, no graceful untrack. Presence is
    # monitor-based, so the leave must still propagate.
    Process.flag(:trap_exit, true)
    Process.exit(view2.pid, :kill)

    eventually(fn ->
      html = render(view1)
      refute html =~ "sheet-peer-editing"
      refute html =~ "Bob"
    end)
  end

  # ── 9th user color wraps deterministically ──────────────────────────────────

  test "nine users land deterministically inside the fixed 8-color palette" do
    ids = for i <- 1..9, do: "adv-user-#{i}"
    colors = Enum.map(ids, &PresenceState.pick_color/1)

    # Every pick is a palette member, repeat calls agree, and 9 users into 8
    # colors must collide (pigeonhole).
    assert Enum.all?(colors, &(&1 in @palette))
    assert colors == Enum.map(ids, &PresenceState.pick_color/1)
    assert length(Enum.uniq(colors)) < 9
  end

  # ── reader render bound ─────────────────────────────────────────────────────

  test "the public reader windows a 600-row sheet at 500 rows/page and pages the rest", %{conn: conn} do
    cells =
      for r <- 1..600, into: %{} do
        {"A#{r}", %{"v" => "row-#{r}"}}
      end

    create_sheet!("adv-bound", cells)
    {:ok, _doc} = Content.publish_document("adv-bound", "sheet", @dataset)

    {:ok, view, html} = live(conn, "/sheets/adv-bound")

    # Page 0: the first 500-row window renders; the pager is up; row 501 lives
    # on the next page (absolute data-refs keep cell identity stable).
    assert html =~ ~s(data-test-id="sheet-pager")
    assert html =~ ~s(data-r="500")
    refute html =~ ~s(data-r="501")
    refute html =~ "row-501"

    # Paging forward reveals row 501 (the pager reaches the read-only mount as
    # navigation, not a mutation) and the range text advances.
    html = view |> element(~s([data-test-id="sheet-pager-next"])) |> render_click()
    assert html =~ "row-501"
    assert html =~ ~s(data-r="501")
    assert html =~ "Showing rows 501"
    refute html =~ "row-500"
  end

  # ── session restart must not silently diverge connected grids ──────────────

  test "a session restart (rev re-counts from 0) triggers a client refetch, not silent divergence" do
    create_sheet!("adv-epoch", %{})
    {view, _grid, _html} = open_as!("adv-epoch", "u-alice", "Alice")

    # Drive the connected client's rev to 1 in the first incarnation.
    %{rev: 1} = apply!("adv-epoch", [set_cell("A1", "first-epoch", "alice")])
    eventually(fn -> assert render(view) =~ "first-epoch" end)

    # New incarnation re-counts rev from 1. Without the epoch stamp, the
    # client (already at rev 1) drops this frame as a stale duplicate and
    # the grid silently freezes on the old content forever.
    stop_all_sessions()

    # The Registry sweeps a dead pid asynchronously — wait it out so
    # call_session's single retry can't burn both attempts on the corpse
    # (real restarts are seconds apart; this race is test-only).
    eventually(fn ->
      assert Registry.lookup(
               Barkpark.Plugins.Sheets.SessionRegistry,
               {@dataset, "adv-epoch"}
             ) == []
    end)

    %{rev: 1} = apply!("adv-epoch", [set_cell("B2", "second-epoch", "bob")])
    eventually(fn -> assert render(view) =~ "second-epoch" end)
  end
end
