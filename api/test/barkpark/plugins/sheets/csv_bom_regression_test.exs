defmodule Barkpark.Plugins.Sheets.CsvBomRegressionTest do
  @moduledoc """
  M5 skeptic probe kept as a regression bar: `parse/2` strips a single
  leading UTF-8 BOM (`\\uFEFF`) — Excel's "CSV UTF-8" export always writes
  one. Without the strip, two failures fall out:

    1. the BOM glues onto the first field's value, and
    2. worse — a quote only OPENS a quoted field when the accumulated field
       is `""` (csv.ex `parse_rows(<<?", …>>, sep, "", …)`), so a BOM before
       a quoted first field defeats quoting entirely and a comma INSIDE the
       quotes splits the field:

           "\\uFEFF\\"a,b\\",c"  parses as  [["\\uFEFF\\"a", "b\\"", "c"]]
                                 instead of [["a,b", "c"]]
  """

  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Sheets.Csv

  @bom "﻿"

  test "parse/2 strips a UTF-8 BOM before an unquoted first field" do
    assert Csv.parse(@bom <> "a,b\r\nc,d\r\n", ",") == {:ok, [["a", "b"], ["c", "d"]]}
  end

  test "parse/2 strips a UTF-8 BOM before a QUOTED first field (quote must still open)" do
    assert Csv.parse(@bom <> "\"a,b\",c\r\nx,y\r\n", ",") == {:ok, [["a,b", "c"], ["x", "y"]]}
  end

  test "import_content/2 does not leak the BOM into cell A1" do
    {:ok, %{"tabs" => [tab]}} = Csv.import_content(@bom <> "hello,world\r\n", ",")

    assert tab["cells"]["A1"] == %{"v" => "hello"}
    assert tab["cells"]["B1"] == %{"v" => "world"}
  end
end
