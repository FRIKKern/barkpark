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
  (`send_ops` guards on `write_capable`, so no session ever starts), and the
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

  test "read-only cells carry NO aria-selected and the wrapper is a labelled region",
       %{conn: conn} do
    create_draft!("rdr-sel-a11y", one_tab(%{"A1" => %{"v" => "x"}}))
    publish!("rdr-sel-a11y")

    {:ok, view, html} = live(conn, "/sheets/rdr-sel-a11y")

    # There is no selection in a read-only view, so stamping
    # aria-selected="false" on every cell was noise: not one td carries the
    # attribute now (the tab strip's role=tab buttons legitimately keep
    # theirs, hence the td-scoped checks).
    refute view |> element(~s(td[data-ref="A1"])) |> render() =~ "aria-selected"
    refute Regex.match?(~r/<td[^>]*aria-selected/, html)

    # WCAG 4.1.2: the wrapper's aria-label needs a real role to land on in
    # read-only mode — region (role=application stays edit-only).
    wrap = view |> element("#sheet-reader-rdr-sel-a11y-grid-view") |> render()
    assert wrap =~ ~s(role="region")
    assert wrap =~ ~s(aria-label="Spreadsheet grid")
    refute html =~ ~s(role="application")
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
    # Formula-UX payloads are editing affordances too: the function vocabulary
    # (data-fns) and the ~25KB signature index (data-fn-sigs) are gated on
    # @editable and must never ship to the anonymous reader.
    refute html =~ "data-fns="
    refute html =~ "data-fn-sigs="

    # The read-only tab switcher works.
    assert html =~ ~s(phx-click="tab-switch")
    assert html =~ ~s(data-v="tab-one")
    refute html =~ ~s(data-v="tab-two")

    view |> element(~s([data-test-id="sheet-tab-1"])) |> render_click()
    assert render(view) =~ ~s(data-v="tab-two")
  end

  # ── reader selection: CLIENT-ONLY (pds-w43-bl-sheetgrid-reader-half) ────────
  #
  # Main ruled on 2026-09-02 10:52Z: "(b): client-only selection + copy layer in
  # bp-sheet-grid.js for :reader — paints its own class, pushes ZERO events,
  # reads data-v already on reader tds. An anonymous principal never round-trips
  # selection and gains no authority. […] (a) rejected: it widens the server
  # surface for a purely local affordance."
  #
  # This test is the SERVER half of that ruling, and its job is as much to pin
  # what did NOT change as what did: the reader gains one attribute
  # (phx-hook="SheetReaderSelect") and not one server event, not one phx-click,
  # not one selection class. The client half — the selection rect, the TSV, and
  # the empty push list — is pinned in api/assets/sheet-grid/__hook.test.mjs.
  test "the reader grid carries the client-only selection hook and NO new server surface",
       %{conn: conn} do
    create_draft!("rdr-sel-hook", one_tab(%{"A1" => %{"v" => "pick"}, "B2" => %{"v" => "me"}}))
    publish!("rdr-sel-hook")

    {:ok, _view, html} = live(conn, "/sheets/rdr-sel-hook")

    # THE ONE ADDITION: the reader's own, much smaller hook.
    assert html =~ ~s(phx-hook="SheetReaderSelect")
    # The Studio hook is still absent — its events (cell-click / nav / select-all)
    # are exactly the server round-trip the ruling refused.
    refute html =~ ~s(phx-hook="SheetGrid")

    # The layout has to register the hook and ship the file, or the attribute is
    # inert. Both live in the reader's own root layout (sheets.html.heex).
    assert html =~ ~s(src="/assets/bp-sheet-grid.js")
    assert html =~ "Hooks.SheetReaderSelect = window.BarkparkSheetReaderSelect"
    # …and the class it paints has a rule to paint WITH. `sheet-rsel`, never the
    # Studio's `sheet-sel` — aliasing would make the grid harness's td.sheet-sel
    # pins ambiguous about which grid produced the highlight.
    assert html =~ ".sheet-cell.sheet-rsel"

    # SERVER SURFACE UNCHANGED. No cell is clickable, no navigation/selection
    # event name is reachable from the anonymous reader's markup, and no <td>
    # carries a server-painted selection (grid_sel(_, _, :reader) is {0,0,0,0}).
    refute Regex.match?(~r/<td[^>]*phx-click/, html)
    refute html =~ ~s(phx-click="cell-click")
    refute html =~ ~s(phx-click="head-click")
    refute html =~ "nav-edge"
    refute html =~ "nav-corner"
    refute html =~ "select-all"
    # td-SCOPED, not a whole-document refute: the reader layout's inline
    # stylesheet is part of this html, and its comment names `sheet-sel` while
    # explaining why the reader class is not it.
    refute Regex.match?(~r/<td[^>]*\bsheet-sel\b/, html)
    refute Regex.match?(~r/<td[^>]*aria-selected/, html)

    # A11y contract held: role="application" stays edit-only (it muted AT
    # table-navigation here — see "grid a11y semantics" above), and the server
    # still stamps no aria-activedescendant. The hook sets that client-side.
    refute html =~ ~s(role="application")
    assert html =~ ~s(role="region")
    assert html =~ ~s(aria-readonly="true")
    refute html =~ "aria-activedescendant"

    # The data the client layer copies from is the data already on the page.
    assert html =~ ~s(data-v="pick")
    assert html =~ ~s(data-v="me")
  end

  test "an http(s) URL cell renders a safe anchor; a javascript: value stays plain text",
       %{conn: conn} do
    create_draft!(
      "rdr-link",
      one_tab(%{
        "A1" => %{"v" => "https://example.com/x"},
        "A2" => %{"v" => "javascript:alert(1)"},
        "A3" => %{"v" => "see http://example.com"}
      })
    )

    publish!("rdr-link")

    {:ok, _view, html} = live(conn, "/sheets/rdr-link")

    # The whole-string URL becomes an anchor through the read-only grid.
    assert html =~ "<a class=\"sheet-cell-v sheet-link\" href=\"https://example.com/x\""
    assert html =~ "rel=\"noopener noreferrer nofollow\""
    # The javascript: payload and the partial-URL cell never link.
    refute html =~ "href=\"javascript:"
    refute html =~ "<a class=\"sheet-cell-v sheet-link\" href=\"see http://example.com\""
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

  # SF-AM4: the per-column filter funnel is a READ affordance, so the reader
  # carries it too — a viewer can filter their own view while the published
  # document (and every other viewer) is untouched. SORT never appears: it is
  # an edit mutation (SF-AM2d) with no affordance in any read-only render.
  test "the reader carries the funnel and filters this socket's rows; the doc is untouched",
       %{conn: conn} do
    create_draft!(
      "rdr-filter",
      one_tab(%{"A1" => %{"v" => 5}, "A2" => %{"v" => 1}, "A3" => %{"v" => 9}})
    )

    publish!("rdr-filter")

    {:ok, view, html} = live(conn, "/sheets/rdr-filter")
    target = with_target(view, "#sheet-reader-rdr-filter")

    # The funnel is present; NO sort control is (buttons live in the editable
    # toolbar, the sort items in the editable column ▾ menu — both stripped).
    assert html =~ ~s(data-test-id="sheet-filter-funnel-1")
    refute html =~ ~s(data-test-id="sheet-sort-asc")
    refute html =~ ~s(data-test-id="sheet-sort-desc")
    refute html =~ "sort-selection"
    refute html =~ "sort-column"
    refute html =~ "Sort A→Z"

    # Filtering hides rows for THIS socket.
    render_click(target, "filter-open", %{"col" => "1"})

    html =
      view
      |> element(~s([data-test-id="sheet-filter-form"]))
      |> render_submit(%{"col" => "1", "op" => "gt", "value" => "3"})

    # A1 (5) and A3 (9) pass gt 3; A2 (1) is hidden for this viewer.
    assert html =~ ~s(data-ref="A1")
    assert html =~ ~s(data-ref="A3")
    refute html =~ ~s(data-ref="A2")
    assert html =~ "rows hidden by filter"

    # Pure view-state (SF-D2): NO session started, so the stored document is
    # untouched — a cold reload sees every row, including the "hidden" one.
    assert Session.whereis("rdr-filter", @dataset) == nil
    {:ok, _view2, html2} = live(conn, "/sheets/rdr-filter")
    assert html2 =~ ~s(data-ref="A2")
  end

  test "a forged sort event is dropped read-only — no session, published order holds",
       %{conn: conn} do
    create_draft!(
      "rdr-sort-forge",
      one_tab(%{"A1" => %{"v" => 3}, "A2" => %{"v" => 1}, "A3" => %{"v" => 2}})
    )

    publish!("rdr-sort-forge")

    {:ok, view, _html} = live(conn, "/sheets/rdr-sort-forge")
    target = with_target(view, "#sheet-reader-rdr-sort-forge")

    # A crafted client could still push these despite the stripped markup: the
    # capability/chrome guard clauses no-op them, and send_ops would drop them anyway.
    render_hook(target, "sort-selection", %{"dir" => "asc"})
    render_hook(target, "sort-column", %{"col" => "1", "dir" => "asc"})

    # No session started (a sort op would have), so nothing was permuted — the
    # published top row still shows the original unsorted value 3, not 1.
    assert Session.whereis("rdr-sort-forge", @dataset) == nil
    assert view |> element(~s(td[data-ref="A1"])) |> render() =~ ~s(data-v="3")
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

      # The static <head> carries the unfurl meta via the shared ShareMeta
      # emitter (preview-contract pc-w2): og:title is the bare manifest title
      # (og:site_name carries "Barkpark"); the site suffix lives on the <title>.
      resp = conn |> get("/sheets/rdr-chrome") |> html_response(200)
      assert resp =~ ~s(<meta property="og:title" content="Quarterly Numbers")
      assert resp =~ "Quarterly Numbers · Barkpark</title>"
      assert resp =~ ~s(<meta property="og:type" content="website")
      assert resp =~ ~s(<meta name="twitter:card" content="summary_large_image")
    end

    test "an untitled sheet falls back to the slug in the page title", %{conn: conn} do
      create_draft!("rdr-untitled", one_tab(%{"A1" => %{"v" => "x"}}))
      publish!("rdr-untitled")

      {:ok, view, _html} = live(conn, "/sheets/rdr-untitled")
      assert page_title(view) == "rdr-untitled · Barkpark"
    end

    test "the reader layout ships the print + mobile stylesheets and styles every emitted sheet-* class",
         %{conn: conn} do
      # Tall enough to page (>500 rows) plus link/number/error cells: the
      # read-only render walks its full chrome — pager, find bar, tabs, and
      # the cell variant classes.
      create_draft!(
        "rdr-css",
        one_tab(%{
          "A1" => %{"v" => "x"},
          "B1" => %{"v" => 42},
          "C1" => %{"v" => "https://example.com/x"},
          "D1" => %{"f" => "1/0", "v" => "#DIV/0!", "t" => "e"},
          "A600" => %{"v" => "deep"}
        })
      )

      publish!("rdr-css")

      # The layout's inline stylesheet only ships on the static GET (the live
      # socket render carries no <head>).
      resp = conn |> get("/sheets/rdr-css") |> html_response(200)
      assert resp =~ "@media print"
      assert resp =~ "max-width: 640px"
      assert [_, css] = Regex.run(~r{<style>(.*?)</style>}s, resp)

      {:ok, view, _html} = live(conn, "/sheets/rdr-css")

      # Surface the error-notice state: a forged single-cell merge is
      # rejected assign-only ("select at least two cells to merge") — no
      # session, the same reader-safe path the forgery suite locks.
      target = with_target(view, "#sheet-reader-rdr-css")
      render_hook(target, "merge-selection", %{})
      html = render(view)
      assert html =~ ~s(data-test-id="sheet-notice")
      assert html =~ ~s(data-test-id="sheet-pager")
      assert Session.whereis("rdr-css", @dataset) == nil

      # GENERIC tripwire: every sheet-* class the reader actually emits must
      # appear as a selector in the layout CSS. Derived from the rendered
      # HTML, not a hardcoded list — a class added to the shared grid render
      # without a matching reader rule fails here by construction.
      emitted =
        ~r/class="([^"]*)"/
        |> Regex.scan(html)
        |> Enum.flat_map(fn [_, classes] -> String.split(classes) end)
        |> Enum.filter(&String.starts_with?(&1, "sheet-"))
        |> Enum.uniq()
        |> Enum.sort()

      # Vacuity guard: the paged + noticed render emits the full chrome.
      for required <-
            ~w(sheet-pager sheet-notice sheet-find-input sheet-table sheet-cell sheet-err) do
        assert required in emitted, "expected the render to emit .#{required}"
      end

      missing =
        Enum.reject(emitted, fn class ->
          Regex.match?(~r/\.#{Regex.escape(class)}(?![\w-])/, css)
        end)

      assert missing == [],
             "reader layout CSS has no selector for emitted class(es): #{inspect(missing)}"

      # The pager/find/notice buttons ride the shared .btn chrome — those
      # selectors are not sheet-* prefixed, so gate them explicitly.
      assert html =~ "btn btn-ghost btn-sm"

      for selector <- [".btn ", ".btn-ghost ", ".btn-sm "] do
        assert css =~ selector, "reader layout CSS is missing #{String.trim(selector)}"
      end

      # Dead-rule guard: nothing emits sheet-cap-notice anymore.
      refute css =~ ".sheet-cap-notice"
    end

    # The unsupported-function ruling (2026-09-02), end to end through the
    # save-time recompute and the shared read-only grid render. BOTH arms:
    # a typed =FOO(1) with nothing cached becomes #NAME? and reads as an error
    # cell; an imported cell that KEPT its cached value keeps rendering that
    # value but error-styled and titled — never a quiet orange dot.
    test "an unsupported function reads as #NAME?, and a kept import reads loud",
         %{conn: conn} do
      create_draft!(
        "rdr-name",
        one_tab(%{
          "A1" => %{"f" => "=FOO(1)"},
          "B1" => %{"f" => "=A1+1"},
          "C1" => %{"f" => "=FOO(1)", "v" => 42, "t" => "n"}
        })
      )

      publish!("rdr-name")

      {:ok, view, _html} = live(conn, "/sheets/rdr-name")
      html = render(view)

      # Arm 1 — nothing cached: the error VALUE is on screen and propagates.
      assert html =~ "#NAME?"
      assert html =~ "sheet-err"

      # Arm 2 — the imported value survives, and says why it is not live.
      assert html =~ "not evaluated: FOO is not supported"
      assert html =~ "42"
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

  # ── field-visibility seal (fail-closed) ─────────────────────────────────────
  # The anonymous public reader serializes `doc.content` into SheetGrid. Once a
  # sheet schema field declares per-field visibility, an anonymous visitor must
  # NOT see it. The reader seals the content through the canonical Envelope
  # chokepoint under the ANONYMOUS caller (mirroring the public paper reader).
  # The only content the reader surfaces is the grid ("tabs"), so the
  # MUTATION-PROOF marks "tabs" private and asserts the cell value is redacted:
  # it FAILS against the pre-seal reader (raw content → cell present) and PASSES
  # after (schema-declared-private "tabs" dropped → cell gone).
  describe "field-visibility seal" do
    setup do
      {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
      %{scope: [workspace_id: ws.id, project_id: project.id]}
    end

    defp declare_sheet_field!(field, scope) do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "sheet", "title" => "Sheet", "fields" => [field]},
          @dataset,
          scope
        )

      :ok
    end

    test "a schema-declared-private grid field is redacted from the anonymous reader",
         %{conn: conn, scope: scope} do
      create_draft!("rdr-seal-priv", one_tab(%{"A1" => %{"v" => "topsecretcell"}}))
      publish!("rdr-seal-priv")

      # The grid-bearing content field is private → the anonymous reader must
      # not render its cells.
      declare_sheet_field!(%{"name" => "tabs", "private" => true}, scope)

      {:ok, _view, html} = live(conn, "/sheets/rdr-seal-priv")

      refute html =~ ~s(data-v="topsecretcell"),
             "a private grid field leaked to the anonymous sheet reader"
    end

    test "with no visibility declared the seal is a byte-identical no-op (cells still render)",
         %{conn: conn, scope: scope} do
      create_draft!("rdr-seal-public", one_tab(%{"A1" => %{"v" => "topsecretcell"}}))
      publish!("rdr-seal-public")

      # Same field, NO visibility flag → the seal drops nothing (latent no-op),
      # proving the redaction is schema-driven, not a blanket strip.
      declare_sheet_field!(%{"name" => "tabs"}, scope)

      {:ok, _view, html} = live(conn, "/sheets/rdr-seal-public")

      assert html =~ ~s(data-v="topsecretcell")
    end
  end

  # preview-contract pc-w2: the sheet reader emits the shared social-share head
  # (og/twitter) from the sheet's preview manifest, in the DEAD render (crawlers
  # + unfurlers run no JS). A sheet's raw type maps to og:type=website (D8) —
  # no JSON-LD Article.
  describe "social-share head (og/twitter)" do
    test "the dead render carries the og/twitter head for a sheet", %{conn: conn} do
      create_draft!("rdr-share", one_tab(%{"A1" => %{"v" => "hi"}}), %{
        "title" => "Q3 Revenue Model"
      })

      publish!("rdr-share")

      conn = get(conn, "/sheets/rdr-share")
      html = html_response(conn, 200)
      base = BarkparkWeb.Endpoint.url()

      assert html =~ ~s(<meta property="og:site_name" content="Barkpark")
      assert html =~ ~s(<meta property="og:title" content="Q3 Revenue Model")
      # D8 — a sheet is a website, not an article.
      assert html =~ ~s(<meta property="og:type" content="website")
      assert html =~ ~s(<meta property="og:url" content="#{base}/sheets/rdr-share")
      # Branded default card (D5) + name= twitter discipline.
      assert html =~ ~s(<meta property="og:image" content="#{base}/images/og-default.jpg")
      assert html =~ ~s(<meta name="twitter:card" content="summary_large_image")

      # A sheet emits no JSON-LD Article, and none of the retired hand-rolled
      # canned og:title-with-suffix survives (the shared emitter owns og now).
      refute html =~ "application/ld+json"
      refute html =~ ~s(content="Q3 Revenue Model · Barkpark")

      # The <title> still carries the site suffix (via <.live_title>).
      assert html =~ "Q3 Revenue Model · Barkpark</title>"
    end
  end
end
