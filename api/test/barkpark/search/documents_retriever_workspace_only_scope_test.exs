defmodule Barkpark.Search.DocumentsRetrieverWorkspaceOnlyScopeTest do
  @moduledoc """
  barkpark-sknf, SEARCH side: `DocumentsRetriever.scope_to_dataset/3` must
  forward `:workspace_id` to `Content.resolve_read_dataset_id/2`, not only
  `:project_id`.

  THE DEFECT — a guard that cannot fire. `resolve_read_dataset_id/2` carries a
  hardening clause written for exactly this hazard:

      cond do
        pid = Keyword.get(opts, :project_id) -> pid
        Keyword.has_key?(opts, :workspace_id) -> nil   # <- barkpark-sknf
        true -> read_default_project_id(opts)
      end

  It keys on the PRESENCE of `:workspace_id`. The retriever built a fresh
  `[project_id: project_id]` list and never put the key in, so the middle arm
  was unreachable from this call site and a workspace-only read fell through
  to the DEFAULT project's dataset_id. The retriever's own
  `scope_to_dataset/3` is STRICT (`d.dataset_id == ^id`, no NULL-tolerant OR),
  so `where d.dataset_id == <Default's id>` ANDed with
  `where d.workspace_id == <B>` is EMPTY BY CONSTRUCTION: document search went
  fully blind for every token-derived non-Default workspace.

  Workspace-only is exactly the scope the flat routes produce.
  `DeriveWorkspaceFromToken` sets the workspace from the token and
  `AssignDefaultScope` deliberately leaves a derived non-Default workspace
  project-less, so `ScopeHelpers.scope_opts/1` emits `[workspace_id: B]` with
  no `:project_id`.

  WHY THE ASSERTIONS ARE SHAPED THIS WAY. The symptom is EMPTINESS, and a
  badly-seeded fixture is also empty — so a test asserting "no wrong rows"
  would pass vacuously here even with the bug live. Every test below therefore
  asserts a POSITIVE fact about real content (B's row IS returned), and the
  fixture asserts its own preconditions: the trap must be armed (Default owns
  a same-named dataset with a DIFFERENT id) and B's row must carry B's OWN
  non-nil `dataset_id` (a NULL would be rescued by a legacy string match and
  the test would prove nothing).
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.WriteScope
  alias Barkpark.Tenancy

  # The SAME dataset string in Default and in workspace B — the collision the
  # Default fallback needs in order to resolve a REAL but WRONG dataset_id.
  @ds "production"
  @term "quokka"

  # Default owns a `production` dataset holding a matching doc (the trap), and
  # workspace B / project B owns its own `production` dataset holding the row
  # the flat search must find. Returns a map of the ids under test.
  defp seed_default_and_workspace_b do
    {_default_ws, default_proj} = ensure_default_scope!()

    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)

    default_scope = [workspace_id: default_proj.workspace_id, project_id: default_proj.id]
    b_scope = [workspace_id: ws_b.id, project_id: proj_b.id]

    # W10 schema-visibility gate: these searches are anonymous (no
    # caller_context), so "post" needs a PUBLIC schema row in each tenant for
    # its docs to be searchable at all. The gate is NOT what is under test —
    # it resolves identically for both scopes.
    for scope <- [default_scope, b_scope] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "post", "title" => "post", "visibility" => "public"},
          @ds,
          scope
        )
    end

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "default-hit", "title" => "#{@term} from Default"},
        @ds,
        default_scope
      )

    {:ok, b_doc} =
      Content.create_document(
        "post",
        %{"doc_id" => "b-hit", "title" => "#{@term} from B"},
        @ds,
        b_scope
      )

    default_ds = Tenancy.get_dataset(default_proj.id, @ds)
    b_ds = Tenancy.get_dataset(proj_b.id, @ds)

    # --- FIXTURE PRECONDITIONS: without these the tests below are vacuous. ---

    # The trap is armed: Default really does own a same-named dataset, so the
    # Default fallback resolves a REAL id rather than nil-ing out harmlessly.
    assert %Tenancy.Dataset{} = default_ds
    assert %Tenancy.Dataset{} = b_ds

    refute default_ds.id == b_ds.id,
           "fixture is inert: Default and workspace B must own DISTINCT `#{@ds}` datasets"

    # B's row carries B's OWN non-nil dataset_id. A NULL dataset_id would be
    # rescued by a legacy `dataset` string match and the strict Default filter
    # would never be observable.
    assert b_doc.dataset_id == b_ds.id,
           "fixture is inert: B's document must carry B's own dataset_id, got #{inspect(b_doc.dataset_id)}"

    %{ws_b: ws_b, proj_b: proj_b, default_ds_id: default_ds.id, b_ds_id: b_ds.id}
  end

  defp search(opts), do: Content.search_documents(@term, @ds, [perspective: :raw] ++ opts)

  defp doc_ids({hits, _total, _facets}), do: Enum.map(hits, & &1.doc_id)
  defp total({_hits, total, _facets}), do: total

  describe "the barkpark-sknf guard on the search read path" do
    test "PRECONDITION — the guard FIRES when it is handed :workspace_id, and falls back to Default without it" do
      %{ws_b: ws_b, default_ds_id: default_ds_id, b_ds_id: b_ds_id} =
        seed_default_and_workspace_b()

      # Without the key, the resolver falls back to the DEFAULT project and
      # hands back a dataset_id belonging to a DIFFERENT tenant. This is the
      # value the retriever used to apply as a strict filter.
      assert WriteScope.resolve_read_dataset_id(@ds, project_id: nil) == default_ds_id

      # WITH the key present the guard fires and returns nil, which sends
      # scope_to_dataset down the legacy STRING path and leaves the workspace
      # filter to keep the read tenant-correct.
      assert WriteScope.resolve_read_dataset_id(@ds, project_id: nil, workspace_id: ws_b.id) ==
               nil

      # And the id it WOULD have wrongly pinned is not B's.
      refute default_ds_id == b_ds_id
    end

    test "POSITIVE CONTROL — workspace+project scope returns B's row (the query CAN return rows)" do
      %{ws_b: ws_b, proj_b: proj_b} = seed_default_and_workspace_b()

      result = search(workspace_id: ws_b.id, project_id: proj_b.id)

      assert total(result) == 1
      assert "drafts.b-hit" in doc_ids(result)
    end

    test "RED — a workspace-ONLY search (the flat token-derived scope) returns B's OWN row" do
      %{ws_b: ws_b} = seed_default_and_workspace_b()

      # This is the shape ScopeHelpers.scope_opts/1 emits for a workspace-bound
      # non-Default token: a workspace, no project.
      result = search(workspace_id: ws_b.id)

      # POSITIVE assertion on real content. Before the fix this returned
      # total=0 / [] because `d.dataset_id == <Default's id>` AND
      # `d.workspace_id == <B>` cannot both hold.
      #
      # Passing this also PROVES THE GUARD FIRED AT THE CALL SITE: B's row
      # carries B's own non-nil dataset_id (asserted in the fixture), so it is
      # reachable ONLY if the strict `dataset_id == <Default's id>` filter was
      # never applied — i.e. the resolver returned nil, i.e. it saw
      # :workspace_id.
      assert total(result) == 1,
             "document search is BLIND for a token-derived workspace: expected B's own row"

      assert "drafts.b-hit" in doc_ids(result)

      # Tenancy still holds in the other direction — but note this refute is
      # NOT the point of the test: it passes vacuously on an empty result.
      refute "drafts.default-hit" in doc_ids(result)
    end

    test "NON-REGRESSION (barkpark-y9ee) — an UNSCOPED search still resolves Default's dataset strictly" do
      %{default_ds_id: default_ds_id} = seed_default_and_workspace_b()

      # The flat back-compat caller passes NO workspace key at all.
      # ScopeHelpers.scope_opts/1 DROPS an absent assign rather than emitting
      # `workspace_id: nil`, so the guard must NOT fire here: the resolver
      # still pins Default's dataset_id. Forwarding a nil workspace_id as a
      # PRESENT key would silently break this arm.
      assert WriteScope.resolve_read_dataset_id(@ds, project_id: nil) == default_ds_id

      result = search([])

      assert total(result) == 1
      assert "drafts.default-hit" in doc_ids(result)
    end
  end
end
