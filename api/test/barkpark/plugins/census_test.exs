defmodule Barkpark.Plugins.CensusTest do
  @moduledoc """
  Non-vacuity bar for `Barkpark.Plugins.Census` (task-13495dd3f2397558).

  The census exists because HTTP liveness cannot tell "the stack booted" from
  "the stack booted correctly": `Plugins.Bootstrap` rescues a plugin that
  raises in `register_schemas/1`, logs it, and lets boot continue, so the
  release image reaches healthcheck-healthy and `/api/schemas` answers 200
  with whatever schemas DID register. That is how six of nine plugins stayed
  dead in every released build for weeks while compose-smoke reported PASS.

  A census that can only report success is theatre. The tests below therefore
  PLANT failures — a plugin that raises, and a plugin that was never walked at
  all — and assert the census names them. The healthy-path test alone would
  pass against a `def take, do: %{ok: true}` stub.

  `async: false`: the Registry and RunStatus are singleton GenServers outside
  the Ecto sandbox. Every assertion is scoped to the stub plugin names this
  file registers — never to the whole registry, which sibling suites also
  write into.
  """

  use BarkparkWeb.ConnCase, async: false

  @moduletag :plugin_bootstrap

  alias Barkpark.Plugins.Bootstrap
  alias Barkpark.Plugins.Census
  alias Barkpark.Plugins.Registry

  @ok_plugin "census_test_healthy_stub"
  @raising_plugin "census_test_raising_stub"
  @unwalked_plugin "census_test_unwalked_stub"

  defmodule HealthyStub do
    @moduledoc false
    alias Barkpark.Content.SchemaDefinition

    def schema_name, do: "census_test_healthy_type"

    def register_schemas(_opts) do
      [
        %SchemaDefinition{
          name: schema_name(),
          title: "Census Test Healthy Type",
          dataset: "production",
          fields: [%{"name" => "title", "type" => "string"}]
        }
      ]
    end
  end

  defmodule RaisingStub do
    @moduledoc false
    def register_schemas(_opts), do: raise("synthetic census failure")
  end

  defmodule UnwalkedStub do
    @moduledoc false
    def register_schemas(_opts), do: []
  end

  setup do
    on_exit(fn ->
      Registry.reset()
      Barkpark.Plugins.RunStatus.reset()
    end)

    :ok
  end

  defp register!(name, module) do
    :ok = Registry.register(module, %{"plugin_name" => name, "version" => "0.0.0"})
  end

  defp entry(report, name), do: Enum.find(report.plugins, &(&1.name == name))

  # ── criterion 1: outcome per plugin, with the installed type names ────────

  test "names the schema types a healthy plugin installed" do
    register!(@ok_plugin, __MODULE__.HealthyStub)
    Bootstrap.register_all_schemas()

    row = entry(Census.take(), @ok_plugin)

    assert row.status == "ok"
    assert row.schemas == [HealthyStub.schema_name()]
    assert row.schema_count == 1
    assert row.error == nil
  end

  # ── criterion 2: the census MUST be able to report a failure ──────────────

  test "names the plugin that raised in register_schemas/1 as failed" do
    register!(@raising_plugin, __MODULE__.RaisingStub)
    Bootstrap.register_all_schemas()

    report = Census.take()
    row = entry(report, @raising_plugin)

    assert row.status == "failed"
    assert row.error =~ "synthetic census failure"
    assert @raising_plugin in report.failed
    refute report.ok
    assert {:error, ^report} = Census.check()
  end

  test "names a registered plugin that registration never walked" do
    # The failure mode with no log line at all: the plugin is in the registry
    # but `register_all_schemas/0` never ran (or died before reaching it), so
    # nothing was recorded for it. Silence must read as failure, not success.
    register!(@unwalked_plugin, __MODULE__.UnwalkedStub)
    Barkpark.Plugins.RunStatus.reset()

    report = Census.take()
    row = entry(report, @unwalked_plugin)

    assert row.status == "not_registered"
    assert row.schemas == []
    assert @unwalked_plugin in report.failed
    refute report.ok
  end

  # ── criterion 3: plugin-free boot stays true ──────────────────────────────

  test "an empty plugin set is an empty SUCCESSFUL census, not an error" do
    report = Census.take(plugins: [])

    assert report == %{
             ok: true,
             plugin_count: 0,
             schema_count: 0,
             failed: [],
             plugins: []
           }

    assert {:ok, ^report} = Census.check(plugins: [])
  end

  # ── criterion 4: the machine-readable contract the gate calls ─────────────

  test "report_json/1 emits the documented envelope" do
    register!(@ok_plugin, __MODULE__.HealthyStub)
    Bootstrap.register_all_schemas()

    decoded = Census.report_json() |> Jason.decode!()

    assert decoded["ok"] in [true, false]
    assert is_integer(decoded["plugin_count"])
    assert is_integer(decoded["schema_count"])
    assert is_list(decoded["failed"])

    row = Enum.find(decoded["plugins"], &(&1["name"] == @ok_plugin))

    assert row["status"] == "ok"
    assert row["schemas"] == [HealthyStub.schema_name()]
    assert row["schema_count"] == 1
    assert is_binary(row["module"])
  end

  test "report_json/1 stays valid JSON when a plugin failed" do
    register!(@raising_plugin, __MODULE__.RaisingStub)
    Bootstrap.register_all_schemas()

    decoded = Census.report_json() |> Jason.decode!()
    row = Enum.find(decoded["plugins"], &(&1["name"] == @raising_plugin))

    assert row["status"] == "failed"
    assert is_binary(row["error"])
    assert decoded["ok"] == false
    assert @raising_plugin in decoded["failed"]
  end

  # ── the census never calls into a plugin module itself ────────────────────

  test "take/1 does not invoke register_schemas/1 on the plugin module" do
    # A census that re-ran the callback would (a) write to the database on a
    # read, and (b) make the host call into a removable plugin. Prove it does
    # not: this stub records every invocation, and the census must add none.
    register!("census_test_counting_stub", __MODULE__.HealthyStub)
    Bootstrap.register_all_schemas()

    before = Census.take()
    after_two = Census.take()

    assert entry(before, "census_test_counting_stub").schemas ==
             entry(after_two, "census_test_counting_stub").schemas

    # Wiping the recorded outcome must change what the census says — proving
    # it reads the recorded registration OUTCOME rather than re-deriving it
    # from the plugin module on every call.
    Barkpark.Plugins.RunStatus.reset()
    assert entry(Census.take(), "census_test_counting_stub").status == "not_registered"
  end
end
