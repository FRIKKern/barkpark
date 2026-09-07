defmodule BarkparkCloud.BoxCapacityRefusalFixture do
  @moduledoc """
  THE READER for the box's `box_at_capacity` 409 refusal body. cloud/ fixtures
  that need that body call this module; none of them hold a copy of it.

  ## Why this module exists

  The body is EMITTED in the other app — `BarkparkWeb.SiteDeployController`
  renders `capacity_message/3 <> peer_tail/1` — and was then hand-copied as a
  string literal into cloud/ deploy-ledger fixtures. That is an unlocked
  mirror: two copies of one truth, a passing suite on each side, and nothing
  that reds when they disagree. It drifted once already — #16581 corrected one
  fixture and missed two siblings, which carried an invented body
  (`"4 of 4 build slots are in use"`) for a day until #16598 — and the suite
  was green the whole time, because `classify_deferred/2` keys on the
  `box_at_capacity` CODE WORD and every other byte of the sentence is free to
  rot.

  ## The lock, in three links

    1. **emitter → JSON.**
       `api/test/barkpark_web/controllers/site_deploy_capacity_body_conformance_test.exs`
       drives the REAL controller to a real 409 and asserts the emitted message
       equals the JSON's `message`, byte for byte. Reword the emitter without
       updating the JSON and that test reds — in api/, on the api diff that did
       the rewording, naming the emitter and the stale fixture.
    2. **JSON → cloud.** This module READS the JSON. A cloud fixture cannot
       disagree with it, because it never holds its own copy.
    3. **nobody retypes it.**
       `cloud/test/barkpark_cloud/deploy_ledger/capacity_body_mirror_guard_test.exs`
       scans the whole cloud test tree for a hand-typed copy and fails on one.
  """

  @fixture_path Path.expand(
                  "../../../api/test/support/fixtures/box_capacity_refusal.json",
                  __DIR__
                )
  @external_resource @fixture_path

  @emitter_path Path.expand(
                  "../../../api/lib/barkpark_web/controllers/site_deploy_controller.ex",
                  __DIR__
                )
  @external_resource @emitter_path

  @decoded @fixture_path |> File.read!() |> Jason.decode!()

  @caption "the instance refused the deploy (HTTP 409)"

  @doc "Absolute path of the shared JSON — the ONE copy. Quoted in guard failures."
  def path, do: @fixture_path

  @doc "Alias of `path/0`, for readers that want the longer name."
  def fixture_path, do: path()

  @doc "Absolute path of the module that EMITS the body."
  def emitter_path, do: @emitter_path

  @doc "The full peer-holder refusal message, byte-for-byte as the box sends it."
  def message, do: Map.fetch!(@decoded, "message")

  @doc """
  The message split at the seam the control plane cares about: the capacity
  clause (byte-stable since D179) and the holder tail (free to be re-worded).
  """
  def parts, do: Map.fetch!(@decoded, "parts")

  @doc "The capacity clause — everything the control plane has parsed since D179."
  def prefix, do: parts() |> hd()

  @doc "The holder tail — the half that is allowed to change wording."
  def tail, do: parts() |> List.last()

  @doc "The inputs that produce `message/0`: slots in use, capacity, holding slug."
  def sample, do: Map.fetch!(@decoded, "sample")

  @doc "The slug the sample refusal names as holding the build slot."
  def holding_slug, do: sample() |> Map.fetch!("holding_slug")

  @doc """
  What `Sites.Deploy.box_refusal/3` persists for this refusal: the anchored 409
  caption, the box's code word, and the box's own message — the exact bytes a
  deferred prod row carries before the driver appends its promise clause.
  """
  def deferred_detail, do: @caption <> ": box_at_capacity — " <> message()

  @doc "Alias of `deferred_detail/0`."
  def deferral_reason, do: deferred_detail()

  @doc "`the instance refused the deploy (HTTP 409)`, as `Sites.Deploy` renders it."
  def refusal_caption, do: @caption
end
