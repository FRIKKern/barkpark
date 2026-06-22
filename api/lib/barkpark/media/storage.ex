defmodule Barkpark.Media.Storage do
  @moduledoc """
  media-storage layer — the persistence + governance floor.

  Owns the media blob row, its access/checkout governance, collection
  membership, the relation graph, signed-URL signing, and public share links.
  This context module re-exports the layer's modules so callers can depend on
  the layer rather than reaching into raw structs:

    * `Barkpark.Media.Storage.MediaFile`    — the `media_files` Ecto schema
    * `Barkpark.Media.Storage.SignedUrl`    — HMAC signing for embed URLs
    * `Barkpark.Media.Storage.Access`       — per-asset delivery/edit permissions
    * `Barkpark.Media.Storage.Checkout`     — editorial checkout locks
    * `Barkpark.Media.Storage.Collections`  — folder/virtual collection membership
    * `Barkpark.Media.Storage.Relations`    — asset relation graph
    * `Barkpark.Media.Storage.Share`        — public collection share links

  This is the BOTTOM media layer: it depends downward on the content / tenancy
  / auth / repo kernel only. Nothing here calls up into `media-processing` or
  `media-delivery`.

  Additive — existing callers that already reach the sub-modules directly keep
  working; new callers may depend on this façade instead.
  """

  alias Barkpark.Media.Storage.{
    Access,
    Checkout,
    Collections,
    MediaFile,
    Relations,
    Share,
    SignedUrl
  }

  # ── blob row (MediaFile) ──────────────────────────────────────────────────

  defdelegate changeset(media_file, attrs), to: MediaFile

  # ── signed embed URLs (SignedUrl) ─────────────────────────────────────────
  # Functions carrying default args (\\) are exposed as explicit thin wrappers
  # rather than bare defdelegate so every external arity stays callable.

  def sign(path, media_file_id, opts \\ []), do: SignedUrl.sign(path, media_file_id, opts)
  defdelegate verify?(media_file_id, path, params), to: SignedUrl
  defdelegate params_from_conn(conn), to: SignedUrl

  # ── access governance (Access) ────────────────────────────────────────────

  defdelegate visibility(doc), to: Access
  defdelegate watermark_profile(doc), to: Access
  defdelegate allowed?(conn, file, doc, level), to: Access
  defdelegate permissions(conn, file, doc), to: Access

  # ── editorial checkout (Checkout) ─────────────────────────────────────────

  defdelegate checkout(file, actor, dataset), to: Checkout
  defdelegate undo_checkout(file, actor, dataset, admin?), to: Checkout

  # ── collection membership (Collections) ───────────────────────────────────

  def list_collections(dataset, opts \\ []), do: Collections.list(dataset, opts)

  def get_collection(collection_id, dataset, opts \\ []),
    do: Collections.get(collection_id, dataset, opts)

  def collection_assets(collection_id, dataset, opts \\ []),
    do: Collections.assets(collection_id, dataset, opts)

  def add_member(collection_id, file, dataset, opts \\ []),
    do: Collections.add_member(collection_id, file, dataset, opts)

  def remove_member(collection_id, file, dataset, opts \\ []),
    do: Collections.remove_member(collection_id, file, dataset, opts)

  defdelegate render_collection(doc), to: Collections, as: :render

  # ── relation graph (Relations) ────────────────────────────────────────────

  def relations(file, dataset, opts \\ []), do: Relations.graph(file, dataset, opts)

  # ── public share links (Share) ────────────────────────────────────────────

  def create_share(collection_id, dataset, opts \\ []),
    do: Share.create(collection_id, dataset, opts)

  def revoke_share(collection_id, dataset, opts \\ []),
    do: Share.revoke(collection_id, dataset, opts)

  defdelegate resolve_share(token, dataset), to: Share, as: :resolve
  defdelegate share_path(dataset, token), to: Share
end
