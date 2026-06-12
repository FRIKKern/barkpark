defmodule Barkpark.SheetsM3ProofTest do
  @moduledoc """
  Independent end-to-end proof of the Sheets M3 contract — the formula
  engine on the wire, no direct `Content` or `Engine` calls anywhere:

    1. `POST /v1/data/mutate/production` creates a `sheet` document whose
       cells carry formulas (`SUM` over a range, a division, a date advance,
       a deliberate `1/0`).
    2. The mutation response envelope already carries COMPUTED `"v"` values —
       the engine ran inside the same save, before the row persisted.
    3. A paper ingested via `/v1/paperflow/papers` embeds the sheet; a
       follow-up mutate fires the write-through, and `GET /papers/:slug`
       renders the computed results (and the `#DIV/0!`) in the HTML grid —
       zero renderer changes.
    4. Patching ONE input cell over the wire recomputes the dependents: the
       re-fetched page shows the new total and no trace of the old one.
  """
  use BarkparkWeb.ConnCase, async: false

  # Papers resolve publicly only in dataset "production" (Content's
  # @paper_default_dataset), so the sheet must live there too.
  @dataset "production"
  @sheet_id "sheet-m3-proof"
  @slug "sheets-m3-proof-paper"

  @write_token "sheets-m3-proof-write-token"
  @ingest_token "paperflow-test-ingest-token"

  setup do
    Barkpark.TenancyFixtures.ensure_default_scope!()
    Barkpark.Auth.create_token(@write_token, "m3-proof", @dataset, ["read", "write"])
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
    |> post("/v1/paperflow/papers", Jason.encode!(body))
  end

  defp read_paper(conn) do
    conn |> get("/papers/#{@slug}") |> html_response(200)
  end

  # One tab: a head row, three quantity inputs, then a formula column —
  # SUM over the inputs, an AVG that divides inexactly, a date advance,
  # and a deliberate division by zero. `b4` is the input later patched.
  defp tabs(b4) do
    [
      %{
        "name" => "Regneark",
        "frozen_rows" => 1,
        "cells" => %{
          "A1" => %{"v" => "Felt", "t" => "s"},
          "B1" => %{"v" => "Verdi", "t" => "s"},
          "A2" => %{"v" => "x1", "t" => "s"},
          "B2" => %{"v" => 2, "t" => "n"},
          "A3" => %{"v" => "x2", "t" => "s"},
          "B3" => %{"v" => 3, "t" => "n"},
          "A4" => %{"v" => "x3", "t" => "s"},
          "B4" => %{"v" => b4, "t" => "n"},
          "A5" => %{"v" => "Sum", "t" => "s"},
          "B5" => %{"f" => "=SUM(B2:B4)"},
          "A6" => %{"v" => "Snitt", "t" => "s"},
          "B6" => %{"f" => "AVG(B2:B3)"},
          "A7" => %{"v" => "Frist", "t" => "s"},
          "B7" => %{"f" => "C7+7"},
          "C7" => %{"v" => "2026-06-12", "t" => "date"},
          "A8" => %{"v" => "Feil", "t" => "s"},
          "B8" => %{"f" => "1/0"}
        }
      }
    ]
  end

  test "M3 story over the wire: formulas compute on save and render in embeds",
       %{conn: conn} do
    # 1 — CREATE the sheet with formula cells through the mutation envelope.
    resp =
      mutate(conn, [
        %{
          "create" => %{
            "_id" => @sheet_id,
            "_type" => "sheet",
            "title" => "M3 proof sheet",
            "content" => %{"locale" => "nb-NO", "tabs" => tabs(5)}
          }
        }
      ])

    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert [%{"operation" => "create", "id" => stored_id, "document" => doc}] = body["results"]
    assert stored_id == "drafts." <> @sheet_id

    # 2 — the response envelope already carries computed values: the engine
    # ran ahead of the persist, inside the same save. (The v1 envelope is
    # flat: content keys sit at the top level.)
    cells = get_in(doc, ["tabs", Access.at(0), "cells"])
    assert cells["B5"]["v"] == 10
    assert cells["B5"]["t"] == "n"
    assert cells["B6"]["v"] == 2.5
    assert cells["B7"] == %{"f" => "C7+7", "v" => "2026-06-19", "t" => "date"}
    assert cells["B8"]["v"] == "#DIV/0!"
    assert cells["B8"]["t"] == "e"

    # 3 — EMBED + WRITE-THROUGH: ingest a paper referencing the sheet, then
    # mutate the sheet again so the snapshot refreshes with computed values.
    resp =
      ingest_paper(conn, %{
        "slug" => @slug,
        "blocks" => [
          %{
            "id" => "p1",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Utregningene under er live."}]
          },
          %{"id" => "s0", "type" => "sheet", "ref" => @sheet_id, "tab" => 0}
        ]
      })

    assert resp.status == 200
    assert Jason.decode!(resp.resp_body)["ok"] == true

    resp =
      mutate(conn, [
        %{
          "patch" => %{
            "id" => stored_id,
            "type" => "sheet",
            "set" => %{"tabs" => tabs(5)}
          }
        }
      ])

    assert resp.status == 200

    html = read_paper(conn)
    assert html =~ "Utregningene under er live."
    # Computed values render in the grid — SUM, AVG, date advance, DIV/0.
    assert html =~ ">10</td>"
    assert html =~ ">2.5</td>"
    assert html =~ ">2026-06-19</td>"
    assert html =~ ">#DIV/0!</td>"
    # The raw formula text never leaks into the rendered grid.
    refute html =~ "SUM(B2:B4)"

    # 4 — patch ONE input (B4: 5 → 15) over the wire; dependents recompute
    # and the refreshed snapshot shows the new total only.
    resp =
      mutate(conn, [
        %{
          "patch" => %{
            "id" => stored_id,
            "type" => "sheet",
            "set" => %{"tabs" => tabs(15)}
          }
        }
      ])

    assert resp.status == 200

    html = read_paper(conn)
    assert html =~ ">20</td>"
    refute html =~ ">10</td>"
    # Untouched computed cells survive the recompute.
    assert html =~ ">2.5</td>"
    assert html =~ ">2026-06-19</td>"
  end
end
