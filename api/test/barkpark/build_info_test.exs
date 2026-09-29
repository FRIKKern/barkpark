defmodule Barkpark.BuildInfoTest do
  @moduledoc """
  Pins the compile-time build identity contract (instance self-update):
  version "A.B.C.D" (D = commits since the vA.B.C tag), release = the first
  three segments, plus commit/built_at. Pure module attributes — no app, no
  DB, no git at test runtime.
  """
  # Pure reads of compile-time constants — safe to run concurrently.
  use ExUnit.Case, async: true

  alias Barkpark.BuildInfo
  alias Barkpark.BuildInfo.Resolve

  @version_re ~r/^(\d+\.\d+\.\d+\.\d+|unknown)$/

  # VERBATIM `Barkpark.SelfUpdate.Checker.parse_release/1`. Copied on purpose:
  # asserting against the checker's OWN private regex is impossible, and
  # asserting against a LOOSER one would pass on values the checker refuses.
  @parse_release_re ~r/^(\d+)\.(\d+)\.(\d+)$/

  # WRITTEN INLINE at the read site — scripts/elixir-path-escape-check.sh's
  # root-anchor door cannot see a path held one binding away. `VERSION` is
  # declared in that script's ELIXIR_COMPILE_PATHS.
  @repo_root Path.expand("../../..", __DIR__)

  test "version/release/commit/built_at return non-empty strings" do
    for value <- [
          BuildInfo.version(),
          BuildInfo.release(),
          BuildInfo.commit(),
          BuildInfo.built_at()
        ] do
      assert is_binary(value)
      assert value != ""
    end
  end

  test "version is A.B.C.D or unknown" do
    assert BuildInfo.version() =~ @version_re
  end

  test "version derives from git in this repo (baseline tag v0.2.23 exists)" do
    # This repo carries the v0.2.23 baseline tag, so `git describe` at
    # compile time must have succeeded — "unknown" here means derivation broke.
    assert BuildInfo.version() != "unknown"
    assert BuildInfo.commit() != "unknown"
  end

  test "release is the first three segments of version" do
    version = BuildInfo.version()

    if version == "unknown" do
      assert BuildInfo.release() == "unknown"
    else
      expected = version |> String.split(".") |> Enum.take(3) |> Enum.join(".")
      assert BuildInfo.release() == expected
    end
  end

  test "info/0 carries the four string keys" do
    info = BuildInfo.info()

    assert info == %{
             "version" => BuildInfo.version(),
             "release" => BuildInfo.release(),
             "commit" => BuildInfo.commit(),
             "built_at" => BuildInfo.built_at()
           }
  end

  describe "Resolve — the identity tiers a self-hoster actually has" do
    # THE SUBJECT. `Barkpark.BuildInfo`'s own values are frozen at compile time
    # from THIS checkout, which has a `.git` and a tag — so no assertion about
    # BuildInfo itself can observe the compose/tarball shape, and for a long
    # time nothing did. `Resolve` is the same precedence as a function of its
    # three inputs, so every tier gets staged here instead of in a container.

    test "the env hatch accepts a bare A.B.C — and that is the bug it used to hide" do
      # `BARKPARK_BUILD_VERSION` is documented for "docker/tarball builds
      # compiled without a .git directory", and A.B.C is what a self-hoster
      # writes: D is a commits-since-tag distance they cannot know. Before the
      # `.0` normalisation, setting the hatch EXACTLY as documented produced
      # version "0.2.26", whose release regex (^A.B.C.D$) then failed, and the
      # whole identity collapsed to "unknown" anyway.
      assert Resolve.version("0.2.26", nil, nil) == "0.2.26.0"
      assert Resolve.release(Resolve.version("0.2.26", nil, nil)) == "0.2.26"
      assert Resolve.release(Resolve.version("0.2.26", nil, nil)) =~ @parse_release_re
    end

    test "the env hatch accepts A.B.C.D and a leading v" do
      assert Resolve.version("0.2.26.7", nil, nil) == "0.2.26.7"
      assert Resolve.version("v0.2.26", nil, nil) == "0.2.26.0"
      assert Resolve.version(" 0.2.26\n", nil, nil) == "0.2.26.0"
    end

    test "git describe wins over the VERSION file — it is strictly more precise" do
      # Only describe carries D. A maintainer checkout must keep using it even
      # though the file is right there.
      assert Resolve.version(nil, "v0.2.26-7-gc707108", "0.9.9") == "0.2.26.7"
      assert Resolve.version(nil, "v0.2.26", "0.9.9") == "0.2.26.0"
    end

    test "the env hatch wins over git describe" do
      assert Resolve.version("1.2.3", "v0.2.26-7-gc707108", "0.9.9") == "1.2.3.0"
    end

    test "THE DOCKER/TARBALL SHAPE: no describe output at all, VERSION file only" do
      # `.git` is excluded from the image build context and a release tarball
      # has neither `.git` nor a tag, so `git` returns nil. This tier is the
      # whole fix.
      assert Resolve.version(nil, nil, "0.2.26") == "0.2.26.0"
      assert Resolve.release(Resolve.version(nil, nil, "0.2.26")) =~ @parse_release_re
    end

    test "CONTROL: with no tier at all the identity is \"unknown\" — the pre-fix state" do
      # Without this the test above proves nothing: it must be possible to fail.
      assert Resolve.version(nil, nil, nil) == "unknown"
      assert Resolve.release(Resolve.version(nil, nil, nil)) == "unknown"
      refute Resolve.release(Resolve.version(nil, nil, nil)) =~ @parse_release_re
    end

    test "every malformed input degrades to unknown, never to a half-version" do
      for bad <- ["", "  ", "unknown", "0.2", "0.2.x", "1.2.3.4.5", "v", "latest", 7, nil] do
        assert Resolve.normalize_version(bad) == nil
      end

      for bad <- ["0.2.26-rc1", "v0.2.26-rc1-3-gabc", "garbage", "", nil, 7] do
        assert Resolve.from_describe(bad) == nil
      end

      for bad <- ["0.2.26", "unknown", "", nil, 7] do
        assert Resolve.release(bad) == "unknown"
      end
    end
  end

  describe "the checked-in VERSION file" do
    test "exists, holds one A.B.C line, and yields a release parse_release/1 accepts" do
      # THE STALENESS/TYPO GUARD. This file is the ONLY identity a compose or
      # tarball install has. A typo in it is invisible everywhere else: the
      # image still builds, boots and serves, and only the self-update check and
      # the Studio nav quietly say "unknown".
      raw = File.read!(Path.join(@repo_root, "VERSION"))
      line = raw |> String.split("\n", parts: 2) |> hd() |> String.trim()

      assert line =~ ~r/^\d+\.\d+\.\d+$/,
             "VERSION must hold a bare A.B.C release on its first line, got #{inspect(line)}"

      assert Resolve.release(Resolve.version(nil, nil, line)) =~ @parse_release_re
    end
  end
end
