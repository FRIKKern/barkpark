defmodule Barkpark.StudioChat.PlanPapersTest do
  @moduledoc """
  Charter D49 — an approved ExitPlanMode plan projected into a real, published
  Bulldocs Paper. Proved NON-VACUOUSLY against the DB:

    * `publish/3` writes a PUBLISHED `paper` row in the seeded Default workspace
      (scope-less upsert), style `article`, dataset `production`, `doc_id` == the
      deterministic slug — the SAME row `/papers/:slug` reads;
    * the slug is a pure function of `session_id <> request_id` (determinism is
      what makes a re-approve idempotent by construction);
    * re-approving the SAME plan upserts ONE row (never dups) and the second
      write UPDATES it — the plan body actually changes on the row;
    * the plan markdown lands as blocks in the paper body (it is a projection of
      the markdown, D7).
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.StudioChat.PlanPapers

  @dataset "production"

  defp paper_rows(slug) do
    Repo.all(
      from(d in Document,
        where: d.doc_id == ^slug and d.type == "paper" and d.dataset == ^@dataset
      )
    )
  end

  describe "slug_for/2 + paper_url/1 (determinism)" do
    test "the slug is a pure function of session_id <> request_id" do
      slug = PlanPapers.slug_for("sess-a", "req-1")

      # deterministic — same inputs, same slug, forever
      assert slug == PlanPapers.slug_for("sess-a", "req-1")
      # shape: chat-plan- + 12 lowercase hex
      assert slug =~ ~r/\Achat-plan-[0-9a-f]{12}\z/
    end

    test "different session OR different request_id ⇒ a different slug" do
      base = PlanPapers.slug_for("sess-a", "req-1")
      assert base != PlanPapers.slug_for("sess-b", "req-1")
      assert base != PlanPapers.slug_for("sess-a", "req-2")
    end

    test "paper_url is the /papers/:slug reader route" do
      assert PlanPapers.paper_url("chat-plan-abc") == "/papers/chat-plan-abc"
    end
  end

  describe "publish/3" do
    test "creates a PUBLISHED article paper at the deterministic slug, dataset production" do
      slug = PlanPapers.slug_for("sess-1", "req-1")

      assert {:ok, %{paper_id: ^slug, paper_url: url}} =
               PlanPapers.publish("sess-1", "req-1", "# Migrate widgets\n\nDo the thing.")

      assert url == "/papers/#{slug}"

      doc = Content.get_paper(slug, @dataset)
      assert doc != nil
      assert doc.doc_id == slug
      assert doc.type == "paper"
      assert doc.dataset == @dataset
      assert doc.status == "published"
      assert get_in(doc.content, ["style"]) == "article"
    end

    test "the plan markdown lands as blocks in the paper body (a projection, D7)" do
      slug = PlanPapers.slug_for("sess-body", "req-1")

      {:ok, _} =
        PlanPapers.publish(
          "sess-body",
          "req-1",
          "# Plan title\n\nInventory the widgets thoroughly."
        )

      doc = Content.get_paper(slug, @dataset)
      # the heading text is the derived row title, the prose is in the rendered body
      assert doc.title == "Plan title"
      assert doc.content["body_html"] =~ "Inventory the widgets thoroughly"
    end

    test "re-approving the SAME plan upserts ONE row and UPDATES it (idempotent)" do
      {:ok, %{paper_id: slug}} =
        PlanPapers.publish("sess-idem", "req-1", "# First\n\nversion one body.")

      assert length(paper_rows(slug)) == 1

      # second approve of the same (session, request) — same slug, so an UPDATE
      {:ok, %{paper_id: ^slug}} =
        PlanPapers.publish("sess-idem", "req-1", "# Second\n\nversion two body.")

      rows = paper_rows(slug)
      assert length(rows) == 1, "a re-approve must never duplicate the paper"

      doc = Content.get_paper(slug, @dataset)
      # the row actually moved to the new content — a real update, not a stale keep
      assert doc.title == "Second"
      assert doc.content["body_html"] =~ "version two body"
      refute doc.content["body_html"] =~ "version one body"
    end
  end
end
