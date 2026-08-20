defmodule Barkpark.Search.SynonymsCrossTenantTest do
  @moduledoc """
  W7 tenancy proof — the search_synonyms cross-tenant 500-collision (VF1).

  Before this slice, `Synonyms.create/3` keyed every write on the bare
  `(surface, scope)` tuple and stamped only `dataset_id` via
  `Tenancy.default_project_dataset_id/1` — a GLOBAL singleton
  (`get_default_project`). Two DIFFERENT workspaces that both search the shared
  `scope = "production"` slug resolved the IDENTICAL `dataset_id`, so the live
  unique index `search_synonyms_dataset_id_unique_idx` on
  `(surface, dataset_id, from, to, kind)` treated tenant B's own copy of a
  common synonym as a collision. `Synonym` had NO changeset, so tenant B's
  insert raised an uncaught `Ecto.ConstraintError` → HTTP 500.

  The fix threads `workspace_id` through the write, splits the unique index into
  two partial arms (per-tenant `WHERE workspace_id IS NOT NULL` + legacy/global
  `WHERE workspace_id IS NULL`), and gives `Synonym` a `changeset/2` whose
  `unique_constraint` maps a same-tenant duplicate to `{:error, changeset}`
  (→ 422) instead of a raw 500.

  These tests exercise the `Synonyms` context directly (the gate runs
  `test/barkpark/search/`). Each workspace stands in for a workspace-bound admin
  token minted via `Auth.create_token(..., ws.id)` — the resolved `workspace_id`
  the controllers thread from `conn.assigns.current_workspace`. A nil-ws caller
  resolves to the Default scope and cannot distinguish tenants, which is exactly
  the collision this closes.
  """
  use Barkpark.DataCase, async: true

  import Ecto.Query

  alias Barkpark.Search.{Synonym, Synonyms}
  alias Barkpark.{Repo, Tenancy}

  # ONE scope string shared by BOTH workspaces — isolation must come from the
  # stamped workspace_id, NOT the dataset slug (both resolve the SAME global
  # Default dataset_id, which is precisely what used to collide).
  @scope "production"

  setup do
    {:ok, ws_a} = Tenancy.create_workspace(%{slug: "syn-tenant-a", name: "Tenant A"})
    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "syn-tenant-b", name: "Tenant B"})
    %{ws_a: ws_a, ws_b: ws_b}
  end

  defp count_rows(surface, from, to) do
    Repo.one(
      from(s in Synonym,
        where: s.surface == ^surface and s.from_query == ^from and s.to_query == ^to,
        select: count(s.id)
      )
    )
  end

  describe "identical (surface, scope, from, to, kind) across two workspaces" do
    for surface <- ["documents", "media"] do
      test "#{surface}: tenant B's identical insert gets its OWN row (no cross-tenant 500)", %{
        ws_a: ws_a,
        ws_b: ws_b
      } do
        surface = unquote(surface)
        attrs = %{"from" => "hero", "to" => "phoenix", "kind" => "one_way"}

        # Tenant A: 2xx.
        assert {:ok, row_a} = Synonyms.create(surface, @scope, attrs, ws_a.id)
        # Tenant B: IDENTICAL tuple, 2xx with its OWN row (RED before: 500).
        assert {:ok, row_b} = Synonyms.create(surface, @scope, attrs, ws_b.id)

        assert row_a.id != row_b.id
        # Two distinct persisted rows for the same (surface, from, to) tuple —
        # one per workspace. Before the fix only one could exist.
        assert count_rows(surface, "hero", "phoenix") == 2
      end

      test "#{surface}: tenant B never sees tenant A's exclusive synonym", %{
        ws_a: ws_a,
        ws_b: ws_b
      } do
        surface = unquote(surface)

        # A-only synonym (distinct target so a leak is observable).
        assert {:ok, _} =
                 Synonyms.create(
                   surface,
                   @scope,
                   %{"from" => "wizard", "to" => "gandalf", "kind" => "one_way"},
                   ws_a.id
                 )

        # A's own scoped read expands it; B's scoped read does NOT.
        assert "gandalf" in Synonyms.search_terms(surface, @scope, "wizard", ws_a.id)
        refute "gandalf" in Synonyms.search_terms(surface, @scope, "wizard", ws_b.id)

        assert Synonyms.correction_for(surface, @scope, "wizard", ws_a.id) == "gandalf"
        assert Synonyms.correction_for(surface, @scope, "wizard", ws_b.id) == nil

        # list/3 is likewise tenant-scoped.
        b_froms = surface |> Synonyms.list(@scope, ws_b.id) |> Enum.map(& &1.from)
        refute "wizard" in b_froms
      end
    end
  end

  describe "same-tenant duplicate → changeset error (422), never a raw 500" do
    test "documents: a second identical insert under the SAME workspace returns {:error, changeset}",
         %{ws_a: ws_a} do
      attrs = %{"from" => "cat", "to" => "feline", "kind" => "one_way"}

      assert {:ok, _} = Synonyms.create("documents", @scope, attrs, ws_a.id)

      # Fail-before: with no Synonym.changeset the duplicate raised
      # Ecto.ConstraintError (→ 500). Now it is caught as a changeset error.
      assert {:error, %Ecto.Changeset{} = cs} =
               Synonyms.create("documents", @scope, attrs, ws_a.id)

      refute cs.valid?

      # Still exactly one row for this workspace's tuple.
      assert count_rows("documents", "cat", "feline") == 1
    end

    test "legacy/global (nil workspace) duplicate also maps to a changeset error" do
      attrs = %{"from" => "dog", "to" => "canine", "kind" => "one_way"}

      assert {:ok, _} = Synonyms.create("documents", @scope, attrs, nil)
      assert {:error, %Ecto.Changeset{}} = Synonyms.create("documents", @scope, attrs, nil)
    end
  end

  describe "tenant delete boundary" do
    test "a workspace cannot delete a sibling workspace's synonym", %{ws_a: ws_a, ws_b: ws_b} do
      assert {:ok, row_a} =
               Synonyms.create(
                 "documents",
                 @scope,
                 %{"from" => "ship", "to" => "vessel", "kind" => "one_way"},
                 ws_a.id
               )

      # B tries to delete A's row → not_found (tenant guard), row survives.
      assert {:error, :not_found} = Synonyms.delete(row_a.id, "documents", @scope, ws_b.id)
      assert Repo.get(Synonym, row_a.id)

      # A deletes its own row → ok.
      assert :ok = Synonyms.delete(row_a.id, "documents", @scope, ws_a.id)
      refute Repo.get(Synonym, row_a.id)
    end
  end
end
