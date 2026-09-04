defmodule Barkpark.SheetsM1ProofTest do
  @moduledoc """
  Independent end-to-end proof of the Sheets M1 realtime contract — two
  colleagues edit the same budget sheet at the same time while a dashboard
  watches live. Driven over the HTTP surface wherever one exists; deliberately
  overlaps zero fixtures with the builders' M1 tests.

  The story:

    1. `POST /v1/data/mutate/production` creates the "Budsjett" sheet (a few
       numbers + an `E1 = SUM(B1:C20)` total) via the mutation envelope, and
       `POST /v1/plugins/bulldocs/papers` embeds it in a dashboard paper.
    2. Watcher W subscribes to the delta stream the way an external consumer
       must: `Phoenix.PubSub` on `Session.topic/3` (the doc topic suffixed
       `":sheets:op"`). The `/v1/data/listen/:dataset` SSE stream does NOT
       carry sheets:op events — `ListenController` subscribes the
       `documents:*` topics and forwards only `{:document_changed, …}` — so W
       ALSO subscribes `documents:production` to prove at runtime that (a) no
       per-op delta rides the SSE topic (exact-once revs while
       dual-subscribed) and (b) the debounced persist DOES land there.
    3. Actors A and B (`Task.async` HTTP clients) POST interleaved op batches
       to `/v1/plugins/sheets/:slug/ops` — A fills B1..B20, B fills C1..C20,
       both write the shared cell D1 last.
    4. Asserts: deltas from BOTH actors — one coalesced delta per posted batch,
       revs strictly monotonic and duplicate-free, ending exactly at 42; D1
       ends as exactly ONE actor's
       whole value (LWW); the =SUM total arrived in deltas recomputed to the
       final grid's value; after the debounce the persisted doc
       (`GET /v1/data/doc/...`) equals the in-session state cell-for-cell;
       the embedding paper's HTML shows the final SUM.
    5. Timing: a single op's op->delta latency stays under 500ms.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Plugins.Sheets.Session

  # Papers resolve publicly only in dataset "production" (the write-through
  # targets same-scope embeds only), so the whole story lives there.
  @dataset "production"
  @sheet_id "sheet-m1-proof-budsjett"
  @draft_id "drafts." <> @sheet_id
  @paper_slug "sheets-m1-proof-dashboard"

  # Fresh write token for mutate/read; fixed ingest secret from config/test.exs.
  @write_token "sheets-m1-proof-write-token"
  @ingest_token "barkpark-test-ingest-token"

  # Publish-wall labels (charter D26/D39): the ingest enforces the wall, so the
  # dashboard-paper POST must carry registered weighted tags + a description.
  @wall_tag_names ~w(m1-proof-budget m1-proof-live m1-proof-dashboard)
  @wall_tags [
    %{
      "tag" => "m1-proof-budget",
      "strength" => 88,
      "rationale" => "Primary label: the live budget dashboard proof paper."
    },
    %{
      "tag" => "m1-proof-live",
      "strength" => 52,
      "rationale" => "Secondary label: two-colleague live-edit coverage."
    },
    %{
      "tag" => "m1-proof-dashboard",
      "strength" => 19,
      "rationale" => "Tertiary label: sheet-embed dashboard fixture."
    }
  ]
  @wall_description "M1 proof fixture dashboard paper embedding a live budget sheet for the wall."

  @rows 20
  @batch_rows 4
  # 40 fill ops + one D1 write per actor.
  @total_ops 2 * @rows + 2
  # B-column 10·i + C-column 7·i over i = 1..20.
  @final_sum 17 * div(@rows * (@rows + 1), 2)

  setup do
    Barkpark.TenancyFixtures.ensure_default_scope!()
    Barkpark.LabelFixtures.register_tags!(@dataset, @wall_tag_names)
    Barkpark.Auth.create_token(@write_token, "m1-proof", @dataset, ["read", "write"])

    stop_all_sessions()

    # Persistence purely debounce-driven (no mid-stream count flush), short
    # enough to observe inside the test; idle-stop long so no session dies
    # mid-story.
    Application.put_env(:barkpark, Barkpark.Plugins.Sheets.Session,
      debounce_ms: 300,
      flush_after_ops: 1_000,
      idle_stop_ms: 60_000
    )

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    :ok
  end

  defp stop_all_sessions do
    for {_, pid, _, _} <-
          DynamicSupervisor.which_children(Barkpark.Plugins.Sheets.SessionSupervisor),
        is_pid(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # ── HTTP helpers (fresh conn per request — actors run in Tasks) ──────────

  defp mutate(mutations) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> @write_token)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp ingest_paper(body) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> @ingest_token)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/plugins/bulldocs/papers", Jason.encode!(body))
  end

  # Explicit JSON body: Phoenix.ConnTest's map-params encoding would
  # stringify the numeric raws — and strings don't participate in SUM ranges,
  # so the 3570 assertion doubles as a type-preservation check.
  defp ops_post(ops) do
    resp =
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> @ingest_token)
      |> put_req_header("content-type", "application/json")
      |> post(
        "/v1/plugins/sheets/#{@sheet_id}/ops",
        Jason.encode!(%{"ops" => ops, "dataset" => @dataset})
      )

    assert resp.status == 200
    Jason.decode!(resp.resp_body)
  end

  defp persisted_cells do
    resp =
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> @write_token)
      |> get("/v1/data/doc/#{@dataset}/sheet/#{@draft_id}")

    case resp.status do
      200 ->
        # The v1 envelope FLATTENS doc.content to the top level of "result".
        resp.resp_body
        |> Jason.decode!()
        |> get_in(["result", "tabs", Access.at(0), "cells"])

      _ ->
        nil
    end
  end

  defp read_paper do
    scoped_conn() |> get("/papers/#{@paper_slug}") |> html_response(200)
  end

  defp op(ref, raw), do: %{"op" => "set_cell", "tab" => 0, "ref" => ref, "raw" => raw}

  # ── actors + watcher plumbing ─────────────────────────────────────────────

  # One colleague: fills `col`1..20 with factor·row in batches of 4, sleeping
  # between batches so the two actors' batches interleave, then writes the
  # shared D1 last. Returns the op receipts.
  defp actor(col, factor, d1_value) do
    fill_receipts =
      for rows <- Enum.chunk_every(1..@rows, @batch_rows) do
        ops = for r <- rows, do: op("#{col}#{r}", factor * r)
        receipt = ops_post(ops)

        assert receipt["ok"] == true
        assert receipt["applied"] == length(ops)
        assert receipt["errors"] == []

        Process.sleep(8)
        receipt
      end

    d1_receipt = ops_post([op("D1", d1_value)])
    assert d1_receipt["applied"] == 1

    fill_receipts ++ [d1_receipt]
  end

  defp collect_deltas(acc, target_rev) do
    receive do
      {:sheets_op, %{rev: rev} = delta} when rev >= target_rev ->
        Enum.reverse([delta | acc])

      {:sheets_op, delta} ->
        collect_deltas([delta | acc], target_rev)
    after
      10_000 ->
        flunk(
          "delta stream stalled before rev #{target_rev}; got " <>
            inspect(acc |> Enum.reverse() |> Enum.map(& &1.rev))
        )
    end
  end

  # Which colleague produced a delta: fills carry a B-/C-column ref, the two
  # D1-only deltas disambiguate by value. CondClauseError on anything else —
  # an unclassifiable delta is itself a failure.
  defp delta_actor(changed) do
    keys = Map.keys(changed)

    cond do
      Enum.any?(keys, &Regex.match?(~r/^B\d+$/, &1)) -> :a
      Enum.any?(keys, &Regex.match?(~r/^C\d+$/, &1)) -> :b
      match?(%{"D1" => %{"v" => "sist-fra-A"}}, changed) -> :a
      match?(%{"D1" => %{"v" => "sist-fra-B"}}, changed) -> :b
    end
  end

  defp wait_until(fun, timeout) do
    do_wait_until(fun, System.monotonic_time(:millisecond) + timeout)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met in time")

      true ->
        Process.sleep(100)
        do_wait_until(fun, deadline)
    end
  end

  # ── the story ─────────────────────────────────────────────────────────────

  test "two colleagues edit the budget live; a watcher and a paper see one truth" do
    # 1 — CREATE the sheet over the mutation envelope: a header, two seed
    # numbers (overwritten live below) and the =SUM total.
    resp =
      mutate([
        %{
          "create" => %{
            "_id" => @sheet_id,
            "_type" => "sheet",
            "title" => "M1 proof budsjett",
            "content" => %{
              "locale" => "nb-NO",
              "tabs" => [
                %{
                  "name" => "Budsjett",
                  "frozen_rows" => 0,
                  "cells" => %{
                    "A1" => %{"v" => "Budsjett 2026"},
                    "B1" => %{"v" => 100},
                    "C1" => %{"v" => 50},
                    "E1" => %{"f" => "SUM(B1:C20)"}
                  }
                }
              ]
            }
          }
        }
      ])

    assert resp.status == 200

    assert [%{"operation" => "create", "id" => @draft_id}] =
             Jason.decode!(resp.resp_body)["results"]

    # …and EMBED it in the dashboard paper (published-id ref, M0 contract).
    resp =
      ingest_paper(%{
        "slug" => @paper_slug,
        "tags" => @wall_tags,
        "description" => @wall_description,
        "blocks" => [
          %{
            "id" => "p1",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Budsjettet oppdateres live."}]
          },
          %{"id" => "s0", "type" => "sheet", "ref" => @sheet_id, "tab" => 0}
        ]
      })

    assert resp.status == 200

    # Ingest hydrated the embed from the sheet's CURRENT state (M0a) — the
    # final sum can only appear after the ops below land and persist.
    refute read_paper() =~ ">#{@final_sum}</td>"

    # 2 — WATCHER: external consumers get sheets:op deltas via Phoenix.PubSub
    # on Session.topic/3, NOT via the /v1/data/listen SSE stream (the
    # ListenController subscribes documents:* and forwards only
    # {:document_changed, …}). Dual-subscribe to prove the topic split live.
    :ok = Phoenix.PubSub.subscribe(Barkpark.PubSub, Session.topic(@sheet_id, @dataset, nil))
    :ok = Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{@dataset}")

    # 3 — ACTORS: two concurrent HTTP clients, interleaved batches, shared D1.
    [receipts_a, receipts_b] =
      Task.await_many(
        [
          Task.async(fn -> actor("B", 10, "sist-fra-A") end),
          Task.async(fn -> actor("C", 7, "sist-fra-B") end)
        ],
        30_000
      )

    # Receipts: every op applied, per-actor revs strictly increasing, the
    # session's monotonic counter ends at exactly 42.
    all_receipts = receipts_a ++ receipts_b
    assert Enum.sum(Enum.map(all_receipts, & &1["applied"])) == @total_ops
    assert Enum.max(Enum.map(all_receipts, & &1["rev"])) == @total_ops

    for receipts <- [receipts_a, receipts_b] do
      revs = Enum.map(receipts, & &1["rev"])
      assert revs == revs |> Enum.sort() |> Enum.uniq()
    end

    # 4 — the watcher's view of the stream.
    deltas = collect_deltas([], @total_ops)

    # Batch-coalescing: each `apply_ops` call recomputes its tab ONCE and
    # broadcasts ONE delta at the batch's final rev (not one per op). So the
    # watcher sees a strictly monotonic, duplicate-free rev sequence — one
    # delta per posted batch — ending exactly at 42. Monotonic uniqueness plus
    # the refute below (dual-subscribed) proves the deltas do NOT also ride the
    # documents:* topic the SSE stream serves.
    revs = Enum.map(deltas, & &1.rev)
    assert revs == Enum.sort(revs)
    assert revs == Enum.uniq(revs)
    assert List.last(revs) == @total_ops
    # One coalesced delta per posted batch: ⌈rows/batch_rows⌉ fill batches + 1
    # D1 write, per actor.
    assert length(deltas) == 2 * (div(@rows + @batch_rows - 1, @batch_rows) + 1)
    refute_received {:sheets_op, _}

    # Per-op writes never hit the doc store before the debounce: no
    # SSE-visible {:document_changed, …} for the sheet yet.
    refute_received {:document_changed, %{doc_id: @draft_id}}

    # Deltas came from BOTH actors, interleaved. A fully serial schedule
    # would show exactly one actor switch; concurrency shows many.
    actors = Enum.map(deltas, &delta_actor(&1.changed))
    assert :a in actors and :b in actors

    switches =
      actors |> Enum.chunk_every(2, 1, :discard) |> Enum.count(fn [x, y] -> x != y end)

    assert switches >= 2,
           "expected interleaved actors, got #{switches} switch(es): #{inspect(actors)}"

    # Every fill landed in some delta.
    seen_refs = deltas |> Enum.flat_map(&Map.keys(&1.changed)) |> MapSet.new()
    for r <- 1..@rows, ref <- ["B#{r}", "C#{r}"], do: assert(ref in seen_refs)

    # The =SUM total rode the deltas, recomputed — its last appearance (the
    # final fill op; D1 is outside the range) matches the finished grid.
    e1_deltas = for %{changed: %{"E1" => cell}} <- deltas, do: cell
    assert e1_deltas != []
    assert List.last(e1_deltas) == %{"f" => "SUM(B1:C20)", "v" => @final_sum, "t" => "n"}

    # D1: both whole writes broadcast; the LAST one is the LWW winner.
    d1_values = for %{changed: %{"D1" => %{"v" => v}}} <- deltas, do: v
    assert Enum.sort(d1_values) == ["sist-fra-A", "sist-fra-B"]
    winner = List.last(d1_values)

    # 5 — TIMING: realtime means realtime — one op, delta in the watcher's
    # hands inside 500ms.
    t0 = System.monotonic_time(:millisecond)
    receipt = ops_post([op("F1", 999)])
    assert receipt["applied"] == 1

    assert_receive {:sheets_op, %{rev: rev, changed: %{"F1" => %{"v" => 999}}}}, 500
    latency_ms = System.monotonic_time(:millisecond) - t0
    assert rev == @total_ops + 1
    assert latency_ms < 500, "op->delta latency was #{latency_ms}ms"
    IO.puts("[m1-proof] op->delta latency: #{latency_ms}ms")

    # 6 — ONE TRUTH: the expected final grid, built independently.
    expected =
      %{
        "A1" => %{"v" => "Budsjett 2026"},
        "D1" => %{"v" => winner},
        "E1" => %{"f" => "SUM(B1:C20)", "v" => @final_sum, "t" => "n"},
        "F1" => %{"v" => 999}
      }
      |> Map.merge(for r <- 1..@rows, into: %{}, do: {"B#{r}", %{"v" => 10 * r}})
      |> Map.merge(for r <- 1..@rows, into: %{}, do: {"C#{r}", %{"v" => 7 * r}})

    assert winner in ["sist-fra-A", "sist-fra-B"]

    # In-session state matches it cell-for-cell…
    {:ok, content} = Session.peek(@sheet_id, @dataset)
    assert get_in(content, ["tabs", Access.at(0), "cells"]) == expected

    # …and after the debounce window the PERSISTED doc (over HTTP) does too.
    wait_until(fn -> persisted_cells() == expected end, 6_000)

    # The debounced persist is what the SSE stream's consumers see.
    assert_receive {:document_changed, %{doc_id: @draft_id, type: "sheet"}}, 1_000

    # 7 — the dashboard paper. The live ops persisted to the DRAFT sheet, so
    # the PUBLISHED paper stays frozen — a draft autosave must never publish
    # draft cell values to anonymous /papers readers (the draft-content
    # boundary). The final SUM is invisible in the reader…
    refute read_paper() =~ ">#{@final_sum}</td>"

    # …until the sheet itself is PUBLISHED, which routes the now-published grid
    # back through the embed write-through and refreshes the paper's snapshot.
    assert mutate([%{"publish" => %{"id" => @sheet_id, "type" => "sheet"}}]).status == 200

    wait_until(fn -> read_paper() =~ ">#{@final_sum}</td>" end, 6_000)
    html = read_paper()
    assert html =~ "Budsjettet oppdateres live."
    assert html =~ ">Budsjett 2026</td>"
    assert html =~ ">#{@final_sum}</td>"
    assert html =~ ">#{winner}</td>"
    # Last fills of each column (B20 = 200, C20 = 140).
    assert html =~ ">200</td>"
    assert html =~ ">140</td>"
  end
end
