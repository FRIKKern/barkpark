defmodule BarkparkWeb.BulldocsLiveTasksTest do
  @moduledoc """
  End-to-end lock for LIVE PLANS: a paper whose `task-list` block carries a
  `query` (not a static snapshot) renders the real `bp` tasks in the Bulldocs
  reader — resolve-at-read — and re-renders when a task moves (the reader
  subscribes to its tenant's task mutations and re-resolves). The task twin of
  the sheet-embed View-mode lock.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Content, Tasks, TenancyFixtures}

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    # E3 tag registry: `with_labels/1`'s weighted tags must resolve to PUBLISHED
    # type:tag docs before a task fixture can be published.
    Barkpark.LabelFixtures.register_tags!(@dataset)

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

  defp mk_task!(title, lifecycle, epic, scope) do
    doc_id = "lt-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => title,
          "content" =>
            # The authoring wall's label spine refuses to PUBLISH a document
            # with no description / weighted tags, and these fixtures now get
            # published (`with_labels/1` supplies the spine, the same way
            # bulldocs_live_test.exs's published task fixture does).
            Barkpark.LabelFixtures.with_labels(%{
              "kind" => "task",
              "lifecycle_status" => lifecycle,
              "parent_id" => epic
            })
        },
        @dataset,
        scope
      )

    doc
  end

  # A task an author has actually PUBLISHED — the only kind a reader surface may
  # render since task-b10e10b944f6f55b. `Content.create_document/4` force-writes
  # every new doc to `drafts.<id>`; publishing promotes it to the bare id, which
  # is what `Tasks.Query`'s `published_only` conjunct matches.
  defp mk_published_task!(title, lifecycle, epic, scope) do
    doc = mk_task!(title, lifecycle, epic, scope)
    pid = Barkpark.Content.DraftId.published_id(doc.doc_id)
    {:ok, published} = Content.publish_document(pid, "task", @dataset, scope)
    published
  end

  test "a task-list query renders live tasks, and a mutation updates the plan", %{
    conn: conn,
    scope: scope
  } do
    epic = "epic-#{System.unique_integer([:positive])}"
    # PUBLISHED tasks: a reader surface renders the published perspective only
    # (task-b10e10b944f6f55b), so this lock uses tasks an author published
    # rather than the draft-only rows it used to lean on.
    _done = mk_published_task!("collect targets", "done", epic, scope)
    open = mk_published_task!("inject snapshot", "open", epic, scope)

    slug = "live-plan-#{System.unique_integer([:positive])}"

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          # Real ingested papers are article-styled (BulldocsIngestController
          # defaults style: "article") — the reader renders their blocks with the
          # CLASSED article emitters. A style-less legacy paper renders the
          # self-contained inline :email variants instead (works, different DOM).
          style: "article",
          blocks: [
            %{
              "id" => "t1",
              "type" => "task-list",
              "query" => %{"parent_id" => epic, "dataset" => @dataset}
            }
          ]
        })
      )

    {:ok, view, html} = live(conn, "/papers/#{slug}")

    # resolve-at-read: the real tasks are in the rendered plan, with the right
    # white-ladder glyphs (done = teal ✓, open-no-blocker = ready ○ white).
    assert html =~ "collect targets"
    assert html =~ "inject snapshot"
    assert html =~ "bp-g--done"
    assert html =~ "bp-g--ready"

    # Move the work: close the open task. A mirror write (source: :sync) —
    # the Writer-seam transition gate (tlv) refuses a raw api-door open → done
    # (`done` is reached only via `bp task close`), and this test's concern is
    # the reader re-resolving on a task mutation broadcast, not the door.
    {:ok, _} =
      Content.upsert_document(
        "task",
        %{
          "doc_id" => open.doc_id,
          # Title + label spine ride along: publishing consumed the original
          # draft row, so this write re-cuts the `drafts.` twin from scratch and
          # the authoring quality gate wants a titled, spine-complete task.
          "title" => open.title,
          "content" =>
            Barkpark.LabelFixtures.with_labels(%{
              "kind" => "task",
              "lifecycle_status" => "done",
              "parent_id" => epic
            })
        },
        @dataset,
        scope ++ [source: :sync]
      )

    # The mutate door writes the `drafts.` twin; twin-collapse suppresses it
    # while the published row exists, so the move only reaches a READER once the
    # author publishes it — the same two-step `bp task close` performs.
    {:ok, _} =
      Content.publish_document(open.doc_id, "task", @dataset, scope ++ [source: :sync])

    # The reader heard the task mutation on its tenant stream and re-resolved —
    # the same live view now shows both tasks done, no ready ROW left (the
    # momentum legend keeps a static "ready" label, so assert on the row class).
    updated = render(view)
    assert updated =~ "inject snapshot"
    refute updated =~ "bp-trow--ready"
    assert updated =~ ~r/bp-trow--done.*bp-trow--done/s
    assert updated =~ "<b>2</b> done"
  end

  test "an author-pinned snapshot (no query) still renders offline", %{conn: conn} do
    slug = "static-plan-#{System.unique_integer([:positive])}"

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          # Real ingested papers are article-styled (BulldocsIngestController
          # defaults style: "article") — the reader renders their blocks with the
          # CLASSED article emitters. A style-less legacy paper renders the
          # self-contained inline :email variants instead (works, different DOM).
          style: "article",
          blocks: [
            %{
              "id" => "t1",
              "type" => "task-list",
              "snapshot" => [%{"title" => "hand-written", "status" => "ready"}]
            }
          ]
        })
      )

    {:ok, _view, html} = live(conn, "/papers/#{slug}")
    assert html =~ "hand-written"
  end
  describe "D5 published-perspective gate on the reader's task blocks" do
    # THE LEAK (task-b10e10b944f6f55b). `reader_task_scope/1` omitted
    # `published_only`, so `Tasks.Query.docs_for_query/2` applied twin-collapse
    # only — and an UNPAIRED `drafts.<id>` row (every `bp task create` task)
    # survives twin-collapse by that function's own documented design. A
    # PUBLISHED paper's task block therefore handed an anonymous reader the
    # titles of tasks nobody published.
    test "an anonymous reader of a published paper never sees a draft-only task",
         %{conn: conn, scope: scope} do
      epic = "epic-#{System.unique_integer([:positive])}"

      # draft-only: created through the real chokepoint, NEVER published.
      _draft = mk_task!("unpublished quarter reorg", "open", epic, scope)
      # positive control: same query, published — so a green `refute` below can
      # not be the trivial pass of an EMPTY block.
      _published = mk_published_task!("public roadmap item", "open", epic, scope)

      slug = "d5-plan-#{System.unique_integer([:positive])}"

      {:ok, _paper} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: slug,
            style: "article",
            blocks: [
              %{
                "id" => "t1",
                "type" => "task-list",
                "query" => %{"parent_id" => epic, "dataset" => @dataset}
              }
            ]
          })
        )

      # `conn` is `Phoenix.ConnTest.build_conn/0` — no token, no session, and
      # `/papers/:slug` is the `:public_root` route with no on_mount gate.
      {:ok, _view, html} = live(conn, "/papers/#{slug}")

      assert html =~ "public roadmap item"
      refute html =~ "unpublished quarter reorg"
    end

    # NEGATIVE CONTROL. The authorised author's own view of the SAME blocks is
    # Studio's `paper_stream_items/4`, which threads its session scope WITHOUT
    # `published_only` — that path must keep resolving draft tasks, or the gate
    # would have broken authoring instead of closing a leak.
    test "the authorised author scope still resolves draft-only tasks", %{scope: scope} do
      epic = "epic-#{System.unique_integer([:positive])}"
      _draft = mk_task!("unpublished author draft", "open", epic, scope)

      blocks = [
        %{
          "id" => "t1",
          "type" => "task-list",
          "query" => %{"parent_id" => epic, "dataset" => @dataset}
        }
      ]

      # EXACTLY the scope Studio passes: workspace/project, no published_only.
      [resolved] = Barkpark.Content.Papers.resolve_tasks_in_blocks(blocks, scope, @dataset)

      titles = Enum.map(resolved["snapshot"] || [], & &1["title"])
      assert "unpublished author draft" in titles
    end
  end
end
