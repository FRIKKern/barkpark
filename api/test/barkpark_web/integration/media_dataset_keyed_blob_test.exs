defmodule BarkparkWeb.Integration.MediaDatasetKeyedBlobTest do
  @moduledoc """
  The blob object space is keyed on `dataset_id` at BIRTH (task-918106d49c62563e).

  ## The failure mode

  The keyspace was FLAT: `Blobstore` resolves an object by the very string
  `media_files.path` holds, while `media_files` uniqueness is `(path,
  dataset_id)`. Two tenants could hold a row at ONE path, and the loser's own
  scoped `GET /w/:ws/p/:proj/media/files/*path` answered 200 carrying the
  winner's bytes — silent, cross-tenant, and unrepairable by the victim
  (`authorize_blob_key/2` refuses its corrective push `:blob_key_not_owned`).

  ## What this pins

    * `upload/3` emits `d/<dataset_id>/YYYY/MM/<unique_filename>` when the write
      carries a `dataset_id`, and the UNCHANGED flat shape when it does not.
    * The object key and `media_files.path` are ONE variable — proved through the
      REAL GET route, never a `File.read`. A store that accepts writes it cannot
      serve is worse than the leak.
    * Two datasets holding the SAME source tail no longer share one object: each
      serves its OWN bytes, neither reaches the other's, and the victim's push at
      its own key is now ACCEPTED (the wedge is gone).
    * NO object is moved and NO existing path is rewritten: an old flat row and a
      new dataset-keyed row both serve 200 in the SAME run.

  ## The read path is sealed too (task-8eb6542ece62aff1)

  This file used to end on a DOCUMENTED RESIDUAL asserting the leak as current
  truth: hand-crafted rows sharing one flat path still substituted on read,
  because the store was addressed by `media_files.path` ALONE. That is closed.
  `media_files.object_key` holds each row's OWN object address — decided once at
  insert by `Media.Storage.ObjectKey.derive/3`, backfilled by migration
  `20260901120000` — and every byte-resolving consumer of `path`
  (`Blobstore.serve_strategy/2`, `ensure_local/1`, `delete/1`, each via a
  `%MediaFile{}` head) goes through `ObjectKey.for_row/1`. The last describe
  block is now the POSITIVE assertion, in both directions.

  Deeper coverage of the read seal — the delete arm, the uncontested majority,
  the birth decision — lives in
  `test/barkpark/media/blob_read_tenant_key_test.exs`.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Media
  alias Barkpark.Media.Blobstore
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  # 1x1 transparent PNG. Same fixture the /media integration probe uses.
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  @shared_tail "2026/08/same-source-path.png"
  @legacy_flat_path "2026/08/legacy-flat-row.png"
  @bytes_a "BYTES-OWNED-BY-A"
  @bytes_b "BYTES-OWNED-BY-B"

  setup do
    a = make_tenant("dkb-a")
    b = make_tenant("dkb-b")

    %{a: a, b: b}
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

  defp upload!(tenant, name \\ "picture.png") do
    tmp = Path.join(System.tmp_dir!(), "dkb-#{System.unique_integer([:positive])}.png")
    File.write!(tmp, Base.decode64!(@png_b64))

    {:ok, file} =
      Media.upload(
        %Plug.Upload{path: tmp, filename: name, content_type: "image/png"},
        "production",
        workspace_id: tenant.ws.id,
        project_id: tenant.project.id
      )

    track!(file.path)
    File.rm(tmp)
    file
  end

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

    track!(path)
    {row, Media.put_blob(path, bytes, workspace_id: tenant.ws.id)}
  end

  # Blobs written by a test outlive the SQL sandbox — remove each one inline.
  defp track!(path), do: on_exit(fn -> Blobstore.delete(path) end)

  # The DIRECTORY the write seam chose for this tenant, obtained by asking the
  # seam rather than by restating its rule here. The probe row + object are
  # discarded; only the directory survives.
  defp seam_dir(tenant) do
    probe = upload!(tenant, "seam-probe.png")
    dir = Path.dirname(probe.path)
    Blobstore.delete(probe.path)
    Repo.delete!(probe)
    dir
  end

  # The REAL scoped GET route — the one the exposure was proved on.
  defp scoped_get(tenant, path) do
    build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> tenant.token)
    |> get("/w/#{tenant.ws.slug}/p/#{tenant.project.slug}/media/files/#{path}")
  end

  describe "criterion 1 — the emitted key shape" do
    test "upload/3 emits d/<dataset_id>/YYYY/MM/<file> when the write carries a dataset_id", %{
      a: a
    } do
      file = upload!(a)

      assert [prefix, dataset_id, year, month, name] = String.split(file.path, "/")
      assert prefix == "d"
      assert dataset_id == a.dataset.id
      assert year =~ ~r/\A\d{4}\z/
      assert month =~ ~r/\A\d{2}\z/
      assert name =~ ~r/\.png\z/
    end

    test "two datasets get DISJOINT key spaces — the separation is structural, not the " <>
           "32-bit filename suffix",
         %{a: a, b: b} do
      file_a = upload!(a)
      file_b = upload!(b)

      ["d", ds_a | tail_a] = String.split(file_a.path, "/")
      ["d", ds_b | tail_b] = String.split(file_b.path, "/")

      refute ds_a == ds_b

      # THE DECISIVE ASSERTION: transplant B's exact tail under A's prefix. Even
      # if the two 32-bit suffixes had collided, the objects are still distinct.
      assert "d/#{ds_a}/#{Enum.join(tail_b, "/")}" != file_b.path
      assert "d/#{ds_b}/#{Enum.join(tail_a, "/")}" != file_a.path
    end

    test "a write with NO dataset_id keeps the UNCHANGED flat shape", %{a: a} do
      # Every test install seeds a Default project, so `upload/3` always resolves
      # a dataset_id here — the legacy arm is unreachable through the HTTP seam
      # and is pinned at its owner instead. A conditional assertion would have
      # been a tautology: one of its branches can never run.
      assert Media.blob_key("2026/08", "x.png", nil) == "2026/08/x.png"
      assert Media.blob_key("2026/08", "x.png", a.dataset.id) == "d/#{a.dataset.id}/2026/08/x.png"
    end
  end

  describe "criterion 1 — key and row are ONE variable" do
    test "the uploaded row serves its OWN bytes through the REAL GET route", %{a: a} do
      file = upload!(a)

      resp = scoped_get(a, file.path)

      assert resp.status == 200,
             "the store accepted a write it cannot serve — the object key and " <>
               "media_files.path have DIVERGED (got #{resp.status} at #{file.path})"

      assert resp.resp_body == Base.decode64!(@png_b64)
    end
  end

  describe "criterion 3 — two tenants at the SAME source path no longer share an object" do
    setup %{a: a, b: b} do
      # THE KEYS COME FROM THE SEAM, not from this test. Each tenant uploads a
      # throwaway probe, we keep the DIRECTORY the seam chose, and put the SAME
      # final segment in it. That is "two workspaces holding the same source
      # path" with only the 32-bit random suffix — the thing that was never the
      # reachable case — removed.
      #
      # Before the prefix, both directories are `YYYY/MM` and the two keys are
      # IDENTICAL: the collision, reproduced through the real write seam.
      key_a = seam_dir(a) <> "/" <> @shared_tail
      key_b = seam_dir(b) <> "/" <> @shared_tail

      {_row_a, push_a} = claim!(a, key_a, @bytes_a)
      {_row_b, push_b} = claim!(b, key_b, @bytes_b)

      %{key_a: key_a, key_b: key_b, push_a: push_a, push_b: push_b}
    end

    test "each tenant's scoped GET returns its OWN bytes", ctx do
      resp_a = scoped_get(ctx.a, ctx.key_a)
      resp_b = scoped_get(ctx.b, ctx.key_b)

      assert resp_a.status == 200
      assert resp_b.status == 200

      assert resp_a.resp_body == @bytes_a

      assert resp_b.resp_body == @bytes_b,
             "cross-tenant blob READ substitution — B's own scoped route served " <>
               "#{inspect(resp_b.resp_body)}; B's own bytes are #{inspect(@bytes_b)}"
    end

    test "THE WEDGE IS GONE — B's push at its own key is ACCEPTED, not :blob_key_not_owned",
         ctx do
      assert {:ok, _p, _r} = ctx.push_b
      assert {:ok, _p, _r} = ctx.push_a
    end

    test "NO NEW REACH — B cannot read A's key on its own scoped route", ctx do
      resp = scoped_get(ctx.b, ctx.key_a)
      assert resp.status == 404
    end
  end

  describe "criterion 5 — no object moved, no existing path rewritten" do
    test "an OLD flat row and a NEW dataset-keyed row both serve 200 in the SAME run", %{a: a} do
      {_legacy_row, legacy_push} = claim!(a, @legacy_flat_path, @bytes_a)
      assert {:ok, _p, _r} = legacy_push

      fresh = upload!(a)

      legacy_resp = scoped_get(a, @legacy_flat_path)
      fresh_resp = scoped_get(a, fresh.path)

      assert legacy_resp.status == 200,
             "a pre-existing FLAT row stopped resolving — the prefix is not forward-only"

      assert legacy_resp.resp_body == @bytes_a

      assert fresh_resp.status == 200
      assert String.starts_with?(fresh.path, "d/")

      # Mixed layouts, coherent in one run: one flat key, one prefixed key, both live.
      refute String.starts_with?(@legacy_flat_path, "d/")
    end
  end

  describe "THE RESIDUAL IS CLOSED — the read path is sealed too" do
    # This describe block replaces "THE DOCUMENTED RESIDUAL — the read path is
    # NOT sealed by this change" (task-8eb6542ece62aff1). That test asserted the
    # leak AS CURRENT TRUTH — B's scoped GET returning @bytes_a — and its failure
    # message instructed whoever sealed the read path to replace it with exactly
    # this. It is now a POSITIVE assertion, on the BYTES, in both directions.
    #
    # The seal: `media_files.object_key` holds each row's OWN object address,
    # decided once at insert by `Media.Storage.ObjectKey.derive/3` and reached by
    # every byte-resolving consumer through `ObjectKey.for_row/1`. The canonical
    # claimant of a flat key keeps it (its bytes are the ones physically there);
    # every later claimant addresses its own tenant shadow.
    test "hand-crafted rows sharing one FLAT path each serve their OWN bytes", %{a: a, b: b} do
      shared = "2026/08/hand-crafted-collision.png"

      {_row_a, push_a} = claim!(a, shared, @bytes_a)
      assert {:ok, _p, _r} = push_a

      # B claims the SAME flat key. THE WEDGE IS GONE: B's push is now ACCEPTED,
      # landing at B's own row's object address rather than on top of A's bytes.
      {_row_b, push_b} = claim!(b, shared, @bytes_b)

      assert match?({:ok, _p, _r}, push_b),
             "B is still wedged out of its own key: #{inspect(push_b)}"

      resp_b = scoped_get(b, shared)
      resp_a = scoped_get(a, shared)

      assert resp_b.resp_body == @bytes_b,
             "cross-tenant blob READ substitution — B's own scoped route served " <>
               "#{inspect(resp_b.resp_body)}; B's own bytes are #{inspect(@bytes_b)}"

      # The other direction, in the same run: the canonical claimant is UNTOUCHED.
      # B acquiring its own bytes must not have moved or overwritten A's.
      assert resp_a.resp_body == @bytes_a,
             "A's published reference stopped resolving to its own bytes — the " <>
               "seal moved an object it must not move"
    end
  end
end
