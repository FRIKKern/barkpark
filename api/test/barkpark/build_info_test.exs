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

  @version_re ~r/^(\d+\.\d+\.\d+\.\d+|unknown)$/

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
end
