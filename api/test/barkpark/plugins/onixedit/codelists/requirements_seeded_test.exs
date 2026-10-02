defmodule Barkpark.Plugins.OnixEdit.Codelists.RequirementsSeededTest do
  @moduledoc """
  task-7c9dafd4a99a8207 — the declared codelist roster and the ids the boot seed
  writes AGREE.

  The OnixEdit schemas name ONIX lists by role (`onixedit:contributor_role`),
  and `EDItEUR.seed_bundled/1` writes them by number (`onixedit:list_17`).
  `CodelistSeeders.requirements/0` used to declare the role names, so
  `Barkpark.Content.CodelistHealth` found 72 lists `:absent` on every boot and
  `/status.json`'s codelists component was permanently degraded.

  ## What is seeded, and why not the whole bundle (task-aca9dda7e954d686)

  The first version ran `seed_bundled/0` + `seed_thema/0` in `setup`, ~28k rows
  per test, and hit 57014 query_canceled under a loaded CI runner, redding
  unrelated PRs. The boot-equivalence this file needs is about the IDS, so it
  keeps the boot's own path and trims the volume:

    * the bundled ONIX snapshot is parsed by `EDItEUR.parse_xml/2` from the
      real `priv/codelists/onix-issue-73.xml` file and registered by
      `EDItEUR.seed/2` at `EDItEUR.bundled_issue/0` — the exact two calls
      `seed_bundled/1` composes — restricted to the lists the roster declares.
      The ids therefore come from the snapshot, never from this test.
    * Thema is seeded under its role id by `seed_thema/1` at boot; its
      correctness is not this file's subject (its id never changed), so one
      value is registered at `EDItEUR.thema_issue/0`.

  Seeded once per test in the test's own sandbox transaction; two tests.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Codelists.EDItEUR
  alias Barkpark.Content.CodelistHealth
  alias Barkpark.Content.Codelists
  alias Barkpark.Plugins.OnixEdit.CodelistSeeders

  @plugin "onixedit"

  setup do
    reqs = CodelistSeeders.requirements()
    wanted = reqs |> Enum.map(& &1.list_id) |> MapSet.new()

    {:ok, path} = EDItEUR.bundled_path()
    {:ok, parsed} = EDItEUR.parse_xml(path, plugin: @plugin)
    declared_lists = Enum.filter(parsed, &MapSet.member?(wanted, &1.list_id))

    assert {:ok, seeded} =
             EDItEUR.seed(declared_lists, plugin: @plugin, issue: EDItEUR.bundled_issue())

    assert {:ok, _} =
             Codelists.register(@plugin, "onixedit:thema", %{
               issue: EDItEUR.thema_issue(),
               name: "Thema",
               values: [%{code: "A", translations: [%{language: "en", label: "Arts"}]}]
             })

    %{reqs: reqs, seeded: seeded}
  end

  test "every declared requirement is present at its declared issue, and /status.json is operational",
       %{reqs: reqs, seeded: seeded} do
    # Every role name maps to a list the real snapshot carries: the numeric ids
    # the roster declares were found in the parsed bundle and seeded.
    numeric = reqs |> Enum.map(& &1.list_id) |> Enum.reject(&(&1 == "onixedit:thema"))

    assert Enum.all?(numeric, &String.starts_with?(&1, "onixedit:list_")),
           "role names with no ONIX list number: " <>
             inspect(Enum.reject(reqs, &String.starts_with?(&1.list_id, "onixedit:list_")))

    assert MapSet.subset?(MapSet.new(numeric), MapSet.new(seeded)),
           "declared ids the bundled snapshot does not carry: " <>
             inspect(MapSet.difference(MapSet.new(numeric), MapSet.new(seeded)))

    audit = CodelistHealth.audit(requirements: reqs)

    assert audit.problems == [],
           "#{length(audit.problems)} declared list(s) the boot seed does not serve: " <>
             Enum.join(CodelistHealth.messages(audit) |> Enum.take(5), " | ")

    assert audit.status == :ok
    assert audit.checked > 60
    assert Enum.all?(reqs, &is_binary(&1.name))

    previous = Application.get_env(:barkpark, :run_boot_codelist_seeders, true)
    Application.put_env(:barkpark, :run_boot_codelist_seeders, true)
    on_exit(fn -> Application.put_env(:barkpark, :run_boot_codelist_seeders, previous) end)

    assert %{component: :codelists, status: :operational, detail: nil} =
             Barkpark.Status.codelists_component(requirements: reqs)
  end

  test "CONTROL: the role-named roster the schemas spell is :absent against the same seed" do
    audit = CodelistHealth.audit(requirements: CodelistSeeders.declared())

    assert audit.status == :degraded
    assert Enum.count(audit.problems, &(&1.reason == :absent)) >= 70
    refute Enum.any?(audit.problems, &(&1.list_id == "onixedit:thema"))
  end
end
