defmodule BarkparkCloud.BoxStatusPayloadFixture do
  @moduledoc """
  THE READER for the box's site-deploy STATUS and RECORD payload key sets.
  cloud/ tests and fixtures that need those shapes call this module; none of
  them hold a copy of them.

  ## Why this module exists

  Both payloads are EMITTED in the other app — `BarkparkWeb.SiteDeployController`
  renders `render_status/1`, `render_stage/1` and `render_build_record/1` — and
  were then hand-copied: a closed `Map.keys(...) == ~w(...)` pin in the api
  controller test, a hand-authored body in
  `cloud/test/support/sites_fake_box_relay.ex`, and a hand-typed `@record_keys`
  allowlist in `cloud/lib/barkpark_cloud/sites/build_log.ex`. Three snapshots of
  one truth, a passing suite on each side, and nothing that reds when they
  disagree.

  They had already disagreed. `render_build_record/1` gained `route_status` and
  `route_detail` in #17640; `@record_keys` did not list them, so the control
  plane's record route silently DROPPED the box's route verdict — with every
  suite green, because an allowlist that omits a key renders a body nobody
  compares to the producer's.

  ## The lock, in three links

    1. **emitter → JSON.**
       `api/test/barkpark_web/controllers/site_deploy_status_payload_conformance_test.exs`
       drives the REAL controller to real 200s on both doors and DERIVES the key
       sets from the responses, asserting them equal to the JSON's lists. Add a
       key to the producer without updating the JSON and that test reds — in
       api/, on the api diff that added it.
    2. **JSON → cloud.** This module READS the JSON, and
       `cloud/test/barkpark_cloud/sites/box_status_payload_conformance_test.exs`
       asserts the cloud CONSUMERS still agree with it: `normalize_report/1`
       consumes every `status.consumed` key, ignores every `status.producer_only`
       key, and `BarkparkCloud.Sites.BuildLog`'s `@record_keys` equals
       `record.emitted`. That file also re-derives the PRODUCER's key set
       straight out of the api source, so an api-side rename reds HERE too,
       without the fixture being touched.
    3. **nobody retypes it.** The guard arm in that same file scans the whole
       cloud test tree for a hand-typed copy of either key list and fails on one.

  ## Adding a key

  One line in the right list in the JSON, kept sorted, plus the producer and —
  for a record key — `@record_keys`. Nothing else in either suite carries these
  lists, so that is the whole edit.
  """

  @fixture_path Path.expand(
                  "../../../api/test/support/fixtures/box_status_payload.json",
                  __DIR__
                )
  @external_resource @fixture_path

  @producer_path Path.expand(
                   "../../../api/lib/barkpark_web/controllers/site_deploy_controller.ex",
                   __DIR__
                 )
  @external_resource @producer_path

  @decoded @fixture_path |> File.read!() |> Jason.decode!()

  @doc "Absolute path of the shared JSON — the ONE copy. Quoted in guard failures."
  def path, do: @fixture_path

  @doc "Absolute path of the module that EMITS both payloads."
  def producer_path, do: @producer_path

  @doc "Repo-relative path of the shared JSON, for failure prose."
  def rel, do: "api/test/support/fixtures/box_status_payload.json"

  @doc "Every key `render_status/1` can emit, sorted. Includes the conditional one."
  def status_keys, do: Enum.sort(status_consumed() ++ status_producer_only())

  @doc "The status keys `BarkparkCloud.Sites.Deploy.normalize_report/1` reads."
  def status_consumed, do: fetch(["status", "consumed"])

  @doc "The status keys the box emits and the control plane deliberately ignores."
  def status_producer_only, do: fetch(["status", "producer_only"])

  @doc """
  The subset of `status_consumed/0` the consumer READS but does not ECHO —
  `state` becomes an atom, `exit_code` only moves the verdict, `stages`/`log`
  feed the stage fold. Each has its own named behavioural assertion instead of
  a sentinel-equality one.
  """
  def status_folded, do: fetch(["status", "folded"])

  @doc """
  The status keys the producer OMITS rather than defaults when the value was
  never measured — absent from a status body, not null in it.
  """
  def status_conditional, do: fetch(["status", "conditional"])

  @doc """
  Keys `normalize_report/1` tolerates that this producer never sends (older
  boxes, the `log`/`console` fallbacks). NOT part of the producer's key set.
  """
  def status_consumer_only, do: fetch(["status", "consumer_only"])

  @doc "Every key `render_stage/1` emits, sorted."
  def stage_keys, do: fetch(["status", "stage", "emitted"])

  @doc "The stage keys `normalize_stage/1` reads."
  def stage_consumed, do: fetch(["status", "stage", "consumed"])

  @doc """
  Every key `render_build_record/1` emits, sorted — and, by the strict-equality
  arm of the lock, exactly `BarkparkCloud.Sites.BuildLog`'s `@record_keys`.
  """
  def record_keys, do: fetch(["record", "emitted"])

  @doc """
  A full status body carrying EVERY key the producer can emit, each with a
  DISTINCT sentinel value, ready for `normalize_report/1`.

  Distinct per key on purpose: a body of shared placeholders proves a key was
  read but not WHICH key landed where, so a consumer that transposed two fields
  would still pass. `overrides` replaces sentinels by key.
  """
  def status_body(overrides \\ %{}) do
    status_keys()
    |> Map.new(&{&1, sentinel(&1)})
    |> Map.merge(Map.new(overrides, fn {k, v} -> {to_string(k), v} end))
  end

  @doc """
  The sentinel this module puts on `key` in `status_body/1` — the value a test
  asserts came through. Typed to what the consumer will accept for that key so
  the sentinel survives normalization rather than being coerced to nil.
  """
  def sentinel("state"), do: "running"
  def sentinel("exit_code"), do: 0
  def sentinel("health_exit_code"), do: 7
  def sentinel("served_port"), do: 4301
  def sentinel("log"), do: []
  def sentinel("stages"), do: []
  def sentinel("mode"), do: "deploy"
  def sentinel(key) when is_binary(key), do: "bp-sentinel-" <> key

  @doc """
  A full terminal-record body carrying every key `render_build_record/1` emits.

  `required` supplies the keys a caller must pin (`slug`, `build_id`,
  `log_state`); everything else gets a sentinel, so a key added to the producer
  arrives here automatically instead of needing a new default typed out.
  """
  def record_body(required \\ %{}) do
    record_keys()
    |> Map.new(&{&1, sentinel(&1)})
    |> Map.merge(Map.new(required, fn {k, v} -> {to_string(k), v} end))
  end

  defp fetch(path) do
    case get_in(@decoded, path) do
      list when is_list(list) and list != [] ->
        list

      other ->
        raise "#{@fixture_path}: #{inspect(path)} is #{inspect(other)} — an empty or missing key list would make every comparison that reads it vacuous"
    end
  end
end
