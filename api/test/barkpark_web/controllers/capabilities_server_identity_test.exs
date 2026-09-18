defmodule BarkparkWeb.CapabilitiesServerIdentityTest do
  @moduledoc """
  The `server` envelope of `GET /v1/capabilities` must not lie about the box.

  MEASURED ON PROD (89.167.28.206, 2026-09-16, read-only) before the fix:

      GET /v1/capabilities -> server.version "0.1.0",     server.min_cli "1.0.0"
      GET /status.json     -> version        "0.2.26.929", commit "ca4534461"

  `server.version` was `Application.spec(:barkpark, :vsn)` — the `mix.exs`
  project version, frozen since the repo was born — so it had never once
  tracked a release. `/status.json` on the SAME box reads
  `Barkpark.BuildInfo.version/0`, the compile-time build identity. Two
  endpoints, one box, two answers.

  These tests pin the three things that can regress:

    1. the two endpoints agree, asserted against the real `/status.json`
       response rather than against the constant either one reads;
    2. the advertised `min_cli` floor stays reachable by a client that exists —
       checked against the PUBLISHED `cli-v*` tag series, not against a number
       typed twice;
    3. the envelope keeps EXACTLY its five keys. `manifest.schema.json` is
       `additionalProperties: false` and `internal/manifest` `Parse` uses
       `DisallowUnknownFields` (recursively), so a sixth key is not an additive
       change — it is a parse outage for every released `bp`.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Plugins.Capabilities

  # The envelope, frozen. Mirrors `@server_keys` in
  # test/barkpark_web/contract/capabilities_manifest_test.exs — deliberately
  # duplicated: that file pins the keys of a RENDERED manifest, this one pins
  # the keys `default_server/0` produces, and a new key added to the builder
  # must red both.
  @server_keys ~w(api_version base_url min_cli name version)

  # The oldest PUBLISHED bp release, re-measured 2026-09-17:
  #
  #     git tag -l 'cli-v*' | sed 's/cli-v//' | sort -V | head -1   -> 1.1.0
  #     git tag -l 'cli-v*' | wc -l                                 -> 27
  #
  # `.github/workflows/cli-release.yml` cuts CLI releases from `cli-v*` tags
  # (`VERSION=${TAG#cli-v}`); the `v0.2.x` series is the SERVER's and no bp
  # binary ever carries one. Conflating the two is the error PR #18876
  # retracted on two CLI surfaces and this row's own description carried as a
  # third copy.
  @oldest_published_cli "1.1.0"

  describe "server.version answers the RUNNING release" do
    test "it equals the version GET /status.json reports on this same box", %{conn: conn} do
      status = conn |> get("/status.json") |> json_response(200)

      assert Capabilities.default_server()["version"] == status["version"],
             """
             server.version and /status.json disagree on one box.

               /v1/capabilities server.version: #{inspect(Capabilities.default_server()["version"])}
               /status.json     version:        #{inspect(status["version"])}

             This is the 2026-09-16 prod defect exactly (0.1.0 vs 0.2.26.929).
             Both must read Barkpark.BuildInfo.version/0.
             """
    end

    test "the shared source is BuildInfo, not the frozen mix.exs project version" do
      assert Capabilities.default_server()["version"] == Barkpark.BuildInfo.version()

      vsn =
        case Application.spec(:barkpark, :vsn) do
          v when is_list(v) -> List.to_string(v)
          _ -> nil
        end

      # A CONTROL, not decoration: if the mix.exs version ever happens to equal
      # the build version the assertion above goes vacuous, so say so out loud
      # rather than let a coincidence read as a pass.
      if vsn == Barkpark.BuildInfo.version() do
        IO.puts(
          "[control] mix.exs vsn #{inspect(vsn)} coincides with BuildInfo.version/0 — " <>
            "this run cannot distinguish the two sources"
        )
      end
    end
  end

  describe "min_cli is an advisory floor a shipped client can meet" do
    test "the advertised floor is at or below the oldest published cli-v release" do
      floor = Capabilities.min_cli()

      assert Version.compare(semver(floor), semver(@oldest_published_cli)) in [:lt, :eq],
             """
             min_cli #{inspect(floor)} is above the oldest published bp release
             #{inspect(@oldest_published_cli)}. Every client below the floor is told it is
             behind by internal/cli serverFloorStaleness (bp whoami / bp doctor
             --onboarding withhold up_to_date:true) and by minCLICheck on
             bp capabilities. Raising it past a release the fleet can reach makes
             that notice unactionable.
             """

      assert Capabilities.default_server()["min_cli"] == floor
    end

    test "@oldest_published_cli still matches the real cli-v tag series" do
      case published_cli_releases() do
        [] ->
          # No tags in this checkout (shallow CI clone, or a release tarball
          # with no .git). The constant above stands on its recorded
          # measurement; it is NOT silently treated as verified.
          IO.puts("[skipped control] no cli-v* tags visible in this checkout")

        releases ->
          oldest = Enum.min(releases, Version)

          assert Version.to_string(oldest) == semver(@oldest_published_cli),
                 "oldest published cli-v release is now #{Version.to_string(oldest)}; " <>
                   "update @oldest_published_cli (and re-check min_cli against it)"
      end
    end
  end

  describe "the server envelope gains no key" do
    test "default_server/0 produces exactly the five frozen keys" do
      assert Capabilities.default_server() |> Map.keys() |> Enum.sort() == @server_keys,
             """
             The server envelope is additionalProperties:false and every released
             bp strict-decodes it (internal/manifest manifest.go Parse,
             DisallowUnknownFields, recursive). A new key here is a whole-CLI
             parse outage, not an additive change. A new answer rides an opt-in
             query param (?build=1 / ?views=1) or the control plane.
             See docs/decisions/0007-capability-oracle.md.
             """
    end

    test "the rendered manifest's server block carries the same five keys" do
      manifest = Capabilities.manifest("admin")

      assert manifest["server"] |> Map.keys() |> Enum.sort() == @server_keys
    end
  end

  # `Version` needs A.B.C; the CLI series is written that way already, but keep
  # the coercion explicit so a four-segment value cannot crash the comparison.
  defp semver(v) do
    case String.split(v, ".") do
      [a, b, c | _] -> Enum.join([a, b, c], ".")
      parts -> Enum.join(parts, ".")
    end
  end

  defp published_cli_releases do
    root = Path.expand("../../../..", __DIR__)

    case System.cmd("git", ["tag", "-l", "cli-v*"], cd: root, stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.replace_prefix(&1, "cli-v", ""))
        |> Enum.flat_map(fn v ->
          case Version.parse(semver(v)) do
            {:ok, parsed} -> [parsed]
            :error -> []
          end
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end
end
