defmodule Barkpark.Content.DeferredBroadcastOrphanTest do
  @moduledoc """
  dr-w12-bl-zero-delivery-root-cause — a named mechanism for "the publish
  committed and fired ZERO webhooks, with no log line at all".

  ## The mechanism

  `Broadcast.maybe_dispatch_webhook/7` defers instead of dispatching whenever
  `Repo.in_transaction?/0` is true. That predicate says a transaction is OPEN,
  never WHO opened it. Only `write_atomically/1`, `Mutations.apply_mutations/2`
  and the `Papers.BlockOps` document-op path take the flush/clear triad. A
  caller that opened a `Repo.transaction` of its own around a document write
  therefore inherited the deferral without inheriting the duty to flush it: the
  `documents` row and the `mutation_events` row COMMIT, the queued webhook dies
  with the process-dictionary entry, `Dispatcher.dispatch_async/7` is never
  called — so not even the `webhook_fanout phase=selected` record exists, which
  is exactly what makes the loss indistinguishable from a crashed fan-out task
  when you only have journald to look at.

  ## What each test measures

  The instrument is the `[:barkpark, :webhooks, :fan_out, :selected]`
  telemetry event. `Dispatcher.fan_out/3` records it SYNCHRONOUSLY in the
  calling process before it spawns anything, so it fires on EVERY dispatch —
  including a dispatch that selects zero endpoints. Its absence is therefore
  "dispatch_async was never called", never "nobody was subscribed".

  Every arm below drives a REAL `tap_broadcast/7` over a REAL committed
  document and reads the SAME instrument, so the zero in the orphan arm is
  measured against a control that is non-zero on the same instrument.
  """

  use Barkpark.DataCase, async: true

  import ExUnit.CaptureLog

  alias Barkpark.Content.{Broadcast, Document}
  alias Barkpark.Repo

  @fan_out [:barkpark, :webhooks, :fan_out, :selected]
  @orphan [:barkpark, :content, :deferred_broadcast, :orphaned]

  setup do
    handler = "deferred-orphan-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach_many(
      handler,
      [@fan_out, @orphan],
      fn event, measurements, metadata, _ ->
        send(test, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp insert_doc do
    suffix = System.unique_integer([:positive])

    %Document{}
    |> Document.changeset(%{
      "doc_id" => "orphan-probe-#{suffix}",
      "type" => "paper",
      "dataset" => "orphan-probe-ds-#{suffix}",
      "title" => "orphan probe #{suffix}",
      "status" => "published",
      "content" => %{},
      "rev" => Barkpark.Content.Writer.generate_rev()
    })
    |> Repo.insert!()
  end

  defp publish(doc) do
    Broadcast.tap_broadcast({:ok, doc}, doc.dataset, doc.type, "publish", nil)
  end

  # `:telemetry` handlers are GLOBAL and this case is `async: true`, so the
  # mailbox also carries every other concurrently-running test's fan-outs.
  # Every arm therefore filters to ITS OWN dataset (unique per `insert_doc/0`).
  # Without this the arms read each other's events — which is how this file
  # first went red, and is a live reminder that a telemetry assertion in an
  # async suite is only as good as its filter.
  defp drain do
    receive do
      {:telemetry, event, m, meta} -> [{event, m, meta} | drain()]
    after
      0 -> []
    end
  end

  # `drain/0` EMPTIES the mailbox, so each test drains exactly ONCE and filters
  # the same list twice. Calling it per-assertion would make the second
  # assertion read an empty mailbox and pass vacuously.
  defp fan_out_events(events, %Document{dataset: ds}) do
    for {@fan_out, m, meta} <- events, meta[:dataset] == ds, do: {m, meta}
  end

  defp orphan_events(events, %Document{dataset: ds}) do
    for {@orphan, m, meta} <- events,
        meta[:dataset] == ds or String.contains?(to_string(meta[:topic] || ""), ds),
        do: {m, meta}
  end

  describe "an unowned transaction swallows the webhook" do
    test "REPRODUCTION: publish inside a bare Repo.transaction dispatches NOTHING and is counted as an orphan" do
      doc = insert_doc()

      log =
        capture_log(fn ->
          {:ok, {:ok, _}} = Repo.transaction(fn -> publish(doc) end)
        end)

      # The loss, measured: dispatch_async was never called, so the fan-out
      # record that would have existed for ANY dispatch (even a zero-endpoint
      # one) is absent.
      events = drain()

      assert fan_out_events(events, doc) == [],
             "expected NO fan-out record from an unowned transaction"

      # The arm: the loss is countable rather than silent.
      webhook_orphans =
        orphan_events(events, doc) |> Enum.filter(fn {_m, meta} -> meta.kind == :webhook end)

      assert [{%{count: 1}, meta}] = webhook_orphans
      assert meta.dataset == doc.dataset
      assert meta.action == "publish"
      assert meta.type == "paper"
      assert meta.doc_id == doc.doc_id
      assert is_integer(meta.event_id)

      assert log =~ "deferred_broadcast_orphan kind=webhook"
      assert log =~ doc.doc_id
    end
  end

  describe "controls — the same instrument, non-zero" do
    test "CONTROL A: the same publish OUTSIDE any transaction dispatches, and raises no orphan" do
      doc = insert_doc()

      {:ok, _} = publish(doc)
      events = drain()

      assert [{%{selected: _}, meta}] = fan_out_events(events, doc)
      assert meta.dataset == doc.dataset
      assert meta.event == "publish"
      assert meta.doc_id == doc.doc_id

      assert orphan_events(events, doc) == []
    end

    test "CONTROL B: the same publish inside an OWNED transaction dispatches on commit, and raises no orphan" do
      doc = insert_doc()

      result =
        Broadcast.with_deferred_queue(fn ->
          Repo.transaction(fn ->
            # Nothing has dispatched yet — the queue is still holding it.
            publish(doc)
          end)
        end)

      assert {:ok, {:ok, _}} = result
      events = drain()

      assert [{%{selected: _}, meta}] = fan_out_events(events, doc)
      assert meta.doc_id == doc.doc_id
      assert orphan_events(events, doc) == []
    end

    test "CONTROL C: an OWNED transaction that rolls back dispatches nothing and raises no orphan" do
      doc = insert_doc()

      result =
        Broadcast.with_deferred_queue(fn ->
          Repo.transaction(fn ->
            publish(doc)
            Repo.rollback(:nope)
          end)
        end)

      assert result == {:error, :nope}
      events = drain()
      assert fan_out_events(events, doc) == []
      assert orphan_events(events, doc) == []
    end
  end

  describe "with_deferred_queue/1 nesting" do
    test "a nested claim does NOT reset the outer owner's queue" do
      outer = insert_doc()
      inner = insert_doc()

      {:ok, {:ok, _}} =
        Broadcast.with_deferred_queue(fn ->
          Repo.transaction(fn ->
            publish(outer)
            # An inner owner (Media.delete_row_with_asset_doc/1 reached from
            # Tenancy.delete_workspace/1) must NOT re-claim: that would drop
            # `outer`'s queued webhook on the floor.
            Broadcast.with_deferred_queue(fn -> publish(inner) end)
          end)
        end)

      events = drain()

      doc_ids =
        (fan_out_events(events, outer) ++ fan_out_events(events, inner))
        |> Enum.map(fn {_m, meta} -> meta.doc_id end)
        |> Enum.sort()

      assert doc_ids == Enum.sort([outer.doc_id, inner.doc_id])
      assert orphan_events(events, outer) == []
      assert orphan_events(events, inner) == []
    end
  end
end
