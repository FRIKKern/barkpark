defmodule Barkpark.Media.Delivery.UrlsTest do
  # async: false — original_url / thumbnail_url / rendition_urls call Cdn.public_url,
  # which reads the global :media_cdn Application env. We reset it in setup to avoid
  # races with cdn_test.exs, which also toggles that env.
  use ExUnit.Case, async: false

  alias Barkpark.Media.Delivery.Urls
  alias Barkpark.Media.Storage.Access
  alias Barkpark.Media.Storage.MediaFile

  setup do
    original = Application.get_env(:barkpark, :media_cdn)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:barkpark, :media_cdn)
        val -> Application.put_env(:barkpark, :media_cdn, val)
      end
    end)

    # Ensure no CDN prefix so URLs are plain relative paths (easier to assert).
    Application.delete_env(:barkpark, :media_cdn)
    :ok
  end

  defp image_file do
    %MediaFile{
      id: Ecto.UUID.generate(),
      path: "2026/06/photo.jpg",
      mime_type: "image/jpeg"
    }
  end

  defp non_image_file do
    %MediaFile{
      id: Ecto.UUID.generate(),
      path: "2026/06/document.pdf",
      mime_type: "application/pdf"
    }
  end

  describe "original_url/2" do
    test "returns path under /media/files/ for image file" do
      file = image_file()
      assert Urls.original_url(file) == "/media/files/2026/06/photo.jpg"
    end

    test "returns path under /media/files/ for non-image file" do
      file = non_image_file()
      assert Urls.original_url(file) == "/media/files/2026/06/document.pdf"
    end

    test "prepends scope_prefix when provided" do
      file = image_file()
      url = Urls.original_url(file, scope_prefix: "/w/ws1/p/proj1")
      assert url == "/w/ws1/p/proj1/media/files/2026/06/photo.jpg"
    end
  end

  describe "thumbnail_url/2" do
    test "returns rendition URL for image files" do
      file = image_file()
      url = Urls.thumbnail_url(file)
      assert url =~ "/media/renditions/#{file.id}/thumb"
    end

    test "falls back to original URL for non-image files" do
      file = non_image_file()
      assert Urls.thumbnail_url(file) == Urls.original_url(file)
    end
  end

  describe "preview_url/2" do
    test "returns rendition URL for image files" do
      file = image_file()
      url = Urls.preview_url(file)
      assert url =~ "/media/renditions/#{file.id}/preview"
    end

    test "falls back to original URL for non-image files" do
      file = non_image_file()
      assert Urls.preview_url(file) == Urls.original_url(file)
    end
  end

  describe "rendition_urls/2" do
    test "returns a map with all preset keys for image files" do
      file = image_file()
      urls = Urls.rendition_urls(file)
      assert is_map(urls)
      assert map_size(urls) > 0
      assert Map.has_key?(urls, "thumb")
      assert Map.has_key?(urls, "preview")
    end

    test "every value contains the file id" do
      file = image_file()
      urls = Urls.rendition_urls(file)

      Enum.each(urls, fn {_preset, url} ->
        assert url =~ file.id
      end)
    end

    test "returns empty map for non-image files" do
      file = non_image_file()
      assert Urls.rendition_urls(file) == %{}
    end
  end

  # ── visibility-aware cache policy (charter http-edge-truth D12) ───────────

  @public_policy "public, max-age=86400, must-revalidate"

  defp tmp_blob! do
    path = "/tmp/barkpark_urls_policy_#{System.unique_integer([:positive])}.bin"
    File.write!(path, "bytes")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp headers(visibility, req_headers \\ []) do
    path = tmp_blob!()

    conn =
      Enum.reduce(req_headers, Plug.Test.conn(:get, "/media/files/x"), fn {k, v}, acc ->
        Plug.Conn.put_req_header(acc, k, v)
      end)

    {Urls.put_file_cache_headers(conn, path, visibility), Urls.etag_for(path)}
  end

  describe "put_file_cache_headers/3 — visibility matrix" do
    test ~s|"public" gets the short revalidated policy plus an etag| do
      {conn, etag} = headers("public")

      assert Plug.Conn.get_resp_header(conn, "cache-control") == [@public_policy]
      assert Plug.Conn.get_resp_header(conn, "etag") == [etag]
      assert conn.state != :sent
    end

    test ~s|"token" gets no-store and NO etag| do
      {conn, _etag} = headers("token")

      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
      assert Plug.Conn.get_resp_header(conn, "etag") == []
    end

    test ~s|"private" gets no-store and NO etag| do
      {conn, _etag} = headers("private")

      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
      assert Plug.Conn.get_resp_header(conn, "etag") == []
    end

    test "an unknown visibility value fails closed to no-store" do
      {conn, _etag} = headers("wide-open-please")

      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
      assert Plug.Conn.get_resp_header(conn, "etag") == []
    end

    test "a nil asset doc resolves to the public default (Access.visibility(nil))" do
      # Defensive default only — there are zero such subjects in production;
      # this is pinned here and NEVER claimed from a live transcript.
      assert Access.visibility(nil) == "public"

      {conn, etag} = headers(Access.visibility(nil))

      assert Plug.Conn.get_resp_header(conn, "cache-control") == [@public_policy]
      assert Plug.Conn.get_resp_header(conn, "etag") == [etag]
    end
  end

  describe "put_file_cache_headers/3 — non-public arm is inert to conditionals" do
    test ~s|a matching etag on a "private" asset still returns the full body| do
      path = tmp_blob!()
      etag = Urls.etag_for(path)

      conn =
        :get
        |> Plug.Test.conn("/media/files/x")
        |> Plug.Conn.put_req_header("if-none-match", etag)
        |> Urls.put_file_cache_headers(path, "private")

      refute conn.state == :sent
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
      assert Plug.Conn.get_resp_header(conn, "etag") == []
    end

    test ~s|a star conditional on a "token" asset still returns the full body| do
      path = tmp_blob!()

      conn =
        :get
        |> Plug.Test.conn("/media/files/x")
        |> Plug.Conn.put_req_header("if-none-match", "*")
        |> Urls.put_file_cache_headers(path, "token")

      refute conn.state == :sent
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  # ── If-None-Match conformance, RFC 9110 §13.1.2 (charter D11) ─────────────
  # Own labelled hunk: these are red against the old `[^etag | _]` pin-match,
  # which honoured ONLY a lone, exact, strong tag.

  describe "put_file_cache_headers/3 — If-None-Match conformance" do
    test "an exact strong tag still 304s" do
      path = tmp_blob!()
      etag = Urls.etag_for(path)

      conn =
        :get
        |> Plug.Test.conn("/media/files/x")
        |> Plug.Conn.put_req_header("if-none-match", etag)
        |> Urls.put_file_cache_headers(path, "public")

      assert conn.status == 304
    end

    test "a weak validator (W/) 304s" do
      path = tmp_blob!()
      etag = Urls.etag_for(path)

      conn =
        :get
        |> Plug.Test.conn("/media/files/x")
        |> Plug.Conn.put_req_header("if-none-match", "W/" <> etag)
        |> Urls.put_file_cache_headers(path, "public")

      assert conn.status == 304
    end

    test "a comma-separated list containing the tag 304s" do
      path = tmp_blob!()
      etag = Urls.etag_for(path)

      conn =
        :get
        |> Plug.Test.conn("/media/files/x")
        |> Plug.Conn.put_req_header("if-none-match", ~s|"stale-1", | <> etag <> ~s|, "stale-2"|)
        |> Urls.put_file_cache_headers(path, "public")

      assert conn.status == 304
    end

    test "the star form 304s" do
      path = tmp_blob!()

      conn =
        :get
        |> Plug.Test.conn("/media/files/x")
        |> Plug.Conn.put_req_header("if-none-match", "*")
        |> Urls.put_file_cache_headers(path, "public")

      assert conn.status == 304
    end

    test "a non-matching validator does NOT 304" do
      path = tmp_blob!()

      conn =
        :get
        |> Plug.Test.conn("/media/files/x")
        |> Plug.Conn.put_req_header("if-none-match", ~s|"not-the-tag"|)
        |> Urls.put_file_cache_headers(path, "public")

      refute conn.state == :sent
      assert conn.status == nil
    end

    # A header made only of separators carries NO entity-tag. The shared
    # matcher drops the empty entries, so nothing can match: full 200, and the
    # request never crashes on an empty candidate.
    test "a separators-only If-None-Match carries no validator and does NOT 304" do
      path = tmp_blob!()

      conn =
        :get
        |> Plug.Test.conn("/media/files/x")
        |> Plug.Conn.put_req_header("if-none-match", " , ,")
        |> Urls.put_file_cache_headers(path, "public")

      refute conn.state == :sent
      assert conn.status == nil
      assert match?([_], Plug.Conn.get_resp_header(conn, "etag"))
    end
  end

  describe "etag_for/1" do
    test "returns unknown etag for a missing path" do
      assert Urls.etag_for("/tmp/barkpark-nonexistent-#{System.unique_integer()}.bin") ==
               "\"unknown\""
    end

    test "returns a quoted size-mtime etag for an existing file" do
      path = "/tmp/barkpark_urls_test_#{System.unique_integer()}.tmp"
      File.write!(path, "hello")

      on_exit(fn -> File.rm(path) end)

      etag = Urls.etag_for(path)
      assert etag =~ ~r/^"\d+-[0-9A-Z]+"$/
    end

    test "etag changes when file content changes" do
      path = "/tmp/barkpark_urls_test_change_#{System.unique_integer()}.tmp"
      File.write!(path, "version1")
      on_exit(fn -> File.rm(path) end)

      etag1 = Urls.etag_for(path)

      # Touch the file with different content (size differs → different etag)
      :timer.sleep(1100)
      File.write!(path, "version2-longer")

      etag2 = Urls.etag_for(path)
      assert etag1 != etag2
    end
  end
end
