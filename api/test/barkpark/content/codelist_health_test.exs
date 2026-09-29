defmodule Barkpark.Content.CodelistHealthTest do
  @moduledoc """
  The operator signal for a codelist seed that did not land.

  The suite is built around the failure the check exists for and the one an
  emptiness scan cannot see: a first-ever seed that rolls back leaves the
  codelist ABSENT, not empty, because `Content.Codelists.register/3` upserts the
  header inside the values' transaction. Every "names the problem" test is paired
  with a NEGATIVE CONTROL on a healthy list at the same issue — a check that
  flagged everything would pass the positive half alone.

  `async: false`: the skip arm reads `:run_boot_codelist_seeders` out of the
  application environment, which is global.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.CodelistHealth
  alias Barkpark.Content.Codelists
  alias Barkpark.Status

  @plugin "healthtest"

  defp req(list_id, issue), do: %{plugin_name: @plugin, list_id: list_id, issue: issue}

  defp seed!(list_id, issue, values) do
    {:ok, codelist} =
      Codelists.register(@plugin, list_id, %{
        issue: issue,
        name: "Health test #{list_id}",
        values: values
      })

    codelist
  end

  defp value(code), do: %{code: code, translations: [%{language: "en", label: code}]}

  describe "audit/1 — a list that seeded correctly" do
    test "a populated list at the declared issue is clean" do
      list_id = "#{@plugin}:ok_#{System.unique_integer([:positive])}"
      seed!(list_id, "73", [value("A"), value("B")])

      assert %{status: :ok, checked: 1, problems: []} =
               CodelistHealth.audit(requirements: [req(list_id, "73")])
    end

    test "an empty roster is clean and checks nothing" do
      assert %{status: :ok, checked: 0, problems: []} = CodelistHealth.audit(requirements: [])
    end
  end

  describe "audit/1 — the fresh-install rollback (ABSENT, not empty)" do
    test "a declared list with no codelist row at all is named" do
      list_id = "#{@plugin}:absent_#{System.unique_integer([:positive])}"

      assert %{status: :degraded, checked: 1, problems: [problem]} =
               CodelistHealth.audit(requirements: [req(list_id, "73")])

      assert problem.reason == :absent
      assert problem.list_id == list_id
      assert problem.message =~ "codelist #{list_id} is empty or stale"
      assert problem.message =~ "no codelist row exists"
    end

    test "the absent list is named while a healthy sibling at the same issue is not" do
      healthy = "#{@plugin}:sib_ok_#{System.unique_integer([:positive])}"
      missing = "#{@plugin}:sib_gone_#{System.unique_integer([:positive])}"
      seed!(healthy, "73", [value("A")])

      audit = CodelistHealth.audit(requirements: [req(healthy, "73"), req(missing, "73")])

      assert audit.status == :degraded
      assert audit.checked == 2
      assert [%{list_id: ^missing, reason: :absent}] = audit.problems

      summary = CodelistHealth.summary(audit)
      assert summary =~ missing
      refute summary =~ healthy
    end
  end

  describe "audit/1 — empty and stale" do
    test "a header row with zero values is named :empty" do
      list_id = "#{@plugin}:empty_#{System.unique_integer([:positive])}"
      seed!(list_id, "73", [])

      assert %{status: :degraded, problems: [problem]} =
               CodelistHealth.audit(requirements: [req(list_id, "73")])

      assert problem.reason == :empty
      assert problem.message =~ "codelist #{list_id} is empty or stale"
      assert problem.message =~ "0 values"
    end

    test "a populated list at an older issue than the plugin declares is named :stale" do
      list_id = "#{@plugin}:stale_#{System.unique_integer([:positive])}"
      seed!(list_id, "72", [value("A")])

      assert %{status: :degraded, problems: [problem]} =
               CodelistHealth.audit(requirements: [req(list_id, "73")])

      assert problem.reason == :stale
      assert problem.expected_issue == "73"
      assert problem.message =~ "registered at issue 72"
      assert problem.message =~ "declares issue 73"
    end

    test "a list carrying BOTH the old and the current issue is clean" do
      list_id = "#{@plugin}:both_#{System.unique_integer([:positive])}"
      seed!(list_id, "72", [value("A")])
      seed!(list_id, "73", [value("A"), value("B")])

      assert %{status: :ok, problems: []} =
               CodelistHealth.audit(requirements: [req(list_id, "73")])
    end
  end

  describe "summary/2" do
    test "returns nil for a clean audit" do
      assert CodelistHealth.summary(%{status: :ok, checked: 0, problems: []}) == nil
    end

    test "names the first few lists and counts the rest" do
      reqs = for n <- 1..8, do: req("#{@plugin}:bulk_#{n}_#{System.unique_integer()}", "73")
      audit = CodelistHealth.audit(requirements: reqs)

      assert audit.status == :degraded
      assert length(audit.problems) == 8

      summary = CodelistHealth.summary(audit, limit: 5)
      assert summary =~ "and 3 more codelist(s) empty or stale"
      assert summary =~ hd(reqs).list_id
      refute summary =~ List.last(reqs).list_id
    end
  end

  describe "Status.codelists_component/1 — the operator-facing surface" do
    setup do
      previous = Application.get_env(:barkpark, :run_boot_codelist_seeders, true)
      Application.put_env(:barkpark, :run_boot_codelist_seeders, true)
      on_exit(fn -> Application.put_env(:barkpark, :run_boot_codelist_seeders, previous) end)
      :ok
    end

    test "a missing codelist degrades the component and the detail names the list" do
      list_id = "#{@plugin}:svc_gone_#{System.unique_integer([:positive])}"

      component = Status.codelists_component(requirements: [req(list_id, "73")])

      assert component.component == :codelists
      assert component.status == :degraded
      assert component.detail =~ "codelist #{list_id} is empty or stale"
    end

    test "a healthy roster is operational with no detail (negative control)" do
      list_id = "#{@plugin}:svc_ok_#{System.unique_integer([:positive])}"
      seed!(list_id, "73", [value("A")])

      assert %{component: :codelists, status: :operational, detail: nil} =
               Status.codelists_component(requirements: [req(list_id, "73")])
    end
  end

  describe "Status.codelists_component/1 — the boot-seeder-disabled skip arm" do
    test "a node that does not boot-seed codelists is not dyed degraded" do
      previous = Application.get_env(:barkpark, :run_boot_codelist_seeders, true)
      Application.put_env(:barkpark, :run_boot_codelist_seeders, false)
      on_exit(fn -> Application.put_env(:barkpark, :run_boot_codelist_seeders, previous) end)

      list_id = "#{@plugin}:skip_#{System.unique_integer([:positive])}"

      assert %{component: :codelists, status: :operational, detail: nil} =
               Status.codelists_component(requirements: [req(list_id, "73")])
    end
  end

  describe "Status.health/0" do
    test "carries a :codelists component alongside the existing probes" do
      health = Status.health()
      names = Enum.map(health.components, & &1.component)

      assert :codelists in names
      assert :database in names
      assert Enum.all?(health.components, &Map.has_key?(&1, :detail))
    end
  end
end
