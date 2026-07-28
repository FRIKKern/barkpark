defmodule Barkpark.Media.Blobstore.S3Test do
  @moduledoc """
  Exercises the S3 backend against an in-process `Req.Test` stub — no network,
  no bucket. The stub is wired through the config's `req_options` seam
  (`plug: {Req.Test, __MODULE__}`), so the code under test builds real
  presigned URLs and sends real requests; only the transport is swapped.

  `async: false` — REQUIRED, not incidental: `put_media_storage/1` mutates
  `Application.put_env(:barkpark, :media_storage, …)`, which is PROCESS-GLOBAL
  VM state (the same reasoning as `Barkpark.MediaTest`'s media_uploads note).
  `Blobstore.impl/0` and the S3 config are read at call time, so a concurrent
  async test running `Media.upload/3` would observe this module's backend
  switch mid-flight. Serial execution is the isolation.

  `use Barkpark.DataCase` (not a bare `ExUnit.Case`) because this module now
  also covers `Media.upload/3` under the :s3 backend — the media.ex × S3 path
  that had ZERO coverage before this suite grew it. This was already the ONLY
  test file setting `backend: :s3`, and it never called `upload/3`; every other
  `Media.upload/3` call site in the suite runs under :local. That path inserts
  a `media_files` row, so it needs the SQL sandbox.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Media
  alias Barkpark.Media.Blobstore
  alias Barkpark.Media.Blobstore.S3

  @bucket "bp-test-bucket"

  defp put_media_storage(s3_overrides) do
    previous = Application.get_env(:barkpark, :media_storage)

    s3 =
      Keyword.merge(
        [
          endpoint: "https://test.r2.example.com",
          bucket: @bucket,
          region: "auto",
          access_key_id: "test-access-key",
          secret_access_key: "test-secret-key",
          req_options: [plug: {Req.Test, __MODULE__}]
        ],
        s3_overrides
      )

    Application.put_env(:barkpark, :media_storage, backend: :s3, s3: s3)
    on_exit(fn -> Application.put_env(:barkpark, :media_storage, previous) end)
  end

  defp unique_rel(name) do
    "test/blobstore-s3/#{System.unique_integer([:positive])}/#{name}"
  end

  defp tmp_source!(bytes) do
    path =
      Path.join(System.tmp_dir!(), "bp-s3-src-#{System.unique_integer([:positive])}")

    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # An HONEST in-memory bucket: a PUT actually stores the bytes, a HEAD answers
  # 200 + content-length for a key it holds and 404 for one it never took. The
  # read-back's whole job is to tell those two apart, so the stub has to be
  # able to say both.
  defp honest_bucket! do
    {:ok, agent} = Agent.start_link(fn -> %{} end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.method do
        "PUT" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Agent.update(agent, &Map.put(&1, conn.request_path, body))
          Plug.Conn.send_resp(conn, 200, "")

        "HEAD" ->
          head_resp(conn, Agent.get(agent, &Map.get(&1, conn.request_path)))

        _ ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)

    agent
  end

  defp head_resp(conn, nil), do: Plug.Conn.send_resp(conn, 404, "")

  defp head_resp(conn, body) do
    conn
    |> Plug.Conn.put_resp_header("content-length", Integer.to_string(byte_size(body)))
    |> Plug.Conn.send_resp(200, "")
  end

  test "backend selection: :s3 routes the Blobstore facade to S3" do
    put_media_storage([])
    assert Blobstore.impl() == S3
  end

  test "put_file/3 PUTs the bytes to /bucket/key with the derived content-type and warms the local cache" do
    put_media_storage([])
    rel = unique_rel("photo.png")
    src = tmp_source!("png-bytes")
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(test_pid, {:request, conn.method, conn.request_path, body, conn.req_headers})

      case conn.method do
        "HEAD" -> head_resp(conn, "png-bytes")
        _ -> Plug.Conn.send_resp(conn, 200, "")
      end
    end)

    assert {:ok, receipt} = S3.put_file(rel, src, content_type: "image/png")

    assert receipt == %{
             received: 9,
             stored: 9,
             verified_by: :head,
             unverified_reason: nil
           }

    assert_received {:request, "PUT", path, "png-bytes", headers}
    assert path == "/#{@bucket}/#{rel}"
    assert {"content-type", "image/png"} in headers

    # the post-condition read is a SECOND round trip against the same key —
    # the stated cost of the claim (2 requests per blob, not 1)
    assert_received {:request, "HEAD", ^path, _, _}

    # write-through cache: the pipeline reads what it just uploaded locally
    assert File.read!(Media.file_path(rel)) == "png-bytes"
  end

  test "a rejected PUT surfaces as a typed error, never a raise" do
    put_media_storage([])
    rel = unique_rel("rejected.bin")

    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 403, "denied") end)

    assert {:error, {:unexpected_status, 403}} = S3.put_bytes(rel, "x", [])
  end

  describe "the storage read-back" do
    test "a black-hole bucket is caught — and BOTH cheap checks are shown passing" do
      put_media_storage([])
      rel = unique_rel("blackhole.bin")
      full = Media.file_path(rel)

      # Exactly what S3.put_file/3's warm_cache leaves behind: the SOURCE bytes
      # at the path Media.file_path/1 resolves.
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, "hello-world")
      on_exit(fn -> File.rm_rf(Path.dirname(full)) end)

      # The bucket ACKs every PUT with 200 and stores NOTHING.
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.method do
          "PUT" -> Plug.Conn.send_resp(conn, 200, "")
          _ -> Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      # TRAP 1 — the obvious File.stat check passes with the EXACT expected count.
      assert {:ok, %File.Stat{size: 11}} = File.stat(full)

      # TRAP 2 — "read it back through the abstraction" also passes, and makes
      # ZERO bucket requests: ensure_local/1 short-circuits on File.regular?.
      assert {:ok, ^full} = S3.ensure_local(rel)

      # The honest read-back goes to the bucket and is not fooled.
      assert {:error, :not_found} = S3.stat_blob(rel)
      assert {:error, :not_stored} = S3.put_bytes(rel, "hello-world", [])

      # And the bucket really is empty: drop the cache copy and the abstraction
      # agrees — which is what makes TRAP 2 a lie rather than a disagreement.
      File.rm!(full)
      assert {:error, :not_found} = S3.ensure_local(rel)
    end

    test "a HEAD without content-length degrades to a NAMED :unverified, never the received count" do
      put_media_storage([])
      rel = unique_rel("no-length.bin")

      # SSE-KMS / multipart / a proxy that strips the header: the object may
      # well be there, but this instance cannot say how many bytes it holds.
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)

      assert {:error, :no_content_length} = S3.stat_blob(rel)

      assert {:ok, receipt} = S3.put_bytes(rel, "0123456789", [])

      assert receipt == %{
               received: 10,
               stored: :unverified,
               verified_by: nil,
               unverified_reason: :no_content_length
             }
    end

    test "a HEAD that cannot be performed is :unverified with the transport reason" do
      put_media_storage([])
      rel = unique_rel("head-broken.bin")

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.method do
          "PUT" -> Plug.Conn.send_resp(conn, 200, "")
          _ -> Plug.Conn.send_resp(conn, 500, "")
        end
      end)

      assert {:ok, %{stored: :unverified, unverified_reason: {:unexpected_status, 500}}} =
               S3.put_bytes(rel, "abc", [])
    end

    test "Media.put_blob/2 carries the receipt up; a short store is a failure, not a 200" do
      put_media_storage([])
      _bucket = honest_bucket!()
      rel = "uploads/2026/07/readback-#{System.unique_integer([:positive])}.png"

      assert {:ok, ^rel, %{received: 11, stored: 11, verified_by: :head}} =
               Media.put_blob(rel, "hello-world")

      # A store that answers a DIFFERENT size is a named failure. (The honest
      # bucket cannot lie, so this one is stubbed directly.)
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.method do
          "PUT" -> Plug.Conn.send_resp(conn, 200, "")
          _ -> head_resp(conn, "trunc")
        end
      end)

      short_rel = "uploads/2026/07/short-#{System.unique_integer([:positive])}.bin"
      assert {:error, {:storage_mismatch, 11, 5}} = Media.put_blob(short_rel, "hello-world")
    end
  end

  # The media.ex × S3 seam. Before the receipt landed this path had ZERO
  # coverage, and a non-:ok return from Blobstore.put_file/3 raised
  # WithClauseError out of upload/3's else-list — a bare 500 out of a module
  # whose contract is a typed 503.
  test "Media.upload/3 under :s3 accepts the receipt shape instead of raising WithClauseError" do
    put_media_storage([])
    _bucket = honest_bucket!()

    src = tmp_source!("png-bytes-here")
    upload = %Plug.Upload{filename: "s3-upload.png", path: src, content_type: "image/png"}

    assert {:ok, file} = Media.upload(upload, "test-blobstore-s3")
    assert file.size == byte_size("png-bytes-here")
    assert file.mime_type == "image/png"

    on_exit(fn -> File.rm_rf(Media.file_path(file.path)) end)
  end

  test "Media.upload/3 under :s3 reports a black-hole bucket as storage_unavailable, never a bare raise" do
    put_media_storage([])

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.method do
        "PUT" -> Plug.Conn.send_resp(conn, 200, "")
        _ -> Plug.Conn.send_resp(conn, 404, "")
      end
    end)

    src = tmp_source!("never-stored")
    upload = %Plug.Upload{filename: "ghost.png", path: src, content_type: "image/png"}

    assert {:error, :storage_unavailable} = Media.upload(upload, "test-blobstore-s3")
  end

  test "ensure_local/1 downloads a cache miss once, then serves from disk" do
    put_media_storage([])
    rel = unique_rel("cold.jpg")
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:request, conn.method, conn.request_path})
      Plug.Conn.send_resp(conn, 200, "jpeg-bytes")
    end)

    assert {:ok, full} = S3.ensure_local(rel)
    assert File.read!(full) == "jpeg-bytes"
    assert_received {:request, "GET", _}

    # warm hit: no second request
    assert {:ok, ^full} = S3.ensure_local(rel)
    refute_received {:request, _, _}
  end

  test "ensure_local/1 answers {:error, :not_found} on a bucket 404 (row outlived blob)" do
    put_media_storage([])

    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

    assert {:error, :not_found} = S3.ensure_local(unique_rel("missing.png"))
  end

  test "delete/1 removes the local cache copy and DELETEs the object" do
    put_media_storage([])
    rel = unique_rel("doomed.txt")
    test_pid = self()

    # seed a cache copy the delete must clear
    full = Media.file_path(rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "cached")

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:request, conn.method, conn.request_path})
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = S3.delete(rel)
    refute File.exists?(full)
    assert_received {:request, "DELETE", path}
    assert path == "/#{@bucket}/#{rel}"
  end

  test "serve_strategy/2 redirects to a presigned URL carrying the response-header overrides" do
    put_media_storage([])
    rel = unique_rel("evil.svg")

    assert {:redirect, url} =
             S3.serve_strategy(rel,
               response_content_type: "application/octet-stream",
               response_content_disposition: "attachment"
             )

    assert url =~ "X-Amz-Signature="
    # the stored-XSS collapse must be INSIDE the signed query, not advisory
    assert url =~ "response-content-type=application%2Foctet-stream"
    assert url =~ "response-content-disposition=attachment"
  end

  test "serve_strategy/2 with :public_base_url emits an unsigned CDN URL only for :public callers" do
    put_media_storage(public_base_url: "https://media.example.com/")
    rel = unique_rel("hero.webp")

    assert {:redirect, "https://media.example.com/" <> ^rel} =
             S3.serve_strategy(rel, public: true)

    # without the caller's vouch the presigned path (with its signed header
    # overrides) stays authoritative
    assert {:redirect, url} = S3.serve_strategy(rel, [])
    assert url =~ "X-Amz-Signature="
  end

  test "key_prefix namespaces every object key" do
    put_media_storage(key_prefix: "tenant-a")
    rel = unique_rel("scoped.png")
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:request, conn.method, conn.request_path})

      case conn.method do
        "HEAD" -> head_resp(conn, "x")
        _ -> Plug.Conn.send_resp(conn, 200, "")
      end
    end)

    assert {:ok, %{received: 1, stored: 1}} = S3.put_bytes(rel, "x", [])
    assert_received {:request, "PUT", path}
    assert path == "/#{@bucket}/tenant-a/#{rel}"
    # the read-back is namespaced by the same prefix — it must not probe the
    # un-prefixed key and report a false miss
    assert_received {:request, "HEAD", ^path}
  end

  test "selecting :s3 without its required keys fails loudly, not silently local" do
    previous = Application.get_env(:barkpark, :media_storage)
    Application.put_env(:barkpark, :media_storage, backend: :s3, s3: [bucket: @bucket])
    on_exit(fn -> Application.put_env(:barkpark, :media_storage, previous) end)

    assert_raise ArgumentError, ~r/config is incomplete/, fn ->
      S3.serve_strategy(unique_rel("x.png"), [])
    end
  end
end
