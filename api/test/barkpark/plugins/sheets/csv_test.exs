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

  # ── round trip ──────────────────────────────────────────────────────────────

  test "csv text → content → csv text round-trips" do
    original = "Name,Score\r\nAlice,42\r\n\"a,b\",2.5\r\n"

    {:ok, content} = Csv.import_content(original)
    {:ok, exported} = Csv.export(content, 0, ",")

    assert exported == original
  end
end
