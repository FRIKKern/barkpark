defmodule BarkparkWeb.SheetsReaderLiveTest do
  @moduledoc """
  M4 locks for the live public sheet reader at `/sheets/:slug`
  (`BarkparkWeb.SheetsReaderLive`, mounted by the Sheets plugin on the
  `:public_root` bucket — the Bulldocs `/papers/:slug` precedent).

  Published-only: a published sheet renders the read-only grid with the
  papers-style title header; a draft-only or unknown slug is a REAL 404.
  The reader is live — a session delta re-renders the mounted grid — and
  read-only is enforced twice: every editing affordance is absent from the
  rendered HTML, and a forged client event is dropped server-side
  (`send_ops` guards on `read_only`, so no session ever starts). The tab
  switcher keeps working.

  `async: false` — sheet sessions are globally registered processes, same
  as the grid/presence suites.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session

  @dataset "production"

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    put_cfg(debounce_ms: 60_000, idle_stop_ms: 60_000)
    # The public surface resolves within the seeded Default workspace
    # (get_public_document fails closed without one).
    Barkpark.TenancyFixtures.ensure_default_scope!()
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

  defp create_draft!(slug, tabs, attrs \\ %{}) do
    {:ok, doc} =
      Content.create_document(
        "sheet",
        Map.merge(%{"doc_id" => slug, "content" => %{"tabs" => tabs}}, attrs),
        @dataset
      )

    doc
  end

  defp publish!(slug) do
    {:ok, doc} = Content.publish_document(slug, "sheet", @dataset)
    doc
  end

  defp one_tab(cells), do: [%{"name" => "Data", "cells" => cells}]

  # Presence-free async re-renders — retry briefly instead of sleeping.
  defp eventually(fun, tries \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, tries) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(20)
      eventually(fun, tries - 1)
  end

  # ── published renders ───────────────────────────────────────────────────────

  test "a published sheet renders the read-only grid with the title header", %{conn: conn} do
    create_draft!(
      "rdr-pub",
      one_tab(%{"A1" => %{"v" => "hello"}, "B1" => %{"f" => "1+1", "v" => 2, "t" => "n"}}),
      %{"title" => "Quarterly Numbers"}
    )

    publish!("rdr-pub")

    {:ok, _view, html} = live(conn, "/sheets/rdr-pub")

    assert html =~ ~s(data-test-id="sheet-reader-head")
    assert html =~ "Quarterly Numbers"
    assert html =~ ~s(data-test-id="sheet-table")
    assert html =~ ~s(data-v="hello")
    # The formula cell shows its computed value.
    assert html =~ ~s(data-v="2")
  end

  test "the read-only grid wrapper is keyboard-focusable with grid a11y semantics",
       %{conn: conn} do
    create_draft!("rdr-a11y", one_tab(%{"A1" => %{"v" => "cell"}}))
    publish!("rdr-a11y")

    {:ok, _view, html} = live(conn, "/sheets/rdr-a11y")

    # WCAG 2.1.1: the scrollable grid wrapper is focusable even read-only
    # (the hook stays edit-only, but tabindex is now unconditional).
    assert html =~ ~s(id="sheet-reader-rdr-a11y-grid-view")
    assert html =~ ~s(tabindex="0")
    assert html =~ ~s(role="application")
    assert html =~ ~s(aria-label="Spreadsheet grid")
    # The table announces itself as a grid.
    assert html =~ ~s(role="grid")
    # WCAG 2.4.7: the reader layout ships the keyboard focus-ring rule. This
    # is a text-presence gate on the reader-layout CSS — a Chrome contrast
    # check is the true verification (manual, noted in the PR).
    assert html =~ ".sheet-grid-wrap:focus-visible"
    # No active-cell tracking in the read-only reader (edit-only attribute).
    refute html =~ "aria-activedescendant"
  end

  # ── 404s ────────────────────────────────────────────────────────────────────

  test "a draft-only sheet is a real 404 publicly", %{conn: conn} do
    create_draft!("rdr-draft", one_tab(%{"A1" => %{"v" => "secret"}}))

    assert_error_sent 404, fn -> get(conn, "/sheets/rdr-draft") end
  end

  test "an unknown slug is a real 404", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, "/sheets/no-such-sheet") end
  end

  # ── live deltas ─────────────────────────────────────────────────────────────

  test "a session delta updates a mounted reader live", %{conn: conn} do
    create_draft!("rdr-live", one_tab(%{"A1" => %{"v" => "old"}}))
    publish!("rdr-live")

    {:ok, view, html} = live(conn, "/sheets/rdr-live")
    assert html =~ ~s(data-v="old")

    {:ok, %{applied: 2, errors: []}} =
      Session.apply_ops("rdr-live", @dataset, [
        %{"op" => "set_cell", "tab" => 0, "ref" => "A1", "raw" => "fresh"},
        %{"op" => "set_cell", "tab" => 0, "ref" => "B2", "raw" => 42}
      ])

    eventually(fn ->
      html = render(view)
      assert html =~ ~s(data-v="fresh")
      assert html =~ ~s(data-v="42")
      refute html =~ ~s(data-v="old")
    end)
  end

  test "a structural delta refetches the grid", %{conn: conn} do
    create_draft!("rdr-struct", one_tab(%{"A1" => %{"v" => "head"}, "A2" => %{"v" => "tail"}}))
    publish!("rdr-struct")

    {:ok, view, _html} = live(conn, "/sheets/rdr-struct")

    {:ok, %{applied: 1}} =
      Session.apply_ops("rdr-struct", @dataset, [
        %{"op" => "insert_rows", "tab" => 0, "at" => 2, "count" => 1}
      ])

    eventually(fn ->
      html = render(view)
      assert html =~ ~s(data-ref="A3" data-r="3")
      assert html =~ ~s(data-v="tail")
    end)
  end

  # ── read-only affordances ───────────────────────────────────────────────────

  test "every editing affordance is absent; the tab switcher remains", %{conn: conn} do
    create_draft!(
      "rdr-ro",
      [
        %{"name" => "First", "cells" => %{"A1" => %{"v" => "tab-one"}}},
        %{"name" => "Second", "cells" => %{"A1" => %{"v" => "tab-two"}}}
      ]
    )

    publish!("rdr-ro")

    {:ok, view, html} = live(conn, "/sheets/rdr-ro")

    # No hook, no formula bar / name box, no header chrome, no structure
    # menus, no resize handles, no tab mutation buttons, no edit bindings.
    refute html =~ ~s(phx-hook="SheetGrid")
    refute html =~ "sheet-toolbar"
    refute html =~ ~s(data-test-id="sheet-formula-bar")
    refute html =~ ~s(data-test-id="sheet-namebox")
    refute html =~ ~s(data-test-id="sheet-mode-toggle")
    refute html =~ "menu-open"
    refute html =~ "rowcol-insert"
    refute html =~ "sheet-rsz"
    refute html =~ ~s(data-test-id="sheet-tab-add")
    refute html =~ ~s(data-test-id="sheet-tab-delete")
    refute html =~ "tab-rename-start"
    refute html =~ "edit-commit"
    refute html =~ "bar-commit"

    # The read-only tab switcher works.
    assert html =~ ~s(phx-click="tab-switch")
    assert html =~ ~s(data-v="tab-one")
    refute html =~ ~s(data-v="tab-two")

    view |> element(~s([data-test-id="sheet-tab-1"])) |> render_click()
    assert render(view) =~ ~s(data-v="tab-two")
  end

  test "a forged edit event is dropped server-side — no session ever starts", %{conn: conn} do
    create_draft!("rdr-forge", one_tab(%{"A1" => %{"v" => "immutable"}}))
    publish!("rdr-forge")

    {:ok, view, _html} = live(conn, "/sheets/rdr-forge")
    target = with_target(view, "#sheet-reader-rdr-forge")

    # Events a crafted client could push despite the stripped markup.
    render_hook(target, "edit-commit", %{"value" => "hacked", "move" => "none"})
    render_hook(target, "paste", %{"tsv" => "a\tb\nc\td"})
    render_hook(target, "tab-delete", %{"tab" => "0"})

    # send_ops dropped them all: no session started, the grid still shows
    # the published value.
    assert Session.whereis("rdr-forge", @dataset) == nil
    assert render(view) =~ ~s(data-v="immutable")
  end
end
