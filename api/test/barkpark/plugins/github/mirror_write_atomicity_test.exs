defmodule Barkpark.Plugins.Github.MirrorWriteAtomicityTest do
  @moduledoc """
  task-8cb1e54603e4c3cf: the GitHub mirror stamp (`Link.put/4`, published arm)
  and the adopt flip (`Adopt.adopt_published/3`) must land the fenced task-row
  write and its `mutation_events` row together, and adopt must post its
  backlink comment only after that commit.

  Both called `Tasks.Internal.fenced_content_write/4` (an `update_all` that
  auto-commits) and only then `insert_mutation_event!`, outside any
  transaction. A fault on the event insert left the row stamped or adopted
  with no event.

  The fault is the `RETURN NULL` trigger from
  `Barkpark.Content.PublishEventAtomicityTest` (its moduledoc says why not a
  `RAISE`): `Repo.insert!` raises `Ecto.StaleEntryError` with the Postgres
  transaction still healthy.

  `async: false`: `CREATE TRIGGER` takes an ACCESS EXCLUSIVE lock on
  `mutation_events`, on every mutation's write path.
  """
  # sync: `CREATE TRIGGER` takes an ACCESS EXCLUSIVE lock on `mutation_events`, on every mutation's write path
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.MutationEvent
  alias Barkpark.Plugins.Github.{Adopt, Link}

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope}
  end

  defp opts(scope) do
    test_pid = self()

    scope
    |> Keyword.put(:dataset, @dataset)
    |> Keyword.put(:repo, "FRIKKern/barkpark")
    |> Keyword.put(:comment_fun, fn repo, number, _body, _opts ->
      send(test_pid, {:comment, repo, number})
      {:ok, %{"id" => 1}}
    end)
  end

  # A PUBLISHED gh-<n> intake row: the arm both writers take.
  defp published_intake!(scope) do
    number = System.unique_integer([:positive])
    tag = "mirror-atomic-tag-#{number}"
    Barkpark.LabelFixtures.register_tags!(@dataset, [tag])
    doc_id = "gh-#{number}"

    content =
      Barkpark.LabelFixtures.with_labels(
        %{
          "kind" => "task",
          "brief" => Barkpark.TaskBriefFixtures.brief(),
          "lifecycle_status" => "open",
          "labels" => ["src:github", "needs-human"],
          "github" => %{"state" => "intake", "repo" => "FRIKKern/barkpark", "issue" => number}
        },
        1
      )
      |> Map.put("tags", [
        %{
          "tag" => tag,
          "strength" => 90,
          "rationale" => "Registered fixture tag for the mirror atomicity test."
        }
      ])

    {:ok, _} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => "Intake #{number}", "content" => content},
        @dataset,
        scope ++ [source: :github]
      )

    {:ok, published} = Content.publish_document(doc_id, "task", @dataset, scope)
    {published, number}
  end

  defp break_mutation_events! do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION bp_test_swallow_mutation_event() RETURNS trigger AS $fn$
    BEGIN
      RETURN NULL;
    END;
    $fn$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER bp_test_swallow_mutation_event_trg
    BEFORE INSERT ON mutation_events
    FOR EACH ROW EXECUTE FUNCTION bp_test_swallow_mutation_event()
    """)

    :ok
  end

  defp github_of(doc_id, scope) do
    {:ok, doc} = Content.get_document(doc_id, "task", @dataset, scope)
    Link.get(doc)
  end

  defp event_count(doc_id) do
    Repo.aggregate(from(e in MutationEvent, where: e.doc_id == ^doc_id), :count)
  end

  describe "Link.put/4 (published arm)" do
    test "a mutation_events fault leaves the task row unstamped", %{scope: scope} do
      {published, _n} = published_intake!(scope)
      break_mutation_events!()

      assert_raise Ecto.StaleEntryError, fn ->
        Link.put(published.doc_id, @dataset, %{"state" => "synced"}, scope)
      end

      assert github_of(published.doc_id, scope)["state"] == "intake",
             "the stamp survived a failed mutation_event insert — in production it is " <>
               "committed and no SSE/webhook consumer ever learns of it"
    end

    test "CONTROL: without the fault the stamp lands with one event", %{scope: scope} do
      {published, _n} = published_intake!(scope)
      before = event_count(published.doc_id)

      assert {:ok, _} = Link.put(published.doc_id, @dataset, %{"state" => "synced"}, scope)

      assert github_of(published.doc_id, scope)["state"] == "synced"
      assert event_count(published.doc_id) == before + 1
    end
  end

  describe "Adopt.adopt_published/3" do
    test "a mutation_events fault leaves the row unadopted and posts no backlink",
         %{scope: scope} do
      {published, _n} = published_intake!(scope)
      break_mutation_events!()

      assert_raise Ecto.StaleEntryError, fn ->
        Adopt.adopt_published(published, @dataset, opts(scope))
      end

      assert github_of(published.doc_id, scope)["state"] == "intake",
             "the adopt flip survived a failed mutation_event insert"

      refute_received {:comment, _, _}
    end

    test "CONTROL: without the fault the flip lands with one event, then the backlink posts",
         %{scope: scope} do
      {published, number} = published_intake!(scope)
      before = event_count(published.doc_id)

      assert {:ok, _} = Adopt.adopt_published(published, @dataset, opts(scope))

      assert github_of(published.doc_id, scope)["state"] == "adopted"
      assert event_count(published.doc_id) == before + 1
      assert_received {:comment, "FRIKKern/barkpark", ^number}
    end
  end
end
