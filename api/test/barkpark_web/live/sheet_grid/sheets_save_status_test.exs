defmodule BarkparkWeb.SheetsSaveStatusTest do
  @moduledoc """
  PROOF for the Sheets Studio toolbar TRUST SIGNALS: the autosave status
  indicator and the visible undo/redo affordances.

  Autosave (debounce 2s / 25-ops / terminate flush) is solid but was 100%
  invisible; the depth-100 undo machine's only trigger was a JS keymap secret.
  This suite locks the fix from BOTH ends of the new seam:

    * `Session.persist_result/1` broadcasts `{:sheets_persisted, %{rev, epoch,
      ok, saved_at}}` on the `:sheets:op` topic — both the success and the
      failure branch.
    * `StudioLive` relays it to the `SheetGrid` component, which renders a
      quiet `role="status"` region (SEPARATE from the polite `@status` commit
      region) reading "Saving…" / "All changes saved · HH:MM" / "Save failed —
      retrying", plus visible Undo/Redo buttons wired to the SAME server events
      the keyboard fires.

  The reader (`/sheets/:slug`) shows NEITHER — it is a published, non-editing
  surface with no session and no save state.

  `async: false` — sheet sessions are globally registered processes that
  persist through the shared-mode SQL sandbox.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session

  @dataset "production"
  @slug "save-status-proof"

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    # A SHORT debounce so the "saved" transition is observable in-test; the
    # stale-frame / error / saving cases override to a long debounce so no
    # real persist races the hand-injected frame.
    put_cfg(debounce_ms: 80, idle_stop_ms: 60_000)
    Barkpark.TenancyFixtures.ensure_default_scope!()

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

  defp wait_until(fun, timeout \\ 3_000) do
    do_wait_until(fun, System.monotonic_time(:millisecond) + timeout)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met in time")

      true ->
        Process.sleep(20)
        do_wait_until(fun, deadline)
    end
  end

  # Seeds an empty sheet and opens it editable in Studio.
  defp open_editor(conn, slug \\ @slug) do
    {:ok, _doc} =
      Content.create_document(
        "sheet",
        %{"doc_id" => slug, "content" => %{"tabs" => [%{"name" => "Q3", "cells" => %{}}]}},
        @dataset
      )

    {:ok, editor, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/#{slug}"))
    {editor, with_target(editor, "#sheet-grid-#{slug}")}
  end

  defp commit(grid, ref, value) do
    render_hook(grid, "cell-click", %{"ref" => ref, "shift" => false})
    render_hook(grid, "edit-start", %{"seed" => String.first(value) || "x"})
    render_hook(grid, "edit-commit", %{"value" => value, "move" => "none"})
  end

  test "an edit flips the toolbar save-status region to Saving…", %{conn: conn} do
    # Long debounce: the persist never fires during the test, so the indicator
    # stays on :saving after the op delta round-trips.
    put_cfg(debounce_ms: 60_000)
    {editor, grid} = open_editor(conn)

    # Before any edit the region is hidden entirely.
    refute render(editor) =~ ~s(data-test-id="sheet-save-status")

    commit(grid, "B2", "1200")

    wait_until(fn -> render(editor) =~ "Saving…" end)
    html = render(editor)
    assert html =~ ~s(data-test-id="sheet-save-status")
    assert html =~ ~s(role="status")
  end

  test "after the debounced persist the region reads 'All changes saved · HH:MM'",
       %{conn: conn} do
    # Keep the short (80ms) debounce from setup so the persist actually lands.
    {editor, grid} = open_editor(conn)

    commit(grid, "B2", "1200")

    wait_until(fn -> render(editor) =~ ~r/All changes saved · \d{2}:\d{2}/ end)
  end

  test "a STALE persist frame (a rev the client has already passed) leaves it on Saving…",
       %{conn: conn} do
    put_cfg(debounce_ms: 60_000)
    {editor, grid} = open_editor(conn)

    # Two ops advance the client's rev to at least 2.
    commit(grid, "B2", "1200")
    commit(grid, "B3", "3400")
    wait_until(fn -> render(editor) =~ "Saving…" end)

    # A persist frame stamped with the rev of the FIRST op — it landed after
    # the client moved on, so the indicator must NOT settle to :saved.
    epoch = :sys.get_state(Session.whereis(@slug, @dataset)).epoch

    send(
      editor.pid,
      {:sheets_persisted,
       %{sheet_id: @slug, rev: 1, epoch: epoch, ok: true, saved_at: DateTime.utc_now()}}
    )

    html = render(editor)
    assert html =~ "Saving…"
    refute html =~ "All changes saved"
  end

  test "a failed persist frame reads 'Save failed — retrying'", %{conn: conn} do
    put_cfg(debounce_ms: 60_000)
    {editor, _grid} = open_editor(conn)

    send(
      editor.pid,
      {:sheets_persisted,
       %{sheet_id: @slug, rev: 1, epoch: nil, ok: false, saved_at: DateTime.utc_now()}}
    )

    # StudioLive relays the persist frame to the SheetGrid component via
    # `send_update`, which enqueues a DEFERRED `$send_update` onto the
    # LiveView's own mailbox — the :error save-state assign lands one message
    # loop AFTER this `send/2` returns. A single one-shot `render/1` can sample
    # the DOM before that deferred update applies (the flake), so poll the
    # eventually-consistent frame instead of a transient snapshot.
    wait_until(fn -> render(editor) =~ "Save failed — retrying" end)
  end

  test "the reader shows NEITHER the save-status region NOR the undo/redo buttons",
       %{conn: conn} do
    {:ok, _doc} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => "rdr-save",
          "content" => %{"tabs" => [%{"name" => "Q3", "cells" => %{"A1" => %{"v" => "x"}}}]}
        },
        @dataset
      )

    {:ok, _pub} = Content.publish_document("rdr-save", "sheet", @dataset)

    {:ok, view, html} = live(conn, "/sheets/rdr-save")

    refute html =~ ~s(data-test-id="sheet-save-status")
    refute html =~ ~s(data-test-id="sheet-undo-btn")
    refute html =~ ~s(data-test-id="sheet-redo-btn")
    # The reader IS the read-only grid (sanity check we mounted the right page).
    assert render(view) =~ ~s(data-test-id="sheet-reader")
  end

  test "the visible Undo button reverts the last edit and announces it; an empty stack alerts",
       %{conn: conn} do
    put_cfg(debounce_ms: 60_000)
    {editor, grid} = open_editor(conn)

    commit(grid, "B3", "42")
    wait_until(fn -> render(editor) =~ ~s(data-v="42") end)

    # Click the ghost Undo button — the SAME "undo" event the keyboard fires.
    html = editor |> element(~s([data-test-id="sheet-undo-btn"])) |> render_click()
    # The polite status region announces the success.
    assert html =~ "Undid last change"
    # The reverted value clears once the undo delta rides the session broadcast
    # back into this LiveView.
    wait_until(fn -> not (render(editor) =~ ~s(data-v="42")) end)

    # A second click has nothing left to undo — the assertive alert fires.
    html = editor |> element(~s([data-test-id="sheet-undo-btn"])) |> render_click()
    assert html =~ ~s(role="alert")
    assert html =~ "undo stack"
  end
end
