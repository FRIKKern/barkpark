defmodule Barkpark.Plugins.Github.AdoptTest do
  @moduledoc """
  Wave-4: adoption — an operator flips a born-dark `gh-<num>` intake task into
  Barkpark ownership (epic D5/D6/D4-cut-#2).

  Exercises the gate (only `content.github.state == "intake"` is adoptable), the
  flip (strip `needs-human`, KEEP `src:github`, set `state = "adopted"`, never
  touch claim/worker/epoch), the best-effort backlink (birth-only body, seam-
  injected — no network), the `source="github"` mutation-event stamp (loop cut
  #2), and idempotency (a second adopt is a `{:ok, doc}` no-op with no second
  backlink). A born intake is seeded through the real `Github.Intake` path so
  the shape under test is the shape wave 3 produces.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Plugins.Github.{Adopt, Intake, Link}

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

  # A `comment_fun` seam that records every call as a message to the test pid and
  # returns `:ok` — lets a test assert the backlink was (or wasn't) posted with
  # no network.
  defp recording_comment_fun do
    test_pid = self()

    fn repo, number, body, _opts ->
      send(test_pid, {:comment, repo, number, body})
      {:ok, %{"id" => 1}}
    end
  end

  defp opts(scope) do
    scope
    |> Keyword.put(:dataset, @dataset)
    |> Keyword.put(:repo, "FRIKKern/barkpark")
    |> Keyword.put(:comment_fun, recording_comment_fun())
  end

  # A silent comment seam (returns :ok, records nothing) — for the birth step
  # whose backlink we don't care about.
  defp silent_opts(scope) do
    scope
    |> Keyword.put(:dataset, @dataset)
    |> Keyword.put(:repo, "FRIKKern/barkpark")
    |> Keyword.put(:comment_fun, fn _r, _n, _b, _o -> {:ok, %{}} end)
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
      "action" => "opened",
      "issue" => issue,
      "sender" => %{"login" => "outsider", "type" => "User"},
      "repository" => %{"full_name" => "FRIKKern/barkpark"}
    }
  end

  # Birth an intake task via the real wave-3 path, then drain its birth
  # mutation-events aside so a later assertion counts only the adopt write.
  defp born_intake(number, scope) do
    {:ok, :born, doc} = Intake.ingest(opened_payload(number), silent_opts(scope))
    doc
  end

  defp fetch_draft(doc_id, scope) do
    case Content.get_document(Content.draft_id(doc_id), "task", @dataset, scope) do
      {:ok, doc} -> doc
      _ -> nil
    end
  end

  describe "the gate (D6)" do
    test "adopts a task whose github.state == intake", %{scope: scope} do
      born_intake(100, scope)

      assert {:ok, doc} = Adopt.adopt("gh-100", @dataset, opts(scope))

      github = Link.get(doc)
      assert github["state"] == "adopted"
      assert doc.content["labels"] == ["src:github"]
    end

    test "a plain task (no github map) → {:error, :not_intake}, no comment", %{scope: scope} do
      {:ok, _} =
        Content.create_document(
          "task",
          %{
            "doc_id" => "plain-1",
            "title" => "A normal task",
            "content" => %{"kind" => "task", "lifecycle_status" => "open"}
          },
          @dataset,
          scope
        )

      assert Adopt.adopt("plain-1", @dataset, opts(scope)) == {:error, :not_intake}
      refute_receive {:comment, _, _, _}
    end

    test "a missing task → {:error, :not_found}", %{scope: scope} do
      assert Adopt.adopt("gh-does-not-exist", @dataset, opts(scope)) == {:error, :not_found}
      refute_receive {:comment, _, _, _}
    end
  end

  describe "the flip" do
    test "strips needs-human, KEEPS src:github, sets state adopted", %{scope: scope} do
      born = born_intake(101, scope)
      assert born.content["labels"] == ["src:github", "needs-human"]

      {:ok, _} = Adopt.adopt("gh-101", @dataset, opts(scope))

      doc = fetch_draft("gh-101", scope)
      assert "src:github" in doc.content["labels"]
      refute "needs-human" in doc.content["labels"]
      assert Link.get(doc)["state"] == "adopted"
    end

    test "NEVER sets a claim/worker/epoch (D6 — adoption clears the gate only)", %{scope: scope} do
      born_intake(102, scope)
      {:ok, doc} = Adopt.adopt("gh-102", @dataset, opts(scope))

      refute Map.has_key?(doc.content, "claim")
      refute Map.has_key?(doc.content, "worker")
      refute Map.has_key?(doc.content, "epoch")
    end

    test "posts the backlink ONCE with a gh-<num> body", %{scope: scope} do
      born_intake(103, scope)
      {:ok, _} = Adopt.adopt("gh-103", @dataset, opts(scope))

      assert_receive {:comment, "FRIKKern/barkpark", 103, body}
      assert body == "Tracked as gh-103 on the Barkpark board."
      refute_receive {:comment, _, _, _}
    end
  end

  describe "loop cut #2 — source=\"github\" stamp" do
    test "the adopt write's mutation_event is stamped exactly \"github\"", %{scope: scope} do
      born_intake(104, scope)
      {:ok, doc} = Adopt.adopt("gh-104", @dataset, opts(scope))

      events =
        Repo.all(
          from e in MutationEvent,
            where: e.doc_id == ^doc.doc_id,
            order_by: e.id
        )

      assert events != []
      assert Enum.all?(events, &(&1.source == "github"))
      refute Enum.any?(events, &(&1.source == "github:inbound"))
    end
  end

  describe "idempotency" do
    test "a second adopt of an already-adopted task is a {:ok, doc} no-op — no re-comment",
         %{scope: scope} do
      born_intake(105, scope)

      assert {:ok, _} = Adopt.adopt("gh-105", @dataset, opts(scope))
      assert_receive {:comment, "FRIKKern/barkpark", 105, _}

      # Second hit: already adopted → idempotent {:ok, doc}, no re-flip, no comment.
      assert {:ok, doc} = Adopt.adopt("gh-105", @dataset, opts(scope))
      assert Link.get(doc)["state"] == "adopted"
      refute_receive {:comment, _, _, _}
    end
  end

  describe "best-effort backlink" do
    test "a failing comment seam is swallowed — adoption still succeeds", %{scope: scope} do
      born_intake(106, scope)

      failing =
        opts(scope)
        |> Keyword.put(:comment_fun, fn _r, _n, _b, _o -> {:error, :boom} end)

      assert {:ok, doc} = Adopt.adopt("gh-106", @dataset, failing)
      assert Link.get(doc)["state"] == "adopted"
    end
  end

  describe "the published-first flip forks no draft twin (task-184760672ff3414b)" do
    # Publish an intake task whose ONE weighted tag is registered. On main the
    # adopt of this row went through `Content.upsert_document/4` (which ALWAYS
    # draft-prefixes) and then collapsed the twin back with
    # `Content.publish_document/4`; UNregistering the tag made that collapse trip
    # the E3 unknown_tag wall and the twin was left live for ever. There is no
    # collapse now: the flip is written straight onto the published row.
    defp published_intake_with_tag!(number, tag, scope) do
      Barkpark.LabelFixtures.register_tags!(@dataset, [tag])

      doc_id = "gh-#{number}"

      content =
        Barkpark.LabelFixtures.with_labels(
          %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "labels" => ["src:github", "needs-human"],
            "github" => %{"state" => "intake", "repo" => "FRIKKern/barkpark", "issue" => number}
          },
          1
        )
        # Pin the single tag to the freshly-registered name.
        |> Map.put("tags", [
          %{
            "tag" => tag,
            "strength" => 90,
            "rationale" => "Registered fixture tag for the published-first test path."
          }
        ])

      {:ok, _} =
        Content.create_document(
          "task",
          %{"doc_id" => doc_id, "title" => "Intake #{number}", "content" => content},
          @dataset,
          scope
        )

      {:ok, _} = Content.publish_document(doc_id, "task", @dataset, scope)
      doc_id
    end

    defp unregister_tag!(tag) do
      Repo.delete_all(
        from d in Document, where: d.doc_id == ^tag and d.type == "tag" and d.dataset == ^@dataset
      )
    end

    test "C0: adopting a PUBLISHED intake writes NO drafts.<id> twin", %{scope: scope} do
      tag = "adopt-nofork-tag-#{System.unique_integer([:positive])}"
      doc_id = published_intake_with_tag!(209, tag, scope)

      # Precondition: no twin before the adopt, so the assertion below cannot
      # pass vacuously against a row that never existed either way.
      assert {:error, :not_found} =
               Content.get_document(Content.draft_id(doc_id), "task", @dataset, scope)

      assert {:ok, doc} = Adopt.adopt(doc_id, @dataset, opts(scope))

      # The flip landed on the PUBLISHED row itself…
      assert doc.status == "published"
      assert Link.get(doc)["state"] == "adopted"
      refute "needs-human" in doc.content["labels"]
      assert "src:github" in doc.content["labels"]

      # …and no draft twin was minted along the way. On main the upsert forks one
      # here and the collapse publishes it back; a refused collapse strands it.
      assert {:error, :not_found} =
               Content.get_document(Content.draft_id(doc_id), "task", @dataset, scope)

      {:ok, published} = Content.get_document(doc_id, "task", @dataset, scope)
      assert Link.get(published)["state"] == "adopted"
      refute "needs-human" in published.content["labels"]
    end

    test "the write does not go through the publish door — an unregistered tag no longer " <>
           "strands a twin, and the row's other content survives byte for byte",
         %{scope: scope} do
      tag = "adopt-wall-tag-#{System.unique_integer([:positive])}"
      doc_id = published_intake_with_tag!(207, tag, scope)
      unregister_tag!(tag)

      {:ok, before} = Content.get_document(doc_id, "task", @dataset, scope)

      assert {:ok, doc} = Adopt.adopt(doc_id, @dataset, opts(scope))
      assert Link.get(doc)["state"] == "adopted"

      # No collapse to refuse, so no stranded twin — the failure mode this row
      # was filed for.
      assert {:error, :not_found} =
               Content.get_document(Content.draft_id(doc_id), "task", @dataset, scope)

      # Only labels + github moved. Everything else the published row carried is
      # preserved verbatim (the erasure `link_put_erasure_test.exs` forbids).
      assert Map.drop(doc.content, ["labels", "github"]) ==
               Map.drop(before.content, ["labels", "github"])
    end

    test "C1: a lost rev fence is REFUSED loudly and machine-readably, never a bare {:ok, doc}",
         %{scope: scope} do
      tag = "adopt-fence-tag-#{System.unique_integer([:positive])}"
      doc_id = published_intake_with_tag!(210, tag, scope)

      {:ok, published} = Content.get_document(doc_id, "task", @dataset, scope)

      # The row moved under us: the struct the arm is fenced on carries a rev the
      # table no longer holds. This is the shape `Tasks.Renew` produces on a
      # claimed task — the exact condition that used to refuse the collapse.
      stale = %{published | rev: "0000deadbeef0000"}

      {result, log} =
        with_log(fn -> Adopt.adopt_published(stale, @dataset, opts(scope)) end)

      assert {:error, {:adopt_refused, detail}} = result
      assert detail.gate == "rev_fence"
      assert detail.doc_id == doc_id
      assert log =~ "[error]"
      assert log =~ "github adopt: flip for #{doc_id} hit rev_fence"

      # NOTHING committed: no ledger write and no backlink comment, so the error
      # does not lie about a side effect.
      {:ok, untouched} = Content.get_document(doc_id, "task", @dataset, scope)
      assert untouched.rev == published.rev
      assert Link.get(untouched)["state"] == "intake"
      refute_receive {:comment, _, _, _}
    end

    test "a twin some OTHER writer left behind is NAMED, not published over", %{scope: scope} do
      tag = "adopt-twin-tag-#{System.unique_integer([:positive])}"
      doc_id = published_intake_with_tag!(211, tag, scope)

      # A foreign draft twin beside the published row, carrying content the
      # published row does not have.
      {:ok, published} = Content.get_document(doc_id, "task", @dataset, scope)

      {:ok, _} =
        Content.upsert_document(
          "task",
          %{
            "doc_id" => doc_id,
            "title" => published.title,
            "content" => Map.put(published.content, "foreign_marker", "do not publish me")
          },
          @dataset,
          scope
        )

      {result, log} = with_log(fn -> Adopt.adopt(doc_id, @dataset, opts(scope)) end)

      assert {:ok, doc} = result
      assert doc.status == "published"
      assert Link.get(doc)["state"] == "adopted"

      # The twin is named at error level…
      assert log =~ "[error]"
      assert log =~ "github adopt: flip for #{doc_id} hit draft_twin_present"

      # …and left alone: it was NOT published over the row.
      refute Map.has_key?(doc.content, "foreign_marker")

      {:ok, twin} = Content.get_document(Content.draft_id(doc_id), "task", @dataset, scope)
      assert twin.content["foreign_marker"] == "do not publish me"
    end
  end

  describe "C2: a NEVER-published intake is left a draft (adoption never force-publishes)" do
    # DECISION (task-184760672ff3414b C2): the never-published arm KEEPS today's
    # behaviour. Adoption clears the `needs-human` gate and flips ownership only
    # (moduledoc D6 — it does not even set a claim); publishing is a human
    # authoring act, and force-publishing here would push a draft that has never
    # faced the publish door out under the operator's name. Rejected option:
    # publish-on-adopt, which would make `bp github adopt` an authoring verb and
    # would put the E3 tag/label walls back in adoption's path — the very
    # refusable door this row removed. Same arm `Link.put/4` kept in #16479.
    test "adopt of a draft-only intake flips the DRAFT and publishes nothing", %{scope: scope} do
      born_intake(212, scope)

      # Wave-3 birth leaves the intake unpublished.
      assert {:error, :not_found} = Content.get_document("gh-212", "task", @dataset, scope)

      assert {:ok, doc} = Adopt.adopt("gh-212", @dataset, opts(scope))

      assert doc.status == "draft"
      assert Link.get(doc)["state"] == "adopted"
      refute "needs-human" in doc.content["labels"]

      # Still no published row — adoption did not force-publish under the human.
      assert {:error, :not_found} = Content.get_document("gh-212", "task", @dataset, scope)

      draft = fetch_draft("gh-212", scope)
      assert Link.get(draft)["state"] == "adopted"
    end
  end
end
