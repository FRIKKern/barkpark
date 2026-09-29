defmodule Barkpark.ContentPubsubGlobalTopicLeakTest do
  @moduledoc """
  THE PRODUCER HALF of task-be3b3aa6da5df3a2 — first task-5d0615ee60143cc8
  (#17207), now task-b7e81f26e959106c, ruling (b): DISALLOW.

  `Content.Broadcast` fires document-list frames on two topics: the
  workspace-keyed `documents:ws:<id>:<dataset>` and the global
  `documents:<dataset>`. The global topic has no workspace component, so every
  one of its subscribers receives every frame on it. #17207 stripped the
  PAYLOAD from a workspace-owned document's global frame but let an
  identity-only twin through (`event_id`, `type`, `doc_id`, `rev`,
  `workspace_id`, ...). That residual is retired here: a workspace-owned
  document's identity and activity are tenant data too (doc ids can be
  user-chosen slugs), so NO frame of any shape for it reaches the global topic.

  What must hold:

    1. LEAK GATE — a workspace-B consumer joined to the document-list stream
       receives NOTHING for workspace A's document on the global topic. Not a
       stripped frame, not an id, nothing. `refute_receive`, not a shape check.
    2. SELF-DELIVERY — the same consumer still gets its OWN workspace's
       document, exactly once, WITH the full payload, off the keyed topic.
    3. SHARED LAYER — a nil-workspace document still reaches every global-topic
       consumer with its full payload (the POSITIVE CONTROL: the subscriber in
       (1) is not silent because the topic is dead). The global topic is the
       shared layer's ONLY announcement.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Broadcast
  alias Barkpark.Content.Document
  alias Barkpark.Tenancy

  @dataset "global-topic-leak"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Posts", "visibility" => "public", "fields" => []},
        @dataset
      )

    {:ok, ws_a} = Tenancy.create_workspace(%{slug: "gtl-alpha", name: "Alpha"})
    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "gtl-bravo", name: "Bravo"})

    %{ws_a: ws_a, ws_b: ws_b}
  end

  # A shared-layer document, built DIRECTLY rather than by omitting the option:
  # `Content.WriteScope.resolve_write_scope/1` stamps an unscoped write with the
  # instance-default workspace when that seat is filled, so `create_document/3`
  # without a workspace does NOT reliably produce a nil-workspace row — it
  # produces a Default-workspace one, and a test would silently measure the
  # wrong arm. Broadcasting a struct we own puts the producer's nil-workspace
  # clause under the assertion with no dependence on the seat.
  defp shared_doc(doc_id) do
    %Document{
      doc_id: doc_id,
      type: "post",
      dataset: @dataset,
      workspace_id: nil,
      project_id: nil,
      rev: "rev-#{doc_id}",
      title: "SHARED",
      status: "published",
      content: %{"title" => "SHARED"},
      updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  describe "GLOBAL documents:<dataset> topic — producer-side tenant fence" do
    test "a workspace-B consumer receives NO frame at all for workspace A's document", %{
      ws_a: ws_a,
      ws_b: ws_b
    } do
      # Subscribe exactly as a workspace-scoped consumer of the document-list
      # stream does: the global topic (shared layer) PLUS its own keyed topic.
      # This is what BoardLive/Recorder/ChatLive/Quiz.Bridge call.
      :ok = Broadcast.subscribe_documents(@dataset, ws_b.id)

      {:ok, _doc_a} =
        Content.create_document(
          "post",
          %{"_id" => "a-secret", "title" => "TENANT A SECRET", "body" => "A private body"},
          @dataset,
          workspace_id: ws_a.id
        )

      # POSITIVE CONTROL, fired AFTER the tenant write on the SAME topic: if
      # this frame arrives, the subscription is live and PubSub delivered in
      # order — so the refute below is a verdict about the producer, not about
      # a dead subscriber.
      :ok =
        Broadcast.broadcast_document_mutation(shared_doc("control-after-a"), "update",
          event_id: 1
        )

      assert_receive {:document_changed, %{doc_id: "control-after-a"} = control}, 1_000
      assert is_nil(control.workspace_id)
      assert control.doc.title == "SHARED"

      # THE GATE. Under #17207 an identity-only frame
      # `%{doc_id: "drafts.a-secret", workspace_id: ws_a.id, doc: nil, ...}`
      # arrived here BEFORE the control. Now nothing does.
      refute_received {:document_changed, %{doc_id: "drafts.a-secret"}},
                      "workspace A's document reached workspace B on the global topic"

      # And no other spelling of it either: NOTHING in the mailbox names A.
      a_id = ws_a.id
      refute_received {:document_changed, %{workspace_id: ^a_id}}
    end

    test "an UNSCOPED global-topic subscriber hears the shared layer ONLY", %{ws_a: ws_a} do
      # The `subscribe_documents(dataset, nil)` shape: a consumer with no
      # workspace in context. It hears shared-layer documents and nothing else —
      # not even the id of a tenant's document.
      :ok = Broadcast.subscribe_documents(@dataset, nil)

      {:ok, _doc_a} =
        Content.create_document("post", %{"_id" => "a-daemon", "title" => "A SECRET"}, @dataset,
          workspace_id: ws_a.id
        )

      :ok =
        Broadcast.broadcast_document_mutation(shared_doc("control-unscoped"), "update",
          event_id: 2
        )

      assert_receive {:document_changed, %{doc_id: "control-unscoped"}}, 1_000
      refute_received {:document_changed, %{doc_id: "drafts.a-daemon"}}
      a_id = ws_a.id
      refute_received {:document_changed, %{type: "post", workspace_id: ^a_id}}
    end

    test "the SAME consumer still gets its OWN document WITH the payload, exactly once", %{
      ws_b: ws_b
    } do
      :ok = Broadcast.subscribe_documents(@dataset, ws_b.id)

      {:ok, _doc_b} =
        Content.create_document(
          "post",
          %{"_id" => "b-own", "title" => "B OWN"},
          @dataset,
          workspace_id: ws_b.id
        )

      assert_receive {:document_changed, %{doc_id: "drafts.b-own"} = msg}, 1_000
      assert msg.workspace_id == ws_b.id
      assert msg.doc.title == "B OWN"
      assert is_map(msg.document)

      # ONE frame, not two. Under #17207 the keyed frame had a payload-free twin
      # on the global topic; a consumer on both topics saw its own document
      # twice. That twin is retired.
      refute_receive {:document_changed, %{doc_id: "drafts.b-own"}}, 300
    end

    test "a nil-workspace (shared-layer) document still carries its payload on the global topic" do
      # The back-compat path every existing global consumer rides. The global
      # topic is the shared layer's ONLY announcement.
      :ok = Phoenix.PubSub.subscribe(Barkpark.PubSub, Broadcast.global_list_topic(@dataset))

      :ok = Broadcast.broadcast_document_mutation(shared_doc("shared-doc"), "update", event_id: 3)

      assert_receive {:document_changed, %{doc_id: "shared-doc"} = msg}, 1_000
      assert is_nil(msg.workspace_id)
      assert msg.doc.title == "SHARED"
      assert is_map(msg.document)
    end

    test "a workspace-owned document is announced on its keyed topic ALONE (the immediate path too)",
         %{ws_a: ws_a, ws_b: ws_b} do
      # `broadcast_document_mutation/3` is the IMMEDIATE (non-deferred) producer
      # — `tap_broadcast/7` is the write-path one exercised above. Both must
      # agree: keyed topic yes, global topic no.
      :ok = Phoenix.PubSub.subscribe(Barkpark.PubSub, Broadcast.global_list_topic(@dataset))

      :ok =
        Phoenix.PubSub.subscribe(
          Barkpark.PubSub,
          Broadcast.workspace_list_topic(@dataset, ws_a.id)
        )

      :ok =
        Phoenix.PubSub.subscribe(
          Barkpark.PubSub,
          Broadcast.workspace_list_topic(@dataset, ws_b.id)
        )

      owned = %{shared_doc("a-immediate") | workspace_id: ws_a.id}
      :ok = Broadcast.broadcast_document_mutation(owned, "update", event_id: 4)

      :ok =
        Broadcast.broadcast_document_mutation(shared_doc("control-immediate"), "update",
          event_id: 5
        )

      # Exactly one frame for the owned document (A's keyed topic), then the
      # control on the global topic, and nothing else naming the owned document.
      assert_receive {:document_changed, %{doc_id: "a-immediate", workspace_id: wid}}, 1_000
      assert wid == ws_a.id
      assert_receive {:document_changed, %{doc_id: "control-immediate"}}, 1_000
      refute_received {:document_changed, %{doc_id: "a-immediate"}}
    end
  end
end
