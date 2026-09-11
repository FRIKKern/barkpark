# Regenerate the `manifest_routes` half of tests/fixtures/capabilities.json.
#
#   cd api && mix run ../js/packages/core/tests/fixtures/refresh-capabilities.exs
#
# SOURCE TIER: "admin", UN-projected (`project: false`). The existence-hiding
# projection drops commands above the caller's tier, so a fixture cut at any
# lower tier would silently record a SMALLER route set and every parity
# assertion over it would weaken without anyone editing an assertion.
#
# Only `manifest_routes` + `generated_at` are rewritten. `coverage` and
# `sdk_only` are hand-authored review artifacts and are carried through
# untouched — this script must never be the thing that "fixes" a parity red.

path = Path.expand("capabilities.json", __DIR__)
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
  |> Map.put("generated_at", DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())

File.write!(path, Jason.encode!(updated, pretty: true) <> "\n")
IO.puts("wrote #{length(routes)} manifest routes to #{path}")
