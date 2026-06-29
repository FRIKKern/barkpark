defmodule BarkparkWeb.ListenControllerTest do
  @moduledoc """
  SSE field-visibility leak-guard (Phase 3, core-auth).

  The live `receive` loop is not directly assertable from a test (the HTTP
  connection is long-lived), so the redaction step is exercised through the
  `ListenController.redacted_result/4` testing seam — the same `@doc false`
  public-seam convention this controller already uses for `replay_since/3`,
  `format_event/2` and `forward_event?/3`. Both the LIVE broadcast path and the
  Last-Event-ID REPLAY path funnel through that one function, so asserting it
  proves the invariant for both surfaces.

  Invariant: a non-encrypted `private` field must NEVER reach a non-admin
  subscriber; an admin subscriber sees it; a nil caller (unscoped / back-compat)
  forwards the snapshot verbatim (byte-identical to the legacy stream).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Envelope}
  alias Barkpark.Crypto.FieldCipher
  alias BarkparkWeb.ListenController

  @dataset "ssetest"

  setup do
    Content.upsert_schema(
      %{
        "name" => "post",
        "title" => "Post",
        "visibility" => "public",
        "fields" => [
          %{"name" => "body", "type" => "string"},
          %{"name" => "ssn", "type" => "string", "private" => true}
        ]
      },
      @dataset
    )

    {:ok, doc} =
      Content.create_document(
        "post",
        %{
          "doc_id" => "drafts.l1",
          "title" => "L1",
          "content" => %{"body" => "ok", "ssn" => "111-22-3333"}
        },
        @dataset
      )

    %{doc: doc}
  end

  defp admin, do: %CallerContext{principal_type: :api_token, is_admin: true}
  defp reader, do: %CallerContext{principal_type: :api_token, token_id: "tok-r"}

  test "replay path: stored snapshot leaks the private field; a non-admin is redacted, admin is not" do
    ev =
      ListenController.replay_since(@dataset, 0)
      |> Enum.find(&(&1.doc_id == "drafts.l1"))

    assert ev, "expected a replayable mutation event for the seeded doc"
    # The stored mutation_events.document snapshot IS the leak surface — it holds
    # the private plaintext. Proving redaction happens at emit time, not at write.
    assert ev.document["ssn"] == "111-22-3333"

    redacted = ListenController.redacted_result(ev, @dataset, reader(), [])
    refute Map.has_key?(redacted, "ssn")
    assert redacted["body"] == "ok"
    assert redacted["_id"] == "drafts.l1"

    assert ListenController.redacted_result(ev, @dataset, admin(), [])["ssn"] == "111-22-3333"
  end

  test "live path: re-renders the CURRENT document under the subscriber", %{doc: doc} do
    # A live broadcast forwards a pre-rendered, unredacted envelope.
    msg = %{doc_id: doc.doc_id, type: "post", document: Envelope.render(doc)}
    assert msg.document["ssn"] == "111-22-3333"

    redacted = ListenController.redacted_result(msg, @dataset, reader(), [])
    refute Map.has_key?(redacted, "ssn")
    assert redacted["body"] == "ok"
    assert redacted["_id"] == doc.doc_id

    assert ListenController.redacted_result(msg, @dataset, admin(), [])["ssn"] == "111-22-3333"
  end

  test "nil caller (unscoped / back-compat) forwards the snapshot verbatim", %{doc: doc} do
    msg = %{doc_id: doc.doc_id, type: "post", document: Envelope.render(doc)}
    assert ListenController.redacted_result(msg, @dataset, nil, []) == msg.document
  end

  test "delete event (document gone) redacts the FROZEN snapshot, not a re-render" do
    # No live document exists for this id — only the stored snapshot remains.
    snapshot = %{
      "_id" => "drafts.gone",
      "_type" => "post",
      "title" => "G",
      "body" => "ok",
      "ssn" => "999-99-9999"
    }

    ev = %{doc_id: "drafts.gone", type: "post", document: snapshot}

    redacted = ListenController.redacted_result(ev, @dataset, reader(), [])
    refute Map.has_key?(redacted, "ssn")
    assert redacted["title"] == "G"
    assert redacted["_id"] == "drafts.gone"
    # Admin still sees the snapshot whole.
    assert ListenController.redacted_result(ev, @dataset, admin(), [])["ssn"] == "999-99-9999"
  end

  test "encrypted field never streams plaintext to a non-admin (schema-free guard)" do
    enc = FieldCipher.encrypt("ssn-enc", "dataset:#{@dataset}")

    {:ok, doc} =
      Content.create_document(
        "post",
        %{"doc_id" => "drafts.l2", "title" => "L2", "content" => %{"ssn" => enc, "body" => "ok"}},
        @dataset
      )

    msg = %{doc_id: doc.doc_id, type: "post", document: Envelope.render(doc)}
    redacted = ListenController.redacted_result(msg, @dataset, reader(), [])
    refute Map.has_key?(redacted, "ssn")
    assert redacted["body"] == "ok"
  end
end
