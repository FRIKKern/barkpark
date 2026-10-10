defmodule BarkparkWeb.Integration.V1MediaUploadDedupTest do
  @moduledoc """
  task-b6e57c37f6928344 — media upload dedupe by content hash.

    * every new media record stores the SHA-1 of its bytes;
    * `POST /v1/media/:ds/upload` of bytes already in the same dataset and
      workspace answers 200 with the existing asset and `existing: true`, and
      stores no second file — never across a workspace;
    * `GET /v1/media/:ds?sha1=<hex>` finds the asset, scoped like every
      other media read;
    * `mix barkpark.media.backfill_sha1`'s function hashes older rows.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Media, Repo}
  alias Barkpark.Media.Storage.MediaFile

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "v1-media-dedup-test", [
      "read",
      "write",
      "admin"
    ])

    :ok
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer barkpark-dev-token")

  defp text_upload(bytes) do
    path = Path.join(System.tmp_dir!(), "dedup-#{System.unique_integer([:positive])}.txt")
    File.write!(path, bytes)
    %Plug.Upload{path: path, filename: "note.txt", content_type: "text/plain"}
  end

  defp sha1(bytes), do: Base.encode16(:crypto.hash(:sha, bytes), case: :lower)

  defp unique_bytes, do: "dedup fixture #{System.unique_integer([:positive])} #{:rand.uniform()}"

  defp rows_with(sha1), do: Repo.aggregate(where(MediaFile, [m], m.sha1 == ^sha1), :count)

  defp upload(conn, bytes) do
    conn
    |> authed()
    |> post(~p"/v1/media/production/upload", %{"file" => text_upload(bytes)})
  end

  @tag :requires_plugins
  test "a new upload stores and reports the SHA-1 of its bytes", %{conn: conn} do
    bytes = unique_bytes()
    result = json_response(upload(conn, bytes), 201)["result"]

    assert result["sha1"] == sha1(bytes)
    assert {:ok, %MediaFile{sha1: stored}} = Media.get_file(result["id"])
    assert stored == sha1(bytes)
  end

  @tag :requires_plugins
  test "the same bytes again answer 200 with the existing asset and store no second file",
       %{conn: conn} do
    bytes = unique_bytes()
    first = json_response(upload(conn, bytes), 201)
    refute Map.has_key?(first, "existing")

    resp = upload(scoped_conn(), bytes)
    second = json_response(resp, 200)

    assert second["existing"] == true
    assert second["result"]["id"] == first["result"]["id"]
    assert second["result"]["assetDocId"] == first["result"]["assetDocId"]
    assert rows_with(sha1(bytes)) == 1, "a second media_files row was stored for the same bytes"

    # Different bytes are a new file.
    other = json_response(upload(scoped_conn(), unique_bytes()), 201)
    refute other["result"]["id"] == first["result"]["id"]
  end

  # NEGATIVE CONTROL: the same bytes in another workspace are a new file.
  test "never across a workspace: the same bytes in workspace B are a new file" do
    bytes = unique_bytes()
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)

    {:ok, in_default} = Media.upload(text_upload(bytes), "production", dedupe: true)

    assert {:ok, in_b} =
             Media.upload(text_upload(bytes), "production",
               dedupe: true,
               workspace_id: ws_b.id,
               project_id: proj_b.id
             )

    refute in_b.id == in_default.id
    assert in_b.workspace_id == ws_b.id

    # And within workspace B, a repeat now finds B's own file, not the default one.
    assert {:existing, again} =
             Media.upload(text_upload(bytes), "production",
               dedupe: true,
               workspace_id: ws_b.id,
               project_id: proj_b.id
             )

    assert again.id == in_b.id
  end

  test "dedupe is opt-in: Media.upload without it stores a second file" do
    bytes = unique_bytes()
    {:ok, a} = Media.upload(text_upload(bytes), "production")
    {:ok, b} = Media.upload(text_upload(bytes), "production")
    refute a.id == b.id
    assert a.sha1 == b.sha1
  end

  @tag :requires_plugins
  test "GET ?sha1= finds the asset; an unknown, malformed or other-workspace hash finds nothing",
       %{conn: conn} do
    bytes = unique_bytes()
    id = json_response(upload(conn, bytes), 201)["result"]["id"]

    list = fn sha ->
      scoped_conn() |> authed() |> get(~p"/v1/media/production?sha1=#{sha}") |> json_response(200)
    end

    hit = list.(sha1(bytes))
    assert Enum.map(hit["result"]["assets"], & &1["id"]) == [id]
    assert hit["result"]["total"] == 1

    # Upper-case hex is the same hash.
    assert Enum.map(list.(String.upcase(sha1(bytes)))["result"]["assets"], & &1["id"]) == [id]

    assert list.(sha1("never uploaded"))["result"]["assets"] == []
    # A malformed value narrows to nothing; it never drops the filter.
    assert list.("not-a-hash")["result"]["assets"] == []

    # The same bytes live in workspace B; the default-scoped lookup cannot see them.
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)
    other = unique_bytes()

    {:ok, _} =
      Media.upload(text_upload(other), "production", workspace_id: ws_b.id, project_id: proj_b.id)

    assert list.(sha1(other))["result"]["assets"] == []
  end

  test "backfill_sha1 hashes a row born before the column" do
    bytes = unique_bytes()
    {:ok, file} = Media.upload(text_upload(bytes), "production")
    Repo.update_all(where(MediaFile, [m], m.id == ^file.id), set: [sha1: nil])

    assert %{remaining: remaining} = Media.backfill_sha1(dry_run: true)
    assert remaining >= 1

    stats = Media.backfill_sha1()
    assert stats.hashed >= 1
    assert {:ok, %MediaFile{sha1: sha}} = Media.get_file(file.id)
    assert sha == sha1(bytes)
  end
end
