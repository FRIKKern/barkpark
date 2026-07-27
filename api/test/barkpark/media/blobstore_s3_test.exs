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
  """
  use ExUnit.Case, async: false

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

      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert :ok = S3.put_file(rel, src, content_type: "image/png")

    assert_received {:request, "PUT", path, "png-bytes", headers}
    assert path == "/#{@bucket}/#{rel}"
    assert {"content-type", "image/png"} in headers

    # write-through cache: the pipeline reads what it just uploaded locally
    assert File.read!(Media.file_path(rel)) == "png-bytes"
  end

  test "a rejected PUT surfaces as a typed error, never a raise" do
    put_media_storage([])
    rel = unique_rel("rejected.bin")

    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 403, "denied") end)

    assert {:error, {:unexpected_status, 403}} = S3.put_bytes(rel, "x", [])
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
      send(test_pid, {:request, conn.request_path})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert :ok = S3.put_bytes(rel, "x", [])
    assert_received {:request, path}
    assert path == "/#{@bucket}/tenant-a/#{rel}"
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
