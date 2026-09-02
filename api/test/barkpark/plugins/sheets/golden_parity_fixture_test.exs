defmodule Barkpark.Plugins.Sheets.GoldenParityFixtureTest do
  @moduledoc """
  Freshness lock for the cross-surface golden parity fixture — the Elixir
  source-of-truth end of the spine `Core.snapshot_for` + `Fmt.display` -> one
  committed fixture -> {api tests, web SDK, internal/pdrender TUI}.

  A `Fmt.display` change, an `sv` bump, or a snapshot-synthesis change that ships
  WITHOUT regenerating the fixture would let the TUI (and web) render a stale /
  wrong grid with every gate otherwise green. This suite reds instead: it
  regenerates the fixture in-memory and asserts term-equality with the committed
  api mirror, asserts the three mirrors are byte-for-byte the same fixture, and
  asserts the fixture's stamped `sv` matches the live schema version.

  Regenerate with `mix barkpark.sheets.gen_golden_parity` (writes all three
  mirrors) whenever this reds.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Sheets.Core
  alias Barkpark.Plugins.Sheets.Fmt
  alias Mix.Tasks.Barkpark.Sheets.GenGoldenParity

  @api_path Path.expand("../../../support/fixtures/sheet-golden-parity.json", __DIR__)
  @web_path Path.expand(
              "../../../../../web/__tests__/fixtures/sheet-golden-parity.json",
              __DIR__
            )
  @go_path Path.expand(
             "../../../../../internal/pdrender/testdata/sheet-golden-parity.json",
             __DIR__
           )

  defp decode!(path), do: path |> File.read!() |> Jason.decode!()

  test "committed api mirror equals a fresh regeneration (build/0)" do
    committed = decode!(@api_path)

    # build/0 emits only JSON-safe terms, so a Jason encode->decode round-trip is
    # the identity — comparing the decoded committed fixture to build/0 directly
    # is exactly the "does the file match the generator" check.
    assert committed == GenGoldenParity.build(),
           "sheet-golden-parity.json is stale — " <>
             "run `mix barkpark.sheets.gen_golden_parity` and re-verify all five surfaces."
  end

  test "the three mirrors decode term-identical" do
    api = decode!(@api_path)
    web = decode!(@web_path)
    go = decode!(@go_path)

    assert api == web,
           "web mirror drifted from api mirror — run `mix barkpark.sheets.gen_golden_parity`."

    assert api == go,
           "internal/pdrender mirror drifted from api mirror — run `mix barkpark.sheets.gen_golden_parity`."
  end

  test "fixture sv matches the live snapshot schema version" do
    assert decode!(@api_path)["sv"] == Core.snapshot_schema_version()
  end

  # ── coverage locks (w16-3) — the fixture must CARRY the shapes the three
  # surface legs assert over; a gutted regen reds here, not just in Go. ────────

  test "coverage floor: expected carries at least 20 shown values" do
    assert map_size(decode!(@api_path)["expected"]) >= 20,
           "fixture expected shrank below the 20-entry floor — a regen dropped coverage."
  end

  test "frozen-head fmt: head cell D1 reads the FORMATTED 50.00%, not the raw 0.5" do
    fixture = decode!(@api_path)

    assert fixture["expected"]["D1"] == "50.00%"
    # head is row 1 of the dense snapshot; D is the 4th label.
    assert Enum.at(fixture["head"], 3) == "50.00%"
  end

  test "fmt-class coverage: datetime (B7) and checkbox-on-boolean (D2) snapshot correctly" do
    expected = decode!(@api_path)["expected"]

    assert expected["B7"] == "2026-06-12 08:30:00"
    assert expected["D2"] == "TRUE"
  end

  test "error coverage: all seven pinned engine error codes (error_refs = 7)" do
    fixture = decode!(@api_path)

    assert Enum.sort(fixture["error_refs"]) == ["A11", "A6", "A9", "B11", "B19", "B9", "C11"]

    assert Map.take(fixture["expected"], ["A11", "B11", "C11", "B19"]) ==
             %{"A11" => "#NUM!", "B11" => "#REF!", "C11" => "#CYCLE!", "B19" => "#NAME?"}
  end

  test "long-cell probe: A12 carries the 60-char string verbatim" do
    a12 = decode!(@api_path)["expected"]["A12"]

    assert String.length(a12) == 60
    assert a12 == "sixty-character-wide-cell-padding-parity-lock-XYZ-0123456789"
  end

  test "note-leak guard: the D4 note canary never reaches the snapshot or expected" do
    fixture = decode!(@api_path)

    # The cell's VALUE must be shown …
    assert fixture["expected"]["D4"] == "has note"

    # … but the note itself must not leak into the encoded snapshot the
    # surfaces consume, nor into any expected value.
    refute Jason.encode!(fixture["snapshot"]) =~ "NOTE-LEAK-CANARY"

    for {ref, val} <- fixture["expected"] do
      refute val =~ "NOTE-LEAK-CANARY", "note canary leaked into expected[#{ref}]"
    end
  end

  test "fmt_vocabulary in the fixture equals the live Fmt.vocabulary/0" do
    assert decode!(@api_path)["fmt_vocabulary"] == Fmt.vocabulary()
  end

  # ── CF coverage locks (CF-E) — the committed snapshot styles map must CARRY
  # the composed conditional-formatting entries the four fixture rules produce,
  # and must NOT carry one for the frozen head row. Keys are "bodyRow,col",
  # 0-based, with the head row (row 1) split off (data_start = 2). ────────────

  # A frozen head + manual-styled cells + the four CF rules make the styles map
  # the substrate for every CF-D3/CF-D4/CF-AM2 assertion below.
  defp styles, do: decode!(@api_path)["snapshot"]["styles"]

  test "storability: the committed golden content passes the before_save gate" do
    # The generator promises "a legitimately storable sheet" — pin it. If a
    # future fixture edit adds a gate-invalid rule (or cell/merge), the golden
    # sheet could never exist through the real save path and the whole parity
    # lock would be certifying a fiction.
    [hook] = Barkpark.Plugins.Sheets.lifecycle_hooks().before_save

    assert hook.(%{doc: %{"type" => "sheet", "content" => decode!(@api_path)["content"]}}) ==
             :ok
  end

  test "CF-D5/CF-D8: a numeric gt rule paints matched occupied cells only" do
    styles = styles()

    # cf-gt (gt 1000 on B2:B10) fires on B2 (1200 -> "0,1") and B8 (1234.5 ->
    # "6,1"), each a CF-ONLY entry (no manual "s" on those cells).
    assert styles["0,1"] == %{"bg" => "#ff0000"}
    assert styles["6,1"] == %{"bg" => "#ff0000"}

    # B10 (1, below the threshold) is occupied but unmatched -> NO entry, even
    # though it sits inside the rule's range. This is "matches some, not others".
    refute Map.has_key?(styles, "8,1")
  end

  test "CF-D4: overlapping ranges resolve first-match-wins" do
    styles = styles()

    # B2 and B8 sit in BOTH cf-gt (B2:B10) and cf-overlap (B2:C8); the first rule
    # in list order supplies the whole contribution — red, never the overlap's
    # green.
    assert styles["0,1"]["bg"] == "#ff0000"
    assert styles["6,1"]["bg"] == "#ff0000"

    # cf-overlap is still live where cf-gt doesn't reach: C7 (1e6 -> "5,2") green.
    assert styles["5,2"] == %{"bg" => "#00ff00"}
  end

  test "CF-D3: CF composes OVER a manually-styled cell — CF wins bg, manual keys survive" do
    # A4 carries a manual style {b, i, bg #e0f0ff, al: right}; cf-compose fires
    # (contains "ote" over "Note") and wins `bg` while al/b/i survive.
    assert styles()["2,0"] == %{
             "al" => "right",
             "b" => true,
             "i" => true,
             "bg" => "#123456"
           }
  end

  test "CF-D3/CF-AM2: the snapshot drops CF for a frozen head-row cell" do
    styles = styles()

    # cf-head (contains "Q" on A1:D1) matches B1/C1 at eval, but the head row is
    # frozen (frozen_rows: 1) so the snapshot carries NO CF entry for it — the
    # would-be body keys (row 1 -> -1) never appear, and no key is head-shaped.
    refute Map.has_key?(styles, "-1,1")
    refute Map.has_key?(styles, "-1,2")

    for {key, _} <- styles do
      refute String.starts_with?(key, "-"),
             "styles carries a negative-row (head) key #{inspect(key)} — head-drop broke"
    end
  end
end
