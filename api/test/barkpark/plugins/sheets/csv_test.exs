defmodule Barkpark.Plugins.Sheets.CsvTest do
  @moduledoc """
  M5 CSV/TSV conversion locks — RFC-4180 parsing edges, single-tab import
  with type inference, per-tab values-only export, and the text → content →
  text round trip. Pure unit tests, no DB.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Sheets.Csv

  # ── parse/2 ─────────────────────────────────────────────────────────────────

  describe "parse/2" do
    test "plain rows, CRLF and LF line endings, optional trailing newline" do
      assert Csv.parse("a,b\r\nc,d\r\n") == {:ok, [["a", "b"], ["c", "d"]]}
      assert Csv.parse("a,b\nc,d") == {:ok, [["a", "b"], ["c", "d"]]}
    end

    test "quoted fields carry separators, escaped quotes and line breaks" do
      assert Csv.parse(~s("a,b",plain\r\n)) == {:ok, [["a,b", "plain"]]}
      assert Csv.parse(~s("say ""hi""",x\r\n)) == {:ok, [[~s(say "hi"), "x"]]}
      assert Csv.parse(~s("line1\r\nline2",x\r\n)) == {:ok, [["line1\r\nline2", "x"]]}
    end

    test "empty fields and empty trailing field" do
      assert Csv.parse("a,,c\r\n") == {:ok, [["a", "", "c"]]}
      assert Csv.parse("a,b,\r\n") == {:ok, [["a", "b", ""]]}
    end

    test "an unterminated quoted field is an error" do
      assert {:error, message} = Csv.parse(~s("never closed))
      assert message =~ "unterminated"
    end

    test "tab separator parses TSV (commas stay literal)" do
      assert Csv.parse("a,x\tb\r\n", "\t") == {:ok, [["a,x", "b"]]}
    end

    test "non-UTF-8 bytes reject cleanly instead of raising" do
      # 0xE9 is 'é' in Windows-1252 — not a valid UTF-8 start byte. Excel on
      # Western-European Windows writes this; it must 422, not 500.
      assert {:error, _} = Csv.parse(<<?a, 0xE9, ?b>>)
    end
  end

  # ── normalize_encoding/1 ─────────────────────────────────────────────────────

  describe "normalize_encoding/1" do
    test "valid UTF-8 passes through untouched" do
      assert Csv.normalize_encoding("a,b\r\né\r\n") == {:ok, "a,b\r\né\r\n"}
    end

    test "UTF-16LE with BOM transcodes to UTF-8" do
      utf16 = :unicode.characters_to_binary("a,b\r\nc,d\r\n", :utf8, {:utf16, :little})
      assert {:ok, "a,b\r\nc,d\r\n"} = Csv.normalize_encoding(<<0xFF, 0xFE>> <> utf16)
    end

    test "UTF-16BE with BOM transcodes to UTF-8" do
      utf16 = :unicode.characters_to_binary("hi\tthere", :utf8, {:utf16, :big})
      assert {:ok, "hi\tthere"} = Csv.normalize_encoding(<<0xFE, 0xFF>> <> utf16)
    end

    test "an odd-byte-length UTF-16 stream errors (surfaces as 422 later)" do
      # BOM + one dangling byte — no complete 16-bit unit follows.
      assert {:error, _} = Csv.normalize_encoding(<<0xFF, 0xFE, 0x41>>)
    end

    test "latin1 high byte falls back to Windows-1252 (0xE9 → é)" do
      assert {:ok, "café"} = Csv.normalize_encoding(<<?c, ?a, ?f, 0xE9>>)
    end

    test "Windows-1252 control-range byte maps via the cp1252 table (0x80 → €)" do
      assert {:ok, "€1"} = Csv.normalize_encoding(<<0x80, ?1>>)
    end
  end

  # ── sniff_separator/2 ─────────────────────────────────────────────────────────

  describe "sniff_separator/2" do
    test "detects a semicolon-delimited European file" do
      assert Csv.sniff_separator("Name;Price\r\nWidget;1,5\r\nGadget;2,0\r\n", ",") == ";"
    end

    test "a quoted comma-carrying field does not flip a comma file to semicolon" do
      text = ~s(name,note\r\nx,"a;b"\r\ny,"c;d"\r\n)
      assert Csv.sniff_separator(text, ",") == ","
    end

    test "a single-column file has no signal and falls back to the extension default" do
      assert Csv.sniff_separator("alpha\r\nbeta\r\ngamma\r\n", ",") == ","
      assert Csv.sniff_separator("alpha\r\nbeta\r\ngamma\r\n", "\t") == "\t"
    end

    test "a tab file sniffs to tab" do
      assert Csv.sniff_separator("a\tb\tc\r\nd\te\tf\r\n", ",") == "\t"
    end
  end

  # ── import_content/2 ────────────────────────────────────────────────────────

  describe "import_content/2" do
    test "builds a single tab with typed cells; empty fields skip" do
      {:ok, content} = Csv.import_content("Name,Score\r\nAlice,42\r\nBob,2.5\r\n,\r\n")

      assert [%{"name" => "Sheet1", "cells" => cells}] = content["tabs"]

      assert cells == %{
               "A1" => %{"v" => "Name"},
               "B1" => %{"v" => "Score"},
               "A2" => %{"v" => "Alice"},
               "B2" => %{"v" => 42},
               "A3" => %{"v" => "Bob"},
               "B3" => %{"v" => 2.5}
             }
    end

    test "empty input builds an empty tab" do
      assert Csv.import_content("") == {:ok, %{"tabs" => [%{"name" => "Sheet1"}]}}
    end

    test "semicolon dialect splits fields and infers decimal-comma numbers" do
      {:ok, content} = Csv.import_content("Widget;1,5\r\n", ";")

      assert [%{"cells" => cells}] = content["tabs"]
      assert cells == %{"A1" => %{"v" => "Widget"}, "B1" => %{"v" => 1.5}}
    end

    test "decimal-comma inference is off for comma/tab dialects" do
      # "1,5" only reaches infer intact under a non-comma separator.
      {:ok, content} = Csv.import_content("1,5\r\n", "\t")
      assert [%{"cells" => %{"A1" => %{"v" => "1,5"}}}] = content["tabs"]
    end

    test "leading-zero runs stay strings; real numbers still infer" do
      {:ok, content} = Csv.import_content("007,00501,0,0.5,-0.7\r\n")

      assert [%{"cells" => cells}] = content["tabs"]

      assert cells == %{
               "A1" => %{"v" => "007"},
               "B1" => %{"v" => "00501"},
               "C1" => %{"v" => 0},
               "D1" => %{"v" => 0.5},
               "E1" => %{"v" => -0.7}
             }
    end

    test "case-insensitive TRUE/FALSE infer to booleans" do
      {:ok, content} = Csv.import_content("TRUE,false,True,maybe\r\n")

      assert [%{"cells" => cells}] = content["tabs"]

      assert cells == %{
               "A1" => %{"v" => true},
               "B1" => %{"v" => false},
               "C1" => %{"v" => true},
               "D1" => %{"v" => "maybe"}
             }
    end

    test "non-UTF-8 bytes reject cleanly instead of raising" do
      assert {:error, _} = Csv.import_content(<<?a, 0xE9>>, ",")
    end

    test "more than the cell cap aborts the fold early, reporting the true count at the halt" do
      # 16_667 rows × 3 columns = 50_001 non-empty cells; the fold halts
      # on the cell that tips the cap, so the running count is cap + 1
      csv = String.duplicate("a,b,c\r\n", 16_667)
      assert Csv.import_content(csv) == {:error, {:cell_cap_exceeded, 50_001}}
    end

    test "fields beyond column XFD clip (gate-legal by construction)" do
      # 16_384 commas → field 16_384 ("x") lands ON XFD, field 16_385 ("y") drops
      csv = String.duplicate(",", 16_383) <> "x,y\r\n"
      {:ok, content} = Csv.import_content(csv)

      assert [%{"name" => "Sheet1", "cells" => cells}] = content["tabs"]
      assert cells == %{"XFD1" => %{"v" => "x"}}
    end

    test "lines beyond row 1_048_576 clip (gate-legal by construction)" do
      csv = String.duplicate("\n", 1_048_575) <> "kept\ndropped"
      {:ok, content} = Csv.import_content(csv)

      assert [%{"name" => "Sheet1", "cells" => cells}] = content["tabs"]
      assert cells == %{"A1048576" => %{"v" => "kept"}}
    end
  end

  # ── export/3 ────────────────────────────────────────────────────────────────

  describe "export/3" do
    setup do
      content = %{
        "tabs" => [
          %{
            "name" => "First",
            "frozen_rows" => 1,
            "cells" => %{
              "A1" => %{"v" => "Name"},
              "B1" => %{"v" => "Note"},
              "A2" => %{"v" => "Alice"},
              "B2" => %{"v" => ~s(said "hi", twice)},
              "A3" => %{"v" => 42},
              "B3" => %{"f" => "A3+1", "v" => 43, "t" => "n"}
            }
          },
          %{"name" => "Second", "cells" => %{"A1" => %{"v" => "tab two"}}}
        ]
      }

      {:ok, content: content}
    end

    test "values only, RFC quoting, frozen head re-attached as first row", %{content: content} do
      assert {:ok, csv} = Csv.export(content, 0, ",")

      assert csv ==
               "Name,Note\r\n" <>
                 ~s(Alice,"said ""hi"", twice"\r\n) <>
                 "42,43\r\n"
    end

    test "?tab selects the tab; out of range is :tab_not_found", %{content: content} do
      assert {:ok, "tab two\r\n"} = Csv.export(content, 1, ",")
      assert Csv.export(content, 7, ",") == {:error, :tab_not_found}
    end

    test "tsv quotes on tabs instead of commas", %{content: content} do
      assert {:ok, tsv} = Csv.export(content, 0, "\t")
      assert tsv =~ "Name\tNote\r\n"
      # the comma-carrying field needs no quotes in TSV; the quote still escapes
      assert tsv =~ ~s("said ""hi"", twice")
    end

    test "an empty tab exports to an empty string" do
      assert Csv.export(%{"tabs" => [%{"name" => "Empty"}]}, 0, ",") == {:ok, ""}
    end

    # #NAME? is an error VALUE like every other `t: "e"` code — the exporter
    # writes the cell's "v" verbatim, so the error survives the round trip
    # instead of exporting as a blank the reader would read as a real gap.
    test "a #NAME? cell exports as the error string" do
      content = %{
        "tabs" => [
          %{
            "name" => "T",
            "cells" => %{
              "A1" => %{"v" => "Label"},
              "A2" => %{"f" => "=FOO(1)", "v" => "#NAME?", "t" => "e"}
            }
          }
        ]
      }

      assert {:ok, csv} = Csv.export(content, 0, ",")
      assert csv =~ "#NAME?"
    end

    test "formula-looking TEXT values are neutralized (CSV injection guard)" do
      content = %{
        "tabs" => [
          %{
            "name" => "Inject",
            "cells" => %{
              "A1" => %{"v" => "=SUM(A1)"},
              "B1" => %{"v" => "@foo"},
              "C1" => %{"v" => "+cmd|'/C calc'!A0"},
              "A2" => %{"v" => "-5"},
              "B2" => %{"v" => "hello"},
              "C2" => %{"v" => 5}
            }
          }
        ]
      }

      assert {:ok, csv} = Csv.export(content, 0, ",")

      # leading `=`/`@`/`+` get an apostrophe prefix (OWASP mitigation)
      assert csv =~ "'=SUM(A1)"
      assert csv =~ "'@foo"
      assert csv =~ "'+cmd|'/C calc'!A0"
      # a negative number and a normal string are left untouched
      assert csv =~ "-5"
      refute csv =~ "'-5"
      assert csv =~ "hello"
      refute csv =~ "'hello"
      # a positive number never serializes with a leading `+`, so it stays raw
      assert csv =~ "5"
      refute csv =~ "'5"
      refute csv =~ "+5"
    end

    test "a sparse-extremes sheet exports within the snapshot row bound" do
      content = %{
        "tabs" => [
          %{"name" => "Wide", "cells" => %{"A1" => %{"v" => "a"}, "CV1500000" => %{"v" => "z"}}}
        ]
      }

      assert {:ok, csv} = Csv.export(content, 0, ",")
      # CV = col 100 → the dense snapshot truncates to 200_000 / 100 rows
      assert csv |> String.split("\r\n", trim: true) |> length() == 2_000
    end
  end

  # ── injection-guard inverse (import strips the export apostrophe) ──────────

  describe "injection-guard round trip" do
    test "guarded text round-trips export → import without gaining an apostrophe" do
      content = %{
        "tabs" => [
          %{
            "name" => "Contacts",
            "cells" => %{
              "A1" => %{"v" => "+47 99887766"},
              "B1" => %{"v" => "=not a formula"}
            }
          }
        ]
      }

      assert {:ok, csv} = Csv.export(content, 0, ",")
      # the file bytes still carry the guard (export behavior unchanged)
      assert csv == "'+47 99887766,'=not a formula\r\n"

      assert {:ok, reimported} = Csv.import_content(csv)
      assert [%{"cells" => cells}] = reimported["tabs"]

      assert cells == %{
               "A1" => %{"v" => "+47 99887766"},
               "B1" => %{"v" => "=not a formula"}
             }
    end

    test "a stored already-escaped value survives one export+import cycle" do
      content = %{
        "tabs" => [%{"name" => "S", "cells" => %{"A1" => %{"v" => "'=already-escaped"}}}]
      }

      assert {:ok, csv} = Csv.export(content, 0, ",")
      # export adds one more marker so the import strip lands back on the original
      assert csv == "''=already-escaped\r\n"

      assert {:ok, reimported} = Csv.import_content(csv)
      assert [%{"cells" => %{"A1" => %{"v" => "'=already-escaped"}}}] = reimported["tabs"]
    end

    test "text starting with an apostrophe NOT followed by a trigger is untouched" do
      {:ok, content} = Csv.import_content("'hello,'twas the night\r\n")

      assert [%{"cells" => cells}] = content["tabs"]
      assert cells == %{"A1" => %{"v" => "'hello"}, "B1" => %{"v" => "'twas the night"}}
    end
  end

  # ── round trip ──────────────────────────────────────────────────────────────

  test "csv text → content → csv text round-trips" do
    original = "Name,Score\r\nAlice,42\r\n\"a,b\",2.5\r\n"

    {:ok, content} = Csv.import_content(original)
    {:ok, exported} = Csv.export(content, 0, ",")

    assert exported == original
  end

  test "booleans round-trip as Excel-uppercase TRUE/FALSE" do
    {:ok, content} = Csv.import_content("TRUE,false\r\n")
    assert {:ok, "TRUE,FALSE\r\n"} = Csv.export(content, 0, ",")
  end

  # QR-D critic regression lock — the documented-lossy formula contract as ONE
  # greppable pin. The :215 export test proves a formula cell serializes its
  # cached VALUE (never "=…"); the :339 round-trip proves plain values survive
  # a full text→content→text cycle. Neither pins the LOSS itself: a formula that
  # round-trips must come back a PLAIN value (no "f" key), and re-exporting the
  # re-imported content must be byte-identical to the first export — i.e. the
  # formula was dropped once on the FIRST export and the pipeline is now a fixed
  # point. A regression that ever re-emitted the formula text (`=A1+1`) or kept
  # an "f" key on import would red here.
  test "documented-lossy: a formula cell exports its cached value, re-imports as a plain value, re-exports byte-identical" do
    content = %{
      "tabs" => [
        %{
          "name" => "Formulas",
          "cells" => %{
            "A1" => %{"v" => 42},
            "B1" => %{"f" => "A1+1", "v" => 43, "t" => "n"}
          }
        }
      ]
    }

    assert {:ok, csv} = Csv.export(content, 0, ",")
    # values only: the formula's cached value serializes, never the "=A1+1" text
    assert csv == "42,43\r\n"

    # re-importing the exported text loses the formula — CSV carries no formulas,
    # so the round-tripped cell is a plain value with NO "f" key (lossy contract)
    assert {:ok, reimported} = Csv.import_content(csv)
    assert [%{"cells" => cells}] = reimported["tabs"]
    assert cells == %{"A1" => %{"v" => 42}, "B1" => %{"v" => 43}}
    refute Map.has_key?(cells["B1"], "f")

    # the pipeline is a fixed point: re-exporting the re-import is byte-identical
    assert {:ok, csv2} = Csv.export(reimported, 0, ",")
    assert csv2 == csv
  end
end
