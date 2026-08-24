defmodule BarkparkWeb.Contract.FederatedSearchMediaVisibilityClampTest do
  @moduledoc """
  Anonymous-media-leak proof for the federated search **media** surface
  (task-0fcec595765a7b00).

  `FederatedSearchController.search_surface("media", ...)` calls
  `Media.search_files/2` with NO visibility ceiling — unlike
  `V1.MediaController.search/2`'s sibling doors, which apply one. `GET
  /v1/search/:dataset` rides the `:api` pipeline, which never halts an
  anonymous caller, and `@default_surfaces` includes `"media"`, so a bare GET
  with no params fires the media surface and renders every hit through
  `AssetResponse.render(file, doc, include_urls: true)` — filename/path/size/
  visibility for `private` and `token` assets included.

  RED-FIRST: this test must FAIL on unmodified origin/main before any lib/
  edit — the private/token asset's filename surfaces in the anonymous
  federated-search hit list.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Media

  @dataset "production"
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    suffix = System.unique_integer([:positive])
    token = "fedmedia-clamp-dev-token-#{suffix}"
    Auth.create_token(token, "fedmedia clamp dev", @dataset, ["read", "write", "admin"])
    {:ok, token: token, suffix: suffix}
  end

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp png_upload(unique_name) do
    png_bin = Base.decode64!(@png_b64)
    tmp_path = Path.join(System.tmp_dir!(), "fedmedia-clamp-#{:rand.uniform(1_000_000)}.png")
    File.write!(tmp_path, png_bin)

    %Plug.Upload{
      path: tmp_path,
      filename: unique_name,
      content_type: "image/png"
    }
  end

  defp upload_asset(conn, token, unique_name) do
    conn
    |> authed(token)
    |> post(~p"/v1/media/#{@dataset}/upload", %{"file" => png_upload(unique_name)})
    |> json_response(201)
  end

  defp set_visibility!(conn, token, id, visibility) do
    conn
    |> authed(token)
    |> patch(~p"/v1/media/#{@dataset}/#{id}", %{"bp_visibility" => visibility})
    |> json_response(200)
  end

  defp cleanup(%{"result" => %{"id" => id, "path" => path}}) do
    File.rm(Path.join(Media.upload_dir(), path))
    Media.Renditions.delete_for_file(id)
    Barkpark.Plugins.Media.Assets.delete_for_blob(id, @dataset)
  end

  defp federated_media_hits(conn, q) do
    conn
    |> get(~p"/v1/search/#{@dataset}", %{"q" => q, "surfaces" => "media"})
    |> json_response(200)
    |> get_in(["results", "media", "hits"])
    |> Kernel.||([])
  end

  describe "GET /v1/search/:dataset — media surface anonymous visibility clamp" do
    test "anonymous federated search does NOT disclose a PRIVATE asset's filename",
         %{conn: conn, token: token, suffix: suffix} do
      unique_name = "zorblex-private-#{suffix}.png"
      created = upload_asset(conn, token, unique_name)
      id = created["result"]["id"]

      set_visibility!(conn, token, id, "private")

      hits = federated_media_hits(build_conn(), "zorblex-private-#{suffix}")

      ids = Enum.map(hits, & &1["id"])

      refute id in ids,
             "anonymous federated media search disclosed a PRIVATE asset: #{inspect(hits)}"

      names =
        hits
        |> Enum.flat_map(fn h -> [h["filename"], h["originalName"], h["name"]] end)
        |> Enum.reject(&is_nil/1)

      refute unique_name in names,
             "anonymous federated media search leaked the PRIVATE filename #{unique_name}"

      cleanup(created)
    end

    test "anonymous federated search does NOT disclose a TOKEN asset's filename",
         %{conn: conn, token: token, suffix: suffix} do
      unique_name = "zorblex-token-#{suffix}.png"
      created = upload_asset(conn, token, unique_name)
      id = created["result"]["id"]

      set_visibility!(conn, token, id, "token")

      hits = federated_media_hits(build_conn(), "zorblex-token-#{suffix}")
      ids = Enum.map(hits, & &1["id"])

      refute id in ids,
             "anonymous federated media search disclosed a TOKEN asset: #{inspect(hits)}"

      cleanup(created)
    end

    test "positive control: a PUBLIC asset still surfaces to an anonymous caller",
         %{conn: conn, token: token, suffix: suffix} do
      unique_name = "zorblex-public-#{suffix}.png"
      created = upload_asset(conn, token, unique_name)
      id = created["result"]["id"]

      hits = federated_media_hits(build_conn(), "zorblex-public-#{suffix}")
      ids = Enum.map(hits, & &1["id"])

      assert id in ids,
             "expected the PUBLIC asset to surface in anonymous federated media search"

      cleanup(created)
    end

    test "positive control: an AUTHENTICATED caller still sees the PRIVATE asset",
         %{conn: conn, token: token, suffix: suffix} do
      unique_name = "zorblex-authed-#{suffix}.png"
      created = upload_asset(conn, token, unique_name)
      id = created["result"]["id"]

      set_visibility!(conn, token, id, "private")

      body =
        conn
        |> authed(token)
        |> get(~p"/v1/search/#{@dataset}", %{
          "q" => "zorblex-authed-#{suffix}",
          "surfaces" => "media"
        })
        |> json_response(200)

      ids = body["results"]["media"]["hits"] |> Enum.map(& &1["id"])

      assert id in ids,
             "an authenticated caller should still see their own PRIVATE asset"

      cleanup(created)
    end
  end
end
