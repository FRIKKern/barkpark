defmodule Barkpark.Search.IdWordInALongerQueryTest do
  # task-5985afa7b6e7454f. A search for a task's full title answered with a tag
  # alone when one word of the title was also that tag's document id ("SDK" →
  # tag `sdk`, "block" → tag `block`), so the task looked missing and the person
  # filed a duplicate.
  #
  # The words of these titles include paths ("/v1/data/search",
  # "reader_task_scope/1"), which Postgres indexes as one token, so the strict
  # every-word pass finds nothing in the task. The id arm, OR-ed around the whole
  # word match, still let the tag in on the one word that was its id, and one
  # hit is not zero, so the any-word recovery that finds the task never ran.
  #
  # The id arm stays (a task row often names another task's id): only when the
  # text alone finds nothing does the recovery run.
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Search.{QueryPipeline, SurfaceConfigs}

  @dataset "idword"
  @title "An unsupported ?perspective is still silently downgraded to published on " <>
           "/v1/data/search and /v1/graph — three forked parsers, and the SDK is " <>
           "stricter than the server"

  setup do
    SurfaceConfigs.seed_defaults!()

    for {name, title} <- [{"tag", "Tag"}, {"note", "Note"}] do
      Content.upsert_schema(
        %{"name" => name, "title" => title, "visibility" => "public", "fields" => []},
        @dataset
      )
    end

    {:ok, _} =
      Content.create_document("tag", %{"doc_id" => "drafts.sdk", "title" => "SDK"}, @dataset)

    {:ok, _} = Content.publish_document("sdk", "tag", @dataset)

    {:ok, _} =
      Content.create_document("note", %{"doc_id" => "drafts.task-1", "title" => @title}, @dataset)

    {:ok, _} = Content.publish_document("task-1", "note", @dataset)

    {:ok, _} =
      Content.create_document(
        "tag",
        %{"doc_id" => "drafts.zebra", "title" => "Striped animals"},
        @dataset
      )

    {:ok, _} = Content.publish_document("zebra", "tag", @dataset)

    for {id, title} <- [
          {"task-abc123", "Parser crash on empty input"},
          {"task-def456", "Fix for task-abc123 in the parser"}
        ] do
      {:ok, _} =
        Content.create_document(
          "note",
          %{"doc_id" => "drafts." <> id, "title" => title},
          @dataset
        )

      {:ok, _} = Content.publish_document(id, "note", @dataset)
    end

    :ok
  end

  defp search(query, opts \\ []) do
    {:ok, result} =
      QueryPipeline.search(
        "documents",
        @dataset,
        %{query: query, filters: %{}, offset: 0},
        [perspective: :published, limit: 20] ++ opts
      )

    {Enum.map(result.hits, & &1.doc_id), result.recovery}
  end

  test "a full title holding a tag's id finds the task, not the tag alone" do
    {found, _recovery} = search(@title)

    assert "task-1" in found,
           "the full title answered #{inspect(found)}: the tag whose id is one word of it " <>
             "stood in for the task"
  end

  test "an id and a word its document lacks, while another document holds every word, finds both" do
    # task-abc123 lacks "fix"; task-def456 holds both words. The text found a
    # document, so no recovery ran, and the id's document stays next to it.
    {found, recovery} = search("task-abc123 fix")

    assert Enum.sort(found) == ["task-abc123", "task-def456"],
           "\"task-abc123 fix\" answered #{inspect(found)}"

    assert recovery == nil
  end

  test "the type-ahead never pays for the ids-only check" do
    # "zebra fi": two words, and "zebra" finds its document by id alone, so a
    # full search reads `IdOnlyHits`. A suggestion runs no recovery, so it must
    # not run that read either: a keystroke never pays for recovery.
    test_pid = self()
    handler = "id-only-exists-#{System.unique_integer()}"

    :telemetry.attach(
      handler,
      [:barkpark, :repo, :query],
      fn _event, _measurements, %{query: sql}, _ ->
        if self() == test_pid and sql =~ "SELECT TRUE", do: send(test_pid, {:exists_query, sql})
      end,
      nil
    )

    try do
      search("zebra fi", suggest: true)
      refute_received {:exists_query, _}, "the type-ahead ran the ids-only exists? read"

      # CONTROL: the full search does run it, so the counter sees the read.
      search("zebra fi")
      assert_received {:exists_query, _}
    after
      :telemetry.detach(handler)
    end
  end

  test "CONTROL: a query that IS a document's id still finds that document by its id" do
    # "zebra" is in no field of the document, only in its id.
    assert search("zebra") == {["zebra"], nil}

    # The type-ahead skips the substring step that also matches an id, so the
    # words step's id arm is the only way it finds the document.
    assert search("zebra", suggest: true) == {["zebra"], nil}
  end
end
