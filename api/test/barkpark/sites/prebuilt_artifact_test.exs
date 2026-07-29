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
      assert {:ok, _} = stage(tarball([file_entry("stale.html", "old")]), dest)
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
