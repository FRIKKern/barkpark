defmodule BarkparkWeb.SheetsCfLiveMatrixReceiptTest do
  @moduledoc """
  sp-cf-verify — the LIVE conditional-formatting matrix receipt.

  Fixture parity (`sheet-golden-parity.json`, `sheet-cond-format-eval.json`)
  proves each surface against a FROZEN document. It cannot prove the thing the
  verification task actually asks for: that ONE edit, made through the real
  Studio editing spine on ONE live sheet, propagates the SAME conditional
  formatting to every consuming surface — and unwinds again on undo.

  So this suite drives one document end to end:

    1. a `type:"sheet"` doc holding a `gt 100 → bg #ff0000` rule over `A1:A5`
       and `A1 = 42` (NOT a match);
    2. the Studio grid (`BarkparkWeb.Studio.SheetGrid`) is opened as an EDITOR
       and the real client events (`cell-click` → `edit-commit`) flip `A1` to
       `150` — a match;
    3. after each step the session is FLUSHED and the sheet PUBLISHED (the
       write-through that moves a published paper's embedded snapshot), then
       all four consuming surfaces are re-read from that ONE document:

       | surface | read under test                                              |
       |---------|--------------------------------------------------------------|
       | reader  | `/sheets/:slug` live render → `td[data-ref="A1"]` inline bg   |
       | embed   | `/papers/:slug` live render (PortableDoc `PdSheet` walk) → bg |
       | web     | `Core.snapshot_for/2` `"styles"` — the exact map the Next.js  |
       |         | `SheetSnapshot` hands `GridTable` — plus, when `web/`'s deps  |
       |         | are installed, the REAL `renderToStaticMarkup` of that        |
       |         | component over this document's snapshot                       |
       | xlsx    | `XlsxExport.to_binary/2` → the BAKED cell fill (re-imported)  |
       |         | AND the `<cfRule>`/`<dxf>` XML (#15399)                       |

    4. UNDO through the grid's real `"undo"` event → every surface must lose
       the formatting; REDO → every surface must regain it;
    5. a second test does the same round trip on the CF OPERATION itself —
       the `set_cond_format` op authored through the Cond. format panel —
       so undo/redo is demonstrated across the rule path, not only the value
       path that drives it.

  A compact `surface × before/after/undo/redo` receipt is printed to the test
  log by each test (`IO.puts`), which is what the verification row wants
  attached.

  ## Why the web leg has two halves

  The Elixir CI job does not install `web/node_modules` (see
  `.github/workflows/elixir.yml` — the Test job never runs `npm ci`). The
  UNCONDITIONAL half therefore asserts the snapshot contract the web renderer
  consumes: `SheetSnapshot` passes `snapshot.styles` straight to `GridTable`,
  which reads `styles["<bodyRow>,<col>"].bg` and emits it as
  `backgroundColor`. When the deps ARE present (any developer checkout) the
  component is transpiled and server-rendered for real, and the assertion is
  made against its HTML. `web_leg/1` reports which half ran, and the receipt
  prints it — a skipped render leg is never silently indistinguishable from a
  passing one.

  `async: false` — sheet sessions are globally registered processes, same as
  the grid/reader/presence suites.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Core
  alias Barkpark.Plugins.Sheets.Session
  alias Barkpark.Plugins.Sheets.XlsxExport
  alias Barkpark.Plugins.Sheets.XlsxImport

  @dataset "production"

  # The CF colour under test. Deliberately NOT one of the palette colours the
  # paper surface or the grid chrome paints with, so a positive read on any
  # surface can only have come from this rule.
  @bg "#ff0000"

  # The reader/Studio grid emit `background: #rrggbb` (space, `Cells.style_css/1`);
  # the PortableDoc `PdSheet` walk emits `background:#rrggbb` (no space).
  @grid_css "background: #{@bg}"
  @pd_css "background:#{@bg}"

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    put_cfg(debounce_ms: 60_000, idle_stop_ms: 60_000)
    seed_sheet_schema!()
    Barkpark.TenancyFixtures.ensure_default_scope!()
    :ok
  end

  # ── the matrix ─────────────────────────────────────────────────────────────

  test "ONE live edit propagates the CF match to reader, embed, web and xlsx — and undo/redo unwinds it on every surface",
       %{conn: conn} do
    slug = uniq("cf-matrix")
    paper = uniq("cf-matrix-paper")

    create_sheet!(slug, [
      %{
        "name" => "Data",
        "cells" => %{"A1" => %{"v" => 42}, "A6" => %{"v" => 999}},
        "cond_formats" => [
          %{
            "id" => "cf-live-1",
            "range" => "A1:A5",
            "when" => %{"op" => "gt", "value" => 100},
            "style" => %{"bg" => @bg}
          }
        ]
      }
    ])

    embed_paper!(paper, slug)

    # ── BEFORE: A1 = 42, the rule does not fire anywhere ─────────────────────
    before = probe(conn, slug, paper)

    assert before.reader == false, "reader painted A1 before any match existed"
    assert before.embed == false, "paper embed painted A1 before any match existed"
    assert before.web == false, "web snapshot carried a CF style before any match existed"
    assert before.xlsx_baked == false, "xlsx baked a CF fill before any match existed"

    # The RULE, however, is exported from the very first publish — a cfRule is
    # a rule, not a match (this is what #15399 added; before it the xlsx lost
    # the rule and kept only the pixels).
    assert before.xlsx_rule == true, "the cfRule must ride the export even with no matching cell"

    # ── the live edit: real Studio grid, real client events ──────────────────
    {view, target, _html} = open_grid!(conn, slug)

    render_hook(target, "cell-click", %{"ref" => "A1", "shift" => false})
    render_hook(target, "edit-commit", %{"value" => "150", "move" => "down"})

    # The editing surface itself paints immediately, off the session state.
    assert view |> element(~s(td[data-ref="A1"])) |> render() =~ @grid_css,
           "the Studio grid did not paint A1 after the edit"

    # A6 sits OUTSIDE the rule's range with a value that would match — proof
    # the range, not merely the predicate, is being honoured.
    refute view |> element(~s(td[data-ref="A6"])) |> render() =~ @grid_css

    after_edit = probe(conn, slug, paper)

    assert after_edit.reader, "READER did not show the CF after the live edit"
    assert after_edit.embed, "EMBED did not show the CF after the live edit"
    assert after_edit.web, "WEB did not show the CF after the live edit"
    assert after_edit.xlsx_baked, "XLSX did not bake the CF fill after the live edit"
    assert after_edit.xlsx_rule, "XLSX lost the cfRule after the live edit"

    # ── UNDO through the grid's real undo event ──────────────────────────────
    render_hook(target, "undo", %{})
    assert peek_cell(slug, "A1")["v"] == 42, "undo did not restore the prior cell value"

    refute view |> element(~s(td[data-ref="A1"])) |> render() =~ @grid_css

    undone = probe(conn, slug, paper)

    assert undone.reader == false, "READER kept the CF after undo"
    assert undone.embed == false, "EMBED kept the CF after undo"
    assert undone.web == false, "WEB kept the CF after undo"
    assert undone.xlsx_baked == false, "XLSX kept the baked CF fill after undo"
    assert undone.xlsx_rule, "undo of a CELL edit must not remove the rule itself"

    # ── REDO ─────────────────────────────────────────────────────────────────
    render_hook(target, "redo", %{})
    assert peek_cell(slug, "A1")["v"] == 150, "redo did not re-apply the edit"

    redone = probe(conn, slug, paper)

    assert redone.reader, "READER did not regain the CF after redo"
    assert redone.embed, "EMBED did not regain the CF after redo"
    assert redone.web, "WEB did not regain the CF after redo"
    assert redone.xlsx_baked, "XLSX did not re-bake the CF fill after redo"
    assert redone.xlsx_rule

    receipt("live cell edit (A1: 42 → 150, rule gt 100 over A1:A5)", [
      {"before", before},
      {"after", after_edit},
      {"undo", undone},
      {"redo", redone}
    ])
  end

  test "undo/redo across the CF OPERATION path — a panel-authored set_cond_format round-trips on every surface",
       %{conn: conn} do
    slug = uniq("cf-op-matrix")
    paper = uniq("cf-op-matrix-paper")

    # The VALUE already matches; only the RULE is missing, so every surface's
    # answer is a pure function of the set_cond_format op.
    create_sheet!(slug, [%{"name" => "Data", "cells" => %{"A1" => %{"v" => 150}}}])
    embed_paper!(paper, slug)

    before = probe(conn, slug, paper)
    assert before.reader == false
    assert before.embed == false
    assert before.web == false
    assert before.xlsx_baked == false
    assert before.xlsx_rule == false, "there is no rule yet — nothing to export"

    {view, target, _html} = open_grid!(conn, slug)

    render_hook(target, "cell-click", %{"ref" => "A1", "shift" => false})
    view |> element(~s([data-test-id="sheet-cf-btn"])) |> render_click()

    view
    |> element(~s([data-test-id="sheet-cf-form"]))
    |> render_submit(%{
      "editing" => "",
      "range" => "A1:A5",
      "op" => "gt",
      "value" => "100",
      "bg" => @bg
    })

    assert [%{"range" => "A1:A5", "style" => %{"bg" => @bg}}] = peek_cond_formats(slug)

    after_rule = probe(conn, slug, paper)
    assert after_rule.reader, "READER did not show the panel-authored rule"
    assert after_rule.embed, "EMBED did not show the panel-authored rule"
    assert after_rule.web, "WEB did not show the panel-authored rule"
    assert after_rule.xlsx_baked, "XLSX did not bake the panel-authored rule"
    assert after_rule.xlsx_rule, "XLSX did not export the panel-authored cfRule"

    render_hook(target, "undo", %{})
    assert peek_cond_formats(slug) == [], "undo did not remove the rule"

    undone = probe(conn, slug, paper)
    assert undone.reader == false, "READER kept the CF after the rule was undone"
    assert undone.embed == false, "EMBED kept the CF after the rule was undone"
    assert undone.web == false, "WEB kept the CF after the rule was undone"
    assert undone.xlsx_baked == false, "XLSX kept the baked fill after the rule was undone"
    assert undone.xlsx_rule == false, "XLSX kept the cfRule after the rule was undone"

    render_hook(target, "redo", %{})
    assert [%{"range" => "A1:A5"}] = peek_cond_formats(slug)

    redone = probe(conn, slug, paper)
    assert redone.reader, "READER did not regain the CF after redo"
    assert redone.embed, "EMBED did not regain the CF after redo"
    assert redone.web, "WEB did not regain the CF after redo"
    assert redone.xlsx_baked, "XLSX did not re-bake after redo"
    assert redone.xlsx_rule, "XLSX did not re-export the cfRule after redo"

    receipt("set_cond_format op (rule gt 100 over A1:A5, A1 = 150 throughout)", [
      {"before", before},
      {"after", after_rule},
      {"undo", undone},
      {"redo", redone}
    ])
  end

  # ── the four surface probes ────────────────────────────────────────────────

  # Persist the live session, publish (the write-through that refreshes a
  # published paper's embedded snapshot), then read all four surfaces off that
  # ONE document.
  defp probe(conn, slug, paper) do
    :ok = Session.flush(slug, @dataset)
    {:ok, _} = Content.publish_document(slug, "sheet", @dataset)

    content = published_content(slug)
    snapshot = Core.snapshot_for(content, 0)
    {web?, web_via} = web_leg(snapshot)

    %{
      reader: reader_leg(conn, slug),
      embed: embed_leg(conn, paper),
      web: web?,
      web_via: web_via,
      xlsx_baked: xlsx_baked_leg(content),
      xlsx_rule: xlsx_rule_leg(content)
    }
  end

  # READER — the public `/sheets/:slug` LiveView, anonymous, published-only.
  defp reader_leg(conn, slug) do
    {:ok, view, _html} = live(conn, "/sheets/#{slug}")
    view |> element(~s(td[data-ref="A1"])) |> render() =~ @grid_css
  end

  # EMBED — the published paper's `"sheet"` block, rendered by the PortableDoc
  # `PdSheet` walk into the Bulldocs reader.
  defp embed_leg(conn, paper) do
    {:ok, _view, html} = live(conn, "/papers/#{paper}")
    html =~ @pd_css
  end

  # WEB — the snapshot contract `SheetSnapshot` → `GridTable` consumes, plus the
  # real component render when web/'s deps are installed. Returns
  # `{shows_cf?, "how"}`; the two halves must AGREE when both run.
  defp web_leg(snapshot) do
    contract? = get_in(snapshot, ["styles", "0,0", "bg"]) == @bg

    case web_render_html(snapshot) do
      {:ok, html} ->
        rendered? = html =~ "background-color:#{@bg}"

        assert rendered? == contract?,
               "web snapshot contract says #{contract?} but the real SheetSnapshot " <>
                 "render says #{rendered?} — the web renderer and the server snapshot disagree"

        {rendered?, "snapshot contract + real SheetSnapshot render"}

      :unavailable ->
        {contract?, "snapshot contract only (web/node_modules absent)"}
    end
  end

  # XLSX (baked) — export, re-import, read the cell's composed style back. This
  # is the fill a spreadsheet shows with conditional formatting switched off.
  defp xlsx_baked_leg(content) do
    {:ok, binary} = XlsxExport.to_binary(content)
    {:ok, imported} = XlsxImport.to_content(binary)
    get_in(imported, ["tabs", Access.at(0), "cells", "A1", "s", "bg"]) == @bg
  end

  # XLSX (rule) — the `<cfRule>` + its `<dxf>` fill, i.e. a LIVE rule in Excel
  # rather than baked pixels (#15399). Both must be present, and the dxf must
  # carry this rule's colour.
  defp xlsx_rule_leg(content) do
    {:ok, binary} = XlsxExport.to_binary(content)
    sheet = member(binary, "xl/worksheets/sheet1.xml")
    styles = member(binary, "xl/styles.xml")

    sheet =~ ~s(<conditionalFormatting sqref="A1:A5">) and
      sheet =~ ~s(operator="greaterThan") and
      sheet =~ "<formula>100</formula>" and
      styles =~ ~s(<bgColor rgb="FFFF0000"/>)
  end

  defp member(binary, name) do
    {:ok, entries} = :zip.extract(binary, [:memory])
    wanted = String.to_charlist(name)

    case Enum.find(entries, fn {n, _} -> n == wanted end) do
      {_, content} -> to_string(content)
      nil -> ""
    end
  end

  # ── the real web render (optional leg) ─────────────────────────────────────

  @web_dir Path.expand("../../../../web", __DIR__)

  # Transpile `components/sheet-grid.tsx` with the repo's own TypeScript, import
  # it, and `renderToStaticMarkup` `SheetSnapshot` over this document's
  # snapshot — the same recipe `web/__tests__/sheet-grid-render.test.ts` uses,
  # because node's test runner strips types but cannot parse JSX.
  #
  # `:unavailable` (never a silent pass) when node or web/node_modules is
  # missing, which is the state of the Elixir CI job.
  defp web_render_html(snapshot) do
    node = System.find_executable("node")

    cond do
      is_nil(node) ->
        :unavailable

      not File.dir?(Path.join([@web_dir, "node_modules", "react-dom"])) ->
        :unavailable

      not File.dir?(Path.join([@web_dir, "node_modules", "typescript"])) ->
        :unavailable

      true ->
        run_web_render(node, snapshot)
    end
  end

  defp run_web_render(node, snapshot) do
    tag = System.unique_integer([:positive, :monotonic])
    runner = Path.join([@web_dir, "components", ".cf-matrix-runner-#{tag}.mjs"])
    snap_path = Path.join(System.tmp_dir!(), "cf-matrix-snapshot-#{tag}.json")

    File.write!(runner, web_runner_source())
    File.write!(snap_path, Jason.encode!(snapshot))

    try do
      case System.cmd(node, [runner, @web_dir, snap_path], stderr_to_stdout: true, cd: @web_dir) do
        {out, 0} ->
          {:ok, out}

        {out, code} ->
          flunk("the web SheetSnapshot render failed (exit #{code}):\n#{out}")
      end
    after
      File.rm(runner)
      File.rm(snap_path)
    end
  end

  # Kept as a raw heredoc (`~S`) so the JS regex escapes survive verbatim.
  defp web_runner_source do
    ~S"""
    // Generated by api/test/barkpark_web/live/sheets_cf_live_matrix_receipt_test.exs
    // and deleted by it. Lives inside web/components/ so `react/jsx-runtime`
    // and `@/lib/*` resolve exactly as they do for the real component.
    import { readFileSync, writeFileSync, unlinkSync } from "node:fs";
    import { pathToFileURL } from "node:url";
    import path from "node:path";
    import ts from "typescript";
    import { createElement } from "react";
    import { renderToStaticMarkup } from "react-dom/server";

    const webDir = process.argv[2];
    const snapPath = process.argv[3];
    const componentsDir = path.join(webDir, "components");
    const libUrl = pathToFileURL(path.join(webDir, "lib") + path.sep).href;

    const source = readFileSync(path.join(componentsDir, "sheet-grid.tsx"), "utf8");
    const transpiled = ts.transpileModule(source, {
      compilerOptions: {
        jsx: ts.JsxEmit.ReactJSX,
        module: ts.ModuleKind.ESNext,
        target: ts.ScriptTarget.ES2022,
        verbatimModuleSyntax: false,
      },
    }).outputText;

    const rewritten = transpiled.replace(
      /(["'])@\/lib\/([^"']+)\1/g,
      (_m, _q, mod) => JSON.stringify(libUrl + mod + ".ts"),
    );

    const tmp = path.join(componentsDir, `.cf-matrix-mod-${process.pid}.mjs`);
    writeFileSync(tmp, rewritten);

    try {
      const mod = await import(pathToFileURL(tmp).href);
      if (typeof mod.SheetSnapshot !== "function") {
        throw new Error("sheet-grid.tsx no longer exports SheetSnapshot");
      }
      const snapshot = JSON.parse(readFileSync(snapPath, "utf8"));
      process.stdout.write(
        renderToStaticMarkup(createElement(mod.SheetSnapshot, { snapshot })),
      );
    } finally {
      try {
        unlinkSync(tmp);
      } catch {
        /* already gone */
      }
    }
    """
  end

  # ── fixtures + plumbing ────────────────────────────────────────────────────

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp create_sheet!(slug, tabs) do
    {:ok, doc} =
      Content.create_document(
        "sheet",
        %{"doc_id" => slug, "content" => %{"locale" => "nb-NO", "tabs" => tabs}},
        @dataset
      )

    doc
  end

  # A published paper carrying a `"sheet"` block pointed at this sheet — the
  # embed surface. Ingest hydrates the block's snapshot immediately (M0a); each
  # later PUBLISH of the sheet refreshes it through the write-through.
  defp embed_paper!(paper_slug, sheet_slug) do
    {:ok, doc} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: paper_slug,
          blocks: [
            %{
              "id" => "s1",
              "type" => "sheet",
              "ref" => Content.published_id(sheet_slug),
              "tab" => 0
            }
          ]
        })
      )

    doc
  end

  defp open_grid!(conn, slug) do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/#{slug}"))
    {view, with_target(view, "#sheet-grid-#{slug}"), html}
  end

  defp published_content(slug) do
    assert {:ok, doc} = Content.get_document(Content.published_id(slug), "sheet", @dataset),
           "the sheet did not publish — no published row for #{slug}"

    assert doc.status == "published"
    doc.content
  end

  defp peek_cell(slug, ref) do
    {:ok, content} = Session.peek(slug, @dataset)
    get_in(content, ["tabs", Access.at(0), "cells", ref]) || %{}
  end

  defp peek_cond_formats(slug) do
    {:ok, content} = Session.peek(slug, @dataset)
    get_in(content, ["tabs", Access.at(0), "cond_formats"]) || []
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

  # ── the receipt ────────────────────────────────────────────────────────────

  @rows [
    {"reader   (/sheets/:slug)", :reader},
    {"embed    (/papers/:slug)", :embed},
    {"web      (SheetSnapshot)", :web},
    {"xlsx     (baked cell fill)", :xlsx_baked},
    {"xlsx     (<cfRule> + <dxf>)", :xlsx_rule}
  ]

  defp receipt(title, phases) do
    header =
      String.pad_trailing("surface", 28) <>
        Enum.map_join(phases, "", fn {name, _} -> String.pad_trailing(name, 8) end)

    body =
      Enum.map_join(@rows, "\n", fn {label, key} ->
        String.pad_trailing(label, 28) <>
          Enum.map_join(phases, "", fn {_, p} ->
            String.pad_trailing(if(Map.fetch!(p, key), do: "CF", else: "—"), 8)
          end)
      end)

    {_, first} = hd(phases)

    IO.puts("""

    ── CF live matrix — #{title} ──
    #{header}
    #{body}

    web leg: #{first.web_via}
    """)
  end
end
