defmodule Barkpark.EdgeProjector.ReprojectLinkersTest do
  @moduledoc """
  task-4ec7e38d85c07ab7: when a target is unpublished or deleted, every
  `content_edges` row pointing at it goes (FK cascade + `delete_record/2`),
  and publishing it again re-projected only its own outbound edges. The
  documents linking to it kept no edges until each was saved again.

  A published row that is BORN now enqueues `ReprojectLinkersWorker`, which
  finds the linkers in live content and re-projects them.
  """
  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  import Ecto.Query

  alias Barkpark.{Content, Repo, TenancyFixtures}
  alias Barkpark.Content.{Document, Edge}
  alias Barkpark.EdgeProjector.ReprojectLinkersWorker

  @ds "reproject_linkers_test"
  @ds2 "reproject_linkers_test_2"

  setup do
    ws = TenancyFixtures.create_workspace!()
    scope = [workspace_id: ws.id, project_id: TenancyFixtures.create_project!(ws).id]
    schemas!(scope, @ds)
    %{scope: scope}
  end

  defp schemas!(scope, ds) do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "rl_author", "title" => "A", "visibility" => "public", "fields" => []},
        ds,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "rl_post",
          "title" => "P",
          "visibility" => "public",
          "fields" => [
            %{"name" => "author", "type" => "reference", "refType" => "rl_author"},
            %{"name" => "body", "type" => "richText"}
          ]
        },
        ds,
        scope
      )
  end

  defp body(id),
    do: %{
      "blocks" => [
        %{
          "type" => "paragraph",
          "content" => [
            %{"type" => "text", "value" => "see "},
            %{
              "type" => "wikilink",
              "docId" => id,
              "target" => id,
              "children" => [%{"type" => "text", "value" => id}]
            }
          ]
        }
      ]
    }

  defp publish!(type, id, attrs, scope, ds \\ @ds) do
    {:ok, _} =
      Content.create_document(type, Map.merge(%{"_id" => id, "title" => id}, attrs), ds, scope)

    {:ok, doc} = Content.publish_document(id, type, ds, scope)
    doc
  end

  defp post!(id, author, scope, ds \\ @ds),
    do: publish!("rl_post", id, %{"author" => author, "body" => body(author)}, scope, ds)

  defp kinds(id, scope, ds \\ @ds) do
    {:ok, %Document{id: pk}} = Content.get_document(id, "rl_post", ds, scope)

    from(e in Edge, where: e.from_id == ^pk, select: e.kind)
    |> Repo.all()
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.filter(&(&1 in ["author", "body"]))
  end

  # The publish's own projection may ride the debounced :edge_projector job
  # inside the test's sandbox transaction; drain it first, then the linkers.
  defp drain do
    Oban.drain_queue(queue: :edge_projector, with_scheduled: true)
    Oban.drain_queue(queue: :edge_linkers, with_scheduled: true, with_recursion: true)
  end

  test "unpublish then republish a target restores its linkers' edges", %{scope: scope} do
    publish!("rl_author", "rl-a1", %{}, scope)
    post!("rl-p1", "rl-a1", scope)
    drain()
    assert kinds("rl-p1", scope) == ["author", "body"]

    {:ok, _} = Content.unpublish_document("rl-a1", "rl_author", @ds, scope)
    assert kinds("rl-p1", scope) == []

    {:ok, _} = Content.publish_document("rl-a1", "rl_author", @ds, scope)
    drain()
    assert kinds("rl-p1", scope) == ["author", "body"]
  end

  test "delete then re-create a target restores its linkers' edges", %{scope: scope} do
    publish!("rl_author", "rl-a2", %{}, scope)
    post!("rl-p2", "rl-a2", scope)
    drain()

    {:ok, _} = Content.delete_document("rl-a2", "rl_author", @ds, scope)
    assert kinds("rl-p2", scope) == []

    publish!("rl_author", "rl-a2", %{}, scope)
    drain()
    assert kinds("rl-p2", scope) == ["author", "body"]
  end

  test "a link published while its target is absent appears when the target is published",
       %{scope: scope} do
    post!("rl-p3", "rl-a3", scope)
    assert kinds("rl-p3", scope) == []

    publish!("rl_author", "rl-a3", %{}, scope)
    drain()
    assert kinds("rl-p3", scope) == ["author", "body"]
  end

  test "a publish over an existing published row enqueues nothing", %{scope: scope} do
    publish!("rl_author", "rl-a4", %{}, scope)
    drain()

    {:ok, _} =
      Content.create_document(
        "rl_author",
        %{"_id" => "rl-a4", "title" => "again"},
        @ds,
        scope
      )

    {:ok, _} = Content.publish_document("rl-a4", "rl_author", @ds, scope)
    assert all_enqueued(worker: ReprojectLinkersWorker) == []
  end

  test "the same id in another workspace or dataset is never re-projected", %{scope: scope} do
    other_ws = TenancyFixtures.create_workspace!()
    other = [workspace_id: other_ws.id, project_id: TenancyFixtures.create_project!(other_ws).id]
    schemas!(other, @ds)
    schemas!(scope, @ds2)

    for {sc, ds} <- [{scope, @ds}, {other, @ds}, {scope, @ds2}] do
      publish!("rl_author", "rl-same", %{}, sc, ds)
      post!("rl-ps", "rl-same", sc, ds)
    end

    drain()

    # The other tenant's and the other dataset's linkers lose their edges by
    # hand, so a stray re-projection there would show.
    for {sc, ds} <- [{other, @ds}, {scope, @ds2}] do
      {:ok, %Document{id: pk}} = Content.get_document("rl-ps", "rl_post", ds, sc)
      Repo.delete_all(from(e in Edge, where: e.from_id == ^pk))
    end

    {:ok, _} = Content.unpublish_document("rl-same", "rl_author", @ds, scope)
    {:ok, _} = Content.publish_document("rl-same", "rl_author", @ds, scope)
    drain()

    assert kinds("rl-ps", scope) == ["author", "body"]
    assert kinds("rl-ps", other) == []
    assert kinds("rl-ps", scope, @ds2) == []
  end

  test "a target with exactly a page of linkers enqueues no empty continuation",
       %{scope: scope} do
    Application.put_env(:barkpark, ReprojectLinkersWorker, page: 3)
    on_exit(fn -> Application.delete_env(:barkpark, ReprojectLinkersWorker) end)

    {:ok, _} = Content.create_document("rl_author", %{"_id" => "rl-a5"}, @ds, scope)
    for i <- 1..3, do: post!("rl-p5-#{i}", "rl-a5", scope)
    drain()
    {:ok, _} = Content.publish_document("rl-a5", "rl_author", @ds, scope)

    assert %{success: 1, failure: 0} =
             Oban.drain_queue(queue: :edge_linkers, with_scheduled: true, with_recursion: true)

    for i <- 1..3, do: assert(kinds("rl-p5-#{i}", scope) == ["author", "body"])
  end

  test "a bulk publish of 200 targets enqueues one bounded job each on its own queue",
       %{scope: scope} do
    Application.put_env(:barkpark, ReprojectLinkersWorker, page: 3)
    on_exit(fn -> Application.delete_env(:barkpark, ReprojectLinkersWorker) end)

    ids = for i <- 1..200, do: "rl-bulk-#{i}"
    for id <- ids, do: {:ok, _} = Content.create_document("rl_author", %{"_id" => id}, @ds, scope)
    # Seven linkers of one target, so its job pages (page 3) and continues.
    for i <- 1..7, do: post!("rl-bulk-post-#{i}", "rl-bulk-1", scope)

    {:ok, _} =
      Content.Mutations.apply_mutations(
        Enum.map(ids, &%{"publish" => %{"id" => &1, "type" => "rl_author"}}),
        @ds,
        scope
      )

    # Each post's own birth enqueued a job too; count the authors'.
    jobs =
      ReprojectLinkersWorker
      |> then(&all_enqueued(worker: &1))
      |> Enum.filter(&(&1.args["type"] == "rl_author"))

    assert length(jobs) == 200
    assert Enum.all?(jobs, &(&1.queue == "edge_linkers"))
    assert jobs |> Enum.map(& &1.args["_id"]) |> Enum.uniq() |> length() == 200

    # Unique: the same birth enqueued again adds no second job.
    {:ok, a1} = Content.get_document("rl-bulk-1", "rl_author", @ds, scope)
    ReprojectLinkersWorker.enqueue(a1)

    assert length(
             Enum.filter(
               all_enqueued(worker: ReprojectLinkersWorker),
               &(&1.args["type"] == "rl_author")
             )
           ) == 200

    assert %{failure: 0, success: success} = drain()
    # 200 first pages plus the continuations of the paged target.
    assert success > 200
    for i <- 1..7, do: assert(kinds("rl-bulk-post-#{i}", scope) == ["author", "body"])

    # Its own queue, at concurrency 1, so a burst never crowds another queue.
    assert Application.get_env(:barkpark, Oban)[:queues][:edge_linkers] == 1
  end

  # ── gyl, 2026-10-30: 1621 new catalogue titles, each job a 30 s scan ──────

  @ds3 "reproject_linkers_test_3"

  # A catalogue: titles, labels that reference a title, and lines nothing
  # references. No richText anywhere, so wikilinks cannot link either.
  defp catalogue_schemas!(scope) do
    for {name, fields} <- [
          {"rl_title", []},
          {"rl_line", [%{"name" => "isbn", "type" => "string"}]},
          {"rl_label",
           [
             %{
               "name" => "book",
               "type" => "reference",
               "refType" => "rl_title",
               "to" => [%{"type" => "rl_title"}]
             }
           ]}
        ] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => name, "title" => name, "visibility" => "public", "fields" => fields},
          @ds3,
          scope
        )
    end
  end

  # The SQL of every statement that reads `documents` while `fun` runs.
  defp documents_reads(fun) do
    ref = make_ref()
    me = self()
    handler = "rl-docs-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:barkpark, :repo, :query],
      fn _event, _measure, meta, _ ->
        if meta[:source] == "documents" or String.contains?(meta[:query] || "", "\"documents\""),
          do: send(me, {ref, meta[:query]})
      end,
      nil
    )

    try do
      result = fun.()
      {result, collect(ref, [])}
    after
      :telemetry.detach(handler)
    end
  end

  defp collect(ref, acc) do
    receive do
      {^ref, sql} -> collect(ref, [sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp job_args(id, type, scope, ds),
    do: %{
      "_id" => id,
      "type" => type,
      "dataset" => ds,
      "dataset_id" => nil,
      "workspace_id" => scope[:workspace_id],
      "project_id" => scope[:project_id]
    }

  describe "linker_plan/2" do
    test "names the types whose fields can hold a link to the type" do
      schemas = [
        %{name: "a", fields: [%{"name" => "r", "type" => "reference", "refType" => "t"}]},
        %{name: "b", fields: [%{"name" => "r", "type" => "reference", "refType" => "other"}]},
        %{
          name: "c",
          fields: [%{"name" => "r", "type" => "reference", "to" => [%{"type" => "t"}]}]
        },
        %{name: "d", fields: [%{"name" => "r", "type" => "reference"}]},
        %{
          name: "e",
          fields: [
            %{
              "name" => "r",
              "type" => "reference",
              "refType" => "other",
              "refTypeTolerant" => true
            }
          ]
        },
        %{
          name: "f",
          fields: [
            %{
              "name" => "rs",
              "type" => "arrayOf",
              "of" => [%{"type" => "reference", "refType" => "t"}]
            }
          ]
        },
        %{
          name: "g",
          fields: [
            %{
              "name" => "o",
              "type" => "object",
              "fields" => [%{"name" => "r", "type" => "reference", "refType" => "t"}]
            }
          ]
        },
        %{name: "h", fields: [%{"name" => "body", "type" => "richText"}]},
        %{name: "i", fields: [%{"name" => "s", "type" => "string"}]}
      ]

      plan = ReprojectLinkersWorker.linker_plan(schemas, "t")
      assert Enum.sort(plan.ref_types) == ~w(a c d e f g)
      assert Enum.sort(plan.ref_fields) == ~w(r rs)
      assert plan.wikilink_types == ["h"]

      assert ReprojectLinkersWorker.linker_plan(
               [
                 %{name: "b", fields: [%{"name" => "r", "type" => "reference", "refType" => "x"}]}
               ],
               "t"
             ) == %{ref_fields: [], ref_types: [], wikilink_types: []}
    end
  end

  test "a target nothing can link to ends after the schema read, with no documents read",
       %{scope: scope} do
    catalogue_schemas!(scope)

    {result, reads} =
      documents_reads(fn ->
        perform_job(ReprojectLinkersWorker, job_args("rl-line-1", "rl_line", scope, @ds3))
      end)

    assert result == :ok
    assert reads == []
  end

  test "the lookup reads only the types that can link, through a materialized match",
       %{scope: scope} do
    catalogue_schemas!(scope)
    publish!("rl_title", "rl-t-1", %{}, scope, @ds3)
    publish!("rl_label", "rl-l-1", %{"book" => "rl-t-1"}, scope, @ds3)
    drain()

    {:ok, %Document{id: pk}} = Content.get_document("rl-l-1", "rl_label", @ds3, scope)
    Repo.delete_all(from(e in Edge, where: e.from_id == ^pk))

    {:ok, title} = Content.get_document("rl-t-1", "rl_title", @ds3, scope)
    args = Map.put(job_args("rl-t-1", "rl_title", scope, @ds3), "dataset_id", title.dataset_id)

    {result, reads} =
      documents_reads(fn -> perform_job(ReprojectLinkersWorker, args) end)

    assert result == :ok
    [lookup | _] = Enum.filter(reads, &String.contains?(&1, "reproject_linker_matches"))
    assert lookup =~ "AS MATERIALIZED"
    assert lookup =~ ~r/"type" = ANY\(/

    assert Repo.exists?(from(e in Edge, where: e.from_id == ^pk and e.kind == "book"))
  end

  test "a lookup past its statement_timeout is cancelled once, not retried", %{scope: scope} do
    Application.put_env(:barkpark, ReprojectLinkersWorker, lookup_timeout_ms: 20)
    on_exit(fn -> Application.delete_env(:barkpark, ReprojectLinkersWorker) end)
    catalogue_schemas!(scope)

    # 20,000 labels with deep content, and no index allowed for the rest of
    # this sandbox transaction: the `_ref` jsonpath then walks every label,
    # which takes far longer than the 20 ms lookup timeout.
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    deep = for i <- 1..40, do: %{"k" => i, "o" => %{"p" => [%{"q" => i}, %{"r" => "x"}]}}

    for chunk <- Enum.chunk_every(1..20_000, 2_000) do
      Repo.insert_all(
        Document,
        for i <- chunk do
          %{
            doc_id: "rl-pad-#{i}",
            rev: "r#{i}",
            type: "rl_label",
            dataset: @ds3,
            status: "published",
            content: %{"book" => "rl-t-#{i}", "deep" => deep},
            workspace_id: scope[:workspace_id],
            project_id: scope[:project_id],
            inserted_at: now,
            updated_at: now
          }
        end
      )
    end

    for setting <- ~w(enable_bitmapscan enable_indexscan enable_indexonlyscan),
        do: Repo.query!("SET LOCAL #{setting} = off")

    Repo.query!("SET LOCAL max_parallel_workers_per_gather = 0")

    {result, log} =
      ExUnit.CaptureLog.with_log(fn ->
        perform_job(ReprojectLinkersWorker, job_args("rl-t-slow", "rl_title", scope, @ds3))
      end)

    assert result == {:cancel, :statement_timeout}

    assert [_] =
             Regex.scan(~r/linker lookup for rl-t-slow .*cancelled, not retried/, log)
  end

  test "a backlog of jobs from the old code drains in one attempt each", %{scope: scope} do
    catalogue_schemas!(scope)
    publish!("rl_title", "rl-t-linked", %{}, scope, @ds3)
    publish!("rl_label", "rl-l-linked", %{"book" => "rl-t-linked"}, scope, @ds3)
    drain()

    # The args the 0.2.32 enqueue wrote, as gyl's queued jobs hold them: one
    # per new title, and one per new line nothing references.
    {:ok, title} = Content.get_document("rl-t-linked", "rl_title", @ds3, scope)

    backlog =
      for(i <- 1..150, do: job_args("rl-t-new-#{i}", "rl_title", scope, @ds3)) ++
        for(i <- 1..150, do: job_args("rl-line-new-#{i}", "rl_line", scope, @ds3)) ++
        [job_args("rl-t-linked", "rl_title", scope, @ds3)]

    Enum.each(backlog, fn args ->
      args
      |> Map.put("dataset_id", title.dataset_id)
      |> ReprojectLinkersWorker.new()
      |> Oban.insert!()
    end)

    {{elapsed_us, result}, reads} =
      documents_reads(fn ->
        :timer.tc(fn -> Oban.drain_queue(queue: :edge_linkers, with_recursion: true) end)
      end)

    assert %{success: 301, failure: 0, cancelled: 0, discard: 0} = result
    # Titles: one lookup statement each. Lines: none. The one linker adds its
    # own read and re-projection, a handful of statements.
    lookups = Enum.count(reads, &String.contains?(&1, "reproject_linker_matches"))
    assert lookups == 151
    assert length(reads) - lookups <= 10

    IO.puts(
      "reproject backlog: 301 jobs drained in #{div(elapsed_us, 1000)} ms " <>
        "(#{Float.round(elapsed_us / 301 / 1000, 2)} ms a job)"
    )
  end
end
