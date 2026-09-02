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
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.PlanPapers
  alias Barkpark.StudioChat.Recorder

  @dataset "production"

  defp paper_rows(slug) do
    Repo.all(
      from(d in Document,
        where: d.doc_id == ^slug and d.type == "paper" and d.dataset == ^@dataset
      )
    )
  end

  # EVERY plan paper in the (sandbox-isolated) dataset, not just the one at the
  # slug we expect. A duplicate written under a DIFFERENT slug is exactly the
  # failure "one Paper per approved plan" forbids, and a slug-keyed count is
  # blind to it.
  defp all_plan_paper_ids do
    Repo.all(
      from(d in Document,
        where: like(d.doc_id, "chat-plan-%") and d.type == "paper" and d.dataset == ^@dataset,
        select: d.doc_id,
        order_by: d.doc_id
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

  # ── publish_approved_plan/3 — the ONE owner of the D49 side effect ──────────
  #
  # `ct-bl-plan-paper-parity`: this used to be a Studio-LiveView-only `defp`
  # reading the socket's in-memory copy of the plan, so a plan allowed from the
  # TUI (POST /v1/chat/sessions/:id/approval) flipped the card on BOTH surfaces
  # and published NOTHING. The seam below is socket-free — it reads the plan row
  # the Recorder persisted — so every surface that can answer an ask reaches the
  # identical Paper, and every non-publishing case is a documented, silent no-op.
  describe "publish_approved_plan/3" do
    defp chat_session! do
      id = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: id, cwd: "/tmp", mode: "plan"})
      id
    end

    defp seed_ask!(sid, request_id, role, input) do
      {:ok, _} =
        StudioChat.append_message(sid, %{
          role: role,
          source_markdown: "ask",
          metadata: %{
            "request_id" => request_id,
            "tool_name" => if(role == "plan", do: "ExitPlanMode", else: "Write"),
            "input" => input,
            "approval_status" => "pending"
          }
        })

      :ok
    end

    defp await(fun, tries \\ 100) do
      cond do
        fun.() -> :ok
        tries <= 0 -> flunk("condition never became true")
        true -> Process.sleep(20) && await(fun, tries - 1)
      end
    end

    # A no-op must be provably a no-op, not merely slow: settle the supervisor,
    # then assert nothing landed.
    defp settle, do: Process.sleep(120)

    defp stamped(sid, request_id) do
      m = StudioChat.get_needs_you_message(sid, request_id)
      {m.metadata["paper_id"], m.metadata["paper_url"]}
    end

    test "an allow on a plan row publishes, stamps the SHARED row, and broadcasts" do
      sid = chat_session!()
      :ok = seed_ask!(sid, "r-ok", "plan", %{"plan" => "# Ship it\n\nDo the work."})
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))

      assert :ok == PlanPapers.publish_approved_plan(sid, "r-ok", :allow)

      slug = PlanPapers.slug_for(sid, "r-ok")
      url = "/papers/#{slug}"

      await(fn ->
        match?(%{status: "published", type: "paper"}, Content.get_paper(slug, @dataset))
      end)

      # the same plan_paper frame the Studio LiveView has always broadcast — a
      # co-viewing tab gets its "→ published as Paper" link no matter WHO allowed
      assert_receive {:plan_paper, "r-ok", %{paper_id: ^slug, paper_url: ^url}}, 2_000

      # …and the id/url persist on the shared message row (replay-durable)
      await(fn -> stamped(sid, "r-ok") == {slug, url} end)
    end

    test "a deny publishes nothing — a rejected plan stays chat ephemera" do
      sid = chat_session!()
      :ok = seed_ask!(sid, "r-deny", "plan", %{"plan" => "# Ship it\n\nDo the work."})

      assert :ok == PlanPapers.publish_approved_plan(sid, "r-deny", {:deny, "keep planning"})

      settle()
      assert Content.get_paper(PlanPapers.slug_for(sid, "r-deny"), @dataset) == nil
      assert stamped(sid, "r-deny") == {nil, nil}
    end

    test "a NON-plan needs-you row publishes nothing, even on an allow" do
      sid = chat_session!()
      :ok = seed_ask!(sid, "r-appr", "approval", %{"file_path" => "/opt/x"})
      :ok = seed_ask!(sid, "r-q", "question", %{"questions" => []})

      assert :ok == PlanPapers.publish_approved_plan(sid, "r-appr", :allow)
      assert :ok == PlanPapers.publish_approved_plan(sid, "r-q", :allow)

      settle()
      assert Content.get_paper(PlanPapers.slug_for(sid, "r-appr"), @dataset) == nil
      assert Content.get_paper(PlanPapers.slug_for(sid, "r-q"), @dataset) == nil
    end

    test "blank / whitespace-only plan markdown publishes nothing (no empty Papers)" do
      sid = chat_session!()
      :ok = seed_ask!(sid, "r-empty", "plan", %{"plan" => ""})
      :ok = seed_ask!(sid, "r-ws", "plan", %{"plan" => "   \n\t \n"})

      assert :ok == PlanPapers.publish_approved_plan(sid, "r-empty", :allow)
      assert :ok == PlanPapers.publish_approved_plan(sid, "r-ws", :allow)

      settle()
      assert Content.get_paper(PlanPapers.slug_for(sid, "r-empty"), @dataset) == nil
      assert Content.get_paper(PlanPapers.slug_for(sid, "r-ws"), @dataset) == nil
    end

    test "a provider-shaped ask with no binary input.plan publishes nothing, never crashes" do
      sid = chat_session!()
      # the transport is provider-neutral (D36): a non-claude ExitPlanMode ask may
      # carry a different input shape, or none at all. Each must degrade to "no
      # Paper", not to a MatchError inside a fire-and-forget task.
      :ok = seed_ask!(sid, "r-steps", "plan", %{"steps" => ["a", "b"]})
      :ok = seed_ask!(sid, "r-nested", "plan", %{"plan" => %{"markdown" => "# nope"}})
      :ok = seed_ask!(sid, "r-noinput", "plan", nil)

      for rid <- ~w(r-steps r-nested r-noinput) do
        assert :ok == PlanPapers.publish_approved_plan(sid, rid, :allow)
      end

      settle()

      for rid <- ~w(r-steps r-nested r-noinput) do
        assert Content.get_paper(PlanPapers.slug_for(sid, rid), @dataset) == nil,
               "#{rid} must not produce a Paper"
      end
    end

    test "an unknown request_id publishes nothing and does not raise" do
      sid = chat_session!()

      assert :ok == PlanPapers.publish_approved_plan(sid, "never-asked", :allow)

      settle()
      assert Content.get_paper(PlanPapers.slug_for(sid, "never-asked"), @dataset) == nil
    end

    test "a REPEATED allow converges on ONE Paper — no duplicate row" do
      sid = chat_session!()
      :ok = seed_ask!(sid, "r-twice", "plan", %{"plan" => "# Ship it\n\nDo the work."})
      slug = PlanPapers.slug_for(sid, "r-twice")

      :ok = PlanPapers.publish_approved_plan(sid, "r-twice", :allow)
      await(fn -> paper_rows(slug) != [] end)

      # a second allow (the double-click, the TUI answering after Studio already
      # did) hits the SAME deterministic slug — an update, never a second row
      :ok = PlanPapers.publish_approved_plan(sid, "r-twice", :allow)
      settle()

      assert all_plan_paper_ids() == [slug],
             "a repeated allow must never mint a second Paper (under any slug)"

      assert stamped(sid, "r-twice") == {slug, "/papers/#{slug}"}
    end
  end
end
