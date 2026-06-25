defmodule Barkpark.Sync.SSETest do
  @moduledoc """
  THE deterministic wire seam. Pure, no DB, no network — feed exact producer
  bytes into `Barkpark.Sync.SSE.parse_frames/1` and assert the framing rules.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Sync.SSE

  # A mutation frame in the exact shape ListenController.format_event/2 emits.
  defp mutation_frame(id, envelope) do
    "id: #{id}\nevent: mutation\ndata: #{Jason.encode!(envelope)}\n\n"
  end

  test "decodes a mutation envelope and takes the cursor id from the id: line" do
    envelope = %{
      "eventId" => 7,
      "mutation" => "update",
      "type" => "post",
      "documentId" => "drafts.p1",
      "rev" => "abc123",
      "previousRev" => "old",
      "result" => %{"_id" => "drafts.p1", "_type" => "post"},
      "syncTags" => ["bp:ds:test:doc:p1"]
    }

    assert {[event], ""} = SSE.parse_frames(mutation_frame(7, envelope))
    assert event.id == 7
    assert event.type == "mutation"
    assert event.envelope["eventId"] == 7
    assert event.envelope["documentId"] == "drafts.p1"
    assert event.envelope["result"]["_type"] == "post"
  end

  test "skips the welcome and keepalive frames (no event, no cursor advance)" do
    bytes = ~s(event: welcome\ndata: {"type":"welcome"}\n\n: keepalive\n\n)
    assert {[], ""} = SSE.parse_frames(bytes)
  end

  test "buffers a frame split across two chunks and emits it once whole" do
    whole = mutation_frame(3, %{"eventId" => 3, "result" => %{"_id" => "x"}})
    {chunk_a, chunk_b} = String.split_at(whole, 18)

    # First chunk has no blank-line delimiter yet — nothing emitted, carried.
    assert {[], rest} = SSE.parse_frames(chunk_a)
    assert rest != ""

    # Prepending the carried remainder completes the frame exactly once.
    assert {[event], ""} = SSE.parse_frames(rest <> chunk_b)
    assert event.id == 3
  end

  test "joins multiple data: lines with newline and strips one leading space" do
    # Two data: lines whose newline-join forms valid JSON. The leading space
    # after each colon must be stripped.
    bytes = "id: 2\nevent: mutation\ndata: {\"a\":1,\ndata: \"b\":2}\n\n"

    assert {[event], ""} = SSE.parse_frames(bytes)
    assert event.id == 2
    assert event.envelope == %{"a" => 1, "b" => 2}
  end

  test "decodes several frames in one buffer and carries a trailing partial" do
    full =
      mutation_frame(10, %{"eventId" => 10, "result" => %{"_id" => "a"}}) <>
        mutation_frame(11, %{"eventId" => 11, "result" => %{"_id" => "b"}}) <>
        "id: 12\nevent: mutation\ndata: {\"eventId\":12"

    assert {[e10, e11], rest} = SSE.parse_frames(full)
    assert e10.id == 10
    assert e11.id == 11
    assert rest =~ "eventId"
  end
end
