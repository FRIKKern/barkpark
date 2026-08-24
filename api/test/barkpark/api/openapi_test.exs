defmodule Barkpark.Api.OpenApiTest do
  use ExUnit.Case, async: true

  alias Barkpark.Api.OpenApi
  alias Barkpark.Content.Errors
  alias Barkpark.Plugins.Capabilities

  # The generator is pure given a manifest; build the un-projected admin
  # superset once. (The registry may be cold in a unit run — `safe_registry`
  # in Capabilities degrades to core nouns, which is fine for these shape
  # assertions.)
  setup_all do
    manifest = Capabilities.manifest("admin", project: false)
    %{spec: OpenApi.spec(manifest), manifest: manifest}
  end

  test "top-level OpenAPI 3.1 shape", %{spec: spec} do
    assert spec["openapi"] == "3.1.0"
    assert is_map(spec["info"])
    assert is_binary(spec["info"]["title"])
    assert is_list(spec["servers"]) and spec["servers"] != []
    assert is_map(spec["paths"]) and map_size(spec["paths"]) > 0
    assert spec["components"]["securitySchemes"]["bearerAuth"]["type"] == "http"
  end

  # ── OpenAPI 3.1 structural / meta validation ────────────────────────────────
  #
  # Not a byte diff: assert the emitted document is well-formed OpenAPI 3.1 —
  # re-serializable JSON, a 3.1.x version string, and every operation carries
  # the three fields a spec consumer (an SDK generator) MUST have.

  test "emitted spec round-trips through JSON encode/decode", %{spec: spec} do
    encoded = Jason.encode!(spec)
    assert {:ok, decoded} = Jason.decode(encoded)
    assert decoded["openapi"] == "3.1.0"
    assert map_size(decoded["paths"]) == map_size(spec["paths"])
  end

  test "openapi version field is 3.1.x", %{spec: spec} do
    assert spec["openapi"] =~ ~r/^3\.1\.\d+$/
  end

  test "every operation carries method, operationId, and responses", %{spec: spec} do
    valid_methods = ~w(get put post delete patch head options trace)

    for {path, item} <- spec["paths"], {method, op} <- item do
      assert method in valid_methods, "#{path} has non-HTTP method #{method}"

      assert is_binary(op["operationId"]) and op["operationId"] != "",
             "#{method} #{path} missing operationId"

      assert is_map(op["responses"]) and map_size(op["responses"]) > 0,
             "#{method} #{path} missing responses"

      # Every response entry is either an inline object or a $ref.
      for {status, resp} <- op["responses"] do
        assert is_map(resp), "#{method} #{path} response #{status} is not an object"

        assert Map.has_key?(resp, "$ref") or Map.has_key?(resp, "description"),
               "#{method} #{path} response #{status} lacks $ref/description"
      end
    end
  end

  test "every operationId is unique across the document", %{spec: spec} do
    ids =
      spec["paths"]
      |> Map.values()
      |> Enum.flat_map(&Map.values/1)
      |> Enum.map(& &1["operationId"])

    assert length(ids) == length(Enum.uniq(ids)),
           "duplicate operationIds: #{inspect(ids -- Enum.uniq(ids))}"
  end

  # ── Enumeration parity: spec surface == live manifest route surface ─────────
  #
  # The honest gate. A CLI command maps to an HTTP ROUTE (method + path
  # template); several sugar commands legitimately share one route (all the
  # mutate verbs POST /v1/data/mutate/:dataset), and OpenAPI keys operations by
  # (path, method) — so the true unit of parity is the DISTINCT ROUTE, flat and
  # its scoped `/w/../p/../` mirror, NOT the command. We derive the route set
  # straight from the manifest and assert the spec enumerates exactly it: no
  # route dropped (a registered endpoint missing from the published spec), no
  # phantom path invented. Non-vacuous: the surface is pinned to be large.

  test "spec operations equal the live manifest route surface (count + set)", %{
    spec: spec,
    manifest: manifest
  } do
    manifest_routes = manifest_route_set(manifest["commands"])
    spec_routes = spec_route_set(spec)

    # Guard against a vacuous pass on an empty/cold manifest.
    assert MapSet.size(manifest_routes) > 50,
           "manifest route surface implausibly small (#{MapSet.size(manifest_routes)})"

    missing = MapSet.difference(manifest_routes, spec_routes)
    extra = MapSet.difference(spec_routes, manifest_routes)

    assert MapSet.equal?(manifest_routes, spec_routes),
           "route surface drift.\n  missing from spec: #{inspect(MapSet.to_list(missing))}\n" <>
             "  extra in spec: #{inspect(MapSet.to_list(extra))}"

    # Count parity: one OpenAPI operation per distinct route.
    op_count = spec["paths"] |> Map.values() |> Enum.map(&map_size/1) |> Enum.sum()

    assert op_count == MapSet.size(manifest_routes),
           "operation count #{op_count} != distinct manifest routes #{MapSet.size(manifest_routes)}"
  end

  # {method, openapi_path} for every command's flat route + scoped mirror.
  defp manifest_route_set(commands) do
    commands
    |> Enum.flat_map(fn cmd ->
      method = cmd |> get_in(["http", "method"]) |> to_string() |> String.downcase()
      template = get_in(cmd, ["http", "path_template"])
      flat = {method, to_openapi_path(template)}

      case Map.get(cmd, "scoped_prefix") do
        prefix when is_binary(prefix) and prefix != "" ->
          [flat, {method, to_openapi_path(prefix <> template)}]

        _ ->
          [flat]
      end
    end)
    |> MapSet.new()
  end

  defp spec_route_set(spec) do
    for {path, item} <- spec["paths"], {method, _op} <- item, into: MapSet.new() do
      {method, path}
    end
  end

  # Mirror of OpenApi.openapi_path/1: `:placeholder` → `{placeholder}`.
  defp to_openapi_path(template) do
    Regex.replace(~r/:([a-zA-Z_][a-zA-Z0-9_]*)/, template, "{\\1}")
  end

  test "path placeholders become required path params", %{spec: spec} do
    op = get_in(spec, ["paths", "/v1/data/doc/{dataset}/{type}/{doc_id}", "get"])
    assert op, "expected the doc.get operation to be present"

    path_params =
      op["parameters"]
      |> Enum.filter(&(&1["in"] == "path"))
      |> Enum.map(& &1["name"])
      |> MapSet.new()

    assert MapSet.subset?(MapSet.new(["dataset", "type", "doc_id"]), path_params)

    assert Enum.all?(op["parameters"], fn p -> p["in"] in ["path", "query"] end)
    assert Enum.all?(op["parameters"], fn p -> p["in"] != "path" or p["required"] == true end)
  end

  test "task.ready exposes an optional integer offset query parameter", %{spec: spec} do
    parameters = get_in(spec, ["paths", "/v1/tasks/ready", "get", "parameters"])

    offset = Enum.find(parameters, &(&1["in"] == "query" and &1["name"] == "offset"))

    assert offset
    assert offset["required"] == false
    assert offset["schema"]["type"] == "integer"
  end

  test "task.ready exposes an optional closure order query parameter", %{spec: spec} do
    parameters = get_in(spec, ["paths", "/v1/tasks/ready", "get", "parameters"])
    order = Enum.find(parameters, &(&1["in"] == "query" and &1["name"] == "order"))

    assert order
    assert order["required"] == false
    assert order["schema"]["type"] == "string"
  end

  test "anon (none-tier) ops carry empty security; gated ops require bearer", %{spec: spec} do
    get_doc = get_in(spec, ["paths", "/v1/data/doc/{dataset}/{type}/{doc_id}", "get"])
    mutate = get_in(spec, ["paths", "/v1/data/mutate/{dataset}", "post"])

    assert get_doc["security"] == []
    assert get_doc["x-barkpark-scope"] == "none"

    assert mutate["security"] == [%{"bearerAuth" => []}]
    assert mutate["x-barkpark-scope"] == "write"
  end

  test "writes get a requestBody; reads do not", %{spec: spec} do
    mutate = get_in(spec, ["paths", "/v1/data/mutate/{dataset}", "post"])
    get_doc = get_in(spec, ["paths", "/v1/data/doc/{dataset}/{type}/{doc_id}", "get"])

    assert is_map(mutate["requestBody"])
    refute Map.has_key?(get_doc, "requestBody")
  end

  test "scoped commands emit a /w/.../p/... mirror path", %{spec: spec} do
    scoped =
      get_in(spec, [
        "paths",
        "/w/{workspace_slug}/p/{project_slug}/v1/data/doc/{dataset}/{type}/{doc_id}",
        "get"
      ])

    assert scoped, "expected a scoped mirror for doc.get"
    assert scoped["operationId"] == "doc.get.scoped"

    names = scoped["parameters"] |> Enum.map(& &1["name"]) |> MapSet.new()
    assert MapSet.subset?(MapSet.new(["workspace_slug", "project_slug"]), names)
  end

  test "every gated op references the rate-limit + auth error responses", %{spec: spec} do
    mutate = get_in(spec, ["paths", "/v1/data/mutate/{dataset}", "post"])

    assert mutate["responses"]["401"]["$ref"] == "#/components/responses/Unauthorized"
    assert mutate["responses"]["429"]["$ref"] == "#/components/responses/RateLimited"
    assert mutate["responses"]["422"]["$ref"] == "#/components/responses/ValidationFailed"
  end

  test "shared RateLimited response documents the Retry-After header", %{spec: spec} do
    rl = get_in(spec, ["components", "responses", "RateLimited"])
    assert rl["headers"]["Retry-After"]["schema"]["type"] == "integer"
  end

  test "Error schema enum matches the live Content.Errors code table (drift guard)", %{spec: spec} do
    enum =
      spec
      |> get_in([
        "components",
        "schemas",
        "Error",
        "properties",
        "error",
        "properties",
        "code",
        "enum"
      ])
      |> MapSet.new()

    assert MapSet.equal?(Errors.known_codes(), enum),
           "Error.code enum drifted from Content.Errors.known_codes/0"
  end

  test "spec/0 builds without raising (admin superset)" do
    assert %{"openapi" => "3.1.0"} = OpenApi.spec()
  end

  # ── Regeneration discipline (task-openapi-drift-chronic) ──────────────────
  #
  # The CI drift gate (.github/workflows/elixir.yml, "OpenAPI drift check")
  # only reports that the committed bytes differ. These asserts are why that is
  # a fair demand rather than mystery noise:
  #
  #   * generation is byte-DETERMINISTIC, so a reported diff is always the
  #     author's own change and never run-to-run jitter — "just regenerate and
  #     commit" is a winnable instruction;
  #   * the two edit shapes that historically drifted `main` — adding a plugin
  #     route, and changing one command's help text — each provably MOVE the
  #     artifact bytes, so the gate cannot be satisfied by luck.
  #
  # If the determinism assert ever fails, the NONDETERMINISM is the bug. Fix
  # the ordering/timestamp source in the generator; do not relax the gate.

  @regen_command "cd api && mix barkpark.openapi"

  # Byte-for-byte what `Mix.Tasks.Barkpark.Openapi` writes to docs/openapi.json.
  # Kept in step with that task: same encoder, same pretty flag, same trailing
  # newline. A divergence here would make these asserts prove the wrong thing.
  defp artifact_bytes(spec), do: Jason.encode!(spec, pretty: true) <> "\n"

  test "generation is byte-deterministic: two builds of one tree encode identically" do
    assert artifact_bytes(OpenApi.spec()) == artifact_bytes(OpenApi.spec()),
           "docs/openapi.json generation is NOT deterministic — `#{@regen_command}` " <>
             "produces different bytes on consecutive runs of an unchanged tree, so " <>
             "the CI drift gate is unwinnable. Find the nondeterministic source " <>
             "(map/registry ordering, a timestamp, an absolute path) and fix it."
  end

  test "adding a route moves the artifact bytes (the drift gate has teeth)", %{
    manifest: manifest
  } do
    [seed | _] = manifest["commands"]

    added =
      seed
      |> Map.put("id", "drifttest.probe")
      |> Map.put("noun", "drifttest")
      |> Map.put("verb", "probe")
      |> Map.put("http", %{"method" => "GET", "path_template" => "/v1/drifttest/probe"})
      |> Map.delete("scoped_prefix")

    mutated = Map.put(manifest, "commands", manifest["commands"] ++ [added])

    assert Map.has_key?(OpenApi.spec(mutated)["paths"], "/v1/drifttest/probe"),
           "a manifest command did not reach the descriptor at all"

    refute artifact_bytes(OpenApi.spec(mutated)) == artifact_bytes(OpenApi.spec(manifest)),
           "adding a route left docs/openapi.json byte-identical — the drift gate " <>
             "would happily let an undocumented public route merge"
  end

  test "editing a command's help text moves the artifact bytes (the drift gate has teeth)",
       %{manifest: manifest} do
    [seed | rest] = manifest["commands"]
    edited = Map.put(seed, "summary", Map.get(seed, "summary", "") <> " (edited)")
    mutated = Map.put(manifest, "commands", [edited | rest])

    refute artifact_bytes(OpenApi.spec(mutated)) == artifact_bytes(OpenApi.spec(manifest)),
           "a one-word command-summary edit left docs/openapi.json byte-identical — " <>
             "this is the exact edit shape that drifted main on 2026-07-13, so the " <>
             "gate must be able to see it"
  end
end
