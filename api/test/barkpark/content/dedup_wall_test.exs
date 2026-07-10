defmodule Barkpark.Content.DedupWallTest do
  @moduledoc """
  The E4 near-duplicate publish gate (authoring-excellence). Two layers:

    * PURE — `assess/3` scores a normalized doc against candidates offline, so
      the threshold/floor/exclusion logic is unit-testable with no DB.
    * DB-backed — `check/4` / `guard/4` fetch the live published corpus via the
      trgm candidate query, exercised end-to-end against real published rows,
      including the fail-open guarantee.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.{DedupWall, Document}
  alias Barkpark.Repo

  @dataset "production"

  # ── PURE assess/3 ────────────────────────────────────────────────────────────

  defp ref(id, title, tags), do: %{id: id, title: title, tags: tags}

  test "a near-identical title+tags publish is REFUSED with the incumbent id" do
    new = ref("new-rl", "Rate limiting the mutate controller", ["rate-limiting", "mutate"])
    inc = ref("old-rl", "Rate limiting the mutate controller", ["rate-limiting", "mutate"])

    assert %{refuse: [match], advise: []} = DedupWall.assess(new, [inc])
    assert match.id == "old-rl"
    assert match.sim >= 0.55
    assert match.shared >= 3
  end

  test "a gray-zone overlap is ADVISED, never refused" do
    # Enough shared tokens to clear thin-content, but partial overlap → 0.30..0.55.
    new = ref("new-a", "Webhook delivery retry backoff schedule", ["webhooks"])
    inc = ref("old-a", "Webhook delivery ordering guarantees", ["webhooks"])

    assert %{refuse: [], advise: [match]} = DedupWall.assess(new, [inc])
    assert match.id == "old-a"
    assert match.sim >= 0.30 and match.sim < 0.55
  end

  test "thin-content guard: a 1-token full match cannot REFUSE (shared < 3)" do
    # Both tokenize to a single shared token → Jaccard 1.0 but shared == 1.
    new = ref("new-thin", "Search", ["search"])
    inc = ref("old-thin", "Search", ["search"])

    assert %{refuse: [], advise: [match]} = DedupWall.assess(new, [inc])
    assert match.sim == 1.0
    assert match.shared == 1
  end

  test "an unrelated document scores below the advise floor and is ignored" do
    new = ref("new-x", "Postfix DKIM relay sidecar", ["mail"])
    inc = ref("old-x", "Studio pane layout brightness ladder", ["studio"])

    assert %{refuse: [], advise: []} = DedupWall.assess(new, [inc])
  end

  test "same-id republish never trips (incumbent with same published id excluded)" do
    new = ref("drafts.paper-x", "Rate limiting the mutate controller", ["rate-limiting"])
    inc = ref("paper-x", "Rate limiting the mutate controller", ["rate-limiting"])

    # Identical text, but the candidate IS the incumbent (drafts. prefix stripped
    # on both) → excluded, so no refuse.
    assert %{refuse: [], advise: []} = DedupWall.assess(new, [inc])
  end

  test "tags carry the weighted-tag shape and still yield tag-name tokens" do
    weighted = [
      %{"tag" => "rate-limiting", "strength" => 80},
      %{"tag" => "mutate", "strength" => 40}
    ]

    new = ref("new-w", "Throttle writes", weighted)
    inc = ref("old-w", "Throttle writes", weighted)

    assert %{refuse: [match], advise: []} = DedupWall.assess(new, [inc])
    assert match.shared >= 3
  end

  test "refuse list is sorted by descending similarity" do
    new = ref("new-s", "Rate limiting the mutate controller endpoint", ["rate-limiting"])
    close = ref("close", "Rate limiting the mutate controller endpoint", ["rate-limiting"])
    looser = ref("looser", "Rate limiting the mutate controller", ["rate-limiting"])

    assert %{refuse: refuses} = DedupWall.assess(new, [looser, close])
    sims = Enum.map(refuses, & &1.sim)
    assert sims == Enum.sort(sims, :desc)
  end

  # ── DB-backed check/4 + guard/4 ──────────────────────────────────────────────

  defp publish_paper!(doc_id, title, tag_names) do
    tags = Enum.map(tag_names, fn n -> %{"tag" => n, "strength" => 50, "rationale" => "r"} end)

    %Document{}
    |> Document.changeset(%{
      "doc_id" => doc_id,
      "type" => "paper",
      "dataset" => @dataset,
      "title" => title,
      "status" => "published",
      "content" => %{"tags" => tags},
      "rev" => "rev-#{doc_id}"
    })
    |> Repo.insert!()
  end

  test "check/4 refuses a publish that near-duplicates a published paper" do
    publish_paper!("live-rl", "Rate limiting the mutate controller", ["rate-limiting", "mutate"])

    incoming = %{
      doc_id: "drafts.new-rl",
      title: "Rate limiting the mutate controller",
      content: %{"tags" => [%{"tag" => "rate-limiting"}, %{"tag" => "mutate"}]}
    }

    assert {:error, {:duplicate_of, payload}} = DedupWall.check(incoming, "paper", @dataset)
    assert payload.duplicate_of == "live-rl"
    assert [%{id: "live-rl"} | _] = payload.similar
  end

  test "guard/4 maps a refuse to the {:duplicate_of, _} error and passes otherwise" do
    publish_paper!("live-wh", "Webhook delivery retry backoff and ordering", ["webhooks"])

    dup = %{
      doc_id: "drafts.new-wh",
      title: "Webhook delivery retry backoff and ordering",
      content: %{"tags" => [%{"tag" => "webhooks"}]}
    }

    assert {:error, {:duplicate_of, _}} = DedupWall.guard(dup, "paper", @dataset)

    fresh = %{
      doc_id: "drafts.fresh",
      title: "Postfix DKIM mail relay sidecar container",
      content: %{"tags" => [%{"tag" => "mail"}]}
    }

    assert :ok = DedupWall.guard(fresh, "paper", @dataset)
  end

  test "check/4 advises (does not block) on a gray-zone match" do
    publish_paper!("live-order", "Webhook delivery ordering guarantees", ["webhooks"])

    incoming = %{
      doc_id: "drafts.new-order",
      title: "Webhook delivery retry backoff schedule",
      content: %{"tags" => [%{"tag" => "webhooks"}]}
    }

    assert {:ok, warnings} = DedupWall.check(incoming, "paper", @dataset)
    warning = Enum.find(warnings, &(&1.message =~ "live-order"))
    assert warning, "expected an advisory warning naming the gray-zone incumbent"
    assert warning.code == "possible_duplicate"
    assert warning.severity == "warning"
  end

  test "same-id republish against its own published row never trips" do
    publish_paper!("solo", "Rate limiting the mutate controller", ["rate-limiting", "mutate"])

    # Republishing the SAME id — identical text — must not flag itself.
    incoming = %{
      doc_id: "drafts.solo",
      title: "Rate limiting the mutate controller",
      content: %{"tags" => [%{"tag" => "rate-limiting"}, %{"tag" => "mutate"}]}
    }

    assert :ok = DedupWall.guard(incoming, "paper", @dataset)
  end

  test "a different type never matches (candidate query is type-scoped)" do
    publish_paper!("live-typed", "Rate limiting the mutate controller", [
      "rate-limiting",
      "mutate"
    ])

    incoming = %{
      doc_id: "drafts.post-rl",
      title: "Rate limiting the mutate controller",
      content: %{"tags" => [%{"tag" => "rate-limiting"}, %{"tag" => "mutate"}]}
    }

    # Same text but published under "post" → the "paper" row is not a candidate.
    assert :ok = DedupWall.guard(incoming, "post", @dataset)
  end

  test "the wall is type-agnostic: a task-type near-duplicate also 409s (title signal)" do
    # Tasks carry `labels`, not weighted `tags`, so a task scores on its TITLE
    # alone — the generic wall still catches a near-identical task publish.
    %Document{}
    |> Document.changeset(%{
      "doc_id" => "task-live",
      "type" => "task",
      "dataset" => @dataset,
      "title" => "Backfill main_tag on published documents btree index",
      "status" => "published",
      "content" => %{},
      "rev" => "rev-task-live"
    })
    |> Repo.insert!()

    incoming = %{
      doc_id: "drafts.task-new",
      title: "Backfill main_tag on published documents btree index",
      content: %{}
    }

    assert {:error, {:duplicate_of, payload}} = DedupWall.check(incoming, "task", @dataset)
    assert payload.duplicate_of == "task-live"
  end

  test "a document with no textual signal passes without a query" do
    incoming = %{doc_id: "drafts.blank", title: "", content: %{"tags" => []}}
    assert :ok = DedupWall.check(incoming, "paper", @dataset)
  end

  test "fail-open: a candidate-fetch error never blocks publish" do
    # A bogus dataset filter type would raise in the query; the rescue turns any
    # fetch failure into an empty candidate set → :ok. Force the failure by
    # passing a non-binary dataset that the trgm fragment cannot bind.
    incoming = %{
      doc_id: "drafts.fo",
      title: "Rate limiting the mutate controller",
      content: %{"tags" => [%{"tag" => "rate-limiting"}, %{"tag" => "mutate"}]}
    }

    # An integer dataset makes `d.dataset == ^dataset` (string column) raise at
    # query build/exec; the fail-open rescue must swallow it and return :ok.
    assert :ok = DedupWall.check(incoming, "paper", 12_345)
  end
end
