defmodule Barkpark.SheetsM3M5ProofTest do
  @moduledoc """
  Independent end-to-end proof of the Sheets M3 (formula engine) + M5
  (conversion) pipeline, driven entirely over HTTP — no direct `Content`,
  `Engine` or converter calls anywhere in the flow.

  The story: a Norwegian sales workbook built in-test with elixlsx — "Salg"
  (merged title band A1:D1, a label row, four product rows with a
  `=qty*price` column, a SUM total row, one bold + one bg-colored cell,
  column widths, a date column) and "Notater" (sparse text). Every formula
  cell in the file carries a deliberately WRONG cached value, so the correct
  numbers can only reach storage if the engine recomputes on the import save.

    1. `POST /v1/plugins/sheets/import` — the stored doc carries the
       recomputed values, never the file's lies.
    2. A paper embeds tab 0 — the ingest hydrates the snapshot immediately
       (M0a); re-uploading the same file then PUBLISHING the sheet fires the
       embed write-through, and `GET /papers/:slug` renders the computed
       total, the merged title (colspan) and the styled cells in the HTML grid.
    3. One qty cell mutates via `/v1/data/mutate` on the DRAFT; the PUBLISHED
       paper stays frozen until the sheet is published again — then the
       dependent product total AND the SUM grand total update in the
       re-fetched page.
    4. `GET export.xlsx` → re-import under a new slug → cell-level equality
       of values / formulas / fmt / merges / col widths (true round trip).
    5. `export.csv` + `export.md` spot-checks (RFC-4180 quoting, computed
       values); a BOM'd CSV with quoted commas parses correctly on import.
    6. Hostile inputs: the 50_001-cell cap names the true count, garbage
       bytes under .xlsx are a clean 422, an A1:ZZZ1000 merge clamps to the
       occupied bounds (and exports fast), and a cell at ZZZZZ9 is rejected
       by the write gate.

  Deliberately overlaps zero fixtures with the builders' tests — same
  contract, fresh data, all on the wire.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Elixlsx.{Sheet, Workbook}

  # Papers resolve publicly only in dataset "production" (Content's
  # @paper_default_dataset) and the import route defaults there too — the
  # write-through targets same-scope embeds only.
  @dataset "production"
  @slug "salgsrapport-juni-proof"
  @rt_slug "salgsrapport-juni-proof-rt"
  @paper_slug "sheets-m3-m5-proof-paper"
  @import_path "/v1/plugins/sheets/import"

  @write_token "sheets-m3-m5-proof-write-token"
  # Fixed ingest secret from config/test.exs.
  @ingest_token "barkpark-test-ingest-token"

  # Publish-wall labels (charter D26/D39): the ingest enforces the wall, so the
  # POST must carry registered weighted tags + a description.
  @wall_tag_names ~w(m3m5-proof-sales m3m5-proof-import m3m5-proof-roundtrip)
  @wall_tags [
    %{
      "tag" => "m3m5-proof-sales",
      "strength" => 93,
      "rationale" => "Primary label: the sales-report import proof paper."
    },
    %{
      "tag" => "m3m5-proof-import",
      "strength" => 58,
      "rationale" => "Secondary label: import-recompute embed coverage."
    },
    %{
      "tag" => "m3m5-proof-roundtrip",
      "strength" => 21,
      "rationale" => "Tertiary label: export round-trip ingest fixture."
    }
  ]
  @wall_description "M3+M5 proof fixture paper embedding an imported live sales sheet."

  setup do
    Barkpark.TenancyFixtures.ensure_default_scope!()
    Barkpark.LabelFixtures.register_tags!(@dataset, @wall_tag_names)
    Barkpark.Auth.create_token(@write_token, "m3-m5-proof", @dataset, ["read", "write"])
    :ok
  end

  # ── HTTP helpers ─────────────────────────────────────────────────────────────

  defp ingest_authed(conn), do: put_req_header(conn, "authorization", "Bearer " <> @ingest_token)
  defp write_authed(conn), do: put_req_header(conn, "authorization", "Bearer " <> @write_token)

  defp import_upload(tmp_dir, filename, binary, params) do
    path = Path.join(tmp_dir, filename)
    File.write!(path, binary)

    upload = %Plug.Upload{
      path: path,
      filename: filename,
      content_type: "application/octet-stream"
    }

    scoped_conn()
    |> ingest_authed()
    |> post(@import_path, Map.put(params, "file", upload))
  end

  defp fetch_sheet(doc_id) do
    scoped_conn()
    |> write_authed()
    |> get("/v1/data/doc/#{@dataset}/sheet/#{doc_id}")
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp mutate(mutations) do
    scoped_conn()
    |> write_authed()
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp ingest_paper(body) do
    scoped_conn()
    |> ingest_authed()
    |> put_req_header("content-type", "application/json")
    |> post("/v1/plugins/bulldocs/papers", Jason.encode!(body))
  end

  defp read_paper do
    scoped_conn() |> get("/papers/#{@paper_slug}") |> html_response(200)
  end

  defp export(slug, ext, query \\ "") do
    scoped_conn() |> ingest_authed() |> get("/v1/plugins/sheets/#{slug}/export.#{ext}#{query}")
  end

  # ── the workbook ─────────────────────────────────────────────────────────────

  # EVERY formula cell carries a deliberately WRONG cached value (1.0 … 4.0,
  # 9999.0). The only way the correct numbers (1998.0 / 1490 / 1798 / 177,
  # total 5463.0) can reach storage is the engine recomputing on the save.
  defp fixture_xlsx do
    salg = %Sheet{
      name: "Salg",
      rows: [
        [["Salgsrapport juni 2026", bold: true]],
        ["Produkt", "Antall", "Stykkpris", "Sum", "Dato"],
        ["Hundeseng", 4, 499.5, {:formula, "B3*C3", value: 1.0}, date_cell({2026, 6, 1})],
        ["Kobbel, kort", 10, 149, {:formula, "B4*C4", value: 2.0}, date_cell({2026, 6, 2})],
        ["Bjeffedemper", 2, 899, {:formula, "B5*C5", value: 3.0}, date_cell({2026, 6, 3})],
        ["Gnagbein", 3, 59, {:formula, "B6*C6", value: 4.0}, date_cell({2026, 6, 4})],
        ["Totalt", nil, nil, [{:formula, "SUM(D3:D6)", value: 9999.0}, bg_color: "#ffe599"]]
      ],
      merge_cells: [{"A1", "D1"}],
      col_widths: %{1 => 18.0, 4 => 14.0}
    }

    notater = %Sheet{
      name: "Notater",
      rows: [["Husk leveringsavtale"], [], [nil, "Purres fredag"]]
    }

    {:ok, {_name, binary}} =
      Elixlsx.write_to_memory(%Workbook{sheets: [salg, notater]}, "salgsrapport.xlsx")

    binary
  end

  defp date_cell(erl_date), do: [{erl_date, {0, 0, 0}}, num_format: "yyyy-mm-dd"]

  # The task's round-trip contract, cell by cell: value, formula, fmt.
  defp comparable_cells(tab) do
    for {addr, cell} <- Map.get(tab, "cells", %{}), into: %{} do
      {addr, Map.take(cell, ["v", "f", "fmt"])}
    end
  end

  # ── the story ────────────────────────────────────────────────────────────────

  @tag :tmp_dir
  test "M3+M5 story over the wire: import recompute → embed render → mutate → round trip → text exports",
       %{tmp_dir: tmp_dir} do
    # 1 — IMPORT. The response counts both tabs and all 30 non-empty cells.
    body =
      import_upload(tmp_dir, "salgsrapport.xlsx", fixture_xlsx(), %{"slug" => @slug})
      |> json_response(200)

    assert %{"ok" => true, "slug" => @slug, "type" => "sheet", "tabs" => 2, "cells" => 30} = body

    doc = fetch_sheet("drafts." <> @slug)
    [salg, notater] = doc["tabs"]
    cells = salg["cells"]

    # The engine REPLACED every wrong cached value on the import save — the
    # stored "v" values are the recomputed numbers, typed "n", never stale.
    assert cells["D3"] == %{"f" => "B3*C3", "v" => 1998.0, "t" => "n"}
    assert cells["D4"] == %{"f" => "B4*C4", "v" => 1490, "t" => "n"}
    assert cells["D5"] == %{"f" => "B5*C5", "v" => 1798, "t" => "n"}
    assert cells["D6"] == %{"f" => "B6*C6", "v" => 177, "t" => "n"}

    assert cells["D7"] ==
             %{"f" => "SUM(D3:D6)", "v" => 5463.0, "t" => "n", "s" => %{"bg" => "#ffe599"}}

    # Layout survived: merged title, widths (18/14 units × 7 px), styles, date.
    assert salg["name"] == "Salg"
    assert salg["merges"] == ["A1:D1"]
    assert salg["col_widths"] == %{"1" => 126, "4" => 98}
    assert cells["A1"] == %{"v" => "Salgsrapport juni 2026", "s" => %{"b" => true}}
    assert cells["E3"] == %{"v" => "2026-06-01", "t" => "date", "fmt" => "date"}
    assert notater["name"] == "Notater"

    assert notater["cells"] ==
             %{"A1" => %{"v" => "Husk leveringsavtale"}, "B3" => %{"v" => "Purres fredag"}}

    # 2 — EMBED: a paper references tab 0. The sheet already exists, so the
    # ingest hydrates the embed snapshot immediately (M0a) — the first read
    # shows the RECOMPUTED values, no post-embed sheet save needed.
    resp =
      ingest_paper(%{
        "slug" => @paper_slug,
        "tags" => @wall_tags,
        "description" => @wall_description,
        "blocks" => [
          %{
            "id" => "p1",
            "type" => "paragraph",
            "content" => [
              %{"type" => "text", "value" => "Salgstallene under oppdateres direkte."}
            ]
          },
          %{"id" => "s0", "type" => "sheet", "ref" => @slug, "tab" => 0}
        ]
      })

    assert resp.status == 200
    assert Jason.decode!(resp.resp_body)["ok"] == true

    html = read_paper()
    assert html =~ "Salgstallene under oppdateres direkte."
    assert html =~ "<table"
    assert html =~ ">Hundeseng</td>"
    # The hydrated snapshot carries the RECOMPUTED total, not the file's lie.
    assert html =~ ">5463</td>"

    # Re-upload the same file: the idempotent upsert re-saves the sheet. The
    # embed snapshot already carries the recomputed grid from the M0a ingest
    # hydration above, so the published reader still renders the full styled
    # grid (the write-through's on-publish half is proven at the end of the
    # story, once the draft has been mutated).
    assert %{"ok" => true, "cells" => 30} =
             import_upload(tmp_dir, "salgsrapport.xlsx", fixture_xlsx(), %{"slug" => @slug})
             |> json_response(200)

    html = read_paper()
    # Computed numbers render in the grid — the per-product total and the SUM.
    assert html =~ ">1998</td>"
    assert html =~ ">5463</td>"
    assert html =~ ">2026-06-01</td>"
    # The merged title spans its four columns, bold style intact on the anchor.
    assert html =~ ~r{<td colspan="4"[^>]*font-weight:bold[^>]*>Salgsrapport juni 2026</td>}
    # The bg-colored total cell carries its fill inline.
    assert html =~ ~r{<td[^>]*background:#ffe599[^>]*>5463</td>}
    # Raw formula text never leaks into the rendered grid.
    refute html =~ "SUM(D3:D6)"
    refute html =~ "B3*C3"

    # 3 — MUTATE one qty cell (B4: 10 → 12) over the wire; dependents follow.
    tabs = fetch_sheet("drafts." <> @slug)["tabs"]
    new_tabs = update_in(tabs, [Access.at(0), "cells", "B4", "v"], fn _ -> 12 end)

    resp =
      mutate([
        %{
          "patch" => %{
            "id" => "drafts." <> @slug,
            "type" => "sheet",
            "set" => %{"tabs" => new_tabs}
          }
        }
      ])

    assert resp.status == 200

    # Stored DRAFT recomputed: the product total AND the grand total moved.
    cells = fetch_sheet("drafts." <> @slug)["tabs"] |> hd() |> Map.fetch!("cells")
    assert cells["D4"]["v"] == 1788
    assert cells["D7"]["v"] == 5761.0

    # DRAFT-CONTENT BOUNDARY: the PUBLISHED paper stays frozen on the last
    # published grid — the draft edit's new numbers do NOT leak to anonymous
    # readers (they surface only when the sheet is published, at the end).
    frozen = read_paper()
    assert frozen =~ ">5463</td>"
    refute frozen =~ ">5761</td>"
    refute frozen =~ ">1788</td>"

    # 4 — ROUND TRIP: export.xlsx → re-import under a new slug → equality.
    conn = export(@slug, "xlsx")
    assert response_content_type(conn, :xlsx) =~ "spreadsheetml"
    exported = response(conn, 200)

    assert %{"ok" => true, "tabs" => 2, "cells" => 30} =
             import_upload(tmp_dir, "reimport.xlsx", exported, %{"slug" => @rt_slug})
             |> json_response(200)

    orig = fetch_sheet("drafts." <> @slug)
    rt = fetch_sheet("drafts." <> @rt_slug)

    for {o_tab, r_tab} <- Enum.zip(orig["tabs"], rt["tabs"]) do
      assert r_tab["name"] == o_tab["name"]
      assert comparable_cells(r_tab) == comparable_cells(o_tab)
      assert r_tab["merges"] == o_tab["merges"]
      assert r_tab["col_widths"] == o_tab["col_widths"]
    end

    # Beyond the task's list, the full tab structures agree — styles included.
    assert rt["tabs"] == orig["tabs"]

    # 5 — TEXT EXPORTS. CSV: RFC-4180 quotes ONLY the comma-carrying name;
    # formulas flatten to their computed values.
    conn = export(@slug, "csv", "?tab=0")
    assert response_content_type(conn, :csv) =~ "text/csv"
    csv = response(conn, 200)
    assert String.starts_with?(csv, "Salgsrapport juni 2026,,,,\r\n")
    assert csv =~ ~s("Kobbel, kort",12,149,1788,2026-06-02\r\n)
    assert csv =~ "Totalt,,,5761,\r\n"

    md = export(@slug, "md") |> response(200)
    assert md =~ "## Salg"
    assert md =~ "## Notater"
    # No frozen head row → synthesized column-letter header.
    assert md =~ "| A | B | C | D | E |"
    assert md =~ "| 5761 |"

    # A BOM'd CSV (Excel "CSV UTF-8") with a quoted comma, over the wire:
    # the BOM strips, the quoted field stays one cell, the number infers.
    bom_csv = "\uFEFF" <> ~s(Vare,Antall\r\n"Krok, liten",7\r\n)

    assert %{"ok" => true, "cells" => 4} =
             import_upload(tmp_dir, "kvittering.csv", bom_csv, %{"slug" => "bom-kvittering-proof"})
             |> json_response(200)

    cells = fetch_sheet("drafts.bom-kvittering-proof")["tabs"] |> hd() |> Map.fetch!("cells")
    assert cells["A1"]["v"] == "Vare"
    assert cells["A2"]["v"] == "Krok, liten"
    assert cells["B2"]["v"] == 7

    # 7 — ON-PUBLISH UN-FREEZE: the sheet's own data (exports, round-trip)
    # reflected the B4 edit immediately, but the PUBLISHED paper only catches
    # up when the sheet is published. Publishing routes the now-published grid
    # back through the write-through, refreshing the embed snapshot.
    assert mutate([%{"publish" => %{"id" => @slug, "type" => "sheet"}}]).status == 200

    html = read_paper()
    assert html =~ ">12</td>"
    assert html =~ ">1788</td>"
    assert html =~ ">5761</td>"
    refute html =~ ">1490</td>"
    refute html =~ ">5463</td>"
    # Untouched neighbours survive the recompute.
    assert html =~ ">1798</td>"
    assert html =~ ">177</td>"
  end

  # ── hostile inputs ───────────────────────────────────────────────────────────

  @tag :tmp_dir
  test "hostile: a 50_001-cell CSV rejects with 413 naming the true count",
       %{tmp_dir: tmp_dir} do
    # 16_667 rows × 3 columns = 50_001 non-empty cells, one over the cap.
    csv = String.duplicate("a,b,c\r\n", 16_667)
    body = import_upload(tmp_dir, "diger.csv", csv, %{}) |> json_response(413)

    assert body["error"]["code"] == "sheet_too_large"
    assert body["error"]["message"] =~ "50001"
    assert body["error"]["message"] =~ "50000"
  end

  @tag :tmp_dir
  test "hostile: garbage bytes under an .xlsx name are a clean 422", %{tmp_dir: tmp_dir} do
    garbage = :binary.copy(<<0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF>>, 128)
    body = import_upload(tmp_dir, "smitte.xlsx", garbage, %{}) |> json_response(422)

    assert body["error"]["code"] == "invalid_xlsx"
  end

  @tag :tmp_dir
  test "hostile: an A1:ZZZ1000 merge clamps to the occupied bounds and exports fast",
       %{tmp_dir: tmp_dir} do
    sheets = [
      %Sheet{name: "Felle", rows: [["a", "b"], ["c", "d"]], merge_cells: [{"A1", "ZZZ1000"}]}
    ]

    {:ok, {_name, binary}} = Elixlsx.write_to_memory(%Workbook{sheets: sheets}, "felle.xlsx")

    assert %{"ok" => true, "cells" => 4} =
             import_upload(tmp_dir, "felle.xlsx", binary, %{"slug" => "hostile-merge-proof"})
             |> json_response(200)

    # Column ZZZ (18_278) reaches past XFD and row 1000 past the data — the
    # range clamps to the occupied 2×2 grid instead of widening it.
    tab = fetch_sheet("drafts.hostile-merge-proof")["tabs"] |> hd()
    assert tab["merges"] == ["A1:B2"]

    # The dense grid never inflated: the export answers promptly and the
    # values stay a 2×2 grid (merges never blank the dense values).
    {micros, conn} = :timer.tc(fn -> export("hostile-merge-proof", "csv") end)
    assert response(conn, 200) == "a,b\r\nc,d\r\n"
    assert micros < 5_000_000
  end

  test "hostile: a mutate writing a cell at ZZZZZ9 is rejected by the write gate" do
    resp =
      mutate([
        %{
          "create" => %{
            "_id" => "sheet-offgrid-proof",
            "_type" => "sheet",
            "content" => %{"tabs" => [%{"cells" => %{"ZZZZZ9" => %{"v" => 1}}}]}
          }
        }
      ])

    assert resp.status == 409
    body = Jason.decode!(resp.resp_body)
    # canonical envelope: code + the halt reason as message (was bare
    # %{"error" => "halted", "reason" => …})
    assert body["error"]["code"] == "halted"
    assert body["error"]["message"] =~ "ZZZZZ9"
    assert body["error"]["message"] =~ "beyond the grid bounds"
  end
end
