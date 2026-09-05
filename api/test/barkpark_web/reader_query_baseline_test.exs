defmodule BarkparkWeb.ReaderQueryBaselineTest do
  @moduledoc """
  Permanent query-count harness for the ANONYMOUS PAPER READER (anonymous-
  metering wave 1, slice am-w1-s3; wave 2's scoring tool).

  Pins the SQL statement cost of one anonymous `/papers/:slug` view on a fixed
  three-shape fixture and asserts absolute budgets — never percentages:

    * dead leg  (`get/2`, the crawler/unfurler render, no JS)  <= 15 statements
    * both legs (`live/2`, disconnected mount + connected mount) <= 30 statements

  ## The pinned three-shape fixture (census stated, not implied)

  One target paper carrying EVERY reader-side query amplifier at count one:

    1. one BACKLINK — a second paper referencing the target via a materialised
       `references` edge (drives `Content.Graph.reverse_referencers/2`);
    2. one DRIVEN TASK — a published `type:task` doc citing the target via a
       `design_doc` edge, 2 acceptance criteria (drives
       `Barkpark.Tasks.Expectations`);
    3. one LIVE TASK-LIST block — `query: {parent_id, dataset}` matching 2
       tasks (drives `Barkpark.PortableDoc.TaskResolver` resolve-at-read);

  plus one heading and one paragraph block (the plain-prose floor).

  Baseline measured at origin/main 5b68852f4: 22 statements dead leg / 44 both
  legs (connected leg == dead leg exactly); per-source dead: documents 7,
  datasets 4, schema_definitions 4, workspaces 3, content_edges 2, projects 1,
  task_edges 1; driven-task N+1 slope 4.0 statements per additional citing
  task per leg.

  ## The counter — no filter INSIDE the handler, an OWNER SET outside it

  The telemetry handler for `[:barkpark, :repo, :query]` runs in WHICHEVER
  process issues the query. NEVER add `if self() == test_pid` inside the
  handler: the connected mount runs in the LiveView process, so a pid-filtered
  counter under-reports `live/2` by EXACTLY the connected leg
  (mutation-measured at the baseline: 44 -> 22). That trap is kept alive here
  as a permanent test — the deliberately filtered twin counter must keep
  under-reporting `live/2` vs the honest one, proving the honest counter still
  sees cross-process queries.

  But "report unconditionally" is not the same as "count unconditionally". The
  handler is GLOBAL: it also fires for statements issued by processes that were
  never part of this request. That is not hypothetical — it reddened main at
  sha 2c5b658d41 (run 33830854180, attempt 1):

      [reader-query-baseline] dead leg (get/2): 19 statements
        (documents 6, datasets 4, schema_definitions 3, workspaces 2,
         chat_messages 1, content_edges 1, projects 1, task_edges 1)
      dead leg blew the budget: 19 > 18

  `chat_messages 1` is the whole defect. The anonymous paper reader never
  touches `chat_messages`; `Barkpark.StudioChat.BlockedSweeper` does — a
  GenServer child of `StudioChat.Supervisor` that boots with the app in EVERY
  env and re-arms `Process.send_after(self(), :sweep, 60_000)`, each sweep
  issuing one `Repo.all` over `chat_messages` joined to `chat_sessions`. The
  dead leg is a ~160ms window; once per 60s the sweeper's statement lands
  inside it and the census gains a source the reader cannot produce. `gh run
  rerun --failed` on the SAME sha passed because the next sweep missed the
  window. Load widens the window; it does not create the bug.

  Note what it is NOT: foreign ROWS. `seed_fixture!/2` already keys every shape
  on a `System.unique_integer` slug/epic, and the sibling N+1 slope test pins
  the shape at 0.0 statements per additional row. Another agent writing to the
  shared test database cannot move this count. A foreign PROCESS can.

  So the handler still reports from any process — it now tags each event with
  the issuing pid — and ownership is decided AFTER the leg has run, when
  `live/2` has finally told us which LiveView process served the connected
  mount. A statement counts when its issuing process is the test process, the
  LiveView process the leg returned, or a process spawned by either
  (`$callers`/`$ancestors`). `BlockedSweeper` is a child of the application
  supervisor and satisfies none of those, so it is excluded by construction,
  not by an allowlist of source names that would have to grow with every new
  background sweeper.

  The foreign-process leak is kept honest by its own permanent test below: a
  deliberately foreign process issues a `chat_messages` statement INSIDE the
  measured window and the census must not move. That test reds on this file's
  pre-fix counter.

  ## Known limit

  A statement-count harness is blind to rows-transferred savings: a fix that
  halves the rows a scan moves but keeps one statement per source is invisible
  here by construction. Row-volume regressions need their own guard.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Content, QueryCounter, Tasks, TenancyFixtures}

  @dataset "production"

  # Absolute budgets (wave-1 targets; wave 2 ratchets here, never loosens).
  # +1 on both (15→16, 30→31): PaperRevisionHeaders' validator lookup
  # (http-edge-truth s1, PR #10834) — one deliberate Repo.one per HTTP view
  # that mints the reader's ETag. It buys the 304 halt: a revalidating
  # reader's dead leg costs 1 statement instead of all 16. A priced
  # capability, not a silent regression — the next unexplained +1 still reds.
  #
  # +2 dead (16→18) / +4 both (31→35): the schema-visibility clamp at the
  # batch-read seat (task-38786b2edab15955 — `?expand=` hydrated a reference
  # into a PRIVATE type with no visibility check, and Envelope.render only
  # redacts FIELDS). `Query.restrict_to_visible_types/3` now guards
  # `get_documents_by_ids/3`, which the driven-tasks reverse view rides, so an
  # unauthenticated reader pays the READ-TIME allowlist: +1 schema_definitions
  # (the allowlist itself) and +1 datasets (its dataset resolution — this
  # LiveView path passes no `memoize: true`, by the barkpark-sknf gate). The
  # connected leg is a second full render, hence ×2 on both legs. Measured,
  # not estimated: dead 18 (documents 6, datasets 4, schema_definitions 3,
  # workspaces 2, content_edges 1, projects 1, task_edges 1); both 35.
  #
  # CONSTANT, not fan-out — the property this harness really guards: the
  # sibling N+1 slope test is UNCHANGED at 0.0 statements per additional citing
  # task per leg (dead 18->18, both 35->35). A priced security capability, and
  # the next unexplained +1 still reds.
  @dead_leg_budget 18
  @both_legs_budget 35
  @max_n_plus_one_slope 1.0

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    # Real task schema (the driven task + task-list rows hydrate under it) and
    # the E3 tag registry (published fixture docs carry weighted tags).
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    Barkpark.LabelFixtures.register_tags!(@dataset)

    %{scope: scope}
  end

  # ── the counter ─────────────────────────────────────────────────────────────
  #
  # `Barkpark.QueryCounter` (test/support/query_counter.ex) — the shared
  # lineage-scoped counter this file's own copy was lifted into. Same
  # semantics, unchanged: the handler reports from ANY process, tags each event
  # with the issuing pid and its `$callers`/`$ancestors`, and ownership is
  # resolved after the leg has named its LiveView process with `own/1`. See
  # that module's @moduledoc for why neither "count everything" nor a `self()`
  # filter is correct here; its permanent leak trap lives in
  # `Barkpark.QueryCounterTest`.

  # The VACUOUS-GREEN TWIN — deliberately wrong, kept only for the trap test
  # below. Counts a query ONLY when the issuing process is the test process,
  # which silently drops the whole connected leg of `live/2`.
  defp count_repo_queries_pid_filtered(fun) do
    ref = make_ref()
    test_pid = self()
    handler_id = {:reader_query_counter_filtered, ref}

    :telemetry.attach(
      handler_id,
      [:barkpark, :repo, :query],
      fn _event, _measurements, _meta, _cfg ->
        if self() == test_pid, do: send(test_pid, {ref, :query, nil})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain_filtered(ref, 0)
  end

  defp drain_filtered(ref, acc) do
    receive do
      {^ref, :query, nil} -> drain_filtered(ref, acc + 1)
    after
      0 -> acc
    end
  end

  # ── the pinned fixture ──────────────────────────────────────────────────────

  # Build the three-shape fixture around a unique slug; `citing_tasks` scales
  # ONLY the driven-task shape (for the N+1 slope test). Titles are genuinely
  # distinct — the publish-time dedup wall refuses near-duplicates at 0.71
  # similarity — and every fixture paper carries a body block (the paper
  # quality gate refuses heading-only papers).
  defp seed_fixture!(scope, opts \\ []) do
    citing_tasks = Keyword.get(opts, :citing_tasks, 1)
    title_offset = Keyword.get(opts, :title_offset, 0)
    uniq = System.unique_integer([:positive])
    slug = "rqb-target-#{uniq}"
    epic = "rqb-epic-#{uniq}"

    # 1 live task-list block matching 2 tasks. These titles must be drawn from
    # the SAME disjoint slice as the driven-task titles below, for the same
    # reason: the slope test seeds two fixtures inside one test, and the
    # publish-time dedup wall compares titles ACROSS them. A shared word stem
    # plus a differing `System.unique_integer` is NOT distinct enough — two
    # `"Collect crawler samples <n>"` scored 0.71 and the second fixture died
    # with `{:error, {:duplicate_task, ...}}` at seed 150461 (1 red in 20 runs,
    # a second flake in this file independent of the statement counter). Only
    # the DRIVEN titles were sliced by `:title_offset` before; the task-list
    # titles were left sharing a stem.
    list_titles = [
      "Collect crawler samples",
      "Publish robots verdict",
      "Chart unfurler latency",
      "Retire the legacy sitemap",
      "Weigh syndication headroom",
      "Draft the embargo memo"
    ]

    for title <-
          Enum.map(0..1, fn n -> "#{Enum.at(list_titles, title_offset + n)} #{uniq}" end) do
      {:ok, _} =
        Content.create_document(
          "task",
          %{
            "doc_id" => "rqb-lt-#{System.unique_integer([:positive])}",
            "title" => title,
            "content" => %{
              "kind" => "task",
              "lifecycle_status" => "open",
              "parent_id" => epic
            }
          },
          @dataset,
          scope
        )
    end

    # The target: heading + paragraph + one query-carrying task-list block.
    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          style: "article",
          blocks: [
            %{"id" => "h", "type" => "heading", "level" => 1, "text" => "Metering target"},
            %{
              "id" => "p",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "One anonymous view, counted."}]
            },
            %{
              "id" => "t1",
              "type" => "task-list",
              "query" => %{"parent_id" => epic, "dataset" => @dataset}
            }
          ]
        })
      )

    # 1 backlink: a second paper + a materialised `references` edge (the reader
    # reads the INDEXED engine, so the edge is seeded the projector's way).
    source_slug = "rqb-source-#{uniq}"

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: source_slug,
          blocks: [
            %{"id" => "h", "type" => "heading", "level" => 1, "text" => "Citing survey"},
            %{
              "id" => "p",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "It references the target."}]
            }
          ]
        })
      )

    Content.add_edges(
      [%{from_id: source_slug, to_id: slug, kind: "references"}],
      dataset: @dataset
    )

    # N driven tasks: published task docs citing the target via `design_doc`,
    # 2 acceptance criteria each. Titles must be GENUINELY distinct — including
    # ACROSS fixtures seeded in the same test (the slope test seeds two): the
    # publish-time dedup wall refuses near-duplicates at 0.71 similarity, and a
    # shared word stem plus a differing number is not distinct enough. The
    # `:title_offset` opt lets a second fixture draw from a disjoint slice.
    driven_titles = [
      "Drive the metering strategy",
      "Wire the shadow limiter kill switch",
      "Score the absorption censuses",
      "Harden the robots exclusion story",
      "Audit anonymous crawler amplification",
      "Prove the request stats instrument",
      "Ratchet reader statement budgets",
      "Seal the query shape dedupe"
    ]

    for n <- 1..citing_tasks do
      task_id = "rqb-dt-#{uniq}-#{n}"

      {:ok, _} =
        Content.create_document(
          "task",
          %{
            "doc_id" => task_id,
            "title" => "#{Enum.at(driven_titles, title_offset + n - 1)} #{uniq}",
            "content" =>
              Barkpark.LabelFixtures.with_labels(%{
                "kind" => "task",
                "lifecycle_status" => "open",
                "design_doc" => slug,
                "acceptance_criteria" => [
                  %{"criterion" => "budget proven", "met" => true, "evidence" => "harness run"},
                  %{"criterion" => "slope proven", "met" => false}
                ]
              })
          },
          @dataset,
          scope
        )

      {:ok, _} = Content.publish_document(task_id, "task", @dataset, scope)

      Content.add_edges(
        [%{from_id: task_id, to_id: slug, kind: "design_doc"}],
        dataset: @dataset
      )
    end

    slug
  end

  # `Phoenix.ConnTest.get/2` runs the endpoint in the test process, so the dead
  # leg owns no extra pid.
  defp dead_leg(conn, slug) do
    {_, census} =
      QueryCounter.census(fn ->
        conn |> get("/papers/#{slug}") |> html_response(200)
      end)

    census
  end

  # `live/2`'s disconnected mount runs in the test process; the connected mount
  # runs in `view.pid`, which is why the counter cannot filter on `self()`.
  defp both_legs(conn, slug) do
    {_, census} =
      QueryCounter.census(fn ->
        {:ok, view, _html} = live(conn, "/papers/#{slug}")
        QueryCounter.own(view.pid)
      end)

    census
  end

  defp print_census(label, count, per_source) do
    split =
      per_source
      |> Enum.sort_by(fn {_s, n} -> -n end)
      |> Enum.map_join(", ", fn {s, n} -> "#{s} #{n}" end)

    IO.puts("[reader-query-baseline] #{label}: #{count} statements (#{split})")
  end

  describe "anonymous /papers/:slug statement budget (pinned three-shape fixture)" do
    test "dead leg <= #{@dead_leg_budget} and both legs <= #{@both_legs_budget} statements",
         %{conn: conn, scope: scope} do
      slug = seed_fixture!(scope)

      {dead, dead_sources} = dead_leg(conn, slug)
      {both, both_sources} = both_legs(conn, slug)
      connected = both - dead

      print_census("dead leg (get/2)", dead, dead_sources)
      print_census("both legs (live/2)", both, both_sources)
      IO.puts("[reader-query-baseline] connected leg (difference): #{connected}")

      # Sanity: the fixture actually rendered its three shapes (a budget met on
      # a half-rendered page would be vacuous).
      html = conn |> get("/papers/#{slug}") |> html_response(200)
      assert html =~ "Metering target"
      assert html =~ "Related papers"
      assert html =~ "Driven tasks"
      assert html =~ "Collect crawler samples"

      assert dead <= @dead_leg_budget,
             "dead leg blew the budget: #{dead} > #{@dead_leg_budget} " <>
               "(per-source: #{inspect(dead_sources)})"

      assert both <= @both_legs_budget,
             "both legs blew the budget: #{both} > #{@both_legs_budget} " <>
               "(per-source: #{inspect(both_sources)})"

      # Not `>= 0`: a zero connected leg would mean the counter stopped seeing
      # the LiveView process, and `both <= 35` would then be a vacuous green.
      assert connected > 0,
             "the connected leg vanished (#{both} - #{dead} = #{connected}) — the honest " <>
               "counter is no longer seeing the LiveView process"
    end

    test "driven-task N+1 slope <= #{@max_n_plus_one_slope} statements per citing task per leg",
         %{conn: conn, scope: scope} do
      slug_1 = seed_fixture!(scope, citing_tasks: 1)
      slug_4 = seed_fixture!(scope, citing_tasks: 4, title_offset: 4)

      {dead_1, _} = dead_leg(conn, slug_1)
      {dead_4, _} = dead_leg(conn, slug_4)
      {both_1, _} = both_legs(conn, slug_1)
      {both_4, _} = both_legs(conn, slug_4)

      dead_slope = (dead_4 - dead_1) / 3
      both_slope = (both_4 - both_1) / 3

      IO.puts(
        "[reader-query-baseline] N+1 slope: dead #{dead_1}->#{dead_4} " <>
          "(#{Float.round(dead_slope, 2)}/task), both #{both_1}->#{both_4} " <>
          "(#{Float.round(both_slope, 2)}/task)"
      )

      assert dead_slope <= @max_n_plus_one_slope,
             "dead-leg slope #{dead_slope} > #{@max_n_plus_one_slope}/citing task " <>
               "(#{dead_1} -> #{dead_4} statements for 1 -> 4 citing tasks)"

      assert both_slope <= @max_n_plus_one_slope,
             "both-legs slope #{both_slope} > #{@max_n_plus_one_slope}/citing task " <>
               "(#{both_1} -> #{both_4} statements for 1 -> 4 citing tasks)"
    end
  end

  describe "the pid-filter vacuous-green trap (permanent)" do
    test "a pid-filtered twin counter under-reports live/2 vs the honest counter",
         %{conn: conn, scope: scope} do
      slug = seed_fixture!(scope)

      {honest, _} = both_legs(conn, slug)

      filtered =
        count_repo_queries_pid_filtered(fn ->
          {:ok, _view, _html} = live(conn, "/papers/#{slug}")
        end)

      # The connected mount runs in the LiveView process; the filtered twin
      # cannot see it. If this ever stops holding, the reader's connected leg
      # has silently vanished — or someone re-added the pid filter upstream.
      assert filtered < honest,
             "the pid-filtered twin (#{filtered}) no longer under-reports the honest " <>
               "counter (#{honest}) on live/2 — the vacuous-green trap has been defused; " <>
               "check whether the honest counter still sees the connected leg"
    end
  end

  describe "the foreign-process leak trap (permanent)" do
    # The regression this file was reddened by: a GLOBAL telemetry handler
    # counts statements from processes that were never part of the request.
    # `BlockedSweeper` (a 60s `Repo.all` over `chat_messages`, booted with the
    # app in every env) put `chat_messages 1` into the dead-leg census on main
    # at 2c5b658d41 and pushed 18 -> 19. This test reproduces that
    # DETERMINISTICALLY instead of once per 60s.
    test "a statement from a process outside the request never enters the census",
         %{conn: conn, scope: scope} do
      slug = seed_fixture!(scope)

      {clean, clean_sources} = dead_leg(conn, slug)

      {_, {noisy, noisy_sources}} =
        QueryCounter.census(fn ->
          conn |> get("/papers/#{slug}") |> html_response(200)
          foreign_chat_messages_statement!()
        end)

      refute Map.has_key?(clean_sources, "chat_messages"),
             "the reader itself queried chat_messages — this trap's premise moved " <>
               "(#{inspect(clean_sources)})"

      refute Map.has_key?(noisy_sources, "chat_messages"),
             "a foreign process's chat_messages statement entered the census " <>
               "(#{inspect(noisy_sources)}) — the counter is global again"

      assert noisy == clean,
             "a foreign statement moved the census: #{noisy} with the foreign process " <>
               "vs #{clean} without it (#{inspect(noisy_sources)})"
    end
  end

  # A process with NO spawn lineage back to the test: plain `spawn/1` writes
  # neither `$callers` nor `$ancestors`, which is exactly the shape of a
  # sweeper started by the application supervisor at boot. It issues the same
  # `chat_messages` statement `BlockedSweeper.sweep/1` issues, INSIDE the
  # measured window, and we block until it has actually run.
  defp foreign_chat_messages_statement! do
    parent = self()
    marker = make_ref()

    spawn(fn ->
      _ = Barkpark.Repo.aggregate(Barkpark.StudioChat.Message, :count, :id)
      send(parent, {marker, :done})
    end)

    receive do
      {^marker, :done} -> :ok
    after
      5_000 -> flunk("the foreign chat_messages statement never ran")
    end
  end
end
