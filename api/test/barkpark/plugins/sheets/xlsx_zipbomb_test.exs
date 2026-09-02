defmodule Barkpark.Plugins.Sheets.XlsxZipbombTest do
  @moduledoc """
  Decompression-bomb guard for the xlsx import parse path (Felix W14, slice C1).

  Pure unit tests, no DB. An xlsx IS a zip archive, and both readers over the
  bytes — `XlsxReader.open` (`open_package/1`) and the raw
  `:zip.extract(binary, [:memory])` in `parse_layout/1` — FULLY inflate the
  members they touch, UPSTREAM of every cell/merge/grid cap. A ~1.45 MiB archive
  can materialise ~400 MiB before `cell_cap/0` is ever consulted, and the import
  controller's 15 MB byte cap bounds only the COMPRESSED on-disk size.

  `to_content/1` therefore carries a pre-extract ceiling: `:zip.list_dir/1`
  reports each member's DECLARED uncompressed size straight from the zip central
  directory WITHOUT inflating, and the guard rejects with
  `{:error, :xlsx_decompressed_size_exceeded}` before either reader runs.

  ## Mutation proof (how the RED-BEFORE was captured)

  Neuter the guard — replace `guard_decompressed_size/1`'s body with a bare
  `:ok` (or delete the `:ok <- guard_decompressed_size(binary)` clause from the
  `with` in `to_content/1`) — and the two bomb tests below turn RED: the bomb
  fully inflates its declared-huge member and `to_content/1` returns `{:ok, _}`
  (or OOMs), never the bounded error atom. Restoring the guard turns them GREEN.
  `bomb ratio is real` pins the attack quantitatively regardless of the guard.

  `async: false`: the ceiling-override tests mutate `Application` env (the
  charter keeps Application-env mutators serial).
  """
  use ExUnit.Case, async: false

  alias Barkpark.Plugins.Sheets.XlsxImport
  alias Elixlsx.{Sheet, Workbook}

  # A member large enough to dwarf a low test ceiling yet cheap to build: 16 MiB
  # of zeros deflates to a few KB, so the on-disk archive stays tiny (the whole
  # point of a decompression bomb).
  @bloat_bytes 16 * 1024 * 1024
  # A test ceiling well under the 16 MiB member but above the base xlsx, so the
  # guard fires on the bomb and NOT on a legitimate sheet.
  @test_ceiling 4 * 1024 * 1024

  defp valid_xlsx do
    {:ok, {_name, binary}} =
      Elixlsx.write_to_memory(
        %Workbook{sheets: [%Sheet{name: "Data", rows: [["hello", 42], ["world", 7]]}]},
        "fixture.xlsx"
      )

    binary
  end

  # Re-pack a valid xlsx with one extra highly-compressible member of
  # `@bloat_bytes` zeros, placed at `member_path` — the fixture pattern from
  # xlsx_roundtrip_test.exs (`:zip.extract` → mutate → `:zip.create`).
  defp repack_with_bloat(binary, member_path) do
    {:ok, entries} = :zip.extract(binary, [:memory])
    bloat = {String.to_charlist(member_path), :binary.copy(<<0>>, @bloat_bytes)}

    # If the bomb replaces a real member (sharedStrings.xml) drop the original.
    kept = Enum.reject(entries, fn {name, _} -> to_string(name) == member_path end)

    {:ok, {_name, out}} = :zip.create(~c"bomb.xlsx", kept ++ [bloat], [:memory])
    out
  end

  defp with_low_ceiling(fun) do
    prev = Application.get_env(:barkpark, XlsxImport)
    Application.put_env(:barkpark, XlsxImport, max_decompressed_bytes: @test_ceiling)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, XlsxImport, prev),
        else: Application.delete_env(:barkpark, XlsxImport)
    end)

    fun.()
  end

  describe "decompression-bomb guard" do
    test "the bomb ratio is real — declared uncompressed dwarfs the on-disk archive" do
      # Pins the attack the guard defends against, independent of the guard:
      # `:zip.list_dir` reads the declared uncompressed size from the central
      # directory (no inflate), and it is ~1000× the compressed archive.
      bomb = repack_with_bloat(valid_xlsx(), "xl/bloat.bin")
      {:ok, entries} = :zip.list_dir(bomb)

      declared =
        Enum.reduce(entries, 0, fn
          {:zip_file, _n, fi, _c, _o, _z}, acc -> acc + elem(fi, 1)
          _, acc -> acc
        end)

      assert declared >= @bloat_bytes
      # The archive on-disk is a tiny fraction of what it would inflate to.
      assert byte_size(bomb) < 2 * 1024 * 1024
      assert declared > byte_size(bomb) * 50
    end

    test "a bomb in an extra member (parse_layout :zip.extract vector) is rejected before inflate" do
      # `parse_layout/1`'s `:zip.extract(binary, [:memory])` inflates EVERY
      # member, including an unparsed extra one. The guard refuses it up front.
      with_low_ceiling(fn ->
        bomb = repack_with_bloat(valid_xlsx(), "xl/bloat.bin")
        assert XlsxImport.to_content(bomb) == {:error, :xlsx_decompressed_size_exceeded}
      end)
    end

    test "a bomb in a member XlsxReader reads (open_package vector) is rejected before inflate" do
      # sharedStrings.xml is read by XlsxReader.open (`open_package/1`), which
      # runs BEFORE parse_layout — so a guard only at parse_layout:365 would miss
      # this. Placing the guard at the TOP of to_content/1 covers it.
      with_low_ceiling(fn ->
        bomb = repack_with_bloat(valid_xlsx(), "xl/sharedStrings.xml")
        assert XlsxImport.to_content(bomb) == {:error, :xlsx_decompressed_size_exceeded}
      end)
    end

    test "a legitimate xlsx still imports under the ceiling" do
      # Same low ceiling as the bomb tests; a normal sheet is well under it and
      # imports cleanly — the guard does not over-reject.
      with_low_ceiling(fn ->
        assert {:ok, content} = XlsxImport.to_content(valid_xlsx())
        assert [%{"name" => "Data"} = tab] = content["tabs"]
        assert tab["cells"]["A1"] == %{"v" => "hello"}
        assert tab["cells"]["B1"] == %{"v" => 42}
      end)
    end

    test "a legitimate xlsx imports under the default (256 MiB) ceiling — no config needed" do
      assert {:ok, content} = XlsxImport.to_content(valid_xlsx())
      assert [%{"name" => "Data"}] = content["tabs"]
    end

    test "a REAL conditional-formatting export (dxfs + cfRule XML) still passes the guard" do
      # CF-X made the exporter add `<dxfs>` to styles.xml and
      # `<conditionalFormatting>` to each worksheet, both through an extra
      # unzip/rezip. Those bytes must not push a legitimate sheet over the
      # ceiling, and the rezip must not disturb the central directory the guard
      # reads: the SAME low ceiling the bombs trip lets this through.
      content = %{
        "tabs" => [
          %{
            "name" => "CF",
            "cond_formats" =>
              for i <- 1..50 do
                %{
                  "id" => "r#{i}",
                  "range" => "A#{i}:D#{i}",
                  "when" => %{"op" => "gt", "value" => i},
                  "style" => %{"bg" => "#ff0000", "b" => true}
                }
              end,
            "cells" => %{"A1" => %{"v" => 150}, "B1" => %{"v" => "text"}}
          }
        ]
      }

      assert {:ok, binary} = Barkpark.Plugins.Sheets.XlsxExport.to_binary(content)

      with_low_ceiling(fn ->
        assert {:ok, imported} = XlsxImport.to_content(binary)
        assert length(hd(imported["tabs"])["cond_formats"]) == 50
      end)
    end

    test "a non-zip binary still yields the canonical invalid-xlsx error, not the size atom" do
      # The guard must not mask a plain not-a-zip: `:zip.list_dir` fails to read a
      # central directory, the guard returns :ok, and open_package/1 produces the
      # existing clean {:error, message} (a 422, message =~ "invalid xlsx").
      assert {:error, message} = XlsxImport.to_content("definitely not a zip")
      assert message =~ "invalid xlsx"
    end
  end
end
