defmodule BarkparkWeb.Studio.SheetGrid.CellsTest do
  @moduledoc """
  Pure-unit coverage for `BarkparkWeb.Studio.SheetGrid.Cells`.
  No socket, no DB — `async: true`.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.SheetGrid.Cells

  describe "display/1" do
    test "boolean true renders as 'TRUE'" do
      assert Cells.display(%{"v" => true}) == "TRUE"
    end

    test "boolean false renders as 'FALSE'" do
      assert Cells.display(%{"v" => false}) == "FALSE"
    end

    test "integer value converts to string" do
      assert Cells.display(%{"v" => 42}) == "42"
    end

    test "float value converts to string" do
      assert Cells.display(%{"v" => 3.14}) == "3.14"
    end

    test "whole float renders integral (no scientific notation)" do
      # to_string(1_000_000.0) == "1.0e6"; the shared formatter keeps it plain.
      assert Cells.display(%{"v" => 1_000_000.0}) == "1000000"
    end

    test "non-whole floats keep their decimals" do
      assert Cells.display(%{"v" => 0.1}) == "0.1"
      assert Cells.display(%{"v" => 1.5}) == "1.5"
      assert Cells.display(%{"v" => -2.5}) == "-2.5"
      assert Cells.display(%{"v" => 123_456_789.123}) == "123456789.123"
      refute Cells.display(%{"v" => 123_456_789.123}) =~ "e"
    end

    test "extreme magnitudes keep exponent form, like Excel General" do
      assert Cells.display(%{"v" => 1.0e-7}) =~ "e"
      assert Cells.display(%{"v" => 1.0e21}) =~ "e"
    end

    test "binary value is returned as-is" do
      assert Cells.display(%{"v" => "hello"}) == "hello"
    end

    test "nil cell returns empty string" do
      assert Cells.display(nil) == ""
    end

    test "empty map returns empty string" do
      assert Cells.display(%{}) == ""
    end

    test "cell with no 'v' key returns empty string" do
      assert Cells.display(%{"f" => "A1+B1"}) == ""
    end
  end

  describe "display/1 — checkbox fmt (glyph, clause order)" do
    test "a checkbox-fmt boolean renders the glyph, NOT 'TRUE'/'FALSE'" do
      # This is the correctness point: the bare `%{"v" => true}` clause would
      # short-circuit to "TRUE" before "fmt" is consulted, so the checkbox
      # clauses MUST come first. If a refactor reorders them, this reds.
      assert Cells.display(%{"fmt" => "checkbox", "v" => true}) == "☑"
      assert Cells.display(%{"fmt" => "checkbox", "v" => false}) == "☐"
    end

    test "a checkbox cell with nil or absent 'v' is unchecked" do
      assert Cells.display(%{"fmt" => "checkbox", "v" => nil}) == "☐"
      assert Cells.display(%{"fmt" => "checkbox"}) == "☐"
    end

    test "a checkbox fmt on a non-boolean value renders the value (General fallback)" do
      assert Cells.display(%{"fmt" => "checkbox", "v" => "hello"}) == "hello"
      assert Cells.display(%{"fmt" => "checkbox", "v" => 42}) == "42"
    end

    test "a bare boolean (no fmt) still renders TRUE/FALSE — checkbox clauses don't steal it" do
      assert Cells.display(%{"v" => true}) == "TRUE"
      assert Cells.display(%{"v" => false}) == "FALSE"
      assert Cells.display(%{"v" => true, "fmt" => "percent"}) == "TRUE"
    end
  end

  describe "checkbox?/1 and aria_checked/1" do
    test "checkbox?/1 is true only for the checkbox fmt" do
      assert Cells.checkbox?(%{"fmt" => "checkbox", "v" => true})
      refute Cells.checkbox?(%{"fmt" => "percent", "v" => 1})
      refute Cells.checkbox?(%{"v" => true})
      refute Cells.checkbox?(nil)
    end

    test "aria_checked/1 reads 'true' only for a boolean true" do
      assert Cells.aria_checked(%{"v" => true}) == "true"
      assert Cells.aria_checked(%{"v" => false}) == "false"
      assert Cells.aria_checked(%{"fmt" => "checkbox"}) == "false"
      assert Cells.aria_checked(%{"v" => 1}) == "false"
    end
  end

  describe "cell_class/5 — checkbox marker" do
    test "a checkbox cell gains the sheet-checkbox class" do
      classes = Cells.cell_class(1, 1, nil, {9, 9}, %{"fmt" => "checkbox", "v" => true})
      assert classes =~ "sheet-checkbox"
    end

    test "a non-checkbox cell does not" do
      refute Cells.cell_class(1, 1, nil, {9, 9}, %{"v" => true}) =~ "sheet-checkbox"
      refute Cells.cell_class(1, 1, nil, {9, 9}, nil) =~ "sheet-checkbox"
    end
  end

  describe "link?/1 — display-time URL detection" do
    test "a whole http(s) URL string reads as a link" do
      assert Cells.link?("http://example.com")
      assert Cells.link?("https://example.com/path?q=1#frag")
      assert Cells.link?("HTTPS://EXAMPLE.COM")
    end

    test "a javascript:/data: payload is NOT a link" do
      refute Cells.link?("javascript:alert(1)")
      refute Cells.link?("data:text/html,<script>alert(1)</script>")
    end

    test "a URL that is only PART of the string is not a link" do
      refute Cells.link?("see http://example.com")
      refute Cells.link?("http://example.com here")
    end

    test "an attribute-breaking payload never matches (quote/space/angle)" do
      refute Cells.link?("http://x\" onmouseover=\"alert-1")
      refute Cells.link?("http://x<script>")
      refute Cells.link?("http://x y")
    end

    test "non-binary and plain text are not links" do
      refute Cells.link?(nil)
      refute Cells.link?(42)
      refute Cells.link?(true)
      refute Cells.link?("just text")
    end
  end

  describe "cell_class/5 — link marker" do
    test "a URL cell gains the sheet-link-cell class" do
      classes = Cells.cell_class(1, 1, nil, {9, 9}, %{"v" => "https://example.com"})
      assert classes =~ "sheet-link-cell"
    end

    test "a plain-text cell does not gain the link marker" do
      refute Cells.cell_class(1, 1, nil, {9, 9}, %{"v" => "hello"}) =~ "sheet-link-cell"

      refute Cells.cell_class(1, 1, nil, {9, 9}, %{"v" => "javascript:alert(1)"}) =~
               "sheet-link-cell"
    end

    test "a checkbox cell is never a link cell even if its value looks urlish" do
      classes =
        Cells.cell_class(1, 1, nil, {9, 9}, %{"fmt" => "checkbox", "v" => "https://x.com"})

      refute classes =~ "sheet-link-cell"
    end
  end

  describe "raw_of/1" do
    test "cell with formula returns '=' prefix followed by formula" do
      assert Cells.raw_of(%{"f" => "A1+B1"}) == "=A1+B1"
    end

    test "formula already starting with '=' is not double-prefixed" do
      assert Cells.raw_of(%{"f" => "=SUM(A1:A5)"}) == "=SUM(A1:A5)"
    end

    test "cell without formula falls through to display" do
      assert Cells.raw_of(%{"v" => "text"}) == "text"
    end

    test "nil cell falls through to display (empty string)" do
      assert Cells.raw_of(nil) == ""
    end
  end

  # QL-D6: the `data-f` td stamp's only source — the stored formula WITHOUT
  # the leading "=", or nil for a literal cell. The client formula clipboard
  # (S-CLIP) reads exactly this off the editable td to rebase formulas through
  # copy/paste; nil MUST omit the attribute (parallel to data_t/1).
  describe "formula/1" do
    test "a formula cell returns the formula sans the leading '='" do
      assert Cells.formula(%{"f" => "=A1+1", "v" => 2}) == "A1+1"
    end

    test "a formula stored WITHOUT a leading '=' returns as-is" do
      assert Cells.formula(%{"f" => "SUM(A1:A5)"}) == "SUM(A1:A5)"
    end

    test "only the FIRST '=' is stripped (an =A1=B1 comparison keeps its inner =)" do
      assert Cells.formula(%{"f" => "=A1=B1"}) == "A1=B1"
    end

    test "a literal cell (no 'f') returns nil" do
      assert Cells.formula(%{"v" => "text"}) == nil
      assert Cells.formula(%{"v" => 7, "t" => "n"}) == nil
    end

    test "nil / empty-map cells return nil" do
      assert Cells.formula(nil) == nil
      assert Cells.formula(%{}) == nil
    end

    test "a blank-or-bare-'=' formula collapses to nil (attribute omitted)" do
      assert Cells.formula(%{"f" => ""}) == nil
      assert Cells.formula(%{"f" => "="}) == nil
    end

    test "a non-binary 'f' is not a formula (nil, never a crash)" do
      assert Cells.formula(%{"f" => nil}) == nil
      assert Cells.formula(%{"f" => 42}) == nil
    end

    test "formula and data_v diverge: the SOURCE vs the computed VALUE" do
      cell = %{"f" => "=1+2", "v" => 3, "t" => "n"}
      assert Cells.formula(cell) == "1+2"
      assert Cells.data_v(cell) == "3"
    end
  end

  describe "fmt raw/display split" do
    # A fmt cell: the visible display formats, but the formula bar (raw_of)
    # and the TSV clipboard (data_v) both round-trip the RAW value so an edit
    # or a paste never sees "25.00%".
    @pct %{"v" => 0.25, "fmt" => "percent"}

    test "display/1 renders the fmt class" do
      assert Cells.display(@pct) == "25.00%"
    end

    test "raw_of/1 returns the raw value, not the formatted display" do
      assert Cells.raw_of(@pct) == "0.25"
    end

    test "data_v/1 returns the raw value for TSV copy" do
      assert Cells.data_v(@pct) == "0.25"
    end

    test "display, raw_of and data_v diverge exactly on a fmt cell" do
      assert Cells.display(@pct) == "25.00%"
      assert Cells.raw_of(@pct) == "0.25"
      assert Cells.data_v(@pct) == "0.25"
    end

    test "a no-fmt float: all three agree with number_to_display" do
      cell = %{"v" => 1_000_000.0}
      expected = Barkpark.Plugins.Sheets.Core.number_to_display(1_000_000.0)
      assert expected == "1000000"
      assert Cells.display(cell) == expected
      assert Cells.raw_of(cell) == expected
      assert Cells.data_v(cell) == expected
    end

    test "a formula fmt cell: display formats, data_v is the raw value, raw_of is the formula" do
      cell = %{"f" => "=A1*B1", "v" => 0.25, "fmt" => "percent"}
      assert Cells.display(cell) == "25.00%"
      assert Cells.data_v(cell) == "0.25"
      assert Cells.raw_of(cell) == "=A1*B1"
    end
  end

  describe "data_t/1 — numeric-value marker" do
    test "an integer value is numeric" do
      assert Cells.data_t(%{"v" => 7}) == "n"
    end

    test "a float value is numeric" do
      assert Cells.data_t(%{"v" => 3.5}) == "n"
    end

    test "a formula whose cached v is a number is numeric (the computed value)" do
      # Formula cells store their computed "v", so a formula yielding a number
      # IS "n" — the marker reads the value, not the presence of a formula.
      assert Cells.data_t(%{"f" => "=A1+B1", "v" => 42}) == "n"
    end

    test "a string value is not numeric (nil omits the attribute)" do
      assert Cells.data_t(%{"v" => "hello"}) == nil
    end

    test "a boolean value is not numeric" do
      assert Cells.data_t(%{"v" => true}) == nil
      assert Cells.data_t(%{"v" => false}) == nil
    end

    test "an empty / absent-value cell is not numeric" do
      assert Cells.data_t(%{}) == nil
      assert Cells.data_t(%{"v" => nil}) == nil
    end

    test "a formula whose cached v is text is not numeric" do
      assert Cells.data_t(%{"f" => "=A1&B1", "v" => "ab"}) == nil
    end

    test ~s(a legacy string-v cell is not numeric even with a "t" => "n" stamp) do
      # Deliberate strictness: the ghost COMMITS on Enter, so data_t never
      # trusts a stored "t" over the value itself. Mainline writers (parse_raw,
      # xlsx/CSV import, engine write-back) all store genuine numbers; the
      # engine still coerces this legacy shape fine at eval time.
      assert Cells.data_t(%{"v" => "7", "t" => "n"}) == nil
    end

    test "an error-value formula cell is not numeric" do
      assert Cells.data_t(%{"f" => "=1/0", "v" => "#DIV/0!", "t" => "e"}) == nil
    end
  end

  describe "bar_value/2" do
    test "returns raw value of the active cell from the cells map" do
      cells = %{"A1" => %{"v" => "hello"}}
      assert Cells.bar_value(cells, {1, 1}) == "hello"
    end

    test "returns formula string when cell has formula" do
      cells = %{"B2" => %{"f" => "SUM(A1:A5)"}}
      assert Cells.bar_value(cells, {2, 2}) == "=SUM(A1:A5)"
    end

    test "returns empty string when active cell is not in map" do
      assert Cells.bar_value(%{}, {1, 1}) == ""
    end
  end

  describe "cell_class/5" do
    # selection rect {c1, c2, r1, r2}
    test "plain cell has only 'sheet-cell' class" do
      assert Cells.cell_class(5, 5, {1, 3, 1, 3}, {9, 9}, nil) == "sheet-cell"
    end

    test "cell within selection rect gets 'sheet-sel' class" do
      result = Cells.cell_class(2, 2, {1, 3, 1, 3}, {9, 9}, nil)
      assert result =~ "sheet-sel"
      assert result =~ "sheet-cell"
    end

    test "active cell gets 'sheet-active' class" do
      result = Cells.cell_class(1, 1, {5, 6, 5, 6}, {1, 1}, nil)
      assert result =~ "sheet-active"
    end

    test "cell with engine error value gets 'sheet-err' class" do
      result = Cells.cell_class(1, 1, {5, 6, 5, 6}, {9, 9}, %{"v" => "#VALUE!"})
      assert result =~ "sheet-err"
    end

    test "cell with #N/A error value gets 'sheet-err' class" do
      result = Cells.cell_class(1, 1, {5, 6, 5, 6}, {9, 9}, %{"v" => "#N/A"})
      assert result =~ "sheet-err"
    end

    test "cell with stale flag gets 'sheet-stale' class" do
      result = Cells.cell_class(1, 1, {5, 6, 5, 6}, {9, 9}, %{"stale" => true})
      assert result =~ "sheet-stale"
    end

    test "a #NAME? cell gets 'sheet-err' like every other engine error" do
      result = Cells.cell_class(1, 1, {5, 6, 5, 6}, {9, 9}, %{"v" => "#NAME?", "t" => "e"})
      assert result =~ "sheet-err"
    end

    # The import-fidelity arm of the unsupported-function ruling: the cell KEEPS
    # its imported value, so it is not an error VALUE — but it must not hide
    # behind the quiet stale dot either. Error-styled AND stale-marked.
    test "an unsupported-function cell that kept its import is error-styled, not just dotted" do
      cell = %{"f" => "=FOO(1)", "v" => 42, "t" => "n", "stale" => true, "stale_fn" => "FOO"}
      result = Cells.cell_class(1, 1, {5, 6, 5, 6}, {9, 9}, cell)

      assert result =~ "sheet-err"
      assert result =~ "sheet-stale"
    end

    test "a bare stale cell with no named function keeps the plain stale marker" do
      result = Cells.cell_class(1, 1, {5, 6, 5, 6}, {9, 9}, %{"v" => "old", "stale" => true})

      assert result =~ "sheet-stale"
      refute result =~ "sheet-err"
    end
  end

  describe "cell_title/1" do
    test "names the function the engine could not evaluate" do
      cell = %{"f" => "=FOO(1)", "v" => 42, "t" => "n", "stale" => true, "stale_fn" => "FOO"}
      assert Cells.cell_title(cell) == "not evaluated: FOO is not supported"
    end

    test "is nil for an ordinary cell, a bare stale cell, and a missing cell" do
      assert Cells.cell_title(%{"v" => 1}) == nil
      assert Cells.cell_title(%{"v" => "old", "stale" => true}) == nil
      assert Cells.cell_title(%{"stale_fn" => ""}) == nil
      assert Cells.cell_title(nil) == nil
    end

    test "normal string value does not get err class" do
      result = Cells.cell_class(1, 1, {5, 6, 5, 6}, {9, 9}, %{"v" => "hello"})
      refute result =~ "sheet-err"
    end

    test "a cell in the find-matches set gets 'sheet-find-hit'" do
      matches = MapSet.new([{2, 3}])
      hit = Cells.cell_class(2, 3, nil, {1, 1}, %{"v" => "found"}, matches)
      miss = Cells.cell_class(2, 4, nil, {1, 1}, %{"v" => "other"}, matches)
      assert hit =~ "sheet-find-hit"
      refute miss =~ "sheet-find-hit"
    end

    test "a nil matches set never adds the hit class (default arg)" do
      refute Cells.cell_class(2, 3, nil, {1, 1}, %{"v" => "x"}) =~ "sheet-find-hit"
    end
  end

  describe "find_matches/2" do
    # A tiny sheet spanning two cells per row so ordering is observable.
    setup do
      cells = %{
        "A1" => %{"v" => "Apple"},
        "B1" => %{"v" => "banana"},
        "A2" => %{"v" => 0.25, "fmt" => "percent"},
        "B2" => %{"f" => "SUM(A1:A1)", "v" => "0"},
        "A3" => %{"v" => "apricot"}
      }

      %{cells: cells}
    end

    test "case-insensitive substring against the RAW value", %{cells: cells} do
      # "ap" matches Apple (A1) and apricot (A3), regardless of case.
      assert Cells.find_matches(cells, "ap") == [{1, 1}, {1, 3}]
      assert Cells.find_matches(cells, "AP") == [{1, 1}, {1, 3}]
    end

    test "matches the fmt DISPLAY too (25.00%), not just the raw 0.25", %{cells: cells} do
      # A2's raw is 0.25 but the user sees 25.00% — searching "25.00%" must hit.
      assert Cells.find_matches(cells, "25.00%") == [{1, 2}]
      # And the raw underlying value is still findable.
      assert Cells.find_matches(cells, "0.25") == [{1, 2}]
    end

    test "matches the '=formula' raw of a formula cell", %{cells: cells} do
      # B2's raw_of is "=SUM(A1:A1)"; searching "=SUM" hits it.
      assert Cells.find_matches(cells, "=SUM") == [{2, 2}]
    end

    test "results are ordered row-major (top-to-bottom, left-to-right)" do
      cells = %{
        "B2" => %{"v" => "x"},
        "A2" => %{"v" => "x"},
        "C1" => %{"v" => "x"},
        "A1" => %{"v" => "x"}
      }

      assert Cells.find_matches(cells, "x") == [{1, 1}, {3, 1}, {1, 2}, {2, 2}]
    end

    test "a blank or whitespace query yields no matches", %{cells: cells} do
      assert Cells.find_matches(cells, "") == []
      assert Cells.find_matches(cells, "   ") == []
    end

    test "a non-binary query is safe and yields no matches", %{cells: cells} do
      assert Cells.find_matches(cells, nil) == []
    end
  end

  describe "next_match/3" do
    test "empty list returns nil regardless of direction" do
      assert Cells.next_match([], {1, 1}, :next) == nil
      assert Cells.next_match([], {1, 1}, :prev) == nil
    end

    test "next finds the first match strictly after the active cell (row-major)" do
      ordered = [{1, 1}, {3, 1}, {1, 2}]
      assert Cells.next_match(ordered, {1, 1}, :next) == {3, 1}
      assert Cells.next_match(ordered, {3, 1}, :next) == {1, 2}
    end

    test "next wraps from the last match back to the first" do
      ordered = [{1, 1}, {3, 1}, {1, 2}]
      assert Cells.next_match(ordered, {1, 2}, :next) == {1, 1}
      # Active past the end also wraps.
      assert Cells.next_match(ordered, {9, 9}, :next) == {1, 1}
    end

    test "prev finds the match strictly before the active cell" do
      ordered = [{1, 1}, {3, 1}, {1, 2}]
      assert Cells.next_match(ordered, {1, 2}, :prev) == {3, 1}
      assert Cells.next_match(ordered, {3, 1}, :prev) == {1, 1}
    end

    test "prev wraps from the first match back to the last" do
      ordered = [{1, 1}, {3, 1}, {1, 2}]
      assert Cells.next_match(ordered, {1, 1}, :prev) == {1, 2}
    end
  end

  describe "cell_dom_id/2" do
    test "builds a stable per-cell id from the table id and the {c, r}" do
      assert Cells.cell_dom_id("sheet-grid-q3", {2, 5}) == "sheet-grid-q3-cell-2-5"
    end

    test "the active cell id matches the id stamped on that cell" do
      assert Cells.cell_dom_id("t", {1, 1}) == "t-cell-1-1"
    end
  end

  describe "aria_selected/3" do
    # sel rect is {c1, c2, r1, r2} — the same shape cell_class consumes.
    test "cell inside the sel rect is aria-selected true" do
      assert Cells.aria_selected({1, 3, 1, 3}, 2, 2) == "true"
    end

    test "cell on the sel-rect boundary is aria-selected true" do
      assert Cells.aria_selected({1, 3, 1, 3}, 3, 1) == "true"
    end

    test "cell outside the sel rect is aria-selected false" do
      assert Cells.aria_selected({1, 3, 1, 3}, 5, 5) == "false"
    end

    test "nil sel is aria-selected false (never crashes)" do
      assert Cells.aria_selected(nil, 1, 1) == "false"
    end

    test "shares cell_class's predicate: aria_selected true iff sheet-sel present" do
      sel = {2, 4, 2, 4}

      for c <- 1..6, r <- 1..6 do
        selected? = Cells.cell_class(c, r, sel, {0, 0}, nil) =~ "sheet-sel"
        assert Cells.aria_selected(sel, c, r) == if(selected?, do: "true", else: "false")
      end
    end
  end

  describe "sel_stats/2" do
    # rect is {c1, c2, r1, r2} (Geometry.selection_rect's shape).
    test "single-cell rect returns nil (nothing to aggregate)" do
      assert Cells.sel_stats(%{"A1" => %{"v" => 10}}, {1, 1, 1, 1}) == nil
    end

    test "a range with no numeric cells returns nil" do
      cells = %{"A1" => %{"v" => "x"}, "A2" => %{"v" => "y"}}
      assert Cells.sel_stats(cells, {1, 1, 1, 2}) == nil
    end

    test "aggregates only numeric cells; text/bool/#N-A excluded" do
      cells = %{
        "A1" => %{"v" => 10},
        "A2" => %{"v" => 30},
        "A3" => %{"v" => "x"},
        "A4" => %{"v" => true},
        "A5" => %{"v" => "#N/A"}
      }

      assert Cells.sel_stats(cells, {1, 1, 1, 5}) == %{sum: 40, avg: 20.0, count: 2}
    end

    test "refs outside the rect are excluded" do
      cells = %{"A1" => %{"v" => 10}, "B1" => %{"v" => 5}, "A2" => %{"v" => 30}}
      # rect covers column A rows 1..2 only — B1 is out.
      assert Cells.sel_stats(cells, {1, 1, 1, 2}) == %{sum: 40, avg: 20.0, count: 2}
    end

    test "large whole-float sum renders plain, not scientific" do
      cells = %{"A1" => %{"v" => 1_000_000.0}, "A2" => %{"v" => 1_500_000.0}}
      stats = Cells.sel_stats(cells, {1, 1, 1, 2})
      assert stats.sum == 2_500_000.0
      assert Barkpark.Plugins.Sheets.Core.number_to_display(stats.sum) == "2500000"
      refute Barkpark.Plugins.Sheets.Core.number_to_display(stats.sum) =~ "e"
    end
  end

  describe "cell_style/7" do
    test "non-frozen cell with no inline style returns nil" do
      assert Cells.cell_style(3, 3, 0, 0, %{}, %{}, nil) == nil
    end

    test "frozen column cell gets sticky left style" do
      style = Cells.cell_style(1, 3, 1, 0, %{}, %{}, nil)
      assert is_binary(style)
      assert style =~ "position: sticky"
      assert style =~ "left:"
    end

    test "frozen row cell gets sticky top style" do
      style = Cells.cell_style(3, 1, 0, 1, %{}, %{}, nil)
      assert is_binary(style)
      assert style =~ "position: sticky"
      assert style =~ "top:"
    end

    test "corner cell (frozen col + row) gets both left and top" do
      style = Cells.cell_style(1, 1, 1, 1, %{}, %{}, nil)
      assert style =~ "left:"
      assert style =~ "top:"
      assert style =~ "z-index: 2"
    end

    test "cell with bold style appends font-weight" do
      style = Cells.cell_style(3, 3, 0, 0, %{}, %{}, %{"s" => %{"b" => true}})
      assert style =~ "font-weight: 600"
    end

    test "cell with valid hex background gets background style" do
      style = Cells.cell_style(3, 3, 0, 0, %{}, %{}, %{"s" => %{"bg" => "#ff0000"}})
      assert style =~ "background: #ff0000"
    end

    test "cell with invalid hex background is ignored" do
      style = Cells.cell_style(3, 3, 0, 0, %{}, %{}, %{"s" => %{"bg" => "red"}})
      assert style == nil
    end

    test "a hex background with a trailing newline is REJECTED (no CSS-attr stowaway)" do
      # `#rrggbb\n` passes the old `$`-anchored copy but is rejected by the
      # canonical `\z` owner (CondFormat.valid_bg?/1) this path now delegates to,
      # so the newline can never land in the inline `style` attribute.
      style = Cells.cell_style(3, 3, 0, 0, %{}, %{}, %{"s" => %{"bg" => "#aabbcc\n"}})
      assert style == nil
      refute is_binary(style) and style =~ "background"
    end

    test "cell with text-align returns alignment style" do
      style = Cells.cell_style(3, 3, 0, 0, %{}, %{}, %{"s" => %{"al" => "center"}})
      assert style =~ "text-align: center"
    end
  end

  describe "cell_style/8 — conditional-format compose (CF-C stage A)" do
    # The whole point of stage A: a nil cf must be byte-identical to today, and
    # a present cf composes per CF-D3 (CF wins bg/b/i; manual keeps al).
    test "a nil cf is byte-identical to the manual-only /7 path" do
      for cell <- [
            nil,
            %{"s" => %{"b" => true}},
            %{"s" => %{"bg" => "#ff0000", "al" => "center"}},
            %{"v" => 42}
          ] do
        assert Cells.cell_style(3, 3, 0, 0, %{}, %{}, cell) ==
                 Cells.cell_style(3, 3, 0, 0, %{}, %{}, cell, nil)
      end
    end

    test "CF bg wins over the manual bg; the manual al survives" do
      cell = %{"s" => %{"bg" => "#000000", "al" => "center"}}
      style = Cells.cell_style(3, 3, 0, 0, %{}, %{}, cell, %{"bg" => "#ff0000"})

      assert style =~ "background: #ff0000"
      refute style =~ "background: #000000"
      assert style =~ "text-align: center"
    end

    test "b/i compose from either side (manual b kept, CF i added)" do
      cell = %{"s" => %{"b" => true}}
      style = Cells.cell_style(3, 3, 0, 0, %{}, %{}, cell, %{"bg" => "#bbf7d0", "i" => true})

      assert style =~ "font-weight: 600"
      assert style =~ "font-style: italic"
      assert style =~ "background: #bbf7d0"
    end

    test "CF applies to an occupied cell that has NO manual style" do
      style = Cells.cell_style(3, 3, 0, 0, %{}, %{}, %{"v" => 5}, %{"bg" => "#fde68a"})
      assert style =~ "background: #fde68a"
    end

    # CF-AM2 + the Cells.cell_style/8 ordering: on a frozen (sticky) cell the CF bg
    # is appended AFTER the sticky "background: var(--bg)" backdrop so it wins.
    test "CF composes on a frozen cell, its bg appended after the sticky backdrop" do
      style = Cells.cell_style(1, 1, 1, 1, %{}, %{}, %{"v" => 5}, %{"bg" => "#ff0000"})

      assert style =~ "position: sticky"
      {sticky_at, _} = :binary.match(style, "background: var(--bg);")
      {cf_at, _} = :binary.match(style, "background: #ff0000")
      assert cf_at > sticky_at
    end
  end

  describe "cell_class/6 — default alignment class (no explicit s.al)" do
    # A CLASS, not an inline style, on purpose: the sheets-parity suite pins
    # the inline b/i/bg/al styles identical across every render surface, so
    # the derived default must never leak into cell_style's output.
    test "a number cell gets sheet-al-right by default" do
      assert Cells.cell_class(3, 3, nil, {9, 9}, %{"v" => 42}) =~ "sheet-al-right"
      assert Cells.cell_class(3, 3, nil, {9, 9}, %{"v" => 3.14}) =~ "sheet-al-right"
    end

    test "a number-shaped fmt right-aligns even when the value is non-numeric" do
      for fmt <- ["currency", "percent", "thousands", "fixed", "date", "datetime"] do
        classes = Cells.cell_class(3, 3, nil, {9, 9}, %{"v" => "x", "fmt" => fmt})
        assert classes =~ "sheet-al-right", "fmt #{fmt} did not right-align"
      end
    end

    test "an explicit s.al suppresses the class and keeps winning as inline style" do
      cell = %{"v" => 42, "s" => %{"al" => "left"}}
      refute Cells.cell_class(3, 3, nil, {9, 9}, cell) =~ "sheet-al-"
      style = Cells.cell_style(3, 3, 0, 0, %{}, %{}, cell)
      assert style =~ "text-align: left"
      refute style =~ "text-align: right"
    end

    test "a checkbox cell and a bare boolean get sheet-al-center" do
      assert Cells.cell_class(3, 3, nil, {9, 9}, %{"fmt" => "checkbox", "v" => true}) =~
               "sheet-al-center"

      assert Cells.cell_class(3, 3, nil, {9, 9}, %{"v" => false}) =~ "sheet-al-center"
    end

    test "a text cell gets NO alignment class (inherits the table's left)" do
      refute Cells.cell_class(3, 3, nil, {9, 9}, %{"v" => "hello"}) =~ "sheet-al-"
      refute Cells.cell_class(3, 3, nil, {9, 9}, nil) =~ "sheet-al-"
    end

    test "the default never leaks into cell_style's inline output (parity seal)" do
      # sheets_parity_test extracts text-align from the INLINE styles across
      # all surfaces — a derived inline default would break A↔B↔C↔D↔F parity.
      assert Cells.cell_style(3, 3, 0, 0, %{}, %{}, %{"v" => 42}) == nil

      style = Cells.cell_style(3, 3, 0, 0, %{}, %{}, %{"v" => 1, "s" => %{"b" => true}})
      assert style =~ "font-weight: 600"
      refute style =~ "text-align"
    end
  end

  # Every affordance class the grid stamps must have a real CSS rule in the
  # layout style blocks — sheet-find-hit et al. shipped class-only (invisible)
  # once already. A pure source-presence check: cheap, and it reds the moment
  # a rule is dropped or a selector is renamed on only one side.
  describe "affordance classes have CSS rules in the layout style blocks" do
    @root_layout Path.expand(
                   "../../../../../lib/barkpark_web/layouts/root.html.heex",
                   __DIR__
                 )
    @reader_layout Path.expand(
                     "../../../../../lib/barkpark_web/layouts/sheets.html.heex",
                     __DIR__
                   )

    test "Studio (root.html.heex) styles every stamped affordance class" do
      css = File.read!(@root_layout)

      for sel <- [
            ".sheet-fmt-group, .sheet-style-group {",
            ".sheet-bg-swatches {",
            ".sheet-bg-swatch {",
            ".sheet-bg-swatch:focus-visible {",
            ".sheet-find {",
            ".sheet-cell.sheet-find-hit {",
            ".sheet-cell.sheet-sel.sheet-find-hit {",
            ".sheet-cell.sheet-checkbox .sheet-cell-v {",
            ".sheet-cell.sheet-al-right {",
            ".sheet-cell.sheet-al-center {"
          ] do
        assert css =~ sel, "root.html.heex is missing a rule for `#{sel}`"
      end
    end

    test "a find hit composed with the selection stays visible (background re-asserted)" do
      css = File.read!(@root_layout)

      assert css =~
               ~r/\.sheet-cell\.sheet-sel\.sheet-find-hit \{[^}]*background:[^}]*rgba\(250, 204, 21/s
    end

    test "the Studio grid uses tabular numerals" do
      assert File.read!(@root_layout) =~
               ~r/\.sheet-table \{[^}]*font-variant-numeric: tabular-nums/s
    end

    test "the reader mirror (sheets.html.heex) carries tabular-nums + the find + align rules" do
      css = File.read!(@reader_layout)
      assert css =~ ~r/\.sheet-table \{[^}]*font-variant-numeric: tabular-nums/s
      assert css =~ ".sheet-find {"
      assert css =~ ".sheet-cell.sheet-find-hit {"
      assert css =~ ".sheet-cell.sheet-al-right {"
      assert css =~ ".sheet-cell.sheet-al-center {"
    end
  end

  describe "col_head_style/3" do
    test "frozen column returns sticky left style string" do
      style = Cells.col_head_style(1, 2, %{})
      assert is_binary(style)
      assert style =~ "left:"
      assert style =~ "z-index: 5"
    end

    test "non-frozen column returns nil" do
      assert Cells.col_head_style(5, 2, %{}) == nil
    end
  end

  describe "row_head_style/3" do
    test "frozen row returns sticky top style string" do
      style = Cells.row_head_style(1, 2, %{})
      assert is_binary(style)
      assert style =~ "top:"
      assert style =~ "z-index: 5"
    end

    test "non-frozen row returns nil" do
      assert Cells.row_head_style(5, 2, %{}) == nil
    end
  end
end
