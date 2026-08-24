defmodule Barkpark.Plugins.Github.IntakeTest do
  @moduledoc """
  Wave-3: inbound intake — births a born-dark task from a GitHub `issues.opened`
  webhook through the `Tasks.Dedup` find-or-create seam (epic D3/D4/D6).

  Exercises the five gates: event filter (`issues.opened` ONLY), `[bot]`-sender
  drop (loop cut #1, before any Content write), deterministic `gh-<num>` birth,
  idempotent re-delivery no-op, the `source="github"` mutation-event stamp
  (loop cut #2), and the best-effort backlink comment (birth-only, never fails
  intake). GitHub HTTP is stubbed via the injectable `:comment_fun` seam — no
  network, no Bypass.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.MutationEvent
  alias Barkpark.Plugins.Github.{Acknowledgement, Intake, Link, Outbox}

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  # A `comment_fun` seam that records every call as a message to the test pid
  # and returns `:ok`. Lets a test assert the backlink was (or wasn't) posted
  # without any network.
  defp recording_comment_fun do
    test_pid = self()

    fn repo, number, body, _opts ->
      send(test_pid, {:comment, repo, number, body})
      {:ok, %{"id" => 1}}
    end
  end

  # A `conflict_fun` seam that records every dead-letter attrs map to the test
  # pid and returns `{:ok, _}`. Stands in for slice-1's `Github.Conflicts.record/1`
  # so this slice's test never needs the conflicts table/module in the tree.
  defp recording_conflict_fun do
    test_pid = self()

    fn attrs ->
      send(test_pid, {:conflict, attrs})
      {:ok, %{id: 1}}
    end
  end

  # Base opts: scope + a stubbed repo + a recording comment seam.
  defp opts(scope) do
    scope
    |> Keyword.put(:dataset, @dataset)
    |> Keyword.put(:repo, "FRIKKern/barkpark")
    |> Keyword.put(:comment_fun, recording_comment_fun())
  end

  # Create a genuine (prev_doc-nil) task so a later look-alike birth is refused
  # by the real `Tasks.Dedup` seam. Parentless + text-identical → `:cross` +
  # near-identical → hard refuse. Mirrors the issue payload's title/body.
  defp seed_lookalike!(doc_id, scope) do
    {:ok, _} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => "Outsider found a bug",
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "description" => "Steps to reproduce: click the thing."
          }
        },
        @dataset,
        scope
      )
  end

  defp opened_payload(number, overrides \\ %{}) do
    issue =
      %{
        "number" => number,
        "title" => "Outsider found a bug",
        "body" => "Steps to reproduce: click the thing.",
        "user" => %{"login" => "outsider", "type" => "User"}
      }
      |> Map.merge(Map.get(overrides, "issue", %{}))

    %{
      "action" => Map.get(overrides, "action", "opened"),
      "issue" => issue,
      "sender" => Map.get(overrides, "sender", %{"login" => "outsider", "type" => "User"}),
      "repository" => Map.get(overrides, "repository", %{"full_name" => "FRIKKern/barkpark"})
    }
  end

  defp fetch_task(number, scope) do
    doc_id = "gh-#{number}"

    case Content.get_document(Content.draft_id(doc_id), "task", @dataset, scope) do
      {:ok, doc} -> doc
      _ -> nil
    end
  end

  defp task_rows(number) do
    like = "%gh-#{number}"

    Repo.all(
      from d in Barkpark.Content.Document,
        where: d.type == "task" and like(d.doc_id, ^like),
        select: d.doc_id
    )
  end

  describe "event filter (D6, issues.opened ONLY)" do
    test "ignores a non-opened action", %{scope: scope} do
      payload = opened_payload(1, %{"action" => "edited"})
      assert Intake.ingest(payload, opts(scope)) == :ignored
      assert task_rows(1) == []
      refute_receive {:comment, _, _, _}
    end

    test "ignores a closed action", %{scope: scope} do
      payload = opened_payload(2, %{"action" => "closed"})
      assert Intake.ingest(payload, opts(scope)) == :ignored
      assert task_rows(2) == []
    end

    test "ignores an opened event with no issue", %{scope: scope} do
      payload = %{"action" => "opened", "sender" => %{"type" => "User"}}
      assert Intake.ingest(payload, opts(scope)) == :ignored
    end
  end

  describe "bot drop (D4 cut #1)" do
    test "drops a Bot sender BEFORE any Content write", %{scope: scope} do
      payload = opened_payload(3, %{"sender" => %{"login" => "barkpark[bot]", "type" => "Bot"}})
      assert Intake.ingest(payload, opts(scope)) == :dropped
      # No task minted — the structural inbound loop cut.
      assert task_rows(3) == []
      refute_receive {:comment, _, _, _}
    end
  end

  describe "birth (D3/D6)" do
    test "births a born-dark task from an outsider issue", %{scope: scope} do
      assert {:ok, :born, doc} = Intake.ingest(opened_payload(10), opts(scope))

      assert doc.doc_id == Content.draft_id("gh-10")
      assert doc.title == "Outsider found a bug"

      c = doc.content
      assert c["kind"] == "task"
      assert c["lifecycle_status"] == "open"
      assert c["labels"] == ["src:github", "needs-human"]
      assert c["description"] == "Steps to reproduce: click the thing."

      assert c["github"] == %{
               "repo" => "FRIKKern/barkpark",
               "issue" => 10,
               "state" => "intake"
             }
    end

    test "never sets synced_rev / claim / worker (born, not mirrored; adoption is wave 4)",
         %{scope: scope} do
      {:ok, :born, doc} = Intake.ingest(opened_payload(11), opts(scope))

      github = Link.get(doc)
      refute Map.has_key?(github, "synced_rev")
      # Never synced at birth — the MirrorJob owns that.
      refute Link.synced?(doc)

      refute Map.has_key?(doc.content, "claim")
      refute Map.has_key?(doc.content, "worker")
      refute Map.has_key?(doc.content, "epoch")
    end

    test "leaves description ABSENT when the issue body is nil (never fabricated)",
         %{scope: scope} do
      payload = opened_payload(12, %{"issue" => %{"body" => nil}})
      {:ok, :born, doc} = Intake.ingest(payload, opts(scope))

      refute Map.has_key?(doc.content, "description")
    end

    test "reads the repo ONCE from repository.full_name at birth", %{scope: scope} do
      payload = opened_payload(13, %{"repository" => %{"full_name" => "someone/forked"}})
      {:ok, :born, doc} = Intake.ingest(payload, opts(scope))

      assert doc.content["github"]["repo"] == "someone/forked"
    end

    test "is born carrying the acknowledgement criterion, unmet and FLAGGED",
         %{scope: scope} do
      # Before this, an intake was born with NO acceptance_criteria key at all —
      # and an empty criteria list reads to every audit as fully proven, which is
      # how nine outsider reports went unanswered with nothing able to see it.
      {:ok, :born, doc} = Intake.ingest(opened_payload(14), opts(scope))

      assert [criterion] = doc.content["acceptance_criteria"]
      assert criterion["ack_gate"] == true
      assert criterion["met"] == false
      assert criterion["evidence"] == ""
      # Names a place the reader can go and check, like the disposition reason.
      assert criterion["criterion"] =~ "FRIKKern/barkpark#14"
      refute Acknowledgement.acknowledged?(doc.content)
    end

    test "the birth criterion names the repo the issue actually lives in",
         %{scope: scope} do
      payload = opened_payload(15, %{"repository" => %{"full_name" => "someone/forked"}})
      {:ok, :born, doc} = Intake.ingest(payload, opts(scope))

      assert doc.content["acceptance_criteria"] |> hd() |> Map.get("criterion") =~
               "someone/forked#15"
    end
  end

  describe "loop cut #2 — source=\"github\" stamp" do
    test "stamps the mutation_event source exactly \"github\" (excluded by the outbox)",
         %{scope: scope} do
      {:ok, :born, doc} = Intake.ingest(opened_payload(20), opts(scope))

      events =
        Repo.all(
          from e in MutationEvent,
            where: e.doc_id == ^doc.doc_id,
            order_by: e.id
        )

      assert events != []
      assert Enum.all?(events, &(&1.source == "github"))
      # NEVER a namespaced "github:inbound" — that would slip the outbox exclusion.
      refute Enum.any?(events, &(&1.source == "github:inbound"))

      # The outbox reader excludes source="github", so an inbound birth never
      # echoes back OUTBOUND (D4 cut #2).
      outbox_rows = Outbox.fetch(@dataset, 0, 1000)
      refute Enum.any?(outbox_rows, &(&1.doc_id == doc.doc_id))
    end
  end

  describe "re-delivery (idempotent, D6)" do
    test "a second delivery is a no-op — one task, comment posted once", %{scope: scope} do
      o = opts(scope)

      assert {:ok, :born, _} = Intake.ingest(opened_payload(30), o)
      assert_receive {:comment, "FRIKKern/barkpark", 30, _body}

      # Re-delivery of the SAME webhook: existing gh-30 doc → no second task.
      assert {:ok, :exists, _} = Intake.ingest(opened_payload(30), o)
      refute_receive {:comment, _, _, _}

      # Exactly one task row family for gh-30 (draft only; never published twin).
      assert length(task_rows(30)) == 1
    end

    test "re-delivery does NOT clobber a post-birth change (read ONCE at birth)",
         %{scope: scope} do
      o = opts(scope)
      assert {:ok, :born, doc} = Intake.ingest(opened_payload(31), o)
      # Drain the birth comment so the post-re-delivery refute is unambiguous.
      assert_receive {:comment, _, 31, _}

      # Simulate a wave-4-style adoption / Studio edit AFTER birth: strip
      # `needs-human`, flip lifecycle, rename. The ownership matrix says the
      # outsider issue is read ONCE at birth — a webhook re-delivery must never
      # regress these Barkpark-owned edits back to the birth attrs. The flip
      # must be a LEGAL D7 transition (open → blocked): the Writer-seam
      # transition gate (tlv) refuses a raw open → in_progress (a claim is
      # minted only by `bp task claim`), and the concern here is re-delivery
      # no-clobber, not the lifecycle value.
      adopted_content =
        doc.content
        |> Map.put("labels", ["src:github"])
        |> Map.put("lifecycle_status", "blocked")

      {:ok, _} =
        Content.upsert_document(
          "task",
          %{"doc_id" => "gh-31", "title" => "Adopted title", "content" => adopted_content},
          @dataset,
          scope
        )

      # Re-deliver the ORIGINAL opened webhook.
      assert {:ok, :exists, existing} = Intake.ingest(opened_payload(31), o)

      # The adopted state survives — no rewrite back to the birth attrs.
      assert existing.title == "Adopted title"
      assert existing.content["labels"] == ["src:github"]
      assert existing.content["lifecycle_status"] == "blocked"
      refute_receive {:comment, _, _, _}

      reloaded = fetch_task(31, scope)
      assert reloaded.title == "Adopted title"
      assert reloaded.content["labels"] == ["src:github"]
    end
  end

  describe "dedup refusal — no outsider gets silence (D6/D7)" do
    test "a look-alike issue is REFUSED: comment + dead-letter row + {:refused, id}, no task",
         %{scope: scope} do
      # An existing task the outsider issue looks like — so the Dedup seam
      # (Tasks.Dedup, through Content.Writer) refuses the birth.
      seed_lookalike!("existing-dup", scope)

      o =
        opts(scope)
        |> Keyword.put(:conflict_fun, recording_conflict_fun())

      assert {:refused, "gh-50"} = Intake.ingest(opened_payload(50), o)

      # No task born for the refused issue — every re-delivery would re-refuse,
      # so the refusal MUST be visible instead of silent.
      assert task_rows(50) == []

      # (1) a maintainer-visible comment, distinct from the birth backlink.
      assert_receive {:comment, "FRIKKern/barkpark", 50, body}
      assert body =~ "looks related to existing tracked work"
      refute body =~ "tracked internally"

      # (2) a findable dead-letter row carrying the dedup verdict.
      assert_receive {:conflict, attrs}
      assert attrs.kind == "dedup_refused"
      assert attrs.issue == 50
      assert attrs.repo == "FRIKKern/barkpark"
      assert attrs.dataset == @dataset
      # No task exists to point at — the row's doc_id is nil (the outcome
      # carries the intended gh-<num>, the row does not).
      assert attrs.doc_id == nil
      # The verdict map is surfaced verbatim (D6 — never bypassed).
      assert is_map(attrs.detail)
      assert [%{id: "existing-dup"} | _] = attrs.detail.similar
    end

    test "re-delivery of a refused issue re-surfaces (still {:refused}, still no task)",
         %{scope: scope} do
      seed_lookalike!("existing-dup-2", scope)

      o =
        opts(scope)
        |> Keyword.put(:conflict_fun, recording_conflict_fun())

      assert {:refused, "gh-51"} = Intake.ingest(opened_payload(51), o)
      assert_receive {:comment, _, 51, _}
      assert_receive {:conflict, %{kind: "dedup_refused"}}

      # Re-delivery: still refused, still no task. The slice-1 recorder DEDUPES
      # the open {repo, issue, kind} row at the DB layer (tested in slice 1);
      # the controller's 2xx keeps GitHub from redelivering on its own, so the
      # comment posts exactly once per genuine delivery.
      assert {:refused, "gh-51"} = Intake.ingest(opened_payload(51), o)
      assert task_rows(51) == []
      assert_receive {:conflict, %{kind: "dedup_refused"}}
    end

    test "the conflict recorder is best-effort — a raising recorder never crashes intake",
         %{scope: scope} do
      seed_lookalike!("existing-dup-3", scope)

      raising = fn _attrs -> raise "recorder down" end

      o =
        opts(scope)
        |> Keyword.put(:conflict_fun, raising)

      # Even though the recorder blew up, the refusal outcome + comment stand.
      assert {:refused, "gh-52"} = Intake.ingest(opened_payload(52), o)
      assert_receive {:comment, _, 52, _}
      assert task_rows(52) == []
    end

    test "a genuine (non-look-alike) birth never touches the conflict recorder",
         %{scope: scope} do
      o =
        opts(scope)
        |> Keyword.put(:conflict_fun, recording_conflict_fun())

      assert {:ok, :born, _doc} = Intake.ingest(opened_payload(53), o)
      # The dead-letter seam only fires on a dedup refusal — a normal birth
      # leaves it untouched (fail-open preserved).
      refute_receive {:conflict, _attrs}
    end
  end

  describe "lifecycle-gate refusal — deterministic vetoes do not redeliver" do
    test "a before_save-vetoed issue is logged as a clean refusal and writes nothing",
         %{scope: scope} do
      payload = opened_payload(54, %{"issue" => %{"title" => "   "}})

      log =
        capture_log(fn ->
          assert {:refused, "gh-54"} = Intake.ingest(payload, opts(scope))
        end)

      assert log =~ "github intake: lifecycle gate refused gh-54"
      assert log =~ "task title is required"
      assert task_rows(54) == []
      assert fetch_task(54, scope) == nil
      refute_receive {:comment, _, _, _}
    end

    test "positive control: a normally titled issue still births its task", %{scope: scope} do
      assert {:ok, :born, doc} = Intake.ingest(opened_payload(55), opts(scope))

      assert doc.doc_id == Content.draft_id("gh-55")
      assert fetch_task(55, scope).id == doc.id
      assert_receive {:comment, "FRIKKern/barkpark", 55, _body}
    end
  end

  describe "backlink comment (best-effort, birth-only)" do
    test "posts the tracked-internally comment on birth", %{scope: scope} do
      assert {:ok, :born, _} = Intake.ingest(opened_payload(40), opts(scope))
      assert_receive {:comment, "FRIKKern/barkpark", 40, body}
      assert body =~ "tracked internally"
    end

    test "a failing comment is swallowed — intake still succeeds", %{scope: scope} do
      failing = fn _repo, _number, _body, _opts -> {:error, :boom} end
      o = opts(scope) |> Keyword.put(:comment_fun, failing)

      assert {:ok, :born, doc} = Intake.ingest(opened_payload(41), o)
      # The task is durably born even though the comment failed.
      assert fetch_task(41, scope).doc_id == doc.doc_id
    end

    test "a RAISING comment is swallowed — intake still succeeds", %{scope: scope} do
      raising = fn _repo, _number, _body, _opts -> raise "network down" end
      o = opts(scope) |> Keyword.put(:comment_fun, raising)

      assert {:ok, :born, _doc} = Intake.ingest(opened_payload(42), o)
      assert fetch_task(42, scope) != nil
    end

    test "no comment when no repo is configured", %{scope: scope} do
      o =
        scope
        |> Keyword.put(:dataset, @dataset)
        |> Keyword.put(:repo, nil)
        |> Keyword.put(:comment_fun, recording_comment_fun())

      assert {:ok, :born, _} = Intake.ingest(opened_payload(43), o)
      refute_receive {:comment, _, _, _}
    end
  end
end
