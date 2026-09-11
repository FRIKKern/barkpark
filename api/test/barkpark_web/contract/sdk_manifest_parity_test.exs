defmodule BarkparkWeb.Contract.SdkManifestParityTest do
  @moduledoc """
  `@barkpark/core` ↔ capabilities-manifest drift guard — the PRODUCER-side half.

  ## Why this test lives in Elixir and not only in the JS suite

  The consumer half is `js/packages/core/tests/manifest-parity.test.ts`, which
  checks the SDK's coverage map against a CHECKED-IN SNAPSHOT of the manifest
  (`js/packages/core/tests/fixtures/capabilities.json`). A snapshot is only as
  fresh as its last refresh, and `.github/workflows/js-tests.yml` is
  paths-filtered on `js/**` and is NOT in the required set
  (`.github/required-checks.json`). So the PR that renames or retires a `/v1`
  route — an api-only diff — never runs the JS suite at all, and even if it did,
  the JS side would compare the SDK against the OLD snapshot and pass.

  A consumer test over a producer's snapshot is producer/consumer drift unless
  something on the PRODUCER side conformance-checks it. This file is that
  something: it reads the JS fixture from the repo and asserts every route the
  SDK claims to cover is still served by the manifest the app ACTUALLY builds,
  under the required Elixir gate, on every PR.

  ## What is compared, and what is deliberately not

  Only the fixture's `coverage` list — the reviewed map from an SDK method to
  the HTTP method + path template it promises. The manifest is a COMMAND
  surface, not an inventory of SDK helpers: most commands (chat, cycles, access,
  secrets, members, shares, …) have no typed JS helper by design, and the SDK
  owns stream/transport helpers that are no command (`listen`, `exportDataset`,
  `handshake`). Global set equality would be false in both directions, so it is
  never asserted here. The fixture's `manifest_routes` snapshot is likewise NOT
  compared against live — a new command must not red this test.

  Paths are compared as SHAPE: every `:placeholder` collapses to `:*` (the two
  surfaces spell the same segment `:id` / `:doc_id` / `:asset_id`) and the
  workspace-scoped mirror `/w/:*/p/:*` is stripped from both sides, matching
  `BarkparkWeb.Contract.RouterManifestDriftTest`.
  """

  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Capabilities

  # Repo-relative, resolved from the `api` directory `mix test` runs in.
  @fixture_path Path.expand("../js/packages/core/tests/fixtures/capabilities.json", File.cwd!())

  # Floors, not exact counts — a new SDK method or a new command must not red
  # this file. They exist because every assertion below is an Enum.filter over a
  # decoded list: an empty or truncated read passes all of them for free.
  @min_coverage 50
  @min_commands 120

  defp fixture do
    case File.read(@fixture_path) do
      {:ok, raw} ->
        Jason.decode!(raw)

      {:error, reason} ->
        flunk("""
        Could not read the JS parity fixture at #{@fixture_path}: #{inspect(reason)}.

        This test is the PRODUCER-side lock on js/packages/core/tests/fixtures/\
        capabilities.json. A missing file is a HARD failure, never a skip — a \
        silent skip is exactly the outcome this test exists to prevent.
        """)
    end
  end

  defp normalize_path(path) do
    path
    |> String.split("/")
    |> Enum.map(fn
      ":" <> _ -> ":*"
      "*" <> _ -> ":*"
      segment -> segment
    end)
    |> Enum.join("/")
  end

  @scope_prefix "/w/:*/p/:*"
  defp strip_scope(@scope_prefix <> rest), do: rest
  defp strip_scope(path), do: path

  defp canonical_path(path), do: path |> normalize_path() |> strip_scope()

  # The UN-projected superset at tier "admin": existence-hiding must not shrink
  # what the guard walks, or a tier-gated command would read as "retired".
  defp live_commands do
    Capabilities.manifest("admin", project: false)["commands"]
  end

  defp command_key(command) do
    {String.upcase(command["http"]["method"]), canonical_path(command["http"]["path_template"])}
  end

  defp coverage_key(entry) do
    {String.upcase(entry["method"]), canonical_path(entry["path_template"])}
  end

  describe "@barkpark/core coverage map ↔ live capabilities manifest" do
    test "the comparison is not vacuous" do
      fixture = fixture()
      coverage = Map.get(fixture, "coverage", [])
      commands = live_commands()

      assert length(coverage) >= @min_coverage,
             """
             Only #{length(coverage)} coverage entries were read from \
             #{@fixture_path} (floor: #{@min_coverage}). A parity comparison over \
             an empty or truncated coverage list passes for free — it compares \
             nothing. Either the fixture lost entries, or the JSON shape changed.
             """

      assert length(commands) >= @min_commands,
             """
             Only #{length(commands)} manifest commands were built (floor: \
             #{@min_commands}). `Capabilities.manifest/2` folds the registry \
             through `safe_registry/2`, which fails SOFT to a default — a \
             registry that did not boot yields a near-empty manifest and every \
             route below would then read as "retired".
             """
    end

    test "every route the JS SDK covers is still served by the manifest" do
      fixture = fixture()
      live = MapSet.new(live_commands(), &command_key/1)

      dangling =
        fixture
        |> Map.get("coverage", [])
        |> Enum.reject(&MapSet.member?(live, coverage_key(&1)))
        |> Enum.map(fn e ->
          "#{e["sdk_method"]} -> #{String.upcase(e["method"])} #{e["path_template"]}"
        end)

      assert dangling == [],
             """
             #{length(dangling)} @barkpark/core method(s) promise a route the \
             capabilities manifest no longer serves:

             #{Enum.map_join(dangling, "\n", &("  * " <> &1))}

             Every JS consumer calling these gets a 404 with no error on either \
             side. Fix the SDK path builder AND the coverage entry in \
             #{Path.relative_to(@fixture_path, File.cwd!() |> Path.dirname())}, or — \
             if the route moved on purpose — update both to the new template. \
             Refreshing the fixture snapshot alone does NOT clear this: the \
             coverage map is hand-authored and this assertion reads the LIVE \
             manifest, not the snapshot.
             """
    end

    test "every coverage entry is fully specified" do
      malformed =
        fixture()
        |> Map.get("coverage", [])
        |> Enum.reject(fn e ->
          is_binary(e["sdk_method"]) and is_binary(e["method"]) and
            is_binary(e["path_template"]) and String.starts_with?(e["path_template"], "/")
        end)

      assert malformed == [],
             "Coverage entries missing sdk_method/method/path_template: #{inspect(malformed)}"
    end
  end
end
