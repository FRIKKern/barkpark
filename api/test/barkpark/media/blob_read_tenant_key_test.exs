defmodule Barkpark.Media.BlobReadTenantKeyTest do
  @moduledoc """
  THE BLOB READ RESOLVES WITHIN THE OWNING ROW'S TENANT (task-8eb6542ece62aff1).

  ## The failure mode this replaces

  `media_files` uniqueness is `(path, dataset_id)` but the store was addressed
  by `path` ALONE — `Blobstore.serve_strategy(file.path)`. Two rows in different
  workspaces at ONE path resolved to ONE object, so the second claimant's own
  scoped `GET /w/:ws/p/:proj/media/files/*path` answered 200 carrying the FIRST
  claimant's bytes. Silent, cross-tenant, and unrepairable by the victim:
  `authorize_blob_key/2` refused its corrective push `:blob_key_not_owned`.

  `api/test/barkpark_web/integration/media_dataset_keyed_blob_test.exs` carried
  that leak as a deliberate RESIDUAL assertion ("THE DOCUMENTED RESIDUAL"),
  whose failure message says a red there means the read path has been SEALED and
  instructs the reader to replace it with a positive assertion. This file is
  that replacement: the same two-rows-one-flat-path fixture, asserting on the
  BYTES that each tenant now gets its OWN.

  ## What is pinned here

    * THE SEAL — B's scoped GET returns B's OWN bytes, not A's. Asserted on the
      bytes, never on a status code: a 404 would also "not be A's bytes" and
      would prove nothing about B being able to hold its own.
    * THE WEDGE IS GONE — B's push at its own path is ACCEPTED, because it lands
      at B's row's `object_key` (its tenant shadow) rather than at A's object.
    * THE CONTROL — A, the canonical claimant, is UNCHANGED: 200, its own bytes,
      through the same route in the same run.
    * NO NEW REACH — neither tenant reaches the other's object, and B's write
      does not overwrite A's bytes (the cross-tenant DESTROY through the same
      hole).
    * NOTHING MOVED — a legacy FLAT row and a dataset-keyed row both serve 200
      in one run, and every row's `path` is byte-identical to what was stored.

  ## Fixture notes

  Every row carries a real `dataset_id` (a media fixture without one is
  invisible to the scoped listing and greens vacuously). Every assertion is
  scoped to this run's own ids — the test DB is shared across the agent fleet,
  so an unscoped count would meet another agent's rows.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Media
  alias Barkpark.Media.Blobstore
  alias Barkpark.Media.Storage.{MediaFile, ObjectKey}
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  import Ecto.Query

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  @bytes_a "BYTES-OWNED-BY-A"
  @bytes_b "BYTES-OWNED-BY-B"

  setup do
    %{a: make_tenant("brk-a"), b: make_tenant("brk-b")}
  end

  defp make_tenant(base) do
    slug = "#{base}-#{System.unique_integer([:positive])}"
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: slug})
    {:ok, project} = Tenancy.create_project(ws, %{slug: slug <> "-p", name: slug})
    {:ok, dataset} = Tenancy.get_or_create_dataset(project.id, "production")

    raw = "#{slug}-token"
    {:ok, _} = Barkpark.Auth.create_token(raw, slug, "production", ["read"], ws.id)

    %{ws: ws, project: project, dataset: dataset, token: raw}
  end

  # A row inserted through `MediaFile.changeset/2` — the seam every direct
  # writer (fixtures, backfills, a future importer) goes through, and the one
  # that stamps `object_key`. Returns the row and the result of the tenant's
  # push of its OWN bytes at its OWN path.
  defp claim!(tenant, path, bytes) do
    row =
      %MediaFile{}
      |> MediaFile.changeset(%{
        filename: Path.basename(path),
        original_name: Path.basename(path),
        path: path,
        mime_type: "image/png",
        size: byte_size(bytes),
        dataset: "production",
        workspace_id: tenant.ws.id,
        project_id: tenant.project.id,
        dataset_id: tenant.dataset.id
      })
      |> Repo.insert!()

    track!(row)
    {row, Media.put_blob(path, bytes, workspace_id: tenant.ws.id)}
  end

  # Blobs written by a test outlive the SQL sandbox — remove each one inline, at
  # the row's OWN object address (the same seal under test).
  defp track!(%MediaFile{} = row), do: on_exit(fn -> Blobstore.delete(row) end)

  defp upload!(tenant, name \\ "picture.png") do
    tmp = Path.join(System.tmp_dir!(), "brk-#{System.unique_integer([:positive])}.png")
    File.write!(tmp, Base.decode64!(@png_b64))

    {:ok, file} =
      Media.upload(
        %Plug.Upload{path: tmp, filename: name, content_type: "image/png"},
        "production",
        workspace_id: tenant.ws.id,
        project_id: tenant.project.id
      )

    track!(file)
    File.rm(tmp)
    file
  end

  # The REAL scoped GET route — the one the exposure was proved on.
  defp scoped_get(tenant, path) do
    build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> tenant.token)
    |> get("/w/#{tenant.ws.slug}/p/#{tenant.project.slug}/media/files/#{path}")
  end

  describe "two rows at ONE flat path" do
    setup %{a: a, b: b} do
      shared = "2026/08/hand-crafted-collision-#{System.unique_integer([:positive])}.png"

      {row_a, push_a} = claim!(a, shared, @bytes_a)
      {row_b, push_b} = claim!(b, shared, @bytes_b)

      %{shared: shared, row_a: row_a, row_b: row_b, push_a: push_a, push_b: push_b}
    end

    test "THE SEAL — B's scoped GET returns B's OWN bytes, and A's returns A's",
         ctx do
      resp_b = scoped_get(ctx.b, ctx.shared)
      resp_a = scoped_get(ctx.a, ctx.shared)

      assert resp_b.status == 200
      assert resp_a.status == 200

      # THE FLIPPED RESIDUAL. Before the seal this read @bytes_a: B's own scoped
      # route served the bytes of a row in ANOTHER workspace. Asserted on the
      # BYTES so the failure names the substitution, not a status code.
      assert resp_b.resp_body == @bytes_b,
             "cross-tenant blob READ substitution — B's own scoped route served " <>
               "#{inspect(resp_b.resp_body)}; B's own bytes are #{inspect(@bytes_b)}"

      # THE CONTROL, in the same run: the canonical claimant is UNCHANGED. Its
      # published reference still resolves to the same object it always did.
      assert resp_a.resp_body == @bytes_a,
             "the canonical claimant's published reference stopped resolving to " <>
               "its own bytes — the seal moved an object it must not move"
    end

    test "THE WEDGE IS GONE — B's push at its own path is ACCEPTED, and does not " <>
           "overwrite A's bytes",
         ctx do
      assert match?({:ok, _path, _receipt}, ctx.push_a),
             "A's push was refused: #{inspect(ctx.push_a)}"

      assert match?({:ok, _path, _receipt}, ctx.push_b),
             "B is still wedged — its push at its OWN path was refused: " <>
               "#{inspect(ctx.push_b)}"

      # The receipt still names the PUBLISHED REFERENCE, never the internal
      # object address: the caller asked about a path and gets that path back.
      {:ok, echoed, _receipt} = ctx.push_b
      assert echoed == ctx.shared

      # B writing its own bytes must not have destroyed A's.
      assert scoped_get(ctx.a, ctx.shared).resp_body == @bytes_a
    end

    test "the two rows address DIFFERENT objects, and neither path was rewritten",
         ctx do
      key_a = ObjectKey.for_row(ctx.row_a)
      key_b = ObjectKey.for_row(ctx.row_b)

      refute key_a == key_b

      # The canonical claimant keeps the flat key — that is where its bytes
      # physically are, and moving them is forbidden.
      assert key_a == ctx.shared
      assert key_b == "d/#{ctx.b.dataset.id}/#{ctx.shared}"

      # NO STORED REFERENCE REWRITTEN: both rows still hold the path documents
      # published, byte for byte.
      assert Repo.reload!(ctx.row_a).path == ctx.shared
      assert Repo.reload!(ctx.row_b).path == ctx.shared
    end

    test "COUNT — exactly the two rows this run seeded sit at the shared path", ctx do
      ids = Enum.sort([ctx.row_a.id, ctx.row_b.id])

      rows =
        MediaFile
        |> where([m], m.path == ^ctx.shared)
        |> select([m], m.id)
        |> Repo.all()
        |> Enum.sort()

      assert length(rows) == 2
      assert rows == ids
    end

    test "NO NEW REACH — B cannot address A's object by naming it", ctx do
      # B's row is the only thing B can name; its address is its own shadow.
      # Nothing B holds resolves to the canonical flat object.
      refute ObjectKey.for_row(ctx.row_b) == ObjectKey.for_row(ctx.row_a)

      # And the delete verb is row-addressed too: B removing its row must not
      # erase A's bytes (the cross-tenant DESTROY through the same hole).
      assert {:ok, _} = Media.delete_file(ctx.row_b.id, workspace_id: ctx.b.ws.id)

      resp_a = scoped_get(ctx.a, ctx.shared)
      assert resp_a.status == 200

      assert resp_a.resp_body == @bytes_a,
             "B's delete erased A's bytes — the delete is still path-addressed"
    end
  end

  describe "nothing moved for the uncontested majority" do
    test "an UNCONTESTED legacy flat row addresses its own path and serves 200", %{a: a} do
      flat = "2026/08/legacy-flat-#{System.unique_integer([:positive])}.png"
      {row, push} = claim!(a, flat, @bytes_a)

      assert match?({:ok, _p, _r}, push)
      assert ObjectKey.for_row(row) == flat

      resp = scoped_get(a, flat)
      assert resp.status == 200
      assert resp.resp_body == @bytes_a
    end

    test "a legacy FLAT row and a dataset-keyed UPLOAD both serve 200 in ONE run", %{a: a} do
      flat = "2026/08/legacy-mixed-#{System.unique_integer([:positive])}.png"
      {_row, push} = claim!(a, flat, @bytes_a)
      assert match?({:ok, _p, _r}, push)

      fresh = upload!(a)

      flat_resp = scoped_get(a, flat)
      fresh_resp = scoped_get(a, fresh.path)

      assert flat_resp.status == 200
      assert flat_resp.resp_body == @bytes_a
      assert fresh_resp.status == 200
      assert fresh_resp.resp_body == Base.decode64!(@png_b64)

      # Mixed layouts, coherent in one run.
      assert String.starts_with?(fresh.path, "d/")
      refute String.starts_with?(flat, "d/")
    end

    test "a BORN tenant-keyed upload addresses itself — the steady state is a no-op",
         %{a: a} do
      file = upload!(a)

      assert ObjectKey.for_row(file) == file.path
      assert String.starts_with?(file.path, "d/#{a.dataset.id}/")
    end
  end

  describe "ObjectKey.derive/3 — the birth decision" do
    test "a row with NO dataset_id keeps the flat path — the documented exclusion" do
      assert ObjectKey.derive(Repo, "2026/08/x.png", nil) == "2026/08/x.png"
    end

    test "a NULL object_key falls back to the path — pre-migration/raw-COPY rows" do
      assert ObjectKey.for_row(%MediaFile{path: "2026/08/x.png", object_key: nil}) ==
               "2026/08/x.png"
    end

    test "a path already born under this dataset's prefix addresses itself", %{a: a} do
      path = "d/#{a.dataset.id}/2026/08/x.png"
      assert ObjectKey.derive(Repo, path, a.dataset.id) == path
    end
  end
end
