defmodule BarkparkWeb.Plugs.ResponseWarningsTest do
  @moduledoc """
  Pins `ResponseWarnings` — the `register_before_send` hook that folds queued
  `Content.Warnings` into a 2xx JSON body's top-level `warnings` key.

  The hook exists so a server-side advisory reaches ALREADY-INSTALLED clients:
  the Go CLI renders any top-level `warnings` array shape-keyed, never
  verb-keyed. That reach is exactly why the guards matter — a hook that can
  touch every JSON response can corrupt every response that only LOOKS like
  JSON. So the bulk of this file is byte-identity on the paths it must not
  touch, split by FAILURE MODE:

    * a chunked stream (`send_chunked/2`) — no single body term at before-send,
    * a binary download (`send_file/3`) — likewise, and a decode would mangle,
    * an octet-stream ATTACHMENT whose bytes happen to be valid JSON — the
      dangerous one: a decodable body behind a non-JSON content-type. Nothing
      but the content-type allowlist stops this one, and the user would see a
      broken download, never a JSON anomaly.
    * an unrecognised content-type (`text/plain`) with a decodable body — the
      fail-closed direction: not on the allowlist means untouched.

  The two `state:` guard tests drive `fold/1` on a hand-built conn because
  Plug forces `resp_body` to `nil` for `:set_file`/`:set_chunked`, which would
  make an end-to-end assertion pass for a reason other than the guard. Those
  two assert the guard; the end-to-end ones assert the real surfaces.
  """
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Barkpark.Content.Warnings
  alias BarkparkWeb.Plugs.ResponseWarnings

  @entry %{code: "cli.release_channel_stale", severity: "warning", message: "bp is 30 days old."}

  setup do
    Warnings.reset()
    :ok
  end

  defp armed do
    Warnings.reset()
    Warnings.put(@entry.code, @entry.message, @entry.severity)
    conn(:get, "/") |> ResponseWarnings.call([])
  end

  defp silent do
    Warnings.reset()
    conn(:get, "/") |> ResponseWarnings.call([])
  end

  # ── The positive path ──────────────────────────────────────────────────────

  test "folds a queued advisory into a 2xx JSON object body" do
    conn =
      armed()
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s({"transactionId":"tx1"}))

    {200, _headers, body} = sent_resp(conn)

    assert Jason.decode!(body) == %{
             "transactionId" => "tx1",
             "warnings" => [
               %{
                 "code" => @entry.code,
                 "severity" => @entry.severity,
                 "message" => @entry.message
               }
             ]
           }
  end

  test "folds into a vendor +json content type" do
    conn =
      armed()
      |> put_resp_content_type("application/vnd.barkpark+json")
      |> send_resp(200, ~s({"ok":true}))

    {200, _headers, body} = sent_resp(conn)
    assert %{"ok" => true, "warnings" => [_]} = Jason.decode!(body)
  end

  test "APPENDS to a hand-rolled warnings list rather than replacing it" do
    conn =
      armed()
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s({"warnings":["a pre-existing string warning"]}))

    {200, _headers, body} = sent_resp(conn)

    assert %{"warnings" => ["a pre-existing string warning", %{"code" => code}]} =
             Jason.decode!(body)

    assert code == @entry.code
  end

  test "drops a now-stale content-length so the adapter recomputes it" do
    conn =
      armed()
      |> put_resp_content_type("application/json")
      |> put_resp_header("content-length", "13")
      |> resp(200, ~s({"ok":true}))
      |> ResponseWarnings.fold()

    assert get_resp_header(conn, "content-length") == []
    assert %{"ok" => true, "warnings" => [_]} = Jason.decode!(conn.resp_body)
  end

  # ── Guard: an empty queue is byte-identical (condition 4) ──────────────────

  test "an empty queue leaves the JSON body BYTE-IDENTICAL, whitespace included" do
    # Deliberately hand-formatted: a decode/re-encode round trip would
    # normalise the spacing, so byte-identity here proves the body was never
    # decoded at all.
    original = ~s({"transactionId": "tx1",  "results": [ ]})

    conn =
      silent()
      |> put_resp_content_type("application/json")
      |> send_resp(200, original)

    assert {200, _headers, ^original} = sent_resp(conn)
  end

  test "an empty queue preserves an existing content-length header" do
    conn =
      silent()
      |> put_resp_content_type("application/json")
      |> put_resp_header("content-length", "11")
      |> resp(200, ~s({"ok":true}))
      |> ResponseWarnings.fold()

    assert get_resp_header(conn, "content-length") == ["11"]
    assert conn.resp_body == ~s({"ok":true})
  end

  # ── Guard: status must be 2xx ──────────────────────────────────────────────

  test "a 4xx error envelope is left BYTE-IDENTICAL — errors are Content.Errors' business" do
    original = ~s({"error": {"code": "conflict"}})

    conn =
      armed()
      |> put_resp_content_type("application/json")
      |> send_resp(409, original)

    assert {409, _headers, ^original} = sent_resp(conn)
  end

  test "a 500 body is left BYTE-IDENTICAL" do
    original = ~s({"error": {"code": "internal"}})

    conn =
      armed()
      |> put_resp_content_type("application/json")
      |> send_resp(500, original)

    assert {500, _headers, ^original} = sent_resp(conn)
  end

  test "a 3xx redirect body is left BYTE-IDENTICAL" do
    original = ~s({"location": "/elsewhere"})

    conn =
      armed()
      |> put_resp_content_type("application/json")
      |> send_resp(302, original)

    assert {302, _headers, ^original} = sent_resp(conn)
  end

  # ── Guard: content-type allowlist, fail closed ─────────────────────────────

  test "an octet-stream ATTACHMENT whose bytes are valid JSON stays BYTE-IDENTICAL" do
    # A JSON export served as a download. Decodable, so nothing but the
    # content-type allowlist stands between it and a rewritten file.
    original = ~s({"export": [1, 2, 3]})

    conn =
      armed()
      |> put_resp_content_type("application/octet-stream")
      |> put_resp_header("content-disposition", ~s(attachment; filename="export.json"))
      |> send_resp(200, original)

    assert {200, _headers, ^original} = sent_resp(conn)
  end

  test "an unrecognised content-type (text/plain) with a decodable body passes UNTOUCHED" do
    original = ~s({"looks": "like json"})

    conn =
      armed()
      |> put_resp_content_type("text/plain")
      |> send_resp(200, original)

    assert {200, _headers, ^original} = sent_resp(conn)
  end

  test "a MISSING content-type passes UNTOUCHED (absent is not on the allowlist)" do
    original = ~s({"ok":true})
    conn = armed() |> send_resp(200, original)

    assert {200, _headers, ^original} = sent_resp(conn)
  end

  test "a content-type that merely CONTAINS json is not on the allowlist" do
    original = ~s({"ok":true})

    conn =
      armed()
      |> put_resp_content_type("application/jsonp")
      |> send_resp(200, original)

    assert {200, _headers, ^original} = sent_resp(conn)
  end

  # ── Guard: non-JSON response SHAPES, end to end ────────────────────────────

  test "an SSE chunked stream is BYTE-IDENTICAL end to end" do
    conn = armed() |> put_resp_content_type("text/event-stream") |> send_chunked(200)
    {:ok, conn} = chunk(conn, ~s(data: {"a":1}\n\n))
    {:ok, conn} = chunk(conn, ~s(data: {"b":2}\n\n))

    # `Plug.Adapters.Test.Conn` never publishes a chunked response to
    # `sent_resp/1` — it accumulates into the conn — so the stream is read off
    # the conn itself.
    assert conn.state == :chunked
    assert conn.status == 200
    assert conn.resp_body == ~s(data: {"a":1}\n\ndata: {"b":2}\n\n)
  end

  test "a chunked application/json stream is BYTE-IDENTICAL end to end" do
    conn = armed() |> put_resp_content_type("application/json") |> send_chunked(200)
    {:ok, conn} = chunk(conn, "{\"rows\":[")
    {:ok, conn} = chunk(conn, "1,2]}")

    assert conn.state == :chunked
    assert conn.status == 200
    assert conn.resp_body == ~s({"rows":[1,2]})
  end

  test "a binary send_file download is BYTE-IDENTICAL end to end" do
    # A PNG header — bytes a JSON decode would refuse, and a rewrite would
    # silently corrupt into an image that will not open.
    bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82>>
    path = Path.join(System.tmp_dir!(), "rw_#{System.unique_integer([:positive])}.png")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)

    conn = armed() |> put_resp_content_type("image/png") |> send_file(200, path)

    assert {200, _headers, ^bytes} = sent_resp(conn)
  end

  test "a send_file of a JSON file behind octet-stream is BYTE-IDENTICAL end to end" do
    original = ~s({"attachment": true})
    path = Path.join(System.tmp_dir!(), "rw_#{System.unique_integer([:positive])}.json")
    File.write!(path, original)
    on_exit(fn -> File.rm(path) end)

    conn = armed() |> put_resp_content_type("application/octet-stream") |> send_file(200, path)

    assert {200, _headers, ^original} = sent_resp(conn)
  end

  # ── Guard: conn.state, asserted directly ───────────────────────────────────
  #
  # Plug forces resp_body to nil for :set_file/:set_chunked, so an end-to-end
  # test would pass even with the state guard removed. These two hand-build the
  # conn so the guard is the ONLY thing that can produce the pass.

  test "state :set_chunked declines even with a JSON content-type and a decodable body" do
    conn = armed() |> put_resp_content_type("application/json") |> resp(200, ~s({"ok":true}))
    conn = ResponseWarnings.fold(%{conn | state: :set_chunked})

    assert conn.resp_body == ~s({"ok":true})
  end

  test "state :set_file declines even with a JSON content-type and a decodable body" do
    conn = armed() |> put_resp_content_type("application/json") |> resp(200, ~s({"ok":true}))
    conn = ResponseWarnings.fold(%{conn | state: :set_file})

    assert conn.resp_body == ~s({"ok":true})
  end

  # ── Guard: the decoded body must be a JSON object ──────────────────────────

  test "a top-level JSON ARRAY has nowhere to put the key and stays BYTE-IDENTICAL" do
    original = ~s([{"_id": "a"}, {"_id": "b"}])

    conn = armed() |> put_resp_content_type("application/json") |> send_resp(200, original)

    assert {200, _headers, ^original} = sent_resp(conn)
  end

  test "a JSON scalar body stays BYTE-IDENTICAL" do
    conn = armed() |> put_resp_content_type("application/json") |> send_resp(200, ~s("ok"))

    assert {200, _headers, ~s("ok")} = sent_resp(conn)
  end

  test "an undecodable body under a JSON content-type stays BYTE-IDENTICAL" do
    original = "not json at all"

    conn = armed() |> put_resp_content_type("application/json") |> send_resp(200, original)

    assert {200, _headers, ^original} = sent_resp(conn)
  end

  test "a non-list `warnings` value makes the hook DECLINE rather than reshape the body" do
    original = ~s({"warnings": "already a string"})

    conn = armed() |> put_resp_content_type("application/json") |> send_resp(200, original)

    assert {200, _headers, ^original} = sent_resp(conn)
  end

  # ── The carrier never opens the queue ──────────────────────────────────────

  test "the plug does not open the queue — put/3 before any reset is still dropped" do
    Process.delete(:barkpark_authoring_warnings)
    conn = conn(:get, "/") |> ResponseWarnings.call([])
    refute Warnings.listening?()

    Warnings.put("never", "queued")

    conn = conn |> put_resp_content_type("application/json") |> send_resp(200, ~s({"ok":true}))

    assert {200, _headers, ~s({"ok":true})} = sent_resp(conn)
  end
end
