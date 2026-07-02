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
    assert html =~ ~s(aria-label="Spreadsheet grid")
    # WCAG 4.1.2: role="application" is edit-only. On the read-only reader it
    # was a dead focus zone that ALSO muted the screen reader's own table-nav
    # commands. Dropping it leaves the inner role="grid" table readable in
    # browse mode; aria-readonly announces the cells cannot be edited.
    refute html =~ ~s(role="application")
    assert html =~ ~s(role="grid")
    assert html =~ ~s(aria-readonly="true")
    # WCAG 2.4.7: the reader layout ships the keyboard focus-ring rule. This
    # is a text-presence gate on the reader-layout CSS — a Chrome contrast
    # check is the true verification (manual, noted in the PR).
    assert html =~ ".sheet-grid-wrap:focus-visible"
    # No active-cell tracking in the read-only reader (edit-only attribute).
    refute html =~ "aria-activedescendant"
  end

  # ── a11y honest counts on the public reader (same renderer) ─────────────────

  test "the reader announces the whole sheet height, not the paged window", %{conn: conn} do
    # A600 spans two 500-row pages; the reader body renders only page 0 but the
    # count must report the FULL logical height. Rows are paged (never clipped),
    # so that is `rows` = used_rows(600) + 2 navigable padding rows = 602
    # (+1 gutter header = 603). The earlier `used_rows` under-count (601) let the
    # last page's aria-rowindex overrun the count.
    create_draft!("rdr-bigcount", one_tab(%{"A1" => %{"v" => "top"}, "A600" => %{"v" => "far"}}))
    publish!("rdr-bigcount")

    {:ok, _view, html} = live(conn, "/sheets/rdr-bigcount")

    assert html =~ ~s(aria-rowcount="603")
    assert html =~ ~s(aria-rowindex="501")
    refute html =~ ~s(aria-rowindex="502")
  end

  test "the reader pins a td's colindex past a rowspan (APG grid indices)", %{conn: conn} do
    # B2:C3 merged: on row 3 the covered B3/C3 tds are skipped, so D3's DOM
    # position shifts — but its explicit aria-colindex stays 5 (gutter 1, A 2,
    # B 3, C 4, D 5), and the gutters carry their columnheader/rowheader roles.
    create_draft!("rdr-merge-idx", [
      %{"name" => "Data", "cells" => %{"D3" => %{"v" => "keep"}}, "merges" => ["B2:C3"]}
    ])

    publish!("rdr-merge-idx")

    {:ok, _view, html} = live(conn, "/sheets/rdr-merge-idx")

    assert Regex.match?(
             ~r/aria-colindex="5"[^>]*data-ref="D3"|data-ref="D3"[^>]*aria-colindex="5"/,
             html
           )

    assert html =~ ~s(role="columnheader")
    assert html =~ ~s(scope="col")
    assert html =~ ~s(role="rowheader")
    assert html =~ ~s(scope="row")
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

  test "the reader renders a checkbox glyph but a forged cell-toggle never mutates it",
       %{conn: conn} do
    create_draft!("rdr-cb", one_tab(%{"A1" => %{"v" => true, "fmt" => "checkbox"}}))
    publish!("rdr-cb")

    {:ok, view, html} = live(conn, "/sheets/rdr-cb")

    # The read-only grid shows the glyph + checkbox a11y role, but NO toggle
    # affordance (no phx-click binding on the cell).
    assert html =~ "☑"
    assert html =~ ~s(role="checkbox")
    assert html =~ ~s(aria-checked="true")
    refute html =~ ~s(phx-click="cell-toggle")

    target = with_target(view, "#sheet-reader-rdr-cb")
    render_hook(target, "cell-toggle", %{"ref" => "A1"})

    # send_ops drops the forged toggle: no session starts, the value holds.
    assert Session.whereis("rdr-cb", @dataset) == nil
    assert render(view) =~ "☑"
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

  # ── reader row paging ────────────────────────────────────────────────────────
  # A published sheet taller than one 500-row window is fully reachable through
  # the pager. Paging is PURE navigation (an assign + re-derive, never a mutation
  # op), so it works on the read-only reader AND can never start a session.

  describe "reader row paging" do
    test "pages past the 500-row window: next reveals deep rows, prev returns",
         %{conn: conn} do
      create_draft!("rdr-page", one_tab(%{"A1" => %{"v" => "top"}, "A600" => %{"v" => "deep"}}))
      publish!("rdr-page")

      {:ok, view, html} = live(conn, "/sheets/rdr-page")

      # Page 0: the first window renders, the deep row does NOT, the pager is up.
      assert html =~ ~s(data-test-id="sheet-pager")
      assert html =~ ~s(data-ref="A1")
      refute html =~ ~s(data-ref="A600")

      # Flip forward — the deep published row (unreachable before this fix) shows,
      # the first window is gone, the range text updates.
      html = view |> element(~s([data-test-id="sheet-pager-next"])) |> render_click()
      assert html =~ ~s(data-ref="A600")
      refute html =~ ~s(data-ref="A1")
      assert html =~ "Showing rows 501"

      # …and back.
      html = view |> element(~s([data-test-id="sheet-pager-prev"])) |> render_click()
      assert html =~ ~s(data-ref="A1")
      refute html =~ ~s(data-ref="A600")
    end

    test "the page buttons disable at the bounds", %{conn: conn} do
      create_draft!("rdr-bounds", one_tab(%{"A1" => %{"v" => "top"}, "A600" => %{"v" => "deep"}}))
      publish!("rdr-bounds")

      {:ok, view, _html} = live(conn, "/sheets/rdr-bounds")

      # First page: prev disabled, next live.
      assert has_element?(view, ~s([data-test-id="sheet-pager-prev"][disabled]))
      refute has_element?(view, ~s([data-test-id="sheet-pager-next"][disabled]))

      view |> element(~s([data-test-id="sheet-pager-next"])) |> render_click()

      # Last page: next disabled, prev live.
      assert has_element?(view, ~s([data-test-id="sheet-pager-next"][disabled]))
      refute has_element?(view, ~s([data-test-id="sheet-pager-prev"][disabled]))
    end

    test "switching tabs resets paging to the first page", %{conn: conn} do
      create_draft!("rdr-page-tabs", [
        %{
          "name" => "Big",
          "cells" => %{"A1" => %{"v" => "big-top"}, "A600" => %{"v" => "big-deep"}}
        },
        %{"name" => "Small", "cells" => %{"A1" => %{"v" => "small"}}}
      ])

      publish!("rdr-page-tabs")

      {:ok, view, _html} = live(conn, "/sheets/rdr-page-tabs")

      # Page into the tall tab.
      html = view |> element(~s([data-test-id="sheet-pager-next"])) |> render_click()
      assert html =~ ~s(data-v="big-deep")

      # A tab switch resets the window; back on the tall tab it opens at page 0.
      view |> element(~s([data-test-id="sheet-tab-1"])) |> render_click()
      html = view |> element(~s([data-test-id="sheet-tab-0"])) |> render_click()
      assert html =~ ~s(data-v="big-top")
      refute html =~ ~s(data-v="big-deep")
    end

    test "a forged rows-page event pages the view but starts NO session", %{conn: conn} do
      create_draft!(
        "rdr-forge-page",
        one_tab(%{"A1" => %{"v" => "top"}, "A600" => %{"v" => "deep"}})
      )

      publish!("rdr-forge-page")

      {:ok, view, _html} = live(conn, "/sheets/rdr-forge-page")
      target = with_target(view, "#sheet-reader-rdr-forge-page")

      # A crafted client pushes the paging event directly: navigation only —
      # the window advances but no session is spun up (never `send_ops`).
      render_hook(target, "rows-page", %{"dir" => "next"})
      assert render(view) =~ ~s(data-ref="A600")
      assert Session.whereis("rdr-forge-page", @dataset) == nil

      # An offset forged past the last page clamps to a real page (no crash),
      # still session-free.
      render_hook(target, "rows-page", %{"dir" => "next"})
      render_hook(target, "rows-page", %{"dir" => "next"})
      assert Session.whereis("rdr-forge-page", @dataset) == nil
    end

    test "a >64-column sheet surfaces the clip in the pager; no buttons when only wide",
         %{conn: conn} do
      wide = Barkpark.Plugins.Sheets.Core.format_ref({70, 1})
      create_draft!("rdr-wide", one_tab(%{"A1" => %{"v" => "x"}, wide => %{"v" => "edge"}}))
      publish!("rdr-wide")

      {:ok, view, html} = live(conn, "/sheets/rdr-wide")

      # One screen of rows, 70 columns → the columns-only sentence, no page buttons.
      assert html =~ ~s(data-test-id="sheet-pager")
      assert html =~ "first 64 of 70 columns"
      refute has_element?(view, ~s([data-test-id="sheet-pager-next"]))
      refute has_element?(view, ~s([data-test-id="sheet-pager-prev"]))
    end

    test "a tall AND wide sheet shows both the page buttons and the column clip",
         %{conn: conn} do
      wide = Barkpark.Plugins.Sheets.Core.format_ref({70, 1})

      create_draft!(
        "rdr-tallwide",
        one_tab(%{"A1" => %{"v" => "x"}, "A600" => %{"v" => "deep"}, wide => %{"v" => "edge"}})
      )

      publish!("rdr-tallwide")

      {:ok, view, html} = live(conn, "/sheets/rdr-tallwide")

      assert has_element?(view, ~s([data-test-id="sheet-pager-next"]))
      assert html =~ "Showing rows 1"
      assert html =~ "first 64 of 70 columns"
    end

    test "a merge crossing the page boundary keeps the next page column-aligned", %{conn: conn} do
      # A499:A502 is a rowspan whose anchor (row 499) is on page 0. On the reader's
      # second page rows 501/502 must render plain column-A tds — before the fix
      # they were merge-skipped, so B501 slot-filled left under column A. This is
      # the published reader path: the same silent mis-labelling anonymous readers
      # would see.
      create_draft!("rdr-merge-page", [
        %{
          "name" => "Data",
          "cells" => %{"A600" => %{"v" => "deep"}, "B501" => %{"v" => "beta"}},
          "merges" => ["A499:A502"]
        }
      ])

      publish!("rdr-merge-page")

      {:ok, view, _html} = live(conn, "/sheets/rdr-merge-page")

      html = view |> element(~s([data-test-id="sheet-pager-next"])) |> render_click()

      # Column A's cell renders on row 501 (absent before the fix)…
      assert html =~ ~s(data-ref="A501" data-r="501" data-c="1")
      # …so B501's value stays in the column-B slot, not shifted left into A.
      assert html =~ ~s(data-ref="B501" data-r="501" data-c="2" data-v="beta")
    end
  end

  # ── reader find-in-sheet ──────────────────────────────────────────────────────
  # Find is PURE navigation (scan + jump, never `send_ops`), so the read-only
  # reader finds and jumps to off-page matches without ever starting a session —
  # the same reader-safe pattern as paging. The find bar is ALWAYS shown in the
  # reader (no JS hook there to Ctrl+F it open).

  describe "reader find-in-sheet" do
    test "the find bar renders on the read-only reader", %{conn: conn} do
      create_draft!("rdr-find-ui", one_tab(%{"A1" => %{"v" => "hello"}}))
      publish!("rdr-find-ui")

      {:ok, _view, html} = live(conn, "/sheets/rdr-find-ui")
      assert html =~ ~s(data-test-id="sheet-find")
      assert html =~ ~s(data-test-id="sheet-find-input")
    end

    test "find jumps to an off-page match and highlights it, no session", %{conn: conn} do
      create_draft!("rdr-find", one_tab(%{"A1" => %{"v" => "top"}, "A700" => %{"v" => "needle"}}))
      publish!("rdr-find")

      {:ok, view, html} = live(conn, "/sheets/rdr-find")
      target = with_target(view, "#sheet-reader-rdr-find")

      # The off-page match is not rendered until find pages it in.
      refute html =~ ~s(data-ref="A700")

      html = render_submit(target, "find-next", %{"q" => "needle"})
      assert html =~ ~s(data-ref="A700")
      assert view |> element(~s(td[data-ref="A700"])) |> render() =~ "sheet-find-hit"
      assert html =~ "Match 1 of 1"

      # PURE navigation — no session ever started (reader-safe).
      assert Session.whereis("rdr-find", @dataset) == nil
    end
  end
end
