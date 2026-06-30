defmodule Barkpark.SheetsM0ProofTest do
  @moduledoc """
  Independent end-to-end proof of the Sheets M0 contract, driven entirely
  over the HTTP surface — no direct `Content` calls anywhere in the flow.

  The story, all on the wire:

    1. `POST /v1/data/mutate/production` creates a 2-tab `sheet` document
       (strings, numbers, a date, col_widths) via the mutation envelope.
    2. `POST /v1/plugins/bulldocs/papers` ingests a paper embedding that sheet via
       two core `"sheet"` blocks (tab 0 + tab 1).
    3. `GET /papers/:slug` — the sheet existed BEFORE the embed, so the
       ingest hydrated BOTH blocks' snapshots immediately (M0a): the first
       read already shows the cell values, still with no DB join at render
       time (the blocks compose straight from their cached snapshots).
    4. A second mutate (append a row) fires the write-through: BOTH embed
       snapshots refresh in the same logical operation, and the re-fetched
       page shows the appended row.
    5. A third mutate edits ONE cell; the re-fetched page shows the new
       value and no trace of the old one.
    6. Structurally malformed sheets (cells as a list, a non-A1 `"1A"` key)
       are rejected at the write gate with a 4xx.

  Deliberately overlaps zero fixtures with the builder's tests: those drive
  `Content` / LiveView directly; this file proves the same contract holds for
  a plain HTTP client.
  """
  use BarkparkWeb.ConnCase, async: false

  # Papers resolve publicly only in dataset "production" (Content's
  # @paper_default_dataset), so the sheet must live there too — the
  # write-through targets same-scope embeds only.
  @dataset "production"
  @sheet_id "sheet-m0-proof"
  @slug "sheets-m0-proof-paper"

  # Fresh write token for the mutate endpoint (same fixture convention as
  # mutate_controller_test.exs, distinct value to avoid any sharing).
  @write_token "sheets-m0-proof-write-token"
  # Fixed paper-ingest secret from config/test.exs.
  @ingest_token "barkpark-test-ingest-token"

  setup do
    # The Default workspace/project must exist: AssignDefaultScope stamps the
    # sheet row with it on the flat mutate route, upsert_paper falls back to
    # it, and get_public_paper fails closed without it.
    Barkpark.TenancyFixtures.ensure_default_scope!()
    Barkpark.Auth.create_token(@write_token, "m0-proof", @dataset, ["read", "write"])
    :ok
  end

  defp mutate(conn, mutations) do
    conn
    |> put_req_header("authorization", "Bearer " <> @write_token)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp ingest_paper(conn, body) do
    conn
    |> put_req_header("authorization", "Bearer " <> @ingest_token)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/plugins/bulldocs/papers", Jason.encode!(body))
  end

  defp read_paper(conn) do
    conn |> get("/papers/#{@slug}") |> html_response(200)
  end

  # Tab 0 is a budget grid with a frozen head row + sparse col_widths; tab 1
  # is a loose notes tab (no frozen rows, gap between its two cells). `extra`
  # merges over tab 0's cells so later mutations can append/edit rows.
  defp tabs(extra) do
    [
      %{
        "name" => "Budsjett",
        "frozen_rows" => 1,
        "frozen_cols" => 0,
        "col_widths" => %{"1" => 120, "2" => 80, "3" => 96},
        "cells" =>
          Map.merge(
            %{
              "A1" => %{"v" => "Produkt", "t" => "string"},
              "B1" => %{"v" => "Antall", "t" => "string"},
              "C1" => %{"v" => "Pris", "t" => "string"},
              "D1" => %{"v" => "Oppdatert", "t" => "string"},
              "A2" => %{"v" => "Hundeseng", "t" => "string"},
              "B2" => %{"v" => 437, "t" => "number"},
              "C2" => %{"v" => 499.5, "t" => "number"},
              "D2" => %{"v" => "2026-06-12", "t" => "date"}
            },
            extra
          )
      },
      %{
        "name" => "Notater",
        "frozen_rows" => 0,
        "cells" => %{
          "A1" => %{"v" => "Q3-lansering utsatt"},
          "B2" => %{"v" => 7, "t" => "number"}
        }
      }
    ]
  end

  defp kobbel_row(pris) do
    %{
      "A3" => %{"v" => "Kobbel", "t" => "string"},
      "B3" => %{"v" => 30, "t" => "number"},
      "C3" => %{"v" => pris, "t" => "number"}
    }
  end

  test "full M0 story over the wire: create → embed (hydrates) → write-through → re-mutate",
       %{conn: conn} do
    # 1 — CREATE the sheet through the public mutation envelope.
    resp =
      mutate(conn, [
        %{
          "create" => %{
            "_id" => @sheet_id,
            "_type" => "sheet",
            "title" => "M0 proof sheet",
            "content" => %{"locale" => "nb-NO", "tabs" => tabs(%{})}
          }
        }
      ])

    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert [%{"operation" => "create", "id" => stored_id}] = body["results"]
    # New docs are always drafts; papers canonically embed the PUBLISHED id —
    # the write-through must bridge the two forms.
    assert stored_id == "drafts." <> @sheet_id

    # 2 — EMBED: ingest a paper whose blocks reference the sheet by its
    # published id, once per tab, plus a plain paragraph.
    resp =
      ingest_paper(conn, %{
        "slug" => @slug,
        "blocks" => [
          %{
            "id" => "p1",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Budsjettet under oppdateres live."}]
          },
          %{"id" => "s0", "type" => "sheet", "ref" => @sheet_id, "tab" => 0},
          %{"id" => "s1", "type" => "sheet", "ref" => @sheet_id, "tab" => 1}
        ]
      })

    assert resp.status == 200
    assert Jason.decode!(resp.resp_body)["ok"] == true

    # 3 — M0a hydration: the embed was ingested AFTER the sheet existed, so
    # the ingest hydrated BOTH blocks' snapshots — the first read already
    # renders the cell values (head row, data, both tabs), before any
    # post-embed sheet mutation.
    html = read_paper(conn)
    assert html =~ "Budsjettet under oppdateres live."
    assert html =~ "<table"
    assert html =~ ">Hundeseng</td>"
    assert html =~ ">Q3-lansering utsatt</td>"
    refute html =~ ">Kobbel</td>"

    # 4 — WRITE-THROUGH: mutate the sheet over the wire (append row 3). The
    # same logical operation must refresh BOTH embed snapshots in the paper.
    resp =
      mutate(conn, [
        %{
          "patch" => %{
            "id" => stored_id,
            "type" => "sheet",
            "set" => %{"tabs" => tabs(kobbel_row(149))}
          }
        }
      ])

    assert resp.status == 200

    html = read_paper(conn)
    # Head row (frozen_rows: 1) becomes <th> column labels.
    assert html =~ "<th"
    assert html =~ "Produkt"
    assert html =~ "Oppdatert"
    # Data cells: string / integer / float / ISO date, as rendered values.
    assert html =~ ">Hundeseng</td>"
    assert html =~ ">437</td>"
    assert html =~ ">499.5</td>"
    assert html =~ ">2026-06-12</td>"
    # The appended row arrived too.
    assert html =~ ">Kobbel</td>"
    assert html =~ ">149</td>"
    # col_widths pass through the snapshot into inline width hints.
    assert html =~ "width:120px;"
    # The SECOND embed (tab 1) refreshed in the same operation.
    assert html =~ ">Q3-lansering utsatt</td>"

    # 5 — mutate ONE cell (C3: 149 → 179) through the same endpoint.
    resp =
      mutate(conn, [
        %{
          "patch" => %{
            "id" => stored_id,
            "type" => "sheet",
            "set" => %{"tabs" => tabs(kobbel_row(179))}
          }
        }
      ])

    assert resp.status == 200

    # 6 — re-fetch: the new value renders; the old one is gone; neighbours
    # are untouched.
    html = read_paper(conn)
    assert html =~ ">179</td>"
    refute html =~ ">149</td>"
    assert html =~ ">Hundeseng</td>"
    assert html =~ ">Kobbel</td>"
    assert html =~ ">Q3-lansering utsatt</td>"
  end

  test "a structurally malformed sheet is rejected at the write gate with a 4xx",
       %{conn: conn} do
    # cells as a LIST instead of an A1-keyed map.
    resp =
      mutate(conn, [
        %{
          "create" => %{
            "_id" => "sheet-m0-bad-list",
            "_type" => "sheet",
            "content" => %{"tabs" => [%{"cells" => ["A1", "A2"]}]}
          }
        }
      ])

    assert resp.status == 409
    body = Jason.decode!(resp.resp_body)
    # canonical envelope: code + the halt reason as message (was bare
    # %{"error" => "halted", "reason" => …})
    assert body["error"]["code"] == "halted"
    assert body["error"]["message"] =~ "cells must be a map"

    # A non-A1 cell key ("1A" — digits first).
    resp =
      mutate(conn, [
        %{
          "create" => %{
            "_id" => "sheet-m0-bad-key",
            "_type" => "sheet",
            "content" => %{"tabs" => [%{"cells" => %{"1A" => %{"v" => 1}}}]}
          }
        }
      ])

    assert resp.status == 409
    body = Jason.decode!(resp.resp_body)
    assert body["error"]["code"] == "halted"
    assert body["error"]["message"] =~ "invalid cell address"
    assert body["error"]["message"] =~ "1A"
  end
end
