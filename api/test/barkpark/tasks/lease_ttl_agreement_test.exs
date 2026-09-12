defmodule Barkpark.Tasks.LeaseTtlAgreementTest do
  @moduledoc """
  `QueueGate` and `TtlSweeper` each decide when a claim's lease is over, and they
  decide it INDEPENDENTLY: two `Application.get_env(:barkpark,
  :task_lease_ttl_seconds, _)` calls with two separate module-level defaults.

  Nothing makes them agree. If they drift, the ledger splits: a claim the ready
  queue treats as dead and hands to a new worker, while the sweeper still
  considers it live and never reaps it — or the reverse, a row the sweeper
  reaps that the queue still hides. Both halves are silent.

  `QueueGate`'s own moduledoc says the readers share its accessor and that
  `TtlSweeper` "keeps its own because it is the writer of the reap boundary, not
  a reader of it". That is a deliberate split, and a deliberate split is exactly
  the kind that needs a test rather than a sentence — the sentence cannot fail.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.Tasks.QueueGate

  @sweeper_source "lib/barkpark/tasks/ttl_sweeper.ex"
  @gate_source "lib/barkpark/tasks/queue_gate.ex"

  # Pull each module's default out of its own source rather than restating the
  # number here. Restating it would make THIS FILE a third place the constant
  # lives, and a drift guard that itself drifts is worse than none.
  defp default_in!(relative_path, attribute) do
    path = Path.join(File.cwd!(), relative_path)
    source = File.read!(path)

    case Regex.run(~r/@#{attribute}\s+(\d[\d_]*)/, source) do
      [_, digits] ->
        String.to_integer(String.replace(digits, "_", ""))

      nil ->
        # AN ABSENCE MUST NOT PASS SILENTLY. If the attribute was renamed, this
        # test would otherwise go vacuous and keep reporting green while the
        # thing it guards stopped existing.
        flunk("""
        Could not find @#{attribute} in #{relative_path}.

        It was renamed or removed. This test cannot compare defaults it cannot
        find, and a green here would be meaningless — update the attribute name
        in this test, do not delete the assertion.
        """)
    end
  end

  test "both modules default to the SAME lease TTL" do
    sweeper_default = default_in!(@sweeper_source, "default_ttl_seconds")
    gate_default = default_in!(@gate_source, "default_lease_ttl_seconds")

    # CONTROL: the reader actually read something. A regex that silently matched
    # nothing would make the equality below trivially true on two zeros.
    assert sweeper_default > 0
    assert gate_default > 0

    assert sweeper_default == gate_default, """
    Lease TTL defaults have DRIFTED.

      #{@gate_source}    @default_lease_ttl_seconds = #{gate_default}
      #{@sweeper_source} @default_ttl_seconds       = #{sweeper_default}

    The ready queue and the reaper would disagree about which claims are dead.
    """

    # And with the config key absent, the accessor every reader uses lands on
    # that same shared number rather than on something a caller passed in.
    original = Application.get_env(:barkpark, :task_lease_ttl_seconds)
    on_exit(fn -> Application.put_env(:barkpark, :task_lease_ttl_seconds, original) end)

    Application.delete_env(:barkpark, :task_lease_ttl_seconds)
    assert QueueGate.lease_ttl_seconds() == gate_default
  end

  test "both modules read the SAME config key" do
    # Equal defaults are not enough: one module could keep its default and start
    # reading a DIFFERENT key, and every default-configured environment would
    # still look fine. Set the shared key to a value neither default could be,
    # and the accessor must follow it.
    original = Application.get_env(:barkpark, :task_lease_ttl_seconds)
    on_exit(fn -> Application.put_env(:barkpark, :task_lease_ttl_seconds, original) end)

    Application.put_env(:barkpark, :task_lease_ttl_seconds, 4321)
    assert QueueGate.lease_ttl_seconds() == 4321

    # CONTROL: the accessor is not simply echoing whatever it is handed — a
    # second, different value must also come back.
    Application.put_env(:barkpark, :task_lease_ttl_seconds, 8765)
    assert QueueGate.lease_ttl_seconds() == 8765

    # And the key name is asserted at its source, so a rename in either module
    # is caught here rather than in production.
    for {path, label} <- [{@sweeper_source, "TtlSweeper"}, {@gate_source, "QueueGate"}] do
      source = File.read!(Path.join(File.cwd!(), path))

      assert source =~ ":task_lease_ttl_seconds",
             "#{label} (#{path}) no longer mentions :task_lease_ttl_seconds — " <>
               "it has been renamed, and the two modules no longer share a key."
    end
  end
end
