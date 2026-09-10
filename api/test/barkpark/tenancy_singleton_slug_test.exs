defmodule Barkpark.TenancySingletonSlugTest do
  @moduledoc """
  The instance-default workspace slug is a SINGLETON SEAT, and a principal
  creating a workspace must never be able to take it (task-94a6ed8ced1fc547).

  `Tenancy.get_default_workspace/0` is `Repo.get_by(Workspace, slug: "default")`.
  Whoever holds that slug IS the instance default: `AssignDefaultScope` binds
  every flat route to it, and `Content.WriteScope.resolve_write_scope/1` stamps
  an UNSCOPED WRITE with it. So once the seat is vacant, taking the slug takes
  the seat.

  The seat goes vacant in NORMAL operation — `SupportResetDefaultWorkspaceStep`
  deletes it and `SupportAdminTokenStep` re-mints it, and the seat is vacant
  BETWEEN those two steps.

  FOUR CLAIM PATHS, and only one of them sends a `slug` field. `put_derived_slug/1`
  slugifies the NAME when no slug is given, and `slugify("Default") == "default"`,
  so a guard on `params["slug"]` alone would catch one of four. All four funnel
  through `do_create_workspace_with_owner/3`, which is where the guard sits.

  The NEGATIVE arms matter as much: `Tenancy.create_workspace/1` is the INTERNAL
  creator that legitimately re-mints the singleton (Seeds.Shared.ensure_default_scope/0,
  mix frt.seed). Guarding it would break seeding and the support bracket's own
  recovery.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Repo, Tenancy}
  alias Barkpark.Tenancy.Workspace

  setup do
    # Vacate the seat with ONE update rather than Tenancy.delete_workspace/1.
    # The real teardown runs a multi-table cascade AND flushes deferred media
    # effects, which under the shared sandbox deadlocked against the test's own
    # transaction (Postgrex 40P01) — a harness artefact, not a product finding.
    # What every arm here needs is only that `get_default_workspace/0` resolves
    # to nothing.
    #
    # RETRACTED, and left standing as the record: this comment used to add "it
    # is also the faithful shape — renaming out of the slug is itself one of the
    # ways the seat goes vacant (Workspace.changeset/2 casts :slug)". That was
    # TRUE when it was written and is FALSE now. task-566dc5be4871353b moved the
    # seat to `workspaces.is_default`, a column NO changeset casts, so a rename
    # moves nothing and the flag has to be cleared on its own line. The rename is
    # kept only so the arms below can mint their own `default`-slugged rows
    # without colliding on `workspaces_slug_index`.
    {_n, _} =
      Repo.update_all(
        from(w in Workspace, where: w.slug == ^"default"),
        set: [slug: "vacated-for-test"]
      )

    # THE RENAME PATH IS CLOSED. Asserted in the setup, where a regression would
    # otherwise make every arm below vacuous rather than red.
    vacated = Tenancy.get_default_workspace()

    assert match?(%Workspace{slug: "vacated-for-test"}, vacated),
           "RENAME MOVED THE SEAT: the instance-default singleton is once again " <>
             "identified by a mutable, user-claimable string (task-566dc5be4871353b); " <>
             "got #{inspect(vacated)}"

    {_n, _} =
      Repo.update_all(from(w in Workspace, where: w.is_default == true), set: [is_default: false])

    Barkpark.Tenancy.DefaultScopeCache.invalidate()

    refute Tenancy.get_default_workspace()
    :ok
  end

  defp unique_name, do: "ws-#{System.unique_integer([:positive])}"

  defp claimant_token do
    # A principal id is all create_workspace_with_owner/2 needs; any binary
    # stands in for the token that would carry it.
    Ecto.UUID.generate()
  end

  describe "a principal claiming ownership can never take the singleton seat" do
    test "EXPLICIT slug — POST /api/workspaces {\"slug\":\"default\"} shape" do
      result =
        Tenancy.create_workspace_with_owner(
          %{name: "Not The Real Default", slug: "default"},
          claimant_token()
        )

      assert match?({:error, %Ecto.Changeset{}}, result),
             "an explicit slug claim took the singleton seat; got: #{inspect(result)}"

      refute Tenancy.get_default_workspace(),
             "the seat must still be vacant after a refused claim"
    end

    test "DERIVED slug — {\"name\":\"Default\"} with no slug field at all" do
      # This is the arm a controller-level params[\"slug\"] check cannot see.
      assert Tenancy.slugify("Default") == "default"

      result = Tenancy.create_workspace_with_owner(%{name: "Default"}, claimant_token())

      assert match?({:error, %Ecto.Changeset{}}, result),
             "a DERIVED slug claim took the singleton seat — put_derived_slug/1 " <>
               "slugifies the name, so the guard must sit after derivation; got: #{inspect(result)}"

      refute Tenancy.get_default_workspace()
    end

    test "DERIVED slug, case and punctuation variants still cannot claim it" do
      for name <- ["DEFAULT", "default", "  Default  ", "default!"] do
        assert Tenancy.slugify(name) == "default", "fixture assumption: #{name}"

        claimed = Tenancy.create_workspace_with_owner(%{name: name}, claimant_token())

        assert match?({:error, %Ecto.Changeset{}}, claimed),
               "name #{inspect(name)} claimed the singleton seat; got: #{inspect(claimed)}"
      end
    end

    test "the refusal does NOT capture an unscoped write (the whole point)" do
      {:error, _} = Tenancy.create_workspace_with_owner(%{name: "Default"}, claimant_token())

      {:ok, doc} =
        Content.create_document(
          "post",
          %{"title" => "unscoped after refused claim"},
          "production",
          []
        )

      row = Repo.get_by(Content.Document, id: doc.id)

      # With the seat vacant and unclaimable, an unscoped write has no workspace
      # to be captured INTO. Vacancy is a bounded problem (the read side is
      # confined by PR #12870); capture is an unbounded privilege transfer.
      assert is_nil(row.workspace_id),
             "an unscoped write was attributed to a workspace despite the seat being vacant"
    end
  end

  describe "NEGATIVE ARMS — the legitimate creators keep working" do
    test "Tenancy.create_workspace/1 still mints a default-slugged row — and the SEAT stays VACANT" do
      minted = Tenancy.create_workspace(%{slug: "default", name: "Default Workspace"})

      assert match?({:ok, %Workspace{slug: "default"}}, minted),
             "the INTERNAL creator was guarded — this breaks seeding and the " <>
               "support bracket's own recovery; got: #{inspect(minted)}"

      # THE ASSERTION THAT FLIPPED, and the flip IS the fix
      # (task-566dc5be4871353b). This line used to read
      # `assert Tenancy.get_default_workspace()`: minting the slug WAS taking the
      # seat, which is exactly why the singleton was claimable. Now the slug and
      # the seat are different things — the row exists, the seat does not move,
      # and only `establish_default_workspace!/0` (below) can fill it.
      refute Tenancy.get_default_workspace(),
             "minting a `default`-slugged workspace TOOK the instance-default seat — the " <>
               "singleton is identifiable by a user-supplied string again"
    end

    test "Seeds.Shared.ensure_default_scope/0 still establishes the default (WRITER 1 of 3)" do
      _ = Barkpark.Seeds.Shared.ensure_default_scope()

      default_ws = Tenancy.get_default_workspace()

      assert match?(%Workspace{slug: "default", is_default: true}, default_ws),
             "ensure_default_scope/0 could not re-establish the singleton; got: #{inspect(default_ws)}"
    end

    test "establish_default_workspace!/0 ADOPTS an orphaned default-slugged row rather than " <>
           "inserting a second one" do
      # The state a migration leaves if the backfill ran while the flag was
      # clear, and the state an operator leaves by clearing the flag by hand:
      # the row is there, the seat is not. A blind insert would collide on
      # `workspaces_slug_index` and crash the support bracket's re-mint.
      {:ok, orphan} = Tenancy.create_workspace(%{slug: "default", name: "Default Workspace"})
      refute Tenancy.get_default_workspace()

      established = Tenancy.establish_default_workspace!()

      assert established.id == orphan.id,
             "establish_default_workspace!/0 minted a SECOND default-slugged workspace " <>
               "instead of adopting the orphaned row"

      assert Tenancy.get_default_workspace().id == orphan.id
    end

    test "establish_default_workspace!/0 is idempotent — a held seat is returned untouched" do
      first = Tenancy.establish_default_workspace!()
      second = Tenancy.establish_default_workspace!()

      assert first.id == second.id
      assert Tenancy.get_default_workspace().id == first.id
    end

    test "at most ONE workspace can hold the seat (workspaces_single_default_index)" do
      held = Tenancy.establish_default_workspace!()
      {:ok, other} = Tenancy.create_workspace_with_owner(%{name: unique_name()}, claimant_token())

      # Postgrex.Error, not Ecto.ConstraintError: `update_all` carries no
      # changeset for Ecto to translate the 23505 against — which is the point.
      # The index is the wall, and it stands under a RAW write, not only under
      # the changeset path that never had access to the field anyway.
      err =
        assert_raise Postgrex.Error, fn ->
          Repo.update_all(from(w in Workspace, where: w.id == ^other.id), set: [is_default: true])
        end

      assert err.postgres.constraint == "workspaces_single_default_index"

      assert Tenancy.get_default_workspace().id == held.id
    end

    test "an ordinary owner-create is untouched" do
      assert {:ok, %Workspace{slug: "my-team"}} =
               Tenancy.create_workspace_with_owner(%{name: "My Team"}, claimant_token())
    end

    test "a name that merely CONTAINS default is not refused" do
      assert {:ok, %Workspace{slug: "default-ish"}} =
               Tenancy.create_workspace_with_owner(%{name: "Default-ish"}, claimant_token())
    end
  end
end
