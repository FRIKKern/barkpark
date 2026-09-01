defmodule Barkpark.Media.Storage.ObjectKey do
  @moduledoc """
  WHICH OBJECT DOES THIS ROW ADDRESS — the read-side twin of
  `Barkpark.Media.blob_key/3` (task-8eb6542ece62aff1).

  `blob_key/3` makes a blob tenant-disjoint at BIRTH. This module makes the
  READ tenant-disjoint, which is a different problem. `media_files` uniqueness
  is `(path, dataset_id)`, so two rows in DIFFERENT tenants can hold ONE
  `path`; a store addressed by that path ALONE cannot tell them apart and hands
  the second claimant the first one's bytes — a silent cross-tenant
  substitution on the victim's OWN scoped route, which no write-side predicate
  can close (`Media.put_blob/3`'s `authorize_blob_key/2` is a WRITE guard; it
  refuses the victim's repair and leaves the read exactly as it was).

  ## The address is DECIDED ONCE, AT BIRTH, and stored

  `media_files.object_key` is stamped by `MediaFile.changeset/2` on insert and
  never recomputed. The read is then a pure field read — no query on the serve
  path at all.

  Deciding it per-read was tried and is WRONG, for a reason worth keeping: any
  rule of the form "the canonical claimant of a flat key is the earliest row at
  that path" is a function of the live row SET, so DELETING the canonical row
  silently re-points every other claimant at the flat key. In `delete_file/2`
  that is not even a race — the deferred `Blobstore.delete` runs after
  `Repo.delete` commits, so the victim would deterministically inherit the
  deleted tenant's leftover bytes. A stored address cannot move under anyone.

  ## The rule at birth (`derive/3`)

    1. No `dataset_id` → the path itself. The untenanted/legacy layer has no
       namespace to resolve within. An EXPLICIT exclusion:
       `Content.Scope.scope_to_workspace_or_global/3` already serves an
       unscoped row to every tenant, so there is one row and one identity here
       — a global-visibility question, not a substitution.
    2. A path already born tenant-keyed (`d/<this row's dataset_id>/…`) → the
       path itself. Every blob written since task-918106d49c62563e is this
       case, so the steady state is a no-op.
    3. Otherwise (a LEGACY FLAT path under a dataset) → the path itself when no
       row yet holds it, else this row's own tenant shadow
       `d/<dataset_id>/<path>`.

  ## Why "first row at the path keeps it" is the sound tie-break

  `authorize_blob_key/2` refuses the corrective push of every claimant AFTER
  the first (`:blob_key_not_owned`), and `upload/3` writes its bytes as it
  inserts. So the object physically sitting at a contested flat key can only
  have been put there by the FIRST claimant. Giving the flat key to that row
  gives it to the tenant whose bytes are actually there, and namespaces every
  other tenant away from them. At most one tenant keeps legacy continuity;
  nobody gains reach they did not have.

  ## What this deliberately does NOT do

  NO object is moved and NO stored reference is rewritten. `media_files.path`
  is a PUBLISHED REFERENCE — documents persist `"/media/files/<path>"` into
  their content and `serve/2` resolves that literal string through
  `Media.get_file_by_path/2` (pinned by
  `test/barkpark/media_path_is_a_published_reference_test.exs`). The URL keeps
  naming the path; only the STORE lookup underneath it changes. So the URL
  builders (`Delivery.Urls`, `Delivery.Cdn`, `Storage.SignedUrl`) and the
  metadata echoes (`Delivery.AssetResponse`, `Plugins.Media.Assets`, the
  controllers' JSON) keep using `file.path`, on purpose — they emit the
  published reference, not an object address.

  The shadow reuses `blob_key/3`'s `d/<dataset_id>/` namespace, so it can only
  ever collide with a fresh upload INSIDE THE SAME DATASET, and only if a
  legacy flat filename equals a 32-bit-suffixed `unique_filename/1` in the same
  date dir. Same tenant either way — never a cross-tenant reach.

  ## The two honest residuals

    * A row whose `object_key` is NULL falls back to its `path`. The
      `20260901120000` migration backfills every existing row, and
      `MediaFile.changeset/2` stamps every new one, so the only NULLs are rows
      written by a raw `COPY` that bypasses the changeset — the workspace
      bundle importer. That importer already REFUSES (PR #12873) to copy a row
      whose path another workspace owns, so it structurally cannot create the
      contested shape this module exists for.
    * Two rows inserted at the SAME flat path CONCURRENTLY in different
      datasets can both observe an empty path and both stamp the flat key, as
      `derive/3` runs inside each insert's own transaction. Reaching it needs
      two direct inserts (not `upload/3`, which prefixes at birth, and not the
      importer, which refuses) racing on one flat path. Named, not sealed.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Media.Storage.MediaFile

  @doc """
  The object address of a loaded row — THE one owner every byte-resolving
  consumer of `media_files.path` goes through.

  `Blobstore.serve_strategy/2`, `Blobstore.ensure_local/1` and
  `Blobstore.delete/1` each take a `%MediaFile{}` head that calls this, so the
  three serve doors (media / share link / ticket attachment), the rendition
  source, the probe source and the blob delete all inherit one rule from one
  place.
  """
  # @canonical capability:tenant-blob-read-key aka:object key,read key,blob address,path alone,serve key,blob substitution,media_files.path
  @spec for_row(MediaFile.t()) :: String.t() | nil
  def for_row(%MediaFile{object_key: object_key}) when is_binary(object_key), do: object_key

  # NULL `object_key` → the path, i.e. exactly today's behaviour. See "The two
  # honest residuals" above for who can still be holding a NULL and why it
  # cannot be the contested shape.
  def for_row(%MediaFile{path: path}), do: path

  @doc """
  Decide a NEW row's object address. Called once, from
  `MediaFile.changeset/2`'s `prepare_changes` hook, inside the insert's own
  transaction. See the moduledoc for the rule and the tie-break's soundness.
  """
  @spec derive(module(), String.t() | nil, String.t() | nil) :: String.t() | nil
  def derive(repo, path, dataset_id)

  def derive(_repo, path, dataset_id) when not is_binary(path) or not is_binary(dataset_id),
    do: path

  def derive(repo, path, dataset_id) do
    cond do
      # Born tenant-keyed by `Media.blob_key/3` — disjoint by construction.
      String.starts_with?(path, "d/#{dataset_id}/") -> path
      # First claimant of a flat key keeps it; every later one is namespaced.
      repo.exists?(from(m in MediaFile, where: m.path == ^path)) -> "d/#{dataset_id}/#{path}"
      true -> path
    end
  end
end
