defmodule BarkparkWeb.SheetsReaderLiveTest do
  @moduledoc """
  M4 locks for the live public sheet reader at `/sheets/:slug`
  (`BarkparkWeb.SheetsReaderLive`, mounted by the Sheets plugin on the
  `:public_root` bucket — the Bulldocs `/papers/:slug` precedent).

  Published-only: a published sheet renders the read-only grid with the
  papers-style title header; a draft-only or unknown slug is a REAL 404.

  PUBLISH-GATE (the contract this suite enforces): the reader is
  published-perspective, NOT live-draft. A session delta (an unpublished
  edit) NEVER reaches the mounted reader — it would leak draft content to
  anonymous visitors and make the live socket disagree with a cold reload.
  The reader refreshes ONLY when a publish lands (the published-doc topic).
  Read-only is enforced in depth: every editing affordance is absent from
  the rendered HTML, a forged client event is dropped server-side
  (`send_ops` guards on `read_only`, so no session ever starts), and the
  grid drops deltas + skips the session peek while read-only. The tab
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

  # ── publish-gate: no draft leak ──────────────────────────────────────────────
  # The reader is published-perspective. Unpublished session edits (which
  # persist to the DRAFT row and stream as `{:sheets_op,…}` deltas) must NEVER
  # surface to an anonymous visitor; only a publish moves the reader forward.

  test "a session (draft) edit never streams to the reader — published-only", %{conn: conn} do
    create_draft!("rdr-gate", one_tab(%{"A1" => %{"v" => "public"}}))
    publish!("rdr-gate")

    {:ok, view, html} = live(conn, "/sheets/rdr-gate")
    assert html =~ ~s(data-v="public")

    # An editor opens a session and changes A1 — this persists to the draft
    # row (drafts.rdr-gate) and broadcasts a `{:sheets_op,…}` delta.
    {:ok, %{applied: 1, errors: []}} =
      Session.apply_ops("rdr-gate", @dataset, [
        %{"op" => "set_cell", "tab" => 0, "ref" => "A1", "raw" => "secret"}
      ])

    # The draft value NEVER reaches the anonymous reader — not on the live
    # socket, not after any async delta round-trip. Give any (bug-reintroduced)
    # forwarding a window to land, then assert it did not.
    Process.sleep(80)
    html = render(view)
    refute html =~ ~s(data-v="secret")
    assert html =~ ~s(data-v="public")
  end

  test "publishing a session's edits refreshes the reader to the new published content",
       %{conn: conn} do
    create_draft!("rdr-refresh", one_tab(%{"A1" => %{"v" => "public"}}))
    publish!("rdr-refresh")

    {:ok, view, html} = live(conn, "/sheets/rdr-refresh")
    assert html =~ ~s(data-v="public")

    # Edit via the session, flush it to the draft row, THEN publish.
    {:ok, %{applied: 1, errors: []}} =
      Session.apply_ops("rdr-refresh", @dataset, [
        %{"op" => "set_cell", "tab" => 0, "ref" => "A1", "raw" => "secret"}
      ])

    :ok = Session.flush("rdr-refresh", @dataset)
    publish!("rdr-refresh")

    # The publish lands on the published-doc topic; the reader re-reads the
    # published perspective and now shows the once-draft value.
    eventually(fn ->
      html = render(view)
      assert html =~ ~s(data-v="secret")
      refute html =~ ~s(data-v="public")
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

  test "a forged commit never peeks the live draft session into the status region",
       %{conn: conn} do
    create_draft!("rdr-peek", one_tab(%{"A1" => %{"v" => "public"}}))
    publish!("rdr-peek")

    {:ok, view, _html} = live(conn, "/sheets/rdr-peek")
    target = with_target(view, "#sheet-reader-rdr-peek")

    # A live draft session holds an unpublished cell value the anonymous reader
    # must never observe. Starting the session for the same sheet loads it.
    {:ok, %{applied: 1, errors: []}} =
      Session.apply_ops("rdr-peek", @dataset, [
        %{"op" => "set_cell", "tab" => 0, "ref" => "A1", "raw" => "draft-secret"}
      ])

    assert Session.whereis("rdr-peek", @dataset) != nil

    # Forge the commit events. Before the seal, announce_commit → committed_display
    # → Session.peek rendered the draft value into the aria-live status region.
    render_hook(target, "edit-commit", %{"value" => "x", "move" => "none"})
    render_hook(target, "bar-commit", %{"value" => "x", "move" => "none"})

    refute render(view) =~ "draft-secret"

    status_html = view |> element(~s([data-test-id="sheet-status"])) |> render()
    refute status_html =~ "draft-secret"
    assert status_html =~ ~r{data-test-id="sheet-status">\s*</div>}
  end

  # ── reader chrome (title / meta / print / mobile) ─────────────────────────────
  # Separate describe block so the reader-paging slice can append its own without
  # a merge conflict. The CSS assertions are TRIPWIRES: they prove the print and
  # mobile stylesheets ship, NOT that paged/mobile rendering looks right — the
  # visual halves rest on a manual Chrome print-preview + device-emulation pass.

  describe "reader chrome" do
    test "the page title reflects the sheet title with the Barkpark suffix + unfurl meta",
         %{conn: conn} do
      create_draft!(
        "rdr-chrome",
        one_tab(%{"A1" => %{"v" => "x"}}),
        %{"title" => "Quarterly Numbers"}
      )

      publish!("rdr-chrome")

      {:ok, view, _html} = live(conn, "/sheets/rdr-chrome")
      assert page_title(view) == "Quarterly Numbers · Barkpark"

      # The static <head> carries the og:title + description unfurl meta.
      resp = conn |> get("/sheets/rdr-chrome") |> html_response(200)
      assert resp =~ ~s(property="og:title")
      assert resp =~ "Quarterly Numbers · Barkpark"
      assert resp =~ ~s(name="description")
    end

    test "an untitled sheet falls back to the slug in the page title", %{conn: conn} do
      create_draft!("rdr-untitled", one_tab(%{"A1" => %{"v" => "x"}}))
      publish!("rdr-untitled")

      {:ok, view, _html} = live(conn, "/sheets/rdr-untitled")
      assert page_title(view) == "rdr-untitled · Barkpark"
    end

    test "the reader layout ships the print + mobile stylesheets", %{conn: conn} do
      create_draft!("rdr-css", one_tab(%{"A1" => %{"v" => "x"}}))
      publish!("rdr-css")

      resp = conn |> get("/sheets/rdr-css") |> html_response(200)
      assert resp =~ "@media print"
      assert resp =~ "max-width: 640px"
    end
  end
end
