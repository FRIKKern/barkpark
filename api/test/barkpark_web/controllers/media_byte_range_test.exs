defmodule BarkparkWeb.MediaByteRangeTest do
  @moduledoc """
  HOSTED MEDIA MUST BE SEEKABLE (2026-08-24).

  Every `Range:` request used to answer `200` with the whole blob, so a
  `<video>` asking for one minute out of a 47-minute recording downloaded the
  file from byte 0. Media fragments (`#t=start,end`), scrubbing, and any
  clip-style playback were unusable on hosted video — the paper that motivated
  this carries 41 per-task clip players over ONE uploaded recording.

  Pinned here, on the real route:
    * a satisfiable range answers 206 with exactly those bytes + content-range;
    * an open-ended `bytes=N-` runs to the last byte;
    * a suffix range `bytes=-N` returns the final N bytes;
    * an out-of-range first byte answers 416, never a silent whole file;
    * no Range header still answers 200 with everything;
    * every answer advertises `accept-ranges: bytes`.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Media.Blobstore
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @path "2026/08/range-clip.mp4"
  @bytes "0123456789ABCDEF"

  setup do
    on_exit(fn -> _ = Blobstore.delete(@path) end)

    slug = "mediarange-#{System.unique_integer([:positive])}"
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: slug})
    {:ok, project} = Tenancy.create_project(ws, %{slug: slug <> "-p", name: slug})
    {:ok, dataset} = Tenancy.get_or_create_dataset(project.id, "production")

    raw = "mediarange-token-#{System.unique_integer([:positive])}"
    {:ok, _} = Barkpark.Auth.create_token(raw, slug, "production", ["read"], ws.id)

    {:ok, _} = Blobstore.put_bytes(@path, @bytes)

    %MediaFile{}
    |> MediaFile.changeset(%{
      filename: Path.basename(@path),
      original_name: Path.basename(@path),
      path: @path,
      mime_type: "video/mp4",
      size: byte_size(@bytes),
      dataset: "production",
      workspace_id: ws.id,
      project_id: project.id,
      dataset_id: dataset.id
    })
    |> Repo.insert!()

    %{ws: ws, project: project, token: raw}
  end

  defp fetch(ctx, range) do
    conn =
      scoped_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> ctx.token)

    conn = if range, do: Plug.Conn.put_req_header(conn, "range", range), else: conn
    get(conn, "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/media/files/#{@path}")
  end

  test "a satisfiable range answers 206 with exactly those bytes", ctx do
    conn = fetch(ctx, "bytes=4-7")
    assert conn.status == 206
    assert response(conn, 206) == "4567"
    assert get_resp_header(conn, "content-range") == ["bytes 4-7/16"]
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
  end

  test "an open-ended range runs to the last byte", ctx do
    conn = fetch(ctx, "bytes=12-")
    assert conn.status == 206
    assert response(conn, 206) == "CDEF"
    assert get_resp_header(conn, "content-range") == ["bytes 12-15/16"]
  end

  test "a suffix range returns the final bytes", ctx do
    conn = fetch(ctx, "bytes=-3")
    assert conn.status == 206
    assert response(conn, 206) == "DEF"
    assert get_resp_header(conn, "content-range") == ["bytes 13-15/16"]
  end

  test "a range past the end is refused, never widened to the whole file", ctx do
    conn = fetch(ctx, "bytes=99-120")
    assert conn.status == 416
    assert get_resp_header(conn, "content-range") == ["bytes */16"]
  end

  test "no Range header still answers the whole file, and advertises ranges", ctx do
    conn = fetch(ctx, nil)
    assert conn.status == 200
    assert response(conn, 200) == @bytes
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
  end
end
