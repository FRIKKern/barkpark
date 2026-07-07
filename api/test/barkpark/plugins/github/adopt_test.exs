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

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.MutationEvent
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
end
