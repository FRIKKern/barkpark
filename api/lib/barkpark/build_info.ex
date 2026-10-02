defmodule Barkpark.BuildInfo.Resolve do
  @moduledoc """
  The PURE half of `Barkpark.BuildInfo` — normalisation and precedence, with
  every input passed in.

  It lives in the same file, above `Barkpark.BuildInfo`, for one mechanical
  reason: a module cannot call its OWN functions while its body is still being
  compiled, but it CAN call a module the compiler has already finished — and
  within a single file Elixir compiles modules in source order. So BuildInfo's
  compile-time body calls these functions directly, and the SAME functions are
  what the test suite exercises with synthetic inputs.

  That matters because the interesting cases are the ones no test can stage by
  compiling BuildInfo: a build with NO `.git` (docker), a tarball with neither
  `.git` nor a tag, and the env hatch carrying a bare `A.B.C`. Before this
  split the only way to observe any of them was to build a container. Now the
  precedence is a function of three arguments and every tier has a test.
  """

  # A version as WRITTEN by a human or a release pipeline: `A.B.C` or
  # `A.B.C.D`, with an optional leading `v`. Anything else is not a version.
  @written_re ~r/^v?(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?$/

  # `git describe --tags` output: `vA.B.C` exactly on the tag, else
  # `vA.B.C-<commits>-g<sha>`.
  @describe_re ~r/^v(\d+\.\d+\.\d+)(?:-(\d+)-g[0-9a-f]+)?$/

  # `release/1`'s shape, and DELIBERATELY the same regex
  # `Barkpark.SelfUpdate.Checker.parse_release/1` applies to the result.
  @release_re ~r/^(\d+\.\d+\.\d+)\.(\d+)$/

  @doc ~S"""
  Normalise a written version to the canonical `"A.B.C.D"`, or `nil`.

  `"0.2.26"` and `"v0.2.26"` both become `"0.2.26.0"`. THE `.0` IS THE POINT:
  `release/1` (and the self-update checker behind it) reads the first three
  segments of a FOUR-segment version, so a hatch value of `"0.2.26"` used to
  normalise to nothing and collapse the whole identity to `"unknown"` — the
  documented escape hatch, set correctly, still yielding the bug it exists to
  fix. A self-hoster writes the release they have; `D` (commits since the tag)
  is a maintainer-checkout fact they cannot know, and `0` is its honest value.
  """
  @spec normalize_version(String.t() | nil) :: String.t() | nil
  def normalize_version(nil), do: nil

  def normalize_version(raw) when is_binary(raw) do
    case Regex.run(@written_re, String.trim(raw)) do
      [_, a, b, c] -> Enum.join([a, b, c, "0"], ".")
      [_, a, b, c, d] -> Enum.join([a, b, c, d], ".")
      _ -> nil
    end
  end

  def normalize_version(_other), do: nil

  @doc ~S"""
  `git describe` output -> `"A.B.C.D"`, or `nil` on anything unparseable
  (including `nil`, which is what a failed/absent git call hands over).
  """
  @spec from_describe(String.t() | nil) :: String.t() | nil
  def from_describe(nil), do: nil

  def from_describe(described) when is_binary(described) do
    case Regex.run(@describe_re, String.trim(described)) do
      [_, release] -> release <> ".0"
      [_, release, commits] -> release <> "." <> commits
      _ -> nil
    end
  end

  def from_describe(_other), do: nil

  @doc ~S"""
  The precedence, as one function of the three inputs BuildInfo can see.

  1. `env_value` — `BARKPARK_BUILD_VERSION`, the explicit operator override;
  2. `describe_output` — `git describe` in the repo root. It wins over the
     VERSION file in a real checkout because it is STRICTLY more precise: it
     carries `D`, the commits-since-tag distance, which no checked-in file can
     know;
  3. `version_file` — the checked-in `VERSION` marker at the repo root. This is
     the tier a self-hoster actually has: it survives `git archive`, a release
     tarball, and a docker build context with `.git` excluded, all of which
     kill tier 2.
  4. otherwise `"unknown"`.
  """
  @spec version(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t()
  def version(env_value, describe_output, version_file) do
    normalize_version(env_value) ||
      from_describe(describe_output) ||
      normalize_version(version_file) ||
      "unknown"
  end

  @doc ~S"""
  Release `"A.B.C"` — the first three segments of an `A.B.C.D` version.
  Anything malformed (`"unknown"` included) degrades to `"unknown"`.
  """
  @spec release(String.t() | nil) :: String.t()
  def release(version) when is_binary(version) do
    case Regex.run(@release_re, version) do
      [_, release, _d] -> release
      _ -> "unknown"
    end
  end

  def release(_other), do: "unknown"
end

defmodule Barkpark.BuildInfo do
  @moduledoc """
  COMPILE-TIME build identity: `version`, `release`, `commit`, `built_at`.

  Every value is resolved while this module compiles and frozen into module
  attributes. Compile-time is CORRECT here, not a shortcut: the build IS the
  code as of compile — prod deploys are clean full builds (`rm -rf _build` +
  recompile, per the Golden Rules), so a running BEAM can never carry a stale
  BuildInfo without also carrying stale code. A runtime lookup would only add
  failure modes (no git on the box, wrong cwd) for no gain.

  Resolution order for `version` (see `Barkpark.BuildInfo.Resolve.version/3`,
  which is where it is actually implemented and tested):

    1. env var override — `BARKPARK_BUILD_VERSION` — for docker/tarball builds
       that want to state the identity explicitly (read at COMPILE time, like
       everything else here). `A.B.C` and `A.B.C.D` are both accepted;
    2. derived from git at compile time (`git describe`, run in the repo root);
    3. the checked-in `VERSION` file at the repo root — `A.B.C`, one line. THIS
       IS THE TIER THAT MAKES A SELF-HOST BUILD REAL: a docker build context
       excludes `.git` (see `api/Dockerfile.dockerignore`) and a release tarball
       has neither `.git` nor a tag, so tier 2 cannot fire on either, and before
       this tier existed every compose install reported release `"unknown"` —
       which the self-update checker's `parse_release/1` refuses, permanently
       disabling the update check on the one install shape it is for
       (task-2ab4f5f0a07e887a). `api/Dockerfile` COPYs the file into the image's
       repo root so tier 3 resolves inside the build;
    4. `"unknown"` — everything failed. Never a compile error.

  `commit` and `built_at` take `BARKPARK_BUILD_COMMIT` / `BARKPARK_BUILD_DATE`
  first and degrade the same way. They are allowed to be `"unknown"`: the
  update check keys on `release` alone.

  KEEPING `VERSION` HONEST: it is the release the tree is ON, bumped with the
  `vA.B.C` tag. A stale file only affects builds WITHOUT `.git` (the maintainer
  checkout keeps using the more precise `git describe`), and its failure mode is
  benign — a self-hoster is told they are behind when they are not, never that
  they are current when they are not.

  Versioning rule (2026-07-02, baseline tag v0.2.23): version = `A.B.C.D`
  where the git tag `vA.B.C` carries the release and `D` = commits since that
  tag. `git describe --tags --match 'v[0-9]*'` yields `vA.B.C-D-g<sha>`
  (exactly on the tag it yields bare `vA.B.C`, i.e. D=0). "Update available"
  compares releases (the first three segments) only — D never matters.
  NOTE: the bp CLI has a SEPARATE version space (`cli-v*` tags, cliVersion
  ldflag) — the `v[0-9]*` match glob deliberately excludes those.
  """

  alias Barkpark.BuildInfo.Resolve

  # Repo root: this file sits at api/lib/barkpark/, so the root is three
  # directories up. Resolved from __DIR__ at compile time. Inside the release
  # image the release lives at /app, so this resolves to `/` — which is exactly
  # where api/Dockerfile COPYs VERSION, design/ and the other out-of-api
  # compile-time inputs.
  @repo_root Path.expand("../../..", __DIR__)

  # WRITTEN INLINE, not held in a helper: scripts/elixir-path-escape-check.sh's
  # root-anchor door only sees `Path.join(@anchor, "literal")` at the read site,
  # and a path constant one binding away is invisible to it. `VERSION` is
  # declared in that script's ELIXIR_COMPILE_PATHS.
  @external_resource Path.join(@repo_root, "VERSION")

  # ── Compile-time derivation ────────────────────────────────────────────
  #
  # Anonymous fns, not defp — a module cannot call its own functions while
  # its body is still being compiled. (Resolve, above, is a DIFFERENT module
  # and already compiled, so its functions are callable here.)

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

  # Trimmed first line of the repo-root VERSION file, or nil when it is absent
  # or unreadable. Fail-closed like every other tier.
  version_file =
    case File.read(Path.join(@repo_root, "VERSION")) do
      {:ok, contents} ->
        contents |> String.split("\n", parts: 2) |> hd() |> String.trim()

      _ ->
        nil
    end

  described =
    git.([
      "describe",
      "--tags",
      "--match",
      "v[0-9]*",
      # Release tags are STRICTLY vA.B.C (versioning rule 2026-07-02).
      # Without the excludes, a nearest v0.3.0-rc1 / v2-beta tag wins
      # the describe, fails the regex, and silently collapses the whole
      # build identity to "unknown".
      "--exclude",
      "v*-*",
      "--exclude",
      "v*[a-zA-Z]*"
    ])

  version = Resolve.version(env.("BARKPARK_BUILD_VERSION"), described, version_file)
  release = Resolve.release(version)

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
