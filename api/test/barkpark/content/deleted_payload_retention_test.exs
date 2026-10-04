defmodule Barkpark.Content.DeletedPayloadRetentionTest do
  @moduledoc """
  Owner ruling #33 (task-43179d8d03efe969 item 4): copies of deleted content in
  `mutation_events.document` and media `webhook_deliveries.payload_snapshot`
  expire after 90 days. Pins:

    * the scheduled sweep redacts an old delete event and an old create event of
      a deleted document, and an old media delivery whose file is gone;
    * it leaves rows younger than the window, every event of a document that
      still exists (published or draft form), pending deliveries and media rows
      whose file still exists;
    * the row survives (only the payload is replaced), and a second run is a
      no-op;
    * with the switch off the worker writes nothing;
    * the mix task's dry run writes nothing and reports the counts.
  """

  use Barkpark.DataCase, async: false

  import ExUnit.CaptureIO

  alias Barkpark.BootModeSandbox
  alias Barkpark.Content.{DeletedPayloadRetention, Document, MutationEvent}
  alias Barkpark.Content.Workers.DeletedPayloadSweeper
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Webhooks.Delivery
  alias Mix.Tasks.Barkpark.DeletedPayloadRetention, as: RetentionTask

  @dataset "production"

  setup do
    previous = Application.get_env(:barkpark, :deleted_payload_retention)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :deleted_payload_retention, previous),
        else: Application.delete_env(:barkpark, :deleted_payload_retention)
    end)

    prev_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(prev_shell) end)

    :ok
  end

  defp switch(enabled),
    do: Application.put_env(:barkpark, :deleted_payload_retention, enabled: enabled, days: 90)

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

  defp seed_doc!(doc_id) do
    %Document{}
    |> Document.changeset(%{
      "doc_id" => doc_id,
      "type" => "post",
      "dataset" => @dataset,
      "title" => "Live #{doc_id}",
      "content" => %{"body" => "still here"},
      "rev" => "rev-#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp event!(doc_id, mutation, age_days, secret \\ "the deleted body") do
    Repo.insert!(%MutationEvent{
      dataset: @dataset,
      type: "post",
      doc_id: doc_id,
      mutation: mutation,
      rev: "rev-#{System.unique_integer([:positive])}",
      document: %{"_id" => doc_id, "_type" => "post", "title" => secret},
      inserted_at: days_ago(age_days)
    })
  end

  defp media_delivery!(file_id, age_days, status \\ "ok") do
    body =
      Jason.encode!(%{
        "event" => "media.deleted",
        "dataset" => @dataset,
        "media_file_id" => file_id,
        "original_name" => "secret-scan.pdf"
      })

    at = days_ago(age_days)

    Repo.insert!(%Delivery{
      source_kind: "media",
      status: status,
      payload_snapshot: %{"url" => "https://hook.example", "secret" => "whsec", "body" => body},
      inserted_at: at,
      updated_at: at
    })
  end

  defp seed_media!() do
    %MediaFile{}
    |> MediaFile.changeset(%{
      filename: "live.png",
      original_name: "live.png",
      path: "live-#{System.unique_integer([:positive])}.png",
      mime_type: "image/png",
      size: 1,
      dataset: @dataset
    })
    |> Repo.insert!()
  end

  defp document(%MutationEvent{id: id}), do: Repo.get!(MutationEvent, id).document
  defp snapshot(%Delivery{id: id}), do: Repo.get!(Delivery, id).payload_snapshot

  defp run_sweeper, do: DeletedPayloadSweeper.perform(%Oban.Job{args: %{}})

  describe "the scheduled sweep (switch on)" do
    setup do
      switch(true)
      :ok
    end

    test "redacts old copies of a deleted document and of a deleted media file" do
      created = event!("gone-1", "create", 200)
      deleted = event!("gone-1", "delete", 120)
      gone_file = Ecto.UUID.generate()
      delivery = media_delivery!(gone_file, 100)

      assert {:ok, %{mutation_events: 2, webhook_deliveries: 1}} = run_sweeper()

      for ev <- [created, deleted] do
        doc = document(ev)
        refute Map.has_key?(doc, "title"), "event #{ev.id} still holds the deleted body"
        assert %{"_id" => "gone-1", "_type" => "post", "_redacted" => "retention"} = doc
        assert doc["_rev"] == ev.rev
      end

      snap = snapshot(delivery)
      assert snap["_redacted"] == "retention"
      refute Map.has_key?(snap, "body")
      refute Map.has_key?(snap, "secret")

      # The rows themselves stay: feeds, replay and delivery history read them.
      assert Repo.get(MutationEvent, deleted.id).mutation == "delete"
      assert Repo.get(Delivery, delivery.id).status == "ok"

      # Idempotent: redacted rows are never matched again.
      assert {:ok, %{mutation_events: 0, webhook_deliveries: 0}} = run_sweeper()
    end

    test "leaves young rows, live documents, pending deliveries and live media files" do
      young = event!("gone-2", "delete", 30)
      live = seed_doc!("live-1")
      old_live = event!("live-1", "create", 200)
      draft_only = seed_doc!("drafts.live-2")
      old_published_form = event!("live-2", "update", 200)
      old_draft_event = event!("drafts.live-1", "update", 200)
      pending = media_delivery!(Ecto.UUID.generate(), 100, "pending")
      file = seed_media!()
      live_file = media_delivery!(file.id, 100)
      young_gone_file = media_delivery!(Ecto.UUID.generate(), 30)

      assert {:ok, %{mutation_events: 0, webhook_deliveries: 0}} = run_sweeper()

      for ev <- [young, old_live, old_published_form, old_draft_event] do
        assert document(ev)["title"] == "the deleted body", "event #{ev.id} was redacted"
      end

      for d <- [pending, live_file, young_gone_file] do
        assert is_binary(snapshot(d)["body"]), "delivery #{d.id} was redacted"
      end

      assert live.id && draft_only.id
    end
  end

  test "the sweep writes nothing while the switch is off (the shipped default)" do
    Application.delete_env(:barkpark, :deleted_payload_retention)
    refute DeletedPayloadRetention.enabled?()
    assert DeletedPayloadRetention.days() == 90

    ev = event!("gone-3", "delete", 200)
    d = media_delivery!(Ecto.UUID.generate(), 200)

    switch(false)
    assert {:ok, %{skipped: :disabled}} = run_sweeper()
    assert document(ev)["title"] == "the deleted body"
    assert is_binary(snapshot(d)["body"])
  end

  test "the sweep is scheduled in the Oban crontab" do
    crontab =
      Application.get_env(:barkpark, Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value([], fn
        {Oban.Plugins.Cron, opts} -> Keyword.get(opts, :crontab, [])
        _ -> nil
      end)

    assert Enum.any?(crontab, &match?({_expr, DeletedPayloadSweeper}, &1))
  end

  test "batches are bounded: a backlog is finished across several passes" do
    switch(true)
    for n <- 1..5, do: event!("gone-batch-#{n}", "delete", 200)

    assert {:ok, %{mutation_events: 5, passes: passes}} =
             DeletedPayloadRetention.sweep(batch_size: 2)

    # 2 + 2 + 1, then the empty pass that ends the loop.
    assert passes == 4
  end

  describe "mix barkpark.deleted_payload_retention" do
    test "the dry run reports counts and writes nothing" do
      switch(false)
      ev = event!("gone-4", "delete", 150)
      event!("gone-4", "create", 300)
      d = media_delivery!(Ecto.UUID.generate(), 120)

      output = capture_io(fn -> run_task([]) end)

      assert output =~ "mutation_events: 2 row(s)"
      assert output =~ "webhook_deliveries: 1 row(s)"
      assert output =~ "oldest "
      assert output =~ "Dry run — nothing was written"

      assert document(ev)["title"] == "the deleted body"
      assert is_binary(snapshot(d)["body"])
    end

    test "--apply redacts and the census then reads zero" do
      switch(false)
      ev = event!("gone-5", "delete", 150)

      output = capture_io(fn -> run_task(["--apply"]) end)

      assert output =~ "Redacted 1 mutation_events"
      assert output =~ "mutation_events: 0 row(s)"
      assert document(ev)["_redacted"] == "retention"
    end
  end

  # `run/1` calls `Barkpark.OneShot.boot!/0`, which persistently sets the
  # node-global `:boot_mode`; the sandbox restores it.
  defp run_task(argv), do: BootModeSandbox.protecting(fn -> RetentionTask.run(argv) end)
end
