defmodule Barkpark.Tasks.SimilarityTest do
  use ExUnit.Case, async: true

  alias Barkpark.Tasks.Similarity

  defp task(id, title, opts \\ []) do
    %{
      id: id,
      title: title,
      description: Keyword.get(opts, :desc, ""),
      labels: Keyword.get(opts, :labels, []),
      parent: Keyword.get(opts, :parent, ""),
      lifecycle: Keyword.get(opts, :lifecycle, "open")
    }
  end

  describe "similarity/2" do
    test "identical text scores high, disjoint text scores ~0" do
      a = task("a", "build the token emitter gate")
      b = task("b", "build the token emitter gate")
      assert Similarity.similarity(a, b) > 0.6

      c = task("c", "render markdown headings in the article reader")
      assert Similarity.similarity(a, c) < 0.15
    end

    test "labels contribute a weighted share" do
      a = task("a", "alpha beta gamma", labels: ["proj:x", "phase:1"])
      b = task("b", "delta epsilon zeta", labels: ["proj:x", "phase:1"])
      # disjoint titles, identical labels → 0.3 * 1.0
      assert_in_delta Similarity.similarity(a, b), 0.3, 0.0001
    end

    test "short tokens and stopwords are ignored" do
      a = task("a", "the a to of in on")
      b = task("b", "the a to of in on")
      # everything is a stopword/short → empty token sets → 0
      assert Similarity.similarity(a, b) == 0.0
    end
  end

  # ── cost: the new task is tokenized ONCE per assess/3 ──────────────────────
  #
  # This is the perf gate for the dedup outage of 2026-07-30. It counts WORK,
  # not wall clock: `tokens/1` emits a telemetry event per call, so N candidates
  # must produce exactly N + 1 tokenizations (N candidates + 1 probe). The
  # pre-fix code recomputed `tokens(new_task)` inside the per-candidate loop and
  # produced 2N — this test reds on it (10 ≠ 6 at N = 5).
  # Telemetry handlers are global and run in the EMITTING process, so the
  # handler counts only events raised by this very test process — a concurrent
  # async test that also tokenizes cannot inflate the count.
  defp attach_tokenize_counter do
    me = self()
    handler = "tokenize-count-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:barkpark, :tasks, :similarity, :tokenize],
      fn _event, measurements, _meta, _cfg ->
        if self() == me, do: send(me, {:tokenize, measurements})
      end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp count_tokenizations do
    receive do
      {:tokenize, _} -> 1 + count_tokenizations()
    after
      0 -> 0
    end
  end

  describe "assess/3 tokenization cost" do
    setup do: attach_tokenize_counter()

    test "tokenizes the new task once per call, not once per candidate" do
      candidates =
        for i <- 1..5 do
          task("c#{i}", "candidate #{i} title words", desc: "some description body #{i}")
        end

      new_task =
        task("new", "brand new task title words",
          desc: String.duplicate("a long description with plenty of distinct vocabulary ", 20)
        )

      Similarity.assess(new_task, candidates)

      assert count_tokenizations() == 6,
             "expected 5 candidate tokenizations + 1 probe; a per-candidate re-tokenization of " <>
               "the new task would give 10"
    end

    test "the count scales with candidates only — +1 candidate is +1 tokenization" do
      new_task = task("new", "brand new task title words", desc: "with a description")

      Similarity.assess(new_task, [task("c1", "one")])
      one = count_tokenizations()

      Similarity.assess(new_task, [task("c1", "one"), task("c2", "two")])
      two = count_tokenizations()

      assert one == 2
      assert two == 3
    end
  end

  describe "structural_relation/3" do
    test "same parent → :sibling" do
      a = task("au-w5-a", "author blocks", parent: "aesthetic-epic")
      b = task("au-w5-b", "author styleguide", parent: "aesthetic-epic")
      assert Similarity.structural_relation(a, b, %{}) == :sibling
    end

    test "milestone ⊇ step → :chain, with drafts. prefix normalized" do
      # child's parent references the PUBLISHED id `pdd-m1`; the child's own id
      # carries the drafts. prefix. Must still detect the chain.
      idx =
        Similarity.build_parent_index([
          task("drafts.pdd-m1", "M1 milestone", parent: "pd-doctrine"),
          task("drafts.pdd-t1", "the step", parent: "pdd-m1")
        ])

      m1 = task("drafts.pdd-m1", "M1 milestone", parent: "pd-doctrine")
      t1 = task("drafts.pdd-t1", "the step", parent: "pdd-m1")
      assert Similarity.structural_relation(m1, t1, idx) == :chain
    end

    test "different parents, no shared ancestor → :cross" do
      a = task("a", "x", parent: "epic-1")
      b = task("b", "y", parent: "epic-2")
      idx = Similarity.build_parent_index([a, b])
      assert Similarity.structural_relation(a, b, idx) == :cross
    end

    test "shared ancestor → :chain" do
      idx =
        Similarity.build_parent_index([
          task("root", "root", parent: ""),
          task("mid-1", "m1", parent: "root"),
          task("leaf-a", "a", parent: "mid-1"),
          task("leaf-b", "b", parent: "root")
        ])

      a = task("leaf-a", "a", parent: "mid-1")
      b = task("leaf-b", "b", parent: "root")
      # leaf-a's ancestors {mid-1, root}; leaf-b's {root} → share root
      assert Similarity.structural_relation(a, b, idx) == :chain
    end
  end

  describe "assess/3" do
    test "same-parent siblings are EXCLUDED even when lexically near-identical" do
      # The calibration case: two epic slices that sound almost the same.
      new =
        task("au-w5-view", "author component blocks in the studio editor",
          desc: "node-views and insert menu for the component block family",
          parent: "aesthetic-epic"
        )

      cand =
        task("au-w5-gallery", "author component blocks styleguide gallery",
          desc: "a gallery page rendering every component block family member",
          parent: "aesthetic-epic"
        )

      out = Similarity.assess(new, [cand])
      assert out.refuse == []
      assert out.advise == []
      assert [%{id: "au-w5-gallery", structural: :sibling, verdict: :excluded}] = out.excluded
    end

    test "a genuine cross-epic near-duplicate is REFUSED" do
      new =
        task("new-dup", "add rate limiting to the mutate controller",
          desc: "throttle writes on the REST mutate endpoint per token",
          parent: "epic-a"
        )

      cand =
        task("old-dup", "add rate limiting to the mutate controller",
          desc: "throttle writes on the REST mutate endpoint per token",
          parent: "epic-b"
        )

      out = Similarity.assess(new, [cand])
      assert [%{id: "old-dup", verdict: :refuse, structural: :cross}] = out.refuse
    end

    test "a cross match between the advise and refuse floors is ADVISE, not refuse" do
      # Partial token overlap → a mid-range similarity. Thresholds set explicitly
      # so the test exercises the bucket boundary deterministically, independent
      # of the exact score.
      new = task("new", "alpha beta gamma delta", parent: "epic-a")
      cand = task("old", "alpha beta epsilon zeta", parent: "epic-b")

      sim = Similarity.similarity(new, cand)
      assert sim > 0.0 and sim < 0.55

      out = Similarity.assess(new, [cand], advise: sim - 0.01, refuse: sim + 0.01)
      assert out.refuse == []
      assert [%{id: "old", verdict: :advise, structural: :cross}] = out.advise
    end

    test "distinct_from moves a would-be match to excluded (the rejection trail)" do
      new =
        task("new-dup", "add rate limiting to the mutate controller",
          desc: "throttle writes on the REST mutate endpoint per token",
          parent: "epic-a"
        )

      cand =
        task("old-dup", "add rate limiting to the mutate controller",
          desc: "throttle writes on the REST mutate endpoint per token",
          parent: "epic-b"
        )

      out = Similarity.assess(new, [cand], distinct_from: ["old-dup"])
      assert out.refuse == []
      assert [%{id: "old-dup", verdict: :excluded}] = out.excluded
    end

    test "distinct_from normalizes the drafts. prefix" do
      new =
        task("new-dup", "same same same words here now",
          desc: "identical body text identical body text",
          parent: "epic-a"
        )

      cand =
        task("drafts.old-dup", "same same same words here now",
          desc: "identical body text identical body text",
          parent: "epic-b"
        )

      # Author passes the published id; candidate carries the draft prefix.
      out = Similarity.assess(new, [cand], distinct_from: ["old-dup"])
      assert out.refuse == []
      assert [%{verdict: :excluded}] = out.excluded
    end

    test "thin content (one shared token) is ADVISE, never refuse" do
      # "multi-a" / "multi-b" share only the token "multi" → Jaccard 1.0 → high
      # sim, but a single shared token is not evidence of duplication.
      a = task("multi-a", "multi-a", parent: "e1")
      b = task("multi-b", "multi-b", parent: "e2")

      out = Similarity.assess(a, [b])
      assert out.refuse == []
      assert [%{id: "multi-b", verdict: :advise}] = out.advise
    end

    test "a task never matches itself" do
      t = task("self", "some words", desc: "more words", parent: "e")
      assert Similarity.assess(t, [t]) == %{refuse: [], advise: [], excluded: []}
    end

    test "results are sorted by descending similarity" do
      new = task("n", "alpha beta gamma delta epsilon", parent: "e1")
      near = task("near", "alpha beta gamma delta zeta", parent: "e2")
      far = task("far", "alpha nothing else common", parent: "e3")

      out = Similarity.assess(new, [near, far], advise: 0.05, refuse: 0.95)
      ids = Enum.map(out.advise, & &1.id)
      assert ids == Enum.sort_by(out.advise, & &1.sim, :desc) |> Enum.map(& &1.id)
      assert hd(ids) == "near"
    end
  end
end
