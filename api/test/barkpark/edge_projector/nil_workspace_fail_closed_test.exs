defmodule Barkpark.EdgeProjector.NilWorkspaceFailClosedTest do
  @moduledoc """
  Goal ges/graph-edge-seam, FIX 3 — the projection WRITE path must FAIL CLOSED
  on a missing workspace in a multi-tenant install, mirroring
  `Scope.scope_to_workspace/3`'s nil-fails-closed posture.

  The leak guarded here: two workspaces share a dataset STRING (e.g.
  "production") and a colliding slug. Under the old `scope_to_workspace_or_global`
  resolution a nil-workspace edge endpoint resolved GLOBALLY — `from_id` could
  resolve to tenant A's `documents.id` and `to_id` (same slug) to a DIFFERENT
  tenant's `documents.id`, durably storing a cross-tenant `content_edges` row
  that `Graph.traverse` then walks, leaking the other tenant's doc.

  With `require_workspace: true` (set by the multi-tenant projector) a
  nil-workspace endpoint resolves to NOTHING (strict `scope_to_workspace/3`,
  `where: false`), so `add_edge/4` returns `{:error, :no_target}` and NO row
  is written.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Edge
  alias Barkpark.EdgeProjector.Projector
  alias Barkpark.{Repo, TenancyFixtures}

  import Ecto.Query

  # Same dataset STRING across both workspaces — isolation MUST come from
  # workspace_id, not the dataset leaf (mirrors TenancyFixtures' shared dataset).
  @dataset "production"

  setup do
    Content.upsert_schema(
      %{
        "name" => "post",
        "title" => "Post",
        "visibility" => "public",
        "fields" => [%{"name" => "ref", "type" => "reference", "refType" => "post"}]
      },
      @dataset
    )

    ws_a = TenancyFixtures.create_workspace!("tenant-a")
    proj_a = TenancyFixtures.create_project!(ws_a)
    ws_b = TenancyFixtures.create_workspace!("tenant-b")
    proj_b = TenancyFixtures.create_project!(ws_b)

    scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]
    scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

    # SAME slug "collide" in BOTH tenants — the colliding-slug vector.
    {:ok, a_from} = mk("a-root", scope_a)
    {:ok, a_target} = mk("collide", scope_a)
    {:ok, b_collide} = mk("collide", scope_b)
    # A second B doc so B's "collide" can own a REAL outbound content_edges row
    # the projector-level test below proves a tenant-A rebuild must not delete.
    {:ok, b_other} = mk("b-other", scope_b)

    %{
      scope_a: scope_a,
      scope_b: scope_b,
      a_from: a_from,
      a_target: a_target,
      b_collide: b_collide,
      b_other: b_other,
      ws_a: ws_a,
      ws_b: ws_b
    }
  end

  defp mk(slug, scope) do
    Content.create_document(
      "post",
      %{"doc_id" => slug, "title" => slug, "content" => %{}},
      @dataset,
      scope
    )
  end

  defp edge_count_between(from_pk, to_pk) do
    Repo.aggregate(
      from(e in Edge, where: e.from_id == ^from_pk and e.to_id == ^to_pk),
      :count,
      :id
    )
  end

  test "require_workspace + nil workspace REFUSES a cross-tenant slug resolution", ctx do
    # Project A's edge with NO workspace_id but the fail-closed flag on. The
    # slug "collide" exists in BOTH tenants; the resolver must not pick either.
    result =
      Content.add_edge("a-root", "collide", "references", %{
        "dataset" => @dataset,
        "require_workspace" => true
      })

    assert result == {:error, :no_target},
           "fail-closed: a nil-workspace endpoint must NOT resolve across tenants, got #{inspect(result)}"

    # And nothing was written between A's root and EITHER "collide" row.
    assert edge_count_between(ctx.a_from.id, ctx.a_target.id) == 0
  end

  test "the SAME edge resolves WITHIN-workspace when the workspace is supplied", ctx do
    # Positive control: with A's workspace in hand the within-workspace scope
    # resolves both endpoints to A's rows and the edge is stored.
    result =
      Content.add_edge("a-root", "collide", "references", %{
        "dataset" => @dataset,
        "require_workspace" => true,
        "workspace_id" => ctx.ws_a.id
      })

    assert {:ok, %Edge{from_id: from_pk, to_id: to_pk}} = result
    assert from_pk == ctx.a_from.id
    assert to_pk == ctx.a_target.id
    assert edge_count_between(ctx.a_from.id, ctx.a_target.id) == 1
  end

  test "no stored content_edges row spans the two tenants after a fail-closed projection", _ctx do
    _ =
      Content.add_edges(
        [%{from_id: "a-root", to_id: "collide", kind: "references", dataset: @dataset}],
        dataset: @dataset,
        require_workspace: true
      )

    # Every content_edges row's endpoints must belong to the SAME workspace —
    # no row may join A's documents to B's documents.
    cross =
      Repo.all(
        from e in Edge,
          join: f in Barkpark.Content.Document,
          on: f.id == e.from_id,
          join: t in Barkpark.Content.Document,
          on: t.id == e.to_id,
          where: f.workspace_id != t.workspace_id,
          select: {f.workspace_id, t.workspace_id}
      )

    assert cross == [],
           "CROSS-TENANT EDGE: content_edges rows span two workspaces: #{inspect(cross)}"
  end

  # ── Projector DELETE/prune side fails closed (FIX 3, doc_pk workspace scope) ──
  #
  # The add_edge tests above prove the WRITE (resolve) side. These prove the
  # DELETE/prune side: Projector.rebuild_scope and upsert_record resolve the
  # corpus's PKs via Projector.doc_pk/2, then DELETE the outbound edges of those
  # PKs. If doc_pk ignored the workspace, a tenant-A rebuild over a corpus that
  # includes the slug "collide" would resolve B's colliding-slug PK and delete
  # B's outbound content_edges row (cross-tenant data destruction). With the
  # workspace threaded + require_workspace, A's corpus resolves ONLY A's rows.

  defp seed_b_outbound_edge(ctx) do
    {:ok, %Edge{} = edge} =
      Content.add_edge("collide", "b-other", "references", %{
        "dataset" => @dataset,
        "require_workspace" => true,
        "workspace_id" => ctx.ws_b.id
      })

    # Sanity: the edge is B's collide -> B's b-other, within tenant B.
    assert edge.from_id == ctx.b_collide.id
    assert edge.to_id == ctx.b_other.id
    edge
  end

  test "rebuild_scope for tenant A does NOT delete tenant B's colliding-slug outbound edge", ctx do
    b_edge = seed_b_outbound_edge(ctx)

    # Tenant-A corpus that INCLUDES a doc with slug "collide" — the same slug B
    # owns. rebuild deletes the outbound edges of the corpus's resolved PKs.
    a_corpus = [
      %{"doc_id" => "a-root", "dataset" => @dataset},
      %{"doc_id" => "collide", "dataset" => @dataset}
    ]

    {:ok, _} =
      Projector.rebuild_scope(@dataset, a_corpus,
        dataset: @dataset,
        workspace_id: ctx.ws_a.id,
        project_id: Keyword.get(ctx.scope_a, :project_id),
        require_workspace: true
      )

    # B's outbound edge must SURVIVE — A's rebuild resolved "collide" to A's PK,
    # never B's, so delete_outbound_for never touched B's row.
    assert Repo.get(Edge, b_edge.id) != nil,
           "CROSS-TENANT DELETE: tenant-A rebuild deleted tenant-B's outbound edge"
  end

  test "upsert_record for a tenant-A doc does NOT prune tenant B's colliding-slug edges", ctx do
    b_edge = seed_b_outbound_edge(ctx)

    # Upsert A's own "collide" doc. remove_stale_outbound resolves the from_pk
    # via doc_pk/2 — it must resolve A's collide PK, so the prune is scoped to
    # A's stored edges and never reaches B's row.
    {:ok, _} =
      Projector.upsert_record(%{"doc_id" => "collide", "dataset" => @dataset},
        dataset: @dataset,
        workspace_id: ctx.ws_a.id,
        project_id: Keyword.get(ctx.scope_a, :project_id),
        require_workspace: true
      )

    assert Repo.get(Edge, b_edge.id) != nil,
           "CROSS-TENANT PRUNE: tenant-A upsert pruned tenant-B's outbound edge"
  end
end
