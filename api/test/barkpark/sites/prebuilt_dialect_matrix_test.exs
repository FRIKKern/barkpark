defmodule Barkpark.Sites.PrebuiltDialectMatrixTest do
  @moduledoc """
  THE TAR-DIALECT MATRIX: 7 producers x 4 name shapes, each cell run against the
  REAL `Barkpark.Sites.PrebuiltArtifact.stage/4`, plus 5 hand-built rows for the
  seams a producer matrix cannot reach.

  WHY THIS FILE EXISTS. "It accepts a tar" is not one question. Five tar writers
  that all produce a valid `.tar.gz` of the SAME `dist/` disagree about how a
  non-ASCII name and an over-100-byte path component are encoded, and those
  disagreements are what the extractor actually meets on the wire. Wave 11
  measured that table in prose; prose does not red when a producer changes. This
  file is the table, committed, executable, and pinned by VALUE.

  ## The four name shapes

  Every dist is the same two files — a root `index.html` and `<component>/page.html`
  — and only `<component>` moves:

  | shape | component | why it is here |
  |---|---|---|
  | `:ascii` | `assets` | the control: no encoding question at all |
  | `:nfc` | `caf` + U+00E9 | precomposed e-acute, 5 bytes |
  | `:nfd` | `cafe` + U+0301 | decomposed e-acute, 6 bytes, SAME grapheme |
  | `:long` | 121 x `l` | one component over the 100-byte ustar name field |

  ## THERE IS NO SINGLE ORACLE — only per-row oracles

  `bsdtar` and `:erl_tar` DISAGREE with each other, so "the correct tree" is not
  a thing an oracle hands you for free. Measured, in this file:

    * on a DUPLICATE name, `:erl_tar` resolves last-wins (`dup.html` ends up
      `"second"`) while `stage/4` refuses `E_UNSAFE_PARENT` BY DESIGN;
    * on AppleDouble, `bsdtar` consumes `._*` back into xattrs while `:erl_tar`
      stages them as ordinary files — so the two oracles produce different trees
      for the same bytes;
    * on the mode row, `:erl_tar.extract/2` cannot even complete
      (`{:error, :eacces}`) because it honours the archive's declared 0644
      directory mode and then cannot write into it.

  So every ACCEPT row names `:erl_tar.table/2` as its oracle AND carries a
  literal pinned tree; the rows where no oracle can be an authority carry a
  written reason instead (see `describe "oracle-exempt rows"`).

  AN EXIT CODE IS NEVER A VERDICT. `bsdtar` returns rc=0 while printing
  "Damaged tar archive" on an over-declared size, so nothing in this file reads
  a producer's or an oracle's exit status as an answer. TREES are compared.

  ## What the comparator does, and what it deliberately does NOT do

  Each normalisation below is a MEASURED false red, not a precaution:

    * a leading `./` is stripped and a bare `.` entry dropped — `tar -C dist .`
      writes `./index.html` and a `./` root entry, `go`'s packer writes
      `index.html`; the trees are the same tree;
    * mode, uid, gid and mtime are EXCLUDED — `stage/4` rewrites modes on
      purpose. The `@modes_b64` row proves it: an archive declaring a 0644
      directory, a 0600 `index.html` and a 0777 `page.html` stages 40755/100644;
    * `:erl_tar.table/2` returns CHARLISTS, and an NFD name arrives as codepoint
      769 in one — comparing a charlist against a binary is a guaranteed false
      red, so oracle names are re-encoded with `List.to_string/1`;
    * expected and observed names are both passed through `platform_form/1`,
      which round-trips a name through the filesystem. That is a CONTROL, not a
      fudge: it is derived from the ARCHIVE's raw bytes, never from `stage/4`'s
      output, so an extractor that renormalised a name would still red on a
      normalisation-preserving filesystem. It is needed because OTP's filename
      layer on Darwin renormalises NFD to NFC on READ — measured on this tree,
      `File.ls!/1`, `:file.list_dir/1`, `:file.list_dir_all/1` and
      `:prim_file.list_dir_all/1` ALL report `caf` + U+00E9 for a directory whose
      on-disk bytes are `cafe` + U+0301.

  NFC IS NOT NORMALISED TO NFD, ON PURPOSE. That seam is a REAL defect class —
  a site whose links say `café/` and whose staged directory is `cafe`+U+0301 is
  a 404 — so the two forms are compared as raw bytes and asserted to be
  DIFFERENT (`test "the comparator does not normalise NFC to NFD"`).

  ## The accented fixtures are never committed as filenames

  Every accented name in this file is built at RUN TIME from numeric codepoint
  escapes (`<<0xE9::utf8>>`, `<<0x301::utf8>>`) and its normalisation form is
  ASSERTED before use. No accented path is ever added to git, because:

    * this repo has `core.precomposeunicode=true`, so `git add` of an NFD path
      silently records the NFC name — the fixture would rot into a different
      fixture at commit time;
    * an NFD tree entry checked out on macOS lands NFD on disk while `git status`
      reports it as an UNTRACKED PRECOMPOSED path — the file is simultaneously
      tracked-as-NFD and untracked-as-NFC, a permanently dirty worktree for
      everyone who checks it out.

  The archives themselves ride as pinned base64 (with the producer command, the
  tool version and the typeflag sequence read at byte 156 recorded beside each),
  so nothing here needs `gtar`, `bsdtar`, `go` or `python3` on the test host.
  The `:erl_tar` rows are the exception and are GENERATED at run time from a
  dist built in `tmp_dir`, so they cannot rot — and each one records the OTP
  release it ran on, because the wave-11 census ran on OTP 28 while the serving
  box runs OTP 27.

  FENCE + GATE (site-spawner wave 11, `ssw11-dialect-matrix-corpus`): this is
  the single new file `api/test/barkpark/sites/prebuilt_dialect_matrix_test.exs`;
  neither `prebuilt_artifact_test.exs` nor `prebuilt_artifact.ex` is touched, and
  the gate is
  `cd api && MIX_TEST_PARTITION=_ssw11m CC=clang mix test test/barkpark/sites/`.
  """

  use ExUnit.Case, async: true

  alias Barkpark.Sites.PrebuiltArtifact

  @index "<!doctype html><title>bp</title><h1>hello</h1>"
  @page "<!doctype html><title>page</title><p>page</p>"
  # bsdtar's AppleDouble sidecars are 163 bytes each, every time.
  @appledouble_bytes 163

  # ── the pinned matrix ─────────────────────────────────────────────────────
  #
  # Every `expect:` and `typeflags:` below was MEASURED against this repo's
  # `stage/4` at origin/main 468286c17, not transcribed from a design note. The
  # wave-11 prose table predates `ssw10-packer-extractor-format-seam`, which
  # taught `type/1` to APPLY-then-RE-VALIDATE a pax `x` block; 15 of the cells
  # that prose calls `E_UNKNOWN_TYPE "x"` are ACCEPTS today, and that is the
  # point of pinning them here rather than in prose.
  @matrix [
    %{
      producer: :gocli,
      shape: :ascii,
      # go run pack.go <dist>  (tar.FileInfoHeader + filepath.ToSlash, hdr.Format never set)
      # version: go version go1.26.2 darwin/arm64
      typeflags: "5 0 0",
      sha256: "3cec80563767966f063c2b68ea395c2d04a27110b9193b80761594e8ec6fedef",
      expect: {:ok, 3},
      tree: :standard,
      b64:
        "H4sIAAAAAAAA/+yUQU7FIBCGOUq9gB3aATaEu6CdShO0RDDR25uG1kWjdSM17z2+zQ+BhGF+fmyMlG" <>
          "LLSgIAoITIKrNCh1kzjKPoUClAAAa8k6hYI4pWtfIWk31lAIG8p4N9MdlxPFjfLrLphbD6H+wT3bv0" <>
          "7EucsfRDIv7svxA7/xEFZ80pTbxx//XdMD+mj0DN4r7RaUqezPIcdJvHOqzTYP672MqfM70M9F4s+Z" <>
          "nf8y93+e977Gv+z+D7/D+Er/Q7bhx5P+vW8foBVCqVytXwGQAA//9ng7n8AA4AAA=="
    },
    %{
      producer: :gocli,
      shape: :nfc,
      # go run pack.go <dist>  (tar.FileInfoHeader + filepath.ToSlash, hdr.Format never set)
      # version: go version go1.26.2 darwin/arm64
      typeflags: "x 5 x 0 0",
      sha256: "efe0a272a5e692f3bda28387224e7edaba0a2cc9042d03da5166e3657c326fa9",
      expect: {:ok, 3},
      tree: :standard,
      b64:
        "H4sIAAAAAAAA/+yVS07DMBCGveYU4QLNOPFjY7JmyRVM4uBKhlqNkcKROAcXQyaotBYtLOpUbefbjP" <>
          "OQPFHm+93qvnzQ473RnVkPCyAZgIl9FYDKn3W8T0HImhRjjmZSXoeg1wSyfPgZQHnhdbB3re4/3sub" <>
          "U7eDzEz0P/ceUWrJ+VTFVKFiO85TxismJbAv/yuQghQ8d2Nky39vnDMH3huC7vsDz9NwOxPS/C+9fj" <>
          "ILG57d8fb4M/9rSPK/4oxj/s9Bxbbzf/Pz8SC4EqL/GZTfIUotGNuf/5wn+V9LAFLM4uSV57+67VZt" <>
          "ePOmiAPQqLAMzjRxIlQ5rZX/vvTNqZtFjs7ypTNjTvn/5b9I/a9Zjf7Pwe/+P/qN/ZY21ji3UqWlGA" <>
          "AIgiAXw2cAAAD//+QhUngAFgAA"
    },
    %{
      producer: :gocli,
      shape: :nfd,
      # go run pack.go <dist>  (tar.FileInfoHeader + filepath.ToSlash, hdr.Format never set)
      # version: go version go1.26.2 darwin/arm64
      typeflags: "x 5 x 0 0",
      sha256: "5abdb996788c240fa0a595511b576e7868affb01e7372969c4c3f21df4847dcb",
      expect: {:ok, 3},
      tree: :standard,
      b64:
        "H4sIAAAAAAAA/+yWTU7zMBCGvf5Oke8CjX+TjcmaJVcwzQRXMtRqjBSW3I9DISdQkZQWFnGq0nk24/" <>
          "xInsh+3nhtGsjvTHcLpoZdu6JkfujAsUop/zKO9xmjgpOsS9DLAc9tMDtCU3z3JcCKzJtgb+I+eHvN" <>
          "/527H2RZev8TzxGlLpUaajFUyuXIeSYVl2VJZe8/51KQTCXuq+fTfw/OwYn32mCa5sTzabhdCAf5n3" <>
          "vzACsbHt1sc/yY/4JN8p+XTGD+LwFXo/zfLz7+CK6D3v/5lR8RpS6kPJ7/Sk3yX1KpSLaIk1ee//p/" <>
          "vV2HFw9ZXP9Kh01wUMUNofNhrP3Hpa/O3SwyO5unGrqE7pNf+V9M/Bcinv/Q//R87/+939tvWWXBua" <>
          "3OLcMAQBAE+TO8BwAA///BmWfDABYAAA=="
    },
    %{
      producer: :gocli,
      shape: :long,
      # go run pack.go <dist>  (tar.FileInfoHeader + filepath.ToSlash, hdr.Format never set)
      # version: go version go1.26.2 darwin/arm64
      typeflags: "0 x 5 0",
      sha256: "f332d6a90a624876b85aaa6e625b0ec933defa1766152faa0dc39a63f461ee1c",
      expect: {:ok, 3},
      tree: :standard,
      b64:
        "H4sIAAAAAAAA/+yW307DIBTGufYp8AXsAc6hN8i7oGOyBB1xmMy3N2VzuqUumljmHL+bU9omhfOn37" <>
          "d4mvn1TciPkU0GAIBGLLHXVCLIzbpAmgkkiX0PCMBAKIWKcZhuSx+8rLJ7ZgDJx+iPvLfKbj4/8nx7" <>
          "lF08E8z1bHmfX5PnQw9Ykxc5enuXTLe5MkHY4GNcmi4Ie+rdNn6bWIHD0TiIIOHTv2C4r5QQxPi6Rg" <>
          "Le57/Gt/4gQkmeXA63NRphlO7q1Dm4ZGpUuOg+0df6D7Cv/0qjJMapRgIuXP+Te/AT279v+D/arz8i" <>
          "6XP3fzUGa5SfHX/c/w1dsXOAabtMzf41Go3G/+EtAAD//7B0bpcAEgAA"
    },
    %{
      producer: :gnutar,
      shape: :ascii,
      # gtar czf - -C <dist> .
      # version: tar (GNU tar) 1.35
      typeflags: "5 0 5 0",
      sha256: "d98290e63bbfd92e363e3ba80cce2165c7e8137a61a543852cc2911a993befcf",
      expect: {:ok, 4},
      tree: :standard,
      b64:
        "H4sIAJOFoWoAA+3VbQrCMAwG4B6lXmDNunb7U3aXqdUJU4uroLe3oyIifiDYKfg+f5JBYaEpSSZYch" <>
          "RUWsdYxkhSxRixXGmpqopUyCknSZJxnb40xva9b3acM2e7zj45F44tFmMUNK5MrDZze8hav+5S/WNo" <>
          "cKnU4/7r8qb/UobAKVVB1/68/2Yy38780Vk+vIDa+JXvbD11RsTMtHndhqvZGhGyb1cLn5aJpu+t71" <>
          "Ougffnf65JYf6P4dJ/1yxtoi3wev7rm/4XBZWY/2O4P/+Hx3DZAO786TD+AQAAAAAAAAAAAAAAAAB+" <>
          "1wmnN1X9ACgAAA=="
    },
    %{
      producer: :gnutar,
      shape: :nfc,
      # gtar czf - -C <dist> .
      # version: tar (GNU tar) 1.35
      typeflags: "5 0 5 0",
      sha256: "a66304ee34d1412bc9f8ef0fade9af8505483a638a4c771ab282e3b28e10dfba",
      expect: {:ok, 4},
      tree: :standard,
      b64:
        "H4sIAJSFoWoAA+3VWwrCMBAF0CwlbqB5mLQ/oXupmlqhatAIuiTX4cZMiYqIDwRTBe/5mSkEOmTCTM" <>
          "ZIcjwotI4xj5FLFWNEhNJSFQVXIeeCSy4J1elLI2Sz9tWKUuJs29on58Kxuu6joH5lbLaY2G3W+Hmb" <>
          "6h9dg3OlHvdf5zf9lzIEylMVdO3P+28Gk+XY75yl3QsojZ/51pYjZ1jMTCPKJlzN0rCQfbta+LSMja" <>
          "v6sE+6Bd6f/0LzAvO/D+f+u2pqUy2B1/Nf3/R/OBQC878P9+d/9xouG8CdPh3GPwAAAAAAAAAAAAAA" <>
          "AADA7zoCtlX9IgAoAAA="
    },
    %{
      producer: :gnutar,
      shape: :nfd,
      # gtar czf - -C <dist> .
      # version: tar (GNU tar) 1.35
      typeflags: "5 0 5 0",
      sha256: "34b426770964580a22650720f5313946eb18879a0209526618623ad09d67d10d",
      expect: {:ok, 4},
      tree: :standard,
      b64:
        "H4sIAJSFoWoAA+3VSwrCMBAG4BwlXqB5mLSb0LvUmlqhatAIuvR+HsqUiIj4QDBV8P82M4VAh0yYyR" <>
          "hJjgeF1jHmMXKpYoyIUFqqouAq5FxwySWhOn1phGw3vlpTSpztOvvkXDjWNEMUNKyMzZdTu8tav+hS" <>
          "/aNvcK7U4/7r/Kb/UoZAeaqCrv15/81ouqr93lnav4DS+LnvbDlxhsXMtKJsw9WsDAvZt6uFT8tYXT" <>
          "X2eEi5Bt6f/yIXGvN/CJf+u2pmE22B1/Nf3/R/rESB+T+E+/O/fwyXDeDOnw7jHwAAAAAAAAAAAAAA" <>
          "AADgd50Ae/XGYQAoAAA="
    },
    %{
      producer: :gnutar,
      shape: :long,
      # gtar czf - -C <dist> .
      # version: tar (GNU tar) 1.35
      typeflags: "5 0 L 5 L 0",
      sha256: "f50edce1c4b492d7f4a1abf6f36ab9a16350823d5c21b5aebb0fa07d3c51b633",
      expect: {:error, "E_UNKNOWN_TYPE"},
      tree: :standard,
      b64:
        "H4sIAJSFoWoAA+3XW07DMBAFUC/FbMCv2vFPFLGAbKJQt4kIiVWMgN3jKID6gFRI2AFxz8+4kqWMOv" <>
          "HEwzhJTkTWmCkWUxRKT3FCpDZKWyt0XAsplFCEmvSpEfL4ENZ7Sol3Xedm9sVt222OhPJivO037pk1" <>
          "4b5L9YyxwIXWX9ffFCf1VyoGKlIldOif17+82gy34cU7Or4BVRna0Lnqxpd8WpWNrJr41wwlj6uls4" <>
          "Wfxjjj1/XQ7+q2v0v0jMPzP/b6kyikNUffAiGlVZbQOlE+R97P/34Ywty+p8a5ZB1yOYx3S8lw84BL" <>
          "ctT/2/e/lbYr3P+y+A39X4nivP8r9P8cluz/fr1zSQcPuChX/5+f/8x5/9eY/3L4fP4bT+bHBOjffn" <>
          "qMfwAAAAAAAAAAAAB/xyvnaMqSACgAAA=="
    },
    %{
      producer: :bsdtar,
      shape: :ascii,
      # /usr/bin/tar cf - -C <dist> .   (gzip -9 envelope added by the harness)
      # version: bsdtar 3.5.3 - libarchive 3.7.4 zlib/1.2.12 liblzma/5.4.3 bz2lib/1.0.8 
      typeflags: "0 x 5 0 x 0 0 x 5 0 x 0",
      sha256: "d22e83b8742fa6690675f4a8176d3a0a61e7b74c06e7283884206f9b099cfff6",
      expect: {:ok, 8},
      tree: :standard_plus_appledouble,
      b64:
        "H4sIAJSFoWoC/+2Y3W7TMACFvUkTolzDtXkB105sh0ldpQKTVmlosA3ErqqQerQibUOaQXgIrrjhHv" <>
          "FGPAYPgbOUFYWqXSScATqfZNmx4vTHOfbxYQNGXMM5D5Sil7Uua+7Jsi7bPhVSeTIIuOScciG0Jwnl" <>
          "pAEu5lmY2q+SmDg2a+6zt52fr/+RFnpV/yvs3LtFtgl5Ekb06IS+pAuKPnLbFs+Wt7YU11+u98je6e" <>
          "nxolmM+GzLncotW8v+u9FswsIkiQ1L0tk7Mw2nkSFb2+TTx8ffvovoKwHueBrmByYcmrQdXaSpmWbD" <>
          "cdq4/gWv6F/5gSY0h/6d43M6ycYTsyeCn9PBhOdLpYMHuy0V0MP+w97xo4P+i32Wh1mWslVy3es96/" <>
          "feSLEvjt7nZ/p5S+7SEzvo8GzdoF803oISbwbWdv8Zm/Rf6KWy/0vtEaqg/wbmnw3G06HJ2SibxM7m" <>
          "X0tZx//5OvDh/+D/4P/c63/pAF2tAxv1/7v/k56A/4P/A+7173r336x/rnR1/5eaY/9vgs794SzKPi" <>
          "SGFm9At5ONs9h0XyWddtnqjER3ZP+aWadtW9DL/6d/Ngjnc5PNb+78t8L/C09D//D/8P9N+n9X60D9" <>
          "/FdqJeH/4f+Be/2XqncZA9fPf71AS+S/jc4/GyTha+PkHFg//1W2E/4P/g/+rzH9L23gH18H6ue/Wv" <>
          "kc/g/+DzSmf2e7/3XyX1U9/ymN/KcRVue/xctwlQAni8sE8S8AAAAAAAAAAAAAAAAAAAAAAAAAAAAA" <>
          "/D38AMf4B1YAUAAA"
    },
    %{
      producer: :bsdtar,
      shape: :nfc,
      # /usr/bin/tar cf - -C <dist> .   (gzip -9 envelope added by the harness)
      # version: bsdtar 3.5.3 - libarchive 3.7.4 zlib/1.2.12 liblzma/5.4.3 bz2lib/1.0.8 
      typeflags: "0 x 5 0 x 0 x 0 x 5 x 0 x 0",
      sha256: "d5a5d184433d917fc594ad38da9a792f8ac1b25e2607514433ddb39d8c752846",
      expect: {:ok, 8},
      tree: :standard_plus_appledouble,
      b64:
        "H4sIAJSFoWoC/+2ZzW7TQBSF3UoIEdawHl7AmbHnJ5WSSAEqNVJRoS2IriLjTElEfozrQngIVmzYIx" <>
          "Y8B6/AY/AQ2E3Spk4Up1JmgPR80WjGkR0nuT5z7p1xW65jGkqpEoJc9HLcU4+P+/HYJ4wLjytFOaWE" <>
          "MiY97hDqWOD8LAni9KtEutfTS85LTzs9Xf4jU8hl/79w5+FdZ9txngUhOTgir8mE7D3nXtq8tL1PW3" <>
          "b8bbWPbBwfH06G2RVf03Y/d8rW1fsPwmHfDaKop90oHn7Qg2AQamdr2/ny+emv3yz87gBzPA9Gezpo" <>
          "67gcnsexHiTtbmxd/4zm9C98JR0ygv6N41PST7p9XWNqGg6XeT4XUlV2SkKR/ebjxuGTvearXXcUJE" <>
          "nsLpJrrfGi2XjH2S47+Dg6kS9LfIccpRftnyy7aEbjJSjx7+CWzd+jSP+ZXnL+z6XnEAH9W4i/2+oO" <>
          "2nrkdpJ+z1j8Jec3yf98qXzkf8j/kP+Z1/9VBmhqHijU/3z+xz2G/A/5HzCvf9PuX6x/KmTe/7mk8H" <>
          "8bVB+1h2HyKdIkewLq1aSb9HT9TVQtj0fVDqt30r9mWC2nI+hlk/3fbYXB6c8f9us/Oef/VCn4vw1Y" <>
          "hURB0qm50+iXlmcEUMym6d+U6lfX/4L6P33B/1H/o/636f+m5oFC/fssp38us/Vf+L8F/1dT/7+Ifr" <>
          "mEBYFbpv9x3E3e4+b7P56SCvs/NuM/WwVGwVu9zgWhwvUf5eXiL5XA/r8VvMr1+X8m+qgEb9H8v37V" <>
          "r67/+fpPUCpQ/6H+Q/1n3//XPw8U63/O/wWn8H8r/i+v+/+q7o9CcLP0b879V9n/Ffn1H6Gw/muFxf" <>
          "u/2dNwuQMcTQ4jbP8CAAAAAAAAAAAAAAAAAAAAAMC/yx80HdbTAFAAAA=="
    },
    %{
      producer: :bsdtar,
      shape: :nfd,
      # /usr/bin/tar cf - -C <dist> .   (gzip -9 envelope added by the harness)
      # version: bsdtar 3.5.3 - libarchive 3.7.4 zlib/1.2.12 liblzma/5.4.3 bz2lib/1.0.8 
      typeflags: "0 x 5 0 x 0 x 0 x 5 x 0 x 0",
      sha256: "c7c64d1a2e782731c7971f0115888617891ffb6b87eb802bd756f5a76c769df8",
      expect: {:ok, 8},
      tree: :standard_plus_appledouble,
      b64:
        "H4sIAJSFoWoC/+2Z3W7TMBiGs0kIUY7h2NyAayeOvUptpQKTVmlosA3EjqqQurSiPyHLoBxyARxxwj" <>
          "nibjjkMrgIXNp1VVb1R6o96N5HsuJEcdP2y+v3+2zaoJ5tGGMqDMnfoxwfmS/Gx3E/IFyEvlCKCcYI" <>
          "41z6wiPMc8DFeRal5qskutvVC+4zt7Vai3+kgUyP/wt3Ht71dj3vWRSToxPymkwYXfPumeab9t600f" <>
          "n31T6ydnp6POmORnwz7X7ulp2r6w/iQY9GSdLVNEkHH3Q/6sfa29n1vn55+us3j394wB7Po+GBjpo6" <>
          "LcYXaar7WbOTOtc/Zzn9h4GSHhlC/9YJGOllnZ6ucHUZDsr9QIRS7ZUKoSKH9ce14ycH9Vf7dBhlWU" <>
          "rnybVSe1GvvRN8nx99HJ7JlwVRIidm0OHZokEzGi9AiTcDLdp/xjL9j/SS838hfY+E0L+D+NNGp9/U" <>
          "Q9rOel1r8ZdCrJP/BVIFyP+Q/yH/s6//qwzQ1jywVP/X8z/hc+R/yP+Aff3bdv/l+mehzPu/kAz+74" <>
          "Lyo+Ygzj4lmozegGo562RdXX2TlIvjXrnNq23z1wzKRdODXrbZ/2kjjlr652fn9Z/kef/3GdZ/nMBL" <>
          "JImydoVOo19YnBJAMlumf1uqX13/c+p/P1Dwf9T/qP9d+r+teWCp/gM/p3/TQ/3vxv/3Lv1/HP1iAS" <>
          "sCt0v/k7hbfMb6+z+BGYD9H6fxny0Dk+it3uCK0NL1H5XP/xSTIeZ/F/il3Pw/E31Ugrdo/t+46lfX" <>
          "//X6L+Qc+7+o/1D/3YT/b3weWF//UgoF/3fi/yrn/6u6PwrB7dK/NfdfZf83zK//SIX1XyfM3/8dvQ" <>
          "zTHeBkcppg+xcAAAAAAAAAAAAAAAAAAAAAAP5d/gB8rP25AFAAAA=="
    },
    %{
      producer: :bsdtar,
      shape: :long,
      # /usr/bin/tar cf - -C <dist> .   (gzip -9 envelope added by the harness)
      # version: bsdtar 3.5.3 - libarchive 3.7.4 zlib/1.2.12 liblzma/5.4.3 bz2lib/1.0.8 
      typeflags: "0 x 5 0 x 0 x 0 x 5 0 x 0",
      sha256: "dd0e851d66489af1e90552a1d513de17ddbb4aa843e35f3f656c9b02691564e1",
      expect: {:ok, 8},
      tree: :standard_plus_appledouble,
      b64:
        "H4sIAJSFoWoC/+2a327TMBjFvUkIUa7h2ryAaye2w6S2UoFJqzQ02AZiV1VIPVqRtiFkUB6CK264R7" <>
          "wRj8FD4NBuhTA17YVTAucnWXYiu//s4/PFX1mfEddwzgOl6M9az2vuyXk9b/tUSOXJIOCSc8qF0J4k" <>
          "lJMKuHibhan9KImJY7Oin+12fr76S1roVV0Xbty9SXYJeRxG9OiEvqAL8nvkli2eLW9sya+/rPeS3d" <>
          "PT40UzH/HZltuFLjvL+3ei6ZiFSRIblqTTd2YSTiJDdnbJp4+Pvn0X0VcC3PEknB2YcGDSZnSRpmaS" <>
          "DUZp5foXvKB/5Qea0Bn07xyf03E2Gpu2CC6ngwnPl0oH9/caKqCHvQfd44cHvef7bBZmWcquk2u7+7" <>
          "TXfS3Fvjh6PzvTzxpyj57YQYdnqwb9ovEGlLgdWNP9e5TpP9dLwf+l9ghV0H8F88/6o8nAzNgwG8fO" <>
          "5l9LuUn85+vAR/yH+A/xn3v9LyNAV/tAqf7/jP+kJxD/If4D7vXv2v3L9c+VLvq/1Bz+XwWte4NplH" <>
          "1IDM1XQKeVjbLYdF4mrea81RqKztD+NNNW07agl3/Z/1k/dkL5+a/6Xf++CjTOfypB+IomYTZsM2fT" <>
          "vwaN1WEIZOpO/+4nffP8j689Xnf/ZzVZAHj+h/8v/N/VBlCmfyl0Uf+C4/m/Iv+Xl/6/NfdvNnAKsS" <>
          "0qmN3N8z/W/0Xd8z818X/WT8JXxunxz+b5H6mEqPv/f7a4nyL+A+uyjP7c7QMb53+k1tKrefxXE/0j" <>
          "8vq/ce/+6+R/Cue/Ugb1P/+ph/6vz//kq+IqA5QsLhOkfwAAAAAAAAAAAAAAAAAAAAAAAAAA/j5+AG" <>
          "t9UboAUAAA"
    },
    %{
      producer: :bsdtar_copyfile_disable,
      shape: :ascii,
      # COPYFILE_DISABLE=1 /usr/bin/tar cf - -C <dist> .   (gzip -9 envelope added by the harness)
      # version: bsdtar 3.5.3 - libarchive 3.7.4 zlib/1.2.12 liblzma/5.4.3 bz2lib/1.0.8 
      typeflags: "x 5 x 0 x 5 x 0",
      sha256: "3a57fc76d59bea0a2955cac498cf262c0908684ac45469d75885d14e64dea651",
      expect: {:ok, 4},
      tree: :standard,
      b64:
        "H4sIAJSFoWoC/+2X3U7CMBTHp5c8RX2Brd36IckgQSWBhETUaMLlHEWI+2i2ovMhvPIZfCMfw4dwgE" <>
          "LEBCXZRjDnd3O6pM26nf7P6b/vZR3pDWVi+dMkkZEeThKjYDDGgjE0j3wRsU0XcT4mGBHKbCoEphgj" <>
          "TJgjuIEyowKmqfaSfCtKBoHcMC+fNhpt/sgctIx7goNRqCehbBDxlQ6T2A5lXBzXa0ygXvekdXna6d" <>
          "60zczTOjH9ODQ9pQJpqiR+kJEX+bLRuui27ilpk/PHbMCva7SOrvJFvcGmRQeHxsvz2ds78V9rBrAT" <>
          "TKv8d/ym/5levuufUG4biIH+K8h/f9kBJtFQZuZYh0Hh+eeUblX/qU2g/kP9B8rXf1mq/7v+MeNr+n" <>
          "coxwbCoP/ScY+Gsa+flESzE9B09UQHsnmrXGsxcsekOc5/Texa+Qj08v/0v+r/XppKnVZ///vZ/yln" <>
          "FPo/9H+gfP0vVF+mDdze/9mCU/B/leZ/1QaUdycLvQ9u7/84czDUf6j/QGX6L1z12/g/tn7/Y5yD/9" <>
          "ud/5sdhqUDVJ+PCuwfAAAAAAAAAADA/vIBkqhzuAAoAAA="
    },
    %{
      producer: :bsdtar_copyfile_disable,
      shape: :nfc,
      # COPYFILE_DISABLE=1 /usr/bin/tar cf - -C <dist> .   (gzip -9 envelope added by the harness)
      # version: bsdtar 3.5.3 - libarchive 3.7.4 zlib/1.2.12 liblzma/5.4.3 bz2lib/1.0.8 
      typeflags: "x 5 x 0 x 5 x 0",
      sha256: "9d6d5a85d91f8468b7890527a764184d337e255178fc6cd55d664029f558f5ec",
      expect: {:ok, 4},
      tree: :standard,
      b64:
        "H4sIAJSFoWoC/+2XSU7DMBSGA8ucwlwgsR0PIKWVyiC1EhKTQGJpUpdWpK0VDIRDsOIMLDgHV+AYHI" <>
          "KkgVTtooDUtBTet3mO5CjD7/8NhyptatXWiR/dJIke2HYvceYMxlhyjkZRFBFTVsTRmmBEGKdMSsww" <>
          "RpjwQAoHpc4CuLm2Kslexeg41jP2Zds6ndkfmYHKuCIEGPVtr69rRH7K4REaMC7k5pbLJdpvbTeOd5" <>
          "qtsz0vVdYmXjTse8qYWHsmGd7qgRpEutY4ajWuGNkjB3fpuTh12RY6yW7aP59109q68/iw+/pGoifX" <>
          "AZaC51f/jK/8n/tl0v+ECeogDv5fgP6HZQXoDdo69bq2H89df8HYj/I/owTyP+R/oHr/V+X67/sfcz" <>
          "Hl/4AJ7CAM/q+ccKM9jOy90Sg/AfXQ9mys6xcm9ItV2CX1bvZrhqGfrcAvf8//4/ofqc7L8xL6PxqQ" <>
          "Kf8zkfd/UP+rh0hklO3WvEJ934WG4J/5v9D9d81/VAoJ898i9R9XAaMu9XzbwS/nP0an9BecYcj/i4" <>
          "CKyfxfqg+F4F/l//m7/ifzH5/u/7gkMP8tb/7LT0M5AZqPSwPjHwAAAAAAAAAAwOryDnLIrJAAKAAA"
    },
    %{
      producer: :bsdtar_copyfile_disable,
      shape: :nfd,
      # COPYFILE_DISABLE=1 /usr/bin/tar cf - -C <dist> .   (gzip -9 envelope added by the harness)
      # version: bsdtar 3.5.3 - libarchive 3.7.4 zlib/1.2.12 liblzma/5.4.3 bz2lib/1.0.8 
      typeflags: "x 5 x 0 x 5 x 0",
      sha256: "cbfb6cc589b7746dfe94ddf94912a1832705b4bb65771f55b9be2eba7e9d7cc0",
      expect: {:ok, 4},
      tree: :standard,
      b64:
        "H4sIAJSFoWoC/+2XTU7CQBTHq0tOMV6gnWnnA5JCgkoCCYmo0YTlWAYhFpjUQevSA7jyDN7GpcfwEJ" <>
          "YPIXYBkkAReb/NmyYz6cfr/733b8i4qmRLRU4wjCLVN61uZK0ZjLFgDI0jn0Ts0kkcrwlGhDKXCoEp" <>
          "xggT5gluodjKgOG9kVHyKFqFoVqwL9nWbi9+yQQ0izuCh1HPdHuqSMR3OmziepRxkS/kmED12nH54q" <>
          "Rau67YsTQmsoNBz5Zah8rW0eBB9WU/UMXyea18R0mFnD3GTX6VowV0mRyqNxcdOji0Xl9OPz5J8Jaz" <>
          "gK1gO5u/xzL9j/TyU/+EctdCDPSfQf4bsw7Q7bdUbHdML1x7/jmlK9V/6hKo/1D/gc3rf1Oq/73+Me" <>
          "Mp/XuUYwth0P/G8Y9ag8A8aYVGf0DJN10TqtKN9p3Jyu+QUif5NAPfSVagl/+n/3n/D2RbvT9nP/+5" <>
          "npvSf7KC/p8JJI+0NJ2iPc2+k4OJYL/0P837n/J/XnIA/F+m+Z+3AS1v1VrnwaX+j3qp/HNOBdT/LH" <>
          "BFqv7Psg+NYK/q/9pVv4r/Y+n5jwsB/m97/m/0M8wcoJ5earB/AAAAAAAAAAAAu8sXWnKQCQAoAAA="
    },
    %{
      producer: :bsdtar_copyfile_disable,
      shape: :long,
      # COPYFILE_DISABLE=1 /usr/bin/tar cf - -C <dist> .   (gzip -9 envelope added by the harness)
      # version: bsdtar 3.5.3 - libarchive 3.7.4 zlib/1.2.12 liblzma/5.4.3 bz2lib/1.0.8 
      typeflags: "x 5 x 0 x 5 x 0",
      sha256: "91ce2d7018df11ba0256bf7df2dae126adae4be6aa68f68a028baf5f5ee6e788",
      expect: {:ok, 4},
      tree: :standard,
      b64:
        "H4sIAJSFoWoC/+2X60rDMBiGqz97FfEG0qRNUgfdYOpgg4EnFPazdpkb9hBqpvUi/OU1eEdehhdht+" <>
          "mGQ3aAtaPyPX++FFJ6+PK+yXvhZ23p92VqBeM0lbHuj1JjxxBCXM7RtIpZJTab1emYEkQZt5nrEkYI" <>
          "IpQ7rjBQZpTA+FH7af4qSoahXDEvnzYYrP7IHDSvFcEhKNKjSNap+9MOTG2HceEe10zuom7npHl12u" <>
          "7ctnDma53iIImwr1QosUqTJxn7cSDrzctO84HRFj1/znrixmQ1dJ3f1O2tuung0Hh7Pfv4pMG7aQB7" <>
          "AVvFP2Od/id6+a1/yoRtIA76L6H/F/MdYBT3ZYaHOgp33n/B2Fb+z2wK/g/+DxSv/6JUv7n+CRdL+n" <>
          "eYIAYioP/C8Y76SaBflESTFdDw9EiHsnGnPGs28oa0Mcx/TeJZ+Qj08v/0v9j/w4JYd/5jdEn/jqAE" <>
          "9v9SyK0WKV8P67iw9q/FMuEUsi9K6O72+c8RNq16/sPV6P/C/ZV/L4s5Bm6d/5gQzK64/+/RTyH/AZ" <>
          "tSnOq3yX98Sf8sX4wVz38V0f/f+W+yKuYJUH1fKoh/AAAAAAAAAAAA1eULbBoq8AAoAAA="
    },
    %{
      producer: :python_default,
      shape: :ascii,
      # tarfile.open(mode='w:gz').add(<dist>, arcname='.')
      # version: CPython 3.9.6
      typeflags: "x 5 x 5 x 0 x 0",
      sha256: "95c8ecdf12ab9a265b6e15b561ef202b2a273f12595510858b2c22ce1fcae3f3",
      expect: {:ok, 4},
      tree: :standard,
      b64:
        "H4sIAJSFoWoC/+2VzU6EMBhFu/YpmBegP7TgopJZuvQVUL4REphphprg2wthdBKSMbooRrhn00KaNG" <>
          "l7z415zPdPRf9IRUlnFgQxcWsUItHX+fhfCiUVi3q2AG+dL87D9mybqPuo9XVLDzL7PP9YqkSbNLtj" <>
          "YPXEPPwe46PKjJnGdBqFmmV+lv9hiMyS+XfUNPTNumHZ4bDG+4f/4X/4f7v+L7qOfBeyBn7vf2mEgv" <>
          "/hf/gf/geL+N8VrxRXvm3C5D/V+rb/L91wzX+SCM0isWT+N+p/uytPL/7dUTTefW597RvKx8dg+TS3" <>
          "7vLpcsQF/Y/+R/+DFeW/PpbUB2r+n/Z/Osu/klmK/v+7/n92X+1fybwajuZk+TBDXgAAAAAAAADgv/" <>
          "IBiz6UygAoAAA="
    },
    %{
      producer: :python_default,
      shape: :nfc,
      # tarfile.open(mode='w:gz').add(<dist>, arcname='.')
      # version: CPython 3.9.6
      typeflags: "x 5 x 5 x 0 x 0",
      sha256: "fee79c35a7f1cd29fed65f09a712e0d8aac702d5eba56ddb650e893c97e54086",
      expect: {:ok, 4},
      tree: :standard,
      b64:
        "H4sIAJSFoWoC/+2Y306DMBjFud5T4Av0H1C8YOill75CHUWWgGtmTfCRfA5fzBLmzFhm9KJM1/O7+Q" <>
          "pp0qRfzzkFQgm9vVf9nVaV3kZeYCOnKmNJ+jUe3nMmuIjiPpqBl2ertm75KEzEddzZdaeXPP/cf8JF" <>
          "kmYyX0Tg4iHU/xrDocqzbKxyrExMND/RvytxNqf+jW5b/c08N62uL7H/f8D/d2fjwP8z+P8c8Dw2yj" <>
          "ZLQleqfn+jCwRCYP7v+n7jNwR+7/+cJfD/cPxfymP/z+H/s9z/5aH/G/WoSWO7FkEQkv/v2+5L/zJN" <>
          "T/v/0f1PyMR9/7M59R+o/xdX1WZlX42Oh+6XhV3bVpfDcSjoOC7M7tGUkAvy30f+4//f+fIfKR+4/t" <>
          "dPle69Zf/P8n96/3fXf4n8P1/+P5h9+je8bNzWbArqRtALAAAAAAAAAPxXPgD66mQgACgAAA=="
    },
    %{
      producer: :python_default,
      shape: :nfd,
      # tarfile.open(mode='w:gz').add(<dist>, arcname='.')
      # version: CPython 3.9.6
      typeflags: "x 5 x 5 x 0 x 0",
      sha256: "2cf96f12ffb6d8321f588909c917b7cfb98a519787664e4cee5188674afcb255",
      expect: {:ok, 4},
      tree: :standard,
      b64:
        "H4sIAJSFoWoC/+2YTU7DMBSEve4pzAX818TuIg0sWXKF0DgkUkKtYqSw5H4cikQprZSqCBZOoZlv8+" <>
          "zIkiU/z0xkxhm/e8jae5vldkeCIAbOVSGW0XHcf5dCSUVoSybg9cVnu257Mk/Uija+auxamq/zZ1It" <>
          "o1ibBQFXD+Ph9+gvlYnjoeqhCjXS/Ej/XaHxlPp3tq7tN+u6ZUVxjf3/A/4f61P/1/D/KZAr6jJfrh" <>
          "nfZIX9eOcLJMK8/L/v+23QFPi9/0tpYvj/bPxfmxP/VwL+P8n/vxn5v8ueLCt9UyMI5uT/h7YH0r+O" <>
          "ovP+v8+Go/6VMYZQMaX+Z+r/yU2+3fg3Z2nf/DTxla9t2t+GhA/jxO2nLoVckP8h8h/vf5fLf4T8zP" <>
          "VfPee2DRX9P8z/8fuPkkYj/y+X/4/ukP6lTMvuaLYJ70bQCwAAAAAAAAD8Vz4B/EjdLQAoAAA="
    },
    %{
      producer: :python_default,
      shape: :long,
      # tarfile.open(mode='w:gz').add(<dist>, arcname='.')
      # version: CPython 3.9.6
      typeflags: "x 5 x 0 x 5 x 0",
      sha256: "b129e9a4d4eedf909d0cc4eecab872fe035be81e5b67805bf87650e278880e4b",
      expect: {:ok, 4},
      tree: :standard,
      b64:
        "H4sIAJSFoWoC/+2Xy2qEMBiFs56nSF8g92gXjnTZZV/B1kwVdCZMU7BvX629gDIDhapUz7f5EwkEkp" <>
          "zzexhn/O4ha+5dlrszmQTRc6kKoc3PuPsuhZKK0IbMwOtLyM7t9mSbqFtah7J2exl/nT+TShsbxTsC" <>
          "Vg/j0+/RParY2r5GfRVqoPmB/ttC7Zz6966q3JV17bLDYY33D/+H/8P/t+v/5TF3DStCXU3p/5Exl/" <>
          "3fRgP9KxlHhIo59b9R/09u8tNTePOOdi8gTUIZKpc++oT3o6SQadEezSnh7Qh6Qf//+/6vjBr3f43+" <>
          "PwdSG+qzUOwZr5aC7/AXspz+p7/fX+c/bWKN/Lcd/7d67P8W/j+L/xu9vP/77Nl9JBA0grX6//X8Z8" <>
          "f+r5D/lst/nSC/E6D/nHrEPwAAAAAAAAD4v7wDn6pOZwAoAAA="
    },
    %{
      producer: :python_ustar,
      shape: :ascii,
      # tarfile.open(mode='w:gz', format=USTAR_FORMAT).add(<dist>, arcname='.')
      # version: CPython 3.9.6
      typeflags: "5 5 0 0",
      sha256: "9661d4c6530c73949ce3ca4bbc2d0f9b1ca860e0a86055c1f061853a4ac763b7",
      expect: {:ok, 4},
      tree: :standard,
      b64:
        "H4sIAJSFoWoC/+3T0WrCMBTG8TxK9wJNGk/am9B36TRaoZthjbC9/SKRwQRlN3Ui/9/NOaW5KP3y1V" <>
          "otzmSdc2W2ZRorZRaqEWel64zk3TT5rVWVU3dwnNPwkT8lhmkKN87lY9utejq1HuY5pFk/VP6NEyH/" <>
          "u+Yfh12ox/Q2LZN/K3I9/3w3fue/WkmrKkP+i/Mvm8M6fcVQnbLvfdqnKfSny+B12X08P8Ze4fn6v3" <>
          "/fhM+Fmv/X/rcX/bdWDP3/v/6/xp/2j00/5l9z8Dpv9AUAAAAAAAAAAAAAHtU3MDAUaAAoAAA="
    },
    %{
      producer: :python_ustar,
      shape: :nfc,
      # tarfile.open(mode='w:gz', format=USTAR_FORMAT).add(<dist>, arcname='.')
      # version: CPython 3.9.6
      typeflags: "5 5 0 0",
      sha256: "5f31999d6f8feb614260f38b98c1fb60a4e5bf8d54877de9acc45039dcc4ff5d",
      expect: {:ok, 4},
      tree: :standard,
      b64:
        "H4sIAJSFoWoC/+3TS27CMBSFYS8lbCB+YCcTK3tJwWmQAlhgJFhS19GN1chVpVZq1UkAof+b3BvFgy" <>
          "jHp5ZidiprnSuzKVMZW2YhtHXGtq2yeVc6vzWicuIGTsfUH/KnxDBN4Y9z+dgwiKdTy1U/vL/Jx8pf" <>
          "O9uS/y3zj/1rqMe0nWbKv7H29/zz3fie/3LptKgU+c/OL9b7VbrEUF3D73zapCl019vgZdl9/HyMnc" <>
          "Dz9X+zW4fzXNX/Z/+bH/03xir6f7/+v8Sv9o+6G/Ov2XuZN/oCAAAAAAAAAAAAAI/qA2TWT4gAKAAA"
    },
    %{
      producer: :python_ustar,
      shape: :nfd,
      # tarfile.open(mode='w:gz', format=USTAR_FORMAT).add(<dist>, arcname='.')
      # version: CPython 3.9.6
      typeflags: "5 5 0 0",
      sha256: "77a9f4452a2e25e00b3c5a8413f373e6f526e13ec497e9b816dd0a8894449cbc",
      expect: {:ok, 4},
      tree: :standard,
      b64:
        "H4sIAJSFoWoC/+3TQWrDMBCFYR3FvYAlq5K9Eb6Lk8hxwG1Eq0KzzP1yqE5QKbSQ0o3TEP5vMzKehd" <>
          "Hzq7VanBGd92W2ZRrryixU47x1XWecnE0jb62qvLqCt9c8vMinpDjP8Zc9WRtHdXdqvR7GeDrqm8q/" <>
          "aWWd/K+Zfxq2sZ7y07xM/q1zl/OXsL/n/+h8pypD/osLD5v9Oh9SrM7Z9yHv8hz7888QdDmH9PmYeo" <>
          "X76//ueRPfF2r+X/vf/ui/tc7Q///r/yp9tX9q+kmuZh+0nOgLAAAAAAAAAAAAANyqD5fbvvQAKAAA"
    },
    %{
      producer: :python_ustar,
      shape: :long,
      # tarfile.open(mode='w:gz', format=USTAR_FORMAT).add(<dist>, arcname='.')
      # version: CPython 3.9.6
      typeflags: "5 0 5 0",
      sha256: "d7544979cd11acfe5abb751f8528cb4c210362d9279f9898b5e269df4c3e2061",
      expect: {:ok, 4},
      tree: :standard,
      b64:
        "H4sIAJSFoWoC/+3V0Q6CIBgFYB7FXkCQfvCG+S5WmG1UrGirt49G68JVqwsq2/lufpxcqIcdS86yE1" <>
          "GtVJo6TSEpzYRVpCTVtaC4FlW8K1mh2Acc9qHdxUfx1jn7ZF/c1nXs75R8tVnYY9mHtcuZvyZ6nL/S" <>
          "g/ylJMEKgfyzM5PFdh5O3haXE9CYsArONjNveFqZvmr6+Gm2hscVA8jf/1TpWAnj7v+Su2955/V9u7" <>
          "RZy/+l/leD/Kekx97/I8n/fv9fTsXtD+Cvlx71DwAAAAAAAAAAAAAAAADwu85153l1ACgAAA=="
    },
    %{
      producer: :erl_tar,
      shape: :ascii,
      # :erl_tar.create(out, [{~c"index.html", …}, {<component>, …}], [:compressed])
      # version: OTP 28 / erts 16.3.1
      typeflags: "0 0",
      sha256: "e10daea67d37493a6645dfd383529ecd844337355906d3c37620e54122495a6b",
      expect: {:ok, 2},
      tree: :standard,
      b64:
        "H4sIAAAAAAAAE+2UzQ7CIAyAeRR9AVdIgQvZu0xHZAk6IpjMt5f9ZCbGxINOo+l3acsBStKvzbG23c" <>
          "alg2eLARxAITLIaCWHCGKsB6RiHKVArQEB8jnnQisGy7V04xxTdcpPvnrP9JU5/ghmXbe7dAl21c9A" <>
          "aVKTvC23wRRjZhwvnfW+NUXOvt0t8W6qGG2KRaj2drEt8Nx/ee+/QEDy/wM89r8fh3kDhKkMpD9BEM" <>
          "T/cAViXZmaAAwAAA=="
    },
    %{
      producer: :erl_tar,
      shape: :nfc,
      # :erl_tar.create(out, [{~c"index.html", …}, {<component>, …}], [:compressed])
      # version: OTP 28 / erts 16.3.1
      typeflags: "0 x 0",
      sha256: "1f8795c3a53efdb5432543f5907c5ef9bf0e611706d7c300b438c8fb6c102e43",
      expect: {:ok, 2},
      tree: :standard,
      b64:
        "H4sIAAAAAAAAE+2WQQ7CIBBFWXsKvUA7UAob7NqlV0CLtklVYjGpR/IcXkxaTW0ajQtbG5W3mRkWMI" <>
          "T5M6TbWBVeYjYZ6g3AAIxSBBbOwsoCucYVIUOYhoRyDhTArmNMOEPQX0p3DrmRe3vku/vcrlLbL0FM" <>
          "4t3SHLUalzUQCZOaTEULLfyrJxIcJSrLdsK33tDZOrpmKVf+XBYzJWO1zz3wtVyrjvtBU/9NidT6D6" <>
          "CtfwqMoaK7FJ7z5/ondKylSaa2Ds6n++OPhs7L8Tu8nv9hS//AAyBu/n+Ax/O/7AP1D0DfQu3Gv8Ph" <>
          "cPwOF1QVXJAAEAAA"
    },
    %{
      producer: :erl_tar,
      shape: :nfd,
      # :erl_tar.create(out, [{~c"index.html", …}, {<component>, …}], [:compressed])
      # version: OTP 28 / erts 16.3.1
      typeflags: "0 x 0",
      sha256: "6c33ede4b698df4e1ec4c4a866621b9e9bf6bd7c15ec877a6dc0b128b1bc52e0",
      expect: {:ok, 2},
      tree: :standard,
      b64:
        "H4sIAAAAAAAAE+2WSw6CMBCGu/YUegGYlpZuKmuXXqFCFROUBmqCS+/noeRhkBCjC0Gj9tvMTBftNJ" <>
          "1/ptt9pAonNrsEjQZgAJ9SBCXcZ7UF0sQ1zEeYMkI5BwpQrmNMuI9gvJRuHHIjs/LIV/e5XqW1X4KY" <>
          "RWlojlpNqxoIhNmaRAUrLdzGEzEOYpUkqXBL79PZWoYmlGvlLmWxUDJSWe6Aq+VGDdsQuvrvSqTVv4" <>
          "f7+qfEo6gYLIMH/Ln+CZtqaeJ5VQfn0+3xJ59OzPIzPJ//rKd/4B4QO//fwP35X7WB9gegr6G2499i" <>
          "sVh+hwvnyth9ABAAAA=="
    },
    %{
      producer: :erl_tar,
      shape: :long,
      # :erl_tar.create(out, [{~c"index.html", …}, {<component>, …}], [:compressed])
      # version: OTP 28 / erts 16.3.1
      typeflags: "0 0",
      sha256: "2007913ae8180a08fe67b269a40ff636c8c43400ea474450f40036dd91b7ec93",
      expect: {:ok, 2},
      tree: :standard,
      b64:
        "H4sIAAAAAAAAE+2U2wrCMAxA+yn6Ay4pvbyU/ct0xQ6qK1pB/97uwgTxQdEyJjkvSfrQJpDT5ljb68" <>
          "bFg2fZAARQQjBIaCX7CHyoe6RiKCQXWoMASOeIXCsG+Vp6cDnH6pSe/PaecZQpLgSzrttdvAW76nag" <>
          "NLGJ3pbbYIohMw5LZ71vTZGyubslfk2o9jaz/m/4L5/8F1ziwv33c/FZ26/977Zi+gHCWAbSnyAI4n" <>
          "+4A2cAh1IADAAA"
    }
  ]

  # ── rows a producer matrix cannot reach ───────────────────────────────────
  # tarfile USTAR_FORMAT, hand-built TarInfos: dir mode 0644, index.html 0600, assets/page.html 0777
  # version: CPython 3.9.6  typeflags: 5 0 0  sha256: a6bd31ee7d23ec6f7170b391be83fba75bde22898ba5969e97f8a2ed67f0014a
  @modes_b64 "H4sIAJSFoWoC/+3UQQ6CMBRF0S4FNyAUWzpp2AtqIyaojdREd28Bo1ETZ6jReyb9ZcLg9f2qbV1oUz" <>
               "GmLCqU6s/o8exnqXSujMlU/93MskIkWrzBoQ3VPv5S/Kf1dumO0zpsmpHzf879lr8uHvM3RoskI//R" <>
               "2clytwgn75LuDZQ2rEPjyrm36TDZWpa1a5qdTeMk8GOqYf/7auVG2wJdxWOjX/Rf3/dfSpnn9P9z/e" <>
               "+ew3UD+MvVU38AAAAAAAAAAAAAAL7TGeyGE0oAKAAA"

  # tarfile USTAR_FORMAT: index.html, then dup.html TWICE (bodies 'first' then 'second')
  # version: CPython 3.9.6  typeflags: 0 0 0  sha256: 76c2188cc66f29ef97de8a99b449d8ae354dcfbdbe4a0913432e6829d24d92b7
  @python_ustar_duplicate_b64 "H4sIAIGLoWoC/+3TMQ6CMBSA4R4FLyDFlLI03EVpDSQVCJREb2/RSV1cwKj/t7yXN3Xo37TWnbd1OH" <>
                                "mxGBlppW4zep5S5lpkKt+popBqvmfzTSRSrGAaw36ITxH/yWxsV4VL75L5D5QmNMG78tCb9L6ZOitr" <>
                                "531n0rgJ/Bg79QvX/0b/MfaH/mWhtKT/NRybYQxkQP8f7V+/9p/R/xpGV3WtpQMAAAAAAAAAAAAA+H" <>
                                "ZXcn1KaAAoAAA="

  # tarfile USTAR_FORMAT: index.html + SYMTYPE leak.txt -> /opt/barkpark/.env
  # version: CPython 3.9.6  typeflags: 0 2  sha256: f7adda6bdfe0b3579e224bd7b9325176fbbf53d36b6ee4a958bdedbb4de18233
  @python_ustar_symlink_b64 "H4sIAIGLoWoC/+3TQQ6CMBCF4R4FL0ALVrppuAtKEwhViI5Gb2/RjZq41IX+X9LMy2zaRV+/a8M572" <>
                              "Qb1ceYpLL2NpPXacyqUoVdldY5Y+d9Me9UZtQXHA/S7NNT1H/yi3bcyGUK2fwHai+9xFCvJ6/vyXdF" <>
                              "3YUYR69TUvgxMTRDLmf55B1zxZ1z7/uf8nP/S7c0Kiv1OIleN/thSkfnYXei/wAAAAAAAAAAAAAAAM" <>
                              "CDK6MaLlwAKAAA"

  # tarfile USTAR_FORMAT: index.html + suid.bin with mode 04755
  # version: CPython 3.9.6  typeflags: 0 0  sha256: 7002b1a7bb7b12866e26557a9374fd0c14cfae4dfc132db7139390000e86db93
  @python_ustar_setuid_b64 "H4sIAIGLoWoC/+3TMQ6CQBCF4T0KXgAWM0CzodPKS4hsAskKRJdEK6/uopUmlpCo/9fMZJqZYl7b1f" <>
                             "YSN/7o1Gx0kIs8avBetc5ylUq2lqLQMs3TaaYirRYwnv3+FE5R/8ms6v7gr4ONph8ojW+9s2U1mOTZ" <>
                             "mSYtG+tcb5LQKfyY89jWcdV2c+4IaZYiyz7nX8tr/nUhkpP/Jdw2uy0pAAAAAAAAAAAAAAAA+F53VT" <>
                             "EDmgAoAAA="

  # tarfile USTAR_FORMAT: index.html + LNKTYPE alias.html -> index.html
  # version: CPython 3.9.6  typeflags: 0 1  sha256: e11fb6898d78966453ee636e78c2c237ab13c1ebae70d947912e8b5e8b58a982
  @python_ustar_hardlink_b64 "H4sIAIGLoWoC/+3UQQ6CMBCF4TkKXkBaU2DTcBeUJm1ShUhN9PYWXelejPJ/m3mZVRd9E069u259Ok" <>
                               "b5GJXVxjxm9j6VqmrRptqZplFm3ut5J4WSBVym1J3zU2Sd7KYfDuk2umL+A61NIUXX7kdbPpP1uvUu" <>
                               "xsGWOQn+TBdDN327/zm/9l83lZJChwWO08r7DwAAAAAAAAAAAAAAgN92B+MRc8gAKAAA"

  setup do
    base = Path.join(System.tmp_dir!(), "bp-dialect-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base, dest: Path.join(base, "current")}
  end

  # ── the name shapes, from NUMERIC CODEPOINTS ONLY ─────────────────────────

  defp component(:ascii), do: "assets"
  # LATIN SMALL LETTER E WITH ACUTE, precomposed.
  defp component(:nfc), do: "caf" <> <<0xE9::utf8>>
  # LATIN SMALL LETTER E + COMBINING ACUTE ACCENT.
  defp component(:nfd), do: "cafe" <> <<0x301::utf8>>
  defp component(:long), do: String.duplicate("l", 121)

  # ── helpers ───────────────────────────────────────────────────────────────

  defp stage_b64(b64, dest) do
    raw = Base.decode64!(b64)
    sha = :sha256 |> :crypto.hash(raw) |> Base.encode16(case: :lower)
    {PrebuiltArtifact.stage(b64, sha, dest), sha}
  end

  # The platform's own answer for "what does this name look like when read
  # back". Derived from the fixture's bytes, never from `stage/4`'s output — see
  # the moduledoc. Identity on a normalisation-preserving filesystem.
  defp platform_form(segment) do
    dir = Path.join(System.tmp_dir!(), "bp-form-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, segment))
    [reported] = File.ls!(dir)
    File.rm_rf!(dir)
    reported
  end

  defp platform_path(path) do
    path |> String.split("/") |> Enum.map_join("/", &platform_form/1)
  end

  # The comparator. Excludes mode, uid, gid and mtime; keeps path, kind and size.
  defp staged_tree(dest) do
    base = Path.expand(dest)

    (base <> "/**")
    |> Path.wildcard(match_dot: true)
    |> Enum.map(fn p ->
      stat = File.lstat!(p)
      rel = Path.relative_to(p, base)

      {rel, if(stat.type == :directory, do: :dir, else: :file),
       if(stat.type == :directory, do: 0, else: stat.size)}
    end)
    |> Enum.sort()
  end

  # `:erl_tar.table/2` is the named oracle for every accept row. It hands back
  # CHARLISTS (an NFD name arrives holding codepoint 769), so every name is
  # re-encoded to a UTF-8 binary before anything is compared. `./` is stripped
  # and a bare `.` dropped; a trailing `/` on a directory entry is dropped too.
  defp oracle_names(b64, base) do
    file = Path.join(base, "oracle-#{System.unique_integer([:positive])}.tar.gz")
    File.write!(file, Base.decode64!(b64))

    {:ok, names} = :erl_tar.table(String.to_charlist(file), [:compressed])

    names
    |> Enum.map(&List.to_string/1)
    |> Enum.map(&String.replace_prefix(&1, "./", ""))
    |> Enum.map(&String.trim_trailing(&1, "/"))
    |> Enum.reject(&(&1 in ["", "."]))
    |> Enum.map(&platform_path/1)
    |> with_implicit_parents()
    |> Enum.sort()
  end

  # A tar need not carry a header for a parent directory — `:erl_tar.create/3`
  # emits none, so its own archives list 2 names where the staged tree holds 3.
  # The extractor creates the parent (`File.mkdir_p/1`), so the oracle's list is
  # completed the same way rather than the staged tree being trimmed to it.
  defp with_implicit_parents(names) do
    names
    |> Enum.flat_map(fn name ->
      name
      |> String.split("/")
      |> Enum.scan(&(&2 <> "/" <> &1))
    end)
    |> Enum.uniq()
  end

  defp expected_tree(:standard, shape) do
    c = platform_path(component(shape))

    Enum.sort([
      {c, :dir, 0},
      {c <> "/page.html", :file, byte_size(@page)},
      {"index.html", :file, byte_size(@index)}
    ])
  end

  # bsdtar on macOS writes an AppleDouble sidecar for the walked root, for each
  # top-level entry and for the leaf — four `._*` files that `stage/4` accepts as
  # ordinary regular files and SERVES. That is a real property of a macOS-packed
  # bundle, pinned here rather than smoothed away.
  defp expected_tree(:standard_plus_appledouble, shape) do
    c = platform_path(component(shape))

    Enum.sort([
      {"._.", :file, @appledouble_bytes},
      {"._" <> c, :file, @appledouble_bytes},
      {"._index.html", :file, @appledouble_bytes},
      {c, :dir, 0},
      {c <> "/._page.html", :file, @appledouble_bytes},
      {c <> "/page.html", :file, byte_size(@page)},
      {"index.html", :file, byte_size(@index)}
    ])
  end

  # ── THE MATRIX ────────────────────────────────────────────────────────────

  describe "producer x name-shape matrix (pinned archives)" do
    for row <- @matrix do
      @row row

      test "#{row.producer} x #{row.shape} -> #{inspect(row.expect)}", %{base: base, dest: dest} do
        {verdict, sha} = stage_b64(@row.b64, dest)

        assert sha == @row.sha256,
               "the pinned archive changed under its own row: #{sha}"

        assert @row.typeflags == typeflags(@row.b64),
               "the typeflag sequence read at byte 156 moved for #{@row.producer}/#{@row.shape}"

        assert_cell(@row.expect, verdict, @row, dest, base)
      end
    end
  end

  # Function clauses, not a `case` on `@row.expect`: the row is a literal, so an
  # inline `case` lets the compiler prove one arm dead and warn on every green
  # cell.
  defp assert_cell({:ok, entries}, verdict, row, dest, base) do
    assert {:ok, summary} = verdict
    assert summary.entries == entries
    assert staged_tree(dest) == expected_tree(row.tree, row.shape)

    # the named oracle, independently
    observed = Enum.sort(Enum.map(staged_tree(dest), &elem(&1, 0)))
    assert observed == oracle_names(row.b64, base)

    # staged path BYTES for the two files every dist carries
    assert File.read!(Path.join(dest, "index.html")) == @index

    assert File.read!(Path.join(dest, platform_path(component(row.shape)) <> "/page.html")) ==
             @page
  end

  defp assert_cell({:error, code}, verdict, _row, dest, _base) do
    assert {:error, ^code, message} = verdict
    assert is_binary(message) and message != ""
    refute File.exists?(dest), "a refusal must leave no partial tree"
  end

  # The typeflag at byte 156 of every 512-byte header block, in order — the one
  # field that says which DIALECT a producer wrote. Read from the pinned bytes so
  # a re-cut fixture cannot silently change dialect under a green row.
  defp typeflags(b64) do
    raw = b64 |> Base.decode64!() |> :zlib.gunzip()

    0
    |> Stream.unfold(fn offset -> next_typeflag(raw, offset) end)
    |> Enum.join(" ")
  end

  defp next_typeflag(raw, offset) when byte_size(raw) - offset < 512, do: nil

  defp next_typeflag(raw, offset) do
    <<_::binary-size(offset), block::binary-size(512), _::binary>> = raw

    if block == :binary.copy(<<0>>, 512) do
      nil
    else
      <<_::binary-size(124), size_field::binary-size(12), _::binary>> = block
      <<_::binary-size(156), flag::binary-size(1), _::binary>> = block
      size = octal(size_field)
      flag = if flag == <<0>>, do: "0", else: flag
      {flag, offset + 512 + div(size + 511, 512) * 512}
    end
  end

  defp octal(field) do
    case field |> :binary.split(<<0>>) |> hd() |> String.trim() do
      "" ->
        0

      digits ->
        case Integer.parse(digits, 8) do
          {v, _} -> v
          :error -> 0
        end
    end
  end

  # ── THE CENTRAL INVERSION ─────────────────────────────────────────────────

  describe "the GNU/gocli inversion" do
    test "GNU tar writes a RAW UTF-8 NFD name into an ORDINARY ustar header and it stages byte-exact",
         %{base: base, dest: dest} do
      row = row(:gnutar, :nfd)

      # 5 0 5 0: dir, file, dir, file. No `x`, no `L` — an ordinary ustar
      # header carrying the accented bytes raw.
      assert row.typeflags == "5 0 5 0"
      refute String.contains?(row.typeflags, "x")

      # the accented bytes really are IN the header, undecomposed and unescaped
      raw = row.b64 |> Base.decode64!() |> :zlib.gunzip()
      assert String.contains?(raw, "cafe" <> <<0x301::utf8>>)
      refute String.contains?(raw, "caf" <> <<0xE9::utf8>>)

      assert {{:ok, summary}, _sha} = stage_b64(row.b64, dest)
      assert summary.entries == 4
      assert staged_tree(dest) == expected_tree(:standard, :nfd)
      assert Enum.sort(Enum.map(staged_tree(dest), &elem(&1, 0))) == oracle_names(row.b64, base)
    end

    test "our own packer needs a pax `x` block for the SAME dist — GNU tar needs none",
         %{dest: dest} do
      # THIS IS THE ASYMMETRY THE WAVE FOUND, and it is a FORMAT asymmetry that
      # survives `ssw10` even though the VERDICT half of it no longer does.
      #
      # Before ssw10, `x` was `E_UNKNOWN_TYPE` and this cell was the finding:
      # our first-party CLI could not deploy a `café/` slug at all while GNU tar
      # sailed through — the stricter client was OURS. ssw10 taught the extractor
      # to apply-then-re-validate `x`, so both now stage. What did NOT change is
      # who writes what: Go's `archive/tar` elects PAX for any non-ASCII name,
      # GNU tar does not.
      assert row(:gocli, :nfd).typeflags == "x 5 x 0 0"
      assert row(:gnutar, :nfd).typeflags == "5 0 5 0"

      assert {{:ok, _}, _} = stage_b64(row(:gocli, :nfd).b64, dest)
    end

    test "on a >100-byte component the asymmetry REVERSES: GNU tar is the one that breaks",
         %{dest: dest} do
      # GNU writes `././@LongLink` (typeflag `L`) whose two shadow headers carry
      # only a TRUNCATED 100-byte name; the extractor refuses rather than stage
      # two entries onto one effective path.
      gnu = row(:gnutar, :long)
      assert gnu.typeflags == "5 0 L 5 L 0"
      assert {{:error, "E_UNKNOWN_TYPE", message}, _} = stage_b64(gnu.b64, dest)
      assert message =~ "GNU long"

      # Our packer splits the leaf into the ustar prefix and pax-wraps only the
      # DIRECTORY header (whose name ends in `/`, leaving an empty name field) —
      # and that stages.
      go = row(:gocli, :long)
      assert go.typeflags == "0 x 5 0"
      assert {{:ok, summary}, _} = stage_b64(go.b64, Path.join(Path.dirname(dest), "go-long"))
      assert summary.entries == 3
    end
  end

  defp row(producer, shape) do
    Enum.find(@matrix, &(&1.producer == producer and &1.shape == shape)) ||
      flunk("no matrix row for #{producer}/#{shape}")
  end

  # ── THE FOUR PREVIOUSLY-DERIVED CELLS, PINNED AS CORRECTED ────────────────

  describe "corrected cells" do
    test "COPYFILE_DISABLE=1 does NOT rescue bsdtar: it still writes `x` on all four shapes" do
      # The wave's first derivation called COPYFILE_DISABLE the Mac escape hatch.
      # It is not: it removes the AppleDouble sidecars and NOTHING else. bsdtar
      # elects pax for EVERY entry, ASCII included.
      for shape <- [:ascii, :nfc, :nfd, :long] do
        assert row(:bsdtar_copyfile_disable, shape).typeflags == "x 5 x 0 x 5 x 0",
               "COPYFILE_DISABLE=1 changed bsdtar's dialect for #{shape}"
      end

      # what it DOES change: the four `._*` sidecars are gone.
      assert row(:bsdtar, :ascii).typeflags == "0 x 5 0 x 0 0 x 5 0 x 0"
      assert row(:bsdtar, :ascii).tree == :standard_plus_appledouble
      assert row(:bsdtar_copyfile_disable, :ascii).tree == :standard
    end

    test "the unsplittability trigger is Go-SPECIFIC: :erl_tar writes a 121-byte component with NO extension header" do
      # Go pax-wraps the DIRECTORY header for a 121-byte component because its
      # name ends in `/` and the ustar split would leave an empty name field.
      # :erl_tar emits no dir header at all and splits the leaf into the ustar
      # prefix cleanly — two plain typeflag-0 headers, and it stages.
      assert row(:erl_tar, :long).typeflags == "0 0"
      assert row(:erl_tar, :long).expect == {:ok, 2}
      assert row(:gocli, :long).typeflags == "0 x 5 0"
    end

    test "CPython tarfile's DEFAULT elects pax for a PURE-ASCII dist on a sub-second mtime" do
      # No accent anywhere in this cell. tarfile's default is PAX_FORMAT and a
      # sub-second mtime is a value ustar's octal mtime field cannot hold, so
      # every entry gets an `x` block named `./PaxHeader/...`.
      assert row(:python_default, :ascii).typeflags == "x 5 x 5 x 0 x 0"
      assert row(:python_ustar, :ascii).typeflags == "5 5 0 0"
    end

    test "CPython tarfile FORCED to USTAR_FORMAT writes raw NFD and it stages", %{dest: dest} do
      r = row(:python_ustar, :nfd)
      assert r.typeflags == "5 5 0 0"
      raw = r.b64 |> Base.decode64!() |> :zlib.gunzip()
      assert String.contains?(raw, "cafe" <> <<0x301::utf8>>)
      assert {{:ok, summary}, _} = stage_b64(r.b64, dest)
      assert summary.entries == 4
    end
  end

  # ── THE FIXTURE FORMS ─────────────────────────────────────────────────────

  describe "the accented fixtures" do
    test "each accented component is the normalisation form its row claims" do
      nfc = component(:nfc)
      nfd = component(:nfd)

      assert byte_size(nfc) == 5
      assert byte_size(nfd) == 6
      assert nfc == :unicode.characters_to_nfc_binary(nfc)
      assert nfd == :unicode.characters_to_nfd_binary(nfd)
      refute nfc == nfd
      # same grapheme, different bytes — which is the whole defect class
      assert :unicode.characters_to_nfc_binary(nfd) == nfc
    end

    test "the comparator does not normalise NFC to NFD" do
      # DELIBERATE. A staged `cafe`+U+0301 for a site whose links say `café/` is
      # a 404, so the two forms must never compare equal anywhere in this file.
      nfc_tree = expected_tree(:standard, :nfc)
      nfd_tree = expected_tree(:standard, :nfd)

      # On a normalisation-preserving filesystem these differ. On Darwin OTP's
      # filename layer reports both as NFC (measured: File.ls!/1,
      # :file.list_dir/1, :file.list_dir_all/1 and :prim_file.list_dir_all/1 all
      # return `caf`+U+00E9 for on-disk bytes `cafe`+U+0301), so the trees can
      # coincide there — which is exactly why the form assert below is made on
      # the ARCHIVE bytes, where no filesystem can interfere.
      _ = {nfc_tree, nfd_tree}

      nfc_raw = row(:python_ustar, :nfc).b64 |> Base.decode64!() |> :zlib.gunzip()
      nfd_raw = row(:python_ustar, :nfd).b64 |> Base.decode64!() |> :zlib.gunzip()

      assert String.contains?(nfc_raw, "caf" <> <<0xE9::utf8>>)
      refute String.contains?(nfc_raw, "cafe" <> <<0x301::utf8>>)
      assert String.contains?(nfd_raw, "cafe" <> <<0x301::utf8>>)
      refute String.contains?(nfd_raw, "caf" <> <<0xE9::utf8>>)
    end
  end

  # ── PROVENANCE for the GENERATED rows ─────────────────────────────────────

  describe ":erl_tar rows (generated at run time)" do
    # The census ran on OTP 28 and the serving box runs OTP 27, so the OTP
    # release is part of every :erl_tar verdict, not a footnote.
    @otp_release_at_pin "28"

    setup %{base: base} do
      {:ok, otp: List.to_string(:erlang.system_info(:otp_release)), base: base}
    end

    test "the pinned :erl_tar rows were measured on a recorded OTP release", %{otp: otp} do
      assert otp =~ ~r/^\d+$/

      # Not an assert that they are EQUAL — a row that only passes on the pinner's
      # OTP is a rotted row. This records what ran, so a differing verdict below
      # is attributable.
      if otp != @otp_release_at_pin do
        IO.puts(
          "\n  [dialect matrix] :erl_tar rows pinned on OTP #{@otp_release_at_pin}, " <>
            "running on OTP #{otp}"
        )
      end
    end

    for shape <- [:ascii, :nfc, :nfd, :long] do
      @shape shape

      test ":erl_tar.create/3 x #{shape} stages, on this host's OTP", %{base: base, otp: otp} do
        c = component(@shape)
        src = Path.join(base, "erl-src-#{@shape}")
        File.mkdir_p!(Path.join(src, c))
        File.write!(Path.join(src, "index.html"), @index)
        File.write!(Path.join([src, c, "page.html"]), @page)

        out = Path.join(base, "erl-#{@shape}.tar.gz")

        :ok =
          :erl_tar.create(
            String.to_charlist(out),
            [
              {~c"index.html", String.to_charlist(Path.join(src, "index.html"))},
              {String.to_charlist(c), String.to_charlist(Path.join(src, c))}
            ],
            [:compressed]
          )

        b64 = out |> File.read!() |> Base.encode64()
        dest = Path.join(base, "erl-dest-#{@shape}")

        assert {{:ok, summary}, _sha} = stage_b64(b64, dest),
               "OTP #{otp}: :erl_tar's own bytes were refused"

        assert summary.entries == 2, "OTP #{otp}"
        assert staged_tree(dest) == expected_tree(:standard, @shape), "OTP #{otp}"
        assert File.read!(Path.join(dest, "index.html")) == @index

        # the typeflag sequence THIS OTP wrote, recorded next to the verdict
        seq = typeflags(b64)

        assert seq == row(:erl_tar, @shape).typeflags,
               "OTP #{otp} wrote typeflags #{inspect(seq)}; " <>
                 "OTP #{@otp_release_at_pin} wrote #{inspect(row(:erl_tar, @shape).typeflags)}"
      end
    end
  end

  # ── MODES ARE REWRITTEN (the reason the comparator excludes them) ──────────

  describe "the mode row" do
    test "a 0644 dir / 0600 index / 0777 leaf archive stages 40755 and 100644", %{dest: dest} do
      assert {{:ok, summary}, _} = stage_b64(@modes_b64, dest)
      assert summary.entries == 3

      assert File.lstat!(Path.join(dest, "assets")).mode == 0o40755
      assert File.lstat!(Path.join(dest, "index.html")).mode == 0o100644
      assert File.lstat!(Path.join(dest, "assets/page.html")).mode == 0o100644
    end

    test "the oracle cannot even extract this archive — the measured reason mode is excluded",
         %{base: base} do
      file = Path.join(base, "modes.tar.gz")
      File.write!(file, Base.decode64!(@modes_b64))
      out = Path.join(base, "modes-oracle")
      File.mkdir_p!(out)

      # :erl_tar HONOURS the declared 0644 directory mode and then cannot write
      # into it. Any comparator that walked an oracle tree would need a
      # `chmod -R u+rwX` first; this file compares `:erl_tar.table/2` instead,
      # which reads headers only.
      assert {:error, :eacces} =
               :erl_tar.extract(String.to_charlist(file), [
                 {:cwd, String.to_charlist(out)},
                 :compressed
               ])

      assert {:ok, names} = :erl_tar.table(String.to_charlist(file), [:compressed])

      assert Enum.map(names, &List.to_string/1) |> Enum.sort() == [
               "assets",
               "assets/page.html",
               "index.html"
             ]
    end
  end

  # ── ORACLE-EXEMPT ROWS ────────────────────────────────────────────────────

  describe "oracle-exempt rows" do
    # NO ORACLE IS AN AUTHORITY HERE. `stage/4` refuses each of these BY DESIGN,
    # and a differential against an oracle that accepts would be a demand for a
    # vulnerability, not a finding.

    test "duplicate names: the extractor refuses while BOTH oracles resolve last-wins",
         %{base: base, dest: dest} do
      assert {{:error, "E_UNSAFE_PARENT", message}, _} =
               stage_b64(@python_ustar_duplicate_b64, dest)

      assert message =~ "more than once"
      refute File.exists?(dest)

      # the oracle, contradicting: it stages `dup.html` and keeps the LAST body.
      file = Path.join(base, "dup.tar.gz")
      File.write!(file, Base.decode64!(@python_ustar_duplicate_b64))
      out = Path.join(base, "dup-oracle")
      File.mkdir_p!(out)

      assert :ok =
               :erl_tar.extract(String.to_charlist(file), [
                 {:cwd, String.to_charlist(out)},
                 :compressed
               ])

      assert File.read!(Path.join(out, "dup.html")) == "second"
    end

    test "a symlink is refused — a staged symlink is SERVED", %{dest: dest} do
      assert {{:error, "E_SYMLINK", message}, _} = stage_b64(@python_ustar_symlink_b64, dest)
      assert message =~ "SERVED"
      refute File.exists?(dest)
    end

    test "setuid is refused", %{dest: dest} do
      assert {{:error, "E_MODE_BITS", message}, _} = stage_b64(@python_ustar_setuid_b64, dest)
      assert message =~ "4755"
      refute File.exists?(dest)
    end

    test "a hard link is refused", %{dest: dest} do
      assert {{:error, "E_HARDLINK", _message}, _} = stage_b64(@python_ustar_hardlink_b64, dest)
      refute File.exists?(dest)
    end

    test "AppleDouble: the two oracles contradict, so the ROW pins what stage/4 does",
         %{base: base, dest: dest} do
      # bsdtar-as-oracle consumes `._*` back into xattrs and reports 3 entries;
      # :erl_tar-as-oracle stages them as 4 ordinary files. Neither is "right".
      # What is measurable, and what this row pins, is that `stage/4` stages them
      # as regular files — a macOS-packed bundle SERVES four AppleDouble sidecars.
      r = row(:bsdtar, :ascii)
      assert {{:ok, summary}, _} = stage_b64(r.b64, dest)
      assert summary.entries == 8

      assert Enum.sort(Enum.map(staged_tree(dest), &elem(&1, 0))) ==
               oracle_names(r.b64, base)

      assert File.lstat!(Path.join(dest, "._.")).size == @appledouble_bytes
      assert File.lstat!(Path.join(dest, "._index.html")).size == @appledouble_bytes
    end
  end

  # ── COVERAGE ──────────────────────────────────────────────────────────────

  test "the matrix really is 7 producers x 4 shapes" do
    producers = @matrix |> Enum.map(& &1.producer) |> Enum.uniq()
    shapes = @matrix |> Enum.map(& &1.shape) |> Enum.uniq()

    assert length(producers) == 7
    assert Enum.sort(shapes) == [:ascii, :long, :nfc, :nfd]
    assert length(@matrix) == 28
  end
end
