defmodule Barkpark.Sync.PusherTest do
  @moduledoc """
  The core PUSH seam, tested directly through the pure `Pusher.drain/3` with an
  INJECTED transport (invariant #7 — no network, no sleeps). Covers: happy-path
  cursor + doc-rev ledger advance; CAS conflict PRESERVES the loser and advances
  WITHOUT overwriting the remote (invariant #5); transient halt does NOT advance
  (invariant #3); phantom double-push reconciles without a conflict; task
  reconcile via the claim/epoch contract, NOT a content merge (invariant #6).
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Sync.{Pusher, PushConflict, PushCursor, PushDocRev}

  @dataset "test"

  test "mutate_url is SCOPED to /w/<ws>/p/<proj> (regression: live run caught the flat URL)" do
    ctx = %{
      url: "https://api.barkpark.cloud",
      workspace: "gyldendal",
      project: "default",
      dataset: "production"
    }

    assert Pusher.mutate_url(ctx) ==
             "https://api.barkpark.cloud/w/gyldendal/p/default/v1/data/mutate/production"
  end

  setup do
    %{source: "push-#{System.unique_integer([:positive])}", dataset: @dataset}
  end

  defp ctx(source), do: %{source: source, dataset: @dataset}

  defp doc_event(id, doc_id, rev, opts \\ []) do
    %MutationEvent{
      id: id,
      dataset: @dataset,
      type: Keyword.get(opts, :type, "post"),
      doc_id: doc_id,
      mutation: Keyword.get(opts, :mutation, "create"),
      rev: rev,
      document: Keyword.get(opts, :document, %{"_id" => doc_id, "_type" => "post", "_rev" => rev})
    }
  end

  # A recording push_fun that forwards every call to the test process so we can
  # assert WHICH ids were pushed (and prove an id is NOT re-pushed).
  defp recording_push(test_pid, reply_fun) do
    fn _ctx, event, base ->
      send(test_pid, {:pushed, event.id, base})
      reply_fun.(event)
    end
  end

  test "happy path: acks advance the cursor to max id and update the doc-rev ledger",
       %{source: source} do
    test_pid = self()
    events = [doc_event(1, "a", "ra"), doc_event(2, "b", "rb"), doc_event(3, "c", "rc")]

    push = recording_push(test_pid, fn ev -> {:ok, "remote-#{ev.doc_id}"} end)
    funs = %{push_fun: push, claim_fun: nil, close_fun: nil}

    {results, cursor} = Pusher.drain(events, ctx(source), funs)

    assert results == [
             {1, {:ok, "remote-a"}},
             {2, {:ok, "remote-b"}},
             {3, {:ok, "remote-c"}}
           ]

    assert cursor == 3
    assert PushCursor.get(source, @dataset) == 3
    assert PushDocRev.get(source, @dataset, "a") == "remote-a"
    assert PushDocRev.get(source, @dataset, "b") == "remote-b"
    assert PushDocRev.get(source, @dataset, "c") == "remote-c"

    assert_received {:pushed, 1, nil}
    assert_received {:pushed, 2, nil}
    assert_received {:pushed, 3, nil}
  end

  test "CAS conflict PRESERVES the loser, advances, never overwrites the remote, no re-push",
       %{source: source} do
    test_pid = self()
    # intended rev "rx"; remote reports a DIFFERENT actual "r-other" → a TRUE conflict.
    event = doc_event(7, "x", "rx")

    push =
      recording_push(test_pid, fn _ev ->
        {:error, {:rev_mismatch, %{expected: "rbase", actual: "r-other"}}}
      end)

    funs = %{push_fun: push, claim_fun: nil, close_fun: nil}

    {results, cursor} = Pusher.drain([event], ctx(source), funs)

    assert results == [{7, {:conflict, :rev_mismatch}}]
    # advanced PAST the conflict (write-then-advance)…
    assert cursor == 7
    assert PushCursor.get(source, @dataset) == 7

    # …the loser is PRESERVED durably with the full local envelope.
    assert [row] = PushConflict.list_open(source, @dataset)
    assert row.event_id == 7
    assert row.kind == "rev_mismatch"
    assert row.local_document["_id"] == "x"
    assert row.expected_remote_rev == "rbase"
    assert row.actual_remote_rev == "r-other"

    # The remote was NOT overwritten: the doc-rev ledger holds no winning rev.
    assert PushDocRev.get(source, @dataset, "x") == nil

    # Pushed exactly once — never re-attempted within the drain.
    assert_received {:pushed, 7, _}
    refute_received {:pushed, 7, _}
  end

  test "transient halt does NOT advance the cursor; replay resumes from the failed event",
       %{source: source} do
    test_pid = self()
    events = [doc_event(1, "a", "ra"), doc_event(2, "b", "rb"), doc_event(3, "c", "rc")]

    push =
      recording_push(test_pid, fn
        %{id: 2} -> {:error, :transient}
        ev -> {:ok, "remote-#{ev.doc_id}"}
      end)

    funs = %{push_fun: push, claim_fun: nil, close_fun: nil}

    {results, cursor} = Pusher.drain(events, ctx(source), funs)

    assert results == [{1, {:ok, "remote-a"}}, {2, {:error, :transient}}]
    # cursor stuck at the last SUCCESS (1), never past the un-pushed event 2.
    assert cursor == 1
    assert PushCursor.get(source, @dataset) == 1

    # event 3 was never pushed (drain halted at 2).
    assert_received {:pushed, 1, _}
    assert_received {:pushed, 2, _}
    refute_received {:pushed, 3, _}

    # Replay: Outbox would now return id > 1 → [2, 3]. With 2 transient cleared,
    # the drain resumes from event 2 and completes.
    push2 = recording_push(test_pid, fn ev -> {:ok, "remote-#{ev.doc_id}"} end)

    {results2, cursor2} =
      Pusher.drain([Enum.at(events, 1), Enum.at(events, 2)], ctx(source), %{
        funs
        | push_fun: push2
      })

    assert results2 == [{2, {:ok, "remote-b"}}, {3, {:ok, "remote-c"}}]
    assert cursor2 == 3
    assert PushCursor.get(source, @dataset) == 3
  end

  test "phantom double-push: rev_mismatch whose actual == intended rev reconciles, no conflict",
       %{source: source} do
    # Ledger is stale ("stale-base"); the remote ALREADY holds our intended rev.
    PushDocRev.put(source, @dataset, "p", "stale-base")
    event = doc_event(9, "p", "rp")

    # actual == the rev we intended to land ("rp") → phantom, not a conflict.
    push = fn _ctx, _ev, base ->
      assert base == "stale-base"
      {:error, {:rev_mismatch, %{expected: "stale-base", actual: "rp"}}}
    end

    funs = %{push_fun: push, claim_fun: nil, close_fun: nil}

    {results, cursor} = Pusher.drain([event], ctx(source), funs)

    assert results == [{9, {:ok, :reconciled}}]
    assert cursor == 9
    assert PushCursor.get(source, @dataset) == 9
    # ledger reconciled to the remote's actual…
    assert PushDocRev.get(source, @dataset, "p") == "rp"
    # …and NO conflict was recorded.
    assert PushConflict.list_open(source, @dataset) == []
  end

  test "task reconcile via claim/epoch (not a content merge): fenced_off → conflict, cursor advances",
       %{source: source} do
    test_pid = self()

    closed =
      doc_event(11, "t1", "rt", mutation: "task.closed", type: "task")
      |> Map.update!(:document, fn d ->
        Map.put(d, "content", %{"claim" => %{"worker" => "w1", "epoch" => 4}})
      end)

    # close transport receives observed_epoch read from document.content.claim.epoch.
    close_fun = fn _ctx, event, body ->
      send(test_pid, {:closed, event.doc_id, body})
      {:error, {:fenced_off, %{}}}
    end

    # push_fun MUST NOT be called for a task event (no /v1/data/mutate path).
    push_fun = fn _ctx, _ev, _base ->
      send(test_pid, :push_called)
      flunk("task hit the doc push path")
    end

    funs = %{push_fun: push_fun, claim_fun: nil, close_fun: close_fun}

    {results, cursor} = Pusher.drain([closed], ctx(source), funs)

    assert results == [{11, {:conflict, :fenced_off}}]
    assert cursor == 11
    assert PushCursor.get(source, @dataset) == 11

    assert_received {:closed, "t1", body}
    assert body.observed_epoch == 4
    assert body.worker_id == "w1"
    refute_received :push_called

    # Conflict recorded via the claim/epoch path; kind reflects the remote reason.
    assert [row] = PushConflict.list_open(source, @dataset)
    assert row.event_id == 11
    assert row.kind == "fenced_off"
  end

  describe "reason_atom/1 (untrusted remote reason → safe kind, no atom-table DoS)" do
    test "whitelisted reasons map to their existing atoms" do
      assert Pusher.reason_atom("fenced_off") == :fenced_off
      assert Pusher.reason_atom("stale_claim") == :stale_claim
      assert Pusher.reason_atom("resource_conflict") == :resource_conflict
    end

    test "any other reason degrades to :transient (never String.to_atom on arbitrary input)" do
      assert Pusher.reason_atom("nope") == :transient
      assert Pusher.reason_atom("some-never-seen-string") == :transient
      assert Pusher.reason_atom("") == :transient
    end
  end

  test "task reconcile fed an unknown remote reason degrades to a transient halt, never a raise",
       %{source: source} do
    closed =
      doc_event(21, "t9", "rt", mutation: "task.closed", type: "task")
      |> Map.update!(:document, fn d ->
        Map.put(d, "content", %{"claim" => %{"worker" => "w1", "epoch" => 1}})
      end)

    # The default close transport (`task_post/3`) maps an
    # `%{"ok" => false, "reason" => ...}` body through reason_atom/1; a hostile
    # unknown reason becomes {:error, {:transient, resp}}, which reconcile_task/4's
    # catch-all degrades to {:error, :transient} — never a CaseClauseError raise.
    close_fun = fn _ctx, _event, _body ->
      resp = %{"ok" => false, "reason" => "nope"}
      {:error, {Pusher.reason_atom(resp["reason"]), resp}}
    end

    funs = %{push_fun: nil, claim_fun: nil, close_fun: close_fun}

    # Must NOT raise, and must yield a safe transient halt (cursor not advanced).
    {results, cursor} = Pusher.drain([closed], ctx(source), funs)

    assert results == [{21, {:error, :transient}}]
    assert cursor == 0
    assert PushConflict.list_open(source, @dataset) == []
  end

  describe "payload_mutations/3 (F2 fail-closed seam)" do
    test "nil base → fail-closed create (no ifRevisionID, NOT createOrReplace)" do
      doc = %{"_id" => "d", "_type" => "post", "_rev" => "r1"}
      assert Pusher.payload_mutations(doc, "post", nil) == [%{"create" => doc}]
    end

    test "known base → createOrReplace carrying ifRevisionID" do
      doc = %{"_id" => "d", "_type" => "post", "_rev" => "r1"}

      assert [%{"createOrReplace" => create}] = Pusher.payload_mutations(doc, "post", "rev1")
      assert create["ifRevisionID"] == "rev1"
      assert create["_id"] == "d"
      refute Map.has_key?(create, "create")
    end
  end

  test "fail-closed: never-pushed doc whose remote exists → conflict, loser preserved, remote NOT overwritten",
       %{source: source} do
    # No PushDocRev primed → push_doc reads base_rev == nil → default transport
    # would issue `create`; the remote already holds the doc → 409 :conflict,
    # which `push/3` maps to {:rev_mismatch, %{expected: nil, actual: nil}}.
    event = doc_event(13, "exists", "rnew")

    push = fn _ctx, _ev, base ->
      # Proves we sent NO CAS base (fail-closed create path).
      assert base == nil
      {:error, {:rev_mismatch, %{expected: nil, actual: nil}}}
    end

    funs = %{push_fun: push, claim_fun: nil, close_fun: nil}

    {results, cursor} = Pusher.drain([event], ctx(source), funs)

    # actual == nil → phantom_double_push? is false → a SAFE conflict, no overwrite.
    assert results == [{13, {:conflict, :rev_mismatch}}]
    assert cursor == 13
    assert PushCursor.get(source, @dataset) == 13

    # The loser is preserved durably…
    assert [row] = PushConflict.list_open(source, @dataset)
    assert row.event_id == 13
    assert row.kind == "rev_mismatch"
    assert row.local_document["_id"] == "exists"

    # …and the remote was NEVER overwritten (ledger holds no winning rev).
    assert PushDocRev.get(source, @dataset, "exists") == nil
  end
end
