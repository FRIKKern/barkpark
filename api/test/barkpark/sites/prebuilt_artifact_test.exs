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
      {"a pax extension header", "E_UNKNOWN_TYPE",
       tarball([file_entry("PaxHeaders/0", "30 path=../../escape\n", type: "x")])},
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

        assert {:error, ^code, message} = result,
               "#{label}: expected #{code}, got #{inspect(result)}"

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

    @tag timeout: 120_000
    test "more than 20 000 entries is refused at the DEFAULT caps", %{dest: dest} do
      # 20 001 zero-byte entries — 10.25 MiB inflated, i.e. UNDER the ratio floor,
      # so this proves the entry-count guard and not the bomb guard.
      tar = tarball(for i <- 1..20_001, do: file_entry("f#{i}.html", ""))

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

  describe "caps/0" do
    test "the named caps are the ones the charter states" do
      assert PrebuiltArtifact.caps() == %{
               max_entries: 20_000,
               max_total_bytes: 64 * 1024 * 1024,
               max_entry_bytes: 64 * 1024 * 1024,
               max_ratio: 200,
               max_name_bytes: 255,
               max_segments: 32
             }
    end
  end
end
