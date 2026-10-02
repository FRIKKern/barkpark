# Regenerate the `manifest_routes` half of
# api/test/support/fixtures/sdk-capabilities-parity.json.
#
#   cd api && mix run test/support/fixtures/refresh-sdk-capabilities-parity.exs
#
# The fixture lives under api/test/ and NOT under js/ on purpose: the Elixir
# producer-side lock (test/barkpark_web/contract/sdk_manifest_parity_test.exs)
# must read it from inside its own tree, or scripts/elixir-path-escape-check.sh
# reds it as an undispatched repo-root read. The JS consumer-side half
# (js/packages/core/tests/manifest-parity.test.ts) reads it across the tree,
# the same way the @barkpark/react PortableDoc parity harnesses read their
# goldens out of this directory.
#
# SOURCE TIER: "admin", UN-projected (`project: false`). The existence-hiding
# projection drops commands above the caller's tier, so a fixture cut at any
# lower tier would silently record a SMALLER route set and every parity
# assertion over it would weaken without anyone editing an assertion.
#
# Only `manifest_routes` + `generated_at` are rewritten. `coverage` and
# `sdk_only` are hand-authored review artifacts and are carried through
# untouched — this script must never be the thing that "fixes" a parity red.

path = Path.expand("sdk-capabilities-parity.json", __DIR__)
fixture = path |> File.read!() |> Jason.decode!()

routes =
  Barkpark.Plugins.Capabilities.manifest("admin", project: false)
  |> Map.fetch!("commands")
  |> Enum.map(fn cmd ->
    %{
      "command" => cmd["id"],
      "method" => String.upcase(cmd["http"]["method"]),
      "path_template" => cmd["http"]["path_template"]
    }
  end)
  |> Enum.sort_by(&{&1["path_template"], &1["method"]})

if routes == [] do
  raise "manifest returned ZERO commands — the app/registry did not boot; refusing to write an empty fixture"
end

updated =
  fixture
  |> Map.put("manifest_routes", routes)
  |> Map.put(
    "generated_at",
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  )

File.write!(path, Jason.encode!(updated, pretty: true) <> "\n")
IO.puts("wrote #{length(routes)} manifest routes to #{path}")
