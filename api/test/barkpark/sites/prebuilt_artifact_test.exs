defmodule Barkpark.Sites.PrebuiltArtifactTest do
  @moduledoc """
  The box ingesting bytes it did not build (site-spawner charter D86/D87/D89).

  These archives are hand-assembled from raw 512-byte tar headers ON PURPOSE:
  `:erl_tar` will not WRITE a traversal name, an absolute path, a setuid mode or
  a device node, and those are exactly the entries this module exists to refuse.
  A legitimate Astro `dist/` is accepted IN THE SAME TABLE, so an implementation
  that "passes" by refusing everything reds.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Sites.PrebuiltArtifact

  @block 512

  setup do
    base = Path.join(System.tmp_dir!(), "bp-prebuilt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base, dest: Path.join(base, "site.prebuilt")}
  end

  # ── tar assembly (write side only — the read side is what is under test) ──

  defp nul_pad(value, width), do: String.pad_trailing(value, width, <<0>>)

  defp octal_field(value, width),
    do: String.pad_leading(Integer.to_string(value, 8), width - 1, "0") <> <<0>>

  defp header(name, opts) do
    type = Keyword.get(opts, :type, "0")
    size = Keyword.get(opts, :size, 0)
    mode = Keyword.get(opts, :mode, 0o644)
    link = Keyword.get(opts, :link, "")
    # ustar splits a long path across `prefix` (155) + `name` (100); the reader
    # rejoins them, which is how a >255-byte path is even expressible.
    prefix = Keyword.get(opts, :prefix, "")

    body =
      nul_pad(name, 100) <>
        octal_field(mode, 8) <>
        octal_field(0, 8) <>
        octal_field(0, 8) <>
        octal_field(size, 12) <>
        octal_field(0, 12) <>
        "        " <>
        type <>
        nul_pad(link, 100) <>
        "ustar" <>
        <<0>> <>
        "00" <>
        nul_pad("", 32) <>
        nul_pad("", 32) <>
        octal_field(0, 8) <>
        octal_field(0, 8) <>
        nul_pad(prefix, 155) <>
        nul_pad("", 12)

    512 = byte_size(body)
    checksum = body |> :binary.bin_to_list() |> Enum.sum()

    <<pre::binary-size(148), _old::binary-size(8), post::binary-size(356)>> = body
    pre <> (String.pad_leading(Integer.to_string(checksum, 8), 6, "0") <> <<0>> <> " ") <> post
  end

  defp pad_body(data) do
    case rem(byte_size(data), @block) do
      0 -> data
      r -> data <> :binary.copy(<<0>>, @block - r)
    end
  end

  defp file_entry(name, data, opts \\ []) do
    header(name, Keyword.merge([size: byte_size(data)], opts)) <> pad_body(data)
  end

  defp dir_entry(name), do: header(name <> "/", type: "5", mode: 0o755)

  # ── pax record assembly ───────────────────────────────────────────────────
  #
  # A pax record is `"<len> <key>=<value>\n"` where `<len>` counts the WHOLE
  # record, its own digits and the newline included — which makes the length
  # self-referential: `path=../../escape` is a 19-byte tail, so a 1-digit length
  # would be 20 (two digits, inconsistent) and the real record is `21`.
  # `pax_record/2` solves that fixed point instead of hand-counting it, because
  # hand-counting is exactly how the fixture at line 204 came to declare 30 for a
  # 21-byte record and green this suite on a MALFORMED-record refusal it never
  # meant to exercise.
  defp pax_record(key, value) do
    "#{pax_len(byte_size(key) + byte_size(value) + 3, 1)} #{key}=#{value}\n"
  end

  defp pax_len(base, digits) do
    len = base + digits

    if byte_size(Integer.to_string(len)) == digits,
      do: len,
      else: pax_len(base, digits + 1)
  end

  # An `x` extension header plus its record block. `:declared_size` lies about the
  # block's length on purpose in the buffer-bomb cases; `:name` is the header's own
  # pseudo-path, which must never reach disk.
  defp pax_entry(records, opts \\ []) when is_list(records) do
    pax_raw(Enum.map_join(records, fn {k, v} -> pax_record(k, v) end), opts)
  end

  defp pax_raw(block, opts \\ []) do
    declared = Keyword.get(opts, :declared_size, byte_size(block))
    name = Keyword.get(opts, :name, "PaxHeaders.0/entry")
    header(name, type: "x", size: declared) <> pad_body(block)
  end

  defp trailer, do: :binary.copy(<<0>>, 2 * @block)

  defp tarball(entries), do: IO.iodata_to_binary(entries) <> trailer()

  # The SAME entries with the end-of-archive marker never written — what a
  # transfer cut on a 512-byte boundary leaves behind.
  defp headless_tarball(entries), do: IO.iodata_to_binary(entries)

  defp gz(tar), do: :zlib.gzip(tar)

  defp artifact(tar_or_gz, opts \\ []) do
    raw = if Keyword.get(opts, :gzipped, true), do: gz(tar_or_gz), else: tar_or_gz
    {Base.encode64(raw), :sha256 |> :crypto.hash(raw) |> Base.encode16(case: :lower)}
  end

  defp stage(tar, dest, opts \\ []) do
    {b64, sha} = artifact(tar, opts)

    PrebuiltArtifact.stage(
      b64,
      sha,
      dest,
      Keyword.take(opts, [:max_entries, :max_total_bytes, :max_entry_bytes, :max_ratio])
    )
  end

  # A real (small) Astro `dist/` shape: an index, a hashed asset dir, a nested
  # page. This is the ACCEPT case, and it lives in the same table as the
  # refusals so a blanket-refuse implementation cannot pass.
  defp astro_dist do
    tarball([
      file_entry("index.html", "<!doctype html><title>bp</title><h1>hello</h1>"),
      dir_entry("_astro"),
      file_entry("_astro/app.a1b2c3.css", "body{margin:0}"),
      dir_entry("blog"),
      file_entry("blog/index.html", "<!doctype html><title>blog</title>")
    ])
  end

  # ── the accept case ───────────────────────────────────────────────────────

  describe "a legitimate prebuilt bundle" do
    test "is staged, with sanitized modes and the verified digest echoed back", %{dest: dest} do
      assert {:ok, summary} = stage(astro_dist(), dest)

      assert summary.dir == dest
      assert summary.entries == 5
      assert summary.sha256 == elem(artifact(astro_dist()), 1)

      assert File.read!(Path.join(dest, "index.html")) =~ "hello"
      assert File.read!(Path.join(dest, "_astro/app.a1b2c3.css")) == "body{margin:0}"
      assert File.read!(Path.join(dest, "blog/index.html")) =~ "blog"

      %{mode: file_mode} = File.stat!(Path.join(dest, "index.html"))
      %{mode: dir_mode} = File.stat!(Path.join(dest, "_astro"))
      assert Bitwise.band(file_mode, 0o777) == 0o644
      assert Bitwise.band(dir_mode, 0o777) == 0o755
    end

    test "REPLACES a previous staging — no bytes of the old bundle survive", %{dest: dest} do
      # The root index.html is what makes this a stageable SITE at all (see the
      # served-shape table); `stale.html` is the byte that must not survive.
      old = tarball([file_entry("index.html", "old"), file_entry("stale.html", "old")])
      assert {:ok, _} = stage(old, dest)
      assert File.exists?(Path.join(dest, "stale.html"))

      assert {:ok, _} = stage(astro_dist(), dest)
      refute File.exists?(Path.join(dest, "stale.html"))
      assert File.exists?(Path.join(dest, "index.html"))
    end

    test "accepts the `./` root entry a plain `tar czf - -C dist .` emits", %{dest: dest} do
      tar =
        tarball([
          dir_entry("."),
          file_entry("./index.html", "<!doctype html><title>bp</title>"),
          dir_entry("./_astro"),
          file_entry("./_astro/app.css", "body{margin:0}")
        ])

      assert {:ok, summary} = stage(tar, dest)
      assert summary.entries == 4
      assert File.read!(Path.join(dest, "index.html")) =~ "bp"
      assert File.read!(Path.join(dest, "_astro/app.css")) == "body{margin:0}"
    end

    test "leaves no staging siblings behind", %{base: base, dest: dest} do
      assert {:ok, _} = stage(astro_dist(), dest)
      refute Enum.any?(File.ls!(base), &String.contains?(&1, ".staging-"))
    end
  end

  # ── the refusal table ─────────────────────────────────────────────────────

  # Each row: {label, expected typed code, archive (or {archive, opts})}. The
  # code is asserted BY VALUE — a refusal that collapses every case into one
  # generic error fails here.
  defp refusal_cases do
    # 155-byte prefix + 100-byte name = a 256-byte path, one over the cap.
    long_prefix = String.duplicate("a", 155)
    long_name = String.duplicate("b", 100)
    # 40 path segments, split across prefix + name exactly as a real ustar
    # writer would (neither field can hold the whole path).
    deep_prefix = Enum.map_join(1..20, "/", &"d#{&1}")
    deep_name = Enum.map_join(21..40, "/", &"d#{&1}") <> "/x.html"

    [
      {"path traversal", "E_PATH_TRAVERSAL", tarball([file_entry("../evil.html", "x")])},
      {"absolute path", "E_ABSOLUTE_PATH", tarball([file_entry("/etc/passwd", "x")])},
      {"symlink to an absolute path", "E_SYMLINK",
       tarball([header("leak.txt", type: "2", link: "/opt/barkpark/.env")])},
      {"symlink escaping the root", "E_SYMLINK",
       tarball([header("up", type: "2", link: "../../../")])},
      {"symlink then write-through", "E_SYMLINK",
       tarball([
         header("dir", type: "2", link: "/tmp"),
         file_entry("dir/evil.html", "pwned")
       ])},
      {"hard link escaping the root", "E_HARDLINK",
       tarball([header("hard.txt", type: "1", link: "../../../etc/passwd")])},
      {"fifo", "E_SPECIAL_FILE", tarball([header("pipe", type: "6")])},
      {"character device", "E_SPECIAL_FILE", tarball([header("dev", type: "3")])},
      {"setuid mode bits", "E_MODE_BITS", tarball([file_entry("suid.bin", "x", mode: 0o4755)])},
      # WAS INVALID until wave 11: this row read
      #   file_entry("PaxHeaders/0", "30 path=../../escape\n", type: "x")
      # — a record DECLARING length 30 that is 21 bytes long. Once the extractor
      # learned pax, a length-prefix-driven parser (the correct kind) would have
      # greened it via a MALFORMED-RECORD refusal and never reached the traversal
      # re-validation the row exists to prove. Both cases now live here, with the
      # VALID one carrying the real code.
      {"a pax path that traverses (a VALID record)", "E_PATH_TRAVERSAL",
       tarball([pax_entry([{"path", "../../escape"}]), file_entry("shadow.html", "x")])},
      {"a pax record whose declared length overruns the block", "E_MALFORMED",
       tarball([pax_raw("30 path=../../escape\n"), file_entry("shadow.html", "x")])},
      {"a pax path that is absolute", "E_ABSOLUTE_PATH",
       tarball([pax_entry([{"path", "/etc/passwd"}]), file_entry("shadow.html", "x")])},
      {"a pax GLOBAL header", "E_UNKNOWN_TYPE",
       tarball([file_entry("PaxHeaders/0", pax_record("comment", "global"), type: "g")])},
      {"an over-long name", "E_BAD_NAME",
       tarball([file_entry(long_name, "x", prefix: long_prefix)])},
      {"an absurdly deep path", "E_BAD_NAME",
       tarball([file_entry(deep_name, "x", prefix: deep_prefix)])},
      {"an entry written THROUGH a file parent", "E_UNSAFE_PARENT",
       tarball([file_entry("a", "i am a file"), file_entry("a/b.html", "x")])},
      {"the same name twice", "E_UNSAFE_PARENT",
       tarball([file_entry("dup.html", "one"), file_entry("dup.html", "two")])},
      {"an entry declaring more than the per-entry cap", "E_ENTRY_TOO_LARGE",
       tarball([header("huge.bin", size: 100 * 1024 * 1024)])},
      {"more entries than the cap", "E_TOO_MANY_ENTRIES",
       tarball(for i <- 1..5, do: file_entry("f#{i}.html", "x")), [max_entries: 3]},
      {"more bytes than the total cap", "E_TOTAL_TOO_LARGE",
       tarball([file_entry("a.bin", String.duplicate("x", 800))]), [max_total_bytes: 600]},
      {"a truncated archive", "E_MALFORMED",
       binary_part(tarball([file_entry("index.html", String.duplicate("x", 2048))]), 0, 900)},
      {"garbage that is not a tar", "E_MALFORMED", :binary.copy("not a tar at all!", 64)},
      {"an archive with no entries at all", "E_MALFORMED", trailer()}
    ]
  end

  describe "the refusal table" do
    test "every malicious archive is refused with its OWN typed code", %{dest: dest} do
      for row <- refusal_cases() do
        {label, code, tar, opts} =
          case row do
            {label, code, tar} -> {label, code, tar, []}
            {label, code, tar, opts} -> {label, code, tar, opts}
          end

        result = stage(tar, dest, opts)

        assert match?({:error, ^code, _}, result),
               "#{label}: expected #{code}, got #{inspect(result)}"

        {:error, _, message} = result

        assert is_binary(message) and message != ""
      end
    end

    test "a refusal leaves NO partial tree and no staging sibling", %{base: base, dest: dest} do
      for row <- refusal_cases() do
        {label, _code, tar, opts} =
          case row do
            {label, code, tar} -> {label, code, tar, []}
            {label, code, tar, opts} -> {label, code, tar, opts}
          end

        assert {:error, _, _} = stage(tar, dest, opts)

        refute File.exists?(dest), "#{label}: the destination was created by a REFUSED artifact"

        siblings = base |> File.ls!() |> Enum.filter(&String.contains?(&1, ".staging-"))
        assert siblings == [], "#{label}: staging tree survived a refusal: #{inspect(siblings)}"
      end
    end

    test "a refusal never clobbers an ALREADY-staged good bundle", %{dest: dest} do
      assert {:ok, _} = stage(astro_dist(), dest)

      assert {:error, "E_SYMLINK", _} =
               stage(tarball([header("leak.txt", type: "2", link: "/etc/passwd")]), dest)

      assert File.read!(Path.join(dest, "index.html")) =~ "hello"
    end
  end

  # ── the envelope: digest, gzip, base64 ────────────────────────────────────

  describe "the envelope" do
    test "a digest mismatch refuses BEFORE anything is written", %{base: base, dest: dest} do
      {b64, _sha} = artifact(astro_dist())
      wrong = String.duplicate("0", 64)

      assert {:error, "E_DIGEST_MISMATCH", message} =
               PrebuiltArtifact.stage(b64, wrong, dest)

      assert message =~ wrong
      refute File.exists?(dest)
      assert File.ls!(base) == []
    end

    test "a non-gzip body is refused", %{dest: dest} do
      assert {:error, "E_NOT_GZIP", _} = stage(astro_dist(), dest, gzipped: false)
    end

    test "a non-base64 body is refused", %{dest: dest} do
      assert {:error, "E_NOT_BASE64", _} =
               PrebuiltArtifact.stage("not base64 !!!", String.duplicate("a", 64), dest)
    end

    test "a corrupt gzip stream is refused, not crashed", %{dest: dest} do
      gzipped = gz(astro_dist())
      head = binary_part(gzipped, 0, 12)
      corrupt = head <> :binary.copy(<<0xFF>>, 200)
      b64 = Base.encode64(corrupt)
      sha = :sha256 |> :crypto.hash(corrupt) |> Base.encode16(case: :lower)

      assert {:error, "E_MALFORMED", _} = PrebuiltArtifact.stage(b64, sha, dest)
      refute File.exists?(dest)
    end
  end

  # ── the bomb guards, at their REAL caps ───────────────────────────────────

  describe "compression bombs" do
    @tag timeout: 120_000
    test "a >200:1 stream past the ratio floor is refused at the DEFAULT caps", %{dest: dest} do
      # 33 MiB of zeros in one entry: under the 64 MiB total cap and the 64 MiB
      # per-entry cap, but past the 32 MiB ratio floor at roughly 1000:1.
      zeros = :binary.copy(<<0>>, 33 * 1024 * 1024)
      tar = tarball([file_entry("bomb.bin", zeros)])

      assert {:error, "E_COMPRESSION_RATIO", _} = stage(tar, dest)
      refute File.exists?(dest)
    end

    test "more than 20 000 entries is refused at the DEFAULT caps", %{dest: dest} do
      # 20 001 headers — 10.25 MiB inflated, i.e. UNDER the ratio floor, so this
      # trips the entry-count guard (and not the bomb guard) at the REAL default
      # cap, with no per-test override.
      #
      # The headers are 20 001 `./` ROOT directory entries ON PURPOSE. The guard
      # counts HEADERS, not inodes or writes: a root entry takes the
      # `{:dir, :root} -> count_entry` arm — counted and skipped, the same
      # counter every file and directory entry passes through — and the
      # "accepts the `./` root entry" case pins that it IS counted
      # (`summary.entries == 4` there includes it). So the counter trips at
      # exactly the same boundary as with 20 001 distinct files, while the
      # extractor performs ZERO filesystem writes getting there.
      #
      # That matters because both write-shaped fixtures MEASURABLY time out
      # under host load (task-a91269a34fe4aa0b): 20 001 distinct empty files put
      # ~40k create+chmod syscalls plus a 20 000-entry `File.rm_rf` walk inside
      # the budget (139s/136s against the old 120s tag — already double the
      # default), and even 20 001 duplicate dir headers still funnel 20 000
      # `File.mkdir_p` round-trips through the BEAM file server (82s). A guard
      # that trips on the COUNT does not need the disk to have been touched to
      # be proven, and the small-cap rows above already prove counting across
      # real file writes.
      tar = tarball(for _ <- 1..20_001, do: dir_entry("."))

      assert {:error, "E_TOO_MANY_ENTRIES", _} = stage(tar, dest)
      refute File.exists?(dest)
    end
  end

  # ── framing: the archive has to be WHOLE ──────────────────────────────────

  # A tar ends with two zero blocks and a gzip member ends with a CRC32/ISIZE
  # trailer. Both are the ONLY signals that the bytes we were handed are all the
  # bytes there were — a transfer cut on a 512-byte boundary produces a tree that
  # parses cleanly and is silently SHORT, which for a site is not a partial file
  # but MISSING PAGES that then go live under the team's domain.
  describe "framing" do
    test "a tar cut ON an entry boundary is refused — no end-of-archive marker",
         %{dest: dest} do
      cut =
        headless_tarball([
          file_entry("index.html", "<!doctype html><title>bp</title>"),
          dir_entry("_astro"),
          file_entry("_astro/app.css", "body{margin:0}")
        ])

      assert {:error, "E_MALFORMED", message} = stage(cut, dest)
      assert message =~ "end-of-archive marker"
      refute File.exists?(dest)
    end

    test "a gzip whose CRC32/ISIZE trailer was cut is refused as truncated", %{dest: dest} do
      gzipped = gz(astro_dist())
      # Drop exactly the 8-byte gzip trailer: every deflate block still inflates,
      # so the tar underneath is COMPLETE and only the envelope is short.
      beheaded = binary_part(gzipped, 0, byte_size(gzipped) - 8)
      b64 = Base.encode64(beheaded)
      sha = :sha256 |> :crypto.hash(beheaded) |> Base.encode16(case: :lower)

      assert {:error, "E_MALFORMED", message} = PrebuiltArtifact.stage(b64, sha, dest)
      assert message =~ "truncated in transit"
      refute File.exists?(dest)
    end

    test "bytes appended AFTER the end-of-archive marker are still BUDGETED", %{dest: dest} do
      # The tail is INCOMPRESSIBLE and 512 KiB, so it spans many 64 KiB input
      # chunks: a parser that stops FEEDING at the marker never sees it and the
      # blob rides in for free, unbudgeted. The honest bundle is 3 blocks
      # (1536 bytes), so only the tail can cross a 200 000-byte total cap.
      tail = :crypto.strong_rand_bytes(512 * 1024)
      tar = tarball([file_entry("index.html", "<!doctype html><title>bp</title>")]) <> tail

      assert {:error, code, _} = stage(tar, dest, max_total_bytes: 200_000)
      assert code in ["E_TOTAL_TOO_LARGE", "E_COMPRESSION_RATIO"]
      refute File.exists?(dest)
    end

    test "the marker still ends the archive — trailing zero padding is not an entry",
         %{dest: dest} do
      # GNU tar pads to its 20-block blocking factor; those zero blocks past the
      # marker must not be parsed, counted or refused.
      padded = astro_dist() <> :binary.copy(<<0>>, 11 * @block)

      assert {:ok, summary} = stage(padded, dest)
      assert summary.entries == 5
    end
  end

  # ── the served shape ──────────────────────────────────────────────────────

  # The CLI already refuses to PACK a directory with no root `index.html`
  # (`validatePrebuiltDir` in internal/cli/sites_tarball.go — the same message,
  # one hop earlier). This is the server half of that contract: the box is the
  # only place that sees what the archive actually CONTAINS, and an archive that
  # stages an empty or index-less tree deploys green and then 404s at the domain.
  describe "the served shape" do
    test "a `./`-only archive is refused — it would stage nothing", %{dest: dest} do
      assert {:error, "E_NO_INDEX", message} = stage(tarball([dir_entry(".")]), dest)
      assert message =~ "no files"
      refute File.exists?(dest)
    end

    test "a directories-only archive is refused", %{dest: dest} do
      tar = tarball([dir_entry("."), dir_entry("_astro"), dir_entry("blog")])

      assert {:error, "E_NO_INDEX", message} = stage(tar, dest)
      assert message =~ "no files"
      refute File.exists?(dest)
    end

    test "files with no index.html AT THE ROOT are refused", %{dest: dest} do
      tar =
        tarball([
          file_entry("about.html", "<!doctype html>"),
          dir_entry("blog"),
          file_entry("blog/index.html", "<!doctype html><title>blog</title>")
        ])

      assert {:error, "E_NO_INDEX", message} = stage(tar, dest)
      assert message =~ "index.html"
      assert message =~ "root"
      refute File.exists?(dest)
    end

    test "`./index.html` satisfies the root requirement", %{dest: dest} do
      tar = tarball([dir_entry("."), file_entry("./index.html", "<!doctype html>")])

      assert {:ok, summary} = stage(tar, dest)
      assert summary.entries == 2
    end
  end

  # ── the tightening is SAFE against writers that are not hand-built ─────────

  # Every archive below was produced by a real writer and is checked in AS BYTES
  # (base64, so it runs in CI with no external tool and no env-var escape hatch).
  # If requiring the end-of-archive marker refused what real writers emit, THESE
  # are the tests that red — which is the whole point of pasting them here.

  # `tar (GNU tar) 1.34`, `tar czf - -C /d .` over index.html,
  # _astro/app.a1b2c3.css and blog/index.html: 6 entries (the `./` root entry
  # included), 20 blocks total, 11 trailing zero blocks past the marker.
  @gnu_tar_134_b64 "H4sIAAAAAAAAA+3X7WqDMBQG4FyKu4EkJ5oIQ7yV4RdVsI1oBitj9760+2AtdCI0ytj7/EmIQg6c8Gq4YMFJL9X6PHrX43lOWsVKk9FS+fU0JcUiHb40xp4nV4xRxEZr3W/vzT3/o7joDnXzwlu370PtcWqwSZLb/dfmsv9EKUkWyVAF/fTP+5891LZyx6GJTicgz1zn+iYvh0x8zLKW8rbpe5sJP9u6Wrg3Lp6KyY025Gdgcf4TKUnI/zV8978YBl5QqaqYV9N01z1m85+u8z9OEoX8X0Np6+Prvhh33eFRvm1dDayNi7K3u7CXgOX5L02skf9r+Ox/0EvAbP77sL/svzLKIP/XcOP/35+JrxvA1hUCAAAAAAAAAAAAAMBS77MUmmgAKAAA"

  # The repo's OWN packer: `packPrebuiltDir` (internal/cli/sites_tarball.go), Go
  # archive/tar + compress/gzip, no `./` root entry, exactly 2 trailing zero blocks.
  @cli_packer_b64 "H4sIAAAAAAAA/+yT72rDIBTFfZTsBZJ7/VcY4qsMk9gZsFWig5Wxdx/F9kth3ZcmYdTflxOIcI/3eN5MynPoyJIAAOyEKCqLAuVFCwQFZVSglAgEkEpGSSMWdXXhI2UzE4Bovbd3zqVs9vs7/68Xueo/4ZK/ibE12NOBtUNKD55x3ofk/Pf8Ud7kL2DHSLPKEp88/z6Mp6+Dmd+n4yt8b+2msjbTcbSfrcsHv9yMP/svbvvPGMfa/zVQL2MY8ina5vwGtMpT9lb3UXXlSznUznofVOdQb+22UqlUKo/iJwAA//9RZPqOAA4AAA=="

  # CPython 3.9 `tarfile`, USTAR_FORMAT. PAX_FORMAT (tarfile's default) emits
  # `x` extension headers, which this module refuses today for a separate,
  # deliberate reason — that question belongs to the packer/extractor format
  # seam, not to framing, so this fixture pins the ustar writer only.
  @python_tarfile_ustar_b64 "H4sIALGdamoC/+3TXYrCMBQF4CxFN5DfJoKEbkXSNthCtaGNqIh7N1p8EXRepkVmzvdyb6EPISeHMjI5nqy0HqcZZ/Kcj11oqaQWRmeCcMGlMmShyQwOQ3R9Okrwbes//HesvW/Jn0PZxg2x79hX5Z++NPKfNX8XAnWikKWi5TD8ev4my97nL8xL/mplUv858p9c0VXny87122a/5lcC/wxlzb7yJ1rH3WSv+8f+69f+S6ky9H8Odll1ZTwHv7i/gNzGJrY+L4Jl42ZrkdfpajrL0oa+AAAAAAAAAAAAAAAAAAB8qxt6ymWyACgAAA=="

  defp stage_bytes(raw, dest) do
    PrebuiltArtifact.stage(
      Base.encode64(raw),
      :sha256 |> :crypto.hash(raw) |> Base.encode16(case: :lower),
      dest
    )
  end

  describe "archives from real writers" do
    test "GNU tar 1.34 output is accepted", %{dest: dest} do
      assert {:ok, summary} = stage_bytes(Base.decode64!(@gnu_tar_134_b64), dest)
      assert summary.entries == 6
      assert File.read!(Path.join(dest, "index.html")) =~ "hello"
      assert File.read!(Path.join(dest, "_astro/app.a1b2c3.css")) == "body{margin:0}"
      assert File.read!(Path.join(dest, "blog/index.html")) =~ "blog"
    end

    test "the CLI's own packPrebuiltDir output is accepted", %{dest: dest} do
      assert {:ok, summary} = stage_bytes(Base.decode64!(@cli_packer_b64), dest)
      assert summary.entries == 3
      assert File.read!(Path.join(dest, "index.html")) =~ "hello"
      assert File.read!(Path.join(dest, "_astro/app.a1b2c3.css")) == "body{margin:0}"
    end

    test "CPython tarfile (ustar) output is accepted", %{dest: dest} do
      assert {:ok, summary} = stage_bytes(Base.decode64!(@python_tarfile_ustar_b64), dest)
      assert summary.entries == 4
      assert File.read!(Path.join(dest, "index.html")) =~ "hello"
    end

    test ":erl_tar.create/3 [:compressed] output is accepted", %{base: base, dest: dest} do
      src = Path.join(base, "erl-src")
      File.mkdir_p!(Path.join(src, "_astro"))
      File.write!(Path.join(src, "index.html"), "<!doctype html><title>bp</title><h1>hello</h1>")
      File.write!(Path.join(src, "_astro/app.css"), "body{margin:0}")
      archive = Path.join(base, "erl.tar.gz")

      :ok =
        :erl_tar.create(
          String.to_charlist(archive),
          [
            {~c"index.html", String.to_charlist(Path.join(src, "index.html"))},
            {~c"_astro/app.css", String.to_charlist(Path.join(src, "_astro/app.css"))}
          ],
          [:compressed]
        )

      assert {:ok, summary} = stage_bytes(File.read!(archive), dest)
      assert summary.entries == 2
      assert File.read!(Path.join(dest, "index.html")) =~ "hello"
      assert File.read!(Path.join(dest, "_astro/app.css")) == "body{margin:0}"
    end
  end

  # ── PINNED, not fixed ─────────────────────────────────────────────────────

  describe "already-refused and parity behaviours (pins, NOT fixes)" do
    test "a corrupted gzip CRC32 with an intact ISIZE is ALREADY refused", %{dest: dest} do
      # zlib checks the CRC itself, so this needs no work from us — it is pinned
      # so nobody 'fixes' a hole that is not there. Only a MISSING trailer
      # escaped, and that is what the framing test above closes.
      gzipped = gz(astro_dist())
      size = byte_size(gzipped)
      <<head::binary-size(size - 8), crc::binary-size(4), isize::binary-size(4)>> = gzipped
      <<first, rest::binary>> = crc
      corrupt = head <> <<Bitwise.bxor(first, 0xFF)>> <> rest <> isize

      assert byte_size(corrupt) == size
      assert {:error, "E_MALFORMED", _} = stage_bytes(corrupt, dest)
      refute File.exists?(dest)
    end

    test "an OVER-DECLARED entry size is parity with GNU tar, not a differential",
         %{dest: dest} do
      # `swallow.txt` declares 1024 bytes with only 512 bytes of body written, so
      # the following block is read as its body. GNU tar 1.34 does EXACTLY this:
      #   $ tar xzf sizelie.tar.gz; echo EXIT=$?   ->  EXIT=0   (no warning)
      #   -rw-r--r-- 1 root root 1024 swallow.txt
      # so the extracted tree matches byte for byte. Pinned, not fixed: making
      # this a refusal would refuse what the reference implementation accepts.
      tar =
        headless_tarball([
          file_entry("index.html", "<!doctype html><title>bp</title><h1>hello</h1>"),
          header("swallow.txt", size: 1024) <> pad_body("x")
        ]) <> :binary.copy(<<0>>, 22 * @block)

      assert {:ok, summary} = stage(tar, dest)
      assert summary.entries == 2
      swallowed = File.read!(Path.join(dest, "swallow.txt"))
      assert byte_size(swallowed) == 1024
      assert binary_part(swallowed, 0, 1) == "x"
    end
  end

  # ── the packer → extractor seam ───────────────────────────────────────────
  #
  # THE REPO'S FIRST END-TO-END PROOF ACROSS THE TWO LANGUAGES. Until wave 11 no
  # test anywhere passed the Go packer's bytes to this extractor: the Go tests
  # asserted Go-made tarballs through `tar.NewReader` (which swallows the `x`
  # header transparently) and the Elixir tests consumed GNU-tar and hand-built
  # fixtures. The seam in between was where `bp cloud site deploy --prebuilt` died
  # on any accented slug — E_UNKNOWN_TYPE on the FIRST header block, while GNU tar
  # (which writes a raw UTF-8 name into an ordinary ustar header) sailed through.
  # Our own first-party client was the stricter, dead-on-arrival one.
  #
  # Both constants below are the REAL `packPrebuiltDir` output (Go 1.26.2,
  # archive/tar + compress/gzip), checked in AS BYTES so this half needs no Go
  # toolchain. Regenerate them with:
  #
  #     CC=clang go test ./internal/cli/ -run Prebuilt -v
  #
  # (`TestPrebuiltPaxFixturesForTheExtractor` in internal/cli/sites_tarball_pax_test.go
  # logs the base64, the sha256 and the raw typeflag sequence for each.)

  # dist/ = index.html + café/index.html. Raw typeflag sequence: `x 5 x 0 0`.
  # The `x` blocks carry `path=café/` and `path=café/index.html`; Go's ustar
  # SHADOW headers name `caf/` and `caf/index.html` — the accented byte DROPPED,
  # which is why skipping the `x` block stages a plausible 404 instead of the site.
  @go_packer_accented_b64 "H4sIAAAAAAAA/+yVTU7zMBBAvf5Oke8Czfh/Y7JmyRVM4sgVhkaNkcKROAcXQ1aESixaWOBUpfM2bpNInsh6L63t6zs73Trbuf24AVIAmDm2AlB9+J2uU1Cak2oqMUzO8xjtnkCRF78AqKwGG/1Na/u31/rfucdBVib5X3qPJLWWcl7VvAITC+epZJwpLgSnBCgDrUglSw9GPvk/uBDciefGaPv+xP08bhdC3v96+9S5aePjY/i1Pb7tfzrzRf+ZFhT7vwZs0f/D4eOX4DpI/hdQfkGSWglxvP+CZ/0XoIFUqzh55f03/7tdG18GV6Xzb0zcxuCah1QDU89/zj0iUpDS7pOf+C9V5j/ngqP/a/C1//fDh/zG08a7EHam9hRTgCAI8md4DwAA///c+vDVABYAAA=="

  # dist/ = index.html + <120 d's>/page.html. Raw typeflag sequence: `x 5 0 0` —
  # note the DIRECTORY entry is the trigger: its 121-byte name (component + `/`)
  # cannot be split across ustar's name/prefix fields, while the LEAF splits
  # cleanly (prefix=120 d's, name=page.html) and rides an ordinary header. A fix
  # that only handled long FILE names would still refuse this archive.
  @go_packer_long_component_b64 "H4sIAAAAAAAA/+yUUU7DMAyG88wpwgVoHDvdS+hdCs2WSWGNWJDG7VFXDamoG+pDDYF8L4naqFH9+3PHgBoRV1alFX7uz88RyJCQJ8HA2zG1r0Ipjrt+IYAgY5v8I0cjzFHd/XQJ/jUcEQ9Sb4w5O76px1VpmjgPRqOukQhBKKThmDQcBbj4H10I7sa5Y2q32xvvvw63TIjtzj349BJWvGOoR010PX/S0/xJG4VCshRxrfw5xJpj4e/b+65/Tu/RyaEJGpv2Kbgm9Iedrcb9wg8WsmJ/6Nxp5QHwrf+mnvoPiJS7/5kw7/9TvNhvPTTehdDbykOZBYVCofBn+AgAAP//XwipiQASAAA="

  # NFC, written as an explicit codepoint so the fixture cannot drift with an
  # editor's normalization: the packer's pax record carries 0x63 0x61 0x66 c3 a9.
  @accented_dir "café"
  @long_component String.duplicate("d", 120)

  describe "the packer → extractor format seam" do
    test "the accented archive's FIRST header block is a pax 'x' — the byte that was refused" do
      raw = :zlib.gunzip(Base.decode64!(@go_packer_accented_b64))
      <<first::binary-size(@block), _rest::binary>> = raw

      # Byte 156 is the typeflag, and it is read off the FILE header — no pax
      # keyword can override it, which is why admitting `x` under a path+size
      # allowlist cannot re-open the symlink/device/setuid refusals.
      assert binary_part(first, 156, 1) == "x"

      # And the block's own name is Go's pseudo-path with the accent already gone.
      # It must never reach the disk.
      assert binary_part(first, 0, 100) |> String.trim_trailing(<<0>>) == "caf/PaxHeaders.0"
    end

    test "an accented dist from the REAL packer stages, with the non-ASCII path INTACT",
         %{dest: dest} do
      assert {:ok, summary} = stage_bytes(Base.decode64!(@go_packer_accented_b64), dest)

      # 3 entries: the accented dir, its index.html, the root index.html. The two
      # `x` blocks are NOT entries.
      assert summary.entries == 3

      assert File.read!(Path.join([dest, @accented_dir, "index.html"])) =~ "kaf"
      assert File.read!(Path.join(dest, "index.html")) =~ "hello"

      # Go's mangled ustar fallback name must NOT be what landed — that is the
      # silent-404 failure mode a skip-the-`x` repair would have shipped.
      refute File.exists?(Path.join(dest, "caf"))
      assert Enum.sort(File.ls!(dest)) == Enum.sort([@accented_dir, "index.html"])
    end

    test "a path component over 100 bytes stages — the DIRECTORY entry is the trigger",
         %{dest: dest} do
      assert {:ok, summary} = stage_bytes(Base.decode64!(@go_packer_long_component_b64), dest)
      assert summary.entries == 3

      assert File.read!(Path.join([dest, @long_component, "page.html"])) =~ "long"
      # The ustar SHADOW name for that directory is truncated to 100 bytes; if the
      # `x` block had been skipped, the leaf's 120-byte prefix would no longer
      # match the directory that was created.
      refute File.exists?(Path.join(dest, String.duplicate("d", 100)))
    end
  end

  # ── pax is APPLIED, then RE-VALIDATED — never trusted ─────────────────────
  #
  # The five `name/1` arms are NOT the rule set: ABSOLUTE and TRAVERSAL are
  # enforced in `safe_path/2`, on the CLEANED JOINED path. A fix that re-ran only
  # `name/1` would leave a pax `path` traversal unchecked, so each half is proven
  # separately below.
  describe "a pax path re-enters the WHOLE rule set" do
    test "traversal is caught by safe_path/2, not by any name/1 arm", %{dest: dest} do
      # `../../escape` passes every one of name/1's five arms — non-empty, under
      # 255 bytes, valid UTF-8, no control chars, 3 segments.
      tar = tarball([pax_entry([{"path", "../../escape"}]), file_entry("shadow.html", "x")])

      assert {:error, "E_PATH_TRAVERSAL", message} = stage(tar, dest)
      assert message =~ "escape"
      refute File.exists?(dest)
    end

    test "a pax path that RESOLVES out of the root is caught even with no `..` segment",
         %{dest: dest} do
      tar = tarball([pax_entry([{"path", "/etc/passwd"}]), file_entry("shadow.html", "x")])
      assert {:error, "E_ABSOLUTE_PATH", _} = stage(tar, dest)
    end

    test "a pax path is measured by name/1's arms too", %{dest: dest} do
      for {label, path, code} <- [
            {"over 255 bytes", String.duplicate("z", 256) <> ".html", "E_BAD_NAME"},
            {"deeper than 32 segments", Enum.map_join(1..40, "/", &"d#{&1}"), "E_BAD_NAME"},
            {"a control character", "ok\x01.html", "E_BAD_NAME"},
            {"empty", "", "E_BAD_NAME"}
          ] do
        tar = tarball([pax_entry([{"path", path}]), file_entry("shadow.html", "x")])
        result = stage(tar, dest)
        assert match?({:error, ^code, _}, result), "#{label}: got #{inspect(result)}"
      end
    end

    test "ONLY path and size are applied — every other record is DISCARDED", %{dest: dest} do
      # Each of these keys exists to override a field this module validated. If any
      # were honoured, the entry below would become a symlink, or setuid, or owned
      # by root — so the assertions are that it is a plain 0644 regular file with
      # the archive's bytes, staged at the pax `path`.
      tar =
        tarball([
          pax_entry([
            {"path", "index.html"},
            {"linkpath", "/opt/barkpark/.env"},
            {"mode", "4777"},
            {"uid", "0"},
            {"gid", "0"},
            {"uname", "root"},
            {"mtime", "1700000000.0"},
            {"atime", "1700000000.0"},
            {"SCHILY.dev", "259"},
            {"SCHILY.ino", "12345"},
            {"comment", "ignored"}
          ]),
          file_entry("shadow.html", "<!doctype html><title>bp</title>")
        ])

      assert {:ok, summary} = stage(tar, dest)
      assert summary.entries == 1

      staged = Path.join(dest, "index.html")
      assert File.read!(staged) =~ "bp"
      # `File.stat` follows links; `File.lstat` is what proves it is not one.
      assert %{type: :regular, mode: mode} = File.lstat!(staged)
      assert Bitwise.band(mode, 0o7777) == 0o644
      refute File.exists?(Path.join(dest, "shadow.html"))
    end

    test "a pax SIZE record is applied — and re-measured against the per-entry cap",
         %{dest: dest} do
      body = String.duplicate("x", 600)

      # The ustar size field says 0; the pax record is what carries the real length.
      applied =
        tarball([
          file_entry("index.html", "<!doctype html><title>bp</title>"),
          pax_entry([{"path", "big.txt"}, {"size", "600"}]),
          header("shadow.txt", size: 0) <> pad_body(body)
        ])

      assert {:ok, summary} = stage(applied, dest)
      assert summary.entries == 2
      assert File.read!(Path.join(dest, "big.txt")) == body

      over =
        tarball([
          pax_entry([{"path", "big.txt"}, {"size", "999999999"}]),
          header("shadow.txt", size: 0)
        ])

      assert {:error, "E_ENTRY_TOO_LARGE", _} = stage(over, dest, max_entry_bytes: 1024)
    end

    test "a pax path onto an already-staged DIRECTORY is refused", %{dest: dest} do
      # The dir-collision hole this slice closes. `mkdir_p` on an existing
      # directory is idempotent (so a duplicate DIR header is harmless and stays
      # accepted — nothing can be overwritten), but a FILE named onto a staged
      # directory used to fall through to a generic write failure.
      tar =
        tarball([
          file_entry("index.html", "<!doctype html>"),
          dir_entry("assets"),
          pax_entry([{"path", "assets"}]),
          file_entry("shadow.html", "clobber")
        ])

      assert {:error, "E_UNSAFE_PARENT", message} = stage(tar, dest)
      assert message =~ "as a directory"
      refute File.exists?(dest)
    end

    test "a DUPLICATE DIRECTORY header is accepted — named, not a hole", %{dest: dest} do
      tar =
        tarball([
          file_entry("index.html", "<!doctype html>"),
          dir_entry("assets"),
          dir_entry("assets"),
          file_entry("assets/app.css", "body{margin:0}")
        ])

      assert {:ok, summary} = stage(tar, dest)
      assert summary.entries == 4
      assert File.read!(Path.join(dest, "assets/app.css")) == "body{margin:0}"
    end
  end

  # ── pax as a bomb, or as a state trick ────────────────────────────────────
  describe "the pax record block is budgeted and cannot carry state" do
    test "a record block over the hard cap is refused on its SIZE FIELD", %{dest: dest} do
      big = String.duplicate("a", 9000)
      tar = tarball([pax_raw(big), file_entry("shadow.html", "x")])

      assert {:error, "E_ENTRY_TOO_LARGE", message} = stage(tar, dest)
      assert message =~ "extension-header cap"
      refute File.exists?(dest)
    end

    test "more records than the cap is refused", %{dest: dest} do
      records = for i <- 1..40, do: {"SCHILY.pad#{i}", "x"}
      tar = tarball([pax_entry(records), file_entry("shadow.html", "x")])

      assert {:error, "E_MALFORMED", message} = stage(tar, dest)
      assert message =~ "records"
    end

    test "a single record over the per-record cap is refused", %{dest: dest} do
      tar =
        tarball([
          pax_entry([{"path", String.duplicate("z", 2000)}]),
          file_entry("shadow.html", "x")
        ])

      assert {:error, "E_MALFORMED", message} = stage(tar, dest)
      assert message =~ "per-record cap"
    end

    test "two pax headers in a row are refused — no state carries forward", %{dest: dest} do
      tar =
        tarball([
          pax_entry([{"path", "a.html"}]),
          pax_entry([{"path", "b.html"}]),
          file_entry("shadow.html", "x")
        ])

      assert {:error, "E_MALFORMED", message} = stage(tar, dest)
      assert message =~ "two pax extension headers in a row"
      refute File.exists?(dest)
    end

    test "a pax header describing NO entry is refused", %{dest: dest} do
      assert {:error, "E_MALFORMED", message} =
               stage(tarball([pax_entry([{"path", "index.html"}])]), dest)

      assert message =~ "describes no entry"
    end

    test "a pax header followed by a SYMLINK is still E_SYMLINK — type/1 is un-bypassable",
         %{dest: dest} do
      tar =
        tarball([
          pax_entry([{"path", "index.html"}]),
          header("shadow", type: "2", link: "/opt/barkpark/.env")
        ])

      assert {:error, "E_SYMLINK", _} = stage(tar, dest)
      refute File.exists?(dest)
    end

    test "a pax header followed by a setuid mode is still E_MODE_BITS", %{dest: dest} do
      tar =
        tarball([
          pax_entry([{"path", "index.html"}]),
          file_entry("shadow.html", "x", mode: 0o4755)
        ])

      assert {:error, "E_MODE_BITS", _} = stage(tar, dest)
    end

    test "a malformed record is refused, with the OLD invalid fixture as the case",
         %{dest: dest} do
      # `"30 path=../../escape\n"` declares 30 bytes and is 21. This is what the
      # pre-wave-11 fail-before fixture actually contained.
      tar = tarball([pax_raw("30 path=../../escape\n"), file_entry("shadow.html", "x")])

      assert {:error, "E_MALFORMED", message} = stage(tar, dest)
      assert message =~ "declares 30 bytes but only 21 remain"
    end

    test "a record with no `=` or no length prefix is refused", %{dest: dest} do
      for block <- ["21 pathis../../escape\n", "path=../../escape\n", "21 =value\n"] do
        tar = tarball([pax_raw(block), file_entry("shadow.html", "x")])
        staged = stage(tar, dest)

        assert match?({:error, "E_MALFORMED", _}, staged),
               "block: #{inspect(block)}, got #{inspect(staged)}"
      end
    end
  end

  # ── the 'x' block is not an entry ─────────────────────────────────────────
  describe "@max_entries never counts a pax block" do
    test "two pax headers plus two real entries stage under a cap of TWO", %{dest: dest} do
      # MEASURED on the packer's real bytes: counting the `x` block refuses a
      # legitimate 10 001-file accented dist with E_TOO_MANY_ENTRIES, because Go
      # emits one `x` per non-ASCII entry — counting them halves the effective cap
      # against a module whose own stated basis is "a Next standalone ~10⁴".
      tar =
        tarball([
          pax_entry([{"path", "index.html"}]),
          file_entry("shadow1.html", "<!doctype html>"),
          pax_entry([{"path", @accented_dir <> "/page.html"}]),
          file_entry("shadow2.html", "<!doctype html>")
        ])

      assert {:ok, summary} = stage(tar, dest, max_entries: 2)
      assert summary.entries == 2
      assert File.exists?(Path.join([dest, @accented_dir, "page.html"]))
    end

    test "the counter is still LIVE at that cap — one more real entry refuses", %{dest: dest} do
      tar =
        tarball([
          pax_entry([{"path", "index.html"}]),
          file_entry("shadow1.html", "<!doctype html>"),
          pax_entry([{"path", "b.html"}]),
          file_entry("shadow2.html", "<!doctype html>"),
          file_entry("c.html", "<!doctype html>")
        ])

      assert {:error, "E_TOO_MANY_ENTRIES", _} = stage(tar, dest, max_entries: 2)
    end
  end

  # ── the GNU long-name headers stay refused, ACTIONABLY ────────────────────
  describe "GNU L/K refusals name the repack" do
    test "an 'L' header refuses with a message that says how to repack", %{dest: dest} do
      # A LIVE path, not a dead branch: GNU tar 1.35 (`--show-defaults` prints
      # `--format=gnu`) emits `L` for a 121-byte unsplittable component, and its
      # two shadow headers carry BYTE-IDENTICAL truncated 100-byte names — so a
      # skip would stage a directory and a file at the same effective path.
      for flag <- ["L", "K"] do
        tar =
          tarball([
            file_entry("././@LongLink", String.duplicate("d", 121) <> "/\0", type: flag),
            file_entry(String.duplicate("d", 100), "x")
          ])

        assert {:error, "E_UNKNOWN_TYPE", message} = stage(tar, dest)
        assert message =~ "GNU"
        assert message =~ "--format=posix"
        assert message =~ "Repack"
        refute File.exists?(dest)
      end
    end
  end

  describe "caps/0" do
    test "the named caps are the ones the charter states" do
      assert PrebuiltArtifact.caps() == %{
               max_entries: 20_000,
               max_total_bytes: 64 * 1024 * 1024,
               max_entry_bytes: 64 * 1024 * 1024,
               max_ratio: 200,
               max_name_bytes: 255,
               max_segments: 32,
               # The pax record block's OWN budget — deliberately NOT a share of
               # max_entries, which an `x` block must never touch.
               max_pax_block_bytes: 8 * 1024,
               max_extension_records: 32,
               max_extension_record_bytes: 1024
             }
    end
  end
end
