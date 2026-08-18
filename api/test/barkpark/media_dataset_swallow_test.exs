defmodule Barkpark.MediaDatasetSwallowTest do
  @moduledoc """
  FAIL-CLOSED proof for `Barkpark.Media` dataset resolution
  (felix-w27-bl-media-dataset-swallow-mirror).

  This is the media-context MIRROR of #12071's `WriteScope` fix, expressed in
  media's ATOM-key dialect (`:dataset` / `:dataset_id`, not string keys):

    * The old `resolve_dataset_id/2` collapsed BOTH error shapes
      `Tenancy.get_or_create_dataset/2` returns — `{:error, %Ecto.Changeset{}}`
      (format-invalid slug) AND `{:error, :dataset_not_found}` — through a bare
      `_ -> nil`. A media upload carrying a format-invalid `dataset` slug (e.g.
      "Bad Slug") then persisted a `MediaFile` row with the raw `dataset` STRING
      but `dataset_id = NULL` — split-brain: strict readers can't see it,
      string-fallback readers can. Reachable by any non-admin WRITE principal via
      `POST /media/upload` (the `dataset` param is caller-controlled).
    * The split now fails closed: a REFUSED resolution surfaces as
      `{:error, {:invalid_dataset, details}}` (→ 422 `validation_failed`, with the
      changeset messages re-keyed under the STRING "dataset" the caller sent — the
      row's `:slug` is internal) or `{:error, :conflict}` (→ 409, after one retry
      on the insert-ok/reload-nil `:dataset_not_found` race). NEVER a silent
      `dataset_id=nil` stamp, never a 500, and — crucially — never a 503: the
      threaded tuple is routed by two explicit `else` clauses in `upload/3` placed
      BEFORE the `{:error, _reason} -> storage_unavailable` (503) catch-all.

  BOTH legit-nil arms are preserved as `{:ok, nil}` (the upload still succeeds,
  `dataset_id` simply absent): (a) nil resolved project INCLUDING the
  Default-project fallback `default_project_id/0`; (b) a non-binary `dataset`
  (dead from the `is_binary` caller guard, kept defensive). `:workspace_id` /
  `:project_id` remain stamped from `opts` independent of dataset resolution.

  MUTATION KILL (the fail-before proof): revert `resolve_dataset_id_once/2`'s
  changeset arm to the old swallow — replace the two error clauses with a bare
  `_ -> {:ok, nil}` (or revert the whole resolver to `_ -> nil`) — and
  `rejects an invalid dataset slug closed` goes GREEN-WHEN-BROKEN: the invalid-slug
  upload returns `{:ok, %MediaFile{}}` with `dataset_id = nil` and a row IS
  inserted. The real split reds it (returns `{:error, {:invalid_dataset, _}}`,
  zero rows). This asserts the swallow is closed, not merely that a happy upload
  works.

  `async: false` mirrors `media_test.exs` — `Media.upload/3` writes real blobs to
  the process-global upload tree and reads process-global `:media_uploads` config.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content.Errors
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  # A real 1x1-ish PNG-named temp file. `.png` → server-derived mime `image/png`;
  # the default allow-all `:media_uploads` config lets `validate_upload/3` pass,
  # so `put_file` succeeds and control reaches `put_scope_attrs` — the seam we
  # are proving. Byte content is irrelevant (no image decode on upload).
  defp temp_upload(filename, content) do
    tmp = Path.join(System.tmp_dir!(), "mds-#{System.unique_integer([:positive])}-#{filename}")
    File.write!(tmp, content)
    %Plug.Upload{path: tmp, filename: filename, content_type: "application/octet-stream"}
  end

  defp media_row_count(dataset) do
    Repo.aggregate(from(m in MediaFile, where: m.dataset == ^dataset), :count)
  end

  describe "upload/3 dataset resolution — fail-closed mirror of #12071" do
    test "rejects an invalid dataset slug closed (422, no row, never a silent NULL / 503)" do
      ws = create_workspace!()
      proj = create_project!(ws)

      # Format-invalid per @slug_format ~r/^[a-z0-9][a-z0-9_-]*$/ — uppercase AND
      # a space both fail. A resolved project MUST be seeded (project_id: proj.id)
      # or resolve_dataset_id(_attrs, nil) short-circuits to {:ok, nil} BEFORE the
      # slug is ever validated and proves nothing (verify D188).
      bad_dataset = "Bad Slug"
      marker = "swallow-#{System.unique_integer([:positive])}"
      upload = temp_upload("shot.png", marker)

      result = Media.upload(upload, bad_dataset, project_id: proj.id)

      # Fail closed: a typed error, NEVER {:ok, %MediaFile{dataset_id: nil}}.
      assert {:error, {:invalid_dataset, details}} = result
      assert is_map(details)
      # Re-keyed under the STRING the caller sent, not the internal :slug field.
      assert %{"dataset" => msgs} = details
      assert is_list(msgs) and msgs != []

      # No row was persisted (no split-brain NULL-dataset_id orphan).
      assert media_row_count(bad_dataset) == 0

      # HTTP edge: the threaded tuple renders 422 validation_failed — never a 500,
      # and never the 503 storage_unavailable the else catch-all would mislabel.
      env = Errors.to_envelope(result, nil)
      assert env.status == 422
      assert env.code == "validation_failed"
      assert env.status != 503
      assert env.details == details
    end

    test "a valid dataset slug still succeeds and stamps dataset_id (happy path preserved)" do
      ws = create_workspace!()
      proj = create_project!(ws)

      good_dataset = "valid-dataset-#{System.unique_integer([:positive])}"
      upload = temp_upload("ok.png", "ok-bytes")

      assert {:ok, %MediaFile{} = file} =
               Media.upload(upload, good_dataset, project_id: proj.id)

      assert file.dataset == good_dataset
      # The authoritative leaf is stamped (not the old silent nil degrade).
      assert file.dataset_id != nil
      assert file.project_id == proj.id
    end

    test "Default-project fallback arm preserved: no explicit project_id → still resolves, not fail-closed" do
      # No project_id opt: put_scope_attrs falls back to default_project_id().
      # With a Default project present the valid slug resolves under it; the split
      # must NOT drag this legit fallback into the fail-closed arm — a valid slug
      # succeeds exactly as before. (The nil-project {:ok, nil} arm is only reached
      # when NO Default project is seeded; unreachable through upload/3 here, it is
      # covered by the total `resolve_dataset_id(_attrs, nil)` clause by inspection.)
      dataset = "fallback-ok-#{System.unique_integer([:positive])}"
      upload = temp_upload("plain.png", "plain-bytes")

      assert {:ok, %MediaFile{} = file} = Media.upload(upload, dataset)
      assert file.dataset == dataset
      # Default project is seeded in this sandbox → the fallback resolves an id,
      # never a silent fail. (No project_id opt → row's project_id stays nil.)
      assert file.dataset_id != nil
    end
  end
end
