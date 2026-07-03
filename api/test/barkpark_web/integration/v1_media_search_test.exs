defmodule BarkparkWeb.Integration.V1MediaSearchTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Media
  alias Barkpark.Plugins.Media.Assets

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "v1-media-search-test",
      ["read", "write", "admin"]
    )

    drain_task_supervisor(30_000)
    :ok
  end

  defp drain_task_supervisor(deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_drain(deadline)
  end

  defp do_drain(deadline) do
    case Task.Supervisor.children(Barkpark.TaskSupervisor) do
      [] ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(50)
          do_drain(deadline)
        end
    end
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer barkpark-dev-token")

  defp png_upload(name \\ "pixel.png") do
    png_bin = Base.decode64!(@png_b64)
    tmp_path = Path.join(System.tmp_dir!(), "search-#{:rand.uniform(1_000_000)}.png")
    File.write!(tmp_path, png_bin)

    %Plug.Upload{
      path: tmp_path,
      filename: name,
      content_type: "image/png"
    }
  end

  defp upload_as(conn, filename, content_type) do
    png_bin = Base.decode64!(@png_b64)
    tmp_path = Path.join(System.tmp_dir!(), "search-#{:rand.uniform(1_000_000)}")
    File.write!(tmp_path, png_bin)

    upload = %Plug.Upload{path: tmp_path, filename: filename, content_type: content_type}

    conn
    |> authed()
    |> post(~p"/v1/media/production/upload", %{"file" => upload})
    |> json_response(201)
    |> Map.fetch!("result")
  end

  defp facet_values(facets, field) do
    facets
    |> Map.get(field, [])
    |> Enum.map(& &1["value"])
  end

  defp upload_tagged(conn, filename, tags) do
    created =
      conn
      |> authed()
      |> post(~p"/v1/media/production/upload", %{"file" => png_upload(filename)})
      |> json_response(201)

    id = created["result"]["id"]

    if tags != [] do
      conn
      |> authed()
      |> patch(~p"/v1/media/production/#{id}", %{"tags" => tags})
    end

    created["result"]
  end

  defp cleanup(%{"id" => id, "path" => path}) do
    File.rm(Path.join(Media.upload_dir(), path))
    Media.Renditions.delete_for_file(id)
    Assets.delete_for_blob(id, "production")
  end

  describe "GET /v1/media/:dataset/search" do
    test "returns hits with delivery URLs and facets", %{conn: conn} do
      hero = upload_tagged(conn, "hero-banner.png", ["hero", "homepage"])
      _other = upload_tagged(conn, "other-shot.png", ["archive"])

      resp =
        conn
        |> get(~p"/v1/media/production/search?facets=kind,tags&facet.tags=hero")
        |> json_response(200)

      assert resp["result"]["total"] >= 1
      hits = resp["result"]["hits"]
      assert is_list(hits)
      assert Enum.all?(hits, &(&1["thumbnailUrl"] =~ "/media/renditions/"))

      hero_hit = Enum.find(hits, &(&1["id"] == hero["id"]))
      assert hero_hit
      assert hero_hit["asset"]["tags"] == ["hero", "homepage"]

      assert is_map(resp["result"]["facets"])
      assert is_list(resp["result"]["facets"]["kind"])

      cleanup(hero)
      cleanup(_other)
    end

    test "q matches asset title with relevance sort", %{conn: conn} do
      created =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{"file" => png_upload("mountain.png")})
        |> json_response(201)

      id = created["result"]["id"]

      conn
      |> authed()
      |> patch(~p"/v1/media/production/#{id}", %{"title" => "Alpine summit panorama"})

      resp =
        conn
        |> get(~p"/v1/media/production/search?q=Alpine&sort=relevance&facets=kind")
        |> json_response(200)

      assert Enum.any?(resp["result"]["hits"], &(&1["id"] == id))
      cleanup(created["result"])
    end

    test "q matches asset tags", %{conn: conn} do
      tagged = upload_tagged(conn, "tagged-search.png", ["campaign", "spring"])

      resp =
        conn
        |> get(~p"/v1/media/production/search?q=campaign&facets=kind")
        |> json_response(200)

      assert Enum.any?(resp["result"]["hits"], &(&1["id"] == tagged["id"]))
      cleanup(tagged)
    end

    test "kind filter via facet.kind selection", %{conn: conn} do
      png = upload_tagged(conn, "facet-kind.png", [])

      resp =
        conn
        |> get(~p"/v1/media/production/search?facet.kind=image&facets=kind")
        |> json_response(200)

      assert Enum.all?(resp["result"]["hits"], fn hit ->
               hit["asset"]["bp_asset_kind"] == "image"
             end)

      cleanup(png)
    end

    # Regression: a facet must be computed with ITS OWN filter removed so the
    # drill-down shows every option. When the filter arrives as a TOP-LEVEL opt
    # (`?kind=image`) instead of `facet.kind=`, the kind facet must NOT collapse
    # to just "image" — it should still report every kind, while the hits stay
    # filtered to image.
    test "top-level ?kind= does not collapse the kind facet", %{conn: conn} do
      image = upload_as(conn, "top-level-kind.png", "image/png")
      doc = upload_as(conn, "top-level-doc.pdf", "application/pdf")

      resp =
        conn
        |> get(~p"/v1/media/production/search?kind=image&facets=kind")
        |> json_response(200)

      # Hits stay filtered to image only.
      assert Enum.all?(resp["result"]["hits"], fn hit ->
               hit["asset"]["bp_asset_kind"] == "image"
             end)

      assert Enum.any?(resp["result"]["hits"], &(&1["id"] == image["id"]))
      refute Enum.any?(resp["result"]["hits"], &(&1["id"] == doc["id"]))

      # Facet reports ALL kinds (not collapsed to the selected "image").
      kinds = facet_values(resp["result"]["facets"], "kind")
      assert "image" in kinds
      assert "document" in kinds

      cleanup(image)
      cleanup(doc)
    end

    # Second field via a different top-level opt (`?type=` → :mime_type). The
    # mimeType facet must still enumerate every mime, not collapse to the
    # selected prefix.
    test "top-level ?type= does not collapse the mimeType facet", %{conn: conn} do
      image = upload_as(conn, "top-level-mime.png", "image/png")
      doc = upload_as(conn, "top-level-mime.pdf", "application/pdf")

      resp =
        conn
        |> get(~p"/v1/media/production/search?type=image&facets=mimeType")
        |> json_response(200)

      # Hits stay filtered to image/* only.
      assert Enum.any?(resp["result"]["hits"], &(&1["id"] == image["id"]))
      refute Enum.any?(resp["result"]["hits"], &(&1["id"] == doc["id"]))

      # Facet reports ALL mime types (not collapsed to "image/png").
      mimes = facet_values(resp["result"]["facets"], "mimeType")
      assert "image/png" in mimes
      assert "application/pdf" in mimes

      cleanup(image)
      cleanup(doc)
    end
  end
end
