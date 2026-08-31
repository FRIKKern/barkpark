defmodule BarkparkWeb.MediaTransformParamsTest do
  @moduledoc """
  wb-api-media-transform-params-400 — a textbook silent failure: `serve/2` and
  `serve_rendition/2` parsed NO transform vocabulary at all (a repo-wide grep
  for `w`/`h`/`fm`/`quality`/`rect` across api/lib media code returned ZERO
  hits), so `?w=200` silently served the ORIGINAL bytes. Live prod proof
  (recorded on gfr-bl-media-transform-params-ignored): the original URL, a
  transform-laden URL, and a garbage-param URL all answered 200 with the
  IDENTICAL MD5.

  This pins the fix: a DENYLIST guard — explicitly NOT an allowlist, so
  signed-URL params (`_`/`exp`) and arbitrary CDN cache-busters keep working
  unchanged — refuses the known image-transform vocabulary with a 400 through
  the existing FallbackController envelope shape, before any blob IO runs.
  It also pins the unknown-preset half: a malformed preset name used to answer
  404 (a missing resource) and now answers 400 (a bad request), listing the
  valid preset names.

  MUTATION PROOF (pasted into the task's acceptance evidence): reverting the
  `case ignored_transform_params(conn) do` guards in `serve/2` /
  `serve_rendition/2` back to a bare call reds the two "...refused with 400"
  tests below (they observe 200 with the original bytes instead); restoring
  the guard goes green again.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Media.Blobstore
  alias Barkpark.Media.Renditions
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @path "2026/08/transform-guard.bin"
  @bytes "ORIGINAL-BYTES-UNCHANGED"

  setup do
    on_exit(fn -> _ = Blobstore.delete(@path) end)

    slug = "mediatransform-#{System.unique_integer([:positive])}"
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: slug})
    {:ok, project} = Tenancy.create_project(ws, %{slug: slug <> "-p", name: slug})
    {:ok, dataset} = Tenancy.get_or_create_dataset(project.id, "production")

    raw = "mediatransform-token-#{System.unique_integer([:positive])}"
    {:ok, _} = Barkpark.Auth.create_token(raw, slug, "production", ["read"], ws.id)

    {:ok, _} = Blobstore.put_bytes(@path, @bytes)

    file =
      %MediaFile{}
      |> MediaFile.changeset(%{
        filename: Path.basename(@path),
        original_name: Path.basename(@path),
        path: @path,
        mime_type: "application/octet-stream",
        size: byte_size(@bytes),
        dataset: "production",
        workspace_id: ws.id,
        project_id: project.id,
        dataset_id: dataset.id
      })
      |> Repo.insert!()

    %{ws: ws, project: project, token: raw, media_file: file}
  end

  defp get_scoped(ctx, path) do
    build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> ctx.token)
    |> get("/w/#{ctx.ws.slug}/p/#{ctx.project.slug}" <> path)
  end

  describe "GET .../media/files/* — transform params" do
    test "a transform param is refused with 400, never silently served", ctx do
      conn = get_scoped(ctx, "/media/files/#{@path}?w=200")

      assert conn.status == 400
      body = json_response(conn, 400)
      assert body["error"]["code"] == "unsupported_transform_param"
      assert body["error"]["details"]["ignored"] == ["w"]
      assert body["error"]["message"] =~ "w"
      assert body["error"]["message"] =~ "/media/renditions/<id>/<preset>"
    end

    test "every ignored transform param is named, not just the first", ctx do
      conn = get_scoped(ctx, "/media/files/#{@path}?w=200&h=100&fm=webp")

      assert conn.status == 400
      body = json_response(conn, 400)
      assert body["error"]["details"]["ignored"] == ["w", "h", "fm"]
    end

    test "a signed-url param set is NOT denylisted — original bytes still serve", ctx do
      conn = get_scoped(ctx, "/media/files/#{@path}?_=somesig&exp=9999999999")

      assert conn.status == 200
      assert response(conn, 200) == @bytes
    end

    test "an arbitrary CDN cache-buster param is NOT denylisted", ctx do
      conn = get_scoped(ctx, "/media/files/#{@path}?v=42&cb=1")

      assert conn.status == 200
      assert response(conn, 200) == @bytes
    end

    test "a bare request with no params is byte-identical to before", ctx do
      conn = get_scoped(ctx, "/media/files/#{@path}")

      assert conn.status == 200
      assert response(conn, 200) == @bytes
    end
  end

  describe "GET .../media/renditions/:id/:preset — transform params" do
    test "a transform param 400s before any rendition IO runs", ctx do
      conn = get_scoped(ctx, "/media/renditions/#{ctx.media_file.id}/thumb?quality=80")

      assert conn.status == 400
      body = json_response(conn, 400)
      assert body["error"]["code"] == "unsupported_transform_param"
      assert body["error"]["details"]["ignored"] == ["quality"]
      assert body["error"]["message"] =~ "/media/renditions/<id>/<preset>"
    end

    test "a signed-url param set is NOT denylisted on renditions either", ctx do
      conn = get_scoped(ctx, "/media/renditions/#{ctx.media_file.id}/not-a-real-preset?_=sig&exp=1")

      # Still reaches the unknown-preset arm — proves `_`/`exp` never entered
      # the denylist check at all, rather than happening to be allowed by luck.
      assert conn.status == 400
      assert json_response(conn, 400)["error"]["code"] == "unknown_preset"
    end

    test "an unknown preset now answers 400 naming valid presets, never 404", ctx do
      conn = get_scoped(ctx, "/media/renditions/#{ctx.media_file.id}/not-a-real-preset")

      assert conn.status == 400
      body = json_response(conn, 400)
      assert body["error"]["code"] == "unknown_preset"
      assert body["error"]["details"]["preset"] == "not-a-real-preset"
      assert body["error"]["details"]["valid_presets"] == Renditions.presets()
      assert body["error"]["message"] =~ "not-a-real-preset"
    end
  end
end
