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

    test "a non-zip binary still yields the canonical invalid-xlsx error, not the size atom" do
      # The guard must not mask a plain not-a-zip: `:zip.list_dir` fails to read a
      # central directory, the guard returns :ok, and open_package/1 produces the
      # existing clean {:error, message} (a 422, message =~ "invalid xlsx").
      assert {:error, message} = XlsxImport.to_content("definitely not a zip")
      assert message =~ "invalid xlsx"
    end
  end

  # ── zero-declared-size bomb (the central directory lies) ───────────────────
  #
  # The central directory is written by whoever built the archive. Erlang's
  # `:zip.list_dir/1` reads it verbatim; `:zip.extract/2` and `XlsxReader` read
  # the LOCAL headers and the actual deflate streams. Zeroing only the CENTRAL
  # uncompressed-size field therefore produces an archive that reports "0 bytes
  # of content" to the guard and still inflates in full to every reader.

  # 320 KiB of incompressible bytes: `comp_size` stays ~320 KiB, so the
  # worst-case bound (comp × 1032 ≈ 338 MB) clears the DEFAULT 256 MiB ceiling
  # on compressed size alone — no low-ceiling override needed, and the fixture
  # costs 320 KiB of RAM rather than the ~268 MB a real payload would.
  @incompressible_bytes 320 * 1024

  defp lying_zip(payload \\ :crypto.strong_rand_bytes(@incompressible_bytes)) do
    {:ok, {_name, bin}} =
      :zip.create(~c"lying.zip", [{~c"xl/payload.bin", payload}], [:memory])

    zero_declared_sizes(bin)
  end

  # Rewrite every central-directory header's uncompressed-size field to 0,
  # parsing the archive properly (End-Of-Central-Directory → central directory
  # offset → N headers) rather than scanning for the signature, which would also
  # match inside compressed data.
  defp zero_declared_sizes(bin) do
    eocd_at = byte_size(bin) - 22

    <<_::binary-size(eocd_at), 0x50, 0x4B, 0x05, 0x06, _::binary-size(6), count::little-16,
      _cd_size::little-32, cd_offset::little-32, 0, 0>> = bin

    <<before_cd::binary-size(cd_offset), central::binary>> = bin
    before_cd <> zero_headers(central, count, <<>>)
  end

  defp zero_headers(rest, 0, acc), do: acc <> rest

  defp zero_headers(rest, n, acc) do
    # Central header: sig(4) … comp_size(4) ends at 24, uncomp_size(4) at 24,
    # then name/extra/comment lengths, then 12 fixed bytes, then the names.
    <<0x50, 0x4B, 0x01, 0x02, upto_comp::binary-size(20), _uncomp::little-32, name_len::little-16,
      extra_len::little-16, comment_len::little-16, tail::binary>> = rest

    var_len = name_len + extra_len + comment_len
    <<fixed::binary-size(12), names::binary-size(var_len), more::binary>> = tail

    header =
      <<0x50, 0x4B, 0x01, 0x02>> <>
        upto_comp <>
        <<0::little-32, name_len::little-16, extra_len::little-16, comment_len::little-16>> <>
        fixed <> names

    zero_headers(more, n - 1, acc <> header)
  end

  describe "a central directory that under-declares its members" do
    test "the lie is real — list_dir reports 0 declared while extract inflates in full" do
      # Guard-independent: pins the attack itself. If this ever goes green
      # differently (list_dir cross-checking the local headers, say), the two
      # tests below stop testing what they claim to.
      bomb = lying_zip(:binary.copy(<<0>>, 4 * 1024 * 1024))
      {:ok, entries} = :zip.list_dir(bomb)

      declared =
        Enum.reduce(entries, 0, fn
          {:zip_file, _n, fi, _c, _o, _z}, acc -> acc + elem(fi, 1)
          _, acc -> acc
        end)

      comp =
        Enum.reduce(entries, 0, fn
          {:zip_file, _n, _fi, _c, _o, z}, acc -> acc + z
          _, acc -> acc
        end)

      assert declared == 0
      assert comp > 0

      # The inflate vector `parse_layout/1` uses, verbatim — it materialises the
      # full 4 MiB the central directory claimed was 0.
      assert {:ok, [{~c"xl/payload.bin", content}]} = :zip.extract(bomb, [:memory])
      assert byte_size(content) == 4 * 1024 * 1024
    end

    test "a member declaring 0 with real compressed bytes is rejected before inflate" do
      # RED BEFORE THE FIX: `uncompressed_size/1` mapped the 0 declaration to 0,
      # the sum was 0, the ceiling passed, and `to_content/1` walked on to
      # `open_package/1` — returning {:error, "invalid xlsx: …"} only because
      # this fixture is not a workbook, AFTER the bytes were inflated. The
      # untrusted-declaration bound (comp × 1032) now rejects it up front, under
      # the DEFAULT 256 MiB ceiling, on compressed size alone.
      assert XlsxImport.to_content(lying_zip()) ==
               {:error, :xlsx_decompressed_size_exceeded}
    end

    test "a member declaring 0 with no compressed bytes contributes nothing" do
      # The worst-case bound is a bound on bytes that EXIST. A genuinely empty
      # member declares 0 and compresses to a couple of bytes, so a legitimate
      # package carrying empty members is not pushed over the ceiling.
      empty = lying_zip("")
      assert {:error, message} = XlsxImport.to_content(empty)
      assert message =~ "invalid xlsx"
    end
  end

  describe "member-count cap" do
    test "a central directory with more than 10_000 members is rejected" do
      files = for i <- 1..10_001, do: {~c"m" ++ Integer.to_charlist(i), "x"}
      {:ok, {_name, many}} = :zip.create(~c"many.zip", files, [:memory])

      # Non-vacuity: the fixture really crosses the cap, and its declared bytes
      # are far under the ceiling, so ONLY the count cap can be rejecting it.
      {:ok, entries} = :zip.list_dir(many)
      assert Enum.count(entries, &match?({:zip_file, _n, _fi, _c, _o, _z}, &1)) == 10_001

      assert XlsxImport.to_content(many) == {:error, :xlsx_decompressed_size_exceeded}
    end
  end

  describe "the guard abstains rather than raising" do
    test ":zip.list_dir/1 traps its own failures — it returns an error, never raises" do
      # This is the standing premise for `guard_decompressed_size/1` having NO
      # function-level rescue: the only thing that rescue could plausibly have
      # caught is a raise out of `:zip.list_dir/1`, and OTP does not raise here.
      # If a future OTP starts raising, this reds — instead of the controller
      # silently turning a 422 into a 500.
      for garbage <- ["definitely not a zip", <<0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0>>, <<>>] do
        assert {:error, _reason} = :zip.list_dir(garbage)
      end
    end

    test "a non-zip binary still yields the canonical invalid-xlsx error after the rescue removal" do
      assert {:error, message} = XlsxImport.to_content(<<0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0>>)
      assert message =~ "invalid xlsx"
    end
  end
end
