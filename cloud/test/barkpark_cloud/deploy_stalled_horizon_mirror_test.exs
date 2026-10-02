defmodule BarkparkCloud.DeployStalledHorizonMirrorTest do
  @moduledoc """
  The `deploy_stalled` horizon is a HAND-MAINTAINED MIRROR across two surfaces,
  and until this file existed nothing on either side could see it drift:

    * Go client — `const queuedDeployStalledAfterSeconds = 300` in
      `internal/cli/cloud_status_cmd.go`. The CLIENT owns the number by design:
      `GET /v1/cloud/status` serves only the raw `queued_deploy_age_seconds`, so
      `bp cloud status` decides for itself when that age is a stall.
    * Elixir server — `@default_queued_deploy_alarm_after_seconds 5 * 60` in
      `cloud/lib/barkpark_cloud/registry.ex`, read through
      `BarkparkCloud.Registry.queued_deploy_alarm_after_seconds/0`.

  Both sides had passing tests and neither could fail because of the other:
  change one and `bp cloud status` fires `deploy_stalled` at a horizon the
  control plane does not believe in (or stays silent past one it does). This
  test is the lock, placed on the side that already BLOCKS — the required Cloud
  gate — because the Go side is another lane's fence and its suite is not the
  merge gate for `cloud/`.

  ## The extractor refuses rather than passes vacuously

  The Go literal is read out of the source by regex, so the failure mode to fear
  is not a wrong number but a MISSING one: a rename, a move, or a reformat makes
  the regex match nothing, and a naive extractor would then compare `nil` to
  `nil`-ish and green. `go_int_const!/2` raises on an unreadable file, on an
  empty read, and on a name it cannot find. The "positive control" test below
  points it at a constant name that does not exist and asserts it raises — so a
  green on the real assertion is evidence the extractor can SEE the constant,
  not evidence that it looked.

  ## The config override: DOCUMENTED, not refused (criterion c2)

  `queued_deploy_alarm_after_seconds/0` falls back to the module default but is
  overridable via `config :barkpark_cloud, :queued_deploy_alarm_after_seconds`.
  That override is a real drift vector — the client cannot follow it, so an
  operator who sets it moves the server's horizon and leaves `bp cloud status`
  alarming at 300s regardless.

  We DOCUMENT it as deliberate and client-invisible rather than refusing it, for
  two reasons:

    1. A test cannot see prod config. This suite runs under `MIX_ENV=test` with
       the test config tree loaded; the override that would actually cause the
       divergence lives in a prod runtime config on the box. A "refuse when the
       override diverges" assertion here would red only on a *test-env* override
       nobody sets, and would stay silent for the exact deployment it claims to
       guard. It would be an assertion with no subject.
    2. The override is a deliberate operator act with a legitimate use: turning
       the SERVER'S alarm horizon during an incident (the value also feeds
       control-plane-side surfacing) without shipping a client. Refusing it
       would take away a knob to protect a mirror that this very test now locks
       at the level where it can be locked honestly — the DEFAULTS.

  So the contract this file enforces is exactly: **the committed default on the
  Elixir side and the committed literal on the Go side are the same number.** A
  runtime override is out of scope by construction, and is documented here so
  the next reader does not mistake the silence for coverage. The lasting fix for
  the override axis is to put the horizon on the wire (serve it in the status
  payload so the client consumes instead of mirrors); that is a payload design
  change and is deliberately NOT taken here.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Registry

  # Path.expand up out of cloud/test/barkpark_cloud/ into the repo root, then
  # into internal/cli/ — the same recipe the other cross-surface locks in this
  # directory use (see providers_capabilities_contract_test.exs).
  @go_source Path.expand("../../../internal/cli/cloud_status_cmd.go", __DIR__)

  @doc false
  @spec go_int_const!(binary(), binary()) :: integer()
  def go_int_const!(path, name) do
    unless File.exists?(path) do
      raise "Go source not found at #{path} — the deploy_stalled mirror lock cannot read its subject"
    end

    source = File.read!(path)

    if String.trim(source) == "" do
      raise "Go source at #{path} read EMPTY — refusing to compare against nothing"
    end

    regex = Regex.compile!("(?m)^\\s*const\\s+#{Regex.escape(name)}\\s*=\\s*(\\d+)\\b")

    case Regex.run(regex, source) do
      [_, digits] ->
        String.to_integer(digits)

      nil ->
        raise "no `const #{name} = <int>` in #{path} — the constant was renamed, moved, " <>
                "or reformatted; fix this extractor rather than deleting the lock"
    end
  end

  test "the Go client literal and the Elixir default horizon are the SAME number" do
    go_value = go_int_const!(@go_source, "queuedDeployStalledAfterSeconds")
    elixir_value = Registry.queued_deploy_alarm_after_seconds()

    assert go_value == elixir_value,
           "deploy_stalled horizon MIRROR DRIFT: internal/cli/cloud_status_cmd.go has " <>
             "queuedDeployStalledAfterSeconds = #{go_value}, but " <>
             "BarkparkCloud.Registry.queued_deploy_alarm_after_seconds/0 returns " <>
             "#{elixir_value}. These are one horizon on two surfaces — `bp cloud status` " <>
             "would fire deploy_stalled at a threshold the control plane does not hold. " <>
             "Update BOTH (cloud/lib/barkpark_cloud/registry.ex " <>
             "@default_queued_deploy_alarm_after_seconds and the Go const) or put the " <>
             "horizon on the wire."
  end

  test "positive control: the extractor REFUSES a name it cannot find" do
    assert_raise RuntimeError, ~r/no `const queuedDeployStalledAfterSecondsNOPE = <int>`/, fn ->
      go_int_const!(@go_source, "queuedDeployStalledAfterSecondsNOPE")
    end
  end

  test "positive control: the extractor REFUSES a missing file and an empty read" do
    assert_raise RuntimeError, ~r/Go source not found/, fn ->
      go_int_const!(Path.join(System.tmp_dir!(), "no_such_cloud_status_cmd.go"), "anything")
    end

    empty =
      Path.join(System.tmp_dir!(), "bp_empty_go_source_#{System.unique_integer([:positive])}.go")

    File.write!(empty, "   \n")

    try do
      assert_raise RuntimeError, ~r/read EMPTY/, fn ->
        go_int_const!(empty, "queuedDeployStalledAfterSeconds")
      end
    after
      File.rm(empty)
    end
  end
end
