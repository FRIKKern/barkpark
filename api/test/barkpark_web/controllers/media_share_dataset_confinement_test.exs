defmodule BarkparkWeb.MediaShareDatasetConfinementTest do
  @moduledoc """
  task-1445262e2c0b54ea — a `:media` SECTION share is minted for ONE dataset,
  but three of the four routes on the `:shared_media_api` pipeline never
  filtered their lookup by dataset at all.

  DISTINCT from task-4f26838232b5ece0 (PR #13828), which was a `?dataset=`
  escape: the guard read a DIFFERENT dataset than the controller did. Here the
  read is dataset-BLIND — the param is ignored entirely, so aligning the guard
  cannot help. `MediaController.show/2`, `serve/2` and `serve_rendition/2` all
  call `Media.get_file/2` / `Media.get_file_by_path/2` with
  `ScopeHelpers.scope_opts/1`, which carries `workspace_id` + `project_id` and
  NO dataset by design; each then reads `file.dataset` for the asset-doc
  lookup, i.e. it ADOPTS the row's dataset instead of checking it against the
  shared one.

  So a share for `production` served a file living in `staging` under the same
  (workspace, project). Bounded to cross-DATASET within one tenant —
  `confine_one/2` and the workspace/project scope still hold — but reachable
  ANONYMOUSLY by anyone holding a scoped URL.

  EVERY refusal below is paired with a control on the SAME route proving the
  route serves 200 when the dataset matches, and the negative assertions are on
  the DISTINCT BYTES / filename of the staging fixture, not merely on a status
  code — a 404 that came from a missing blob would otherwise look identical to
  a 404 that came from the fence. Both blobs and both rendition caches are
  seeded on disk precisely so the pre-fix behaviour is a real 200 carrying
  real staging bytes.

  The last test is the OVER-BLOCK control: an authenticated workspace member
  still reads the staging file on the same scoped route, because the fence
  keys on the `:share_dataset` assign, which only a share grant sets.
  """

  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Media, Repo, Sharing, Tenancy}

  @shared_dataset "production"
  @unshared_dataset "staging"

  @prod_bytes "PRODUCTION-ONLY-BYTES"
  @staging_bytes "STAGING-ONLY-BYTES"

  setup %{conn: conn} do
    ws = create_workspace!("media-ds-confine-ws")
    {:ok, proj} = Tenancy.create_project_with_dataset(ws, %{name: "media-ds-confine-proj"})

    # `Media.Delivery.Search` filters on `m.dataset_id` whenever the dataset
    # STRING resolves to a real row, so BOTH fixtures need their Dataset row
    # and the FK set — otherwise the reads come back empty and every
    # assertion below passes vacuously.
    {:ok, _} = Tenancy.create_dataset(proj, %{slug: @unshared_dataset, name: @unshared_dataset})
    shared_ds = Tenancy.get_dataset(proj, @shared_dataset)
    unshared_ds = Tenancy.get_dataset(proj, @unshared_dataset)

    shared_file = seed_file!(ws, proj, shared_ds, @shared_dataset, "prod-asset", @prod_bytes)

    unshared_file =
      seed_file!(ws, proj, unshared_ds, @unshared_dataset, "staging-asset", @staging_bytes)

    %{
      conn: put_req_header(conn, "accept", "*/*"),
      ws: ws,
      proj: proj,
      shared_file: shared_file,
      unshared_file: unshared_file
    }
  end

  # A media row PLUS its blob on disk PLUS a pre-seeded `thumb` rendition.
  # `Renditions.ensure/3` short-circuits on `File.exists?`, so the rendition
  # route answers 200 without libvips in test.
  defp seed_file!(ws, proj, dataset_row, dataset, stem, bytes) do
    suffix = System.unique_integer([:positive])
    rel = "uploads/media-ds-confine/#{stem}-#{suffix}.png"
    full = Media.file_path(rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, bytes)

    {:ok, file} =
      create_media_file_in!(
        ws,
        proj,
        %{
          filename: "#{stem}-#{suffix}.png",
          original_name: "#{stem}-#{suffix}.png",
          path: rel,
          mime_type: "image/png",
          size: byte_size(bytes),
          dataset_id: dataset_row.id
        },
        dataset
      )

    thumb_rel = Path.join(["_renditions", file.id, "thumb.jpg"])
    thumb_full = Media.file_path(thumb_rel)
    File.mkdir_p!(Path.dirname(thumb_full))
    File.write!(thumb_full, "THUMB-#{stem}")

    on_exit(fn ->
      File.rm_rf(Path.dirname(full))
      File.rm_rf(Path.dirname(thumb_full))
    end)

    file
  end

  # arpss-w8: shares are planted as STORED rows via `Barkpark.SharingFixtures`,
  # so `Sharing.refresh/0` — fired by add_share/remove_share, POST/DELETE
  # /v1/shares and the Studio shares handlers — REBUILDS this fixture instead of
  # ERASING it (a bare `put_env(:barkpark, :shares, …)` is in neither refresh
  # input). Snapshots and restores `:shares_env` as well as `:shares`.
  defp with_shares(env_string), do: Barkpark.SharingFixtures.plant_shares!(env_string)

  defp share_production_media(ws, proj),
    do: with_shares("#{ws.slug}/#{proj.slug}/#{@shared_dataset}:media:read")

  defp base(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}"

  # Assert the SHAPE (never a 2xx) rather than pinning a code, so this stays
  # true across the 403 and 404 arms of the gate.
  defp assert_refused(conn) do
    assert conn.status in [401, 403, 404],
           "expected the share's dataset fence to refuse, got #{conn.status}"

    conn
  end

  defp member_bearer!(ws) do
    raw = "media-ds-confine-#{System.unique_integer([:positive])}"

    {:ok, token} =
      %Barkpark.Auth.ApiToken{}
      |> Barkpark.Auth.ApiToken.changeset(%{
        token_hash: Barkpark.Auth.ApiToken.hash_token(raw),
        label: "media-ds-confine-member",
        dataset: @shared_dataset,
        permissions: ["read"]
      })
      |> Repo.insert()

    {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "member")
    raw
  end

  describe "GET /media/:id/meta (show/2)" do
    test "serves a file in the SHARED dataset (control — the 200 is reachable)", ctx do
      %{conn: conn, ws: ws, proj: proj, shared_file: shared} = ctx
      share_production_media(ws, proj)

      body = conn |> get("#{base(ws, proj)}/media/#{shared.id}/meta") |> json_response(200)

      assert body["filename"] == shared.filename
    end

    test "REFUSES a file living in a dataset the share never covered", ctx do
      %{conn: conn, ws: ws, proj: proj, unshared_file: unshared} = ctx
      share_production_media(ws, proj)

      refused =
        conn
        |> get("#{base(ws, proj)}/media/#{unshared.id}/meta")
        |> assert_refused()

      refute refused.resp_body =~ unshared.filename
      refute refused.resp_body =~ unshared.path
    end
  end

  describe "GET /media/files/*path (serve/2)" do
    test "serves the bytes of a file in the SHARED dataset (control)", ctx do
      %{conn: conn, ws: ws, proj: proj, shared_file: shared} = ctx
      share_production_media(ws, proj)

      body =
        conn
        |> get("#{base(ws, proj)}/media/files/#{shared.path}")
        |> response(200)

      assert body == @prod_bytes
    end

    test "REFUSES the bytes of a file living in an unshared dataset", ctx do
      %{conn: conn, ws: ws, proj: proj, unshared_file: unshared} = ctx
      share_production_media(ws, proj)

      refused =
        conn
        |> get("#{base(ws, proj)}/media/files/#{unshared.path}")
        |> assert_refused()

      refute refused.resp_body =~ @staging_bytes
    end
  end

  describe "GET /media/renditions/:id/:preset (serve_rendition/2)" do
    test "serves a rendition of a file in the SHARED dataset (control)", ctx do
      %{conn: conn, ws: ws, proj: proj, shared_file: shared} = ctx
      share_production_media(ws, proj)

      body =
        conn
        |> get("#{base(ws, proj)}/media/renditions/#{shared.id}/thumb")
        |> response(200)

      assert body =~ "THUMB-prod-asset"
    end

    test "REFUSES a rendition of a file living in an unshared dataset", ctx do
      %{conn: conn, ws: ws, proj: proj, unshared_file: unshared} = ctx
      share_production_media(ws, proj)

      refused =
        conn
        |> get("#{base(ws, proj)}/media/renditions/#{unshared.id}/thumb")
        |> assert_refused()

      refute refused.resp_body =~ "THUMB-staging-asset"
    end
  end

  describe "the fence is SHARE-ONLY (over-block control)" do
    test "an authenticated member still reads the staging file on the same route", ctx do
      %{ws: ws, proj: proj, unshared_file: unshared} = ctx
      share_production_media(ws, proj)
      raw = member_bearer!(ws)

      body =
        scoped_conn()
        |> put_req_header("accept", "*/*")
        |> put_req_header("authorization", "Bearer #{raw}")
        |> get("#{base(ws, proj)}/media/#{unshared.id}/meta")
        |> json_response(200)

      assert body["filename"] == unshared.filename
    end

    test "an authenticated member still gets the staging BYTES on the same route", ctx do
      %{ws: ws, proj: proj, unshared_file: unshared} = ctx
      share_production_media(ws, proj)
      raw = member_bearer!(ws)

      body =
        scoped_conn()
        |> put_req_header("accept", "*/*")
        |> put_req_header("authorization", "Bearer #{raw}")
        |> get("#{base(ws, proj)}/media/files/#{unshared.path}")
        |> response(200)

      assert body == @staging_bytes
    end
  end
end
