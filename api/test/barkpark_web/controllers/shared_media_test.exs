defmodule BarkparkWeb.SharedMediaTest do
  @moduledoc """
  P3 — the share-aware scoped MEDIA surface:

    * `GET /w/:ws/p/:project/media`              (list)
    * `GET /w/:ws/p/:project/media/:id/meta`     (one asset's metadata)
    * `GET /w/:ws/p/:project/media/files/*path`  (serve the bytes)

  SECURITY CONTRACT: a `:media` share opens ONLY the read-only media surface of
  its OWN scope. The MediaController is scope-aware (every read takes the
  resolved workspace scope), so a share can never reach another workspace's
  media — a path that resolves to a different workspace 404s. Writes
  (upload/delete) and the UNSCOPED rendition route are not mounted on the share
  pipeline. Per-asset `bp_visibility` still applies on serve.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Media, Sharing}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  import Barkpark.TenancyFixtures

  @dataset "production"

  setup %{conn: conn} do
    ws_a = create_workspace!("media-share-a")
    proj_a = create_project!(ws_a, "media-share-pa")
    ws_b = create_workspace!("media-share-b")
    proj_b = create_project!(ws_b, "media-share-pb")

    # A real on-disk file per workspace, with a matching scoped MediaFile row.
    file_a = put_media!("a", @dataset, ws_a, proj_a, "BYTES-FROM-A")
    file_b = put_media!("b", @dataset, ws_b, proj_b, "BYTES-FROM-B")

    {:ok,
     conn: conn,
     ws_a: ws_a,
     proj_a: proj_a,
     ws_b: ws_b,
     proj_b: proj_b,
     file_a: file_a,
     file_b: file_b}
  end

  # ── fixtures ────────────────────────────────────────────────────────────
  defp put_media!(tag, dataset, ws, project, bytes) do
    name = "#{tag}-#{System.unique_integer([:positive])}.png"
    rel = "uploads/shared-media-test/#{name}"
    full = Media.file_path(rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, bytes)
    on_exit(fn -> File.rm_rf(Path.dirname(full)) end)

    %MediaFile{}
    |> MediaFile.changeset(%{
      filename: name,
      original_name: name,
      path: rel,
      mime_type: "image/png",
      size: byte_size(bytes),
      dataset: dataset,
      workspace_id: ws.id,
      project_id: project.id
    })
    |> Repo.insert!()
  end

  defp media_root(ws, project), do: "/w/#{ws.slug}/p/#{project.slug}/media"
  defp serve_path(ws, project, file), do: "#{media_root(ws, project)}/files/#{file.path}"
  defp meta_path(ws, project, file), do: "#{media_root(ws, project)}/#{file.id}/meta"

  defp with_shares(env_string) do
    prior = Application.get_env(:barkpark, :shares)
    Application.put_env(:barkpark, :shares, Sharing.parse(env_string))

    on_exit(fn ->
      if is_nil(prior),
        do: Application.delete_env(:barkpark, :shares),
        else: Application.put_env(:barkpark, :shares, prior)
    end)

    :ok
  end

  defp share(ws, project, surface), do: "#{ws.slug}/#{project.slug}/#{@dataset}:#{surface}:read"

  # ── (a) :media share — anonymous list is public + scope-isolated ──────────
  describe "(a) :media shared scope — anonymous list" do
    test "lists ONLY this scope's files (never another workspace's)", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      file_a: file_a,
      file_b: file_b
    } do
      with_shares(share(ws_a, proj_a, :media))

      body =
        conn
        |> get(media_root(ws_a, proj_a))
        |> json_response(200)

      ids = body["files"] |> Enum.map(& &1["id"])
      assert file_a.id in ids
      refute file_b.id in ids
    end

    test "anonymous GET /:id/meta returns this scope's file", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      file_a: file_a
    } do
      with_shares(share(ws_a, proj_a, :media))

      body = conn |> get(meta_path(ws_a, proj_a, file_a)) |> json_response(200)
      assert body["id"] == file_a.id
    end
  end

  # ── (b) serve the bytes ───────────────────────────────────────────────────
  describe "(b) :media shared scope — anonymous serve" do
    test "serves the file bytes of a public-visibility asset", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      file_a: file_a
    } do
      with_shares(share(ws_a, proj_a, :media))

      conn = get(conn, serve_path(ws_a, proj_a, file_a))
      assert conn.status == 200
      assert conn.resp_body == "BYTES-FROM-A"
    end
  end

  # ── (c) CROSS-WORKSPACE — a share can never reach another scope's bytes ────
  describe "(c) cross-workspace isolation" do
    test "A's :media share serving B's file PATH (under A's scope) 404s", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      file_b: file_b
    } do
      with_shares(share(ws_a, proj_a, :media))

      # B's real path, requested under A's shared scope: get_file_by_path is
      # scoped to A, so B's row is not found -> 404 (B's bytes never served).
      conn = get(conn, "#{media_root(ws_a, proj_a)}/files/#{file_b.path}")
      assert conn.status == 404
      refute conn.resp_body =~ "BYTES-FROM-B"
    end
  end

  # ── (d) non-shared scope stays gated ──────────────────────────────────────
  describe "(d) non-shared scope" do
    test "no share -> anonymous media list is gated", %{conn: conn, ws_a: ws_a, proj_a: proj_a} do
      Application.delete_env(:barkpark, :shares)

      conn = get(conn, media_root(ws_a, proj_a))
      assert conn.status in [401, 403, 404]
      refute conn.status == 200
    end

    test "sharing a DIFFERENT scope does not open THIS scope's media", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      with_shares("some-other-ws/some-other-proj/#{@dataset}:media:read")

      conn = get(conn, media_root(ws_a, proj_a))
      assert conn.status in [401, 403, 404]
    end
  end

  # ── (e) surface-exact — :docs / :papers do NOT open :media ────────────────
  describe "(e) surface-exact" do
    test "a :docs share on this scope leaves media gated", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      with_shares(share(ws_a, proj_a, :docs))

      assert Sharing.shared?(ws_a.slug, proj_a.slug, @dataset, :docs)
      refute Sharing.shared?(ws_a.slug, proj_a.slug, @dataset, :media)

      conn = get(conn, media_root(ws_a, proj_a))
      assert conn.status in [401, 403, 404]
    end

    test "a :papers share on this scope leaves media gated", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      with_shares(share(ws_a, proj_a, :papers))

      conn = get(conn, media_root(ws_a, proj_a))
      assert conn.status in [401, 403, 404]
    end
  end
end
