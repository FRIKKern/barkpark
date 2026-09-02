defmodule Barkpark.Content.GraphExtractorSeamTest do
  @moduledoc """
  The INVERTED plugin edge-extractor seam behind the drafts graph.

  `Barkpark.Content.Graph` used to call
  `Barkpark.Plugins.Registry.collect_edge_extractors/1` directly — a KERNEL
  concept (`content`) reaching into a FEATURE (`registry`), the wrong-direction
  dependency `tooling/concept-map/boundary.mjs` reports. The arrow is now
  turned around: the composition root (`Barkpark.Application.start/2`) installs
  the fan-out under `:edge_extractor_collector` and the kernel only READS it.

  Two properties that indirection has to buy, or it is decoration:

    1. SUBSTITUTABILITY — a collector installed through the seam actually
       reaches the drafts graph. Anything (a plugin registry, a stub) can be
       the supplier, because the kernel names none of them.
    2. ABSENCE IS SAFE — an UNSET seam yields the CORE edges only and never
       raises. That is the fresh-install invariant: a host with no plugin layer
       still walks its drafts graph.

  `graph_test.exs` covers the other side of the same seam — that the REAL
  registry, installed at boot, still delivers the Bulldocs plugin edges.
  """

  # NOT async. The seam is one global `Application` env key; a module running
  # concurrently would observe this module's stub (or its deletion) as its own
  # configuration and the drafts assertions on both sides would go non-
  # deterministic.
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Graph

  @dataset "graph_extractor_seam_test"
  @seam_key :edge_extractor_collector

  setup do
    Content.upsert_schema(
      %{"name" => "node", "title" => "Node", "visibility" => "public", "fields" => []},
      @dataset
    )

    # A scalar reference field — the CORE extract path has something real to
    # walk, so "core edges only" is an assertion about presence, not emptiness.
    Content.upsert_schema(
      %{
        "name" => "linker",
        "title" => "Linker",
        "visibility" => "public",
        "fields" => [%{"name" => "rel", "type" => "reference", "refType" => "node"}]
      },
      @dataset
    )

    # NO core reference fields: a `paper`'s only possible edges arrive through
    # the seam, so nothing below can pass vacuously off a core edge.
    Content.upsert_schema(
      %{"name" => "paper", "title" => "Paper", "visibility" => "public", "fields" => []},
      @dataset
    )

    # The app installs the real collector at boot; restore whatever was there.
    original = Application.get_env(:barkpark, @seam_key)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:barkpark, @seam_key)
        value -> Application.put_env(:barkpark, @seam_key, value)
      end
    end)

    :ok
  end

  defp publish!(id) do
    {:ok, _} = Content.create_document("node", %{"_id" => id, "title" => id}, @dataset)
    {:ok, doc} = Content.publish_document(id, "node", @dataset)
    doc
  end

  defp draft_only!(type, id, attrs \\ %{}) do
    {:ok, doc} =
      Content.create_document(type, Map.merge(%{"_id" => id, "title" => id}, attrs), @dataset)

    doc
  end

  defp drafts_traverse(root) do
    Graph.traverse(root,
      dataset: @dataset,
      perspective: :drafts,
      root_pub_id: root,
      depth: 2,
      direction: :out
    )
  end

  defp triples(result), do: Enum.map(result.edges, fn e -> {e.from_id, e.to_id, e.kind} end)

  defp pairs(result), do: Enum.map(result.edges, fn e -> {e.from_id, e.to_id} end)

  describe "the inverted :edge_extractor_collector seam" do
    test "a collector installed through the seam contributes an edge to the drafts graph" do
      _target = draft_only!("node", "seam-target")
      src = draft_only!("paper", "seam-src")
      assert String.starts_with?(src.doc_id, "drafts.")

      test_pid = self()

      # A stand-in for `Plugins.Registry.collect_edge_extractors/1`: the SAME
      # `[baseline:, ctx:]` contract, unioning one edge of its own onto the
      # core baseline. The kernel cannot tell this from the registry — which
      # is the whole point of the inversion.
      Application.put_env(:barkpark, @seam_key, fn opts ->
        baseline = Keyword.fetch!(opts, :baseline)
        ctx = Keyword.fetch!(opts, :ctx)
        slug = Content.published_id(Map.get(ctx.doc, :doc_id))
        send(test_pid, {:seam_invoked, slug})

        if slug == "seam-src" do
          baseline ++
            [
              %{
                from_id: "seam-src",
                to_id: "seam-target",
                kind: "seam-edge",
                plugin_source: "seam_stub"
              }
            ]
        else
          baseline
        end
      end)

      result = drafts_traverse("seam-src")

      assert {"seam-src", "seam-target", "seam-edge"} in triples(result),
             "an edge from the seam-installed collector must reach the drafts graph"

      # The seam carries the plugin's provenance through, same as the registry
      # path does (published-path parity for the `:sources` filter).
      assert Enum.any?(result.edges, fn e -> e.plugin_source == "seam_stub" end)

      # The target is a member of the drafts corpus, so the edge is NOT
      # dangling and the BFS walks into it — a real node, never a phantom.
      assert "seam-target" in Enum.map(result.nodes, &Map.get(&1, :doc_id))

      # Non-vacuity: the kernel really drove the seam, and drove it with the
      # per-doc ctx the registry contract promises.
      assert_received {:seam_invoked, "seam-src"}
    end

    test "an UNSET seam yields the core edges only, and never crashes" do
      Application.delete_env(:barkpark, @seam_key)
      assert Application.get_env(:barkpark, @seam_key) == nil

      publish!("seam-core-target")
      draft_only!("linker", "seam-core-src", %{"rel" => "seam-core-target"})

      # A paper whose body holds a valueref: with the seam installed this is a
      # plugin edge, so its ABSENCE here is what proves the fold is off rather
      # than the fixture being empty.
      draft_only!("paper", "seam-unset-paper", %{
        "body" => [
          %{
            "type" => "paragraph",
            "children" => [%{"type" => "valueref", "target" => "seam-core-target"}]
          }
        ]
      })

      core = drafts_traverse("seam-core-src")

      assert {"seam-core-src", "seam-core-target"} in pairs(core),
             "the CORE reference-field edge must survive an unset seam"

      paper = drafts_traverse("seam-unset-paper")

      assert paper.edges == [],
             "with no collector installed the plugin fold contributes nothing: #{inspect(paper.edges)}"

      # No crash, and the envelope contract still holds on both walks.
      assert core.truncated == false
      assert paper.truncated == false
    end

    test "a garbage seam value degrades to core edges instead of taking the walk down" do
      Application.put_env(:barkpark, @seam_key, :not_a_collector)

      publish!("seam-bad-target")
      draft_only!("linker", "seam-bad-src", %{"rel" => "seam-bad-target"})

      result = drafts_traverse("seam-bad-src")

      assert {"seam-bad-src", "seam-bad-target"} in pairs(result)
    end
  end
end
