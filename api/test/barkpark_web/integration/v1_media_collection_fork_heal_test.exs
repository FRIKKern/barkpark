defmodule BarkparkWeb.Integration.V1MediaCollectionForkHealTest do
  @moduledoc """
  Read-side heal for media folders FORKED by a share before
  task-9289f78cfbe3dd3d (task-2ca003669acbe0cf).

  Sharing a published folder used to write the share link through
  `upsert_document/4`, which writes `drafts.<id>`: the folder forked into a
  published row plus a draft twin carrying the token. The write is fixed, but
  forked folders remain in deployed databases. Without touching stored data:

    (a) the forked pair lists ONCE — the published row, flagged
        `draftPending` when the draft differs;
    (b) the old share link (token on the draft) serves the PUBLISHED folder's
        assets instead of an empty gallery;
    (c) a folder that is ONLY a draft still lists and shares as before;
    (d) a draft with genuinely newer unpublished state stays readable to an
        author by its own id, and the anonymous share never shows it.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Media
  alias Barkpark.Plugins.Media.Assets

  # Each upload appends a unique trailer after IEND (still a valid PNG):

  # the v1 upload door answers repeated bytes with the existing asset

  # (task-b6e57c37f6928344), and these tests need distinct assets.

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "v1-media-fork-heal", [
      "read",
      "write",
      "admin"
    ])

    :ok
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer barkpark-dev-token")

  defp folder_attrs(id, title, extra \\ %{}) do
    %{
      "doc_id" => id,
      "title" => title,
      "content" => Map.merge(%{"kind" => "folder", "slug" => id}, extra)
    }
  end

  defp upsert!(id, title, extra \\ %{}) do
    {:ok, doc} =
      Content.upsert_document("mediaCollection", folder_attrs(id, title, extra), "production",
        source: :api
      )

    doc
  end

  defp legacy_link(token) do
    %{
      "shareLink" => %{
        "enabled" => true,
        "token" => token,
        "expiresAt" => DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
      }
    }
  end

  # The pre-fix shape: a PUBLISHED folder plus a draft twin that carries the
  # share token (and whatever else the draft had).
  defp forked_folder!(title, draft_title, token) do
    id = "col-fork-#{System.unique_integer([:positive])}"
    upsert!(id, title)
    {:ok, _} = Content.publish_document(id, "mediaCollection", "production")
    upsert!(id, draft_title, legacy_link(token))
    id
  end

  defp upload!(conn) do
    path = Path.join(System.tmp_dir!(), "fork-heal-#{:rand.uniform(1_000_000)}.png")
    File.write!(path, Base.decode64!(@png_b64) <> "#{System.unique_integer([:positive])}")
    upload = %Plug.Upload{path: path, filename: "pixel.png", content_type: "image/png"}

    conn
    |> authed()
    |> post(~p"/v1/media/production/upload", %{"file" => upload})
    |> json_response(201)
  end

  defp add!(conn, folder_id, created) do
    conn
    |> authed()
    |> post(~p"/v1/media/production/collections/#{folder_id}/members", %{
      "assetId" => created["result"]["id"]
    })
    |> json_response(200)
  end

  defp rows(conn, slug) do
    conn
    |> authed()
    |> get(~p"/v1/media/production/collections")
    |> json_response(200)
    |> get_in(["result", "collections"])
    |> Enum.filter(&(&1["slug"] == slug))
  end

  defp share_view(token) do
    scoped_conn()
    |> get("/v1/media/production/share/#{token}")
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp cleanup(created, ids) do
    for c <- created do
      File.rm(Path.join(Media.upload_dir(), c["result"]["path"]))
      Media.Renditions.delete_for_file(c["result"]["id"])
      Assets.delete_for_blob(c["result"]["id"], "production")
    end

    for id <- ids do
      Content.delete_document(id, "mediaCollection", "production")
      Content.delete_document("drafts." <> id, "mediaCollection", "production")
    end
  end

  @tag :requires_plugins
  test "(a)+(b) a forked folder lists once and its old share link serves the published folder",
       %{conn: conn} do
    token = "fork-heal-#{System.unique_integer([:positive])}"
    id = forked_folder!("Campaign", "Campaign", token)
    created = upload!(conn)
    add!(conn, id, created)

    listed = rows(conn, id)
    assert length(listed) == 1, "the forked folder is listed twice"
    [row] = listed
    assert row["id"] == id
    assert row["draftPending"] == true
    assert row["draftId"] == "drafts." <> id

    shared = share_view(token)
    assert shared["total"] == 1, "the old share link served an empty gallery"
    assert shared["collection"]["id"] == id

    cleanup([created], [id])
  end

  @tag :requires_plugins
  test "(c) a draft-only folder still lists and shares as before", %{conn: conn} do
    draft = upsert!("col-draft-only-#{System.unique_integer([:positive])}", "Draft only")
    created = upload!(conn)
    add!(conn, draft.doc_id, created)

    assert [row] = rows(conn, Content.published_id(draft.doc_id))
    assert row["id"] == draft.doc_id
    refute Map.has_key?(row, "draftPending")

    token =
      conn
      |> authed()
      |> post(~p"/v1/media/production/collections/#{draft.doc_id}/share")
      |> json_response(200)
      |> get_in(["result", "token"])

    shared = share_view(token)
    assert shared["total"] == 1
    assert shared["collection"]["id"] == draft.doc_id

    cleanup([created], [Content.published_id(draft.doc_id)])
  end

  @tag :requires_plugins
  test "(d) newer draft state stays with the author and never reaches the anonymous share",
       %{conn: conn} do
    token = "fork-heal-#{System.unique_integer([:positive])}"
    id = forked_folder!("Published name", "Unpublished rename", token)
    published_member = upload!(conn)
    draft_member = upload!(conn)
    add!(conn, id, published_member)
    add!(conn, "drafts." <> id, draft_member)

    # The author still reaches the draft — its newer name and its own member.
    draft_doc =
      conn
      |> authed()
      |> get(~p"/v1/media/production/collections/drafts.#{id}")
      |> json_response(200)

    assert draft_doc["result"]["title"] == "Unpublished rename"

    draft_assets =
      conn
      |> authed()
      |> get(~p"/v1/media/production/collections/drafts.#{id}/assets")
      |> json_response(200)

    assert Enum.map(draft_assets["result"]["hits"], & &1["id"]) == [draft_member["result"]["id"]]

    # The index flags the pending draft on the one published row.
    assert [%{"id" => ^id, "title" => "Published name", "draftPending" => true}] = rows(conn, id)

    # The anonymous share shows the published folder only.
    shared = share_view(token)
    assert shared["collection"]["title"] == "Published name"
    assert Enum.map(shared["hits"], & &1["id"]) == [published_member["result"]["id"]]

    cleanup([published_member, draft_member], [id])
  end
end
