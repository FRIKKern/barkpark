defmodule Barkpark.Content.PluginWriteWebhookFanoutTest do
  @moduledoc """
  task-a8ac171ba5cddba4 — the Bokbasen status writer (and the Staleness console)
  rejoin the event spine after a raw state-preserving write and say, in their
  own docs, that "SSE, webhooks, and cache revalidation see the write". They
  called `Content.broadcast_document_mutation/3`, which is PubSub ONLY, so no
  webhook ever fired. `webhook: true` now dispatches the fan-out too; the
  default stays PubSub-only (task writers deliberately skip webhooks).
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Status
  alias Barkpark.Repo

  setup do
    me = self()
    id = "plugin-fanout-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:barkpark, :webhooks, :fan_out, :selected],
      fn _e, _m, meta, _ -> send(me, {:fan_out, meta.doc_id}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        "doc_id" => "pwf-#{System.unique_integer([:positive])}",
        "type" => "book",
        "dataset" => "production",
        "title" => "t",
        "status" => "published",
        "content" => %{},
        "rev" => "rev-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert()

    %{doc: doc}
  end

  test "a Bokbasen status write reaches the webhook fan-out", %{doc: doc} do
    Status.write(doc, %{state: "accepted"})

    doc_id = doc.doc_id
    assert_receive {:fan_out, ^doc_id}, 1_000
  end

  test "broadcast_document_mutation with webhook: true fans out; without it, it does not", %{
    doc: doc
  } do
    ev =
      Barkpark.Content.Broadcast.save_event(doc, doc.type, doc.dataset, "update", doc.rev, :test)

    Content.broadcast_document_mutation(doc, "update", event_id: ev.id)
    refute_receive {:fan_out, _}, 300

    Content.broadcast_document_mutation(doc, "update", event_id: ev.id, webhook: true)
    doc_id = doc.doc_id
    assert_receive {:fan_out, ^doc_id}, 1_000
  end
end
