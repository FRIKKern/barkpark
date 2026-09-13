defmodule Barkpark.Content.CodelistRequirementsSeamTest do
  @moduledoc """
  The INVERTED codelist-requirements seam behind `CodelistHealth.requirements/0`.

  `Barkpark.Content.CodelistHealth` used to call `Barkpark.Plugins.Registry.all/0`
  directly — a KERNEL concept (`content`) reaching into a FEATURE (`registry`),
  the wrong-direction dependency `tooling/concept-map/ci-boundary.mjs` reports
  as `content>registry`. The arrow is now turned around: the composition root
  (`Barkpark.Application.start/2`) installs the roster fan-out under
  `:codelist_requirements_collector` and the kernel only READS it. Modelled on
  `graph_extractor_seam_test.exs`, which proves the same shape one module over.

  Two properties the indirection has to buy, or it is decoration:

    1. SUBSTITUTABILITY — a collector installed through the seam actually
       reaches `audit/1`'s verdict. Anything (the plugin registry, a stub) can
       be the supplier, because the kernel names none of them.
    2. ABSENCE IS SAFE — an UNSET seam yields an EMPTY roster and an `:ok`
       audit, never a raise and never invented `:absent` problems. That is the
       fresh-install invariant: a plugin-free host is not "missing" codelists.
  """

  # NOT async. The seam is one global `Application` env key; a module running
  # concurrently would observe this module's stub (or its deletion) as its own
  # configuration.
  # sync: swaps node-global Application env (the codelist-requirements seam key)
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.CodelistHealth

  @seam_key :codelist_requirements_collector

  setup do
    original = Application.get_env(:barkpark, @seam_key)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:barkpark, @seam_key)
        value -> Application.put_env(:barkpark, @seam_key, value)
      end
    end)

    :ok
  end

  defp req(list_id),
    do: %{plugin_name: "seamtest", list_id: list_id, issue: "73"}

  describe "the inverted :codelist_requirements_collector seam" do
    test "a collector installed through the seam reaches the audit verdict" do
      test_pid = self()
      list_id = "seamtest:stub_#{System.unique_integer([:positive])}"

      Application.put_env(:barkpark, @seam_key, fn ->
        send(test_pid, :seam_invoked)
        [req(list_id)]
      end)

      # Non-vacuity: the roster the kernel read is the stub's, and nothing in
      # the database holds this list — so the verdict names it.
      assert [req(list_id)] == CodelistHealth.requirements()

      audit = CodelistHealth.audit()

      assert_received :seam_invoked
      assert audit.checked == 1
      assert audit.status == :degraded
      assert [%{list_id: ^list_id, reason: :absent}] = audit.problems
      assert Enum.any?(CodelistHealth.messages(audit), &String.contains?(&1, list_id))
    end

    test "a {module, function} pair is an equally valid supplier" do
      Application.put_env(:barkpark, @seam_key, {__MODULE__, :mfa_roster})

      assert [%{list_id: "seamtest:mfa"}] = CodelistHealth.requirements()
      assert %{checked: 1, status: :degraded} = CodelistHealth.audit()
    end

    test "an UNSET seam yields an empty roster and an :ok audit, and never raises" do
      Application.delete_env(:barkpark, @seam_key)
      assert Application.get_env(:barkpark, @seam_key) == nil

      assert CodelistHealth.requirements() == []
      assert %{status: :ok, checked: 0, problems: []} = CodelistHealth.audit()
      assert %{status: :ok, checked: 0, problems: []} = CodelistHealth.log_boot_audit()
    end

    test "a garbage seam value, and a collector that raises, degrade to []" do
      Application.put_env(:barkpark, @seam_key, :not_a_collector)
      assert CodelistHealth.requirements() == []
      assert %{status: :ok, checked: 0} = CodelistHealth.audit()

      Application.put_env(:barkpark, @seam_key, fn -> raise "boom" end)
      assert CodelistHealth.requirements() == []
      assert %{status: :ok, checked: 0} = CodelistHealth.audit()

      # Malformed entries are dropped rather than propagated.
      Application.put_env(:barkpark, @seam_key, fn -> [:garbage, %{plugin_name: "x"}] end)
      assert CodelistHealth.requirements() == []
    end

    test "the kernel module names no plugin module (the edge the gate reports)" do
      source = File.read!("lib/barkpark/content/codelist_health.ex")

      refute source =~ "Barkpark.Plugins",
             "content/codelist_health.ex must hold no compile-time reference to the plugin layer"
    end
  end

  describe "the supplier side" do
    test "the registry collector probes for the plugin-local declaration" do
      roster = Barkpark.Plugins.Registry.collect_codelist_requirements()

      assert is_list(roster)

      # Every entry a registered plugin declared is roster-shaped; a plugin
      # without `codelist_requirements/0` simply contributes nothing.
      for entry <- roster do
        assert %{plugin_name: _, list_id: _, issue: _} = entry
      end
    end
  end

  def mfa_roster, do: [%{plugin_name: "seamtest", list_id: "seamtest:mfa", issue: "73"}]
end
