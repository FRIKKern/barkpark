defmodule Barkpark.BuildInfo do
  @moduledoc """
  COMPILE-TIME build identity: `version`, `release`, `commit`, `built_at`.

  Every value is resolved while this module compiles and frozen into module
  attributes. Compile-time is CORRECT here, not a shortcut: the build IS the
  code as of compile — prod deploys are clean full builds (`rm -rf _build` +
  recompile, per the Golden Rules), so a running BEAM can never carry a stale
  BuildInfo without also carrying stale code. A runtime lookup would only add
  failure modes (no git on the box, wrong cwd) for no gain.

  Resolution order, per value:

    1. env var override — `BARKPARK_BUILD_VERSION` / `BARKPARK_BUILD_COMMIT` /
       `BARKPARK_BUILD_DATE` — for docker/tarball builds compiled without a
       `.git` directory (read at COMPILE time, like everything else here);
    2. derived from git at compile time (`git describe` / `git rev-parse`,
       run in the repo root);
    3. `"unknown"` — a missing git binary, a checkout with no `v*` tag, or
       any command failure degrades to `"unknown"`, never a compile error.

  Versioning rule (2026-07-02, baseline tag v0.2.23): version = `A.B.C.D`
  where the git tag `vA.B.C` carries the release and `D` = commits since that
  tag. `git describe --tags --match 'v[0-9]*'` yields `vA.B.C-D-g<sha>`
  (exactly on the tag it yields bare `vA.B.C`, i.e. D=0). "Update available"
  compares releases (the first three segments) only — D never matters.
  NOTE: the bp CLI has a SEPARATE version space (`cli-v*` tags, cliVersion
  ldflag) — the `v[0-9]*` match glob deliberately excludes those.
  """

  # Repo root: this file sits at api/lib/barkpark/, so the root is three
  # directories up. Resolved from __DIR__ at compile time.
  @repo_root Path.expand("../../..", __DIR__)

  # ── Compile-time derivation ────────────────────────────────────────────
  #
  # Anonymous fns, not defp — a module cannot call its own functions while
  # its body is still being compiled.

  # Non-empty env var or nil.
  env = fn name ->
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  # Run git in the repo root; trimmed stdout on exit 0, nil on ANY failure
  # (non-zero exit, missing binary, missing cwd) — fail-closed to "unknown".
  git = fn args ->
    try do
      case System.cmd("git", args, cd: @repo_root, stderr_to_stdout: true) do
        {out, 0} -> String.trim(out)
        _ -> nil
      end
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  version =
    env.("BARKPARK_BUILD_VERSION") ||
      case git.([
             "describe",
             "--tags",
             "--match",
             "v[0-9]*",
             # Release tags are STRICTLY vA.B.C (versioning rule 2026-07-02).
             # Without the excludes, a nearest v0.3.0-rc1 / v2-beta tag wins
             # the describe, fails the regex below, and silently collapses
             # the whole build identity to "unknown".
             "--exclude",
             "v*-*",
             "--exclude",
             "v*[a-zA-Z]*"
           ]) do
        nil ->
          "unknown"

        described ->
          # "v0.2.23-7-gc707108" -> "0.2.23.7"; bare "v0.2.23" -> "0.2.23.0".
          case Regex.run(~r/^v(\d+\.\d+\.\d+)(?:-(\d+)-g[0-9a-f]+)?$/, described) do
            [_, release] -> release <> ".0"
            [_, release, commits] -> release <> "." <> commits
            _ -> "unknown"
          end
      end

  # Release = the first three segments of an A.B.C.D version; anything
  # malformed (including "unknown") degrades to "unknown".
  release =
    case Regex.run(~r/^(\d+\.\d+\.\d+)\.\d+$/, version) do
      [_, release] -> release
      _ -> "unknown"
    end

  commit =
    env.("BARKPARK_BUILD_COMMIT") || git.(["rev-parse", "--short", "HEAD"]) || "unknown"

  built_at =
    env.("BARKPARK_BUILD_DATE") ||
      DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @version version
  @release release
  @commit commit
  @built_at built_at

  # ── Public API ─────────────────────────────────────────────────────────

  @doc ~S|Build version "A.B.C.D" (D = commits since the vA.B.C tag), or "unknown".|
  @spec version() :: String.t()
  def version, do: @version

  @doc ~S|Release "A.B.C" — the first three segments of version — or "unknown".|
  @spec release() :: String.t()
  def release, do: @release

  @doc ~S|Short git sha of the built commit, or "unknown".|
  @spec commit() :: String.t()
  def commit, do: @commit

  @doc ~S|Build timestamp, UTC ISO8601 (frozen at compile time), or "unknown".|
  @spec built_at() :: String.t()
  def built_at, do: @built_at

  @doc """
  All four values as a string-keyed map — the wire shape the
  `/v1/capabilities` manifest embeds under its top-level `"build"` key.
  """
  @spec info() :: %{String.t() => String.t()}
  def info do
    %{
      "version" => @version,
      "release" => @release,
      "commit" => @commit,
      "built_at" => @built_at
    }
  end
end
