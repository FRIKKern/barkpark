defmodule Barkpark.Tasks.DedupTest do
  @moduledoc """
  DB-backed tests for the find-or-create gate (task-obsession layer 1), driven
  through the real `Content.create_document/4` write path so the Writer hook,
  the candidate query, and the escape hatches are all exercised end-to-end.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}

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

  defp create_task(doc_id, title, scope, content_extra) do
    content =
      Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content_extra)

    Content.create_document(
      "task",
      %{"doc_id" => doc_id, "title" => title, "content" => content},
      @dataset,
      scope
    )
  end

  @rate_limit "add rate limiting to the mutate controller"
  @rate_limit_desc "throttle writes on the REST mutate endpoint per token bucket"

  test "a near-duplicate cross-epic task is REFUSED with the similar list", %{scope: scope} do
    {:ok, _} =
      create_task("existing-rl", @rate_limit, scope, %{
        "description" => @rate_limit_desc,
        "parent_id" => "epic-a"
      })

    assert {:error, {:duplicate_task, payload}} =
             create_task("new-rl", @rate_limit, scope, %{
               "description" => @rate_limit_desc,
               "parent_id" => "epic-b"
             })

    assert [%{id: "existing-rl"} | _] = payload.similar
  end

  test "a same-parent sibling is ALLOWED even when lexically near-identical", %{scope: scope} do
    {:ok, _} =
      create_task("sib-1", @rate_limit, scope, %{
        "description" => @rate_limit_desc,
        "parent_id" => "shared-epic"
      })

    # Same parent → structural sibling → never a duplicate.
    assert {:ok, _} =
             create_task("sib-2", @rate_limit, scope, %{
               "description" => @rate_limit_desc,
               "parent_id" => "shared-epic"
             })
  end

  test "distinct_from naming the match ALLOWS the create and persists the trail", %{scope: scope} do
    {:ok, _} =
      create_task("orig-rl", @rate_limit, scope, %{
        "description" => @rate_limit_desc,
        "parent_id" => "epic-a"
      })

    assert {:ok, doc} =
             create_task("clone-rl", @rate_limit, scope, %{
               "description" => @rate_limit_desc,
               "parent_id" => "epic-b",
               "distinct_from" => ["orig-rl"]
             })

    # The escape hatch is persisted on the doc as the queryable rejection trail.
    assert doc.content["distinct_from"] == ["orig-rl"]
  end

  test "a genuinely distinct task is ALLOWED", %{scope: scope} do
    {:ok, _} =
      create_task("rl", @rate_limit, scope, %{
        "description" => @rate_limit_desc,
        "parent_id" => "epic-a"
      })

    assert {:ok, _} =
             create_task("reader", "render markdown headings in the article reader", scope, %{
               "description" => "heading rhythm and vertical spacing in the paper reader",
               "parent_id" => "epic-b"
             })
  end

  test "a CANCELLED task never blocks a legitimate re-attempt (criterion 4)", %{scope: scope} do
    {:ok, _} =
      create_task("abandoned-rl", @rate_limit, scope, %{
        "description" => @rate_limit_desc,
        "parent_id" => "epic-a",
        "lifecycle_status" => "cancelled"
      })

    # We decided not to do it → re-proposing the same work must be allowed.
    assert {:ok, _} =
             create_task("retry-rl", @rate_limit, scope, %{
               "description" => @rate_limit_desc,
               "parent_id" => "epic-b"
             })
  end

  test "a DONE task DOES still surface (already-landed signal)", %{scope: scope} do
    {:ok, _} =
      create_task("shipped-rl", @rate_limit, scope, %{
        "description" => @rate_limit_desc,
        "parent_id" => "epic-a",
        "lifecycle_status" => "done"
      })

    assert {:error, {:duplicate_task, payload}} =
             create_task("redo-rl", @rate_limit, scope, %{
               "description" => @rate_limit_desc,
               "parent_id" => "epic-b"
             })

    assert Enum.any?(payload.similar, &(&1.lifecycle_status == "done"))
  end

  # ── the gate SAYS WHAT IT COULD NOT DO ─────────────────────────────────────
  #
  # The 2026-07-30 outage: the candidate scan lost its race with the 15 s DB
  # checkout budget, the old code swallowed that into an empty candidate set,
  # and the create either sailed through unchecked or died as
  # `internal_error / "unknown error"`. Both are the same lie — a create
  # reporting success on a duplicate check that never ran.

  # A REAL, unmocked scan failure, driven through the production code path: the
  # candidate query is built with an unusable workspace scope, so `Repo.all`
  # raises before it can produce a candidate set. What matters is that the gate
  # cannot compute its answer — the same state the 15 s checkout timeout left it
  # in — and that it says so instead of returning an empty backlog.
  defp check_with_failing_scan(doc_id, title, content) do
    Barkpark.Tasks.Dedup.check_new_task(
      "task",
      %{"doc_id" => doc_id, "title" => title, "content" => content},
      @dataset,
      nil,
      workspace_id: "not-a-uuid-so-the-scan-cannot-run"
    )
  end

  describe "degraded candidate scan" do
    test "REFUSES with a message naming what could not be done — never a silent pass" do
      assert {:error, {:dedup_unavailable, message}} =
               check_with_failing_scan("deg-new", @rate_limit, %{
                 "kind" => "task",
                 "description" => @rate_limit_desc
               })

      # The body names the gate, the failure, the consequence and the way out.
      assert message =~ "task dedup gate could not complete"
      assert message =~ "the backlog scan"
      assert message =~ "REFUSED rather than filed unchecked"
      assert message =~ "no duplicate check ran"
      assert message =~ "content.dedup_bypass: true"
      refute message =~ "unknown error"
    end

    test "the refusal renders as a NAMED error body, not internal_error/unknown error" do
      assert {:error, {:dedup_unavailable, _}} =
               result = check_with_failing_scan("deg-env", @rate_limit, %{"kind" => "task"})

      env = Barkpark.Content.Errors.to_envelope(result)

      refute env.code == "internal_error"
      refute env.message == "unknown error"
      # 503, not the plugin-veto 409: a dedup outage is TRANSIENT, and the STATUS
      # is what tells an unattended caller (Github.Intake, a generic SDK retry
      # policy) to come back rather than treat the refusal as a permanent policy
      # decision and drop the row. The wire `code` still reads `halted` — a new
      # public code must be registered in known_codes/0, which drives both the
      # served OpenAPI enum and docs/api-v1.md §9 under a CI-enforced byte cap —
      # so the arm carries a `reason` discriminator and its OWN retry hint, and
      # the code rename stays filed on its own row.
      assert env.status == 503
      assert env.reason == "dedup_unavailable"
      assert env.hint =~ "Resend the identical request"

      # THE TRIPWIRE. `:halted` is the plugin-VETO tag, and consumers treat it
      # as deterministic: `Plugins.Github.Intake` answers a clean 2xx on
      # `{:error, {:halted, _}}` on the explicit reasoning that "GitHub
      # redelivery would only hit the same veto forever". A dedup outage is
      # TRANSIENT, so wearing that tag would make an unattended intake drop the
      # issue permanently and log it as a policy refusal that never happened.
      # If a future change borrows `:halted` here again, this reds.
      refute match?({:error, {:halted, _}}, result)
      assert env.message =~ "task dedup gate could not complete"
    end

    test "the bypass is an OWNER decision, not a server shortcut — it skips a real duplicate", %{
      scope: scope
    } do
      {:ok, _} =
        create_task("byp2-existing", @rate_limit, scope, %{
          "description" => @rate_limit_desc,
          "parent_id" => "epic-a"
        })

      # Same text, healthy scan: without the flag this is a hard refuse.
      assert {:error, {:duplicate_task, _}} =
               create_task("byp2-no-flag", @rate_limit, scope, %{
                 "description" => @rate_limit_desc,
                 "parent_id" => "epic-b"
               })

      assert {:ok, doc} =
               create_task("byp2-flag", @rate_limit, scope, %{
                 "description" => @rate_limit_desc,
                 "parent_id" => "epic-b",
                 "dedup_bypass" => true
               })

      # The flag persists on the document as the queryable trail — the same
      # shape as `distinct_from`, so "who waved this through" stays answerable.
      assert doc.content["dedup_bypass"] == true
    end
  end

  # ── bounded candidate fetch ────────────────────────────────────────────────

  # `Content.create_document/4` always writes a DRAFT (`drafts.<id>`), so a real
  # twin pair is a published row alongside its draft — the shape every
  # edited-then-published task on the live corpus has. Mirror the draft row into
  # a published one to build it.
  defp publish_twin_of!(%Barkpark.Content.Document{} = draft, published_id) do
    draft
    |> Map.from_struct()
    |> Map.drop([
      :__meta__,
      :id,
      :inserted_at,
      :updated_at,
      :search_vector,
      :task_edges,
      :tags_meta,
      :slug_text,
      :author_text,
      :category_text
    ])
    |> Map.merge(%{doc_id: published_id, status: "published"})
    |> then(&struct(Barkpark.Content.Document, &1))
    |> Barkpark.Repo.insert!()
  end

  # ── the candidate cap can no longer bind silently ──────────────────────────
  #
  # `@candidate_limit` bounds the backlog scan. On 2026-08-24 the eligible corpus
  # (7,064 distinct canonical ids) CROSSED that cap, so 2,064 ids — 29.2% — were
  # invisible to every dedup scan and the gate still answered `:ok`, reporting a
  # duplicate check it had only partly run.
  #
  # These tests drive the SAME condition at fixture scale through the production
  # code path, using the `:dedup_candidate_limit` override as the mutation lever:
  # a limit below the fixture corpus reproduces the live truncation exactly.
  #
  # WHAT CHANGED UNDER THEM. The cap no longer decides WHO gets checked by
  # alphabet. Candidates are trgm-pre-filtered and ranked by descending title
  # similarity before the limit applies, so a bind now drops the LEAST similar
  # rows rather than the alphabetically-last ones, and the 29.2% hole above is
  # closed — the index is consulted over the whole corpus instead of a sorted
  # prefix. The tests below therefore assert the cap's ORDERING, not just that it
  # announces itself.
  defp check_with_limit(doc_id, title, content, scope, limit) do
    Barkpark.Tasks.Dedup.check_new_task(
      "task",
      %{"doc_id" => doc_id, "title" => title, "content" => content},
      @dataset,
      nil,
      Keyword.put(scope, :dedup_candidate_limit, limit)
    )
  end

  describe "candidate cap truncation" do
    setup %{scope: scope} do
      # Three eligible rows. `a-…` and `b-…` are filler; `z-dupe` is a REAL
      # near-duplicate of the probe and sorts LAST under the scan's
      # `DISTINCT ON (canonical doc_id) ASC` key — the same construction that put
      # every live `task-*` id past the cut on guerrilla.
      #
      # THE FILLER TITLES ARE TUNED ON TWO AXES AT ONCE, and the test is vacuous
      # if either one is wrong.
      #
      #   1. TRIGRAM-NEAR the probe, so they clear @candidate_trgm_floor and are
      #      actually IN the candidate set the cap then cuts. A first draft used
      #      "rate limiting for the release notes generator …" — it shares two
      #      WORDS but few trigrams, so the pre-filter dropped both fillers, the
      #      candidate set was {z-dupe} alone, and every cap kept the duplicate
      #      no matter how it was ordered. The test passed while proving nothing:
      #      mutating the ORDER BY left it green.
      #   2. TOKEN-FAR, so they cannot themselves refuse. Once stopwords go, the
      #      probe scores {rate, limiting, mutate, controller} and each filler
      #      shares only {rate} out of a seven-token union — Jaccard 0.14, well
      #      under the 0.30 advise floor.
      #
      # Near-misspellings of the probe satisfy both: almost the same string,
      # almost none of the same words.
      {:ok, _} =
        create_task("a-filler-one", "add rate throttling to the mutation controllers", scope, %{})

      {:ok, _} =
        create_task("b-filler-two", "add rate limiters to the mutating controls", scope, %{})

      {:ok, _} =
        create_task("z-dupe", @rate_limit, scope, %{"description" => @rate_limit_desc})

      :ok
    end

    # THIS TEST USED TO ASSERT THE DEFECT, AND NOW ASSERTS ITS REPAIR.
    #
    # Its previous form was `a duplicate PAST the cap is not detected — the scan
    # is partial`: with the keep ordered by ascending canonical doc_id, a cap of
    # 2 kept `a-filler-one` and `b-filler-two` and dropped `z-dupe`, so the gate
    # answered a confident `:ok` about a backlog it had only partly read. That
    # was the live shape on guerrilla — 2,064 ids (29.2%) past the cut, including
    # 100% of the `task-*` ids `bp task create` mints by default.
    #
    # The trgm pre-filter ranks candidates by DESCENDING TITLE SIMILARITY before
    # the cap applies, so the rows a bind discards are now the LEAST similar
    # rather than the alphabetically-last. `z-dupe` is the most similar row in
    # the corpus, so it survives even the tightest possible cap. Alphabet no
    # longer decides who gets checked.
    test "the cap keeps the MOST SIMILAR row, not the alphabetically-first", %{scope: scope} do
      probe = %{"kind" => "task", "description" => @rate_limit_desc}

      # A cap of ONE. Under the old ascending-doc_id keep this window could only
      # ever hold `a-filler-one`; the duplicate sorted last and was unreachable.
      assert {:error, {:duplicate_task, payload}} =
               check_with_limit("probe-tightest-cap", @rate_limit, probe, scope, 1)

      assert Enum.any?(payload.similar, &(&1.id == "z-dupe")),
             "the single kept candidate must be the near-duplicate, not the alphabetic first"

      # THE CONTROL. Same corpus, same probe, cap lifted clear of everything: the
      # verdict is the same, so the refusal above is the ordering working, not a
      # lucky accident of a one-row window.
      assert {:error, {:duplicate_task, _}} =
               check_with_limit("probe-complete", @rate_limit, probe, scope, 50)
    end

    # CRITERION 1 — when the cap binds, the gate SAYS SO, by name, carrying both
    # rows-returned and the limit. A bound nobody can observe engaging is the
    # defect, not the number.
    test "the truncated scan WARNS with rows-returned and the limit", %{scope: scope} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          check_with_limit("probe-warn", @rate_limit, %{"kind" => "task"}, scope, 2)
        end)

      assert log =~ "Tasks.Dedup scan TRUNCATED"
      assert log =~ "returned 2"
      assert log =~ "limit 2"
      # The consequence, not just the counts: an `:ok` here is a narrower claim
      # than the one the caller would otherwise read it as.
      assert log =~ "PARTIAL candidate set"
      assert log =~ "not 'no duplicate'"
      # The warning must say what a bind MEANS now — most-title-similar kept, not
      # alphabetically-first — because the remedy changed with the ordering.
      assert log =~ "MOST"
      assert log =~ "@candidate_trgm_floor"
    end

    test "the truncation is COUNTABLE — telemetry carries returned and limit", %{scope: scope} do
      handler = "dedup-truncation-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:barkpark, :tasks, :dedup, :scan_truncated],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:truncated, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      check_with_limit("probe-telemetry", @rate_limit, %{"kind" => "task"}, scope, 2)

      assert_received {:truncated, %{returned: 2, limit: 2}, %{dataset: @dataset}}
    end

    # A scan that fit does NOT cry wolf. The probe row is the whole discriminator
    # between "the backlog is exactly `limit` rows" and "the backlog is bigger".
    test "a scan that FITS is silent and reports truncated: false", %{scope: scope} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:duplicate_task, payload}} =
                   check_with_limit(
                     "probe-fits",
                     @rate_limit,
                     %{"kind" => "task", "description" => @rate_limit_desc},
                     scope,
                     3
                   )

          # Exactly `limit` eligible rows exist. Without the +1 probe row this
          # case is indistinguishable from a truncation, and a naive
          # `length == limit` check would false-alarm on every one of them.
          assert payload.scan == %{
                   truncated: false,
                   candidates_scanned: 3,
                   candidate_limit: 3
                 }
        end)

      refute log =~ "Tasks.Dedup scan TRUNCATED"
    end

    # CRITERION 1, third channel — the ANSWER states the population it was
    # computed over, so a duplicate payload produced under a bound scan is not
    # mistaken for one produced over the whole backlog.
    test "the duplicate payload carries the scan population", %{scope: scope} do
      # A duplicate that sorts INSIDE the truncated window, so the scan both
      # binds AND still produces a verdict. (`dedup_bypass` is only how this row
      # gets filed past the gate it is a fixture for — it plays no part in the
      # scan that follows.)
      {:ok, _} =
        create_task("a-real-dupe", @rate_limit, scope, %{
          "description" => @rate_limit_desc,
          "dedup_bypass" => true
        })

      assert {:error, {:duplicate_task, payload}} =
               check_with_limit(
                 "probe-payload",
                 @rate_limit,
                 %{"kind" => "task", "description" => @rate_limit_desc},
                 scope,
                 2
               )

      assert payload.scan == %{truncated: true, candidates_scanned: 2, candidate_limit: 2}
    end

    # CRITERION 4 — the tripwire is not paid for with a detection hole. The rows
    # the scan DOES fetch are scored exactly as before; only the extra probe row
    # is new, and it is dropped before scoring.
    test "no detection regression: an in-range duplicate is still refused", %{scope: scope} do
      assert {:error, {:duplicate_task, payload}} =
               create_task("probe-default-limit", @rate_limit, scope, %{
                 "description" => @rate_limit_desc
               })

      assert Enum.any?(payload.similar, &(&1.id == "z-dupe"))
      assert payload.scan.truncated == false
    end
  end

  # ── the trgm candidate pre-filter ────────────────────────────────────────────
  #
  # WHY THIS EXISTS. `@query_timeout_ms` bounds `Repo.all/2` and nothing else, so
  # the pure-Elixir scoring loop that consumes the fetched rows ran under no
  # budget at all. MEASURED 2026-08-24 against guerrilla `production`: a gated
  # draft-only `bp task create` took 9.2–14.3 s while the same create carrying
  # `dedup_bypass` took 0.18–0.47 s — the gate was ~98% of a task birth — and
  # `Similarity.assess/3` benched at 6,217 ms over 5,000 real rows vs 89 ms over
  # 500. The remedy is to stop handing the scorer thousands of rows.
  #
  # Cost is not what these tests assert. Wall-clock on a shared host measures the
  # load, not the code (the same reason `similarity_test.exs` counts tokenize
  # events instead of milliseconds). What is asserted here is the MECHANISM that
  # produces the cost reduction — that unrelated rows never enter the candidate
  # set — plus, in both directions, that detection survived it.
  describe "trgm candidate pre-filter" do
    test "an unrelated task never enters the candidate set", %{scope: scope} do
      {:ok, _} =
        create_task("dupe-target", @rate_limit, scope, %{"description" => @rate_limit_desc})

      # Ten rows with no lexical relationship to the probe whatsoever. Before the
      # pre-filter every one of them was fetched, shaped and scored on every
      # single create; that is the work the live corpus had 7,000 of.
      #
      # Each carries its OWN subject rather than a numbered suffix: digits are
      # dropped as sub-3-character tokens, so "… delivery 1" and "… delivery 2"
      # tokenize IDENTICALLY, and the second would be refused as a duplicate of
      # the first before it ever reached the corpus.
      for subject <- ~w(
            bokbasen onixedit sheets webhooks presence
            scaffold codelist thumbnails changelog telemetry
          ) do
        {:ok, _} = create_task("unrelated-#{subject}", "audit the #{subject} surface", scope, %{})
      end

      assert {:error, {:duplicate_task, payload}} =
               create_task("probe-prefilter", @rate_limit, scope, %{
                 "description" => @rate_limit_desc
               })

      # The scan population is the assertion. 11 eligible rows exist; the scan
      # must have scored FAR fewer, and must still have found the one that
      # matters. An off-by-a-little here is fine — an unfiltered scan would read
      # all 11.
      assert payload.scan.candidates_scanned < 11,
             "the pre-filter did not engage: #{payload.scan.candidates_scanned} of 11 rows scanned"

      assert Enum.any?(payload.similar, &(&1.id == "dupe-target"))
    end

    # ARM A of the mutation proof. The pre-filter must not become a hole: a
    # genuine near-duplicate still has to be REFUSED through the new query.
    test "a genuine near-duplicate is still REFUSED through the pre-filtered query", %{
      scope: scope
    } do
      {:ok, _} =
        create_task("prefilter-incumbent", @rate_limit, scope, %{
          "description" => @rate_limit_desc,
          "parent_id" => "epic-a"
        })

      assert {:error, {:duplicate_task, payload}} =
               create_task("prefilter-newcomer", @rate_limit, scope, %{
                 "description" => @rate_limit_desc,
                 "parent_id" => "epic-b"
               })

      assert [%{id: "prefilter-incumbent"} | _] = payload.similar
    end

    # ARM B. A pre-filter that refused everything would pass arm A and still be
    # worthless, so the non-duplicate has to keep sailing through.
    #
    # THE NEWCOMER'S TITLE IS A NEAR-MISSPELLING OF THE INCUMBENT'S, ON PURPOSE.
    # An obviously-unrelated title ("render onix codelist 153 …") would be
    # dropped by the trgm net before scoring, so the create would succeed no
    # matter what the threshold said — the test would pass even with the refuse
    # threshold dropped to 0.0, proving nothing about the decision. A trigram-
    # near, token-far title keeps the candidate IN the set and forces the
    # THRESHOLD to be the thing that lets it through: shared tokens are {rate}
    # against a seven-token union, Jaccard 0.14, under the 0.30 advise floor.
    test "a candidate that IS scanned but scores below the threshold still PASSES", %{
      scope: scope
    } do
      {:ok, _} =
        create_task("prefilter-other", @rate_limit, scope, %{"description" => @rate_limit_desc})

      assert {:ok, _} =
               create_task(
                 "prefilter-distinct",
                 "add rate throttling to the mutation controllers",
                 scope,
                 %{"description" => "cap concurrent writes per workspace in the sync fanout"}
               )
    end

    # THE FAIL-OPEN GUARD. `similarity(x, '')` is 0 for every row, so `? % ?`
    # against an empty probe matches NOTHING — the scan would return an empty
    # candidate set, find no refusals, and report a clean bill of health on a
    # check it never ran. That is the exact silent-pass shape this module exists
    # to refuse, so a blank title falls back to the unfiltered scan.
    #
    # DRIVEN THROUGH `check_new_task/5` DIRECTLY, and through a planted row, for
    # the same reason the object-shaped-labels test below is: the authoring
    # quality gate refuses a blank title ("task title is required") before
    # `Content.create_document/4` ever reaches the dedup seam, so the write path
    # cannot construct this case. Anything calling the gate without that gate in
    # front of it — another plugin, an internal caller, a future write path —
    # still can, and for those the empty probe would match nothing and hand back
    # a clean bill of health it never computed.
    test "a BLANK title falls back to the full scan instead of matching nothing", %{scope: scope} do
      Barkpark.Repo.insert!(%Barkpark.Content.Document{
        doc_id: "blank-title-incumbent",
        type: "task",
        dataset: @dataset,
        status: "published",
        rev: Ecto.UUID.generate(),
        title: "",
        workspace_id: Keyword.fetch!(scope, :workspace_id),
        project_id: Keyword.fetch!(scope, :project_id),
        content: %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "description" => @rate_limit_desc
        }
      })

      assert {:error, {:duplicate_task, payload}} =
               Barkpark.Tasks.Dedup.check_new_task(
                 "task",
                 %{
                   "doc_id" => "blank-title-newcomer",
                   "title" => "",
                   "content" => %{"kind" => "task", "description" => @rate_limit_desc}
                 },
                 @dataset,
                 nil,
                 scope
               )

      assert Enum.any?(payload.similar, &(&1.id == "blank-title-incumbent")),
             "an empty trgm probe must fall back to the full scan, not match nothing"
    end
  end

  describe "candidate projection + twin collapse" do
    test "a draft/published TWIN pair is scored and reported ONCE, not twice", %{scope: scope} do
      {:ok, draft} =
        create_task("twin-rl", @rate_limit, scope, %{
          "description" => @rate_limit_desc,
          "parent_id" => "epic-a"
        })

      assert draft.doc_id == "drafts.twin-rl"
      published = publish_twin_of!(draft, "twin-rl")
      assert published.doc_id == "twin-rl"

      assert {:error, {:duplicate_task, payload}} =
               create_task("twin-new", @rate_limit, scope, %{
                 "description" => @rate_limit_desc,
                 "parent_id" => "epic-b"
               })

      # DISTINCT ON the drafts-stripped id: one row survives per task, and it is
      # the PUBLISHED one. Before the fix both rows were fetched and scored, and
      # `similar` carried the same task twice.
      assert Enum.count(payload.similar, &(&1.id == "twin-rl")) == 1
      assert [%{id: "twin-rl"}] = payload.similar
    end

    test "detection is unchanged for a task that exists ONLY as a draft", %{scope: scope} do
      # No published counterpart: the draft is the one surviving row and must
      # still block. Collapsing twins narrowed nothing.
      {:ok, draft} =
        create_task("only-draft-rl", @rate_limit, scope, %{
          "description" => @rate_limit_desc,
          "parent_id" => "epic-a"
        })

      assert draft.doc_id == "drafts.only-draft-rl"

      assert {:error, {:duplicate_task, payload}} =
               create_task("only-draft-new", @rate_limit, scope, %{
                 "description" => @rate_limit_desc,
                 "parent_id" => "epic-b"
               })

      # `present/1` reports the canonical id, so the drafts-only row shows up
      # under the id the author would reference.
      assert [%{id: "only-draft-rl"}] = payload.similar
    end

    test "the projected row still carries every scored field (labels included)", %{scope: scope} do
      {:ok, _} =
        create_task("proj-a", "alpha beta gamma delta", scope, %{
          "parent_id" => "epic-a",
          "labels" => ["proj:x", "phase:1"]
        })

      # Disjoint titles; only the labels can push this over the advise floor, so
      # a lost `labels` projection would make this create succeed.
      assert {:error, {:duplicate_task, payload}} =
               create_task("proj-b", "alpha beta gamma epsilon", scope, %{
                 "parent_id" => "epic-b",
                 "labels" => ["proj:x", "phase:1"]
               })

      assert [%{id: "proj-a"} | _] = payload.similar
    end
  end

  # ── tier-2 judge escalation ────────────────────────────────────────────────

  defmodule FakeJudge do
    def post(_url, _body, _headers) do
      case Application.get_env(:barkpark, :judge_fake) do
        {:ok, text} -> {:ok, 200, %{"content" => [%{"type" => "text", "text" => text}]}}
        {:error, r} -> {:error, r}
        other -> other
      end
    end
  end

  # A cross-epic pair with partial token overlap → lands in the ADVISE band
  # (sim ~0.42, below the 0.55 refuse floor), which is exactly where the judge
  # is consulted.
  @adv_title_a "alpha beta gamma delta"
  @adv_title_b "alpha beta gamma zeta"

  defp with_judge(fake) do
    Application.put_env(:barkpark, :judge_http_adapter, FakeJudge)
    Application.put_env(:barkpark, :anthropic_api_key, "sk-test")
    Application.put_env(:barkpark, :judge_fake, fake)

    on_exit(fn ->
      Application.delete_env(:barkpark, :judge_http_adapter)
      Application.delete_env(:barkpark, :anthropic_api_key)
      Application.delete_env(:barkpark, :judge_fake)
    end)
  end

  describe "tier-2 judge escalation" do
    test "a judged 'duplicate' escalates an advise-band match to a REFUSE", %{scope: scope} do
      with_judge({:ok, ~s({"relation":"duplicate","confidence":0.9,"reason":"same"})})
      {:ok, _} = create_task("adv-a", @adv_title_a, scope, %{"parent_id" => "epic-a"})

      assert {:error, {:duplicate_task, payload}} =
               create_task("adv-b", @adv_title_b, scope, %{"parent_id" => "epic-b"})

      assert Enum.any?(payload.similar, &(&1.id == "adv-a"))
    end

    test "a judged 'distinct' leaves the advise match non-blocking (create allowed)", %{
      scope: scope
    } do
      with_judge({:ok, ~s({"relation":"distinct","confidence":0.9,"reason":"different"})})
      {:ok, _} = create_task("adv-a2", @adv_title_a, scope, %{"parent_id" => "epic-a"})

      assert {:ok, _} = create_task("adv-b2", @adv_title_b, scope, %{"parent_id" => "epic-b"})
    end

    test "a judge error fails open — the advise match does not block", %{scope: scope} do
      with_judge({:error, :timeout})
      {:ok, _} = create_task("adv-a3", @adv_title_a, scope, %{"parent_id" => "epic-a"})

      assert {:ok, _} = create_task("adv-b3", @adv_title_b, scope, %{"parent_id" => "epic-b"})
    end

    test "low judge confidence does not escalate", %{scope: scope} do
      with_judge({:ok, ~s({"relation":"duplicate","confidence":0.4,"reason":"maybe"})})
      {:ok, _} = create_task("adv-a4", @adv_title_a, scope, %{"parent_id" => "epic-a"})

      assert {:ok, _} = create_task("adv-b4", @adv_title_b, scope, %{"parent_id" => "epic-b"})
    end
  end

  # ── a malformed backlog row must not take down creation for everyone ───────
  #
  # MEASURED LIVE 2026-08-01 (PDS wave 33): EVERY `type:task` create against
  # guerrilla was refused 409 `halted` with "the backlog scan failed
  # (Protocol.UndefinedError)", until callers learned to pass `dedup_bypass` —
  # which disables duplicate detection fleet-wide. The gate itself behaved
  # correctly: it failed CLOSED and named its own bypass. The defect was that a
  # single poisoned row could put the gate into that state for every caller.
  #
  # THE POISON: `fetch_candidates/2` projects `content->'labels'` as RAW JSONB
  # (every other projected field uses `->>`, which is always text-or-NULL). That
  # raw term is fed to `to_string/1`, which has no `String.Chars` implementation
  # for a map — so ONE task row whose `content.labels` holds objects instead of
  # strings raises `Protocol.UndefinedError` inside the scan.
  #
  # The row is planted with a direct `Repo.insert!` ON PURPOSE: the write path
  # would coerce it, and the whole point is a row that arrived through a
  # non-`bp` path (a migration, a restore, a hand-written INSERT).
  #
  # THE TITLE IS LOAD-BEARING, and it was not before. The candidate scan now
  # trgm-pre-filters on the title, so a planted row titled "poisoned backlog row"
  # would simply never be FETCHED when the probe below files "an unrelated new
  # task" — and every assertion in this describe block would pass without the
  # poison ever reaching the scan. A totality test that never sees the malformed
  # row proves nothing. So the planted title deliberately shares the probe's
  # opening words (trgm match -> the row IS scanned) while its scored tokens stay
  # far apart: the probe tokenizes to {unrelated} once stopwords go, against
  # {unrelated, poisoned, label, set} here, for a Jaccard of 0.25 — under the
  # 0.30 advise floor, so the create is still allowed on the merits.
  @poison_probe_title "an unrelated new task"

  defp plant_poisoned_row!(doc_id, labels, scope) do
    Barkpark.Repo.insert!(%Barkpark.Content.Document{
      doc_id: doc_id,
      type: "task",
      dataset: @dataset,
      status: "published",
      rev: Ecto.UUID.generate(),
      title: @poison_probe_title <> " with a poisoned label set",
      workspace_id: Keyword.fetch!(scope, :workspace_id),
      project_id: Keyword.fetch!(scope, :project_id),
      content: %{
        "kind" => "task",
        "lifecycle_status" => "open",
        "description" => "a row written through a non-bp path",
        "labels" => labels
      }
    })
  end

  describe "a malformed candidate row" do
    # The exact live shape: `labels` holding weighted-tag OBJECTS (the same
    # shape `content.tags` legitimately carries) instead of bare strings.
    @poison_shapes %{
      "a list of objects" => [%{"tag" => "pds", "strength" => 86}],
      "a bare object" => %{"tag" => "pds"},
      "a list mixing strings and objects" => ["pds", %{"tag" => "elixir"}]
    }

    for {label, shape} <- @poison_shapes do
      @shape shape
      @label label

      test "#{label} in content.labels does NOT take the gate down", %{scope: scope} do
        plant_poisoned_row!("poison-#{:erlang.phash2(@label)}", @shape, scope)

        # THE REGRESSION. Before the fix this was
        # {:error, {:dedup_unavailable, "... the backlog scan failed
        # (Protocol.UndefinedError) ..."}} — for EVERY caller, on every create,
        # regardless of what the caller sent.
        # NON-VACUITY. The assertion that matters is not just "the create
        # succeeded" — it is "the create succeeded WITH the poisoned row in the
        # candidate set". The malformed-labels warning naming this doc_id is the
        # proof the scan reached it; without that, a pre-filter that dropped the
        # row would look identical to a gate that survived it.
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert {:ok, _} =
                     create_task(
                       "clean-#{:erlang.phash2(@label)}",
                       @poison_probe_title,
                       scope,
                       %{"description" => "nothing like the poisoned row"}
                     )
          end)

        assert log =~ "poison-#{:erlang.phash2(@label)}",
               "the poisoned row never entered the candidate set — this test is vacuous"
      end
    end

    test "the malformed row is REPORTED by doc_id, not silently swallowed", %{scope: scope} do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          plant_poisoned_row!("poison-reported", [%{"tag" => "pds"}], scope)

          assert {:ok, _} =
                   create_task("clean-reported", @poison_probe_title, scope, %{
                     "description" => "nothing like the poisoned row"
                   })
        end)

      # Resilience must not become a blind spot: the scan survives the row AND
      # says which row it was, so the poison can be found and fixed at source.
      assert log =~ "poison-reported"
      assert log =~ "labels"
    end

    test "the poisoned row still PARTICIPATES in detection — it is not dropped", %{scope: scope} do
      # A row with unusable labels keeps its title/description signal, which is
      # 0.7 of the score. Degrading `labels` must not amount to deleting the row
      # from the backlog: that would silently punch a hole in dedup coverage.
      Barkpark.Repo.insert!(%Barkpark.Content.Document{
        doc_id: "poison-dup",
        type: "task",
        dataset: @dataset,
        status: "published",
        rev: Ecto.UUID.generate(),
        title: @rate_limit,
        workspace_id: Keyword.fetch!(scope, :workspace_id),
        project_id: Keyword.fetch!(scope, :project_id),
        content: %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "description" => @rate_limit_desc,
          "parent_id" => "epic-a",
          "labels" => [%{"tag" => "pds"}]
        }
      })

      assert {:error, {:duplicate_task, payload}} =
               create_task("poison-dup-new", @rate_limit, scope, %{
                 "description" => @rate_limit_desc,
                 "parent_id" => "epic-b"
               })

      assert Enum.any?(payload.similar, &(&1.id == "poison-dup"))
    end

    # The SECOND hole, same root cause, different blast radius. `string_list/1`
    # also runs over the NEW task's own content in `to_task/2` — which is
    # OUTSIDE `fetch_candidates/2`'s rescue. There the same `to_string/1` on a
    # map was an UNHANDLED raise, i.e. a 500, not a named refusal. MEASURED on
    # the pre-fix tree, verbatim:
    #
    #   ** (Protocol.UndefinedError) protocol String.Chars not implemented for Map
    #       (barkpark) lib/barkpark/tasks/dedup.ex:287: Barkpark.Tasks.Dedup.to_task/2
    #
    # It is driven through `check_new_task/5` DIRECTLY on purpose:
    # `Content.create_document/4` normalises content against the schema first,
    # so the write path never delivered this shape and the hole was invisible
    # from there. Anything calling the gate without that normalisation — another
    # plugin, an internal caller, a future write path — got the 500.
    test "a CALLER's own object-shaped labels do not raise out of the gate", %{scope: scope} do
      assert :ok =
               Barkpark.Tasks.Dedup.check_new_task(
                 "task",
                 %{
                   "doc_id" => "caller-poison",
                   "title" => "a task with object labels",
                   "content" => %{
                     "kind" => "task",
                     "description" => "labels arrived as weighted-tag objects",
                     "labels" => [%{"tag" => "pds", "strength" => 86}]
                   }
                 },
                 @dataset,
                 nil,
                 scope
               )
    end
  end

  # ── the upsert INSERT branch (pds-bl-upsert-insert-branch-ungated-birth) ──
  #
  # `do_upsert_document` has its own insert branch (prev_doc nil -> Repo.insert)
  # and its `with` chain used to call NEITHER dedup arm — run-proven on the
  # pre-fix tree: `Content.create_document` REFUSED a near-duplicate
  # ({:error, {:duplicate_task, _}}) while `Content.upsert_document` on the
  # SAME attrs and an unseen doc_id BIRTHED it (drafts.probe-dup-upsert
  # persisted). These pin the gate now riding that branch.
  describe "upsert insert-branch birth gate" do
    @up_title "add rate limiting to the mutate controller"
    @up_desc "throttle writes on the REST mutate endpoint per token bucket"

    test "an upsert onto an UNSEEN doc_id is a birth and the duplicate is REFUSED", %{
      scope: scope
    } do
      {:ok, _} =
        create_task("up-existing", @up_title, scope, %{
          "description" => @up_desc,
          "parent_id" => "epic-a"
        })

      assert {:error, {:duplicate_task, payload}} =
               Content.upsert_document(
                 "task",
                 %{
                   "doc_id" => "up-dup",
                   "title" => @up_title,
                   "content" => %{
                     "kind" => "task",
                     "lifecycle_status" => "open",
                     "description" => @up_desc,
                     "parent_id" => "epic-b"
                   }
                 },
                 @dataset,
                 scope
               )

      assert [%{id: "up-existing"} | _] = payload.similar

      # Nothing was born: neither the draft nor a published twin exists.
      assert {:error, :not_found} =
               Content.get_document("drafts.up-dup", "task", @dataset, scope)
    end

    test "an upsert onto a LIVE row is an update and stays ungated (autosave parity)", %{
      scope: scope
    } do
      {:ok, _} =
        create_task("up-live", @up_title, scope, %{
          "description" => @up_desc,
          "parent_id" => "epic-a"
        })

      # Same near-duplicate text, but prev_doc resolves — the guard head-matches
      # prev_doc == nil and must not fire on an update.
      assert {:ok, doc} =
               Content.upsert_document(
                 "task",
                 %{
                   "doc_id" => "up-live",
                   "title" => @up_title,
                   "content" => %{
                     "kind" => "task",
                     "lifecycle_status" => "open",
                     "description" => @up_desc <> " (edited)",
                     "parent_id" => "epic-a"
                   }
                 },
                 @dataset,
                 scope
               )

      assert doc.content["description"] =~ "(edited)"
    end
  end
end
