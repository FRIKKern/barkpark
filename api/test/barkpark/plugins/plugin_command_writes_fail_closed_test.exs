defmodule Barkpark.Plugins.PluginCommandWritesFailClosedTest do
  @moduledoc """
  A plugin-supplied CLI command that omits `writes` must FAIL CLOSED
  (pds-bl-plugin-cli-command-writes-fails-open).

  #6426 closed the CORE half: `Capabilities.core_cmd/8` reads
  `Keyword.fetch!(opts, :writes)`, and `capabilities_manifest_test.exs` asserts
  every non-GET core command declares `writes == true`. That guard filters on
  `source == "core"`, so it can never see a plugin command.

  Plugin commands arrive through `Capabilities.normalize_command/1`, which
  defaulted `http`/`args`/`flags` and left `writes` alone.
  `Barkpark.Plugin`'s `required(:writes) => boolean()` is a typespec — dialyzer
  only, no runtime effect. So an omitted bit emitted no `writes` key, the Go
  side decoded the absence to the `false` zero value, and the prod write-guard
  (`run.go`: `cmd.Writes && isProd(..)`), the verbless read inference
  (`usage.go`: `soleReadVerb`) and the MCP hint (`mcp_bridge.go`) all read the
  mutator as a reader.

  These arms are RED without `put_writes_fail_closed/1` in
  `normalize_command/1`: the first two assert on a key that would be absent,
  and the third asserts the warning that would never be logged.

  Related but NOT closed by this row: `pds-bl-manifest-writes-fails-open` is the
  GO-side tri-state (`manifest.Command.Writes` is a plain `bool`, so the client
  still cannot distinguish "declared false" from "absent" on a manifest served
  by an older server). This row makes THIS server stop emitting the ambiguous
  shape; that row makes the client stop trusting it. Neither closes the other.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Barkpark.Plugins.Capabilities

  # The wire shape a plugin's `cli_commands/0` returns: atom keys, and — the
  # defect — no `:writes`.
  defp plugin_cmd(extra \\ %{}) do
    Map.merge(
      %{
        id: "widget.publish",
        noun: "widget",
        verb: "publish",
        summary: "Publish a widget",
        http: %{method: "POST", path_template: "/v1/plugins/demo/widgets/:id/publish"},
        auth_tier: "admin",
        args: [],
        flags: []
      },
      extra
    )
  end

  test "a plugin command that omits :writes normalizes to writes == true" do
    normalized = Capabilities.normalize_command(plugin_cmd())

    assert Map.has_key?(normalized, "writes"),
           "an omitted `writes` still emitted NO key — the Go client decodes " <>
             "that absence to the `false` zero value and runs the mutator " <>
             "unconfirmed"

    assert normalized["writes"] == true,
           "an omitted `writes` must fail CLOSED (treated as a writer): being " <>
             "wrongly prompted costs a keystroke, being wrongly trusted costs " <>
             "an unconfirmed write"
  end

  test "a non-boolean :writes is coerced closed too" do
    assert Capabilities.normalize_command(plugin_cmd(%{writes: "true"}))["writes"] == true
    assert Capabilities.normalize_command(plugin_cmd(%{writes: nil}))["writes"] == true
  end

  test "the fail-closed default is LOUD, naming the offending command" do
    log = capture_log(fn -> Capabilities.normalize_command(plugin_cmd()) end)

    assert log =~ "widget",
           "the warning must name the command so the plugin author is told, " <>
             "not silently protected"

    assert log =~ "publish"
    assert log =~ "writes"
  end

  # The negative arm — without it the fix above could be "always true", which
  # would make every read command prompt on a prod host.
  test "an explicit writes: false is left alone" do
    normalized = Capabilities.normalize_command(plugin_cmd(%{writes: false, verb: "list"}))

    assert normalized["writes"] == false,
           "a plugin that correctly declares a read command must not be " <>
             "promoted to a writer"
  end

  test "an explicit writes: true is left alone, and logs nothing" do
    log =
      capture_log(fn ->
        assert Capabilities.normalize_command(plugin_cmd(%{writes: true}))["writes"] == true
      end)

    refute log =~ "fail-closed",
           "a correctly-declared command must not warn — a warning that fires " <>
             "on every command stops discriminating"
  end
end
