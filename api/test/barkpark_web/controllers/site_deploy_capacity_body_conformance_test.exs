defmodule BarkparkWeb.SiteDeployCapacityBodyConformanceTest do
  @moduledoc """
  THE PRODUCER-SIDE HALF OF THE CAPACITY-BODY LOCK.

  `BarkparkWeb.SiteDeployController` emits the box's `box_at_capacity` 409
  body (`capacity_message/3 <> peer_tail/1`). Four fixtures in the OTHER app
  (cloud/, the deploy-ledger classifier's corpus) used to hand-copy that body
  as a string literal, and nothing in either suite reds when the two disagree:
  `classify_deferred/2` keys on the `box_at_capacity` code word, so every other
  byte of the body is free to rot. It rotted once already — #16581 corrected
  one fixture, missed two siblings carrying an invented body, #16598 caught up
  a day later.

  The one copy now lives in `test/support/fixtures/box_capacity_refusal.json`
  and cloud/ READS it (`BarkparkCloud.BoxCapacityRefusalFixture`). This test is
  what makes that file trustworthy: it drives the REAL controller to a real 409
  with the fixture's own sample inputs and asserts the emitted message is the
  fixture's `message`, byte for byte. A hand-written fixture nobody asserts
  against is still a mirror.

  So: reword the emitter without updating the JSON and THIS test fails — in
  api/, on the api diff that did the rewording, naming both files.
  """
  # async: false — mutates the singleton DeployRunner + application env.
  use ExUnit.Case, async: false

  alias Barkpark.Sites.DeployRequest
  alias Barkpark.Sites.DeployRunner
  alias Barkpark.Sites.Provisioner

  @fixture_path Path.expand("../../support/fixtures/box_capacity_refusal.json", __DIR__)
  @external_resource @fixture_path
  @fixture @fixture_path |> File.read!() |> Jason.decode!()

  @emitter "api/lib/barkpark_web/controllers/site_deploy_controller.ex"
  @fixture_rel "api/test/support/fixtures/box_capacity_refusal.json"

  setup do
    base = Path.join(System.tmp_dir!(), "bp-cap-conf-#{System.unique_integer([:positive])}")
    template = Path.join(base, "template")
    File.mkdir_p!(template)
    File.write!(Path.join(template, "package.json"), ~s({"name":"stub"}))

    prior = Application.get_env(:barkpark, Provisioner)

    Application.put_env(:barkpark, Provisioner,
      sites_dir: Path.join(base, "sites"),
      template_dir: template
    )

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, Provisioner, prior),
        else: Application.delete_env(:barkpark, Provisioner)

      File.rm_rf(base)
    end)

    :ok
  end

  test "the shared JSON is INTERNALLY consistent — parts join to message" do
    parts = Map.fetch!(@fixture, "parts")

    assert Enum.join(parts) == Map.fetch!(@fixture, "message"),
           "#{@fixture_rel}: `parts` no longer concatenate to `message`."
  end

  test "the emitted 409 body IS the shared JSON's message, byte for byte" do
    sample = Map.fetch!(@fixture, "sample")
    holder = Map.fetch!(sample, "holding_slug")
    expected = Map.fetch!(@fixture, "message")

    # The sample's slot arithmetic is part of the contract: a fixture that
    # renders "1 of 1" while the box is configured for four slots is a copy of
    # nothing.
    assert DeployRunner.build_slot_capacity() == Map.fetch!(sample, "build_slot_capacity")

    put_cfg(enabled: true, command: stub("sleep 0.6; exit 0"))

    assert DeployRunner.trigger(req(holder)) == {:ok, :started}

    conn =
      BarkparkWeb.SiteDeployController.trigger(
        Phoenix.ConnTest.build_conn(),
        %{"slug" => "capacity-conformance-other", "build_id" => "b1", "mode" => "deploy"}
      )

    assert conn.status == 409
    assert %{"error" => error} = Jason.decode!(conn.resp_body)
    assert error["code"] == "box_at_capacity"
    assert error["holder"] == "peer"
    assert error["build_slots_in_use"] == Map.fetch!(sample, "build_slots_in_use")
    assert error["build_slot_capacity"] == Map.fetch!(sample, "build_slot_capacity")

    assert error["message"] == expected,
           """
           THE CAPACITY-BODY MIRROR HAS DRIFTED.

           #{@emitter} now emits:
               #{inspect(error["message"])}

           …but #{@fixture_rel} still says:
               #{inspect(expected)}

           That JSON is THE ONE COPY: cloud/ deploy-ledger fixtures read it
           through BarkparkCloud.BoxCapacityRefusalFixture, so they are now
           testing the classifier against a body the box no longer sends.

           If the reword is intended, update `parts` and `message` in
           #{@fixture_rel} in the SAME commit. Do not retype the string
           anywhere else — the cloud-side guard
           (cloud/test/barkpark_cloud/deploy_ledger/capacity_body_mirror_guard_test.exs)
           fails if you do.
           """

    assert %{state: :done, exit_code: 0} = await_done(holder)
  end

  # ── helpers (kept local: this file must not depend on another test file) ──

  defp put_cfg(overrides) do
    prior = Application.get_env(:barkpark, DeployRunner)
    Application.put_env(:barkpark, DeployRunner, Keyword.merge(prior || [], overrides))

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, DeployRunner, prior),
        else: Application.delete_env(:barkpark, DeployRunner)
    end)
  end

  defp stub(script), do: {"bash", ["-c", script]}

  defp req(slug) do
    {:ok, request} =
      DeployRequest.new(%{"slug" => slug, "build_id" => "b1", "mode" => "deploy"})

    request
  end

  defp await_done(slug, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 15_000

    case DeployRunner.status(slug) do
      %{state: :done} = status ->
        status

      status ->
        if System.monotonic_time(:millisecond) >= deadline do
          status
        else
          Process.sleep(25)
          await_done(slug, deadline)
        end
    end
  end
end
