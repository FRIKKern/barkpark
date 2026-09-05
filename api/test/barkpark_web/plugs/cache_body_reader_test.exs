defmodule BarkparkWeb.Plugs.CacheBodyReaderTest do
  @moduledoc """
  The path-scoped raw-body tee, and the webhook body cap that rides it.

  Two layers proven here:

    * UNIT — on the GitHub webhook path `read_body/2` accumulates the read bytes
      into `conn.assigns[:raw_body]` (across a chunked body) and OVERRIDES `:length`
      down to `github_webhook_body_cap/0`; on every other path it is a transparent
      pass-through that sets no assign and does not cap.
    * INTEGRATION — driven through the REAL `BarkparkWeb.Endpoint` `parse_body`
      chain: an OVER-cap webhook POST answers the canonical 413 `payload_too_large`
      envelope (the cap makes `Plug.Conn.read_body/2` return `{:more, ...}` →
      `Plug.Parsers.JSON` `{:error, :too_large}` → `RequestTooLargeError` → the
      endpoint's enveloped 413), while an UNDER-cap POST sails past parse_body and
      reaches `GithubWebhookSignature` (401 on a bogus signature — proof the cap
      never false-rejects a legitimate-size delivery). The endpoint's global
      `length: 100_000_000` is untouched; only this one unauthenticated route caps.

  ConnCase (not a bare unit case) because the under-cap 401 path runs the
  signature gate, which reads the webhook secret through the DB — it needs the
  Ecto sandbox. The unit tests below build their own `Plug.Test` conns and ignore
  the case's sandbox.
  """
  use BarkparkWeb.ConnCase, async: false

  import Plug.Test, only: [conn: 3]

  alias BarkparkWeb.Plugs.CacheBodyReader

  @webhook_path "/v1/plugins/github/webhook"
  @body ~s({"action":"opened","issue":{"number":7}})
  @cap_key :github_webhook_body_cap

  # Override the webhook body cap for the duration of one test, restoring the
  # prior value on exit. The cap key is read ONLY by CacheBodyReader and exercised
  # ONLY by this (async: false) module, so a global put_env is safe here.
  defp put_cap(bytes) do
    prior = Application.get_env(:barkpark, @cap_key)
    Application.put_env(:barkpark, @cap_key, bytes)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, @cap_key, prior),
        else: Application.delete_env(:barkpark, @cap_key)
    end)
  end

  defp json_conn(method, path, body) do
    conn(method, path, body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
  end

  # Loop CacheBodyReader.read_body/2 to completion, mirroring how Plug.Parsers
  # drains a chunked body, and return the accumulated read plus the final conn.
  defp read_all(conn, opts, acc \\ "") do
    case CacheBodyReader.read_body(conn, opts) do
      {:ok, chunk, conn} -> {:ok, acc <> chunk, conn}
      {:more, chunk, conn} -> read_all(conn, opts, acc <> chunk)
    end
  end

  describe "github webhook path (unit)" do
    test "caches the full body into assigns.raw_body in one read" do
      conn = json_conn(:post, @webhook_path, @body)
      assert {:ok, read, conn} = CacheBodyReader.read_body(conn, [])
      assert read == @body
      assert conn.assigns[:raw_body] == @body
    end

    test "accumulates raw_body across a chunked body (cap forces {:more})" do
      # A small cap makes read_body hand back {:more, ...} first, so we exercise
      # the multi-chunk accumulation path (not a single {:ok, ...}). The cap is the
      # length ceiling now — it drives chunking whatever :length the caller passes.
      put_cap(8)
      body = String.duplicate("x", 40)
      conn = json_conn(:post, @webhook_path, body)

      assert {:more, _chunk, _} = CacheBodyReader.read_body(conn, [])

      assert {:ok, full, conn} = read_all(conn, [])
      assert full == body
      assert conn.assigns[:raw_body] == body
    end

    test "caps :length down to the configured cap (over-cap body → {:more})" do
      put_cap(8)
      over = String.duplicate("x", 40)
      conn = json_conn(:post, @webhook_path, over)

      # Even with a caller :length of 100 MB (as Plug.Parsers passes), the cap wins.
      assert {:more, chunk, _conn} = CacheBodyReader.read_body(conn, length: 100_000_000)
      assert byte_size(chunk) <= 8
    end

    test "an under-cap body still reads through as {:ok} with the tee intact" do
      put_cap(8)
      under = "1234"
      conn = json_conn(:post, @webhook_path, under)

      assert {:ok, read, conn} = CacheBodyReader.read_body(conn, length: 100_000_000)
      assert read == under
      assert conn.assigns[:raw_body] == under
    end

    test "github_webhook_body_cap/0 defaults to 26_000_000" do
      # The wired default rejects zero legitimate deliveries (GitHub's hard 25 MB
      # ceiling). Assert the value without disturbing any env the other tests set.
      prior = Application.get_env(:barkpark, @cap_key)
      Application.delete_env(:barkpark, @cap_key)
      on_exit(fn -> if prior, do: Application.put_env(:barkpark, @cap_key, prior) end)

      assert CacheBodyReader.github_webhook_body_cap() == 26_000_000
    end
  end

  describe "every other path (unit)" do
    test "reads through with NO raw_body assign (zero buffering)" do
      conn = json_conn(:post, "/v1/data/mutate/production", @body)
      assert {:ok, read, conn} = CacheBodyReader.read_body(conn, [])
      assert read == @body
      refute Map.has_key?(conn.assigns, :raw_body)
    end

    test "a path that merely prefixes the webhook path does NOT cache" do
      conn = json_conn(:post, "/v1/plugins/github/webhook/extra", @body)
      assert {:ok, _read, conn} = CacheBodyReader.read_body(conn, [])
      refute Map.has_key?(conn.assigns, :raw_body)
    end

    test "a non-webhook path is NOT capped (the caller's :length stands)" do
      # With the cap set to 8, a 40-byte OFF-PATH body read at a large caller
      # :length must return the WHOLE body as {:ok}. Had the cap leaked to this
      # path it would have truncated the read to {:more} at 8 bytes.
      put_cap(8)
      body = String.duplicate("x", 40)
      conn = json_conn(:post, "/v1/data/mutate/production", body)

      assert {:ok, read, _conn} = CacheBodyReader.read_body(conn, length: 100_000_000)
      assert read == body
    end
  end

  describe "webhook body cap end-to-end (through the real endpoint)" do
    @bogus_sig "sha256=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

    defp deliver(body) do
      scoped_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-event", "issues")
      |> put_req_header("x-hub-signature-256", @bogus_sig)
      |> post(@webhook_path, body)
    end

    test "an OVER-cap webhook POST answers the canonical 413 payload_too_large envelope" do
      put_cap(64)
      # 200 bytes > 64-byte cap → read_body {:more} → RequestTooLargeError → 413.
      over = ~s({"action":"opened","filler":"#{String.duplicate("A", 200)}"})

      conn = deliver(over)

      assert %{"error" => %{"code" => "payload_too_large"}} = json_response(conn, 413)
    end

    test "an UNDER-cap webhook POST sails past parse_body and reaches the 401 signature gate" do
      put_cap(64)
      # 20-ish bytes < 64-byte cap → parse_body succeeds, the tee runs, and the
      # bogus signature is rejected by GithubWebhookSignature — NOT a 413. This is
      # the behavior-preservation proof: the cap never rejects a legitimate size.
      under = ~s({"action":"x"})

      conn = deliver(under)

      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
    end
  end
end
