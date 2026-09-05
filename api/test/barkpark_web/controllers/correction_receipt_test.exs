defmodule BarkparkWeb.CorrectionReceiptTest do
  @moduledoc """
  The correction receipt, pinned WHERE A CALLER READS IT — over HTTP.

  `Barkpark.Search.Intelligence.record_correction/4` answers five causally
  different outcomes (PDS-D496 shipped the `status:` key that names them):

    * `:recorded`            — a `correction` event row was written.
    * `:recording_disabled`  — recording is off for this request (a no-op).
    * `:blank`               — `from` or `to` normalized to "".
    * `:identical`           — `from` and `to` normalized to the same string.
    * `:error`               — an exception was swallowed. THE SIGNAL WAS LOST.

  Before this file, `correction/2` destructured `status:` away and rendered
  `{"ok":true,"promoted":false,"distinctSessions":0}` for ALL FIVE — 51 bytes
  that a lost write and a recorded correction shared exactly, while the rows
  behind them differed 0 to 1. There was no coverage of any kind
  (`grep -rn ':correction\\b' api/test` returned nothing), so nothing red when
  the discriminator was discarded.

  These tests therefore assert on the RESPONSE and on the ROW COUNT, never on
  the shape of the controller: a receipt that says `recorded: true` must be
  backed by a `search_intel_events` correction row, and a receipt that says
  `status: "error"` must be backed by the ABSENCE of one.

  ## Status mapping (PDS-D695 — uniform 200)

  Every outcome answers HTTP 200 and discriminates in the body:

      status              | ok    | recorded
      --------------------|-------|---------
      recorded            | true  | true
      recording_disabled  | true  | false
      blank               | true  | false
      identical           | true  | false
      error               | false | false

  The transport stays 200 because this endpoint is a fire-and-forget signal:
  every existing caller posts it without branching on `res.ok`, so moving a
  lost write to 5xx would invert that flag underneath them without telling
  anyone anything the body does not already say. The find-event slice of this
  wave rules the same way.

  ## Reachability is re-derived, not inherited

  `router.ex:1656` `post("/search/:dataset/correction", SearchController,
  :correction)` sits in `scope "/v1/data"` (`:1651`) on
  `pipe_through([:api, :api_grant_read])` — no `:require_token`,
  `:require_write` or `:require_admin`, and `:api` authenticates through
  `Plugs.OptionalToken`. Every case below posts WITHOUT an authorization
  header, and the first test proves that anonymity is real by running it.

  `router.ex:2191` carries the SAME controller action inside
  `scope "/w/:workspace_slug/p/:project_slug"` on `pipe_through(:scoped_api)`.
  Nothing in this file dispatches to that mirror and its pipeline is NOT what
  these cases prove anything about. It is unpinned here, deliberately.
  """
  use BarkparkWeb.ConnCase, async: true

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Search.Event

  @dataset "production"

  # A NUL byte survives `correction_string/3` (String.trim) and
  # `Sanitizer.normalize/1` (trim + whitespace collapse + downcase), reaches
  # Postgres inside the `query` :string column, and is rejected there. The
  # `rescue` in `record_correction/4` swallows it into `status: :error` — the
  # arm where the signal is LOST, produced by a real request rather than a
  # stub.
  @nul_from "corection" <> <<0>> <> "typo"

  setup do
    Repo.delete_all(from(e in Event, where: e.surface == "documents"))
    :ok
  end

  # Anonymous on purpose: the receipt has to hold for the caller the route
  # actually admits, not for an operator with an admin token.
  defp post_correction(conn, params, headers \\ []) do
    headers
    |> Enum.reduce(conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    |> post(~p"/v1/data/search/#{@dataset}/correction", params)
  end

  defp correction_rows do
    Repo.aggregate(
      from(e in Event, where: e.surface == "documents" and e.event_type == "correction"),
      :count
    )
  end

  describe "reachability — the receipt is on a path a real, non-admin caller can hit" do
    test "the flat correction route answers an ANONYMOUS post (no token, no admin)", %{conn: conn} do
      resp = post_correction(conn, %{"from" => "corection", "to" => "correction"})

      refute resp.status in [401, 403, 404],
             "POST /v1/data/search/#{@dataset}/correction must be reachable anonymously " <>
               "(router.ex:1656 in scope \"/v1/data\", pipe_through [:api, :api_grant_read] — " <>
               "no :require_token/:require_admin), got #{resp.status}"

      assert resp.status == 200
    end
  end

  describe "the five outcomes are distinguishable at the HTTP boundary" do
    test "a recorded correction answers status recorded AND writes a row", %{conn: conn} do
      body =
        conn
        |> post_correction(%{"from" => "corection", "to" => "correction"})
        |> json_response(200)

      assert body["ok"] == true
      assert body["status"] == "recorded"
      assert body["recorded"] == true
      assert body["promoted"] == false
      assert body["distinctSessions"] == 0

      assert correction_rows() == 1,
             "status:\"recorded\" must be backed by a correction row"
    end

    test "a switched-off recorder answers status recording_disabled and writes nothing", %{
      conn: conn
    } do
      body =
        conn
        |> post_correction(
          %{"from" => "corection", "to" => "correction"},
          [{"x-bp-search-disable", "1"}]
        )
        |> json_response(200)

      assert body["ok"] == true
      assert body["status"] == "recording_disabled"
      assert body["recorded"] == false
      assert correction_rows() == 0
    end

    test "a blank side answers status blank and writes nothing", %{conn: conn} do
      body =
        conn
        |> post_correction(%{"from" => "   ", "to" => "correction"})
        |> json_response(200)

      assert body["ok"] == true
      assert body["status"] == "blank"
      assert body["recorded"] == false
      assert correction_rows() == 0
    end

    test "an identical from/to answers status identical and writes nothing", %{conn: conn} do
      body =
        conn
        |> post_correction(%{"from" => "Correction", "to" => "correction"})
        |> json_response(200)

      assert body["ok"] == true
      assert body["status"] == "identical"
      assert body["recorded"] == false
      assert correction_rows() == 0
    end

    test "a LOST write answers ok:false status error and writes nothing", %{conn: conn} do
      body =
        conn
        |> post_correction(%{"from" => @nul_from, "to" => "correction"})
        |> json_response(200)

      assert body["ok"] == false
      assert body["status"] == "error"
      assert body["recorded"] == false

      assert correction_rows() == 0,
             "the :error arm must be a genuinely lost write, not a recorded one"
    end

    # The defect this file exists for: five outcomes, one body. Measured side
    # by side in ONE run with the table reset between, so the comparison is of
    # receipts and not of two separate runs' luck.
    test "no two outcomes share a body — the lost write and the recorded one differ on the wire",
         %{conn: conn} do
      cases = [
        {:recorded, %{"from" => "corection", "to" => "correction"}, [], 1},
        {:recording_disabled, %{"from" => "corection", "to" => "correction"},
         [{"x-bp-search-disable", "1"}], 0},
        {:blank, %{"from" => "   ", "to" => "correction"}, [], 0},
        {:identical, %{"from" => "Correction", "to" => "correction"}, [], 0},
        {:error, %{"from" => @nul_from, "to" => "correction"}, [], 0}
      ]

      receipts =
        Enum.map(cases, fn {label, params, headers, expected_rows} ->
          Repo.delete_all(from(e in Event, where: e.surface == "documents"))

          resp = post_correction(conn, params, headers)
          body = json_response(resp, 200)
          rows = correction_rows()

          assert rows == expected_rows,
                 "#{label}: expected #{expected_rows} correction row(s), got #{rows}"

          {label, {resp.status, body}, rows}
        end)

      bodies = Enum.map(receipts, fn {_label, receipt, _rows} -> receipt end)

      assert length(Enum.uniq(bodies)) == 5,
             "five causally different outcomes collapsed into fewer receipts: " <>
               inspect(receipts, pretty: true)

      # The pair the epic cares about most: 0 rows written vs 1 row written.
      {_, lost_receipt, 0} = Enum.find(receipts, fn {label, _, _} -> label == :error end)
      {_, kept_receipt, 1} = Enum.find(receipts, fn {label, _, _} -> label == :recorded end)

      refute lost_receipt == kept_receipt,
             "a lost signal and a recorded correction are byte-identical on the wire"
    end
  end
end
