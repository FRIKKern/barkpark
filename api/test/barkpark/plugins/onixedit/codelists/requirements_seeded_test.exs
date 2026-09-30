defmodule Barkpark.Plugins.OnixEdit.Codelists.RequirementsSeededTest do
  @moduledoc """
  task-7c9dafd4a99a8207 — the declared codelist roster and the ids the boot seed
  writes AGREE.

  The OnixEdit schemas name ONIX lists by role (`onixedit:contributor_role`),
  and `EDItEUR.seed_bundled/1` writes them by number (`onixedit:list_17`).
  `CodelistSeeders.requirements/0` used to declare the role names, so
  `Barkpark.Content.CodelistHealth` found 72 lists `:absent` on every boot and
  `/status.json`'s codelists component was permanently degraded. This seeds
  exactly what boot seeds (the bundled ONIX issue-73 snapshot and Thema) and
  audits the plugin's own roster against it.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Codelists.EDItEUR
  alias Barkpark.Content.CodelistHealth
  alias Barkpark.Plugins.OnixEdit.CodelistSeeders

  @moduletag timeout: 300_000

  setup do
    # config/test.exs turns the boot seed of the bundled snapshots off; this
    # test IS the boot seed, so it turns it back on for itself only.
    previous = Application.fetch_env(:barkpark, :seed_bundled_codelist_snapshots)
    Application.put_env(:barkpark, :seed_bundled_codelist_snapshots, true)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:barkpark, :seed_bundled_codelist_snapshots, v)
        :error -> Application.delete_env(:barkpark, :seed_bundled_codelist_snapshots)
      end
    end)

    assert {:ok, lists} = EDItEUR.seed_bundled()
    assert is_integer(lists) and lists > 100
    assert {:ok, thema} = EDItEUR.seed_thema()
    refute thema in [:no_snapshot, :skipped]
    :ok
  end

  test "every declared requirement is present at its declared issue after the boot seed" do
    reqs = CodelistSeeders.requirements()
    audit = CodelistHealth.audit(requirements: reqs)

    assert audit.problems == [],
           "#{length(audit.problems)} declared list(s) the boot seed does not serve: " <>
             Enum.join(CodelistHealth.messages(audit) |> Enum.take(5), " | ")

    assert audit.status == :ok
    assert audit.checked > 60
    assert Enum.all?(reqs, &is_binary(&1.name))
  end

  test "/status.json's codelists component is operational on the real roster after the boot seed" do
    previous = Application.get_env(:barkpark, :run_boot_codelist_seeders, true)
    Application.put_env(:barkpark, :run_boot_codelist_seeders, true)
    on_exit(fn -> Application.put_env(:barkpark, :run_boot_codelist_seeders, previous) end)

    assert %{component: :codelists, status: :operational, detail: nil} =
             Barkpark.Status.codelists_component(requirements: CodelistSeeders.requirements())
  end

  test "CONTROL: the role-named roster the schemas spell is :absent against the same seed" do
    audit = CodelistHealth.audit(requirements: CodelistSeeders.declared())

    assert audit.status == :degraded
    assert Enum.count(audit.problems, &(&1.reason == :absent)) >= 70
    refute Enum.any?(audit.problems, &(&1.list_id == "onixedit:thema"))
  end

  test "every declared role name resolves to a list number the bundled snapshot carries" do
    unmapped =
      CodelistSeeders.requirements()
      |> Enum.reject(&(&1.list_id == "onixedit:thema"))
      |> Enum.reject(&String.starts_with?(&1.list_id, "onixedit:list_"))
      |> Enum.map(& &1.name)

    assert unmapped == [], "role names with no ONIX list number: #{inspect(unmapped)}"
  end
end
