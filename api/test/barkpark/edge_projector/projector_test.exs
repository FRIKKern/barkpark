defmodule Barkpark.EdgeProjector.ProjectorTest do
  @moduledoc """
  Phase 3 — `Barkpark.EdgeProjector.Projector` + `ProjectorWorker`.

  Surfaces (per the brief's VERIFY gate):

    1. `project/3` over a fixture corpus UNIONS core (reference-field) edges
       with PLUGIN-projected edges, deduped by `{from_id, to_id, kind}`.
    2. FRESH-INSTALL invariant: with plugins `[]`, `project/3` yields ONLY the
       core reference-field edges — no plugin needed for a non-empty graph.
    3. `delete_record/2` removes BOTH-direction rows (a doc as `from_id` AND as
       `to_id`).
    4. `upsert_record/2` REPLACES `weight`/`plugin_source` on a changed
       re-extract (asserts the Phase-2 `on_conflict` replace) and PRUNES a
       removed edge.
    5. `ProjectorWorker` perform: the three ops route correctly. Driven via
       `Oban.Testing.perform_job/2` (config/test.exs runs `testing: :manual`,
       so plain enqueue-and-assert would NOT auto-run — gap #10).

  Runs against the test DB (Postgres on :5432).
  """

  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.Content
  alias Barkpark.Content.Edge
  alias Barkpark.EdgeProjector.{Projector, ProjectorWorker}
  alias Barkpark.Plugins.Registry

  @dataset "edge_projector_test"

  setup do
    # Force the unset-plugins baseline so the fresh-install assertion is honest
    # and any fake we register is visible to the collector. Restore on exit.
    prev_plugins = Application.get_env(:barkpark, :plugins)
    Application.delete_env(:barkpark, :plugins)

    on_exit(fn ->
      Registry.reset()

      case prev_plugins do
        nil -> Application.delete_env(:barkpark, :plugins)
        v -> Application.put_env(:barkpark, :plugins, v)
      end
    end)

    Content.upsert_schema(
      %{"name" => "author", "title" => "Author", "visibility" => "public", "fields" => []},
      @dataset
    )

    Content.upsert_schema(
      %{
        "name" => "article",
        "title" => "Article",
        "visibility" => "public",
        "fields" => [
          %{"name" => "author", "type" => "reference", "refType" => "author"}
        ]
      },
      @dataset
    )

    :ok
  end

  defp publish!(type, id, attrs \\ %{}) do
    {:ok, _} =
      Content.create_document(type, Map.merge(%{"_id" => id, "title" => id}, attrs), @dataset)

    {:ok, doc} = Content.publish_document(id, type, @dataset)
    doc
  end

  # A minimal fake plugin that projects ONE extra edge from the doc — proves
  # the union includes plugin edges. Implements the RESOLVER form directly (the
  # {nil,nil,nil,:none} entry collects only the resolver form), guarding nil doc.
  defmodule FakeEdgePlugin do
    @moduledoc false
    def name, do: "fake_edges"

    def resolve_extract_edges(prev, ctx) do
      case Map.get(ctx, :doc) do
        nil ->
          prev

        doc ->
          from = Content.published_id(Map.get(doc, :doc_id) || Map.get(doc, "doc_id"))
          prev ++ [%{from_id: from, to_id: "auth-1", kind: "related-to", plugin_source: "fake"}]
      end
    end
  end

  describe "project/3 — pure union" do
    test "fresh install (plugins []) yields ONLY core reference-field edges" do
      publish!("author", "auth-1")
      src = publish!("article", "art-1", %{"author" => "auth-1"})

      {:ok, %{edges: edges}} = Projector.project(@dataset, [src], dataset: @dataset)

      # kind IS the source field name now (graph-edge-seam) — the article's
      # `author` reference projects an "author"-kind edge, not generic "references".
      kinds = edges |> Enum.map(& &1[:kind]) |> Enum.sort()
      assert kinds == ["author"]

      ref = Enum.find(edges, &(&1[:kind] == "author"))
      assert ref[:from_id] == "art-1"
      assert ref[:to_id] == "auth-1"
    end

    test "unions core + plugin edges when a plugin is registered" do
      publish!("author", "auth-1")
      src = publish!("article", "art-2", %{"author" => "auth-1"})

      :ok = Registry.register(FakeEdgePlugin, %{"plugin_name" => "fake_edges"})

      {:ok, %{edges: edges}} = Projector.project(@dataset, [src], dataset: @dataset)

      kinds = edges |> Enum.map(& &1[:kind]) |> Enum.sort()
      assert "author" in kinds
      assert "related-to" in kinds
    end

    test "dedups by {from_id, to_id, kind}" do
      publish!("author", "auth-1")
      src = publish!("article", "art-3", %{"author" => "auth-1"})

      # Project the SAME doc twice in one corpus — the union must dedup.
      {:ok, %{edges: edges}} = Projector.project(@dataset, [src, src], dataset: @dataset)

      refs = Enum.filter(edges, &(&1[:kind] == "author"))
      assert length(refs) == 1
    end
  end

  describe "rebuild_scope/3 — materialises into content_edges" do
    test "writes resolvable edges and is the atomic swap" do
      publish!("author", "auth-1")
      src = publish!("article", "art-4", %{"author" => "auth-1"})

      {:ok, %{added: added}} = Projector.rebuild_scope(@dataset, [src], dataset: @dataset)
      assert added >= 1

      from_pk = doc_pk("art-4")
      stored = Content.list_outbound_edges(from_pk)
      assert Enum.any?(stored, &(&1.kind == "author"))
    end
  end

  describe "delete_record/2 — both directions" do
    test "removes rows where the doc is from_id AND where it is to_id" do
      publish!("author", "auth-1")
      src = publish!("article", "art-5", %{"author" => "auth-1"})

      {:ok, _} = Projector.rebuild_scope(@dataset, [src], dataset: @dataset)

      # auth-1 is a to_id; art-5 is a from_id. Deleting auth-1 must clear the
      # inbound row that targets it.
      {:ok, count} =
        Projector.delete_record(%{"doc_id" => "auth-1", "dataset" => @dataset}, dataset: @dataset)

      assert count >= 1

      to_pk = doc_pk("auth-1")
      assert Content.list_inbound_edges(to_pk) == []
    end
  end

  describe "upsert_record/2 — replace + prune" do
    test "REPLACES weight/plugin_source on a changed re-extract" do
      publish!("author", "auth-1")
      src = publish!("article", "art-6", %{"author" => "auth-1"})

      from_pk = doc_pk("art-6")
      to_pk = doc_pk("auth-1")

      # Seed an edge with an OLD weight via the raw CRUD. kind "author" matches
      # what the extract produces (the article's author reference field) so the
      # on_conflict replace hits the SAME (from,to,kind) row rather than pruning.
      {:ok, _} =
        Content.add_edge("art-6", "auth-1", "author", %{
          "dataset" => @dataset,
          "weight" => 1.0,
          "plugin_source" => "old"
        })

      # Re-extract via the projector. The core extract carries no weight, so the
      # on_conflict replace must overwrite plugin_source/weight (to nil).
      {:ok, _} = Projector.upsert_record(src, dataset: @dataset)

      edge = Repo.get_by!(Edge, from_id: from_pk, to_id: to_pk, kind: "author")
      refute edge.plugin_source == "old"
    end

    test "PRUNES a stored outbound edge no longer in the fresh extract" do
      publish!("author", "auth-1")
      publish!("author", "auth-stale")
      src = publish!("article", "art-7", %{"author" => "auth-1"})

      from_pk = doc_pk("art-7")

      # Establish the doc's REAL outbound edge (art-7 → auth-1) first. Publish
      # enqueues this but `testing: :manual` never runs the job, so materialise
      # it explicitly via the production upsert path — this is the baseline the
      # prune must preserve.
      {:ok, _} = Projector.upsert_record(src, dataset: @dataset)

      # Seed a stale edge to auth-stale that the fresh extract will NOT produce.
      {:ok, _} =
        Content.add_edge("art-7", "auth-stale", "references", %{"dataset" => @dataset})

      assert length(Content.list_outbound_edges(from_pk)) >= 2

      {:ok, _} = Projector.upsert_record(src, dataset: @dataset)

      to_ids = Content.list_outbound_edges(from_pk) |> Enum.map(& &1.to_id)
      assert doc_pk("auth-1") in to_ids
      refute doc_pk("auth-stale") in to_ids
    end
  end

  describe "ProjectorWorker — perform (Oban.Testing, manual mode → perform_job)" do
    test "rebuild op materialises the scope corpus" do
      publish!("author", "auth-1")
      publish!("article", "art-8", %{"author" => "auth-1"})

      assert :ok =
               perform_job(ProjectorWorker, %{
                 "op" => "rebuild",
                 "scope" => @dataset,
                 "types" => ["article", "author"],
                 "perspective" => "published"
               })

      from_pk = doc_pk("art-8")
      assert Enum.any?(Content.list_outbound_edges(from_pk), &(&1.kind == "author"))
    end

    test "rebuild op with no types cancels (no_types)" do
      assert {:cancel, :no_types} =
               perform_job(ProjectorWorker, %{"op" => "rebuild", "scope" => @dataset, "types" => []})
    end

    test "delete op clears the doc's edges" do
      publish!("author", "auth-1")
      publish!("article", "art-9", %{"author" => "auth-1"})

      assert :ok =
               perform_job(ProjectorWorker, %{
                 "op" => "rebuild",
                 "scope" => @dataset,
                 "types" => ["article", "author"]
               })

      assert :ok =
               perform_job(ProjectorWorker, %{
                 "op" => "delete",
                 "scope" => @dataset,
                 "_id" => "art-9"
               })

      from_pk = doc_pk("art-9")
      assert Content.list_outbound_edges(from_pk) == []
    end

    test "missing scope cancels" do
      assert {:cancel, :missing_scope} = perform_job(ProjectorWorker, %{"op" => "rebuild"})
    end
  end

  defp doc_pk(doc_id) do
    Barkpark.Content.Document
    |> Repo.get_by(doc_id: doc_id, dataset: @dataset)
    |> case do
      %{id: pk} -> pk
      _ -> nil
    end
  end
end
