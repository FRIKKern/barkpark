defmodule BarkparkWeb.Studio.StudioLiveSheetPresenceTest do
  @moduledoc """
  Sheets M4 — grid collaborator presence.

  Two LiveViewTest mounts on the same sheet prove the full presence loop
  through the real spine: the hosting StudioLive tracks each editor on the
  per-sheet topic (`Barkpark.Sheets.Session.presence_topic/3` via
  `BarkparkWeb.Presence`); the SheetGrid component renders collaborators'
  cursors (colored outline + name tag), selection overlays and the
  emphasized editing tag; meta updates ride the component's `presence-meta`
  event (the hook's client-throttled frame) and the edit-start/commit/cancel
  editing lifecycle; a process exit becomes a presence leave. Colors are
  deterministic per user_id (`PresenceState.pick_color/1` — the studio
  in-bar identity convention, reused).

  `async: false` — sheet sessions are globally registered processes and
  presence diffs fan out across test-spawned LiveViews, same as the M2
  grid suite.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias BarkparkWeb.Studio.PresenceState

  @dataset "production"

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Sheets.Session)
    end)

    put_cfg(debounce_ms: 60_000, idle_stop_ms: 60_000)
    seed_sheet_schema!()
    :ok
  end

  defp put_cfg(overrides) do
    base = Application.get_env(:barkpark, Barkpark.Sheets.Session, [])
    Application.put_env(:barkpark, Barkpark.Sheets.Session, Keyword.merge(base, overrides))
  end

  defp stop_all_sessions do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Barkpark.Sheets.SessionSupervisor),
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
        %{
          "doc_id" => slug,
          "content" => %{"locale" => "nb-NO", "tabs" => [%{"name" => "Data", "cells" => cells}]}
        },
        @dataset
      )

    doc
  end

  # Mount Studio on a sheet AS a specific identity — the same localStorage
  # connect params the studio in-bar presence reads (user_id + user_name;
  # no stored color, so the deterministic palette pick applies).
  defp open_as!(slug, user_id, user_name) do
    conn =
      Phoenix.ConnTest.build_conn()
      |> put_connect_params(%{"user_id" => user_id, "user_name" => user_name})

    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/#{slug}"))
    {view, with_target(view, "#sheet-grid-#{slug}"), html}
  end

  defp cell(view, ref) do
    view |> element(~s(td[data-ref="#{ref}"])) |> render()
  end

  # Presence diffs (Phoenix.Tracker) and LV re-renders are asynchronous —
  # retry the assertion briefly instead of sleeping a fixed eternity.
  defp eventually(fun, tries \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, tries) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(20)
      eventually(fun, tries - 1)
  end

  # ── join + color determinism ───────────────────────────────────────────────

  test "two editors on the same sheet see each other's join at the seeded A1 cursor" do
    create_sheet!("sp-join", %{"A1" => %{"v" => "x"}})
    {view1, _t1, _} = open_as!("sp-join", "alice-id-001", "Alice")
    {view2, _t2, _} = open_as!("sp-join", "bob-id-002", "Bob")

    # Each sees the OTHER's name tag parked at A1 (the tracked seed meta)…
    eventually(fn ->
      assert cell(view1, "A1") =~ "sheet-peer-tag"
      assert cell(view1, "A1") =~ "Bob"
      assert cell(view2, "A1") =~ "Alice"
    end)

    # …never their own (self is excluded from the peer list), and the tag
    # carries the deterministic palette color for the peer's user_id.
    refute cell(view1, "A1") =~ "Alice"
    refute cell(view2, "A1") =~ "Bob"
    assert cell(view1, "A1") =~ "background: #{PresenceState.pick_color("bob-id-002")}"
    assert cell(view2, "A1") =~ "background: #{PresenceState.pick_color("alice-id-001")}"
  end

  test "colors are deterministic per user_id from the fixed palette" do
    # Same user = same color, every call, and always a palette member.
    color = PresenceState.pick_color("carol-id-003")
    assert color == PresenceState.pick_color("carol-id-003")
    assert color =~ ~r/^#[0-9a-f]{6}$/

    palette = for uid <- 1..100, do: PresenceState.pick_color("user-#{uid}")
    assert palette |> Enum.uniq() |> length() <= 8
  end

  # ── cursor + selection ─────────────────────────────────────────────────────

  test "a presence-meta frame moves the peer cursor; a range renders the overlay" do
    create_sheet!("sp-cursor", %{})
    {view1, _t1, _} = open_as!("sp-cursor", "alice-id-001", "Alice")
    {_view2, t2, _} = open_as!("sp-cursor", "bob-id-002", "Bob")

    # Cursor move — the tag leaves A1 and lands on B4 with the outline class.
    render_hook(t2, "presence-meta", %{"active" => "B4", "selection" => nil})

    eventually(fn ->
      assert cell(view1, "B4") =~ "sheet-peer-cursor"
      assert cell(view1, "B4") =~ "Bob"
      refute cell(view1, "A1") =~ "Bob"
    end)

    # Selection — every cell of B2:C3 gets the translucent overlay class;
    # a cell outside the rect stays clean.
    render_hook(t2, "presence-meta", %{"active" => "B2", "selection" => "B2:C3"})

    eventually(fn ->
      assert cell(view1, "B2") =~ "sheet-peer-sel"
      assert cell(view1, "C3") =~ "sheet-peer-sel"
      refute cell(view1, "D4") =~ "sheet-peer-sel"
    end)
  end

  test "a malformed presence frame degrades to no cursor instead of erroring" do
    create_sheet!("sp-junk", %{})
    {view1, _t1, _} = open_as!("sp-junk", "alice-id-001", "Alice")
    {_view2, t2, _} = open_as!("sp-junk", "bob-id-002", "Bob")

    eventually(fn -> assert cell(view1, "A1") =~ "Bob" end)

    render_hook(t2, "presence-meta", %{"active" => "not-a-ref", "selection" => "junk"})

    eventually(fn -> refute render(view1) =~ "sheet-peer-tag" end)
  end

  # ── editing flag lifecycle ─────────────────────────────────────────────────

  test "edit-start emphasizes the peer tag on the edited cell; commit clears it" do
    create_sheet!("sp-edit", %{})
    {view1, _t1, _} = open_as!("sp-edit", "alice-id-001", "Alice")
    {view2, t2, _} = open_as!("sp-edit", "bob-id-002", "Bob")

    render_hook(t2, "cell-click", %{"ref" => "B2", "shift" => false})
    render_hook(t2, "edit-start", %{})

    eventually(fn ->
      assert cell(view1, "B2") =~ "sheet-peer-editing"
      assert cell(view1, "B2") =~ "Bob"
    end)

    render_hook(t2, "edit-commit", %{"value" => "42", "move" => "none"})

    eventually(fn ->
      # The soft lock lifts (LWW stood all along); the committed value
      # reached the other editor through the session delta.
      refute render(view1) =~ "sheet-peer-editing"
      assert render(view1) =~ ~s(data-v="42")
    end)

    # Cancel clears it too.
    render_hook(t2, "edit-start", %{})
    eventually(fn -> assert cell(view1, "B2") =~ "sheet-peer-editing" end)
    render_hook(t2, "edit-cancel", %{})
    eventually(fn -> refute render(view1) =~ "sheet-peer-editing" end)

    # view2 never saw a tag of ITSELF on the cell it edited (Alice's tag
    # sits parked at A1 — that one is legitimate).
    refute cell(view2, "B2") =~ "sheet-peer-tag"
  end

  # ── departure ──────────────────────────────────────────────────────────────

  test "a departing editor's cursor leaves with their process" do
    create_sheet!("sp-leave", %{})
    {view1, _t1, _} = open_as!("sp-leave", "alice-id-001", "Alice")
    {view2, _t2, _} = open_as!("sp-leave", "bob-id-002", "Bob")

    eventually(fn -> assert cell(view1, "A1") =~ "Bob" end)

    # Process exit -> presence leave -> the tag disappears for the survivor.
    Process.flag(:trap_exit, true)
    GenServer.stop(view2.pid)

    eventually(fn -> refute render(view1) =~ "Bob" end)
  end

  # ── bystander read access ──────────────────────────────────────────────────

  test "a third anonymous mount reads the sheet unaffected by presence" do
    create_sheet!("sp-anon", %{"A1" => %{"v" => "hello"}})
    {_view1, _t1, _} = open_as!("sp-anon", "alice-id-001", "Alice")
    {_view2, t2, _} = open_as!("sp-anon", "bob-id-002", "Bob")
    render_hook(t2, "presence-meta", %{"active" => "C3", "selection" => "C3:D4"})

    # No connect params at all — the dev fallback identity (random user_id,
    # "User xxxx" name) mounts fine and reads the live grid + both peers.
    {:ok, view3, html3} = live(build_conn(), scoped_studio("/d/#{@dataset}/studio/sheet/sp-anon"))

    assert html3 =~ ~s(data-test-id="sheet-table")
    assert html3 =~ ~s(data-v="hello")

    eventually(fn ->
      html = render(view3)
      assert html =~ "Alice"
      assert html =~ "Bob"
    end)
  end
end
