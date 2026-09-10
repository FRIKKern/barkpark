defmodule Barkpark.ContentPubsubGlobalTopicLeakTest do
  @moduledoc """
  THE PRODUCER HALF of task-be3b3aa6da5df3a2 (task-5d0615ee60143cc8).

  `Content.Broadcast` fires TWO document-list topics: the workspace-keyed
  `documents:ws:<id>:<dataset>`, only when the document HAS a workspace, and the
  global `documents:<dataset>`, UNCONDITIONALLY. The global topic has no
  workspace component, so every one of its subscribers received every tenant's
  frame — and that frame carried `Envelope.render(doc, nil, :internal)` plus
  `title`/`status`/`content`. PR #17132 taught ONE consumer (StudioLive) to
  refuse foreign frames; every other direct subscriber
  (`Tasks.Web.BoardLive`, `StudioChat.Recorder`, `ChatLive.subscribe_hand_tasks/1`,
  `Quiz.Bridge`) still read them.

  The fix is on the PRODUCER: a workspace-owned document's global frame is
  stripped of its payload (`Broadcast.global_msg/1`). What must hold:

    1. LEAK GATE — a workspace-B consumer that joins the document-list stream
       receives NO payload for workspace A's document. Identity metadata may
       arrive (that is what keeps instance-wide daemons like `Quiz.Bridge`
       working); `:document` and `:doc` must not.
    2. SELF-DELIVERY — the same consumer still gets its OWN workspace's
       document WITH the full payload, off the workspace-keyed topic.
    3. SHARED LAYER — a nil-workspace document still reaches every global-topic
       consumer with its full payload. The global topic is its ONLY
       announcement (`ListenController.list_topic/2` states this rule), so
       narrowing it would silence the shared layer entirely.
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

  describe "GLOBAL documents:<dataset> topic — producer-side tenant fence" do
    test "a workspace-B consumer gets NO payload for workspace A's document", %{
      ws_a: ws_a,
      ws_b: ws_b
    } do
      # Subscribe exactly as a workspace-scoped consumer of the document-list
      # stream does: the global topic (shared layer) PLUS its own keyed topic.
      # This is what BoardLive/Recorder/ChatLive now call.
      :ok = Broadcast.subscribe_documents(@dataset, ws_b.id)

      {:ok, _doc_a} =
        Content.create_document(
          "post",
          %{"_id" => "a-secret", "title" => "TENANT A SECRET", "body" => "A private body"},
          @dataset,
          workspace_id: ws_a.id
        )

      # The frame may arrive — identity only. It must carry NO payload.
      assert_receive {:document_changed, %{doc_id: "drafts.a-secret"} = msg}, 1_000

      assert msg.workspace_id == ws_a.id,
             "the frame must still say WHOSE document changed"

      refute msg.document,
             "the global topic leaked workspace A's rendered envelope to workspace B: " <>
               inspect(msg.document)

      refute msg.doc,
             "the global topic leaked workspace A's title/status/content to workspace B: " <>
               inspect(msg.doc)

      # And nothing else follows carrying the body.
      refute_receive {:document_changed, %{doc_id: "drafts.a-secret", doc: %{}}}, 300
    end

    test "the SAME consumer still gets its OWN document WITH the payload", %{ws_b: ws_b} do
      :ok = Broadcast.subscribe_documents(@dataset, ws_b.id)

      {:ok, _doc_b} =
        Content.create_document(
          "post",
          %{"_id" => "b-own", "title" => "B OWN"},
          @dataset,
          workspace_id: ws_b.id
        )

      # BOTH topics fire for a workspace-owned document, global first: the
      # payload-free twin, then the real frame on the keyed topic. Match on a
      # `doc` MAP so the assertion is about the payload-bearing one — this is
      # the same shape every consumer's handler guard now requires.
      assert_receive {:document_changed, %{doc_id: "drafts.b-own", doc: %{}} = msg}, 1_000
      assert msg.workspace_id == ws_b.id
      assert msg.doc.title == "B OWN"
      assert is_map(msg.document)
    end

    test "the payload-free global twin arrives too, and is ignorable by shape", %{ws_b: ws_b} do
      # The documented cost of keeping the global topic alive: a consumer on
      # BOTH topics sees its own document twice. The FIRST frame is the global
      # one and it is stripped — which is why `BoardLive`, `Recorder` and
      # `ChatLive` all guard `when is_map(doc)`. Pin the order and the shape so
      # a future producer change cannot silently make the stripped twin the
      # only frame.
      :ok = Broadcast.subscribe_documents(@dataset, ws_b.id)

      {:ok, _doc_b} =
        Content.create_document(
          "post",
          %{"_id" => "b-twin", "title" => "B TWIN"},
          @dataset,
          workspace_id: ws_b.id
        )

      assert_receive {:document_changed, %{doc_id: "drafts.b-twin"} = first}, 1_000
      refute first.doc, "the GLOBAL frame must arrive first and carry no payload"
      refute first.document

      assert_receive {:document_changed, %{doc_id: "drafts.b-twin", doc: %{}} = second}, 1_000
      assert second.doc.title == "B TWIN"
    end

    test "a nil-workspace (shared-layer) document still carries its payload on the global topic" do
      # The back-compat path every existing global consumer rides. The global
      # topic is the shared layer's ONLY announcement.
      #
      # The nil workspace is built DIRECTLY rather than by omitting the option:
      # `Content.WriteScope.resolve_write_scope/1` stamps an unscoped write with
      # the instance-default workspace when that seat is filled, so
      # `create_document/3` without a workspace does NOT reliably produce a
      # nil-workspace row — it produces a default-workspace one, and the test
      # would silently measure the wrong arm. Broadcasting a struct we own puts
      # the producer's nil-workspace clause under the assertion with no
      # dependence on the seat.
      :ok = Phoenix.PubSub.subscribe(Barkpark.PubSub, Broadcast.global_list_topic(@dataset))

      shared = %Document{
        doc_id: "shared-doc",
        type: "post",
        dataset: @dataset,
        workspace_id: nil,
        project_id: nil,
        rev: "rev-shared",
        title: "SHARED",
        status: "published",
        content: %{"title" => "SHARED"},
        updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      :ok = Broadcast.broadcast_document_mutation(shared, "update", event_id: 1)

      assert_receive {:document_changed, %{doc_id: "shared-doc"} = msg}, 1_000
      assert is_nil(msg.workspace_id)
      assert msg.doc.title == "SHARED"
      assert is_map(msg.document)
    end

    test "an UNSCOPED global-topic subscriber sees no tenant payload at all", %{ws_a: ws_a} do
      # `Quiz.Bridge`'s shape: an instance-wide daemon with no workspace in
      # context. It keeps the identity fields it reads (type + doc_id) and
      # never sees a tenant body.
      :ok = Broadcast.subscribe_documents(@dataset, nil)

      {:ok, _doc_a} =
        Content.create_document("post", %{"_id" => "a-daemon", "title" => "A SECRET"}, @dataset,
          workspace_id: ws_a.id
        )

      assert_receive {:document_changed, %{doc_id: "drafts.a-daemon", type: "post"} = msg}, 1_000
      refute msg.document
      refute msg.doc
    end
  end
end
