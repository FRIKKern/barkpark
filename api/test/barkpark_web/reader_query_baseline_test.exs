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

  ## The counter — pid-filter-FREE, and why that is load-bearing

  The telemetry handler for `[:barkpark, :repo, :query]` runs in WHICHEVER
  process issues the query and sends to the test pid unconditionally. NEVER
  add `if self() == test_pid` inside the handler: the connected mount runs in
  the LiveView process, so a pid-filtered counter under-reports `live/2` by
  EXACTLY the connected leg (mutation-measured at the baseline: 44 -> 22).
  That trap is kept alive here as a permanent test — the deliberately filtered
  twin counter must keep under-reporting `live/2` vs the honest one, proving
  the honest counter still sees cross-process queries.

  ## Known limit

  A statement-count harness is blind to rows-transferred savings: a fix that
  halves the rows a scan moves but keeps one statement per source is invisible
  here by construction. Row-volume regressions need their own guard.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Content, Tasks, TenancyFixtures}

  @dataset "production"

  # Absolute budgets (wave-1 targets; wave 2 ratchets here, never loosens).
  # +1 on both (15→16, 30→31): PaperRevisionHeaders' validator lookup
  # (http-edge-truth s1, PR #10834) — one deliberate Repo.one per HTTP view
  # that mints the reader's ETag. It buys the 304 halt: a revalidating
  # reader's dead leg costs 1 statement instead of all 16. A priced
  # capability, not a silent regression — the next unexplained +1 still reds.
  #
  # +1 dead (16→17) / +2 both (31→33): the schema-visibility clamp at the
  # batch-read seat (task-38786b2edab15955 — `?expand=` hydrated a reference
  # into a PRIVATE type with no visibility check, and Envelope.render only
  # redacts FIELDS). `Query.restrict_to_visible_types/4` guards
  # `get_documents_by_ids/3`, which the driven-tasks reverse view rides, so an
  # unauthenticated reader pays ONE read-time `schema_definitions` allowlist
  # query. The connected leg is a second full render, hence ×2 on both legs.
  #
  # THE MEASURED DELTA, per source, origin/main → clamped (dead leg):
  #   documents 6→6, datasets 3→3, schema_definitions 2→3, workspaces 2→2,
  #   content_edges 1→1, projects 1→1, task_edges 1→1.
  # Only `schema_definitions` moves, and by exactly one. `documents` is FLAT —
  # the clamp is not per-row.
  #
  # CONSTANT, not fan-out — the property this harness really guards: the sibling
  # N+1 slope test is 0.0 statements per additional citing task per leg (dead
  # 17->17, both 33->33). A per-document visibility lookup would scale there.
  #
  # THE OTHER STATEMENT WAS PAID BACK, NOT PINNED. The clamp first cost +2: the
  # schema catalog re-resolved the SAME `{project_id, dataset}` pair that the
  # row read had just resolved, and this path passes no `memoize: true` (the
  # barkpark-sknf gate), so it was a real second `datasets` round-trip.
  # `get_documents_by_ids/3` now resolves once and hands the answer to the
  # clamp via `:resolved_dataset_id` — `datasets` is back at origin/main's 3.
  #
  # The remaining +1 is irreducible BY DESIGN: the allowlist is derived at READ
  # TIME so a schema flipped to private drops out on the very next read. Folding
  # it into the row query as a subquery would mean hand-rolling `public_schema?/1`
  # AND `list_schemas/2`'s dataset_id-first dedup precedence in SQL — a second
  # implementation of the exact rule this clamp exists to unify, and the shape
  # this repo's duplicated-predicate findings keep recurring through. One
  # statement is the honest price. The next unexplained +1 still reds.
  @dead_leg_budget 17
  @both_legs_budget 33
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
  # Copied from graph_controller_test.exs `count_repo_queries` — the
  # pid-filter-FREE shape (attach, send from ANY process, detach, drain),
  # extended with the per-source split (`meta[:source]` from Ecto telemetry).

  defp count_repo_queries(fun) do
    ref = make_ref()
    test_pid = self()
    handler_id = {:reader_query_counter, ref}

    :telemetry.attach(
      handler_id,
      [:barkpark, :repo, :query],
      # NO pid filter here — see @moduledoc. The handler executes in the
      # query-issuing process (test pid on the dead leg, the LiveView process
      # on the connected leg) and reports unconditionally.
      fn _event, _measurements, meta, _cfg -> send(test_pid, {ref, :query, meta[:source]}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain_counts(ref, {0, %{}})
  end

  defp drain_counts(ref, {count, per_source}) do
    receive do
      {^ref, :query, source} ->
        key = source || "(no source)"
        drain_counts(ref, {count + 1, Map.update(per_source, key, 1, &(&1 + 1))})
    after
      0 -> {count, per_source}
    end
  end

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

    {count, _} = drain_counts(ref, {0, %{}})
    count
  end

  # ── the pinned fixture ──────────────────────────────────────────────────────

  # Build the three-shape fixture around a unique slug; `citing_tasks` scales
  # ONLY the driven-task shape (for the N+1 slope test). Titles are genuinely
  # distinct — the publish-time dedup wall refuses near-duplicates at 0.71
  # similarity — and every fixture paper carries a body block (the paper
  # quality gate refuses heading-only papers).
  defp seed_fixture!(scope, opts \\ []) do
    citing_tasks = Keyword.get(opts, :citing_tasks, 1)
    uniq = System.unique_integer([:positive])
    slug = "rqb-target-#{uniq}"
    epic = "rqb-epic-#{uniq}"

    # 1 live task-list block matching 2 tasks (distinct titles).
    for title <- ["Collect crawler samples #{uniq}", "Publish robots verdict #{uniq}"] do
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

    title_offset = Keyword.get(opts, :title_offset, 0)

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

  defp dead_leg(conn, slug) do
    count_repo_queries(fn ->
      conn |> get("/papers/#{slug}") |> html_response(200)
    end)
  end

  defp both_legs(conn, slug) do
    count_repo_queries(fn ->
      {:ok, _view, _html} = live(conn, "/papers/#{slug}")
    end)
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
      assert html =~ "Linked mentions"
      assert html =~ "Driven tasks"
      assert html =~ "Collect crawler samples"

      assert dead <= @dead_leg_budget,
             "dead leg blew the budget: #{dead} > #{@dead_leg_budget} " <>
               "(per-source: #{inspect(dead_sources)})"

      assert both <= @both_legs_budget,
             "both legs blew the budget: #{both} > #{@both_legs_budget} " <>
               "(per-source: #{inspect(both_sources)})"

      assert connected >= 0
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
end
